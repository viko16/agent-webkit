import CFNetwork
import Network
import WebKit

func systemProxyState() -> [String: Any] {
    (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
}

func activeSystemProxyTypes() -> [String] {
    let keys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
    var active = Set<String>()
    func visit(_ settings: [String: Any]) {
        for key in keys where (settings[key] as? NSNumber)?.boolValue == true { active.insert(key) }
        for value in settings.values { if let nested = value as? [String: Any] { visit(nested) } }
    }
    visit(systemProxyState())
    return active.sorted()
}

func systemProxySummary() -> [String: Any] {
    let active = activeSystemProxyTypes()
    return ["enabled": !active.isEmpty, "enabledTypes": active]
}

func requireDirectAvailable() throws {
    let active = activeSystemProxyTypes()
    if !active.isEmpty {
        throw BrowserError("direct_system_proxy_conflict", "此 Direct Space 已暂停：系统代理已启用（\(active.joined(separator: ","))）。关闭系统代理后重新加载即可恢复；Cookie、Tab ID 和 URL 保留。公开 WebKit API 无强制直连开关")
    }
}

enum RequestOrigin: Equatable {
    case agent, observer, confirmed(ObserverImpact)
    case closingOtherTabs(keeping: UUID, consent: ObserverImpact?)
}

// In-process only. Bind a sheet's consent to the exact work it described.
struct ObserverImpact: Error, Equatable {
    let command: String
    let spaceID: UUID
    let spaceName: String
    let tabs: Set<UUID>
    let downloads: Set<String>
    let dialogs: Set<String>
    let recentActivity: ContinuousClock.Instant?

    var detail: String {
        var messages: [String] = []
        if command == "space.delete" { messages.append("将移除全部标签页、登录状态和网站数据，无法撤销。") }
        if command == "space.suspend" { messages.append("休眠会释放此 Space 的所有页面，未提交的表单内容会丢失。标签页地址和网站数据会保留。") }
        if !downloads.isEmpty { messages.append("将中断 \(downloads.count) 项活跃下载。") }
        if !dialogs.isEmpty { messages.append("将关闭 \(dialogs.count) 个待处理的网页对话框。") }
        if recentActivity != nil { messages.append("Agent 在最近 5 分钟内操作过目标标签页。") }
        return messages.joined(separator: "\n")
    }
}

struct TabActivity {
    var executing = 0
    var agentFinishedAt: ContinuousClock.Instant?
    var recentUntil: ContinuousClock.Instant? { agentFinishedAt?.advanced(by: .seconds(300)) }
    var recent: Bool { recentUntil.map { $0 > .now } ?? false }
}

@MainActor
final class Space {
    var record: SpaceRecord
    private(set) var store: WKWebsiteDataStore?
    var tabs: [Tab] = []
    var activity: [UUID: TabActivity] = [:]
    var busy = false
    var busyTabID: UUID?
    var busyOrigin: RequestOrigin?
    var resourceBlockedReason: String?
    private(set) var configurationError: BrowserError?
    init(_ record: SpaceRecord, restoring: Bool = false) throws {
        self.record = record
        do {
            _ = try proxyConfigurations()
            if record.suspended != true { try activate() }
        } catch {
            guard restoring, let error = error as? BrowserError else { throw error }
            configurationError = error
        }
    }
    func checkObserverImpact(_ command: String, tabID: UUID? = nil, origin: RequestOrigin) throws {
        let consent: ObserverImpact?
        switch origin {
        case .agent: return
        case .observer: consent = nil
        case .confirmed(let impact): consent = impact
        case let .closingOtherTabs(keeping, approved):
            // Under the same Space lock as the close, including after every sheet.
            guard command == "tab.close", keeping != tabID, tabs.contains(where: { $0.id == keeping }) else {
                throw BrowserError("batch_target_unavailable", "已停止关闭其他标签页：要保留的标签页已关闭，或 Space 已休眠。")
            }
            consent = approved
        }
        if let impact = try observerImpact(command, tabID: tabID), impact != consent { throw impact }
    }

    func observerImpact(_ command: String, tabID: UUID? = nil) throws -> ObserverImpact? {
        let ids = tabID.map { Set([$0]) } ?? Set(record.tabs.map(\.id))
        guard !ids.contains(where: { (activity[$0]?.executing ?? 0) > 0 }) else {
            throw BrowserError("space_busy", "目标标签页仍有操作执行中，请等待完成。")
        }
        let live = tabs.filter { ids.contains($0.id) }
        // Ordinary navigation dismisses dialogs but leaves WKDownload instances alone.
        let preservesDownloads = ["back", "forward"].contains(command)
            || (["open", "reload"].contains(command) && !live.contains { $0.terminated || $0.unresponsive })
        let downloads = preservesDownloads ? [] : Set(live.flatMap { $0.downloads.activeIDs })
        let dialogs = Set(live.flatMap { $0.dialogs.pendingIDs })
        let closing = tabID.flatMap { activity[$0] }
        let recent = command == "tab.close" && closing?.recent == true ? closing?.agentFinishedAt : nil
        guard command == "space.delete" || command == "space.suspend" || !downloads.isEmpty || !dialogs.isEmpty || recent != nil else { return nil }
        return ObserverImpact(command: command, spaceID: record.id, spaceName: record.name, tabs: ids,
                              downloads: downloads, dialogs: dialogs, recentActivity: recent)
    }

    var suspended: Bool { record.suspended == true }
    func activate() throws {
        guard tabs.isEmpty else { return }
        if let configurationError { throw configurationError }
        let configurations = try proxyConfigurations()
        let store = self.store ?? WKWebsiteDataStore(forIdentifier: record.id)
        store.proxyConfigurations = configurations
        self.store = store
        tabs = record.tabs.map { Tab(record: $0, store: store, tls: record.tls) }
    }
    private func proxyConfigurations() throws -> [ProxyConfiguration] {
        let configurations: [ProxyConfiguration]
        if record.proxy == "direct" {
            configurations = []
        } else {
            guard let url = URL(string: record.proxy), url.scheme == "http", url.host == "127.0.0.1",
                  let port = url.port, (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)),
                  url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else {
                throw BrowserError("invalid_proxy", "仅支持 direct 或 http://127.0.0.1:<PORT>，端口须为 1–65535；不支持认证、路径、查询参数或片段")
            }
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: endpointPort))
            proxy.allowFailover = false
            proxy.matchDomains = []
            proxy.excludedDomains = []
            configurations = [proxy]
        }
        return configurations
    }
    func releaseRuntime() {
        for tab in tabs { tab.close() }
        // Keep the data-store coordinator alive: dropping it before WebKit flushes
        // newly written cookies loses them even during same-process restoration.
        tabs = []
    }
    var tabStates: [[String: Any]] {
        if !suspended && configurationError == nil { return tabs.map(\.state) }
        return record.tabs.map { tab in
            ["tabId": tab.id.uuidString, "url": tab.url, "title": tab.title ?? "", "loading": false,
             "navigationId": NSNull(), "navigationPhase": "suspended", "httpStatus": NSNull(), "responseURL": NSNull(),
             "httpResponseNavigationId": NSNull(), "redirectCount": 0,
             "webContentTerminated": false, "unresponsive": false, "suspended": true,
             "pendingDialogs": 0, "requiresForeground": false, "tls": record.tls?.summary ?? TLSConfiguration.systemSummary]
        }
    }
    var summary: [String: Any] {
        ["id": record.id.uuidString, "name": record.name, "proxy": record.proxy, "persistent": true,
         "dataStoreId": record.id.uuidString,
         "tabs": tabStates, "busy": busy, "network": networkState,
         "lifecycle": configurationError != nil ? "configuration-error" : suspended ? "suspended" : "active", "liveWebViews": tabs.count,
         "configurationError": configurationError.map { failure($0)["error"]! } ?? NSNull(),
         "resourceBlockedReason": resourceBlockedReason as Any? ?? NSNull(),
         "tls": record.tls?.summary ?? TLSConfiguration.systemSummary]
    }
    var networkState: [String: Any] {
        let error = networkError
        return ["configuredProxy": record.proxy, "routeVerified": false,
         "blocked": error != nil, "recoverable": error != nil,
         "error": error.map { failure($0)["error"]! } ?? NSNull(),
         "limitation": record.proxy == "direct"
            ? "System proxy checked on restore, commands and navigation; already running page requests may follow changed system settings. Cannot bypass VPN/content filters. Disable system proxy then reload to resume."
            : "Loopback requests, including localhost and 127.0.0.1, may bypass this proxy. Configuration success is not route verification."]
    }
    var networkError: BrowserError? {
        if let configurationError { return configurationError }
        guard record.proxy == "direct" else { return nil }
        do { try requireDirectAvailable(); return nil }
        catch { return error as? BrowserError }
    }
}
