// Test-only observer controls; all browser commands use the production SocketServer.
import AppKit

@MainActor
final class TerminationHost: NSObject, NSApplicationDelegate {
    var model: BrowserModel!
    var observer: ObserverWindow!
    var server: SocketServer!
    var timer: Timer?
    var lastRequest = ""
    var activated = false
    var foregroundChanged = false
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let initialForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            model = try BrowserModel(directory: directory)
            observer = ObserverWindow(model: model, socketPath: directory.appendingPathComponent("browser.sock").path)
            server = SocketServer(path: directory.appendingPathComponent("browser.sock").path)
            try server.start { [self] request in await model.handle(request) }
            Task { @MainActor in try await model.restore() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        } catch { fputs("Host startup failed: \(error)\n", stderr); exit(1) }
    }

    func applicationDidBecomeActive(_ notification: Notification) { activated = true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.finishDialogsForExit() }

    func field<T>(_ name: String, as type: T.Type) throws -> T {
        guard let value = Mirror(reflecting: observer!).children.first(where: { $0.label == name })?.value as? T else {
            throw BrowserError("probe_failed", "Observer field missing: \(name)")
        }
        return value
    }

    func poll() {
        foregroundChanged = foregroundChanged || NSWorkspace.shared.frontmostApplication?.processIdentifier != initialForeground
        guard let data = try? Data(contentsOf: output.appendingPathComponent("gui-request.json")),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = request["id"], id != lastRequest else { return }
        lastRequest = id
        do {
            switch request["action"] {
            case "select":
                guard let row = model.spaces.firstIndex(where: { $0.record.name == request["space"] }) else {
                    throw BrowserError("probe_failed", "Unknown GUI Space")
                }
                let table = try field("table", as: NSTableView.self)
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            case "hide": observer.window.performClose(nil)
            case "show": observer.window.orderBack(nil)
            case "reload":
                let retry = try field("retry", as: NSButton.self)
                guard retry.isEnabled else { throw BrowserError("probe_failed", "Recovery button disabled") }
                retry.performClick(nil)
            default: break
            }
            let banner = try field("banner", as: NSStackView.self)
            let status = try field("status", as: NSTextField.self)
            let text = try field("bannerText", as: NSTextField.self)
            let retry = try field("retry", as: NSButton.self)
            let progress = try field("progress", as: NSProgressIndicator.self)
            let security = try field("security", as: NSTextField.self)
            let result: [String: Any] = ["id": id, "ok": true, "status": status.stringValue,
                "security": security.stringValue, "securityWarning": security.textColor == NSColor.systemOrange,
                "banner": text.stringValue, "bannerVisible": !banner.isHiddenOrHasHiddenAncestor,
                "retryEnabled": retry.isEnabled,
                "progressVisible": !progress.isHiddenOrHasHiddenAncestor && progress.alphaValue > 0,
                "windowNumber": observer.window.windowNumber,
                "visible": observer.window.isVisible, "key": observer.window.isKeyWindow,
                "activated": activated, "foregroundChanged": foregroundChanged,
                "observer": model.observerState?() ?? [:]]
            try jsonData(result).write(to: output.appendingPathComponent("gui-response.json"), options: .atomic)
        } catch {
            try? jsonData(["id": id, "ok": false, "error": String(describing: error)]).write(
                to: output.appendingPathComponent("gui-response.json"), options: .atomic)
        }
    }
}

@main
struct TerminationHostEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let host = TerminationHost(); app.delegate = host
        withExtendedLifetime(host) { app.run() }
    }
}
