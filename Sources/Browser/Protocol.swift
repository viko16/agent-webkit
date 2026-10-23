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
}

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
        let allowed = Set(["space", "tab", "proxy", "ca-cert", "out", "timeout", "socket", "data-dir"])
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if ["ignore-certificate-errors", "wait-for-navigation"].contains(key), options[key] == nil {
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
browser snapshot|state --space NAME_OR_ID [--tab ID]
browser click SELECTOR_OR_REF --space NAME_OR_ID [--tab ID] [--wait-for-navigation] [--timeout 15000]
browser fill SELECTOR_OR_REF VALUE --space NAME_OR_ID [--tab ID]
browser evaluate JAVASCRIPT --space NAME_OR_ID [--tab ID]
browser screenshot --space NAME_OR_ID [--tab ID] --out PATH
browser wait [SELECTOR_OR_REF] --space NAME_OR_ID [--tab ID] [--timeout 15000]
所有命令支持 --socket PATH。页面命令必须指定 Space；默认标签页固定，与 GUI 无关。
响应 timing 包含 cliMs、ipcRoundTripMs、serverMs、webkitMs；完整 CLI 进程耗时需由调用方测量。
"""
