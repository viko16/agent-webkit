// Exercise the product bridge in real WebKit. Only the test bootstrap exposes Map size.
import AppKit
import WebKit

@MainActor
final class DOMReferenceProbe: NSObject, NSApplicationDelegate {
    private var tabs: [Tab] = []
    private var checks: [String] = []
    private var samples: [[String: Any]] = []
    private let output = URL(fileURLWithPath: CommandLine.arguments[2])

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BrowserError("probe_assertion", message) }
        checks.append(message)
    }

    private func makeTab(store: WKWebsiteDataStore) -> Tab {
        let tab = Tab(record: TabRecord(id: UUID(), url: "about:blank"), store: store, tls: nil)
        tabs.append(tab); return tab
    }

    private func open(_ tab: Tab, _ url: String) async throws {
        tab.load(URL(string: url)!); try await tab.wait(selector: nil, timeout: 10000)
    }

    private func snapshot(_ tab: Tab) async throws -> [[String: Any]] {
        let value = try await tab.runJS("window.__agentWebKit.snapshot()", world: DOM.world) as! [String: Any]
        return value["elements"] as! [[String: Any]]
    }

    private func ref(_ elements: [[String: Any]], _ name: String) throws -> String {
        guard let ref = elements.first(where: { $0["name"] as? String == name })?["ref"] as? String else {
            throw BrowserError("probe_assertion", "Missing snapshot element: \(name)")
        }
        return ref
    }

    private func act(_ tab: Tab, _ kind: String, _ ref: String, _ value: String = "") async throws {
        _ = try await tab.runJS("window.__agentWebKit.act(\(try quoteJS(kind)),\(try quoteJS(ref)),\(try quoteJS(value)))", world: DOM.world)
    }

    private func stale(_ tab: Tab, _ ref: String, _ message: String) async throws {
        do {
            _ = try await tab.runJS("Boolean(window.__agentWebKit.resolve(\(try quoteJS(ref))));", world: DOM.world)
            throw BrowserError("probe_assertion", message + ": old reference resolved")
        } catch { try check((error as? BrowserError)?.code == "stale_ref", message) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); finish(nil) }
            catch { finish(error) }
        }
    }

    private func run() async throws {
        let base = CommandLine.arguments[1], store = WKWebsiteDataStore.nonPersistent()
        let tab = makeTab(store: store), peer = makeTab(store: store), other = makeTab(store: .nonPersistent())
        for target in tabs { try await open(target, base + "/index.html") }
        let peerRef = try ref(await snapshot(peer), "Save message")
        let otherRef = try ref(await snapshot(other), "Save message")
        _ = try await tab.runJS("document.body.innerHTML='<input id=current aria-label=Current><output id=result></output>';window.saved=0;true")
        let instrumented = DOM.bootstrap
            .replacingOccurrences(of: "if (window.__agentWebKit) return;", with: "delete window.__agentWebKit;")
            .replacingOccurrences(of: "window.__agentWebKit={snapshot", with: "window.__agentWebKit={refCount:()=>nodes.size,snapshot")
        _ = try await tab.runJS(instrumented, world: DOM.world)
        var previous = "", current = ""
        for batch in 0..<8 {
            _ = try await tab.runJS("""
                document.querySelectorAll('button').forEach(el=>el.hidden=true);
                for(let i=0;i<500;i++) {
                  const el=document.createElement('button');el.id='b-\(batch)-'+i;el.textContent='Batch \(batch) '+i;
                  el.onclick=()=>{document.querySelector('#result').textContent=String(++window.saved)};
                  document.body.prepend(el);
                }
                // Current controls precede historical nodes so the existing scan
                // budget cannot truncate the input used to verify this snapshot.
                document.body.prepend(document.querySelector('#current'));true
                """)
            let start = monotonicNow(), elements = try await snapshot(tab)
            let count = try await tab.runJS("window.__agentWebKit.refCount()", world: DOM.world) as! Int
            samples.append(["batch": batch, "refs": count, "snapshotMs": milliseconds(from: start), "connectedButtons": (batch + 1) * 500])
            try check(count == 501 && elements.count == 501, "Batch \(batch): connected historical nodes do not enlarge the reference Map")
            current = try ref(elements, "Batch \(batch) 0")
            let input = try ref(elements, "Current")
            try await act(tab, "click", current)
            try await act(tab, "fill", input, "value-\(batch)")
            let values = try await tab.runJS("[window.saved,document.querySelector('#current').value]") as! [Any]
            try check(values[0] as? Int == batch + 1 && values[1] as? String == "value-\(batch)", "Batch \(batch): newest snapshot supports click and fill")
            let repeated = try await snapshot(tab)
            try check(try ref(repeated, "Batch \(batch) 0") == current && ref(repeated, "Current") == input,
                      "Batch \(batch): repeated snapshot keeps current node identities")
            if !previous.isEmpty { try await stale(tab, previous, "Batch \(batch): a connected node omitted from the latest snapshot is stale") }
            previous = current
        }
        _ = try await tab.runJS("document.querySelector('#b-7-0').remove();true")
        try await stale(tab, current, "Removed node becomes stale before another snapshot")
        _ = try await tab.runJS("document.querySelectorAll('button').forEach(el=>el.remove());true")
        _ = try await snapshot(tab)
        try check(try await tab.runJS("window.__agentWebKit.refCount()", world: DOM.world) as? Int == 1,
                  "Next snapshot releases removed nodes")
        try await stale(peer, current, "References cannot cross Tabs sharing a Store")
        try await stale(other, current, "References cannot cross Stores")
        try await act(peer, "fill", "#message", "peer")
        try await act(peer, "click", peerRef)
        try await act(other, "fill", "#message", "other")
        try await act(other, "click", otherRef)
        try check(try await peer.runJS("document.querySelector('#result').textContent") as? String == "peer", "Peer Tab retains its references and click result")
        try check(try await other.runJS("document.querySelector('#result').textContent") as? String == "other", "Other Store retains its references and click result")

        try await open(tab, base + "/contexts")
        try await tab.wait(selector: "#frame >>> #inner >>> input", timeout: 10000)
        let contexts = try await snapshot(tab)
        let shadow = try ref(contexts, "Shadow input"), frame = try ref(contexts, "Frame input")
        let nested = try ref(contexts, "Frame shadow input"), main = try ref(contexts, "Main input")
        _ = try await snapshot(tab)
        try await act(tab, "fill", shadow, "shadow")
        try await act(tab, "click", ref(contexts, "Shadow button"))
        try await act(tab, "fill", frame, "frame")
        try await act(tab, "click", ref(contexts, "Frame button"))
        try await act(tab, "fill", nested, "nested")
        let actual = try await tab.runJS("[document.querySelector('#host').shadowRoot.querySelector('output').textContent,document.querySelector('#frame').contentDocument.querySelector('#result').textContent,document.querySelector('#frame').contentDocument.querySelector('#inner').shadowRoot.querySelector('input').value]") as! [String]
        try check(actual == ["shadow", "frame", "nested"], "Repeated snapshot preserves same-origin frame and open shadow actions")
        _ = try await tab.runJS("new Promise(resolve=>{const f=document.querySelector('#frame');f.onload=()=>resolve(true);f.src='/context-frame?new=1'})", awaitPromise: true)
        try await stale(tab, frame, "Frame navigation invalidates the old frame reference")
        try await stale(tab, nested, "Frame navigation invalidates nested shadow references")
        try await open(tab, base + "/contexts?reload=1")
        try await stale(tab, main, "Full navigation invalidates the old document reference")
        let beforeRecovery = try ref(await snapshot(tab), "Main input")
        // Recovery creates a fresh real WebView, matching release/recreation of a Tab runtime.
        tab.close()
        let recovered = makeTab(store: store)
        try await open(recovered, base + "/contexts?recovery=1")
        try await stale(recovered, beforeRecovery, "Explicit WebView recreation invalidates old document references")
        let afterRecovery = try ref(await snapshot(recovered), "Main input")
        try await act(recovered, "fill", afterRecovery, "recovered")
        try check(try await recovered.runJS("document.querySelector('#same').value") as? String == "recovered", "New snapshot works after explicit WebView recreation")
    }

    private func finish(_ error: Error?) -> Never {
        for tab in tabs where !tab.closed { tab.close() }
        let report: [String: Any] = ["ok": error == nil, "error": error.map(String.init(describing:)) as Any? ?? NSNull(),
                                    "checks": checks, "samples": samples,
                                    "method": "Real WKWebView and product DOM bootstrap; test-only Map count; explicit WebView recreation"]
        do { try jsonData(report).write(to: output, options: .atomic) }
        catch { fputs("Cannot write DOM reference report: \(error)\n", stderr); exit(2) }
        exit(error == nil ? 0 : 1)
    }
}

@main
struct DOMReferenceProbeEntry {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let probe = DOMReferenceProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
