import AppKit
import Foundation

@MainActor
final class Application: NSObject, NSApplicationDelegate {
    let options: Options
    var model: BrowserModel?
    var observer: ObserverWindow?
    var server: SocketServer?
    init(_ options: Options) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try BrowserModel(directory: options.dataDirectory)
            self.model = model
            observer = ObserverWindow(model: model)
            let server = SocketServer(path: options.socketPath)
            try server.start { [model] request in await model.handle(request) }
            self.server = server
            Task { @MainActor in
                do { try await model.restore() }
                catch { fputs("Restore failed: \(error)\n", stderr); NSApp.terminate(nil) }
            }
            print(String(decoding: try jsonData(["ok":true,"result":["socket":options.socketPath,"pid":ProcessInfo.processInfo.processIdentifier]]), as: UTF8.self))
            fflush(stdout)
        } catch {
            print(String(decoding: (try? jsonData(failure(error))) ?? Data(), as: UTF8.self)); fflush(stdout)
            exit(1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        observer?.window.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { for space in model?.spaces ?? [] { try model?.save(space) } }
        catch { fputs("Failed to save: \(error)\n", stderr) }
        return .terminateNow
    }
}

let cliStartedAt = monotonicNow()
MainActor.assumeIsolated {
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty, Bundle.main.bundleIdentifier == "local.agent-webkit.browser" { arguments = ["daemon"] }
    let options = try Options(arguments)
    if options.request.command == "daemon" {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Application(options)
        app.delegate = delegate
        let menu = NSMenu()
        let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Agent WebKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    } else if options.request.command == "help" {
        print(String(decoding: try jsonData(["ok":true,"result":["usage":usage]]), as: UTF8.self))
    } else {
        let ipcStartedAt = monotonicNow()
        let data = try sendRequest(options.request, path: options.socketPath)
        let ipcFinishedAt = monotonicNow()
        guard var response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserError("invalid_response", "服务端未返回 JSON 对象")
        }
        var timing = response["timing"] as? [String: Any] ?? [:]
        timing["ipcRoundTripMs"] = milliseconds(from: ipcStartedAt, to: ipcFinishedAt)
        timing["cliMs"] = milliseconds(from: cliStartedAt)
        response["timing"] = timing
        print(String(decoding: try jsonData(response), as: UTF8.self))
        exit(response["ok"] as? Bool == true ? 0 : 1)
    }
} catch {
    var response = failure(error)
    response["timing"] = ["cliMs": milliseconds(from: cliStartedAt)]
    print(String(decoding: (try? jsonData(response)) ?? Data(), as: UTF8.self)); exit(1)
}
}
