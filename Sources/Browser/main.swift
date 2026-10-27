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
            observer = ObserverWindow(model: model, socketPath: options.socketPath)
            configureMenu()
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
    private func configureMenu() {
        let menu = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); item.submenu = submenu; menu.addItem(item); return submenu
        }
        let app = section("Agent WebKit")
        app.addItem(withTitle: "关于 Agent WebKit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Agent WebKit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 Agent WebKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = section("文件")
        let newTab = file.addItem(withTitle: "新建标签页", action: #selector(ObserverWindow.newTab(_:)), keyEquivalent: "t")
        newTab.target = observer
        let location = file.addItem(withTitle: "打开网址…", action: #selector(ObserverWindow.focusAddress(_:)), keyEquivalent: "l")
        location.target = observer
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = section("编辑")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let view = section("显示")
        let reload = view.addItem(withTitle: "重新加载页面", action: #selector(ObserverWindow.reloadPage), keyEquivalent: "r")
        reload.target = observer
        let sidebar = view.addItem(withTitle: "显示／隐藏侧边栏", action: #selector(ObserverWindow.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]; sidebar.target = observer
        let search = view.addItem(withTitle: "搜索 Space", action: #selector(ObserverWindow.focusSpaces(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = [.command, .shift]; search.target = observer
        for (title, selector, key) in [("下一个标签页", #selector(ObserverWindow.nextTab(_:)), "]"), ("上一个标签页", #selector(ObserverWindow.previousTab(_:)), "[")] {
            let item = view.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]; item.target = observer
        }
        let windows = section("窗口")
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows; NSApp.mainMenu = menu
    }
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
        print(String(decoding: try jsonData(["ok":true,"result":try CLIContract.help(options.request.args)]), as: UTF8.self))
    } else if options.request.command == "capabilities" {
        print(String(decoding: try jsonData(["ok":true,"result":CLIContract.capabilities]), as: UTF8.self))
    } else if options.request.command == "version" {
        print(String(decoding: try jsonData(["ok":true,"result":["version":productVersion]]), as: UTF8.self))
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
