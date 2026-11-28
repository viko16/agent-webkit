import AppKit
import WebKit

extension URL {
    var observerDisplayAddress: String {
        var parts = URLComponents(url: self, resolvingAgainstBaseURL: true)
        parts?.user = nil
        parts?.password = nil
        return parts?.string ?? host ?? "目标网址"
    }
}

@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    let backingWindow: NSPanel
    static let defaultViewport = NSSize(width: 1000, height: 700)
    private(set) var fixedViewport: NSSize?
    let diagnostics: DiagnosticLog
    let dialogs = DialogStore()
    let downloads = DownloadStore()
    let fileChooser = FileChooser()
    let frames = FrameStore()
    var inputDocumentEpoch: String?
    var inputFocusConflict: (() -> Bool)?
    private(set) var navigationErrorRevision = 0
    // Space/policy errors have no navigation token; callback failures carry their owning sequence.
    private var navigationErrorSequence: Int?
    var hasFailedNavigation: Bool { navigationErrorSequence != nil }
    var navigationError: Error? {
        didSet {
            failedNavigationTarget = nil
            navigationErrorSequence = nil
            if navigationError != nil { navigationErrorRevision += 1 }
        }
    }
    var changed: (() -> Void)?
    var statusChanged: (() -> Void)?
    var networkCheck: (() throws -> Void)?
    var createPopup: ((WKWebViewConfiguration, URL) throws -> Tab)?
    var closeRequested: (() -> Void)?
    var openerTabID: UUID?
    var hasUnreadPopupNotice = false
    var pendingAddressDraft: String?
    var lastNavigationRejection: BrowserError? {
        didSet { observerDismissedRejection = false }
    }
    var observerDismissedRejection = false
    private(set) var popupSequence = 0
    private var lastPopupID: UUID?
    var suppressedDialogs = 0
    var terminated = false
    var unresponsive = false
    private(set) var closed = false
    private(set) var persistedURL: String
    private(set) var requestedURL: String?
    struct NavigationTarget {
        let url: URL
        let isGET: Bool
    }
    private(set) var failedNavigationTarget: NavigationTarget?
    private var nextMainFrameTarget: NavigationTarget?
    private(set) var committedDocumentURL = "about:blank"
    var deadline: UInt64?
    private var observations: [NSKeyValueObservation] = []
    private var pending: [UUID: (Error) -> Void] = [:]
    let tls: TLSConfiguration?
    var tlsChallenge: [String: Any] = [:]
    var certificateError: BrowserError?
    var operationTiming: RequestTiming?
    private struct NavigationSpan {
        // WebKit can release a cancelled token without a terminal callback.
        // Weak identity lets us reclaim its span without aliasing a reused address.
        weak var navigation: WKNavigation?
        let start: UInt64
        let timing: RequestTiming?
        let token: Int?
        let sequence: Int
        let id: UUID
        var becameDownload = false
    }
    private struct MainDocumentResponse {
        let status: Int
        let url: URL
        let navigationID: UUID
    }
    private struct HistoryResponse {
        weak var item: WKBackForwardListItem?
        let response: MainDocumentResponse
    }
    private struct NavigationResult {
        enum Phase: String {
            case provisional, redirecting, response, committed, finished, failed, download, terminated
            case provisionalFailure = "provisional-failure"
        }
        let id = UUID()
        var target: NavigationTarget?
        var phase = Phase.provisional
        var response: MainDocumentResponse?
        var redirects = 0
    }
    private var navigationResult: NavigationResult?
    private var committedNavigationID: UUID?
    private static let historyResponseLimit = 128
    private var historyResponses: [HistoryResponse] = []
    private let observerStoppedNavigations = NSHashTable<WKNavigation>.weakObjects()
    private var navigationSpans: [ObjectIdentifier: NavigationSpan] = [:]
    private(set) var navigationSequence = 0
    private var completedNavigationSequence = 0
    private var completedNavigationWasDownload = false
    private weak var provisionalNavigation: WKNavigation?
    private(set) var navigationPending = false
    private var navigationStartedAt: UInt64?

    init(record: TabRecord, store: WKWebsiteDataStore, tls: TLSConfiguration?, configuration supplied: WKWebViewConfiguration? = nil, diagnostics: DiagnosticLog? = nil) {
        id = record.id
        persistedURL = record.url
        openerTabID = record.openerTabID
        self.tls = tls
        self.diagnostics = diagnostics ?? DiagnosticLog()
        let configuration = supplied ?? WKWebViewConfiguration()
        if supplied == nil { configuration.websiteDataStore = store }
        else {
            // Keep the supplied popup configuration (including opener/store), with a
            // controller owned by this view so document-start opt-in cannot be inherited.
            configuration.userContentController = WKUserContentController()
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = configuration.userContentController
        controller.add(FrameRouter.shared, contentWorld: DOM.world, name: FrameRouter.name)
        controller.add(DiagnosticRouter.shared, contentWorld: .page, name: DiagnosticScript.name)
        Self.installUserScripts(on: controller, diagnosticSource: DiagnosticScript.source)
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.defaultViewport), configuration: configuration)
        webView.isInspectable = false
        backingWindow = NSPanel(contentRect: webView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        dialogs.automaticallyDismissed = { [weak self] in self?.suppressedDialogs += 1 }
        dialogs.changed = { [weak self] in self?.statusChanged?() }
        downloads.activityChanged = { [weak self] in self?.statusChanged?() }
        DiagnosticRouter.shared.logs.setObject(self.diagnostics, forKey: webView)
        self.diagnostics.captureConfigurationChanged = { [weak self] in self?.updateDiagnosticScript() }
        FrameRouter.shared.stores.setObject(frames, forKey: webView)
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
                    if self.navigationError == nil && self.navigationResult?.phase != .provisionalFailure {
                        self.persistedURL = url.absoluteString
                        self.committedDocumentURL = url.absoluteString
                        self.changed?()
                    } else {
                        // A failed provisional request may leave url pointing at its target.
                        // Read the surviving document before accepting a same-document update.
                        let sequence = self.navigationSequence
                        self.webView.evaluateJavaScript("location.href") { [weak self] value, _ in
                            guard let self, !self.closed, !self.navigationPending,
                                  self.navigationSequence == sequence, let actual = value as? String else { return }
                            self.persistedURL = actual; self.committedDocumentURL = actual
                            self.changed?()
                        }
                    }
                }
            }
        ]
    }

    func park() {
        guard !closed else { return }
        webView.isHidden = false
        webView.removeFromSuperview()
        let viewportSize = fixedViewport ?? Self.defaultViewport
        webView.autoresizingMask = []
        backingWindow.setContentSize(viewportSize)
        backingWindow.contentView = webView
        webView.frame = NSRect(origin: .zero, size: viewportSize)
        backingWindow.orderOut(nil)
    }

    func mount(in host: NSView) {
        webView.removeFromSuperview()
        host.addSubview(webView)
        layoutViewport()
    }

    func setViewport(_ size: NSSize?) {
        fixedViewport = size
        layoutViewport()
    }

    private func layoutViewport() {
        if webView.window === backingWindow {
            let viewportSize = fixedViewport ?? Self.defaultViewport
            backingWindow.setContentSize(viewportSize)
            webView.frame = NSRect(origin: .zero, size: viewportSize)
        } else if let host = webView.superview {
            guard let viewportSize = fixedViewport else {
                webView.frame = host.bounds
                webView.autoresizingMask = [.width, .height]
                return
            }
            webView.autoresizingMask = [.minYMargin]
            webView.frame = NSRect(x: host.bounds.minX, y: host.bounds.maxY - viewportSize.height,
                                   width: viewportSize.width, height: viewportSize.height)
        }
    }

    func cssViewport(setting size: NSSize? = nil) async throws -> (width: Double, height: Double, devicePixelRatio: Double) {
        let previous = fixedViewport
        if let size {
            try requireResponsiveContent()
            setViewport(size)
        }
        let script = "({width:innerWidth,height:innerHeight,devicePixelRatio:devicePixelRatio})"
        do {
            guard let viewport = try await runJS(script, world: DOM.world) as? [String: Any],
                  let width = viewport["width"] as? Double, let height = viewport["height"] as? Double,
                  let scale = viewport["devicePixelRatio"] as? Double, width > 0, height > 0, scale > 0 else {
                throw BrowserError("snapshot_failed", "无法读取文档 CSS 视口")
            }
            return (width, height, scale)
        } catch {
            if size != nil { setViewport(previous) }
            throw error
        }
    }

    func close() {
        closed = true
        dialogs.stop(code: "tab_closed")
        downloads.stop(); fileChooser.stop()
        webView.isInspectable = false
        diagnostics.captureConfigurationChanged = nil
        diagnostics.setDetail(false)
        DiagnosticRouter.shared.logs.removeObject(forKey: webView)
        FrameRouter.shared.stores.removeObject(forKey: webView)
        frames.reset()
        failPending(BrowserError("tab_closed", "标签页已关闭"))
        observations.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview(); backingWindow.contentView = nil; backingWindow.close()
        changed = nil
        statusChanged = nil
        networkCheck = nil
        createPopup = nil; closeRequested = nil
        inputFocusConflict = nil
        clearNavigationSpans()
    }

    func disableDiagnosticDetails() {
        diagnostics.setDetail(false)
    }

    private static func installUserScripts(on controller: WKUserContentController, diagnosticSource: String) {
        for source in [DOM.bootstrap, FrameRouter.script] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DOM.world))
        }
        controller.addUserScript(WKUserScript(source: diagnosticSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private func updateDiagnosticScript() {
        let controller = webView.configuration.userContentController
        let source = DiagnosticScript.source(configuration: diagnostics.documentStartConfiguration)
        if controller.userScripts.last?.source != source {
            // The API's script list is backed by the controller. Reinstall from source;
            // a list retained across removal does not preserve the old scripts.
            controller.removeAllUserScripts()
            Self.installUserScripts(on: controller, diagnosticSource: source)
        }
        // Host filtering is immediate even when WebContent cannot acknowledge disable/expiry.
        let stop = "window.__agentWebKitDiagnosticMode?.(null)"
        if diagnostics.configuration == nil { webView.evaluateJavaScript(stop, completionHandler: nil) }
        if diagnostics.documentStartConfiguration == nil {
            for document in frames.documents where !document.info.isMainFrame {
                webView.evaluateJavaScript(stop, in: document.info, in: .page) { _ in }
            }
        }
    }

    func enableDiagnosticDetails(continuous: Bool, includeInfo: Bool) async throws {
        diagnostics.setDetail(true, continuous: continuous, includeInfo: includeInfo)
        do {
            guard let configuration = diagnostics.configuration, let generation = configuration["generation"] as? String else {
                throw BrowserError("diagnostics_unavailable", "诊断模式已失效")
            }
            let literal = String(decoding: try jsonData(configuration), as: UTF8.self)
            let script = """
                typeof window.__agentWebKitDiagnosticMode === 'function' ?
                ({generation:window.__agentWebKitDiagnosticMode(\(literal)),tree:window.__agentWebKitDiagnosticTreeId}) : null
                """
            let current = committedNavigationID
            let info = try await runJS(script) as? [String: Any]
            let ack = info?["generation"] as? String
            // A fresh about:blank may have no hook yet. The next document is armed
            // by the controller even if there is nothing to attach to right now.
            let blank = committedDocumentURL == "about:blank" && (webView.url?.absoluteString ?? "about:blank") == "about:blank"
            guard generation == diagnostics.detailGeneration, ack == generation || (continuous && blank && ack == nil) else {
                throw BrowserError("diagnostics_unavailable", "当前文档没有可用诊断 hook；请检查页面或显式重新加载")
            }
            if let current, current == committedNavigationID {
                diagnostics.associateDocumentTree(info?["tree"], navigation: current)
            }
            if continuous, ack == generation {
                let source = DiagnosticScript.source(configuration: configuration)
                let childScript = "if (typeof window.__agentWebKitDiagnosticMode === 'function') { \(script) } else { \(source) }"
                for document in frames.documents where !document.info.isMainFrame {
                    webView.evaluateJavaScript(childScript, in: document.info, in: .page) { _ in }
                }
            }
        } catch {
            disableDiagnosticDetails()
            throw error
        }
    }

    var state: [String: Any] {
        ["tabId": id.uuidString, "url": committedDocumentURL, "title": webView.title ?? "",
         "requestedURL": requestedURL as Any? ?? NSNull(), "committedDocumentURL": committedDocumentURL, "restoreURL": persistedURL,
         "navigationId": navigationResult?.id.uuidString as Any? ?? NSNull(),
         "navigationPhase": navigationResult?.phase.rawValue ?? "idle",
         "httpStatus": navigationResult?.response?.status as Any? ?? NSNull(),
         "responseURL": navigationResult?.response?.url.absoluteString as Any? ?? NSNull(),
         "httpResponseNavigationId": navigationResult?.response?.navigationID.uuidString as Any? ?? NSNull(),
         "redirectCount": navigationResult?.redirects ?? 0,
         "loading": webView.isLoading, "webContentTerminated": terminated, "suppressedDialogs": suppressedDialogs,
         "pendingDialogs": dialogs.pendingCount, "suspended": false,
         "activeDownloads": downloads.hasActive, "fileChooser": fileChooser.state,
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

    private func requireResponsiveContent() throws {
        guard !closed else { throw BrowserError("tab_closed", "标签页已关闭") }
        guard !terminated else { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请重新 open") }
        guard !unresponsive else { throw BrowserError("web_content_unresponsive", "上次 WebKit 调用超时，请先 reload 恢复标签页") }
        guard deadline.map({ monotonicNow() < $0 }) ?? true else { throw BrowserError("timeout", "命令执行超时") }
    }

    private func perform<Value>(_ operation: String, body: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try requireResponsiveContent()
        let now = monotonicNow()
        let remaining = deadline.map { Double($0 > now ? $0 - now : 0) / 1_000_000 } ?? 15000
        guard remaining > 0 else { throw BrowserError("timeout", "命令执行超时") }
        let timing = operationTiming
        let token = timing?.begin(operation, from: monotonicNow())
        let id = UUID()
        defer { pending[id] = nil }
        do {
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
        } catch {
            // WebKit may fail a pending JS callback with an unsupported-result error
            // before delivering its termination delegate in the same main-loop turn.
            // Prefer the observed process state when the continuation resumes.
            if terminated { throw BrowserError("web_content_terminated", "WebContent 进程已退出；reload 可恢复页面，操作可能已部分生效") }
            throw error
        }
    }

    func runJS(_ script: String, awaitPromise: Bool = false, world: WKContentWorld? = nil, frameID: String? = nil) async throws -> Any {
        let world = world ?? .page
        let internalDOM = world == DOM.world
        var target: FrameDocument?
        if let frameID {
            guard internalDOM else { throw BrowserError("invalid_arguments", "--frame 仅支持内部 DOM 操作") }
            guard let document = frames.documents.first(where: { $0.id == frameID }), document.info.webView === webView else {
                throw BrowserError("stale_frame", "frame 文档已失效或不属于此 Tab；重新 frame list 并确认目标")
            }
            target = document
        }
        let guardScript = try target.map { "if(!globalThis.__agentWebKitFrame?.active||globalThis.__agentWebKitFrame.epoch!==\(try quoteJS($0.epoch)))throw new Error('stale_frame: frame document changed');" } ?? ""
        let source = internalDOM ? "(()=>{try{\(guardScript)return (0,eval)(\(try quoteJS(script)))}catch(error){throw new Error('__agent_webkit_dom__:'+String(error?.message||error))}})()" : script
        return try await perform(awaitPromise ? "callAsyncJavaScript" : "evaluateJavaScript") { complete in
            let callback: (Any?, Error?) -> Void = { [weak self] result, error in
                if let error {
                    let nsError = error as NSError
                    if let target, nsError.domain == WKErrorDomain, nsError.code == WKError.Code.javaScriptInvalidFrameTarget.rawValue {
                        self?.frames.remove(target.id)
                        complete(.failure(BrowserError("stale_frame", "frame 已移除或文档已失效；重新 frame list")))
                        return
                    }
                    if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
                        let codes = ["input_target_changed", "input_focus_failed", "stale_frame", "stale_ref", "selector_count", "invalid_selector", "unsupported_context", "element_not_actionable", "element_readonly", "unsupported_fill_type", "element_not_editable", "invalid_option", "unsupported_upload_target", "upload_multiple_not_allowed", "upload_unavailable", "unsupported_screenshot_geometry", "snapshot_truncated", "unsupported_checkbox_target", "dom_state_mismatch"]
                        let prefix = "__agent_webkit_dom__:"
                        let exception = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
                        let tagged = internalDOM && exception.hasPrefix(prefix)
                        let detail = tagged ? String(exception.dropFirst(prefix.count)) : message
                        let candidate = String(detail.split(separator: ":", maxSplits: 1).first ?? "")
                        let code = tagged && codes.contains(candidate) ? candidate : "javascript_error"
                        if code == "stale_frame", let target { self?.frames.remove(target.id) }
                        complete(.failure(BrowserError(code, String(detail.prefix(2000)))))
                    } else { complete(.failure(error)) }
                }
                else { complete(.success(result ?? NSNull())) }
            }
            if awaitPromise {
                webView.callAsyncJavaScript("return await (0, eval)(source)", arguments: ["source": source], in: target?.info, in: world) { result in
                    switch result {
                    case .success(let value): callback(value, nil)
                    case .failure(let error): callback(nil, error)
                    }
                }
            } else {
                webView.evaluateJavaScript(source, in: target?.info, in: world) { result in
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
        fileChooser.stop()
        requestedURL = url.absoluteString
        navigationError = nil; lastNavigationRejection = nil; certificateError = nil; tlsChallenge = [:]; terminated = false
        // A repeated failed load can return nil and still deliver a terminal delegate callback.
        // Never treat the previous document's readyState as completion of this request.
        navigationPending = true
        let target = NavigationTarget(url: url, isGET: true)
        nextMainFrameTarget = nil
        navigationResult = NavigationResult(target: target)
        let start = monotonicNow()
        navigationStartedAt = start
        if let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) {
            trackNavigation(navigation, start: start, target: target)
        }
        changed?()
    }

    private func trackNavigation(_ navigation: WKNavigation, start: UInt64, target: NavigationTarget?) {
        discardReleasedNavigations()
        let key = ObjectIdentifier(navigation)
        guard navigationSpan(navigation) == nil else { return }
        navigationSequence += 1
        let result = NavigationResult(target: target)
        navigationResult = result
        navigationSpans[key] = NavigationSpan(navigation: navigation, start: start, timing: operationTiming,
            token: operationTiming?.begin("navigation", from: start), sequence: navigationSequence, id: result.id)
    }

    private func navigationSpan(_ navigation: WKNavigation?) -> NavigationSpan? {
        guard let navigation, let span = navigationSpans[ObjectIdentifier(navigation)],
              span.navigation === navigation else { return nil }
        return span
    }

    private func discardReleasedNavigations() {
        for (key, span) in navigationSpans where span.navigation == nil {
            if let token = span.token { span.timing?.finish(token) }
            navigationSpans.removeValue(forKey: key)
        }
    }

    private func clearNavigationSpans() {
        for span in navigationSpans.values {
            if let token = span.token { span.timing?.finish(token) }
        }
        navigationSpans.removeAll()
    }

    @discardableResult
    private func finishNavigation(_ navigation: WKNavigation?, becameDownload: Bool = false) -> Bool {
        discardReleasedNavigations()
        let span = navigationSpan(navigation)
        if span != nil, let navigation { navigationSpans.removeValue(forKey: ObjectIdentifier(navigation)) }
        if let token = span?.token { span?.timing?.finish(token) }
        let latest = span.map { $0.id == navigationResult?.id } ?? (navigationPending && (navigation == nil || provisionalNavigation == nil))
        if latest {
            completedNavigationSequence = navigationSequence
            completedNavigationWasDownload = becameDownload
            navigationPending = false
        }
        if provisionalNavigation === navigation { provisionalNavigation = nil }
        return latest
    }

    func waitForNavigation(after sequence: Int, errorRevision: Int, timeout: Int) async throws {
        let start = monotonicNow()
        repeat {
            if terminated { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请 reload") }
            if navigationErrorRevision > errorRevision,
               navigationErrorSequence.map({ $0 > sequence }) ?? true,
               let navigationError { throw navigationError }
            if let lastNavigationRejection { throw lastNavigationRejection }
            if navigationSequence > sequence, !navigationPending, completedNavigationSequence == navigationSequence {
                guard !completedNavigationWasDownload else {
                    throw BrowserError("unsupported_navigation", "点击已转为下载，没有产生新的页面文档；请查询 download list 核对下载，不要重复点击")
                }
                return
            }
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

    func traverseHistory(back: Bool) async throws -> [String: Any] {
        let history = webView.backForwardList
        guard !navigationPending, !webView.isLoading else {
            throw BrowserError("unsupported_navigation", "当前导航尚未完成，先检查 state")
        }
        guard let item = back ? history.backItem : history.forwardItem else {
            throw BrowserError("history_unavailable", "目标方向没有历史记录")
        }
        let before = history.currentItem
        let sequence = navigationSequence, errorRevision = navigationErrorRevision
        let script = "({href:location.href,revision:window.__agentWebKit?.historyState.revision,ready:document.readyState==='complete'})"
        let initial = try await runJS(script, world: DOM.world) as? [String: Any]
        guard sequence == navigationSequence, history.currentItem === before, !navigationPending, !webView.isLoading else {
            throw BrowserError("unsupported_navigation", "历史目标已改变；请重新检查当前页面")
        }
        try requireResponsiveContent()
        guard webView.go(to: item) != nil else {
            throw BrowserError("history_unavailable", "WebKit 未接受历史导航")
        }
        let end = deadline ?? monotonicNow() + 15_000_000_000
        while monotonicNow() < end {
            if terminated { throw BrowserError("web_content_terminated", "WebContent 进程已退出，请 reload") }
            if navigationErrorRevision > errorRevision, let navigationError { throw navigationError }
            if history.currentItem === item, !navigationPending, !webView.isLoading {
                let sampleSequence = navigationSequence
                let page = try await runJS(script, world: DOM.world) as? [String: Any]
                let sameDocument = sampleSequence == sequence
                let traversed = sameDocument
                    ? (page?["revision"] as? Int ?? 0) > (initial?["revision"] as? Int ?? 0)
                    : completedNavigationSequence == sampleSequence && !completedNavigationWasDownload
                if traversed, let href = page?["href"] as? String, href == item.url.absoluteString, page?["ready"] as? Bool == true,
                   history.currentItem === item, sampleSequence == navigationSequence, !navigationPending, !webView.isLoading {
                    persistedURL = href; committedDocumentURL = href
                    return ["method": "webkit-history", "sameDocument": sameDocument, "businessOutcomeVerified": false]
                }
            }
            let now = monotonicNow()
            if now < end { try await Task.sleep(nanoseconds: min(50_000_000, end - now)) }
        }
        throw BrowserError("timeout", "等待历史导航完成超时；先检查 state，命令不会重放")
    }

    func wait(selector: String?, timeout: Int, state: String = "visible", text: String? = nil,
              url: String? = nil, urlPattern: String? = nil, function: String? = nil,
              stableFor: Int = 0, frameID: String? = nil) async throws {
        let start = monotonicNow()
        let end = min(start + UInt64(timeout) * 1_000_000, deadline ?? UInt64.max)
        var stableSince: UInt64?
        var stableSequence = navigationSequence
        let conditionScript: String?
        if let url {
            conditionScript = "location.href === \(try quoteJS(url))"
        } else if let function {
            conditionScript = """
                (()=>{const predicate=(\(function)\n);
                if(typeof predicate!=='function')throw new Error('--fn expects a synchronous function');
                const result=predicate();
                if(typeof result!=='boolean')throw new Error('--fn must return a boolean');
                return result})()
                """
        } else if selector != nil || text != nil {
            let target = try selector.map { try quoteJS($0) } ?? "null"
            let expected = try text.map { try quoteJS($0) } ?? "null"
            conditionScript = "Boolean(window.__agentWebKit && window.__agentWebKit.matchesCondition(\(target),\(try quoteJS(state)),\(expected)))"
        } else { conditionScript = nil }
        repeat {
            if frameID == nil {
                if let navigationError { throw navigationError }
                if let certificateError { throw certificateError }
            }
            let sampleSequence = navigationSequence
            let matched: Bool
            if let urlPattern {
                let href = try await runJS("location.href", world: DOM.world, frameID: frameID) as? String
                matched = href.map { fnmatch(urlPattern, $0, 0) == 0 } ?? false
            } else if let conditionScript {
                let world: WKContentWorld = function != nil && frameID == nil ? .page : DOM.world
                matched = try await runJS(conditionScript, world: world, frameID: frameID) as? Bool == true
            } else if frameID != nil {
                matched = try await runJS("document.readyState", world: DOM.world, frameID: frameID) as? String == "complete"
            } else if !webView.isLoading, !navigationPending, navigationSequence == completedNavigationSequence,
                      (try await runJS("document.readyState", world: DOM.world) as? String) == "complete" {
                if let navigationError { throw navigationError }
                if let certificateError { throw certificateError }
                matched = !webView.isLoading && !navigationPending && navigationSequence == completedNavigationSequence
            } else {
                matched = false
            }
            let now = monotonicNow()
            if stableSequence != navigationSequence {
                stableSince = nil
                stableSequence = navigationSequence
            }
            if matched, sampleSequence == navigationSequence,
               stableFor == 0 || frameID != nil || !navigationPending {
                if stableSince == nil { stableSince = now }
                if let stableSince, now - stableSince >= UInt64(stableFor) * 1_000_000,
                   now <= end { return }
            } else { stableSince = nil }
            if now >= end { break }
            try await Task.sleep(nanoseconds: min(50_000_000, end - now))
        } while monotonicNow() < end
        diagnostics.native(navigationPending ? "navigation-timeout" : "condition-timeout", url: URL(string: persistedURL),
                           error: BrowserError("timeout", ""), duration: milliseconds(from: start))
        throw BrowserError("timeout", "等待页面条件超时（\(timeout) ms）")
    }

    private func snapshotBitmap(rect: CGRect) async throws -> NSBitmapImageRep {
        guard webView.bounds.contains(rect), !rect.isEmpty else { throw BrowserError("unsupported_screenshot_geometry", "截图范围超出 WebView 视口") }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        let image: NSImage = try await perform("takeSnapshot") { complete in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { complete(.failure(error)) }
                else if let image { complete(.success(image)) }
                else { complete(.failure(BrowserError("snapshot_failed", "WebKit 未返回图像"))) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw BrowserError("png_failed", "无法读取截图像素") }
        return bitmap
    }

    func screenshot(path: String, element: String? = nil, fullPage: Bool = false) async throws -> [String: Any] {
        let document = committedNavigationID
        return try await TabScreenshot.capture(in: self, path: path, element: element, fullPage: fullPage,
                                               snapshotBitmap: snapshotBitmap, sameDocument: { self.committedNavigationID == document })
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A failed provisional load can retain the current document and all its frames.
        // Live document epochs, not navigation attempts, govern frame validity.
        if let navigation, observerStoppedNavigations.contains(navigation) { return }
        if let span = navigationSpan(navigation), span.sequence != navigationSequence { return }
        dialogs.cancelAll(code: "dialog_cancelled")
        fileChooser.stop()
        navigationError = nil
        lastNavigationRejection = nil
        certificateError = nil
        if !navigationPending {
            navigationStartedAt = monotonicNow()
            navigationResult = NavigationResult()
        }
        navigationPending = true
        provisionalNavigation = navigation
        if let navigation { trackNavigation(navigation, start: monotonicNow(), target: nextMainFrameTarget) }
        nextMainFrameTarget = nil
        diagnostics.beginNavigation(id: navigationResult?.id)
        changed?()
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard navigationSpan(navigation)?.sequence == navigationSequence else { return }
        navigationResult?.redirects += 1
        navigationResult?.phase = .redirecting
        statusChanged?()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigationSpan(navigation)?.sequence == navigationSequence || (navigation == nil && navigationPending) else { return }
        if let response = navigationResult?.response?.url, let committed = webView.url,
           response.absoluteString.split(separator: "#", maxSplits: 1).first != committed.absoluteString.split(separator: "#", maxSplits: 1).first {
            navigationResult?.response = nil
        }
        navigationResult?.phase = .committed
        committedNavigationID = navigationResult?.id
        if let url = webView.url { persistedURL = url.absoluteString; committedDocumentURL = url.absoluteString }
        correlateDiagnosticDocument()
        changed?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation, observerStoppedNavigations.contains(navigation) { return }
        recordNavigation("navigation-finished", navigation: navigation)
        if finishNavigation(navigation) {
            navigationResult?.phase = .finished
            committedNavigationID = navigationResult?.id
            if let url = webView.url { persistedURL = url.absoluteString; committedDocumentURL = url.absoluteString }
            if let item = webView.backForwardList.currentItem {
                if let response = navigationResult?.response {
                    historyResponses.removeAll { $0.item == nil || $0.item === item }
                    if historyResponses.count == Self.historyResponseLimit { historyResponses.removeFirst() }
                    historyResponses.append(HistoryResponse(item: item, response: response))
                } else if let prior = historyResponses.first(where: { $0.item === item }),
                          prior.response.url.absoluteString == committedDocumentURL {
                    // A cached document can finish without a new response callback.
                    navigationResult?.response = prior.response
                }
            }
            correlateDiagnosticDocument()
        }
        changed?()
    }
    private func correlateDiagnosticDocument() {
        guard diagnostics.detailGeneration != nil, let id = committedNavigationID else { return }
        let script = "({tree:window.__agentWebKitDiagnosticTreeId??null,href:location.href})"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, !self.closed, self.navigationResult?.id == id,
                  self.committedNavigationID == id, let page = value as? [String: Any],
                  page["href"] as? String == self.committedDocumentURL else { return }
            self.diagnostics.associateDocumentTree(page["tree"], navigation: id)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failNavigation(navigation, error: error, provisional: false)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failNavigation(navigation, error: error, provisional: true)
    }
    func stopLoadingByObserver() {
        if navigationPending, !terminated, let result = navigationResult {
            let span = navigationSpans.values.first { $0.id == result.id }
            // WebKit may deliver a terminal callback after another document has started.
            if let navigation = span?.navigation { observerStoppedNavigations.add(navigation) }
            let download = span?.becameDownload == true
            if download { recordNavigation("navigation-download", navigation: span?.navigation) }
            if finishNavigation(span?.navigation, becameDownload: download) {
                if download {
                    navigationResult?.phase = .download
                } else if committedNavigationID == result.id {
                    navigationResult?.phase = .failed
                } else {
                    navigationResult?.phase = .provisionalFailure
                    navigationResult?.response = nil
                }
            }
        }
        webView.stopLoading()
        changed?()
    }
    private func failNavigation(_ navigation: WKNavigation?, error: Error, provisional: Bool) {
        if let navigation, observerStoppedNavigations.contains(navigation) { return }
        // Unknown cancelled callbacks may belong to a superseded navigation.
        let native = error as NSError
        if navigationSpan(navigation) == nil,
           native.domain == NSURLErrorDomain, native.code == NSURLErrorCancelled { return }
        if navigationSpan(navigation)?.becameDownload == true {
            recordNavigation("navigation-download", navigation: navigation)
            if finishNavigation(navigation, becameDownload: true) { navigationResult?.phase = .download }
            changed?()
            return
        }
        let failedSequence = navigationSpan(navigation)?.sequence ?? navigationSequence
        recordNavigation("navigation-failed", navigation: navigation, error: error)
        let latest = finishNavigation(navigation)
        // A replacement load cancels the previous request. Its late failure must not poison the new one.
        if latest {
            navigationResult?.phase = provisional ? .provisionalFailure : .failed
            if provisional { navigationResult?.response = nil }
            navigationError = certificateError ?? error
            navigationErrorSequence = failedSequence
            let target = navigationResult?.target
            let errorURL = native.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            if let url = errorURL ?? target?.url, Self.supports(url) {
                // Policy callbacks have no navigation token. Only offer a GET when the target
                // agrees with this failure or WebKit recorded a redirect on this navigation.
                let matches = target?.url == url || (navigationResult?.redirects ?? 0) > 0
                failedNavigationTarget = NavigationTarget(url: url, isGET: target?.isGET == true && matches)
            }
            changed?()
        }
    }
    private func recordNavigation(_ kind: String, navigation: WKNavigation?, error: Error? = nil) {
        let span = navigationSpan(navigation)
        let start = span?.start ?? navigationStartedAt
        let latest = span.map { $0.id == navigationResult?.id } ?? navigationPending
        let failedURL = (error as NSError?)?.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        // A failed provisional load can leave webView.url pointing at the previous document.
        let url = error == nil ? webView.url : failedURL ?? URL(string: persistedURL)
        diagnostics.native(kind, url: url, error: error, cause: latest ? certificateError : nil,
                           duration: start.map { milliseconds(from: $0) }, navigationId: span?.id)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            // The response delegate has no navigation token. Associate it with the
            // live provisional main-frame load, and reconcile its URL on commit.
            if navigationPending, let span = navigationSpan(provisionalNavigation), span.sequence == navigationSequence {
                navigationResult?.phase = .response
                if let url = response.url {
                    navigationResult?.response = MainDocumentResponse(status: response.statusCode, url: url, navigationID: span.id)
                }
                diagnostics.native("navigation-response", url: response.url, status: response.statusCode, navigationId: span.id)
            }
        }
        if !navigationResponse.canShowMIMEType || (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true {
            if navigationResponse.isForMainFrame, let navigation = provisionalNavigation, navigationSpan(navigation) != nil {
                navigationSpans[ObjectIdentifier(navigation)]?.becameDownload = true
            }
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.begin(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.begin(download) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        guard !closed else { completionHandler(nil); return }
        fileChooser.present(webView: webView, parameters: parameters, completion: completionHandler)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated = true
        navigationResult?.phase = .terminated
        frames.reset()
        clearNavigationSpans()
        dialogs.stop(code: "web_content_terminated")
        downloads.stop(); fileChooser.stop()
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
        if navigationAction.targetFrame?.isMainFrame == true {
            requestedURL = url.absoluteString
            nextMainFrameTarget = NavigationTarget(url: url, isGET: navigationAction.request.httpMethod == "GET")
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
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
