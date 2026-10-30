// Real Tab/WebKit stress test. Reflection observes bookkeeping only; no product debug API.
import AppKit
import WebKit

@MainActor
final class NavigationSpanProbe: NSObject, NSApplicationDelegate {
    private var tab: Tab!
    private var checks: [String] = []
    private var samples: [[String: Any]] = []
    private var report: [String: Any] = [:]
    private let output = URL(fileURLWithPath: CommandLine.arguments[3])

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BrowserError("probe_assertion", message) }
        checks.append(message)
    }

    private func spans() -> [Mirror] {
        let value = Mirror(reflecting: tab!).children.first { $0.label == "navigationSpans" }!.value
        return Mirror(reflecting: value).children.map { Mirror(reflecting: $0.value) }
    }

    private func currentKey() throws -> String {
        for entry in spans() {
            let pair = Array(entry.children)
            let span = Mirror(reflecting: pair[1].value)
            if span.children.first(where: { $0.label == "sequence" })!.value as! Int == tab.navigationSequence {
                return String(describing: pair[0].value)
            }
        }
        throw BrowserError("probe_assertion", "Latest navigation has no span")
    }

    private func timingFinished() -> Bool {
        let operations = tab.operationTiming!.summary["webkitOperations"] as! [[String: Any]]
        return operations.allSatisfy { $0["inProgress"] as! Int == 0 }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        tab = Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: .nonPersistent(), tls: nil)
        Task {
            do { try await run(); finish(nil) }
            catch { finish(error) }
        }
    }

    private func run() async throws {
        let base = CommandLine.arguments[1]
        var addresses = Set<String>(), reusedAddresses = 0, cancelledCallbacks = 0
        for batch in 0..<5 {
            tab.operationTiming = RequestTiming()
            _ = tab.diagnostics.snapshot(clear: true)
            for index in 0..<100 {
                let url = URL(string: base + "?delay=0.15&batch=\(batch)&n=\(index)")!
                tab.load(url)
                if !addresses.insert(try currentKey()).inserted { reusedAddresses += 1 }
                let previousSequence = tab.navigationSequence
                tab.load(url)
                guard tab.navigationSequence == previousSequence + 1 else {
                    throw BrowserError("probe_assertion", "A new token aliased a cancelled navigation")
                }
                if !addresses.insert(try currentKey()).inserted { reusedAddresses += 1 }
                // Deliver callbacks between cancellation bursts. Completion is checked below.
                if index % 10 == 0 { await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                } }
            }
            let finalURL = base + "?settle=\(batch)"
            tab.load(URL(string: finalURL)!)
            try await tab.wait(selector: nil, timeout: 10000)
            let events = tab.diagnostics.snapshot(clear: false)["events"] as! [[String: Any]]
            cancelledCallbacks += events.filter { $0["errorCode"] as? Int == NSURLErrorCancelled }.count
            samples.append(["batch": batch, "spans": spans().count, "sequence": tab.navigationSequence,
                            "timing": tab.operationTiming!.summary])
            try check(spans().isEmpty, "Batch \(batch): completed navigation reclaims orphan spans")
            try check(timingFinished(), "Batch \(batch): cancelled navigation timings have ended")
            try check(tab.state["url"] as? String == finalURL && tab.navigationError == nil,
                      "Batch \(batch): old callbacks do not poison the latest document")
        }
        try check(reusedAddresses > 0, "Allocator reused token addresses during real cancellations")
        try check(cancelledCallbacks > 0, "Real WebKit cancellation callbacks were observed")
        report["reusedAddresses"] = reusedAddresses
        report["uniqueAddresses"] = addresses.count
        report["cancelledCallbacks"] = cancelledCallbacks

        for index in 0..<10 {
            tab.load(URL(string: CommandLine.arguments[2])!)
            do {
                try await tab.wait(selector: nil, timeout: 3000)
                throw BrowserError("probe_assertion", "Refused connection unexpectedly loaded")
            } catch {
                let native = error as NSError
                try check(native.domain == NSURLErrorDomain && native.code == NSURLErrorCannotConnectToHost,
                          "Repeated failure \(index) terminates with the actual connection error")
            }
        }
        tab.load(URL(string: base + "?recovered=1")!)
        try await tab.wait(selector: nil, timeout: 10000)
        try check(tab.state["url"] as? String == base + "?recovered=1" && tab.navigationError == nil,
                  "Navigation recovers after repeated failures")

        tab.operationTiming = RequestTiming()
        tab.load(URL(string: base + "?delay=0.15&timeout=1")!)
        do {
            try await tab.wait(selector: nil, timeout: 1)
            throw BrowserError("probe_assertion", "Delayed navigation unexpectedly met a 1 ms deadline")
        } catch {
            try check((error as? BrowserError)?.code == "timeout", "Navigation wait timeout remains a timeout")
        }
        tab.load(URL(string: base + "?after-timeout=1")!)
        try await tab.wait(selector: nil, timeout: 10000)
        try check(spans().isEmpty && timingFinished(), "Explicit replacement after timeout reclaims spans and timings")

        // Explicit delegate injection is separate from the real cancellation observations.
        tab.operationTiming = RequestTiming()
        tab.load(URL(string: base + "?delay=0.15&termination=1")!)
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        try check(spans().isEmpty && timingFinished(), "Injected WebContent termination clears spans and timings")
        tab.load(URL(string: base + "?after-termination=1")!)
        try await tab.wait(selector: nil, timeout: 10000)
        try check(tab.navigationError == nil, "Explicit reload after injected termination recovers")

        tab.operationTiming = RequestTiming()
        tab.load(URL(string: base + "?delay=0.15&close=1")!)
        tab.close()
        try check(spans().isEmpty && timingFinished(), "Closing an active navigation clears spans and timings")
        report["finalSpans"] = spans().count
    }

    private func finish(_ error: Error?) -> Never {
        if !tab.closed { tab.close() }
        report.merge(["ok": error == nil, "error": error.map(String.init(describing:)) as Any? ?? NSNull(),
                      "checks": checks, "samples": samples,
                      "method": "Real nonpersistent WKWebView and product Tab; separate injected termination callback"]) { _, new in new }
        do { try jsonData(report).write(to: output, options: .atomic) }
        catch { fputs("Cannot write navigation report: \(error)\n", stderr); exit(2) }
        exit(error == nil ? 0 : 1)
    }
}

@main
struct NavigationSpanProbeEntry {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let probe = NavigationSpanProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
