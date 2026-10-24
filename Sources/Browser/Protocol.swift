import Foundation
import Darwin

struct BrowserError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

struct Request: Codable {
    var command: String
    var args: [String]
    var options: [String: String]

    func validate() throws {
        let arities: [String: ClosedRange<Int>] = ["help":0...0, "version":0...0, "daemon":0...0,
            "status":0...0, "shutdown":0...0, "space.list":0...0, "space.create":1...1,
            "space.info":1...1, "space.delete":1...1, "tab.list":0...0, "tab.new":0...1,
            "tab.close":1...1, "tab.default":1...1, "open":1...1, "reload":0...0,
            "snapshot":0...0, "state":0...0, "evaluate":1...1, "click":1...1,
            "fill":2...2, "screenshot":0...0, "wait":0...1]
        guard let arity = arities[command], arity.contains(args.count) else {
            throw BrowserError("invalid_arguments", "未知命令或参数数量不正确：\(command)；browser help 查看用法")
        }
        var allowed: Set<String> = ["socket", "data-dir"]
        if !["help", "version", "daemon", "status", "shutdown"].contains(command), !command.hasPrefix("space.") {
            allowed.insert("space")
            if !command.hasPrefix("tab.") { allowed.insert("tab") }
        }
        if ["open", "reload", "tab.new", "snapshot", "evaluate", "click", "fill", "screenshot", "wait"].contains(command) { allowed.insert("timeout") }
        if command == "space.create" { allowed.formUnion(["proxy", "ca-cert", "ignore-certificate-errors"]) }
        if command == "click" { allowed.formUnion(["wait-for-navigation", "wait-for-popup"]) }
        if options["wait-for-navigation"] != nil && options["wait-for-popup"] != nil {
            throw BrowserError("invalid_arguments", "--wait-for-navigation 与 --wait-for-popup 不能同时使用")
        }
        if command == "evaluate" { allowed.insert("await") }
        if command == "wait" {
            allowed.formUnion(["url", "text", "state"])
            let conditions = ["url", "text", "state"].filter { options[$0] != nil }
            guard conditions.count <= 1,
                  options["url"] == nil || args.isEmpty,
                  options["state"] == nil || !args.isEmpty,
                  options["url"] != "", options["text"] != "" else {
                throw BrowserError("invalid_arguments", "wait 的 --url / --text / --state 只能选一个；--url 不带选择器，--state 需要选择器，URL 和文本不能为空")
            }
            if let state = options["state"], !["visible", "hidden", "attached", "detached", "enabled", "disabled"].contains(state) {
                throw BrowserError("invalid_arguments", "wait --state 支持 visible、hidden、attached、detached、enabled、disabled")
            }
        }
        if command == "screenshot" { allowed.insert("out") }
        if let key = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw BrowserError("invalid_arguments", "\(command) 不支持 --\(key)")
        }
        for key in ["await", "wait-for-navigation", "wait-for-popup", "ignore-certificate-errors"] {
            if let value = options[key], value != "true" { throw BrowserError("invalid_arguments", "--\(key) 是无值开关") }
        }
    }
}

let productVersion = "0.2.0"

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
        let allowed = Set(["space", "tab", "proxy", "ca-cert", "out", "timeout", "socket", "data-dir", "url", "text", "state"])
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--", !literal { literal = true; i += 1; continue }
            if !literal, ["--help", "-h", "--version"].contains(arg), arguments.count == 1 {
                positionals = [arg == "--version" ? "version" : "help"]; break
            }
            if arg.hasPrefix("--"), !literal {
                let key = String(arg.dropFirst(2))
                if ["ignore-certificate-errors", "wait-for-navigation", "wait-for-popup", "await"].contains(key), options[key] == nil {
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
        if ["space", "tab"].contains(command) {
            guard !positionals.isEmpty else { throw BrowserError("invalid_arguments", "需要子命令") }
            command += "." + positionals.removeFirst()
        }
        dataDirectory = URL(fileURLWithPath: options["data-dir"] ?? ProcessInfo.processInfo.environment["BROWSER_DATA_DIR"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentWebKit").path)
        socketPath = options["socket"] ?? ProcessInfo.processInfo.environment["BROWSER_SOCKET"] ?? dataDirectory.appendingPathComponent("browser.sock").path
        request = Request(command: command, args: positionals, options: options)
        try request.validate()
    }
}

let usage = """
browser daemon [--data-dir PATH] [--socket PATH]
browser status | shutdown
browser space create NAME --proxy direct|http://127.0.0.1:8899 [--ca-cert PATH | --ignore-certificate-errors]
browser space list
browser space info|delete NAME_OR_ID
browser open URL --space NAME_OR_ID [--tab ID]
browser tab new [URL] --space NAME_OR_ID
browser tab list --space NAME_OR_ID
browser tab close ID --space NAME_OR_ID
browser tab default ID --space NAME_OR_ID
browser reload --space NAME_OR_ID [--tab ID] [--timeout 15000]
browser snapshot|state --space NAME_OR_ID [--tab ID]
browser click SELECTOR_OR_REF --space NAME_OR_ID [--tab ID] [--wait-for-navigation | --wait-for-popup] [--timeout 15000]
browser fill SELECTOR_OR_REF VALUE --space NAME_OR_ID [--tab ID]
browser evaluate JAVASCRIPT --space NAME_OR_ID [--tab ID] [--await] [--timeout 15000]
browser screenshot --space NAME_OR_ID [--tab ID] --out PATH
browser wait [SELECTOR_OR_REF] --space NAME_OR_ID [--tab ID] [--timeout 15000]
browser wait --url EXACT_URL --space NAME_OR_ID
browser wait [SELECTOR_OR_REF] --text TEXT --space NAME_OR_ID
browser wait SELECTOR_OR_REF --state visible|hidden|attached|detached|enabled|disabled --space NAME_OR_ID
所有命令支持 --socket PATH。页面命令必须指定 Space；默认标签页固定，与 GUI 无关。
WebKit 操作支持 --timeout 1–60000；--await 等待 Promise；-- 后的参数按字面值处理。
browser --help | --version 无需启动服务。reload 恢复异常页面，保留 Tab ID 和 Space 网站数据。
--wait-for-popup 等待同 Space 新 Tab 并返回 newTabId；DOM 点击不保证可信用户激活或业务成功。
响应 timing 包含 cliMs、ipcRoundTripMs、serverMs、webkitMs；完整 CLI 进程耗时需由调用方测量。
"""
