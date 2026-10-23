import AppKit
import WebKit
import Network
import CFNetwork
import Security

struct TabRecord: Codable { var id: UUID; var url: String }
struct SpaceRecord: Codable {
    var id: UUID
    var name: String
    var proxy: String
    var defaultTab: UUID
    var tabs: [TabRecord]
    var deleting: Bool = false
    var tls: TLSConfiguration?
}

func systemProxyState() -> [String: Any] {
    (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
}

func requireDirectAvailable() throws {
    let settings = systemProxyState()
    let keys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
    func enabled(_ dictionary: [String: Any]) -> [String] {
        var active = keys.filter { (dictionary[$0] as? NSNumber)?.boolValue == true }
        for (key, value) in dictionary {
            if let nested = value as? [String: Any] { active += enabled(nested).map { "\(key).\($0)" } }
        }
        return active
    }
    let active = enabled(settings)
    if !active.isEmpty {
        throw BrowserError("direct_system_proxy_conflict", "系统代理已启用（\(active.joined(separator: ","))）；公开 WebKit API 无强制直连开关，拒绝将系统代理当作 direct")
    }
}

@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    let backingWindow: NSPanel
    var navigationError: Error?
    var changed: (() -> Void)?
    var suppressedDialogs = 0
    var terminated = false
    let tls: TLSConfiguration?
    var tlsChallenge: [String: Any] = [:]
    var certificateError: BrowserError?
    var operationTiming: RequestTiming?
    private struct NavigationSpan {
        let timing: RequestTiming?
        let token: Int?
        let sequence: Int
    }
    private var navigationSpans: [ObjectIdentifier: NavigationSpan] = [:]
    private(set) var navigationSequence = 0
    private var completedNavigationSequence = 0

    init(record: TabRecord, store: WKWebsiteDataStore, tls: TLSConfiguration?) {
        id = record.id
        self.tls = tls
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(source: DOM.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        backingWindow = NSPanel(contentRect: webView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        backingWindow.isReleasedWhenClosed = false
        backingWindow.contentView = webView
        webView.navigationDelegate = self; webView.uiDelegate = self
    }

    func park() {
        webView.removeFromSuperview()
        backingWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        backingWindow.orderOut(nil)
    }

    func close() {
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview(); backingWindow.contentView = nil; backingWindow.close()
        changed = nil
        navigationSpans.removeAll()
    }

    var state: [String: Any] {
        ["tabId": id.uuidString, "url": webView.url?.absoluteString ?? "about:blank", "title": webView.title ?? "",
         "loading": webView.isLoading, "webContentTerminated": terminated, "suppressedDialogs": suppressedDialogs,
         "requiresForeground": false, "tls": tls?.summary ?? TLSConfiguration.systemSummary,
         "lastTLSChallenge": tlsChallenge]
    }

    func runJS(_ script: String) async throws -> Any {
        guard !terminated else { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请重新 open") }
        let timing = operationTiming
        let start = monotonicNow()
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                timing?.record("evaluateJavaScript", from: start)
                if let error {
                    let nsError = error as NSError
                    if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
                        let code = message.contains("stale_ref:") ? "stale_ref" : "javascript_error"
                        continuation.resume(throwing: BrowserError(code, message))
                    } else { continuation.resume(throwing: error) }
                }
                else { continuation.resume(returning: result ?? NSNull()) }
            }
        }
    }

    func load(_ url: URL) {
        navigationError = nil; certificateError = nil; tlsChallenge = [:]; terminated = false
        let start = monotonicNow()
        if let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) {
            trackNavigation(navigation, start: start)
        }
    }

    private func trackNavigation(_ navigation: WKNavigation, start: UInt64) {
        let key = ObjectIdentifier(navigation)
        guard navigationSpans[key] == nil else { return }
        navigationSequence += 1
        navigationSpans[key] = NavigationSpan(timing: operationTiming,
            token: operationTiming?.begin("navigation", from: start), sequence: navigationSequence)
    }

    private func finishNavigation(_ navigation: WKNavigation?) {
        guard let navigation, let span = navigationSpans.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
        if let token = span.token { span.timing?.finish(token) }
        completedNavigationSequence = max(completedNavigationSequence, span.sequence)
    }

    func waitForNavigation(after sequence: Int, timeout: Int) async throws {
        let start = monotonicNow()
        repeat {
            if let navigationError { throw navigationError }
            if navigationSequence > sequence, completedNavigationSequence == navigationSequence { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while milliseconds(from: start) < Double(timeout)
        throw BrowserError("timeout", "点击后等待新导航完成超时（\(timeout) ms）；同页锚点或 SPA 跳转不会触发完整导航")
    }

    func wait(selector: String?, timeout: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        repeat {
            if let navigationError { throw navigationError }
            if let selector {
                let script = "(() => { try { return !!window.__agentWebKit.resolve(\(try quoteJS(selector))); } catch(e) { return false; } })()"
                if (try await runJS(script) as? Bool) == true { return }
            } else if !webView.isLoading, (try await runJS("document.readyState") as? String) == "complete" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        throw BrowserError("timeout", "等待\(selector ?? "页面加载")超时（\(timeout) ms）")
    }

    func screenshot(path: String) async throws -> [String: Any] {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let timing = operationTiming
        let start = monotonicNow()
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                timing?.record("takeSnapshot", from: start)
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: BrowserError("snapshot_failed", "WebKit 未返回图像")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError("png_failed", "无法编码 PNG")
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        return ["path": url.path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "requiresForeground": false]
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationError = nil
        if let navigation { trackNavigation(navigation, start: monotonicNow()) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(navigation); changed?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(navigation); navigationError = certificateError ?? error; changed?()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(navigation); navigationError = certificateError ?? error; changed?()
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let tls else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host
        if tls.ignoreCertificateErrors == true {
            tlsChallenge = ["host": host, "policy": "insecure", "accepted": true, "certificateErrorsIgnored": true]
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        guard let certificate = tls.certificate,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
            certificateError = BrowserError("certificate_rejected", "无法为 \(host) 配置 Space CA")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Keep WebKit's SSL/hostname policies. Only add this Space's anchor to this trust object.
        // Security requires this call to originate on the callback queue (the main queue here).
        let status = SecTrustEvaluateAsyncWithError(trust, .main) { [weak self] trust, accepted, error in
            let message = error.map { CFErrorCopyDescription($0) as String } ?? ""
            let details = accepted ? "" : String(describing: SecTrustCopyResult(trust))
            Task { @MainActor in
                self?.tlsChallenge = ["host": host, "policy": "custom-ca", "accepted": accepted, "error": message, "details": details]
                if accepted { completionHandler(.useCredential, URLCredential(trust: trust)) }
                else {
                    self?.certificateError = BrowserError("certificate_rejected", "\(host): \(message)")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }
        if status != errSecSuccess {
            certificateError = BrowserError("certificate_rejected", "\(host): SecTrust evaluation failed (\(status))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated = true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        // Do not launch external applications or create windows from page content.
        decisionHandler(["http", "https", "about"].contains(scheme) && navigationAction.targetFrame != nil ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { suppressedDialogs += 1; completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { suppressedDialogs += 1; completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { suppressedDialogs += 1; completionHandler(nil) }
}

@MainActor
final class Space {
    var record: SpaceRecord
    let store: WKWebsiteDataStore
    var tabs: [Tab] = []
    var busy = false
    init(_ record: SpaceRecord) throws {
        self.record = record
        let configurations: [ProxyConfiguration]
        if record.proxy == "direct" {
            try requireDirectAvailable()
            configurations = []
        } else {
            guard let url = URL(string: record.proxy), url.scheme == "http", url.host == "127.0.0.1", url.port == 8899,
                  url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else {
                throw BrowserError("invalid_proxy", "仅支持 direct 或 http://127.0.0.1:8899")
            }
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 8899))
            proxy.allowFailover = false
            proxy.matchDomains = []
            proxy.excludedDomains = []
            configurations = [proxy]
        }
        store = WKWebsiteDataStore(forIdentifier: record.id)
        store.proxyConfigurations = configurations
        tabs = record.tabs.map { Tab(record: $0, store: store, tls: record.tls) }
    }
    var summary: [String: Any] {
        ["id": record.id.uuidString, "name": record.name, "proxy": record.proxy, "persistent": store.isPersistent,
         "dataStoreId": store.identifier?.uuidString ?? "", "defaultTabId": record.defaultTab.uuidString,
         "tabs": tabs.map(\.state), "busy": busy, "network": networkState,
         "tls": record.tls?.summary ?? TLSConfiguration.systemSummary]
    }
    var networkState: [String: Any] {
        ["configuredProxy": record.proxy, "routeVerified": false,
         "limitation": record.proxy == "direct"
            ? "System proxy checked per command; cannot bypass VPN/content filters or guarantee routing after system settings change."
            : "On tested macOS 27.0.1 loopback requests bypass this proxy, including localhost and 127.0.0.1. Configuration success is not route verification."]
    }
}

@MainActor
final class BrowserModel {
    var spaces: [Space] = []
    var records: [SpaceRecord] = []
    var changed: (() -> Void)?
    var willRemove: ((Space) -> Void)?
    private let file: URL
    private var lockFD: Int32 = -1
    var shuttingDown = false

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        file = directory.appendingPathComponent("spaces.json")
        lockFD = Darwin.open(directory.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw BrowserError("already_running", "此数据目录已有运行中的应用") }
        if FileManager.default.fileExists(atPath: file.path) { records = try JSONDecoder().decode([SpaceRecord].self, from: Data(contentsOf: file)) }
        for record in records where !record.deleting { spaces.append(try Space(record)) }
        for space in spaces { bind(space) }
    }

    func restore() async throws {
        for record in records.filter(\.deleting) {
            try await removeStore(record.id)
            records.removeAll { $0.id == record.id }; try persist()
        }
        for space in spaces {
            for (tab, record) in zip(space.tabs, space.record.tabs) {
                if record.url != "about:blank", let url = URL(string: record.url) { tab.load(url) }
            }
        }
        changed?()
    }

    func persist() throws {
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    private func bind(_ space: Space) {
        for tab in space.tabs {
            tab.changed = { [weak self, weak space] in
                guard let self, let space, !self.shuttingDown else { return }
                do { try self.save(space) } catch { fputs("Persistence error: \(error)\n", stderr) }
                self.changed?()
            }
        }
    }

    func save(_ space: Space) throws {
        space.record.tabs = space.tabs.map { TabRecord(id: $0.id, url: $0.webView.url?.absoluteString ?? "about:blank") }
        if let index = records.firstIndex(where: { $0.id == space.record.id }) { records[index] = space.record }
        try persist()
    }

    private func removeStore(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
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

    func handle(_ request: Request) async -> [String: Any] {
        let timing = RequestTiming()
        var response: [String: Any]
        do { response = ["ok": true, "result": try await execute(request, timing: timing)] }
        catch { response = failure(error) }
        response["timing"] = timing.summary
        return response
    }

    private func execute(_ r: Request, timing: RequestTiming) async throws -> Any {
        guard !shuttingDown else { throw BrowserError("shutting_down", "应用正在退出") }
        let command = r.command
        if command != "click", r.options["wait-for-navigation"] != nil {
            throw BrowserError("invalid_arguments", "--wait-for-navigation 只能用于 click")
        }
        if command != "space.create", r.options["ca-cert"] != nil || r.options["ignore-certificate-errors"] != nil {
            throw BrowserError("invalid_arguments", "证书策略只能在 space create 时配置")
        }
        func arg(_ index: Int) throws -> String {
            guard r.args.indices.contains(index) else { throw BrowserError("invalid_arguments", "缺少参数；browser help 查看用法") }
            return r.args[index]
        }
        let arities: [String: ClosedRange<Int>] = ["status":0...0,"shutdown":0...0,"space.list":0...0,"space.create":1...1,"space.info":1...1,"space.delete":1...1,"tab.list":0...0,"tab.new":0...1,"tab.close":1...1,"open":1...1,"snapshot":0...0,"state":0...0,"evaluate":1...1,"click":1...1,"fill":2...2,"screenshot":0...0,"wait":0...1]
        guard let arity = arities[command], arity.contains(r.args.count) else { throw BrowserError("invalid_arguments", "未知命令或参数数量不正确：\(command)") }
        if command == "status" {
            return ["pid": ProcessInfo.processInfo.processIdentifier, "spaces": spaces.count,
                    "systemProxy": systemProxyState(), "frontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                    "capabilities": ["input":"dom-synthetic", "snapshot":"main-frame", "screenshot":"viewport", "foregroundRequired":false],
                    "directPolicy":"reject-enabled-system-proxy; no VPN/content-filter bypass guarantee"] as [String: Any]
        }
        if command == "shutdown" {
            guard !spaces.contains(where: \.busy) else { throw BrowserError("space_busy", "仍有操作执行中") }
            for space in spaces { try save(space) }
            shuttingDown = true
            // Give the reply time to reach the client; terminate through AppKit to release WebKit cleanly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return ["shutdown": true]
        }
        if command == "space.list" { return spaces.map(\.summary) }
        if command == "space.create" {
            let name = try arg(0)
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw BrowserError("invalid_name", "名称需为字母开头的 1–64 位字母、数字、下划线或连字符") }
            guard !records.contains(where: { $0.name == name }) else { throw BrowserError("space_exists", "Space 已存在") }
            guard let proxy = r.options["proxy"] else { throw BrowserError("proxy_required", "创建 Space 必须显式指定 --proxy") }
            guard r.options["ca-cert"] == nil || r.options["ignore-certificate-errors"] == nil else {
                throw BrowserError("invalid_arguments", "--ca-cert 和 --ignore-certificate-errors 不能同时使用")
            }
            let tab = TabRecord(id: UUID(), url: "about:blank")
            let tls = r.options["ignore-certificate-errors"] == "true" ? TLSConfiguration.insecure : try r.options["ca-cert"].map { try TLSConfiguration(path: $0) }
            let record = SpaceRecord(id: UUID(), name: name, proxy: proxy, defaultTab: tab.id, tabs: [tab], tls: tls)
            let space = try Space(record)
            records.append(record)
            do { try persist() } catch { records.removeLast(); throw error }
            spaces.append(space); bind(space); changed?()
            return space.summary
        }
        let target = command.hasPrefix("space.") ? try arg(0) : r.options["space"]
        guard let target else { throw BrowserError("space_required", "所有页面操作必须指定 --space") }
        guard let id = spaces.first(where: { $0.record.name == target || $0.record.id.uuidString.lowercased() == target.lowercased() })?.record.id else {
            throw BrowserError("space_not_found", "Space 不存在：\(target)")
        }
        if command == "space.delete" {
            // Avoid retaining the Space/DataStore across the asynchronous removal API.
            guard spaces.first(where: { $0.record.id == id })?.busy == false else { throw BrowserError("space_busy", "Space 正在操作中") }
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].deleting = true }
            try persist(); detach(id); changed?()
            // Let AppKit's autorelease pool release the detached WKWebViews before removing their store.
            try await Task.sleep(nanoseconds: 100_000_000)
            try await removeStore(id)
            records.removeAll { $0.id == id }; try persist()
            return ["deleted": true, "spaceId": id.uuidString, "websiteDataRemoved": true]
        }
        guard let space = spaces.first(where: { $0.record.id == id }) else { throw BrowserError("space_not_found", "Space 已删除") }
        if command == "space.info" { return space.summary }
        guard !space.busy else { throw BrowserError("space_busy", "同一 Space 已有操作；请在该 Agent 内顺序执行") }
        space.busy = true; defer { space.busy = false }
        if space.record.proxy == "direct" { try requireDirectAvailable() }
        let timeout: Int
        if let raw = r.options["timeout"] {
            guard let value = Int(raw), (1...60000).contains(value) else { throw BrowserError("invalid_timeout", "timeout 必须为 1–60000 ms") }; timeout = value
        } else { timeout = 15000 }
        if command == "tab.list" { return space.tabs.map(\.state) }
        if command == "tab.new" {
            let url = try validateURL(r.args.first ?? "about:blank")
            let tab = Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: space.store, tls: space.record.tls)
            tab.operationTiming = timing; defer { tab.operationTiming = nil }
            space.tabs.append(tab); bind(space); try save(space); changed?()
            tab.load(url); try await tab.wait(selector: nil, timeout: timeout); try save(space)
            return tab.state
        }
        if command == "tab.close" {
            let tabID = try arg(0)
            guard let index = space.tabs.firstIndex(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else { throw BrowserError("tab_not_found", "标签页不存在") }
            guard space.tabs.count > 1 else { throw BrowserError("last_tab", "不能关闭最后一个标签页；可删除 Space") }
            let tab = space.tabs.remove(at: index); tab.close()
            if space.record.defaultTab == tab.id { space.record.defaultTab = space.tabs[0].id }
            try save(space); changed?(); return ["closed": tabID, "defaultTabId": space.record.defaultTab.uuidString]
        }
        let tabID = r.options["tab"] ?? space.record.defaultTab.uuidString
        guard let tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else { throw BrowserError("tab_not_found", "Space 中不存在该标签页") }
        tab.operationTiming = timing; defer { tab.operationTiming = nil }
        var value: Any = NSNull()
        switch command {
        case "open":
            let url = try validateURL(arg(0)); tab.load(url)
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "state": break
        case "snapshot": value = try await tab.runJS("window.__agentWebKit.snapshot()")
        case "evaluate": value = try await tab.runJS(arg(0))
        case "click", "fill":
            let before = tab.navigationSequence
            value = try await tab.runJS("window.__agentWebKit.act(\(try quoteJS(command)),\(try quoteJS(arg(0))),\(try quoteJS(command == "fill" ? arg(1) : "")))")
            if r.options["wait-for-navigation"] == "true" { try await tab.waitForNavigation(after: before, timeout: timeout) }
        case "wait": try await tab.wait(selector: r.args.first, timeout: timeout)
        case "screenshot":
            guard let path = r.options["out"] else { throw BrowserError("invalid_arguments", "截图需要 --out PATH") }
            value = try await tab.screenshot(path: path)
        default: throw BrowserError("unknown_command", "未知命令")
        }
        return ["spaceId": id.uuidString, "space": space.record.name, "proxy": space.record.proxy, "network": space.networkState, "page": tab.state, "value": value]
    }

    private func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") && url.host != nil || raw == "about:blank" else {
            throw BrowserError("invalid_url", "仅支持完整 http(s) URL 或 about:blank")
        }
        return url
    }
}
