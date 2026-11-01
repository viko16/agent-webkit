import Foundation
import WebKit

struct FrameDocument {
    let id = UUID().uuidString
    let epoch: String
    let info: WKFrameInfo
}

/// Handles identify documents, never URLs or transient WKFrameInfo identities.
@MainActor
final class FrameStore: NSObject {
    static let limit = 128
    private(set) var documents: [FrameDocument] = []
    private(set) var evicted = 0

    func reset() { documents.removeAll(); evicted = 0 }
    func remove(_ id: String) { documents.removeAll { $0.id == id } }

    func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: String],
              let epoch = body["epoch"], epoch.count == 32,
              epoch.allSatisfy({ $0.isHexDigit }), let kind = body["kind"] else { return }
        if kind == "leave" { documents.removeAll { $0.epoch == epoch }; return }
        guard kind == "register", !documents.contains(where: { $0.epoch == epoch }) else { return }
        if documents.count == Self.limit { documents.removeFirst(); evicted += 1 }
        documents.append(FrameDocument(epoch: epoch, info: message.frameInfo))
    }
}

@MainActor
final class FrameRouter: NSObject, WKScriptMessageHandler {
    static let shared = FrameRouter()
    let stores = NSMapTable<WKWebView, FrameStore>.weakToWeakObjects()
    static let name = "agentWebKitFrames"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, message.frameInfo.webView === view else { return }
        stores.object(forKey: view)?.receive(message)
    }

    static let script = #"""
    (() => {
      if (globalThis.__agentWebKitFrame) return;
      const newEpoch=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),n=>n.toString(16).padStart(2,'0')).join('');
      const state={epoch:newEpoch(),active:true};
      Object.defineProperty(globalThis,'__agentWebKitFrame',{value:state});
      const report=kind=>webkit.messageHandlers.agentWebKitFrames.postMessage({kind,epoch:state.epoch});
      // A page-cache restore must not revive a handle even if its leave message was lost.
      addEventListener('pagehide',()=>{state.active=false;report('leave');state.epoch=newEpoch()});
      addEventListener('pageshow',()=>{state.active=true;report('register')});
      report('register');
    })();
    """#
}

extension Tab {
    func frameList() async throws -> [String: Any] {
        var result: [[String: Any]] = []
        for document in frames.documents {
            do {
                var metadata = try await runJS("({url:location.href.slice(0,2048),title:document.title.slice(0,200)})",
                    world: DOM.world, frameID: document.id) as? [String: Any] ?? [:]
                metadata["frameId"] = document.id
                metadata["mainFrame"] = document.info.isMainFrame
                // Public WKFrameInfo has no parent identity. Do not infer it from URLs/depth.
                metadata["parentFrameId"] = NSNull()
                result.append(metadata)
            } catch let error as BrowserError where error.code == "stale_frame" { continue }
        }
        return ["frames": result, "limit": FrameStore.limit, "truncated": frames.evicted > 0,
                "evictedDocuments": frames.evicted, "parentRouting": false,
                "identity": "document; scoped to this Space/Tab; not persisted"]
    }
}
