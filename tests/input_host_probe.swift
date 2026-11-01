// Real GUI reparenting and unfinished address protection, without activating the app.
import AppKit

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
        do {
            let browser = try BrowserModel(directory: output.deletingLastPathComponent().appendingPathComponent("host-state"))
            model = browser
            try await browser.restore()
            let created = await browser.handle(Request(command: "space.create", args: ["input-host"], options: ["proxy": "direct"]))
            guard created["ok"] as? Bool == true, let space = browser.spaces.first, let tab = space.tabs.first else {
                throw BrowserError("probe_failed", "cannot create test Space")
            }
            let ui = ObserverWindow(model: browser, socketPath: "unused"); observer = ui
            tab.load(URL(string: CommandLine.arguments[1])!)
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
            report = ["ok": true, "guiReparented": true, "addressDraftPreserved": true,
                      "backgroundKeyVerified": true, "foregroundUnchanged": true]
        } catch { report["error"] = error.localizedDescription }
        if let model {
            let deleted = await model.handle(Request(command: "space.delete", args: ["input-host"], options: [:]))
            if deleted["ok"] as? Bool != true { report["ok"] = false; report["cleanupError"] = deleted }
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
        app.setActivationPolicy(.prohibited)
        let probe = InputHostProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
