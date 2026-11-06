// Real responder and WebKit races; foreground fixture setup is explicitly opt-in.
import AppKit

@MainActor var inputHostAfterDOM: (() async -> Void)?
@MainActor var inputHostLateCallback: (() -> Void)?
@MainActor var inputHostAfterKeyState: (() async -> Void)?

@MainActor
final class InputHostProbe: NSObject, NSApplicationDelegate {
    private var activatedDuringViewport = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    func verifyViewport(_ tab: Tab, peer: Tab, model: BrowserModel, space: Space, directory: URL,
                        showObserver: () -> ObserverWindow) async throws -> [String: Any] {
        guard NSApp.activationPolicy() == .regular,
              let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw BrowserError("probe_failed", "viewport probe requires a logged-in GUI session")
        }
        let center = NotificationCenter.default
        let activationObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activatedDuringViewport = true }
        }
        defer { center.removeObserver(activationObserver) }
        let peerScript = "[innerWidth,innerHeight,location.href,inputRead().epoch,inputRead().value]"
        guard let peerState = try await peer.runJS(peerScript) as? [Any],
              peerState.first as? Int == 720, peerState.dropFirst().first as? Int == 480 else {
            throw BrowserError("probe_failed", "unexpected peer viewport before setting the target")
        }
        let peerBefore = try jsonData(peerState)
        let options = ["space": space.record.id.uuidString, "tab": tab.id.uuidString]
        let viewport = await model.handle(Request(command: "viewport.set", args: ["1440", "900"], options: options))
        guard viewport["ok"] as? Bool == true else { throw BrowserError("probe_failed", "viewport set failed: \(viewport)") }
        _ = try await tab.runJS("""
            const marks = [['left:0;top:0','red'],['right:0;top:0','lime'],
                ['left:0;bottom:0','blue'],['right:0;bottom:0','magenta'],
                ['left:50%;top:50%;transform:translate(-50%,-50%)','yellow']];
            for (const [position,color] of marks)
                document.body.insertAdjacentHTML('beforeend',
                    '<div style="position:fixed;pointer-events:none;z-index:99;width:48px;height:48px;background:'+color+';'+position+'"></div>');
            true
            """)
        func capture(_ phase: String, window: NSWindow) async throws -> [String: Any] {
            let host = tab.webView.superview
            let shouldBeVisible = window !== tab.backingWindow
            func checkMount() throws {
                guard tab.webView.window === window, tab.webView.superview === host, window.isVisible == shouldBeVisible else {
                    throw BrowserError("probe_failed", "unexpected screenshot host during \(phase)")
                }
            }
            try checkMount()
            let state = try await tab.runJS("[innerWidth,innerHeight,getComputedStyle(document.querySelector('#breakpoint'),'::before').content]") as? [Any]
            guard state?[0] as? Int == 1440, state?[1] as? Int == 900, state?[2] as? String == "\"wide\"" else {
                throw BrowserError("probe_failed", "viewport/breakpoint changed during \(phase): \(String(describing: state))")
            }
            let path = directory.appendingPathComponent("viewport-\(phase).png")
            var screenshotOptions = options
            screenshotOptions["out"] = path.path
            let result = await model.handle(Request(command: "screenshot", args: [], options: screenshotOptions))
            guard let payload = result["result"] as? [String: Any], let shot = payload["value"] as? [String: Any],
                  let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path)),
                  let css = shot["cssViewport"] as? [String: Double], css["width"] == 1440, css["height"] == 900,
                  let scale = shot["pixelsPerCssPixel"] as? [String: Double],
                  shot["width"] as? Int == bitmap.pixelsWide, shot["height"] as? Int == bitmap.pixelsHigh,
                  scale["x"] == Double(bitmap.pixelsWide) / 1440, scale["y"] == Double(bitmap.pixelsHigh) / 900 else {
                throw BrowserError("probe_failed", "invalid screenshot metadata during \(phase): \(result)")
            }
            let points = [(24, 24), (1416, 24), (24, 876), (1416, 876), (720, 450)]
            let samples = points.compactMap { x, y -> [Int]? in
                guard let color = bitmap.colorAt(x: x * bitmap.pixelsWide / 1440, y: y * bitmap.pixelsHigh / 900),
                      color.colorSpace.colorSpaceModel == .rgb else { return nil }
                return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
            }
            let expected = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 0, 255, 255], [255, 255, 0, 255]]
            guard samples == expected else { throw BrowserError("probe_failed", "wrong PNG pixels during \(phase): \(samples)") }
            try checkMount()
            guard !activatedDuringViewport, !NSApp.isActive, !window.isKeyWindow,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                  try await jsonData(peer.runJS(peerScript)) == peerBefore else {
                throw BrowserError("probe_failed", "foreground or peer Tab changed during \(phase)")
            }
            return ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "cssViewport": css,
                    "pixelsPerCssPixel": scale, "breakpoint": "wide", "samples": samples]
        }
        let background = try await capture("background", window: tab.backingWindow)
        let observer = showObserver()
        guard let host = tab.webView.superview else { throw BrowserError("probe_failed", "no observer host") }
        let observed = try await capture("selected", window: observer.window)
        let originalWindowFrame = observer.window.frame
        let originalHostSize = host.bounds.size
        observer.window.setContentSize(NSSize(width: 880, height: 500))
        observer.window.contentView?.layoutSubtreeIfNeeded()
        let clippedSize = host.bounds.size
        guard tab.webView.superview === host, originalHostSize != clippedSize,
              host.clipsToBounds, clippedSize.width < 1416, clippedSize.height < 876 else {
            throw BrowserError("probe_failed", "test did not crop both axes: \(clippedSize)")
        }
        let resized = try await capture("resized", window: observer.window)
        observer.nextTab(nil)
        guard tab.webView.window === tab.backingWindow, peer.webView.window === observer.window else {
            throw BrowserError("probe_failed", "GUI Tab switch did not park the target")
        }
        let parked = try await capture("parked", window: tab.backingWindow)
        observer.previousTab(nil)
        observer.window.setFrame(originalWindowFrame, display: true)
        for shot in [observed, resized, parked] where try jsonData(shot) != jsonData(background) {
            throw BrowserError("probe_failed", "screenshot evidence changed with observer geometry")
        }
        tab.setViewport(NSSize(width: 680, height: 460))
        return ["background": background, "selected": observed, "resized": resized, "parked": parked,
                "hostBeforeResize": ["width": originalHostSize.width, "height": originalHostSize.height],
                "hostAfterResize": ["width": clippedSize.width, "height": clippedSize.height],
                "frontmostPid": frontmost, "peerUnchanged": true]
    }

    func probeFrameInput(_ tab: Tab, page: URL) async throws -> [[String: Any]] {
        var cross = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        cross.host = "localhost"; cross.path = "/context-frame"; cross.query = "probe=cross"
        _ = try await tab.runJS("document.body.insertAdjacentHTML('beforeend','<iframe id=cross-frame></iframe>'); document.querySelector('#cross-frame').src=\(try quoteJS(cross.string!));true")
        let crossPattern = cross.string!
        try await tab.wait(selector: nil, timeout: 5000)
        var results: [[String: Any]] = []
        let frameScript = "({value:document.querySelector('#same').value, active:document.activeElement?.id, keys:window.frameProbeKeys})"
        for (id, crossOrigin) in [("frame", false), ("cross-frame", true)] {
            var document: [String: Any]?
            for _ in 0..<50 {
                let documents = try await tab.frameList()["frames"] as? [[String: Any]] ?? []
                document = documents.first { row in
                    guard row["mainFrame"] as? Bool == false, let url = row["url"] as? String else { return false }
                    return crossOrigin ? url == crossPattern : url.hasSuffix("/context-frame")
                }
                if document != nil { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let frameID = document?["frameId"] as? String, let window = tab.webView.window else {
                throw BrowserError("probe_failed", "iframe probe document unavailable: \(id) \(try await tab.frameList())")
            }
            _ = try await tab.runJS("window.frameProbeKeys=[];document.addEventListener('keydown',e=>frameProbeKeys.push([e.key,e.isTrusted])); window.__agentWebKit.focus('#same')",
                                    world: DOM.world, frameID: frameID)
            guard window.makeFirstResponder(tab.webView),
                  try await tab.runJS("document.activeElement?.id") as? String == id else {
                throw BrowserError("probe_failed", "iframe is not the main document's active element")
            }
            func send() {
                let key = BackgroundKey.shiftX.event
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: key.characters, charactersIgnoringModifiers: key.ignoring, isARepeat: false, keyCode: key.code)!
                    if type == .keyDown { tab.webView.keyDown(with: event) } else { tab.webView.keyUp(with: event) }
                }
            }
            send()
            let routed = try await tab.runJS(frameScript, world: DOM.world, frameID: frameID)
            _ = try await tab.runJS("document.querySelector('#first').focus();true")
            let afterFocusMoved = try await tab.runJS(frameScript, world: DOM.world, frameID: frameID)
            send()
            let afterDispatch = try await tab.runJS(frameScript, world: DOM.world, frameID: frameID)
            let mainInput = try await tab.runJS("document.querySelector('#first').value")
            guard let routedState = routed as? [String: Any],
                  routedState["value"] as? String == "X", routedState["active"] as? String == "same",
                  try jsonData(routedState["keys"] ?? NSNull()) == jsonData([["X", true] as [Any]]),
                  try jsonData(afterFocusMoved) == jsonData(afterDispatch),
                  (mainInput as? String)?.hasSuffix("X") == true else {
                throw BrowserError("probe_failed", "unexpected native event route for \(id)")
            }
            _ = try await tab.runJS("document.querySelector('#first').value='alpha beta';true")
            results.append(["crossOrigin": crossOrigin, "routed": routed, "afterFocusMoved": afterFocusMoved,
                            "afterDispatch": afterDispatch, "mainValueAfterDispatch": mainInput])
        }
        return results
    }

    func run() async {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var model: BrowserModel?
        var observer: ObserverWindow?
        var report: [String: Any] = ["ok": false]
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originalApp = NSWorkspace.shared.frontmostApplication
        let foregroundTest = ProcessInfo.processInfo.environment["BROWSER_TEST_FOREGROUND"] == "1"
        defer { originalApp?.activate(options: []) }
        do {
            let browser = try BrowserModel(directory: output.deletingLastPathComponent().appendingPathComponent("host-state"))
            model = browser
            try await browser.restore()
            if CommandLine.arguments.last == "--cleanup-only" {
                let empty = browser.records.isEmpty && browser.spaces.isEmpty
                try jsonData(["ok": empty, "pendingStoreCleanup": browser.records.count]).write(to: output, options: .atomic)
                exit(empty ? 0 : 1)
            }
            let created = await browser.handle(Request(command: "space.create", args: ["input-host"], options: ["proxy": "direct"]))
            guard created["ok"] as? Bool == true, let space = browser.spaces.first, let tab = space.tabs.first else {
                throw BrowserError("probe_failed", "cannot create test Space")
            }
            let sibling = await browser.handle(Request(command: "space.create", args: ["input-next"], options: ["proxy": "direct"]))
            guard sibling["ok"] as? Bool == true else { throw BrowserError("probe_failed", "cannot create sidebar peer") }
            tab.load(URL(string: CommandLine.arguments[1])!)
            try await tab.wait(selector: nil, timeout: 5000)
            try await tab.wait(selector: "#first", timeout: 5000)
            let newTab = await browser.handle(Request(command: "tab.new", args: [CommandLine.arguments[1]], options: ["space": space.record.id.uuidString]))
            guard newTab["ok"] as? Bool == true, let peer = space.tabs.last, peer !== tab else {
                throw BrowserError("probe_failed", "cannot create GUI Tab peer")
            }
            peer.setViewport(NSSize(width: 720, height: 480))
            let viewportEvidence = try await verifyViewport(tab, peer: peer, model: browser, space: space,
                directory: output.deletingLastPathComponent()) {
                let ui = ObserverWindow(model: browser, socketPath: "unused")
                observer = ui
                return ui
            }
            guard let ui = observer else { throw BrowserError("probe_failed", "no observer") }
            report["viewport"] = viewportEvidence
            ui.focusAddress(nil)
            guard let editor = ui.window.firstResponder as? NSTextView else { throw BrowserError("probe_failed", "address editor did not accept focus") }
            editor.string = "unfinished-address"
            do {
                _ = try await tab.focus(target: "#first")
                throw BrowserError("probe_failed", "input stole address focus")
            } catch let error as BrowserError where error.code == "input_focus_conflict" {}
            guard ui.window.firstResponder === editor, editor.string == "unfinished-address" else {
                throw BrowserError("probe_failed", "address editing changed")
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let table = descendants(ui.window.contentView!).first(where: { $0 is NSTableView }) as? NSTableView else {
                throw BrowserError("probe_failed", "sidebar missing")
            }
            ui.window.endEditing(for: nil)
            if foregroundTest {
                ui.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true) // Fixture setup only; production input must preserve this state.
                for _ in 0..<200 where !NSApp.isActive || !ui.window.isKeyWindow { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            guard (!foregroundTest || (NSApp.isActive && ui.window.isKeyWindow)), ui.window.makeFirstResponder(table) else {
                throw BrowserError("probe_failed", "foreground sidebar did not accept focus: active=\(NSApp.isActive) key=\(ui.window.isKeyWindow) responder=\(String(describing: ui.window.firstResponder))")
            }
            let valueBefore = try await tab.runJS("document.querySelector('#first').value") as? String
            do {
                _ = try await tab.focus(target: "#first")
                throw BrowserError("probe_failed", "input stole sidebar focus: \(String(describing: ui.window.firstResponder))")
            } catch let error as BrowserError where error.code == "input_focus_conflict" {}
            guard ui.window.firstResponder === table,
                  try await tab.runJS("document.querySelector('#first').value") as? String == valueBefore else {
                throw BrowserError("probe_failed", "sidebar responder or page changed")
            }
            let row = table.selectedRow
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ui.window.windowNumber, context: nil,
                characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
            ui.window.sendEvent(down) // Local window dispatch; never a global keyboard event.
            guard table.selectedRow == row + 1, ui.window.firstResponder === table else {
                throw BrowserError("probe_failed", "ArrowDown no longer navigates the sidebar")
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Exercise a genuine successful page focus, then move the user's focus back to the sidebar.
            ui.window.makeFirstResponder(tab.webView)
            _ = try await tab.focus(target: "#first")
            ui.window.makeFirstResponder(table)
            do {
                _ = try await tab.key(.shiftX)
                throw BrowserError("probe_failed", "key stole sidebar focus")
            } catch let error as BrowserError where error.code == "input_focus_conflict" {}
            guard ui.window.firstResponder === table,
                  try await tab.runJS("document.querySelector('#first').value") as? String == valueBefore else {
                throw BrowserError("probe_failed", "rejected key changed responder or input")
            }
            // Gate the actual asynchronous DOM callback boundary, without a timing sleep.
            ui.window.makeFirstResponder(tab.webView)
            inputHostAfterDOM = {
                ui.focusAddress(nil)
                (ui.window.firstResponder as? NSTextView)?.string = "race-address"
            }
            do {
                _ = try await tab.focus(target: "#first")
                throw BrowserError("probe_failed", "focus ignored concurrent address edit")
            } catch let error as BrowserError where error.code == "input_focus_conflict" {}
            inputHostAfterDOM = nil
            guard let raceEditor = ui.window.firstResponder as? NSTextView, raceEditor.string == "race-address" else {
                throw BrowserError("probe_failed", "concurrent address edit changed")
            }
            ui.window.endEditing(for: nil)
            ui.window.makeFirstResponder(tab.webView)
            inputHostAfterDOM = { ui.nextTab(nil) }
            do {
                _ = try await tab.focus(target: "#first")
                throw BrowserError("probe_failed", "focus accepted a concurrent GUI Tab switch")
            } catch let error as BrowserError where error.code == "input_target_changed" {}
            inputHostAfterDOM = nil
            guard tab.webView.window === tab.backingWindow,
                  try await peer.runJS("document.querySelector('#first').value") as? String == "alpha beta" else {
                throw BrowserError("probe_failed", "Tab switch input changed the peer")
            }
            ui.previousTab(nil)
            ui.window.makeFirstResponder(tab.webView)
            _ = try await tab.focus(target: "#first")
            inputHostAfterKeyState = { ui.nextTab(nil) }
            do {
                _ = try await tab.key(.shiftX)
                throw BrowserError("probe_failed", "key accepted a concurrent GUI Tab switch")
            } catch let error as BrowserError where error.code == "input_target_changed" {}
            inputHostAfterKeyState = nil
            guard try await tab.runJS("document.querySelector('#first').value") as? String == valueBefore,
                  try await peer.runJS("document.querySelector('#first').value") as? String == "alpha beta" else {
                throw BrowserError("probe_failed", "rejected Tab switch key changed a page")
            }
            ui.previousTab(nil)
            ui.window.orderOut(nil)
            originalApp?.activate(options: [])
            for _ in 0..<100 where NSApp.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            ui.window.makeFirstResponder(nil)
            _ = try await tab.focus(target: "#first")
            _ = try await tab.runJS("document.querySelector('#first').setSelectionRange(10,10);true")
            let result = try await tab.key(.shiftX)
            let value = try await tab.runJS("document.querySelector('#first').value") as? String
            guard value == "alpha betaX", result["dispatched"] as? Bool == true,
                  tab.webView.window === ui.window,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                  !NSApp.isActive, !ui.window.isKeyWindow else {
                throw BrowserError("probe_failed", "GUI key or background invariants failed")
            }
            let iframeInput = try await probeFrameInput(tab, page: URL(string: CommandLine.arguments[1])!)
            tab.deadline = monotonicNow() + 50_000_000
            do {
                _ = try await tab.runJS("new Promise(resolve=>{window.releaseLateInputProbe=()=>{window.lateInputCount=1;resolve(1)}})", awaitPromise: true)
                throw BrowserError("probe_failed", "held Promise did not time out")
            } catch let error as BrowserError where error.code == "timeout" {}
            tab.deadline = nil
            await withCheckedContinuation { continuation in
                inputHostLateCallback = { inputHostLateCallback = nil; continuation.resume() }
                tab.webView.evaluateJavaScript("releaseLateInputProbe()", completionHandler: nil)
            }
            guard tab.unresponsive else { throw BrowserError("probe_failed", "late callback changed timeout state") }
            report = ["ok": true, "guiReparented": true, "fixedViewportVerified": true, "viewport": viewportEvidence, "iframeInputProbe": iframeInput, "addressDraftPreserved": true,
                      "sidebarResponderPreserved": true, "rejectedKeyHasNoEffect": true,
                      "foregroundGUIVerified": foregroundTest,
                      "sidebarArrowNavigationPreserved": true, "concurrentTabSwitchRejected": true,
                      "lateWebKitCallbackCompletedOnce": true,
                      "concurrentAddressDraftPreserved": true,
                      "backgroundKeyVerified": true, "foregroundUnchanged": true]
        } catch { report["error"] = error.localizedDescription }
        if let model {
            for space in model.spaces {
                let deleted = await model.handle(Request(command: "space.delete", args: [space.record.id.uuidString], options: [:]))
                if deleted["ok"] as? Bool != true { report["ok"] = false; report["cleanupError"] = deleted }
            }
        }
        observer?.window.close()
        do { try jsonData(report).write(to: output, options: .atomic) }
        catch { exit(2) }
        exit(report["ok"] as? Bool == true ? 0 : 1)
    }
}

@main struct InputHostMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.last == "--cleanup-only" ? .prohibited : .regular)
        let probe = InputHostProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
