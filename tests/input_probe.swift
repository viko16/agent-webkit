// Standalone public-API spike. Never activates a window or posts global input.
import AppKit
import WebKit

@MainActor
final class InputProbe: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    let origin = CommandLine.arguments[1]
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    var views: [String: WKWebView] = [:]
    var panels: [String: NSPanel] = [:]
    var messages: [[String: Any]] = []
    var samples: [[String: Any]] = []
    var checks: [String] = []
    var foreground: pid_t = -1
    var foregroundChanged = false
    var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.foreground { self.foregroundChanged = true }
            }
        }
        Task { @MainActor in
            do { try await run(); finish(nil) } catch { finish(error) }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, message.frameInfo.isMainFrame,
              let slot = views.first(where: { $0.value === view })?.key,
              var body = message.body as? [String: Any], body["slot"] as? String == slot else { return }
        body["hostSlot"] = slot
        messages.append(body)
    }

    func create(_ slot: String, store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store
        configuration.userContentController.add(self, name: "inputProbe")
        configuration.userContentController.addUserScript(WKUserScript(source: DOM.bootstrap,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DOM.world))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
        panel.contentView = view; panel.orderOut(nil)
        views[slot] = view; panels[slot] = panel
        view.load(URLRequest(url: URL(string: origin + "/input-probe.html?slot=" + slot)!))
    }

    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw BrowserError("probe_assertion", label) }
        checks.append(label)
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BrowserError("probe_timeout", "page observation timed out")
    }

    func js(_ slot: String, _ source: String, world: WKContentWorld, awaitPromise: Bool = false, milliseconds: Double = 2000) async throws -> Any {
        guard let view = views[slot] else { throw BrowserError("tab_closed", "probe tab closed") }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = PendingOperation<Any>(continuation)
            operation.arm(milliseconds: milliseconds, onTimeout: {})
            if awaitPromise {
                view.callAsyncJavaScript(source, arguments: [:], in: nil, in: world) { operation.finish($0) }
            } else { view.evaluateJavaScript(source, in: nil, in: world) { operation.finish($0) } }
        }
    }

    func observe(_ label: String, slot: String = "A1") async throws -> [String: Any] {
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = messages.count
        try await wait { self.messages.dropFirst(start).contains { $0["kind"] as? String == "heartbeat" && $0["label"] as? String == label && $0["hostSlot"] as? String == slot } }
        return messages.dropFirst(start).last { $0["kind"] as? String == "heartbeat" && $0["label"] as? String == label && $0["hostSlot"] as? String == slot }!
    }

    func reset(_ label: String, slot: String = "A1") async throws {
        let start = messages.count
        views[slot]!.load(URLRequest(url: URL(string: origin + "/input-probe.html?slot=" + slot + "&trial=" + label)!))
        try await wait { self.messages.dropFirst(start).contains { $0["kind"] as? String == "loaded" && $0["hostSlot"] as? String == slot } }
        let loaded = messages.dropFirst(start).last { $0["kind"] as? String == "loaded" && $0["hostSlot"] as? String == slot }!
        let activation = loaded["activation"] as! [String: Any]
        try check(activation["active"] as? Bool == false && activation["sticky"] as? Bool == false, label + ": fresh document has no user activation")
    }

    func record(_ label: String, _ state: [String: Any], slot: String = "A1") throws {
        let panel = panels[slot]!
        let sample: [String: Any] = ["label": label, "hostSlot": slot, "state": state, "windowVisible": panel.isVisible,
            "keyWindow": panel.isKeyWindow, "appActive": NSApp.isActive,
            "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
        samples.append(sample)
        try check(!panel.isVisible && !panel.isKeyWindow && !NSApp.isActive, label + ": hidden non-key inactive host")
        try check(!foregroundChanged && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, label + ": foreground unchanged")
    }

    func mouse(_ route: String, x: CGFloat, y: CGFloat) throws {
        let view = views["A1"]!, panel = panels["A1"]!
        let point = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let windowPoint = view.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0) else { throw BrowserError("event_creation", "mouse event unavailable") }
        switch route {
        case "window": panel.sendEvent(event)
        case "view": view.mouseMoved(with: event)
        default:
            guard let target = view.hitTest(point) else { throw BrowserError("hit_test", "no public hit-test responder") }
            target.mouseMoved(with: event)
        }
    }

    func key(_ route: String, characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil, slot: String = "A1") throws {
        guard let panel = panels[slot], let view = views[slot], view.window === panel else {
            throw BrowserError("tab_closed", "probe target Tab unavailable")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code)
            else { throw BrowserError("event_creation", "key event unavailable") }
            if route == "window" { panel.sendEvent(event) }
            else {
                let target = route == "view" ? view : panel.firstResponder
                guard let target else { throw BrowserError("first_responder", "missing responder") }
                if route == "equivalent" && type == .keyDown {
                    try check(view.performKeyEquivalent(with: event), "public performKeyEquivalent accepted Command-A")
                } else if type == .keyDown { target.keyDown(with: event) } else { target.keyUp(with: event) }
            }
        }
    }

    func run() async throws {
        let storeA = WKWebsiteDataStore.nonPersistent(), storeB = WKWebsiteDataStore.nonPersistent()
        create("A1", store: storeA); create("A2", store: storeA); create("B1", store: storeB)
        try await wait { Set(self.messages.filter { $0["kind"] as? String == "loaded" }.compactMap { $0["slot"] as? String }).count == 3 }
        for route in ["synthetic", "window", "view", "hit-test"] {
            let label = route + "-hover"
            try await reset(label)
            if route != "synthetic" { try mouse(route, x: 80, y: 70) }
            try record(label, await observe(label))
            if route != "synthetic" { try mouse(route, x: 400, y: 400) }
            try record(label + "-outside", await observe(label))
        }
        for route in ["synthetic", "window", "view", "responder"] {
            for (name, characters, code, flags, ignoring) in [
                ("enter", "\r", UInt16(36), NSEvent.ModifierFlags(), "\r"),
                ("tab", "\t", 48, [], "\t"), ("escape", "\u{1b}", 53, [], "\u{1b}"),
                ("shift-left", "\u{f702}", 123, .shift, "\u{f702}"),
                ("option-left", "\u{f702}", 123, .option, "\u{f702}"),
                ("control-b", "\u{2}", 11, .control, "b"),
                ("command-a", "a", 0, .command, "a"), ("shift-x", "X", 7, .shift, "x")
            ] {
                let label = route + "-" + name
                try await reset(label)
                if route != "synthetic" {
                    let accepted = panels["A1"]!.makeFirstResponder(views["A1"]!)
                    try check(accepted, label + ": makeFirstResponder accepted without key window")
                    try key(route, characters: characters, code: code, flags: flags, ignoring: ignoring)
                }
                try record(label, await observe(label))
            }
        }
        try await reset("equivalent-command-a")
        try check(panels["A1"]!.makeFirstResponder(views["A1"]!), "key equivalent first responder accepted")
        try key("equivalent", characters: "a", code: 0, flags: .command)
        try record("equivalent-command-a", await observe("equivalent-command-a"))
        try await reset("window-cancel-tab")
        try check(panels["A1"]!.makeFirstResponder(views["A1"]!), "cancelable Tab first responder accepted")
        try key("window", characters: "\t", code: 48)
        try record("window-cancel-tab", await observe("window-cancel-tab"))
        // Current product bridge is measured separately from timer-originated DOM events.
        try await reset("product-fill")
        _ = try await js("A1", "window.__agentWebKit.act('fill','#first','product-value')", world: DOM.world)
        try record("product-fill", await observe("product-fill"))
        _ = try await js("A1", "window.__agentWebKit.act('click','#save','')", world: DOM.world)
        try await wait { self.messages.contains { $0["kind"] as? String == "business-result" && $0["label"] as? String == "product-fill" } }
        try record("product-click", await observe("product-fill"))
        for slot in ["A2", "B1"] {
            // Hidden idle WebViews can throttle timers. These reads are not activation evidence.
            let state = try await js(slot, "window.probeRead()", world: .page) as! [String: Any]
            try check((state["events"] as? [[String: Any]])?.isEmpty == true && state["value"] as? String == "", slot + ": no foreign input or business result")
        }
        try await reset("reload")
        try record("reload", await observe("reload"))
        do {
            _ = try await js("A1", "globalThis.probePending=new Promise(()=>{});return await probePending", world: .page,
                             awaitPromise: true, milliseconds: 150)
            throw BrowserError("probe_assertion", "pending JS unexpectedly completed")
        } catch let error as BrowserError { try check(error.code == "timeout", "pending JS host wait bounded; no input replay") }
        close("A1")
        do { try key("window", characters: "X", code: 7); throw BrowserError("probe_assertion", "closed Tab accepted") }
        catch let error as BrowserError { try check(error.code == "tab_closed", "closed Tab rejected") }
        try await reset("peer-after-close", slot: "B1")
        try check(panels["B1"]!.makeFirstResponder(views["B1"]!), "other Space first responder accepted after close")
        try key("window", characters: "X", code: 7, flags: .shift, ignoring: "x", slot: "B1")
        let peer = try await observe("peer-after-close", slot: "B1")
        try check(peer["value"] as? String == "alpha betaX", "explicit other Space receives native key after target close")
        try record("peer-after-close", peer, slot: "B1")
        let untouched = try await js("A2", "window.probeRead()", world: .page) as! [String: Any]
        try check(untouched["value"] as? String == "" && (untouched["events"] as? [[String: Any]])?.isEmpty == true, "other Tab remains untouched after Space switch")
        try check(!foregroundChanged && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                  "foreground unchanged through the final isolation read")
    }

    func close(_ slot: String) {
        guard let view = views.removeValue(forKey: slot) else { return }
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "inputProbe")
        view.removeFromSuperview(); panels[slot]?.contentView = nil; panels[slot]?.close(); panels[slot] = nil
    }

    func finish(_ error: Error?) -> Never {
        for slot in Array(views.keys) { close(slot) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        let native = error as NSError?
        let report: [String: Any] = ["ok": error == nil, "error": native.map { $0.userInfo["WKJavaScriptExceptionMessage"] as? String ?? $0.localizedDescription } as Any? ?? NSNull(),
            "checks": checks, "samples": samples, "messages": messages, "foregroundPID": foreground,
            "foregroundChanged": foregroundChanged, "spaces": 2, "tabs": 3, "productChanged": false]
        do { try jsonData(report).write(to: output, options: .atomic) }
        catch { fputs("Cannot write input report: \(error)\n", stderr); exit(2) }
        exit(error == nil ? 0 : 1)
    }
}

@main
struct InputProbeEntry {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let probe = InputProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
