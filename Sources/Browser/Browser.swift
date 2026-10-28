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
        throw BrowserError("direct_system_proxy_conflict", "此 Direct Space 已暂停：系统代理已启用（\(active.joined(separator: ","))）。关闭系统代理后重新加载即可恢复；Cookie、Tab ID 和 URL 保留。公开 WebKit API 无强制直连开关")
    }
}

@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    let backingWindow: NSPanel
    let diagnostics: DiagnosticLog
    let dialogs = DialogStore()
    var navigationError: Error?
    var changed: (() -> Void)?
    var statusChanged: (() -> Void)?
    var networkCheck: (() throws -> Void)?
    var createPopup: ((WKWebViewConfiguration, URL) throws -> Tab)?
    var closeRequested: (() -> Void)?
    var openerTabID: UUID?
    var lastNavigationRejection: BrowserError?
    private(set) var popupSequence = 0
    private var lastPopupID: UUID?
    var suppressedDialogs = 0
    var terminated = false
    var unresponsive = false
    private(set) var closed = false
    private(set) var persistedURL: String
    var deadline: UInt64?
    private var observations: [NSKeyValueObservation] = []
    private var pending: [UUID: (Error) -> Void] = [:]
    let tls: TLSConfiguration?
    var tlsChallenge: [String: Any] = [:]
    var certificateError: BrowserError?
    var operationTiming: RequestTiming?
    private struct NavigationSpan {
        let start: UInt64
        let timing: RequestTiming?
        let token: Int?
        let sequence: Int
    }
    private var navigationSpans: [ObjectIdentifier: NavigationSpan] = [:]
    private(set) var navigationSequence = 0
    private var completedNavigationSequence = 0
    private var navigationPending = false
    private var navigationStartedAt: UInt64?

    init(record: TabRecord, store: WKWebsiteDataStore, tls: TLSConfiguration?, configuration supplied: WKWebViewConfiguration? = nil, diagnostics: DiagnosticLog? = nil) {
        id = record.id
        persistedURL = record.url
        self.tls = tls
        self.diagnostics = diagnostics ?? DiagnosticLog()
        let configuration = supplied ?? WKWebViewConfiguration()
        if supplied == nil { configuration.websiteDataStore = store }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if !configuration.userContentController.userScripts.contains(where: { $0.source == DOM.bootstrap }) {
            configuration.userContentController.addUserScript(WKUserScript(source: DOM.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DOM.world))
        }
        if !configuration.userContentController.userScripts.contains(where: { $0.source == DiagnosticScript.source }) {
            configuration.userContentController.add(DiagnosticRouter.shared, contentWorld: .page, name: DiagnosticScript.name)
            configuration.userContentController.addUserScript(WKUserScript(source: DiagnosticScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        webView.isInspectable = false
        backingWindow = NSPanel(contentRect: webView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        dialogs.automaticallyDismissed = { [weak self] in self?.suppressedDialogs += 1 }
        DiagnosticRouter.shared.logs.setObject(self.diagnostics, forKey: webView)
        backingWindow.isReleasedWhenClosed = false
        backingWindow.contentView = webView
        webView.navigationDelegate = self; webView.uiDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged?() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged?() }
            },
            webView.observe(\.title) { [weak self] _, _ in
                Task { @MainActor in self?.changed?() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, !self.webView.isLoading, !self.navigationPending,
                          self.navigationSequence == self.completedNavigationSequence,
                          let url = self.webView.url else { return }
                    self.persistedURL = url.absoluteString
                    self.changed?()
                }
            }
        ]
    }

    func park() {
        guard !closed else { return }
        webView.isHidden = false
        webView.removeFromSuperview()
        backingWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        backingWindow.orderOut(nil)
    }

    func close() {
        closed = true
        dialogs.cancelAll(code: "tab_closed")
        webView.isInspectable = false
        diagnostics.setDetail(false)
        DiagnosticRouter.shared.logs.removeObject(forKey: webView)
        failPending(BrowserError("tab_closed", "标签页已关闭"))
        observations.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview(); backingWindow.contentView = nil; backingWindow.close()
        changed = nil
        statusChanged = nil
        networkCheck = nil
        createPopup = nil; closeRequested = nil
        navigationSpans.removeAll()
    }

    func disableDiagnosticDetails() {
        diagnostics.setDetail(false)
        // Host filtering and erasure are immediate, even if a hung page cannot acknowledge this.
        webView.evaluateJavaScript("window.__agentWebKitDiagnosticMode?.(null)", completionHandler: nil)
    }

    var state: [String: Any] {
        ["tabId": id.uuidString, "url": persistedURL, "title": webView.title ?? "",
         "loading": webView.isLoading, "webContentTerminated": terminated, "suppressedDialogs": suppressedDialogs,
         "pendingDialogs": dialogs.pendingCount,
         "unresponsive": unresponsive, "lastError": navigationError.map { failure($0)["error"]! } ?? NSNull(),
         "requiresForeground": false, "tls": tls?.summary ?? TLSConfiguration.systemSummary,
         "lastTLSChallenge": tlsChallenge, "openerTabId": openerTabID?.uuidString as Any? ?? NSNull(),
         "lastNavigationRejection": lastNavigationRejection.map { failure($0)["error"]! } ?? NSNull(),
         "popupPolicy": "same-space tabs; window geometry/toolbars ignored; synthetic clicks do not guarantee user activation"]
    }

    private func failPending(_ error: Error) {
        let callbacks = Array(pending.values)
        pending.removeAll()
        callbacks.forEach { $0(error) }
    }

    private func perform<Value>(_ operation: String, body: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard !closed else { throw BrowserError("tab_closed", "标签页已关闭") }
        guard !terminated else { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请重新 open") }
        guard !unresponsive else { throw BrowserError("web_content_unresponsive", "上次 WebKit 调用超时，请先 reload 恢复标签页") }
        let now = monotonicNow()
        let remaining = deadline.map { Double($0 > now ? $0 - now : 0) / 1_000_000 } ?? 15000
        guard remaining > 0 else { throw BrowserError("timeout", "命令执行超时") }
        let timing = operationTiming
        let token = timing?.begin(operation, from: monotonicNow())
        let id = UUID()
        defer { pending[id] = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let call = PendingOperation(continuation)
            pending[id] = { call.finish(.failure($0)) }
            call.arm(milliseconds: remaining) { [weak self] in
                if let self {
                    let waitingForDialog = self.dialogs.hasPending || self.dialogs.expired(since: now)
                    self.dialogs.cancelAll(code: "dialog_expired")
                    self.unresponsive = !waitingForDialog
                }
                self?.diagnostics.native("operation-timeout", url: self?.webView.url,
                    error: BrowserError("timeout", ""), duration: milliseconds(from: now))
                self?.changed?()
            }
            body { result in
                if let token { timing?.finish(token) }
                call.finish(result)
            }
        }
    }

    func runJS(_ script: String, awaitPromise: Bool = false, world: WKContentWorld? = nil) async throws -> Any {
        let world = world ?? .page
        return try await perform(awaitPromise ? "callAsyncJavaScript" : "evaluateJavaScript") { complete in
            let callback: (Any?, Error?) -> Void = { result, error in
                if let error {
                    let nsError = error as NSError
                    if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
                        let codes = ["stale_ref", "selector_count", "invalid_selector", "unsupported_context", "element_not_actionable", "element_readonly", "unsupported_fill_type", "element_not_editable", "invalid_option"]
                        let code = codes.first { message.contains($0) } ?? "javascript_error"
                        complete(.failure(BrowserError(code, message)))
                    } else { complete(.failure(error)) }
                }
                else { complete(.success(result ?? NSNull())) }
            }
            if awaitPromise {
                webView.callAsyncJavaScript("return await (0, eval)(source)", arguments: ["source": script], in: nil, in: world) { result in
                    switch result {
                    case .success(let value): callback(value, nil)
                    case .failure(let error): callback(nil, error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script, in: nil, in: world) { result in
                    switch result {
                    case .success(let value): callback(value, nil)
                    case .failure(let error): callback(nil, error)
                    }
                }
            }
        }
    }

    func load(_ url: URL) {
        dialogs.cancelAll(code: "dialog_cancelled")
        persistedURL = url.absoluteString
        navigationError = nil; lastNavigationRejection = nil; certificateError = nil; tlsChallenge = [:]; terminated = false
        // A repeated failed load can return nil and still deliver a terminal delegate callback.
        // Never treat the previous document's readyState as completion of this request.
        navigationPending = true
        let start = monotonicNow()
        navigationStartedAt = start
        if let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) {
            trackNavigation(navigation, start: start)
        }
        changed?()
    }

    private func trackNavigation(_ navigation: WKNavigation, start: UInt64) {
        let key = ObjectIdentifier(navigation)
        guard navigationSpans[key] == nil else { return }
        navigationSequence += 1
        navigationSpans[key] = NavigationSpan(start: start, timing: operationTiming,
            token: operationTiming?.begin("navigation", from: start), sequence: navigationSequence)
    }

    @discardableResult
    private func finishNavigation(_ navigation: WKNavigation?) -> Bool {
        let span = navigation.flatMap { navigationSpans.removeValue(forKey: ObjectIdentifier($0)) }
        if let token = span?.token { span?.timing?.finish(token) }
        let latest = span.map { $0.sequence == navigationSequence } ?? navigationPending
        if latest {
            completedNavigationSequence = navigationSequence
            navigationPending = false
        }
        return latest
    }

    func waitForNavigation(after sequence: Int, timeout: Int) async throws {
        let start = monotonicNow()
        repeat {
            if terminated { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请 reload") }
            if let navigationError { throw navigationError }
            if let lastNavigationRejection { throw lastNavigationRejection }
            if navigationSequence > sequence, !navigationPending, completedNavigationSequence == navigationSequence { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while milliseconds(from: start) < Double(timeout) && (deadline.map { monotonicNow() < $0 } ?? true)
        throw BrowserError("timeout", "点击后等待新导航完成超时（\(timeout) ms）；同页锚点或 SPA 跳转不会触发完整导航")
    }

    func waitForPopup(after sequence: Int, timeout: Int) async throws -> String {
        let start = monotonicNow()
        repeat {
            if closed { throw BrowserError("tab_closed", "发起弹窗的标签页已关闭") }
            if let lastNavigationRejection { throw lastNavigationRejection }
            if popupSequence > sequence, let lastPopupID { return lastPopupID.uuidString }
            try await Task.sleep(nanoseconds: 25_000_000)
        } while milliseconds(from: start) < Double(timeout) && (deadline.map { monotonicNow() < $0 } ?? true)
        throw BrowserError("popup_not_opened", "期限内未观察到新 Tab；DOM 合成点击不是可信用户激活，网站或 WebKit 可能拒绝弹窗。请核对页面状态，必要时手动点击；不会自动重试")
    }

    func wait(selector: String?, timeout: Int, state: String = "visible", text: String? = nil, url: String? = nil) async throws {
        let start = monotonicNow()
        repeat {
            if let navigationError { throw navigationError }
            if let certificateError { throw certificateError }
            if let url {
                if (try await runJS("location.href === \(try quoteJS(url))", world: DOM.world) as? Bool) == true { return }
            } else if selector != nil || text != nil {
                let target = try selector.map { try quoteJS($0) } ?? "null"
                let expected = try text.map { try quoteJS($0) } ?? "null"
                let script = "Boolean(window.__agentWebKit && window.__agentWebKit.matchesCondition(\(target),\(try quoteJS(state)),\(expected)))"
                if (try await runJS(script, world: DOM.world) as? Bool) == true { return }
            } else if !webView.isLoading, !navigationPending, navigationSequence == completedNavigationSequence,
                      (try await runJS("document.readyState", world: DOM.world) as? String) == "complete" {
                if let navigationError { throw navigationError }
                if let certificateError { throw certificateError }
                if !webView.isLoading, !navigationPending, navigationSequence == completedNavigationSequence { return }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while milliseconds(from: start) < Double(timeout)
        diagnostics.native(navigationPending ? "navigation-timeout" : "condition-timeout", url: URL(string: persistedURL),
                           error: BrowserError("timeout", ""), duration: milliseconds(from: start))
        throw BrowserError("timeout", "等待页面条件超时（\(timeout) ms）")
    }

    func screenshot(path: String) async throws -> [String: Any] {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image: NSImage = try await perform("takeSnapshot") { complete in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { complete(.failure(error)) }
                else if let image { complete(.success(image)) }
                else { complete(.failure(BrowserError("snapshot_failed", "WebKit 未返回图像"))) }
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
        dialogs.cancelAll(code: "dialog_cancelled")
        diagnostics.beginNavigation()
        navigationError = nil
        certificateError = nil
        if !navigationPending { navigationStartedAt = monotonicNow() }
        navigationPending = true
        if let navigation { trackNavigation(navigation, start: monotonicNow()) }
        changed?()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { persistedURL = url.absoluteString }
        changed?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigation("navigation-finished", navigation: navigation)
        if finishNavigation(navigation), let url = webView.url { persistedURL = url.absoluteString }
        changed?()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failNavigation(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failNavigation(navigation, error: error)
    }
    private func failNavigation(_ navigation: WKNavigation?, error: Error) {
        // Unknown cancelled callbacks may belong to a superseded navigation.
        if navigation.flatMap({ navigationSpans[ObjectIdentifier($0)] }) == nil,
           (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        recordNavigation("navigation-failed", navigation: navigation, error: error)
        let latest = finishNavigation(navigation)
        // A replacement load cancels the previous request. Its late failure must not poison the new one.
        if latest { navigationError = certificateError ?? error; changed?() }
    }
    private func recordNavigation(_ kind: String, navigation: WKNavigation?, error: Error? = nil) {
        let span = navigation.flatMap { navigationSpans[ObjectIdentifier($0)] }
        let start = span?.start ?? navigationStartedAt
        let latest = span.map { $0.sequence == navigationSequence } ?? navigationPending
        let failedURL = (error as NSError?)?.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        // A failed provisional load can leave webView.url pointing at the previous document.
        let url = error == nil ? webView.url : failedURL ?? URL(string: persistedURL)
        diagnostics.native(kind, url: url, error: error, cause: latest ? certificateError : nil,
                           duration: start.map { milliseconds(from: $0) })
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            diagnostics.native("navigation-response", url: response.url, status: response.statusCode)
        }
        decisionHandler(.allow)
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
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated = true
        dialogs.cancelAll(code: "web_content_terminated")
        let error = BrowserError("web_content_terminated", "WebContent 进程已退出；reload 可恢复页面，未提交的表单不会保留")
        navigationError = error
        diagnostics.native("web-content-terminated", url: webView.url, error: error)
        failPending(error)
        changed?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        do { try networkCheck?() }
        catch {
            navigationError = error
            diagnostics.native("navigation-blocked", url: navigationAction.request.url, error: error)
            changed?(); decisionHandler(.cancel); return
        }
        guard let url = navigationAction.request.url, Self.supports(url) else {
            rejectNavigation(BrowserError("unsupported_navigation", "仅支持 http(s) 与 about:blank；已拒绝外部应用或不支持的 URL scheme"))
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    private static func supports(_ url: URL) -> Bool {
        (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) || url.absoluteString == "about:blank"
    }
    private func rejectNavigation(_ error: BrowserError) {
        diagnostics.native("navigation-blocked", url: webView.url, error: error)
        lastNavigationRejection = error; changed?()
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        do {
            guard !closed, let url = navigationAction.request.url, Self.supports(url), let createPopup else {
                throw BrowserError("unsupported_navigation", "新窗口只支持 http(s) 或 about:blank；不会启动外部应用")
            }
            try networkCheck?()
            let popup = try createPopup(configuration, url)
            popupSequence += 1; lastPopupID = popup.id
            return popup.webView // WebKit loads the request and preserves the opener relationship.
        } catch {
            rejectNavigation((error as? BrowserError) ?? BrowserError("popup_failed", error.localizedDescription))
            return nil
        }
    }
    func webViewDidClose(_ webView: WKWebView) {
        closeRequested?()
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialogs.present(kind: "alert", message: message, origin: DiagnosticLog.origin(frame.request.url), mainFrame: frame.isMainFrame, deadline: deadline) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialogs.present(kind: "confirm", message: message, origin: DiagnosticLog.origin(frame.request.url), mainFrame: frame.isMainFrame, deadline: deadline) { accepted, _ in completionHandler(accepted) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        dialogs.present(kind: "prompt", message: prompt, defaultText: defaultText, origin: DiagnosticLog.origin(frame.request.url), mainFrame: frame.isMainFrame, deadline: deadline) { accepted, text in completionHandler(accepted ? text : nil) }
    }
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
        let error = networkError
        return ["configuredProxy": record.proxy, "routeVerified": false,
         "blocked": error != nil, "recoverable": error != nil,
         "error": error.map { failure($0)["error"]! } ?? NSNull(),
         "limitation": record.proxy == "direct"
            ? "System proxy checked on restore, commands and navigation; already running page requests may follow changed system settings. Cannot bypass VPN/content filters. Disable system proxy then reload to resume."
            : "On tested macOS 27.0.1 loopback requests bypass this proxy, including localhost and 127.0.0.1. Configuration success is not route verification."]
    }
    var networkError: BrowserError? {
        guard record.proxy == "direct" else { return nil }
        do { try requireDirectAvailable(); return nil }
        catch { return error as? BrowserError }
    }
}

@MainActor
final class BrowserModel {
    var spaces: [Space] = []
    var records: [SpaceRecord] = []
    var changed: (() -> Void)?
    var willRemove: ((Space) -> Void)?
    var observerState: (() -> [String: Any])?
    private let file: URL
    var storagePath: String { file.deletingLastPathComponent().path }
    private var lockFD: Int32 = -1
    var shuttingDown = false
    private(set) var restoring = true

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
        // Static removal can crash in WebKit's WebsiteDataStoreIO run loop when
        // no store has initialized WebKit yet (e.g. only tombstones remain).
        // Use an ephemeral store; never open the user's default website store.
        let cleanupBootstrap = records.contains(where: \.deleting) ? WKWebsiteDataStore.nonPersistent() : nil
        defer { withExtendedLifetime(cleanupBootstrap) {} }
        for record in records.filter(\.deleting) {
            if try await removeStore(record.id) {
                records.removeAll { $0.id == record.id }; try persist()
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
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    private func bind(_ space: Space) {
        for tab in space.tabs {
            tab.createPopup = { [weak self, weak space, weak tab] configuration, url in
                guard let self, let space, let tab, !self.shuttingDown,
                      self.spaces.contains(where: { $0 === space }), !tab.closed else {
                    throw BrowserError("tab_closed", "弹窗所属 Space 或标签页已关闭")
                }
                guard configuration.websiteDataStore === space.store else {
                    throw BrowserError("popup_store_mismatch", "拒绝使用其他 Space 的网站数据创建弹窗")
                }
                let popup = Tab(record: TabRecord(id: UUID(), url: url.absoluteString), store: space.store,
                                tls: space.record.tls, configuration: configuration)
                popup.openerTabID = tab.id
                space.tabs.append(popup); self.bind(space)
                do { try self.save(space) }
                catch { space.tabs.removeAll { $0 === popup }; popup.close(); throw error }
                self.changed?()
                return popup
            }
            tab.closeRequested = { [weak self, weak space, weak tab] in
                guard let self, let space, let tab, !tab.closed,
                      self.spaces.contains(where: { $0 === space }) else { return }
                space.tabs.removeAll { $0 === tab }; tab.close()
                if space.tabs.isEmpty {
                    space.tabs.append(Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: space.store, tls: space.record.tls))
                    self.bind(space)
                }
                if space.record.defaultTab == tab.id { space.record.defaultTab = space.tabs[0].id }
                do { try self.save(space) } catch { fputs("Persistence error: \(error)\n", stderr) }
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
        space.record.tabs = space.tabs.map { TabRecord(id: $0.id, url: $0.persistedURL) }
        if let index = records.firstIndex(where: { $0.id == space.record.id }) { records[index] = space.record }
        try persist()
    }

    private func removeStore(_ id: UUID) async throws -> Bool {
        do { try await removeStoreOnce(id); return true }
        catch {
            // WebKit may retain an idle network session after a stalled view is replaced.
            // Clear and verify the website data through the public API; keep the tombstone
            // if the empty store container cannot yet be removed in this process.
            try await clearStoreContents(id)
            for delay in [100, 200, 400] {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                do { try await removeStoreOnce(id); return true } catch { continue }
            }
            return false
        }
    }

    private func clearStoreContents(_ id: UUID) async throws {
        let store = WKWebsiteDataStore(forIdentifier: id)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = PendingOperation(continuation)
            operation.arm(milliseconds: 5000, error: BrowserError("data_removal_timeout", "网站数据清理超时；已保留删除标记，下次启动会重试"), onTimeout: {})
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                store.fetchDataRecords(ofTypes: types) { records in
                    if records.isEmpty { operation.finish(.success(())) }
                    else { operation.finish(.failure(BrowserError("data_removal_failed", "网站数据仍存在；已保留删除标记，下次启动会重试"))) }
                }
            }
        }
    }

    private func removeStoreOnce(_ id: UUID) async throws {
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
            guard r.args.indices.contains(index) else { throw BrowserError("invalid_arguments", "缺少参数；browser help 查看用法") }
            return r.args[index]
        }
        if command == "help" { return try CLIContract.help(r.args) }
        if command == "capabilities" { return CLIContract.capabilities }
        if command == "version" { return ["version": productVersion] }
        if command == "status" {
            return ["version": productVersion, "pid": ProcessInfo.processInfo.processIdentifier, "spaces": spaces.count,
                    "ready": !restoring,
                    "observer": observerState?() ?? [:],
                    "pendingStoreCleanup": records.filter(\.deleting).count,
                    "blockedSpaces": spaces.filter { $0.networkError != nil }.map { $0.record.id.uuidString },
                    "systemProxy": systemProxyState(), "frontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                    "capabilities": ["input":"dom-synthetic", "snapshot":"same-origin-frames-and-open-shadow-roots", "screenshot":"viewport", "foregroundRequired":false],
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
            guard !records.contains(where: { $0.name == name && !$0.deleting }) else { throw BrowserError("space_exists", "Space 已存在") }
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
        let pendingID = command == "space.delete" ? records.first(where: { $0.deleting && ($0.name == target || $0.id.uuidString.lowercased() == target.lowercased()) })?.id : nil
        guard let id = spaces.first(where: { $0.record.name == target || $0.record.id.uuidString.lowercased() == target.lowercased() })?.record.id ?? pendingID else {
            throw BrowserError("space_not_found", "Space 不存在：\(target)")
        }
        if command == "space.delete" {
            // Avoid retaining the Space/DataStore across the asynchronous removal API.
            guard spaces.first(where: { $0.record.id == id })?.busy != true else { throw BrowserError("space_busy", "Space 正在操作中") }
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].deleting = true }
            try persist(); detach(id); changed?()
            // Let AppKit's autorelease pool release the detached WKWebViews before removing their store.
            try await Task.sleep(nanoseconds: 100_000_000)
            let removed = try await removeStore(id)
            if removed { records.removeAll { $0.id == id }; try persist() }
            return ["deleted": true, "spaceId": id.uuidString, "websiteDataRemoved": true,
                    "dataStoreRemoved": removed, "cleanupPending": !removed]
        }
        guard let space = spaces.first(where: { $0.record.id == id }) else { throw BrowserError("space_not_found", "Space 已删除") }
        if command == "space.info" { return space.summary }
        if command == "tab.list" { return space.tabs.map(\.state) }
        if command == "state" || command == "diagnostics" || command.hasPrefix("dialog.") {
            let tabID = r.options["tab"] ?? space.record.defaultTab.uuidString
            guard let tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else {
                throw BrowserError("tab_not_found", "Space 中不存在该标签页")
            }
            if command.hasPrefix("dialog.") {
                let value = command == "dialog.list" ? tab.dialogs.snapshot() : try tab.dialogs.respond(id: arg(0), action: arg(1), text: r.options["text"])
                return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "busy": space.busy, "value": value]
            }
            if command == "diagnostics" {
                // Reads and disabling remain available while busy, blocked or hung.
                if let inspectable = r.options["inspectable"] { tab.webView.isInspectable = inspectable == "on" }
                if r.options["detail"] == "off" {
                    tab.disableDiagnosticDetails()
                } else if r.options["detail"] == "on" {
                    guard !space.busy else { throw BrowserError("space_busy", "启用详细诊断需要等待当前操作完成") }
                    space.busy = true
                    tab.operationTiming = timing; tab.deadline = monotonicNow() + 2_000_000_000
                    defer { space.busy = false; tab.operationTiming = nil; tab.deadline = nil }
                    tab.diagnostics.setDetail(true)
                    let generation = tab.diagnostics.detailGeneration!
                    let config: [String: Any] = ["generation": generation, "expiresAtMs": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000]
                    do {
                        let literal = String(decoding: try jsonData(config), as: UTF8.self)
                        let ack = try await tab.runJS("typeof window.__agentWebKitDiagnosticMode === 'function' ? window.__agentWebKitDiagnosticMode(\(literal)) : null") as? String
                        guard ack == generation else { throw BrowserError("diagnostics_unavailable", "当前文档没有可用诊断 hook；请检查页面或显式重新加载") }
                    } catch { tab.disableDiagnosticDetails(); throw error }
                }
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
        guard !space.busy else { throw BrowserError("space_busy", "同一 Space 已有操作；请在该 Agent 内顺序执行") }
        space.busy = true; changed?()
        defer { space.busy = false; changed?() }
        if !["tab.close", "tab.default"].contains(command), let error = space.networkError { throw error }
        let timeout: Int
        if let raw = r.options["timeout"] {
            guard let value = Int(raw), (1...60000).contains(value) else { throw BrowserError("invalid_timeout", "timeout 必须为 1–60000 ms") }; timeout = value
        } else { timeout = 15000 }
        if command == "tab.new" {
            let url = try validateURL(r.args.first ?? "about:blank")
            let tab = Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: space.store, tls: space.record.tls)
            tab.operationTiming = timing; tab.deadline = monotonicNow() + UInt64(timeout) * 1_000_000
            defer { tab.operationTiming = nil; tab.deadline = nil }
            space.tabs.append(tab); bind(space); try save(space); changed?()
            tab.load(url); try await tab.wait(selector: nil, timeout: timeout); try save(space)
            return tab.state
        }
        if command == "tab.default" {
            let tabID = try arg(0)
            guard let tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else { throw BrowserError("tab_not_found", "标签页不存在") }
            space.record.defaultTab = tab.id
            try save(space); changed?()
            return ["defaultTabId": tab.id.uuidString]
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
        guard var tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else { throw BrowserError("tab_not_found", "Space 中不存在该标签页") }
        // Replace a stalled view only on explicit navigation. Never replay an Agent action.
        if ["open", "reload"].contains(command), tab.terminated || tab.unresponsive {
            let replacement = Tab(record: TabRecord(id: tab.id, url: tab.persistedURL), store: space.store, tls: space.record.tls, diagnostics: tab.diagnostics)
            let index = space.tabs.firstIndex(where: { $0 === tab })!
            tab.close(); space.tabs[index] = replacement; tab = replacement
            bind(space); changed?()
        }
        tab.operationTiming = timing; tab.deadline = monotonicNow() + UInt64(timeout) * 1_000_000
        defer { tab.operationTiming = nil; tab.deadline = nil }
        var value: Any = NSNull()
        switch command {
        case "open":
            let url = try validateURL(arg(0)); tab.load(url)
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "reload":
            tab.load(try validateURL(tab.persistedURL))
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "state": break
        case "snapshot": value = try await tab.runJS("window.__agentWebKit.snapshot()", world: DOM.world)
        case "evaluate": value = try await tab.runJS(arg(0), awaitPromise: r.options["await"] == "true")
        case "click", "fill":
            let before = tab.navigationSequence
            let beforePopup = tab.popupSequence
            tab.lastNavigationRejection = nil
            value = try await tab.runJS("window.__agentWebKit.act(\(try quoteJS(command)),\(try quoteJS(arg(0))),\(try quoteJS(command == "fill" ? arg(1) : "")))", world: DOM.world)
            if r.options["wait-for-navigation"] == "true" { try await tab.waitForNavigation(after: before, timeout: timeout) }
            if r.options["wait-for-popup"] == "true" {
                let popupID = try await tab.waitForPopup(after: beforePopup, timeout: timeout)
                var action = value as? [String: Any] ?? [:]
                action["newTabId"] = popupID; value = action
            }
        case "wait":
            try await tab.wait(selector: r.args.first, timeout: timeout, state: r.options["state"] ?? "visible", text: r.options["text"], url: r.options["url"])
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
