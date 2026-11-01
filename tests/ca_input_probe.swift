import Foundation
import Darwin

struct BrowserError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

#if CA_READ_OBSERVATION
// Only the test copy of TLS.swift uses this wrapper; production has no test hook.
final class ObservedFileHandle {
    static var reads: [[String: Int]] = []
    private let handle: Foundation.FileHandle
    private var grew = false

    init(fileDescriptor: Int32, closeOnDealloc: Bool) {
        handle = Foundation.FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: closeOnDealloc)
    }

    func read(upToCount count: Int) throws -> Data? {
        // Grow after the product's fstat, before its first read.
        if !grew, let path = ProcessInfo.processInfo.environment["CA_PROBE_GROW_PATH"] {
            grew = true
            let writer = try Foundation.FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: Data(repeating: 32, count: 2 * 1_048_576))
        }
        // Force short reads to exercise the remaining budget across multiple calls.
        let result = try handle.read(upToCount: min(count, 32_768))
        Self.reads.append(["requested": count, "returned": result?.count ?? 0])
        return result
    }

    func close() throws { try handle.close() }
}
#endif

@main struct CAInputProbe {
    static func main() throws {
        var result: [String: Any]
        do {
            let path = try JSONDecoder().decode(String.self, from: Data(CommandLine.arguments[1].utf8))
            let tls = try TLSConfiguration(path: path)
            result = ["ok": true, "der": tls.certificateDER!.base64EncodedString()]
        } catch {
            result = ["ok": false, "code": (error as? BrowserError)?.code ?? "operation_failed",
                      "message": error.localizedDescription]
        }
        #if CA_READ_OBSERVATION
        result["reads"] = ObservedFileHandle.reads
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
