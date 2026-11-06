import Foundation
import Darwin

struct BrowserError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

// A finite set of public-AppKit key behaviors; not a general shortcut or text-input API.
enum BackgroundKey: String, CaseIterable {
    case enter = "Enter", tab = "Tab", escape = "Escape", left = "ArrowLeft"
    case right = "ArrowRight", up = "ArrowUp", down = "ArrowDown"
    case backspace = "Backspace", delete = "Delete"
    case shiftLeft = "Shift+ArrowLeft", optionLeft = "Option+ArrowLeft"
    case controlB = "Control+B", shiftX = "Shift+X"
}

struct Request: Codable {
    var command: String
    var args: [String]
    var options: [String: String]

    static let arities: [String: ClosedRange<Int>] = ["help":0...2, "capabilities":0...0, "version":0...0, "daemon":0...0,
            "status":0...0, "shutdown":0...0, "space.list":0...0, "space.create":1...1,
            "space.info":1...1, "space.delete":1...1, "tab.list":0...0, "tab.new":0...1,
            "tab.close":1...1, "tab.default":1...1, "open":1...1, "reload":0...0,
            "snapshot":0...0, "state":0...0, "evaluate":1...1, "click":1...1,
            "fill":2...2, "screenshot":0...0, "wait":0...1, "diagnostics":0...0,
            "dialog.list":0...0, "dialog.respond":2...2, "space.suspend":1...1, "space.resume":1...1,
            "download.list":0...0, "download.wait":1...1, "download.cancel":1...1, "upload":2...17, "frame.list":0...0,
            "focus":1...1, "key":1...1, "viewport.get":0...0, "viewport.set":2...2,
            "back":0...0, "forward":0...0, "scroll":2...2, "select":2...2, "check":1...1, "uncheck":1...1]

    static let clientOptions: Set<String> = ["socket", "data-dir"]
    static let frameCommands = ["snapshot", "click", "fill", "wait", "scroll", "select", "check", "uncheck"]
    static let explicitTabCommands = ["focus", "key", "viewport.set", "back", "forward", "scroll", "select", "check", "uncheck"]

    static func allowedOptions(for command: String, includingClientOptions: Bool = false) -> Set<String> {
        var allowed: Set<String> = includingClientOptions ? clientOptions : []
        if !["help", "capabilities", "version", "daemon", "status", "shutdown"].contains(command), !command.hasPrefix("space.") {
            allowed.insert("space")
            if !command.hasPrefix("tab.") { allowed.insert("tab") }
        }
        if (["open", "reload", "tab.new", "evaluate", "screenshot", "frame.list", "focus", "key", "back", "forward"] + frameCommands).contains(command) { allowed.insert("timeout") }
        if frameCommands.contains(command) { allowed.insert("frame") }
        if command == "snapshot" { allowed.formUnion(["scope", "interactive", "role", "name"]) }
        if command == "space.create" { allowed.formUnion(["proxy", "ca-cert", "ignore-certificate-errors"]) }
        if command == "click" { allowed.formUnion(["wait-for-navigation", "wait-for-popup"]) }
        if ["open", "reload"].contains(command) { allowed.insert("fail-on-http-error") }
        if command == "evaluate" { allowed.insert("await") }
        if command == "wait" { allowed.formUnion(["url", "url-pattern", "fn", "stable-for", "text", "state"]) }
        if command == "screenshot" { allowed.formUnion(["out", "element", "full-page"]) }
        if command == "shutdown" { allowed.insert("all") }
        if command == "download.wait" { allowed.insert("timeout") }
        if command == "upload" { allowed.insert("timeout") }
        if command.hasPrefix("viewport.") { allowed.insert("timeout") }
        if command == "diagnostics" { allowed.formUnion(["clear", "detail", "include-info", "inspectable"]) }
        if command == "dialog.respond" { allowed.insert("text") }
        return allowed
    }

    func validate() throws {
        guard let arity = Self.arities[command], arity.contains(args.count) else {
            throw BrowserError("invalid_arguments", "未知命令或参数数量不正确：\(command)；awb help 查看用法")
        }
        let allowed = Self.allowedOptions(for: command)
        if Self.explicitTabCommands.contains(command), options["tab"]?.isEmpty != false {
            throw BrowserError("invalid_arguments", "\(command) 必须显式指定 --tab")
        }
        if ["focus", "key"].contains(command), options["frame"] != nil {
            throw BrowserError("invalid_arguments", "focus/key 仅支持主文档和开放 Shadow Root；iframe 可用 fill/click 或手动接管")
        }
        if command == "key", BackgroundKey(rawValue: args[0]) == nil {
            throw BrowserError("unsupported_key", "支持的后台按键：\(BackgroundKey.allCases.map(\.rawValue).joined(separator: ", "))；通用快捷键和 IME 未支持")
        }
        if command == "viewport.set", !args.allSatisfy({ Int($0).map { (100...4096).contains($0) } == true }) {
            throw BrowserError("invalid_arguments", "viewport set 的宽高均须为 100–4096 的整数")
        }
        if command == "scroll", !args.allSatisfy({ Int($0).map { (-100_000...100_000).contains($0) } == true }) {
            throw BrowserError("invalid_arguments", "scroll 需要两个 -100000–100000 的 CSS px 整数偏移")
        }
        if let frame = options["frame"], frame.isEmpty || options["tab"] == nil {
            throw BrowserError("invalid_arguments", "--frame 需要非空文档 ID 和显式 --tab；先用 frame list 确认目标")
        }
        if command == "snapshot" {
            guard options["scope"] != "", (options["scope"]?.utf8.count ?? 0) <= 512,
                  (options["role"] == nil) == (options["name"] == nil),
                  options["role"] != "", (options["role"]?.utf8.count ?? 0) <= 64,
                  options["name"] != "", (options["name"]?.count ?? 0) <= 200,
                  (options["name"]?.utf8.count ?? 0) <= 800 else {
                throw BrowserError("invalid_arguments", "snapshot 的 --scope 需要非空选择器或引用；--role 与 --name 必须成对提供")
            }
        }
        if options["element"] != nil && options["full-page"] != nil { throw BrowserError("invalid_arguments", "--element 与 --full-page 互斥") }
        if command == "shutdown", options["all"] != "true" {
            throw BrowserError("invalid_arguments", "shutdown 会退出全部 Space；先用 status 查看 shutdownImpact，确认全局退出意图后使用 shutdown --all")
        }
        if command == "dialog.respond", !["accept", "dismiss"].contains(args[1]) {
            throw BrowserError("invalid_arguments", "dialog respond 的响应必须为 accept 或 dismiss")
        }
        if let detail = options["detail"], !["on", "continuous", "off"].contains(detail) {
            throw BrowserError("invalid_arguments", "--detail 支持 on、continuous 或 off")
        }
        if options["detail"] == "continuous", options["tab"]?.isEmpty != false {
            throw BrowserError("invalid_arguments", "跨导航诊断必须显式指定 --tab")
        }
        if options["include-info"] != nil, !["on", "continuous"].contains(options["detail"] ?? "") {
            throw BrowserError("invalid_arguments", "--include-info 需要同时启用详细诊断")
        }
        if let inspectable = options["inspectable"], !["on", "off"].contains(inspectable) {
            throw BrowserError("invalid_arguments", "--inspectable 支持 on 或 off")
        }
        if options["detail"] != nil && options["inspectable"] != nil {
            throw BrowserError("invalid_arguments", "每次只能修改详细模式或 Inspector 开关之一")
        }
        if options["wait-for-navigation"] != nil && options["wait-for-popup"] != nil {
            throw BrowserError("invalid_arguments", "--wait-for-navigation 与 --wait-for-popup 不能同时使用")
        }
        if options["frame"] != nil && options["wait-for-navigation"] != nil {
            throw BrowserError("invalid_arguments", "--frame 不能与 --wait-for-navigation 同时使用；子文档跳转后重新 frame list，确认新文档 ID，再用 wait 等待对应条件；不会执行点击")
        }
        if command == "wait" {
            let standalone = ["url", "url-pattern", "fn"]
            let conditions = (standalone + ["text", "state"]).filter { options[$0] != nil }
            guard conditions.count <= 1,
                  args.isEmpty || !standalone.contains(where: { options[$0] != nil }),
                  options["state"] == nil || !args.isEmpty,
                  !conditions.contains(where: { options[$0]?.isEmpty == true }),
                  (options["url-pattern"]?.utf8.count ?? 0) <= 512,
                  options["url-pattern"]?.utf8.contains(0) != true,
                  (options["fn"]?.utf8.count ?? 0) <= 4096 else {
                throw BrowserError("invalid_arguments", "wait 只能选一个条件；--url / --url-pattern / --fn 不带选择器，--state 需要选择器；模式/函数上限 512/4096 字节")
            }
            if let state = options["state"], !["visible", "hidden", "attached", "detached", "enabled", "disabled"].contains(state) {
                throw BrowserError("invalid_arguments", "wait --state 支持 visible、hidden、attached、detached、enabled、disabled")
            }
            if let stable = options["stable-for"] {
                guard let value = Int(stable), (1...60000).contains(value),
                      value <= (Int(options["timeout"] ?? "15000") ?? 60000) else {
                    throw BrowserError("invalid_arguments", "--stable-for 必须为 1–60000 ms，且不超过 --timeout")
                }
            }
        }
        if let key = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw BrowserError("invalid_arguments", "\(command) 不支持 --\(key)")
        }
        for key in Self.flags {
            if let value = options[key], value != "true" { throw BrowserError("invalid_arguments", "--\(key) 是无值开关") }
        }
    }

    static let flags: Set<String> = ["await", "wait-for-navigation", "wait-for-popup", "ignore-certificate-errors", "clear", "all", "full-page", "include-info", "fail-on-http-error", "interactive"]
}

// Single version source; packaging reads it through `awb version`.
let productVersion = "0.2.1"

func jsonData(_ value: Any) throws -> Data {
    // Foundation can raise an Objective-C exception for non-finite JS numbers.
    // Wrapping the value permits scalar fragments while validating the full tree.
    guard JSONSerialization.isValidJSONObject([value]) else {
        throw BrowserError("invalid_json_result", "结果无法表示为 JSON（例如 Infinity、NaN 或不支持的对象）")
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
}

func quoteJS(_ value: String) throws -> String {
    String(decoding: try jsonData(value), as: UTF8.self)
}

func failure(_ error: Error) -> [String: Any] {
    ["ok": false, "error": ["code": (error as? BrowserError)?.code ?? "operation_failed",
                            "message": error.localizedDescription]]
}

struct Options {
    var request: Request
    var dataDirectory: URL
    var socketPath: String
    init(_ arguments: [String]) throws {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var i = 0
        var literal = false
        let allowed = Set(["space", "tab", "frame", "proxy", "ca-cert", "out", "timeout", "socket", "data-dir", "url", "url-pattern", "fn", "stable-for", "text", "state", "detail", "inspectable", "element", "scope", "role", "name"])
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--", !literal { literal = true; i += 1; continue }
            if !literal, ["--help", "-h", "--version"].contains(arg), arguments.count == 1 {
                positionals = [arg == "--version" ? "version" : "help"]; break
            }
            if arg.hasPrefix("--"), !literal {
                let key = String(arg.dropFirst(2))
                if Request.flags.contains(key), options[key] == nil {
                    options[key] = "true"; i += 1; continue
                }
                guard allowed.contains(key), i + 1 < arguments.count, options[key] == nil else {
                    throw BrowserError("invalid_arguments", "未知、重复或缺少值的参数：\(arg)")
                }
                i += 1; options[key] = arguments[i]
            } else { positionals.append(arg) }
            i += 1
        }
        var command = positionals.isEmpty ? "help" : positionals.removeFirst()
        if ["space", "tab", "frame", "dialog", "download", "viewport"].contains(command) {
            guard !positionals.isEmpty else { throw BrowserError("invalid_arguments", "需要子命令") }
            command += "." + positionals.removeFirst()
        }
        dataDirectory = URL(fileURLWithPath: options["data-dir"] ?? ProcessInfo.processInfo.environment["BROWSER_DATA_DIR"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentWebKit").path)
        socketPath = options["socket"] ?? ProcessInfo.processInfo.environment["BROWSER_SOCKET"] ?? dataDirectory.appendingPathComponent("browser.sock").path
        for key in Request.clientOptions { options[key] = nil }
        request = Request(command: command, args: positionals, options: options)
        try request.validate()
    }
}

let usage = """
awb help [COMMAND [SUBCOMMAND]] | capabilities
awb daemon [--data-dir PATH] [--socket PATH]
awb status | shutdown --all
awb space create NAME --proxy direct|http://127.0.0.1:<PORT> [--ca-cert PATH | --ignore-certificate-errors]
  PORT: 1–65535; each Space retains its own proxy across restarts (e.g. 8899).
awb space list
awb space info|delete NAME_OR_ID
awb space suspend|resume NAME_OR_ID
awb open URL --space NAME_OR_ID [--tab ID] [--fail-on-http-error]
awb tab new [URL] --space NAME_OR_ID
awb tab list --space NAME_OR_ID
awb tab close ID --space NAME_OR_ID
awb tab default ID --space NAME_OR_ID
awb reload --space NAME_OR_ID [--tab ID] [--timeout 15000] [--fail-on-http-error]
awb back|forward --space NAME_OR_ID --tab ID
awb snapshot --space NAME_OR_ID [--tab ID] [--scope SELECTOR_OR_REF] [--interactive] [--role ROLE --name NAME]
awb state --space NAME_OR_ID [--tab ID]
awb frame list --space NAME_OR_ID [--tab ID] [--timeout 15000]
awb snapshot|click|fill|wait|scroll|select|check|uncheck ... --space NAME_OR_ID --tab ID --frame FRAME_DOCUMENT_ID
awb diagnostics --space NAME_OR_ID [--tab ID] [--clear] [--detail on|continuous|off [--include-info] | --inspectable on|off]
awb dialog list --space NAME_OR_ID [--tab ID]
awb dialog respond ID accept|dismiss --space NAME_OR_ID [--tab ID] [--text PROMPT_VALUE]
awb download list --space NAME_OR_ID [--tab ID]
awb download wait|cancel ID --space NAME_OR_ID [--tab ID]
awb upload SELECTOR_OR_REF FILE_PATH [FILE_PATH ...] --space NAME_OR_ID [--tab ID]
awb click SELECTOR_OR_REF --space NAME_OR_ID [--tab ID] [--wait-for-navigation | --wait-for-popup] [--timeout 15000]
awb fill SELECTOR_OR_REF VALUE --space NAME_OR_ID [--tab ID]
awb scroll DX DY --space NAME_OR_ID --tab ID
awb select SELECTOR_OR_REF VALUE --space NAME_OR_ID --tab ID
awb check|uncheck SELECTOR_OR_REF --space NAME_OR_ID --tab ID
awb focus SELECTOR_OR_REF --space NAME_OR_ID --tab ID [--timeout 15000]
awb key KEY --space NAME_OR_ID --tab ID [--timeout 15000]
awb evaluate JAVASCRIPT --space NAME_OR_ID [--tab ID] [--await] [--timeout 15000]
awb screenshot --space NAME_OR_ID [--tab ID] --out PATH [--element SELECTOR_OR_REF | --full-page]
awb viewport get --space NAME_OR_ID [--tab ID]
awb viewport set WIDTH HEIGHT --space NAME_OR_ID --tab ID
awb wait [SELECTOR_OR_REF] --space NAME_OR_ID [--tab ID] [--timeout 15000]
awb wait --url EXACT_URL --space NAME_OR_ID
awb wait --url-pattern GLOB | --fn FUNCTION [--stable-for MS] --space NAME_OR_ID
awb wait [SELECTOR_OR_REF] --text TEXT --space NAME_OR_ID
awb wait SELECTOR_OR_REF --state visible|hidden|attached|detached|enabled|disabled --space NAME_OR_ID
所有命令支持 --socket PATH。页面命令必须指定 Space；默认标签页固定，与 GUI 无关。
WebKit 操作支持 --timeout 1–60000；--await 等待 Promise；-- 后的参数按字面值处理。
--frame 与 --wait-for-navigation 不能组合；子文档跳转后重新 frame list 确认新文档，再 wait 验证。
awb --help | --version 无需启动服务。reload 恢复异常页面，保留 Tab ID 和 Space 网站数据。
--wait-for-popup 等待同 Space 新 Tab 并返回 newTabId；DOM 点击不保证可信用户激活或业务成功。
响应 timing 包含 cliMs、ipcRoundTripMs、serverMs、webkitMs；完整 CLI 进程耗时需由调用方测量。
"""
