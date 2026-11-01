// Real responder and WebKit races; foreground fixture setup is explicitly opt-in.
import AppKit

@MainActor var inputHostAfterDOM: (() async -> Void)?
@MainActor var inputHostLateCallback: (() -> Void)?
@MainActor var inputHostAfterKeyState: (() async -> Void)?

@MainActor
final class InputHostProbe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
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
            let ui = ObserverWindow(model: browser, socketPath: "unused"); observer = ui
            tab.load(URL(string: CommandLine.arguments[1])!)
            try await tab.wait(selector: nil, timeout: 5000)
            try await tab.wait(selector: "#first", timeout: 5000)
            guard tab.webView.window === ui.window else { throw BrowserError("probe_failed", "view was not reparented into GUI") }
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
            let newTab = await browser.handle(Request(command: "tab.new", args: [CommandLine.arguments[1]], options: ["space": space.record.id.uuidString]))
            guard newTab["ok"] as? Bool == true, let peer = space.tabs.last, peer !== tab else {
                throw BrowserError("probe_failed", "cannot create GUI Tab peer")
            }
            try await peer.wait(selector: nil, timeout: 5000)
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
            report = ["ok": true, "guiReparented": true, "addressDraftPreserved": true,
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
        app.setActivationPolicy(ProcessInfo.processInfo.environment["BROWSER_TEST_FOREGROUND"] == "1" ? .regular : .prohibited)
        let probe = InputHostProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
