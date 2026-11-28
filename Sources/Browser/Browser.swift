import AppKit
import WebKit

struct TabRecord: Codable {
    var id: UUID
    var url: String
    var openerTabID: UUID? = nil
    var title: String? = nil
}

struct SpaceRecord: Codable {
    var id: UUID
    var name: String
    var proxy: String
    var tabs: [TabRecord]
    var deleting: Bool = false
    var tls: TLSConfiguration?
    var suspended: Bool?
    // Only the on-disk codec uses this hint when an older daemon opens the registry.
    fileprivate var rollbackTab: UUID? = nil
    var popupCount: Int { tabs.filter { $0.openerTabID != nil }.count }
}

extension SpaceRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, proxy, tabs, deleting, tls, suspended, defaultTab
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        proxy = try fields.decode(String.self, forKey: .proxy)
        tabs = try fields.decode([TabRecord].self, forKey: .tabs)
        deleting = try fields.decode(Bool.self, forKey: .deleting)
        tls = try fields.decodeIfPresent(TLSConfiguration.self, forKey: .tls)
        suspended = try fields.decodeIfPresent(Bool.self, forKey: .suspended)
        rollbackTab = try? fields.decode(UUID.self, forKey: .defaultTab)
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(name, forKey: .name)
        try fields.encode(proxy, forKey: .proxy)
        try fields.encode(tabs, forKey: .tabs)
        try fields.encode(deleting, forKey: .deleting)
        try fields.encodeIfPresent(tls, forKey: .tls)
        try fields.encodeIfPresent(suspended, forKey: .suspended)
        let survivingPin = tabs.first { $0.id == rollbackTab }?.id
        try fields.encodeIfPresent(survivingPin ?? tabs.first?.id ?? rollbackTab, forKey: .defaultTab)
    }
}

struct BrowserLimits {
    private static func value(_ key: String, default fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 else { return fallback }
        return value
    }
    let spaces = value("BROWSER_MAX_SPACES", default: 64)
    let tabsPerSpace = value("BROWSER_MAX_TABS_PER_SPACE", default: 64)
    let totalTabs = value("BROWSER_MAX_TOTAL_TABS", default: 1024)
    let liveWebViews = value("BROWSER_MAX_LIVE_WEBVIEWS", default: 128)
    let popupsPerSpace = value("BROWSER_MAX_POPUPS_PER_SPACE", default: 8)
    var summary: [String: Int] {
        ["spaces": spaces, "tabsPerSpace": tabsPerSpace, "totalTabs": totalTabs,
         "liveWebViews": liveWebViews, "popupsPerSpace": popupsPerSpace]
    }
}

@MainActor
final class BrowserModel {
    var spaces: [Space] = []
    var records: [SpaceRecord] = []
    var changed: (() -> Void)?
    var willRemove: ((Space) -> Void)?
    var tabsCommitted: ((UUID, [TabRecord], [TabRecord]) -> Void)?
    var observerState: (() -> [String: Any])?
    private let file: URL
    var storagePath: String { file.deletingLastPathComponent().path }
    private var lockFD: Int32 = -1
    var shuttingDown = false
    private(set) var restoring = true
    private var storeCleanupErrors: [UUID: [String: Any]] = [:]
    private var removingStores: Set<UUID> = []
    private var pendingStoreCallbacks: Set<UUID> = []
    private let limits = BrowserLimits()

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        file = directory.appendingPathComponent("spaces.json")
        lockFD = Darwin.open(directory.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw BrowserError("already_running", "此数据目录已有运行中的应用") }
        if FileManager.default.fileExists(atPath: file.path) { records = try JSONDecoder().decode([SpaceRecord].self, from: Data(contentsOf: file)) }
        for var record in records where !record.deleting {
            let exceedsCapacity = record.suspended != true &&
                (record.tabs.count > limits.tabsPerSpace || record.popupCount > limits.popupsPerSpace ||
                 spaces.reduce(0) { $0 + $1.tabs.count } + record.tabs.count > limits.liveWebViews)
            if exceedsCapacity { record.suspended = true }
            let space = try Space(record, restoring: true)
            if exceedsCapacity { space.resourceBlockedReason = "恢复所需页面或弹窗超出容量；已保留为休眠 Space，可关闭多余 Tab 或释放容量后 resume" }
            spaces.append(space)
        }
        for space in spaces { bind(space) }
    }

    func restore() async throws {
        let downloads = URL(fileURLWithPath: storagePath).appendingPathComponent("downloads", isDirectory: true)
        // This process owns no previous transfers. Recovery only touches older session
        // markers and must not hold healthy Spaces hostage to one blocked file-system call.
        Task.detached(priority: .utility) {
            for error in DownloadStore.recoverIncomplete(in: downloads) {
                fputs("Pending download cleanup failed: \(error)\n", stderr)
            }
        }
        for record in records.filter(\.deleting) {
            do {
                if try await removeStore(record.id) {
                    try commitRecords(records.filter { $0.id != record.id })
                }
            }
            catch {
                storeCleanupErrors[record.id] = failure(error)["error"] as? [String: Any]
                fputs("Pending store cleanup failed (\(record.id)): \(error)\n", stderr)
            }
        }
        for space in spaces {
            for (tab, record) in zip(space.tabs, space.record.tabs) {
                if let error = space.networkError { tab.navigationError = error; continue }
                if record.url != "about:blank", let url = URL(string: record.url) { tab.load(url) }
            }
        }
        restoring = false
        changed?()
    }

    func persist() throws {
        try commitRecords(records)
    }

    private func commitRecords(_ candidate: [SpaceRecord]) throws {
        try JSONEncoder().encode(candidate).write(to: file, options: .atomic)
        records = candidate
    }

    private func bind(_ space: Space) {
        for tab in space.tabs {
            tab.downloads.directory = URL(fileURLWithPath: storagePath).appendingPathComponent("downloads", isDirectory: true)
                .appendingPathComponent(space.record.id.uuidString, isDirectory: true).appendingPathComponent(tab.id.uuidString, isDirectory: true)
            tab.createPopup = { [weak self, weak space, weak tab] configuration, url in
                guard let self, let space, let tab, !self.shuttingDown,
                      self.spaces.contains(where: { $0 === space }), !tab.closed else {
                    throw BrowserError("tab_closed", "弹窗所属 Space 或标签页已关闭")
                }
                guard configuration.websiteDataStore === space.store else {
                    throw BrowserError("popup_store_mismatch", "拒绝使用其他 Space 的网站数据创建弹窗")
                }
                try self.checkCapacity(space: space, addingTabs: 1, addingViews: 1, popup: true)
                let popup = Tab(record: TabRecord(id: UUID(), url: url.absoluteString), store: configuration.websiteDataStore,
                                tls: space.record.tls, configuration: configuration)
                popup.openerTabID = tab.id
                popup.hasUnreadPopupNotice = true
                space.tabs.append(popup); self.bind(space)
                do { try self.save(space) }
                catch { space.tabs.removeAll { $0 === popup }; popup.close(); throw error }
                self.changed?()
                return popup
            }
            tab.closeRequested = { [weak self, weak space, weak tab] in
                guard let self, let space, let tab, !tab.closed,
                      self.spaces.contains(where: { $0 === space }) else { return }
                var remaining = space.tabs.filter { $0 !== tab }
                let replacement = remaining.isEmpty ? Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: tab.webView.configuration.websiteDataStore, tls: space.record.tls) : nil
                if let replacement { remaining.append(replacement) }
                var record = space.record
                record.tabs = remaining.map { TabRecord(id: $0.id, url: $0.persistedURL, openerTabID: $0.openerTabID) }
                do { try self.commitSpaceRecord(record, for: space) }
                catch { replacement?.close(); fputs("Persistence error: \(error)\n", stderr); return }
                space.activity[tab.id] = nil
                space.tabs = remaining; tab.close(); self.bind(space)
                self.changed?()
            }
            tab.networkCheck = { [weak space] in
                if let error = space?.networkError { throw error }
            }
            tab.statusChanged = { [weak self] in self?.changed?() }
            tab.changed = { [weak self, weak space] in
                guard let self, let space, !self.shuttingDown else { return }
                do { try self.save(space) } catch { fputs("Persistence error: \(error)\n", stderr) }
                self.changed?()
            }
        }
    }

    func save(_ space: Space) throws {
        var record = space.record
        if !space.suspended && space.configurationError == nil { record.tabs = space.tabs.map { TabRecord(id: $0.id, url: $0.persistedURL, openerTabID: $0.openerTabID) } }
        try commitSpaceRecord(record, for: space)
    }

    private func commitSpaceRecord(_ record: SpaceRecord, for space: Space) throws {
        var candidate = records
        if let index = candidate.firstIndex(where: { $0.id == record.id }) { candidate[index] = record }
        try commitRecords(candidate)
        let previous = space.record.tabs
        space.record = record
        if previous.map(\.id) != record.tabs.map(\.id) {
            tabsCommitted?(record.id, previous, record.tabs)
        }
    }

    func saveAll() throws {
        var errors: [String] = []
        for space in spaces {
            do { try save(space) }
            catch { errors.append("\(space.record.name): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { throw BrowserError("persistence_failed", errors.joined(separator: "\n")) }
    }

    private func resume(_ space: Space) throws {
        guard space.suspended else { return }
        try checkCapacity(space: space, addingTabs: 0, addingViews: space.record.tabs.count)
        let previous = space.record
        try space.activate()
        space.record.suspended = false
        do { try save(space) }
        catch {
            space.record = previous
            if let index = records.firstIndex(where: { $0.id == previous.id }) { records[index] = previous }
            space.releaseRuntime()
            throw error
        }
        bind(space)
        space.resourceBlockedReason = nil
        for tab in space.tabs {
            if let error = space.networkError { tab.navigationError = error; continue }
            if tab.persistedURL != "about:blank", let url = URL(string: tab.persistedURL) { tab.load(url) }
        }
        changed?()
    }

    private func checkCapacity(space: Space? = nil, addingTabs: Int, addingViews: Int, popup: Bool = false) throws {
        let reason: String?
        if space == nil && spaces.count >= limits.spaces { reason = "Space 数量上限 \(limits.spaces)" }
        else if let space, space.record.tabs.count + addingTabs > limits.tabsPerSpace { reason = "每个 Space 的 Tab 上限 \(limits.tabsPerSpace)" }
        else if records.filter({ !$0.deleting }).reduce(0, { $0 + $1.tabs.count }) + addingTabs > limits.totalTabs { reason = "总 Tab 上限 \(limits.totalTabs)" }
        else if spaces.reduce(0, { $0 + $1.tabs.count }) + addingViews > limits.liveWebViews { reason = "活跃 WebView 上限 \(limits.liveWebViews)" }
        else if let space, space.record.popupCount + (popup ? 1 : 0) > limits.popupsPerSpace { reason = "网页弹窗上限 \(limits.popupsPerSpace)" }
        else { reason = nil }
        if let reason { throw BrowserError("resource_limit", "已达到\(reason)；请显式关闭或休眠不再使用的页面") }
    }

    private func removeStore(_ id: UUID) async throws -> Bool {
        guard !removingStores.contains(id), !pendingStoreCallbacks.contains(id) else {
            throw BrowserError("space_busy", "此 Store 仍在删除或等待 WebKit 清理回调；请稍后重试")
        }
        removingStores.insert(id)
        defer { removingStores.remove(id) }
        // Occupy this UUID before yielding, including the detached view release window.
        try await Task.sleep(nanoseconds: 100_000_000)
        // All callers may run in a fresh process with no active Space stores.
        // Keep WebKit initialized throughout removal and fallback cleanup.
        let cleanupBootstrap = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(cleanupBootstrap) {} }
        do { try await removeStoreOnce(id); return true }
        catch {
            if (error as? BrowserError)?.code == "data_store_removal_timeout" { throw error }
            // WebKit may retain an idle network session after a stalled view is replaced.
            // Clear and verify the website data through the public API; keep the tombstone
            // if the empty store container cannot yet be removed in this process.
            try await clearStoreContents(id)
            for delay in [100, 200, 400] {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                do { try await removeStoreOnce(id); return true }
                catch {
                    if (error as? BrowserError)?.code == "data_store_removal_timeout" { throw error }
                }
            }
            return false
        }
    }

    private func clearStoreContents(_ id: UUID) async throws {
        let store = WKWebsiteDataStore(forIdentifier: id)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        pendingStoreCallbacks.insert(id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = PendingOperation(continuation)
            operation.arm(milliseconds: 5000, error: BrowserError("data_removal_timeout", "网站数据清理超时；已保留删除标记，下次启动会重试"), onTimeout: {})
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                store.fetchDataRecords(ofTypes: types) { records in
                    self.pendingStoreCallbacks.remove(id)
                    if records.isEmpty { operation.finish(.success(())) }
                    else { operation.finish(.failure(BrowserError("data_removal_failed", "网站数据仍存在；已保留删除标记，下次启动会重试"))) }
                }
            }
        }
    }

    private func removeStoreOnce(_ id: UUID) async throws {
        pendingStoreCallbacks.insert(id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = PendingOperation(continuation)
            operation.arm(milliseconds: 5000, error: BrowserError("data_store_removal_timeout", "Store 删除超时；已保留删除标记，下次启动会重试"), onTimeout: {})
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                // The caller timing out does not mean WebKit has stopped this operation.
                self.pendingStoreCallbacks.remove(id)
                if let error { operation.finish(.failure(error)) } else { operation.finish(.success(())) }
            }
        }
    }

    private func detach(_ id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.record.id == id }) else { return }
        let space = spaces.remove(at: index)
        willRemove?(space)
        for tab in space.tabs { tab.close() }
        space.tabs = []
    }

    func handle(_ request: Request, origin: RequestOrigin, onConfirmation: ((ObserverImpact) -> Void)? = nil) async -> [String: Any] {
        let timing = RequestTiming()
        var response: [String: Any]
        do { response = ["ok": true, "result": try await execute(request, timing: timing, origin: origin)] }
        catch let impact as ObserverImpact {
            response = failure(BrowserError("confirmation_required", impact.detail))
            onConfirmation?(impact)
        } catch { response = failure(error) }
        response["timing"] = timing.summary
        return response
    }

    func finishDialogsForExit() {
        for space in spaces {
            for tab in space.tabs { tab.dialogs.stop(code: "dialog_cancelled") }
            for tab in space.tabs { tab.downloads.stop(); tab.fileChooser.stop() }
        }
    }

    private var shutdownImpact: [String: Any] {
        ["spaces": spaces.map { space in
            ["spaceId": space.record.id.uuidString, "name": space.record.name,
             "tabIds": space.record.tabs.map { $0.id.uuidString }] as [String: Any]
        }, "websiteDataPreserved": true, "pageMemoryPreserved": false]
    }

    private func execute(_ r: Request, timing: RequestTiming, origin: RequestOrigin) async throws -> Any {
        guard !shuttingDown else { throw BrowserError("shutting_down", "应用正在退出") }
        try r.validate()
        let command = r.command
        guard !restoring || ["status", "help", "capabilities", "version"].contains(command) else {
            throw BrowserError("not_ready", "应用正在恢复会话；请等待 status.ready 为 true")
        }
        if command != "click", r.options["wait-for-navigation"] != nil {
            throw BrowserError("invalid_arguments", "--wait-for-navigation 只能用于 click")
        }
        if command != "space.create", r.options["ca-cert"] != nil || r.options["ignore-certificate-errors"] != nil {
            throw BrowserError("invalid_arguments", "证书策略只能在 space create 时配置")
        }
        func arg(_ index: Int) throws -> String {
            guard r.args.indices.contains(index) else { throw BrowserError("invalid_arguments", "缺少参数；awb help 查看用法") }
            return r.args[index]
        }
        if command == "help" { return try CLIContract.help(r.args) }
        if command == "capabilities" { return CLIContract.capabilities }
        if command == "version" { return ["version": productVersion] }
        if command == "status" {
            let liveWebViews = spaces.reduce(0) { $0 + $1.tabs.count }
            let pendingStores: [[String: String]] = records.filter(\.deleting).map {
                ["spaceId": $0.id.uuidString, "name": $0.name]
            }
            let cleanupErrors: [[String: Any]] = storeCleanupErrors.map {
                ["spaceId": $0.key.uuidString, "error": $0.value]
            }
            let blockedSpaceIDs = spaces.filter { $0.networkError != nil }.map { $0.record.id.uuidString }
            let capabilities: [String: Any] = ["input":"dom-synthetic", "keyboard":"explicit focus/key; limited directed AppKit events, main document/open shadow only", "snapshot":"same-origin-frames-and-open-shadow-roots", "crossOriginDOM":"frame list + explicit --tab/--frame", "frameCommands":Request.frameCommands, "fixedViewport":true, "screenshot":"viewport", "screenshotModes":["viewport", "element", "full-page"], "foregroundRequired":false]
            return ["version": productVersion, "pid": ProcessInfo.processInfo.processIdentifier, "spaces": spaces.count,
                    "ready": !restoring,
                    "shutdownImpact": shutdownImpact,
                    "liveWebViews": liveWebViews,
                    "resourceLimits": limits.summary,
                    "observer": observerState?() ?? [:],
                    "pendingStoreCleanup": pendingStores.count,
                    "pendingStores": pendingStores,
                    "storeCleanupErrors": cleanupErrors,
                    "blockedSpaces": blockedSpaceIDs,
                    "systemProxy": systemProxySummary(), "frontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                    "capabilities": capabilities,
                    "directPolicy":"reject-enabled-system-proxy; no VPN/content-filter bypass guarantee"] as [String: Any]
        }
        if command == "shutdown" {
            guard !spaces.contains(where: \.busy) else { throw BrowserError("space_busy", "仍有操作执行中") }
            try saveAll()
            let impact = shutdownImpact
            shuttingDown = true
            finishDialogsForExit()
            // Give the reply time to reach the client; terminate through AppKit to release WebKit cleanly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return ["shutdown": true, "shutdownImpact": impact]
        }
        if command == "space.list" { return spaces.map(\.summary) }
        if command == "space.create" {
            let name = try arg(0)
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw BrowserError("invalid_name", "名称须以英文字母开头，最多 64 位，可包含英文字母、数字、下划线和连字符。") }
            guard !records.contains(where: { $0.name == name && !$0.deleting }) else { throw BrowserError("space_exists", "Space 已存在") }
            guard let proxy = r.options["proxy"] else { throw BrowserError("proxy_required", "创建 Space 必须显式指定 --proxy direct 或 --proxy http://127.0.0.1:<PORT>") }
            guard r.options["ca-cert"] == nil || r.options["ignore-certificate-errors"] == nil else {
                throw BrowserError("invalid_arguments", "--ca-cert 和 --ignore-certificate-errors 不能同时使用")
            }
            let tab = TabRecord(id: UUID(), url: "about:blank")
            let tls = r.options["ignore-certificate-errors"] == "true" ? TLSConfiguration.insecure : try r.options["ca-cert"].map { try TLSConfiguration(path: $0) }
            try checkCapacity(addingTabs: 1, addingViews: 1)
            let record = SpaceRecord(id: UUID(), name: name, proxy: proxy, tabs: [tab], tls: tls)
            let space = try Space(record)
            records.append(record)
            do { try persist() } catch { records.removeLast(); throw error }
            spaces.append(space); bind(space); changed?()
            return space.summary
        }
        let target = command.hasPrefix("space.") ? try arg(0) : r.options["space"]
        guard let target else { throw BrowserError("space_required", "缺少 --space NAME_OR_ID；先用 awb space list 查看已有 Space 或 awb space create 创建") }
        let id: UUID
        if let uuid = UUID(uuidString: target) {
            // A confirmed UUID must keep its identity even after its record disappears.
            guard records.contains(where: { $0.id == uuid }) else {
                throw BrowserError("space_not_found", "Space 不存在：\(target)")
            }
            id = uuid
        } else {
            let matches = records.filter { $0.name == target && (command == "space.delete" || !$0.deleting) }
            guard let record = matches.first else {
                throw BrowserError("space_not_found", "Space 不存在：\(target)；运行 awb space list 核对名称或 UUID")
            }
            guard matches.count == 1 else {
                throw BrowserError("space_ambiguous", "同名 Space 包含待清理记录；请从 space list 和 status.pendingStores 确认 UUID")
            }
            id = record.id
        }
        if command == "space.delete" {
            // Avoid retaining the Space/DataStore across the asynchronous removal API.
            if let live = spaces.first(where: { $0.record.id == id }) {
                guard !live.busy else { throw BrowserError("space_busy", "Space 正在操作中") }
                try live.checkObserverImpact(command, origin: origin)
            } else if origin != .agent {
                throw BrowserError("space_not_found", "Space 已移除，数据容器仍待清理。")
            }
            var candidate = records
            if let index = candidate.firstIndex(where: { $0.id == id }) { candidate[index].deleting = true }
            try commitRecords(candidate); detach(id); changed?()
            defer { changed?() }
            let removed = try await removeStore(id)
            if removed { try commitRecords(records.filter { $0.id != id }); storeCleanupErrors[id] = nil }
            return ["deleted": true, "spaceId": id.uuidString, "websiteDataRemoved": true,
                    "dataStoreRemoved": removed, "cleanupPending": !removed]
        }
        guard let space = spaces.first(where: { $0.record.id == id }) else { throw BrowserError("space_not_found", "Space 已删除") }
        if command == "space.info" { return space.summary }
        if command == "tab.list" { return space.tabStates }
        let targetTab = r.options["tab"].flatMap(UUID.init(uuidString:))
        if r.options["tab"] != nil, !space.record.tabs.contains(where: { $0.id == targetTab }) {
            throw BrowserError("tab_not_found", "Space 中不存在该标签页；运行 awb tab list --space \(space.record.id.uuidString) 核对 Tab UUID")
        }
        if let error = space.configurationError { throw error }
        if command == "space.suspend" {
            guard !space.busy else { throw BrowserError("space_busy", "Space 正在操作中") }
            guard !space.tabs.contains(where: { $0.downloads.hasActive }) else { throw BrowserError("space_busy", "Space 有下载进行中；先等待或显式取消") }
            if !space.suspended {
                try space.checkObserverImpact(command, origin: origin)
                try save(space)
                let previous = space.record
                for (index, tab) in space.tabs.enumerated() { space.record.tabs[index].title = tab.webView.title }
                space.record.suspended = true
                do { try save(space) }
                catch {
                    space.record = previous
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index] = previous }
                    throw error
                }
                willRemove?(space)
                space.releaseRuntime(); changed?()
            }
            return space.summary
        }
        if command == "space.resume" {
            guard !space.busy else { throw BrowserError("space_busy", "Space 正在操作中") }
            try resume(space)
            return space.summary
        }
        // Page reads, dialog responses and download waits can overlap a locked page action.
        // Count their lifetimes without changing the Space command lock.
        var trackedTab: UUID?
        var renewsRecent = false
        var didWork = false
        func setBusy(_ busy: Bool, tab: UUID? = nil) {
            space.busy = busy
            space.busyTabID = tab
            space.busyOrigin = busy ? origin : nil
            changed?()
        }
        func beginActivity(_ id: UUID, renewing: Bool) {
            renewsRecent = renewing
            trackedTab = id
            space.activity[id, default: TabActivity()].executing += 1
            changed?()
        }
        defer {
            if let id = trackedTab, var activity = space.activity[id] {
                activity.executing -= 1
                if origin == .agent && renewsRecent && (didWork || timing.hasWebKitWork) { activity.agentFinishedAt = .now }
                space.activity[id] = activity
                changed?()
            }
        }
        if space.suspended, ["state", "diagnostics", "dialog.list", "dialog.respond", "download.list", "download.wait", "download.cancel"].contains(command) {
            guard let state = space.tabStates.first(where: { ($0["tabId"] as? String) == targetTab?.uuidString }) else {
                throw BrowserError("tab_not_found", "Space 中不存在该标签页；运行 awb tab list --space \(space.record.id.uuidString) 核对 Tab UUID")
            }
            guard command == "state" else { throw BrowserError("space_suspended", "Space 已休眠；使用 space resume 显式恢复") }
            return ["spaceId": id.uuidString, "space": space.record.name, "proxy": space.record.proxy,
                    "network": space.networkState, "page": state, "busy": false, "value": NSNull()] as [String: Any]
        }
        if command == "state" || command == "diagnostics" || command.hasPrefix("dialog.") || command.hasPrefix("download.") {
            guard let tab = space.tabs.first(where: { $0.id == targetTab }) else {
                throw BrowserError("tab_not_found", "Space 中不存在该标签页；运行 awb tab list --space \(space.record.id.uuidString) 核对 Tab UUID")
            }
            if command.hasPrefix("download.") {
                if command == "download.list" { return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "value": tab.downloads.snapshot()] }
                let downloadID = try arg(0)
                if command == "download.cancel" {
                    _ = try tab.downloads.item(downloadID)
                    beginActivity(tab.id, renewing: true)
                    try await tab.downloads.cancelAndWait(downloadID) { didWork = true }
                }
                if command == "download.wait" {
                    let timeout = Int(r.options["timeout"] ?? "15000") ?? 0
                    guard (1...60000).contains(timeout) else { throw BrowserError("invalid_timeout", "timeout 必须为 1–60000 ms") }
                    let download = try tab.downloads.item(downloadID)
                    guard download["status"] as? String == "running" else {
                        return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "value": download]
                    }
                    beginActivity(tab.id, renewing: false)
                    let start = monotonicNow()
                    while (try tab.downloads.item(downloadID)["status"] as? String) == "running" {
                        guard !tab.closed else { throw BrowserError("tab_closed", "目标标签页已关闭") }
                        guard milliseconds(from: start) < Double(timeout) else { throw BrowserError("timeout", "等待下载超时；原下载继续，不要重复触发动作") }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
                return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "value": try tab.downloads.item(downloadID)]
            }
            if command.hasPrefix("dialog.") {
                let value = command == "dialog.list" ? tab.dialogs.snapshot() : try tab.dialogs.respond(id: arg(0), action: arg(1), text: r.options["text"])
                if command == "dialog.respond" {
                    beginActivity(tab.id, renewing: true)
                    didWork = true
                }
                return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "busy": space.busy, "value": value]
            }
            if command == "diagnostics" {
                // Reads and disabling remain available while busy, blocked or hung.
                if let mode = r.options["detail"], mode != "off", space.busy {
                    throw BrowserError("space_busy", "启用详细诊断需要等待当前操作完成")
                }
                if r.options["detail"] != nil || r.options["inspectable"] != nil || r.options["clear"] == "true" {
                    beginActivity(tab.id, renewing: true)
                }
                if let inspectable = r.options["inspectable"] { tab.webView.isInspectable = inspectable == "on" }
                if r.options["detail"] == "off" {
                    tab.disableDiagnosticDetails()
                } else if let detail = r.options["detail"] {
                    setBusy(true, tab: tab.id)
                    tab.operationTiming = timing; tab.deadline = monotonicNow() + 2_000_000_000
                    defer { tab.operationTiming = nil; tab.deadline = nil; setBusy(false) }
                    try await tab.enableDiagnosticDetails(continuous: detail == "continuous", includeInfo: r.options["include-info"] == "true")
                }
                didWork = true
                var value = tab.diagnostics.snapshot(clear: r.options["clear"] == "true")
                value["inspectable"] = tab.webView.isInspectable
                return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "busy": space.busy,
                        "networkBlocked": space.networkError != nil,
                        "networkErrorCode": space.networkError?.code as Any? ?? NSNull(),
                        "value": value]
            }
            return ["spaceId": id.uuidString, "space": space.record.name, "proxy": space.record.proxy,
                    "network": space.networkState, "page": tab.state, "busy": space.busy, "value": NSNull()] as [String: Any]
        }
        guard !space.busy else { throw BrowserError("space_busy", "同一 Space 已有操作执行中；先用 state 和 dialog list 检查是否正在等待 JS 对话框，否则等待原操作完成后再顺序执行") }
        setBusy(true, tab: targetTab)
        defer { setBusy(false) }
        if command != "tab.close", let error = space.networkError { throw error }
        let timeout: Int
        if let raw = r.options["timeout"] {
            guard let value = Int(raw), (1...60000).contains(value) else { throw BrowserError("invalid_timeout", "timeout 必须为 1–60000 ms") }; timeout = value
        } else { timeout = 15000 }
        if command == "open" { _ = try validateURL(arg(0)) }
        if command == "tab.new" { _ = try validateURL(r.args.first ?? "about:blank") }
        if command == "tab.new" {
            try checkCapacity(space: space, addingTabs: 1, addingViews: space.suspended ? space.record.tabs.count + 1 : 1)
        }
        if command == "tab.close" {
            var record = space.record
            if !space.suspended { record.tabs = space.tabs.map { TabRecord(id: $0.id, url: $0.persistedURL, openerTabID: $0.openerTabID) } }
            guard let index = record.tabs.firstIndex(where: { $0.id == targetTab }) else { throw BrowserError("tab_not_found", "标签页不存在") }
            let id = record.tabs[index].id
            guard record.tabs.count > 1 else { throw BrowserError("last_tab", "不能关闭最后一个标签页；可休眠 Space") }
            let activity = space.activity[id]
            guard (activity?.executing ?? 0) == 0 else { throw BrowserError("space_busy", "标签页仍有操作执行中") }
            try space.checkObserverImpact(command, tabID: id, origin: origin)
            record.tabs.remove(at: index)
            try commitSpaceRecord(record, for: space)
            if let tab = space.tabs.first(where: { $0.id == id }) {
                space.tabs.removeAll { $0 === tab }; tab.close()
            }
            space.activity[id] = nil
            changed?()
            return ["closed": id.uuidString]
        }
        let wasSuspended = space.suspended
        if wasSuspended, case .confirmed = origin {
            throw BrowserError("space_suspended", "Space 在确认期间已休眠；请先显式恢复。")
        }
        try resume(space)
        guard let store = space.store else { throw BrowserError("space_suspended", "Space 尚未恢复") }
        if command == "tab.new" {
            let url = try validateURL(r.args.first ?? "about:blank")
            let tab = Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: store, tls: space.record.tls)
            tab.operationTiming = timing; tab.deadline = monotonicNow() + UInt64(timeout) * 1_000_000
            defer { tab.operationTiming = nil; tab.deadline = nil }
            space.tabs.append(tab); bind(space)
            do { try save(space) }
            catch { space.tabs.removeAll { $0 === tab }; tab.close(); throw error }
            space.busyTabID = tab.id
            beginActivity(tab.id, renewing: true)
            didWork = true
            do {
                tab.load(url); try await tab.wait(selector: nil, timeout: timeout); try save(space)
            } catch {
                throw BrowserError((error as? BrowserError)?.code ?? "operation_failed",
                    "标签页已创建（\(tab.id.uuidString)），但导航或保存未完成：\(error.localizedDescription)；请查询该 Tab 状态后再继续，避免重复创建")
            }
            return tab.state
        }
        guard var tab = space.tabs.first(where: { $0.id == targetTab }) else {
            throw BrowserError("tab_not_found", "Space 中不存在该标签页；运行 awb tab list --space \(space.record.id.uuidString) 核对 Tab UUID")
        }
        // Replace a stalled view only on explicit navigation. Never replay an Agent action.
        let navigating = command == "open" || command == "reload"
        if navigating || command == "back" || command == "forward" {
            try space.checkObserverImpact(command, tabID: tab.id, origin: origin)
        }
        if navigating, tab.terminated || tab.unresponsive {
            let index = space.tabs.firstIndex(where: { $0 === tab })!
            let record = TabRecord(id: tab.id, url: tab.persistedURL, openerTabID: tab.openerTabID)
            tab.close()
            let replacement = Tab(record: record, store: store, tls: space.record.tls, diagnostics: tab.diagnostics)
            replacement.setViewport(tab.fixedViewport)
            space.tabs[index] = replacement; tab = replacement
            bind(space); changed?()
        }
        let observing = ["snapshot", "screenshot", "frame.list", "viewport.get", "wait"].contains(command)
        beginActivity(tab.id, renewing: !observing)
        tab.operationTiming = timing; tab.deadline = monotonicNow() + UInt64(timeout) * 1_000_000
        defer { tab.operationTiming = nil; tab.deadline = nil }
        var value: Any = NSNull()
        if wasSuspended, !["open", "reload"].contains(command) { try await tab.wait(selector: nil, timeout: timeout) }
        switch command {
        case "open":
            let url = try validateURL(arg(0))
            didWork = true
            tab.load(url)
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "reload":
            let url = try validateURL(tab.persistedURL)
            didWork = true
            tab.load(url)
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "state": break
        case "back", "forward":
            value = try await tab.traverseHistory(back: command == "back")
            try save(space)
        case "viewport.get", "viewport.set":
            var size: NSSize?
            if command == "viewport.set", let width = Int(r.args[0]), let height = Int(r.args[1]) {
                size = NSSize(width: width, height: height)
            }
            let viewport = try await tab.cssViewport(setting: size)
            let points = tab.webView.bounds.size
            value = ["cssViewport": ["width": viewport.width, "height": viewport.height, "devicePixelRatio": viewport.devicePixelRatio],
                     "viewPoints": ["width": points.width, "height": points.height]]
        case "focus": value = try await tab.focus(target: arg(0))
        case "key":
            guard let key = BackgroundKey(rawValue: try arg(0)) else { throw BrowserError("unsupported_key", "不支持此后台按键") }
            value = try await tab.key(key)
        case "frame.list": value = try await tab.frameList()
        case "snapshot":
            let scope = try r.options["scope"].map(quoteJS) ?? "null"
            let role = try r.options["role"].map(quoteJS) ?? "null"
            let name = try r.options["name"].map(quoteJS) ?? "null"
            value = try await tab.runJS("window.__agentWebKit.snapshot(\(scope),\(r.options["interactive"] == "true"),\(role),\(name))", world: DOM.world, frameID: r.options["frame"])
            if let frameID = r.options["frame"], var snapshot = value as? [String: Any] {
                snapshot["frameId"] = frameID
                if snapshot["textScope"] as? String == "main-frame" { snapshot["textScope"] = "selected-frame" }
                snapshot["visibilityScope"] = "selected-document; cross-origin embedding ancestors not checked"
                snapshot["elements"] = (snapshot["elements"] as? [[String: Any]] ?? []).map { element in
                    var element = element
                    if var bounds = element["bounds"] as? [String: Any] {
                        bounds["coordinateSpace"] = "frame-viewport"; element["bounds"] = bounds
                    }
                    return element
                }
                value = snapshot
            }
        case "evaluate": value = try await tab.runJS(arg(0), awaitPromise: r.options["await"] == "true")
        case "click", "fill", "select", "check", "uncheck":
            let before = tab.navigationSequence
            let beforeError = tab.navigationErrorRevision
            let beforePopup = tab.popupSequence
            tab.lastNavigationRejection = nil
            let input = r.args.count == 2 ? r.args[1] : ""
            value = try await tab.runJS("window.__agentWebKit.act(\(try quoteJS(command)),\(try quoteJS(arg(0))),\(try quoteJS(input)))", world: DOM.world, frameID: r.options["frame"])
            if r.options["wait-for-navigation"] == "true" { try await tab.waitForNavigation(after: before, errorRevision: beforeError, timeout: timeout) }
            if r.options["wait-for-popup"] == "true" {
                let popupID = try await tab.waitForPopup(after: beforePopup, timeout: timeout)
                var action = value as? [String: Any] ?? [:]
                action["newTabId"] = popupID; value = action
            }
        case "scroll":
            guard let x = Int(try arg(0)), let y = Int(try arg(1)) else { throw BrowserError("invalid_arguments", "scroll 需要整数偏移") }
            value = try await tab.runJS("window.__agentWebKit.scroll(\(x),\(y))", world: DOM.world, frameID: r.options["frame"])
        case "wait":
            try await tab.wait(selector: r.args.first, timeout: timeout, state: r.options["state"] ?? "visible",
                               text: r.options["text"], url: r.options["url"], urlPattern: r.options["url-pattern"],
                               function: r.options["fn"], stableFor: r.options["stable-for"].flatMap(Int.init) ?? 0, frameID: r.options["frame"])
        case "screenshot":
            guard let path = r.options["out"] else { throw BrowserError("invalid_arguments", "截图需要 --out PATH") }
            value = try await tab.screenshot(path: path, element: r.options["element"], fullPage: r.options["full-page"] == "true")
        case "upload": value = try await tab.upload(target: arg(0), paths: Array(r.args.dropFirst()))
        default: throw BrowserError("unknown_command", "未知命令")
        }
        didWork = true
        if r.options["fail-on-http-error"] == "true", let status = tab.state["httpStatus"] as? Int, status >= 400 {
            throw BrowserError("http_error", "主文档 HTTP \(status)；使用 state 查看响应 URL 和导航 ID")
        }
        var result: [String: Any] = ["spaceId": id.uuidString, "space": space.record.name, "proxy": space.record.proxy, "network": space.networkState, "page": tab.state, "value": value]
        if let frameID = r.options["frame"] {
            result["frameId"] = frameID
            result["visibilityScope"] = "selected-document; cross-origin embedding ancestors not checked"
        }
        return result
    }

    private func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") && url.host != nil || raw == "about:blank" else {
            throw BrowserError("invalid_url", "仅支持完整 http(s) URL 或 about:blank")
        }
        return url
    }
}
