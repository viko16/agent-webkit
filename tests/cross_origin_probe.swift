// Standalone spike: reuse the product DOM bridge in every frame; no product command changes.
import AppKit
import WebKit

@MainActor
final class FrameRecord {
    let slot: String
    let epoch: String
    let role: String
    let depth: Int
    let info: WKFrameInfo
    weak var view: WKWebView?
    init(slot: String, epoch: String, role: String, depth: Int, info: WKFrameInfo, view: WKWebView) {
        self.slot = slot; self.epoch = epoch; self.role = role; self.depth = depth; self.info = info; self.view = view
    }
}

@MainActor
final class FrameProbe: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var views: [String: WKWebView] = [:]
    var panels: [String: NSPanel] = [:]
    var frames: [FrameRecord] = []
    var events: [[String: Any]] = []
    var checks: [String] = []
    var observations: [String: Any] = [:]
    let originA = CommandLine.arguments[1]
    let originB = CommandLine.arguments[2]
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    var initialFocus: pid_t = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        initialFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        Task { @MainActor in
            do {
                try await run()
                finish(error: nil)
            } catch { finish(error: error) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, message.frameInfo.webView === view,
              let slot = views.first(where: { $0.value === view })?.key,
              let body = message.body as? [String: Any], let epoch = body["epoch"] as? String,
              let role = body["role"] as? String, let depth = body["depth"] as? Int else { return }
        if let old = frames.first(where: { $0.slot == slot && $0.epoch == epoch }) {
            events.append(["kind": body["kind"] ?? "repeat", "slot": slot, "epoch": epoch,
                           "sameObject": old.info === message.frameInfo, "isEqual": old.info.isEqual(message.frameInfo)])
            return
        }
        frames.append(FrameRecord(slot: slot, epoch: epoch, role: role, depth: depth, info: message.frameInfo, view: view))
        events.append(["kind": "registered", "slot": slot, "epoch": epoch, "role": role, "depth": depth,
                       "main": message.frameInfo.isMainFrame, "url": message.frameInfo.request.url?.absoluteString ?? "",
                       "origin": "\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host):\(message.frameInfo.securityOrigin.port)"])
    }

    func create(_ slot: String, store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let controller = configuration.userContentController
        controller.add(self, contentWorld: DOM.world, name: "frameProbe")
        controller.addUserScript(WKUserScript(source: DOM.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DOM.world))
        controller.addUserScript(WKUserScript(source: #"""
        (()=>{
          const epoch=Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-');
          Object.defineProperty(globalThis,'__frameProbeEpoch',{value:epoch});
          function report(kind){
            let depth=0;for(let w=window;w!==w.parent&&depth<16;w=w.parent)depth++;
            webkit.messageHandlers.frameProbe.postMessage({kind,epoch,depth,role:document.body?.dataset.role||'unknown'});
          }
          addEventListener('DOMContentLoaded',()=>report('ready'),{once:true});
          addEventListener('pagehide',()=>report('pagehide'));
        })()
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DOM.world))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view; panel.orderOut(nil)
        views[slot] = view; panels[slot] = panel
        view.load(URLRequest(url: URL(string: originA + "/root")!))
    }

    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw BrowserError("probe_assertion", label) }
        checks.append(label)
    }

    func waitFor(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BrowserError("probe_timeout", label)
    }

    func evaluate(_ view: WKWebView, frame: WKFrameInfo?, source: String, world: WKContentWorld = DOM.world,
                  awaitPromise: Bool = false, milliseconds: Double = 2000) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let operation = PendingOperation<Any>(continuation)
            operation.arm(milliseconds: milliseconds, error: BrowserError("probe_timeout", "frame callback timed out"), onTimeout: {})
            if awaitPromise {
                view.callAsyncJavaScript("return await (0,eval)(source)", arguments: ["source": source], in: frame, in: world) { result in operation.finish(result) }
            } else {
                view.evaluateJavaScript(source, in: frame, in: world) { result in operation.finish(result) }
            }
        }
    }

    func scoped(_ frame: FrameRecord, slot: String, source: String) async throws -> Any {
        guard let view = views[slot] else { throw BrowserError("tab_closed", "probe tab closed") }
        guard frame.slot == slot, frame.view === view, frame.info.webView === view else { throw BrowserError("frame_owner_mismatch", "frame belongs to another Tab") }
        // The epoch guard and DOM operation run in one JS turn, not a preflight round trip.
        let script = "(()=>{if(globalThis.__frameProbeEpoch!==\(try quoteJS(frame.epoch)))throw new Error('stale_frame');return (0,eval)(\(try quoteJS(source)))})()"
        return try await evaluate(view, frame: frame.info, source: script)
    }

    func expectStale(_ frame: FrameRecord, slot: String) async throws {
        do {
            _ = try await scoped(frame, slot: slot, source: "document.querySelector('#same').value='WRONG';true")
        } catch {
            let native = error as NSError
            let message = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            events.append(["kind": "stale-guard", "epoch": frame.epoch, "error": message, "domain": native.domain, "code": native.code])
            try check(message.contains("stale_frame") ||
                (native.domain == WKErrorDomain && native.code == WKError.Code.javaScriptInvalidFrameTarget.rawValue), "old document rejected before mutation")
            return
        }
        throw BrowserError("probe_assertion", "stale frame mutated a replacement document")
    }

    func rawObservation(_ frame: FrameRecord) async -> [String: Any] {
        guard let view = frame.view else { return ["unavailable": true] }
        do {
            let value = try await evaluate(view, frame: frame.info, source: "({epoch:globalThis.__frameProbeEpoch,url:location.href})")
            return ["value": value]
        } catch {
            let native = error as NSError
            return ["error": error.localizedDescription, "domain": native.domain, "code": native.code]
        }
    }

    func submit(_ frame: FrameRecord, value: String) async throws {
        let snapshot = try await scoped(frame, slot: frame.slot, source: "window.__agentWebKit.snapshot()") as! [String: Any]
        let elements = snapshot["elements"] as! [[String: Any]]
        let input = elements.first { $0["name"] as? String == "Frame input" }!["ref"] as! String
        let fill = try await scoped(frame, slot: frame.slot, source: "window.__agentWebKit.act('fill',\(try quoteJS(input)),\(try quoteJS(value)))") as! [String: Any]
        try check(fill["nativeVerified"] as? Bool == false, "frame fill is synthetic")
        _ = try await scoped(frame, slot: frame.slot, source: "window.__agentWebKit.act('click','#save','')")
        for _ in 0..<100 {
            let result = try await evaluate(frame.view!, frame: frame.info, source: "window.saved??null", world: .page)
            if let result = result as? [String: Any] {
                try check(result["value"] as? String == value && result["nonce"] as? String != nil, "real frame business acknowledgement")
                events.append(["kind": "business-result", "slot": frame.slot, "epoch": frame.epoch, "value": result])
                let trusted = try await evaluate(frame.view!, frame: frame.info, source: "window.inputTrusted", world: .page) as? Bool
                try check(trusted == false, "frame input event remains untrusted")
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BrowserError("probe_timeout", "business acknowledgement")
    }

    func close(_ slot: String) {
        guard let view = views.removeValue(forKey: slot) else { return }
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "frameProbe", contentWorld: DOM.world)
        view.removeFromSuperview()
        panels[slot]?.contentView = nil; panels[slot]?.close(); panels[slot] = nil
    }

    func run() async throws {
        let storeA = WKWebsiteDataStore.nonPersistent(), storeB = WKWebsiteDataStore.nonPersistent()
        create("A1", store: storeA); create("A2", store: storeA); create("B1", store: storeB)
        try await waitFor("initial frame registration") { ["A1", "A2", "B1"].allSatisfy { slot in frames.filter { $0.slot == slot }.count == 5 } }
        try check(Set(frames.map(\.epoch)).count == 15, "all documents have distinct isolated epochs")
        for frame in frames {
            let expectedPort = URL(string: frame.depth == 1 ? originB : originA)!.port!
            let expectedHost = URL(string: frame.depth == 1 ? originB : originA)!.host!
            try check(frame.info.securityOrigin.host == expectedHost && frame.info.securityOrigin.port == expectedPort && frame.info.isMainFrame == (frame.depth == 0), "native origin and main-frame metadata match the fixture")
        }
        let root = frames.first { $0.slot == "A1" && $0.depth == 0 }!
        let children = frames.filter { $0.slot == "A1" && $0.depth == 1 }
        let leaves = frames.filter { $0.slot == "A1" && $0.depth == 2 }
        try check(children.count == 2 && leaves.count == 2, "nested cross-origin registration")
        try check(children[0].info.request.url == children[1].info.request.url && children[0].epoch != children[1].epoch, "identical URLs do not identify sibling frames")
        let sop = try await scoped(root, slot: "A1", source: "document.querySelector('#one').contentDocument===null") as? Bool
        try check(sop == true, "parent DOM same-origin restriction remains active")
        let privateHandler = try await evaluate(children[0].view!, frame: children[0].info, source: "typeof window.webkit?.messageHandlers?.frameProbe", world: .page) as? String
        try check(privateHandler == "undefined", "page world cannot access probe message handler")
        let parentAccess = try await evaluate(children[0].view!, frame: children[0].info,
            source: "(()=>{try{return parent.document.body.innerHTML}catch(error){return error.name}})()", world: .page) as? String
        try check(parentAccess == "SecurityError", "target page world still cannot access cross-origin parent DOM")
        _ = try await evaluate(children[0].view!, frame: children[0].info, source: "window.__frameProbeEpoch='forged';window.__agentWebKit={snapshot:()=>({forged:true})};true", world: .page)
        let epoch = try await scoped(children[0], slot: "A1", source: "globalThis.__frameProbeEpoch") as? String
        try check(epoch == children[0].epoch, "page globals cannot replace isolated bridge epoch")
        _ = try await scoped(children[0], slot: "A1", source: "webkit.messageHandlers.frameProbe.postMessage({kind:'repeat',epoch:__frameProbeEpoch,role:document.body.dataset.role,depth:1});true")
        try await waitFor("repeat frameInfo sample") { events.contains { $0["kind"] as? String == "repeat" } }
        try await submit(children[0], value: "cross-child")
        try await submit(leaves[0], value: "nested-leaf")
        for frame in frames where frame.slot != "A1" || frame.epoch == children[1].epoch {
            let value = try await scoped(frame, slot: frame.slot, source: "document.querySelector('#same').value") as? String
            try check(value == "", "other frame/Tab/Space untouched")
        }
        for slot in ["A2", "B1"] {
            do {
                _ = try await scoped(children[0], slot: slot, source: "document.querySelector('#same').value='WRONG'")
                throw BrowserError("probe_assertion", "cross-Tab frame accepted")
            } catch let error as BrowserError { try check(error.code == "frame_owner_mismatch", "host rejects wrong Tab ownership") }
        }
        let siblingSnapshot = try await scoped(children[1], slot: "A1", source: "window.__agentWebKit.snapshot()") as! [String: Any]
        let siblingInput = (siblingSnapshot["elements"] as! [[String: Any]]).first { $0["name"] as? String == "Frame input" }!["ref"] as! String
        _ = try await scoped(children[1], slot: "A1", source: "history.pushState({},'', '?spa=1');window.__agentWebKit.act('fill',\(try quoteJS(siblingInput)),'same-document')")
        let sameDocumentValue = try await scoped(children[1], slot: "A1", source: "document.querySelector('#same').value") as? String
        try check(sameDocumentValue == "same-document", "same-document navigation keeps epoch and element reference")
        _ = try await scoped(children[1], slot: "A1", source: "const input=document.querySelector('#same');input.replaceWith(input.cloneNode());document.querySelector('#same').value='safe-clone';true")
        do {
            _ = try await scoped(children[1], slot: "A1", source: "window.__agentWebKit.act('fill',\(try quoteJS(siblingInput)),'WRONG')")
            throw BrowserError("probe_assertion", "removed element reference accepted")
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            try check(message.contains("stale_ref"), "removed cross-origin DOM reference rejected")
        }
        let clonedValue = try await scoped(children[1], slot: "A1", source: "document.querySelector('#same').value") as? String
        try check(clonedValue == "safe-clone", "stale element action leaves replacement unchanged")
        _ = try await scoped(root, slot: "A1", source: "localStorage.setItem('frame-store','A');true")
        for slot in ["A2", "B1"] {
            let frame = frames.first { $0.slot == slot && $0.depth == 0 }!
            let value = try await scoped(frame, slot: slot, source: "localStorage.getItem('frame-store')")
            try check(slot == "A2" ? value as? String == "A" : value is NSNull, "Store sharing follows Space, not Tab")
        }
        let began = monotonicNow()
        do {
            _ = try await evaluate(children[0].view!, frame: children[0].info, source: "globalThis.__frameProbePendingPromise=new Promise(()=>{})", awaitPromise: true, milliseconds: 150)
            throw BrowserError("probe_assertion", "never-settling frame Promise unexpectedly completed")
        } catch let error as BrowserError { try check(error.code == "probe_timeout", "frame Promise wait times out without replay") }
        try check(milliseconds(from: began) < 2000, "frame Promise host wait is bounded")
        let otherFrame = frames.first { $0.slot == "B1" && $0.depth == 1 }!
        let asyncEpoch = try await evaluate(otherFrame.view!, frame: otherFrame.info, source: "Promise.resolve(globalThis.__frameProbeEpoch)", awaitPromise: true) as? String
        try check(asyncEpoch == otherFrame.epoch, "other Space async frame remains usable after timeout")
        _ = try await scoped(children[0], slot: "A1", source: "location.href=\(try quoteJS(originA + "/leaf?navigation=1"));true")
        try await waitFor("child cross-origin navigation") { frames.contains { $0.slot == "A1" && $0.depth == 1 && $0.role == "leaf" } }
        let replacement = frames.first { $0.slot == "A1" && $0.depth == 1 && $0.role == "leaf" }!
        observations["oldHandleAfterNavigation"] = await rawObservation(children[0])
        try await expectStale(children[0], slot: "A1")
        let replacementValue = try await scoped(replacement, slot: "A1", source: "document.querySelector('#same').value") as? String
        try check(replacementValue == "", "replacement document not mutated by old epoch")
        var invalidLeaves = 0
        for leaf in leaves {
            let result = await rawObservation(leaf)
            if result["code"] as? Int == WKError.Code.javaScriptInvalidFrameTarget.rawValue { invalidLeaves += 1; try await expectStale(leaf, slot: "A1") }
        }
        try check(invalidLeaves == 1, "parent navigation invalidates exactly its nested frame")
        _ = try await scoped(root, slot: "A1", source: "Array.from(document.querySelectorAll('iframe')).find(f=>f.contentDocument===null).remove();true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let removed = await rawObservation(children[1])
        observations["removedFrame"] = removed
        try check(removed["code"] as? Int == WKError.Code.javaScriptInvalidFrameTarget.rawValue, "removed frame gets native invalid-frame target")
        try await expectStale(children[1], slot: "A1")
        views["A1"]!.reload()
        try await waitFor("top reload epoch") { frames.contains { $0.slot == "A1" && $0.depth == 0 && $0.epoch != root.epoch } }
        try await expectStale(root, slot: "A1"); try await expectStale(replacement, slot: "A1")
        let peer = frames.first { $0.slot == "B1" && $0.depth == 1 }!
        let peerValue = try await scoped(peer, slot: "B1", source: "document.querySelector('#same').value") as? String
        try check(peerValue == "", "other Space remains usable after reload")
        close("A1")
        do {
            _ = try await scoped(root, slot: "A1", source: "true")
            throw BrowserError("probe_assertion", "closed Tab accepted")
        } catch let error as BrowserError { try check(error.code == "tab_closed", "closed Tab rejects retained frame") }
        observations["foregroundUnchanged"] = initialFocus == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
        try check(observations["foregroundUnchanged"] as? Bool == true, "no foreground activation")
    }

    func finish(error: Error?) -> Never {
        for slot in Array(views.keys) { close(slot) }
        let native = error as NSError?
        let report: [String: Any] = ["ok": error == nil, "error": error.map { failure($0)["error"]! } ?? NSNull(),
            "nativeError": native.map { ["domain": $0.domain, "code": $0.code,
                "message": $0.userInfo["WKJavaScriptExceptionMessage"] as? String ?? $0.localizedDescription] } as Any? ?? NSNull(),
            "checks": checks, "events": events, "observations": observations,
            "spaces": 2, "tabs": 3, "nonPersistent": true, "productChanged": false]
        do { try jsonData(report).write(to: output, options: .atomic) }
        catch { fputs("Cannot write probe report: \(error)\n", stderr); exit(2) }
        exit(error == nil ? 0 : 1)
    }
}

@main
struct CrossOriginEntry {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let probe = FrameProbe(); app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}
