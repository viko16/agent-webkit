import AppKit
import WebKit
import Network
import CFNetwork
import Security

struct TabRecord: Codable { var id: UUID; var url: String; var openerTabID: UUID? = nil }
struct SpaceRecord: Codable {
    var id: UUID
    var name: String
    var proxy: String
    var defaultTab: UUID
    var tabs: [TabRecord]
    var deleting: Bool = false
    var tls: TLSConfiguration?
    var suspended: Bool?
    var popupCount: Int { tabs.filter { $0.openerTabID != nil }.count }
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

@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    let backingWindow: NSPanel
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
    var navigationError: Error? {
        didSet {
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
    var lastNavigationRejection: BrowserError?
    private(set) var popupSequence = 0
    private var lastPopupID: UUID?
    var suppressedDialogs = 0
    var terminated = false
    var unresponsive = false
    private(set) var closed = false
    private(set) var persistedURL: String
    private(set) var requestedURL: String?
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
        var becameDownload = false
    }
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
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if !configuration.userContentController.userScripts.contains(where: { $0.source == DOM.bootstrap }) {
            configuration.userContentController.addUserScript(WKUserScript(source: DOM.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DOM.world))
        }
        if !configuration.userContentController.userScripts.contains(where: { $0.source == FrameRouter.script }) {
            configuration.userContentController.add(FrameRouter.shared, contentWorld: DOM.world, name: FrameRouter.name)
            configuration.userContentController.addUserScript(WKUserScript(source: FrameRouter.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DOM.world))
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
                    if self.navigationError == nil {
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
        backingWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        backingWindow.orderOut(nil)
    }

    func close() {
        closed = true
        dialogs.stop(code: "tab_closed")
        downloads.stop(); fileChooser.stop()
        webView.isInspectable = false
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
        // Host filtering and erasure are immediate, even if a hung page cannot acknowledge this.
        webView.evaluateJavaScript("window.__agentWebKitDiagnosticMode?.(null)", completionHandler: nil)
    }

    var state: [String: Any] {
        ["tabId": id.uuidString, "url": committedDocumentURL, "title": webView.title ?? "",
         "requestedURL": requestedURL as Any? ?? NSNull(), "committedDocumentURL": committedDocumentURL, "restoreURL": persistedURL,
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
                        let codes = ["input_target_changed", "input_focus_failed", "stale_frame", "stale_ref", "selector_count", "invalid_selector", "unsupported_context", "element_not_actionable", "element_readonly", "unsupported_fill_type", "element_not_editable", "invalid_option", "unsupported_upload_target", "upload_multiple_not_allowed", "upload_unavailable", "unsupported_screenshot_geometry"]
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
        let start = monotonicNow()
        navigationStartedAt = start
        if let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) {
            trackNavigation(navigation, start: start)
        }
        changed?()
    }

    private func trackNavigation(_ navigation: WKNavigation, start: UInt64) {
        discardReleasedNavigations()
        let key = ObjectIdentifier(navigation)
        guard navigationSpan(navigation) == nil else { return }
        navigationSequence += 1
        navigationSpans[key] = NavigationSpan(navigation: navigation, start: start, timing: operationTiming,
            token: operationTiming?.begin("navigation", from: start), sequence: navigationSequence)
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
        let latest = span.map { $0.sequence == navigationSequence } ?? navigationPending
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

    func wait(selector: String?, timeout: Int, state: String = "visible", text: String? = nil, url: String? = nil, frameID: String? = nil) async throws {
        let start = monotonicNow()
        repeat {
            if frameID == nil {
                if let navigationError { throw navigationError }
                if let certificateError { throw certificateError }
            }
            if let url {
                if (try await runJS("location.href === \(try quoteJS(url))", world: DOM.world, frameID: frameID) as? Bool) == true { return }
            } else if selector != nil || text != nil {
                let target = try selector.map { try quoteJS($0) } ?? "null"
                let expected = try text.map { try quoteJS($0) } ?? "null"
                let script = "Boolean(window.__agentWebKit && window.__agentWebKit.matchesCondition(\(target),\(try quoteJS(state)),\(expected)))"
                if (try await runJS(script, world: DOM.world, frameID: frameID) as? Bool) == true { return }
            } else if frameID != nil {
                if (try await runJS("document.readyState", world: DOM.world, frameID: frameID) as? String) == "complete" { return }
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

    private func fullPageBitmap(token: String) async throws -> (bitmap: NSBitmapImageRep, range: [String: Any], tiles: Int) {
        let literal = try quoteJS(token)
        guard let info = try await runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
              let width = info["width"], let height = info["height"], let viewportWidth = info["viewportWidth"], let viewportHeight = info["viewportHeight"],
              [width,height,viewportWidth,viewportHeight].allSatisfy({ $0.isFinite && $0 > 0 }) else { throw BrowserError("snapshot_failed", "无效整页范围") }
        guard width <= viewportWidth else { throw BrowserError("unsupported_screenshot_geometry", "整页截图暂不支持横向溢出；请截取元素或视口") }
        let scaleX = webView.bounds.width / viewportWidth, scaleY = webView.bounds.height / viewportHeight
        let backing = webView.window?.backingScaleFactor ?? 2
        let pixelScale = Double(max(scaleX, scaleY) * backing)
        guard height <= 16000, width * height * pixelScale * pixelScale <= 32_000_000 else {
            throw BrowserError("screenshot_too_large", "整页截图最多16000 CSS px高、预计3200万像素")
        }
        var canvas: CGContext?
        var outputWidth = 0, outputHeight = 0, tiles = 0
        var pixelScaleY = 0.0
        for y in stride(from: 0.0, to: height, by: viewportHeight) {
            _ = try await runJS("window.__agentWebKit.scrollScreenshot(\(literal),\(min(y, max(0, height - viewportHeight))))", world: DOM.world)
            try await Task.sleep(nanoseconds: 50_000_000)
            guard let state = try await runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
                  state["width"] == width, state["height"] == height, state["viewportWidth"] == viewportWidth, state["viewportHeight"] == viewportHeight,
                  let actualY = state["y"], let actualX = state["x"], abs(actualX) < 1 else {
                throw BrowserError("screenshot_changed", "分块期间页面尺寸、文档或视口改变；未写成功文件")
            }
            let tileHeight = min(viewportHeight, height - y), offset = y - actualY
            guard offset >= 0, offset + tileHeight <= viewportHeight else {
                throw BrowserError("unsupported_screenshot_geometry", "页面滚动吸附或脚本阻止了目标分块定位")
            }
            let tile = try await snapshotBitmap(rect: CGRect(x: 0, y: max(0, offset) * scaleY, width: width * scaleX, height: tileHeight * scaleY))
            if canvas == nil {
                outputWidth = tile.pixelsWide; pixelScaleY = Double(tile.pixelsHigh) / tileHeight
                outputHeight = Int((height * pixelScaleY).rounded())
                guard Double(outputWidth) * Double(outputHeight) <= 32_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw BrowserError("screenshot_too_large", "整页像素范围超限或无法分配画布")
                }
                canvas = context
            }
            guard tile.pixelsWide == outputWidth, abs(Double(tile.pixelsHigh) - tileHeight * pixelScaleY) <= 1,
                  let image = tile.cgImage else { throw BrowserError("screenshot_changed", "分块像素比例改变") }
            let start = Int((y * pixelScaleY).rounded()), end = Int(((y + tileHeight) * pixelScaleY).rounded())
            canvas!.draw(image, in: CGRect(x: 0, y: outputHeight - end, width: outputWidth, height: end - start))
            tiles += 1
        }
        guard let final = try await runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
              final["width"] == width, final["height"] == height,
              final["viewportWidth"] == viewportWidth, final["viewportHeight"] == viewportHeight else {
            throw BrowserError("screenshot_changed", "最后分块完成后页面范围改变；未写成功文件")
        }
        guard let image = canvas?.makeImage() else { throw BrowserError("snapshot_failed", "没有生成整页图像") }
        return (NSBitmapImageRep(cgImage: image), ["x": 0, "y": 0, "width": width, "height": height, "coordinateSpace": "document-css"], tiles)
    }

    func screenshot(path: String, element: String? = nil, fullPage: Bool = false) async throws -> [String: Any] {
        var rect = webView.bounds
        var token: String?
        var tiles = 1
        var range: [String: Any] = ["x": 0, "y": 0, "width": webView.bounds.width, "height": webView.bounds.height, "coordinateSpace": "view-points"]
        func restore() async throws {
            guard let current = token else { return }
            token = nil
            let previousDeadline = deadline
            deadline = monotonicNow() + 1_000_000_000
            defer { deadline = previousDeadline }
            guard try await runJS("window.__agentWebKit.restoreScreenshot(\(try quoteJS(current)))", world: DOM.world) as? Bool == true else {
                throw BrowserError("screenshot_changed", "截图期间页面改变，未能还原全部滚动位置")
            }
        }
        do {
            var bitmap: NSBitmapImageRep
            if fullPage {
                guard let current = try await runJS("window.__agentWebKit.prepareScreenshot('html')", world: DOM.world) as? String else {
                    throw BrowserError("snapshot_failed", "无法准备整页截图")
                }
                token = current
                let result = try await fullPageBitmap(token: current)
                bitmap = result.bitmap; range = result.range; tiles = result.tiles
            } else {
                if let element {
                    guard let current = try await runJS("window.__agentWebKit.prepareScreenshot(\(try quoteJS(element)))", world: DOM.world) as? String else {
                        throw BrowserError("snapshot_failed", "无法准备元素截图")
                    }
                    token = current
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard let bounds = try await runJS("window.__agentWebKit.screenshotBounds(\(try quoteJS(current)))", world: DOM.world) as? [String: Any],
                          let x = bounds["x"] as? Double, let y = bounds["y"] as? Double,
                          let width = bounds["width"] as? Double, let height = bounds["height"] as? Double,
                          let viewportWidth = bounds["viewportWidth"] as? Double, let viewportHeight = bounds["viewportHeight"] as? Double,
                          viewportWidth > 0, viewportHeight > 0 else { throw BrowserError("snapshot_failed", "无效元素截图范围") }
                    let scaleX = webView.bounds.width / viewportWidth, scaleY = webView.bounds.height / viewportHeight
                    rect = CGRect(x: x * scaleX, y: y * scaleY, width: width * scaleX, height: height * scaleY).intersection(webView.bounds)
                    guard !rect.isEmpty else { throw BrowserError("element_not_actionable", "元素完全位于可截图范围之外") }
                    range = ["x": x, "y": y, "width": width, "height": height, "coordinateSpace": "main-viewport-css", "clipped": bounds["clipped"] ?? false]
                }
                bitmap = try await snapshotBitmap(rect: rect)
            }
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw BrowserError("png_failed", "无法编码 PNG")
            }
            try await restore()
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
            return ["path": url.path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "requiresForeground": false,
                    "mode": fullPage ? "full-page" : element == nil ? "viewport" : "element", "range": range, "scrollRestored": true,
                    "tiles": tiles, "captureConsistency": fullPage ? "best-effort" : "single-snapshot",
                    "limitations": fullPage ? ["Fixed/sticky content can repeat across tiles", "Lazy and virtualized content is captured only as rendered; dimensions must remain stable", "Nested scroll containers are not expanded; dynamic pixels are not atomic across tiles"] : []]
        } catch let originalError {
            do { try await restore() }
            catch { throw BrowserError((originalError as? BrowserError)?.code ?? "snapshot_failed", "\(originalError.localizedDescription)；滚动还原未完成：\(error.localizedDescription)") }
            throw originalError
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A failed provisional load can retain the current document and all its frames.
        // Live document epochs, not navigation attempts, govern frame validity.
        dialogs.cancelAll(code: "dialog_cancelled")
        fileChooser.stop()
        diagnostics.beginNavigation()
        navigationError = nil
        certificateError = nil
        if !navigationPending { navigationStartedAt = monotonicNow() }
        navigationPending = true
        provisionalNavigation = navigation
        if let navigation { trackNavigation(navigation, start: monotonicNow()) }
        changed?()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { persistedURL = url.absoluteString; committedDocumentURL = url.absoluteString }
        changed?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigation("navigation-finished", navigation: navigation)
        if finishNavigation(navigation), let url = webView.url { persistedURL = url.absoluteString; committedDocumentURL = url.absoluteString }
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
        let native = error as NSError
        if navigationSpan(navigation) == nil,
           native.domain == NSURLErrorDomain, native.code == NSURLErrorCancelled { return }
        if navigationSpan(navigation)?.becameDownload == true {
            recordNavigation("navigation-download", navigation: navigation)
            finishNavigation(navigation, becameDownload: true)
            changed?()
            return
        }
        recordNavigation("navigation-failed", navigation: navigation, error: error)
        let failedSequence = navigationSpan(navigation)?.sequence ?? navigationSequence
        let latest = finishNavigation(navigation)
        // A replacement load cancels the previous request. Its late failure must not poison the new one.
        if latest {
            navigationError = certificateError ?? error
            navigationErrorSequence = failedSequence
            changed?()
        }
    }
    private func recordNavigation(_ kind: String, navigation: WKNavigation?, error: Error? = nil) {
        let span = navigationSpan(navigation)
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
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, affectsPage: true, completionHandler: completionHandler)
    }
    func authenticate(_ challenge: URLAuthenticationChallenge, affectsPage: Bool,
                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let tls else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host
        if tls.ignoreCertificateErrors == true {
            if affectsPage { tlsChallenge = ["host": host, "policy": "insecure", "accepted": true, "certificateErrorsIgnored": true] }
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        guard let certificate = tls.certificate,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
            if affectsPage { certificateError = BrowserError("certificate_rejected", "无法为 \(host) 配置 Space CA") }
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Keep WebKit's SSL/hostname policies. Only add this Space's anchor to this trust object.
        // Security requires this call to originate on the callback queue (the main queue here).
        let status = SecTrustEvaluateAsyncWithError(trust, .main) { [weak self] trust, accepted, error in
            let message = error.map { CFErrorCopyDescription($0) as String } ?? ""
            let details = accepted ? "" : String(describing: SecTrustCopyResult(trust))
            Task { @MainActor in
                if affectsPage { self?.tlsChallenge = ["host": host, "policy": "custom-ca", "accepted": accepted, "error": message, "details": details] }
                if accepted { completionHandler(.useCredential, URLCredential(trust: trust)) }
                else {
                    if affectsPage { self?.certificateError = BrowserError("certificate_rejected", "\(host): \(message)") }
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }
        if status != errSecSuccess {
            if affectsPage { certificateError = BrowserError("certificate_rejected", "\(host): SecTrust evaluation failed (\(status))") }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated = true
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
        if navigationAction.targetFrame?.isMainFrame == true { requestedURL = url.absoluteString }
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

@MainActor
final class Space {
    var record: SpaceRecord
    private(set) var store: WKWebsiteDataStore?
    var tabs: [Tab] = []
    var busy = false
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
            ["tabId": tab.id.uuidString, "url": tab.url, "title": "", "loading": false,
             "webContentTerminated": false, "unresponsive": false, "suspended": true,
             "pendingDialogs": 0, "requiresForeground": false, "tls": record.tls?.summary ?? TLSConfiguration.systemSummary]
        }
    }
    var summary: [String: Any] {
        ["id": record.id.uuidString, "name": record.name, "proxy": record.proxy, "persistent": true,
         "dataStoreId": record.id.uuidString, "defaultTabId": record.defaultTab.uuidString,
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
                if record.defaultTab == tab.id { record.defaultTab = remaining[0].id }
                do { try self.commitSpaceRecord(record, for: space) }
                catch { replacement?.close(); fputs("Persistence error: \(error)\n", stderr); return }
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
        space.record = record
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

    func handle(_ request: Request) async -> [String: Any] {
        let timing = RequestTiming()
        var response: [String: Any]
        do { response = ["ok": true, "result": try await execute(request, timing: timing)] }
        catch { response = failure(error) }
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
            guard r.args.indices.contains(index) else { throw BrowserError("invalid_arguments", "缺少参数；awb help 查看用法") }
            return r.args[index]
        }
        if command == "help" { return try CLIContract.help(r.args) }
        if command == "capabilities" { return CLIContract.capabilities }
        if command == "version" { return ["version": productVersion] }
        if command == "status" {
            return ["version": productVersion, "pid": ProcessInfo.processInfo.processIdentifier, "spaces": spaces.count,
                    "ready": !restoring,
                    "shutdownImpact": shutdownImpact,
                    "liveWebViews": spaces.reduce(0) { $0 + $1.tabs.count },
                    "resourceLimits": limits.summary,
                    "observer": observerState?() ?? [:],
                    "pendingStoreCleanup": records.filter(\.deleting).count,
                    "pendingStores": records.filter(\.deleting).map { ["spaceId": $0.id.uuidString, "name": $0.name] },
                    "storeCleanupErrors": storeCleanupErrors.map { ["spaceId": $0.key.uuidString, "error": $0.value] as [String: Any] },
                    "blockedSpaces": spaces.filter { $0.networkError != nil }.map { $0.record.id.uuidString },
                    "systemProxy": systemProxySummary(), "frontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                    "capabilities": ["input":"dom-synthetic", "keyboard":"explicit focus/key; limited directed AppKit events, main document/open shadow only", "snapshot":"same-origin-frames-and-open-shadow-roots", "crossOriginDOM":"frame list + explicit --tab/--frame for snapshot/click/fill/wait", "screenshot":"viewport", "screenshotModes":["viewport", "element", "full-page"], "foregroundRequired":false],
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
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw BrowserError("invalid_name", "名称需为字母开头的 1–64 位字母、数字、下划线或连字符") }
            guard !records.contains(where: { $0.name == name && !$0.deleting }) else { throw BrowserError("space_exists", "Space 已存在") }
            guard let proxy = r.options["proxy"] else { throw BrowserError("proxy_required", "创建 Space 必须显式指定 --proxy") }
            guard r.options["ca-cert"] == nil || r.options["ignore-certificate-errors"] == nil else {
                throw BrowserError("invalid_arguments", "--ca-cert 和 --ignore-certificate-errors 不能同时使用")
            }
            let tab = TabRecord(id: UUID(), url: "about:blank")
            let tls = r.options["ignore-certificate-errors"] == "true" ? TLSConfiguration.insecure : try r.options["ca-cert"].map { try TLSConfiguration(path: $0) }
            try checkCapacity(addingTabs: 1, addingViews: 1)
            let record = SpaceRecord(id: UUID(), name: name, proxy: proxy, defaultTab: tab.id, tabs: [tab], tls: tls)
            let space = try Space(record)
            records.append(record)
            do { try persist() } catch { records.removeLast(); throw error }
            spaces.append(space); bind(space); changed?()
            return space.summary
        }
        let target = command.hasPrefix("space.") ? try arg(0) : r.options["space"]
        guard let target else { throw BrowserError("space_required", "所有页面操作必须指定 --space") }
        var deletionID: UUID?
        if command == "space.delete" {
            if let uuid = UUID(uuidString: target), records.contains(where: { $0.id == uuid }) {
                deletionID = uuid
            } else {
                let matches = records.filter { $0.name == target }
                guard matches.count <= 1 else {
                    throw BrowserError("space_ambiguous", "同名 Space 包含待清理记录；请从 space list 和 status.pendingStores 确认 UUID 后按 UUID 删除")
                }
                deletionID = matches.first?.id
            }
        }
        guard let id = deletionID ?? spaces.first(where: { $0.record.name == target || $0.record.id.uuidString.lowercased() == target.lowercased() })?.record.id else {
            throw BrowserError("space_not_found", "Space 不存在：\(target)")
        }
        if command == "space.delete" {
            // Avoid retaining the Space/DataStore across the asynchronous removal API.
            guard spaces.first(where: { $0.record.id == id })?.busy != true else { throw BrowserError("space_busy", "Space 正在操作中") }
            var candidate = records
            if let index = candidate.firstIndex(where: { $0.id == id }) { candidate[index].deleting = true }
            try commitRecords(candidate); detach(id); changed?()
            let removed = try await removeStore(id)
            if removed { try commitRecords(records.filter { $0.id != id }); storeCleanupErrors[id] = nil }
            return ["deleted": true, "spaceId": id.uuidString, "websiteDataRemoved": true,
                    "dataStoreRemoved": removed, "cleanupPending": !removed]
        }
        guard let space = spaces.first(where: { $0.record.id == id }) else { throw BrowserError("space_not_found", "Space 已删除") }
        if command == "space.info" { return space.summary }
        if command == "tab.list" { return space.tabStates }
        if let error = space.configurationError { throw error }
        if command == "space.suspend" {
            guard !space.busy else { throw BrowserError("space_busy", "Space 正在操作中") }
            guard !space.tabs.contains(where: { $0.downloads.hasActive }) else { throw BrowserError("space_busy", "Space 有下载进行中；先等待或显式取消") }
            if !space.suspended {
                try save(space)
                let previous = space.record
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
        if space.suspended, ["state", "diagnostics", "dialog.list", "dialog.respond", "download.list", "download.wait", "download.cancel"].contains(command) {
            let tabID = r.options["tab"] ?? space.record.defaultTab.uuidString
            guard let state = space.tabStates.first(where: { ($0["tabId"] as? String)?.lowercased() == tabID.lowercased() }) else {
                throw BrowserError("tab_not_found", "Space 中不存在该标签页")
            }
            guard command == "state" else { throw BrowserError("space_suspended", "Space 已休眠；使用 space resume 显式恢复") }
            return ["spaceId": id.uuidString, "space": space.record.name, "proxy": space.record.proxy,
                    "network": space.networkState, "page": state, "busy": false, "value": NSNull()] as [String: Any]
        }
        if command == "state" || command == "diagnostics" || command.hasPrefix("dialog.") || command.hasPrefix("download.") {
            let tabID = r.options["tab"] ?? space.record.defaultTab.uuidString
            guard let tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else {
                throw BrowserError("tab_not_found", "Space 中不存在该标签页")
            }
            if command.hasPrefix("download.") {
                if command == "download.list" { return ["spaceId": id.uuidString, "tabId": tab.id.uuidString, "value": tab.downloads.snapshot()] }
                let downloadID = try arg(0)
                if command == "download.cancel" { try await tab.downloads.cancelAndWait(downloadID) }
                if command == "download.wait" {
                    let timeout = Int(r.options["timeout"] ?? "15000") ?? 0
                    guard (1...60000).contains(timeout) else { throw BrowserError("invalid_timeout", "timeout 必须为 1–60000 ms") }
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
        if let tabID = r.options["tab"], !space.record.tabs.contains(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) {
            throw BrowserError("tab_not_found", "Space 中不存在该标签页")
        }
        if ["tab.close", "tab.default"].contains(command) {
            guard space.record.tabs.contains(where: { $0.id.uuidString.lowercased() == r.args[0].lowercased() }) else {
                throw BrowserError("tab_not_found", "标签页不存在")
            }
            if command == "tab.close", space.record.tabs.count == 1 { throw BrowserError("last_tab", "不能关闭最后一个标签页；可删除 Space") }
        }
        if command == "open" { _ = try validateURL(arg(0)) }
        if command == "tab.new" { _ = try validateURL(r.args.first ?? "about:blank") }
        if command == "tab.new" {
            try checkCapacity(space: space, addingTabs: 1, addingViews: space.suspended ? space.record.tabs.count + 1 : 1)
        }
        if command == "tab.default" || command == "tab.close" {
            let tabID = try arg(0)
            var record = space.record
            if !space.suspended { record.tabs = space.tabs.map { TabRecord(id: $0.id, url: $0.persistedURL, openerTabID: $0.openerTabID) } }
            let index = record.tabs.firstIndex { $0.id.uuidString.lowercased() == tabID.lowercased() }!
            let id = record.tabs[index].id
            if command == "tab.default" {
                record.defaultTab = id
            } else {
                record.tabs.remove(at: index)
                if record.defaultTab == id { record.defaultTab = record.tabs[0].id }
            }
            try commitSpaceRecord(record, for: space)
            if command == "tab.close", let tab = space.tabs.first(where: { $0.id == id }) {
                space.tabs.removeAll { $0 === tab }; tab.close()
            }
            changed?()
            if command == "tab.default" { return ["defaultTabId": record.defaultTab.uuidString] }
            return ["closed": tabID, "defaultTabId": record.defaultTab.uuidString]
        }
        let wasSuspended = space.suspended
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
            changed?()
            do {
                tab.load(url); try await tab.wait(selector: nil, timeout: timeout); try save(space)
            } catch {
                throw BrowserError((error as? BrowserError)?.code ?? "operation_failed",
                    "标签页已创建（\(tab.id.uuidString)），但导航或保存未完成：\(error.localizedDescription)；请查询该 Tab 状态后再继续，避免重复创建")
            }
            return tab.state
        }
        let tabID = r.options["tab"] ?? space.record.defaultTab.uuidString
        guard var tab = space.tabs.first(where: { $0.id.uuidString.lowercased() == tabID.lowercased() }) else { throw BrowserError("tab_not_found", "Space 中不存在该标签页") }
        // Replace a stalled view only on explicit navigation. Never replay an Agent action.
        if ["open", "reload"].contains(command), tab.terminated || tab.unresponsive {
            let replacement = Tab(record: TabRecord(id: tab.id, url: tab.persistedURL, openerTabID: tab.openerTabID), store: store, tls: space.record.tls, diagnostics: tab.diagnostics)
            let index = space.tabs.firstIndex(where: { $0 === tab })!
            tab.close(); space.tabs[index] = replacement; tab = replacement
            bind(space); changed?()
        }
        tab.operationTiming = timing; tab.deadline = monotonicNow() + UInt64(timeout) * 1_000_000
        defer { tab.operationTiming = nil; tab.deadline = nil }
        var value: Any = NSNull()
        if wasSuspended, !["open", "reload"].contains(command) { try await tab.wait(selector: nil, timeout: timeout) }
        switch command {
        case "open":
            let url = try validateURL(arg(0)); tab.load(url)
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "reload":
            tab.load(try validateURL(tab.persistedURL))
            try await tab.wait(selector: nil, timeout: timeout); try save(space)
        case "state": break
        case "focus": value = try await tab.focus(target: arg(0))
        case "key":
            guard let key = BackgroundKey(rawValue: try arg(0)) else { throw BrowserError("unsupported_key", "不支持此后台按键") }
            value = try await tab.key(key)
        case "frame.list": value = try await tab.frameList()
        case "snapshot":
            value = try await tab.runJS("window.__agentWebKit.snapshot()", world: DOM.world, frameID: r.options["frame"])
            if let frameID = r.options["frame"], var snapshot = value as? [String: Any] {
                snapshot["frameId"] = frameID
                snapshot["textScope"] = "selected-frame"
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
        case "click", "fill":
            let before = tab.navigationSequence
            let beforeError = tab.navigationErrorRevision
            let beforePopup = tab.popupSequence
            tab.lastNavigationRejection = nil
            value = try await tab.runJS("window.__agentWebKit.act(\(try quoteJS(command)),\(try quoteJS(arg(0))),\(try quoteJS(command == "fill" ? arg(1) : "")))", world: DOM.world, frameID: r.options["frame"])
            if r.options["wait-for-navigation"] == "true" { try await tab.waitForNavigation(after: before, errorRevision: beforeError, timeout: timeout) }
            if r.options["wait-for-popup"] == "true" {
                let popupID = try await tab.waitForPopup(after: beforePopup, timeout: timeout)
                var action = value as? [String: Any] ?? [:]
                action["newTabId"] = popupID; value = action
            }
        case "wait":
            try await tab.wait(selector: r.args.first, timeout: timeout, state: r.options["state"] ?? "visible", text: r.options["text"], url: r.options["url"], frameID: r.options["frame"])
        case "screenshot":
            guard let path = r.options["out"] else { throw BrowserError("invalid_arguments", "截图需要 --out PATH") }
            value = try await tab.screenshot(path: path, element: r.options["element"], fullPage: r.options["full-page"] == "true")
        case "upload": value = try await tab.upload(target: arg(0), paths: Array(r.args.dropFirst()))
        default: throw BrowserError("unknown_command", "未知命令")
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
