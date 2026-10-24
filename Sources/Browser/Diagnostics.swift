import Foundation
import WebKit

// No persistence, raw messages, stacks, headers, bodies, URL paths or query strings.
@MainActor
final class DiagnosticLog: NSObject {
    private var events: [[String: Any]] = []
    private var nextID = 0
    private var dropped = 0
    static let limit = 200

    static func origin(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, host.count <= 253 else { return "opaque" }
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = host; parts.port = url.port
        return parts.string ?? "opaque"
    }

    func append(_ fields: [String: Any], source: String) {
        nextID += 1
        var event = fields
        event["id"] = nextID
        event["source"] = source
        event["receivedAtMs"] = Date().timeIntervalSince1970 * 1000
        if events.count == Self.limit { events.removeFirst(); dropped += 1 }
        events.append(event)
    }

    func native(_ kind: String, url: URL?, error: Error? = nil, cause: BrowserError? = nil, duration: Double? = nil, status: Int? = nil) {
        var fields: [String: Any] = ["kind": kind, "origin": Self.origin(url)]
        if let duration { fields["durationMs"] = duration }
        if let status { fields["status"] = status }
        if let error {
            let ns = error as NSError
            fields["errorDomain"] = [NSURLErrorDomain, WKError.errorDomain, NSCocoaErrorDomain].contains(ns.domain) ? ns.domain : "other"
            fields["errorCode"] = ns.code
            let reasons = [NSURLErrorTimedOut: "timeout", NSURLErrorCannotFindHost: "host_not_found",
                NSURLErrorCannotConnectToHost: "connection_failed", NSURLErrorNetworkConnectionLost: "connection_lost",
                NSURLErrorNotConnectedToInternet: "offline", NSURLErrorCancelled: "cancelled",
                NSURLErrorServerCertificateUntrusted: "certificate_rejected", NSURLErrorSecureConnectionFailed: "tls_failed"]
            let code = cause?.code ?? (error as? BrowserError)?.code ?? ""
            let known = ["certificate_rejected", "direct_system_proxy_conflict", "unsupported_navigation", "web_content_terminated", "timeout"]
            fields["reason"] = known.contains(code) ? code : ns.domain == NSURLErrorDomain ? reasons[ns.code] ?? "network_error" : "webkit_error"
        }
        append(fields, source: "webkit")
    }

    func receive(_ body: Any) {
        guard let batch = body as? [String: Any], let entries = batch["events"] as? [[String: Any]] else { return }
        if let count = batch["dropped"] as? Double, count.isFinite, count > 0 { dropped += Int(min(count, 1_000_000)) }
        dropped += max(0, entries.count - 100)
        // The page can forge this channel. Whitelist every retained field; never copy arbitrary data.
        let enums: [String: Set<String>] = [
            "kind": ["capture-ready", "console", "exception", "unhandled-rejection", "resource-error", "fetch", "xhr"],
            "level": ["warn", "error"],
            "errorType": ["TypeError", "RangeError", "ReferenceError", "SyntaxError", "Error", "other"],
            "outcome": ["response", "rejected", "abort", "timeout", "error"],
            "resourceType": ["img", "script", "link", "audio", "video", "other"]]
        for entry in entries.prefix(100) {
            guard let kind = entry["kind"] as? String, enums["kind"]!.contains(kind) else { continue }
            var fields: [String: Any] = ["kind": kind]
            for (key, choices) in enums {
                if let value = entry[key] as? String, choices.contains(value) { fields[key] = value }
            }
            for key in ["pageTimeMs", "durationMs", "status", "line", "column", "argumentCount"] {
                if let value = entry[key] as? Double, value.isFinite, (0...1_000_000_000).contains(value) { fields[key] = value }
            }
            if let raw = entry["origin"] as? String, raw.count <= 2048 {
                fields["origin"] = Self.origin(URL(string: raw))
            }
            append(fields, source: "page-script")
        }
    }

    func snapshot(clear: Bool) -> [String: Any] {
        if clear { events.removeAll(keepingCapacity: true); dropped = 0 }
        return ["events": events, "limit": Self.limit, "droppedEvents": dropped,
            "redacted": true, "persistent": false, "routeVerified": false,
            "coverage": ["native": "main-frame navigation responses/failures, operation deadlines and content termination",
                         "pageScript": "main-frame console.warn/error, exceptions, unhandled rejection, resource error, fetch and XHR"],
            "limitations": ["Page-script entries can be forged, replaced or suppressed; they do not prove proxy routing.",
                "No frames, workers, WebSocket messages, complete resource trace, console text or response bodies.",
                "Fetch rejection may be network, CORS or policy failure; status 0 does not prove a failed request.",
                "Page batches may be delayed or lost on navigation/termination; clear only removes entries already received.",
                "Origins are retained; URL credentials/paths/query/hash and all free-form error messages are omitted."]]
    }
}

// Popup configurations can share a content controller. Route by WebKit's webView,
// never by a page-supplied Space/Tab ID, and do not retain closed tabs.
@MainActor
final class DiagnosticRouter: NSObject, WKScriptMessageHandler {
    static let shared = DiagnosticRouter()
    let logs = NSMapTable<WKWebView, DiagnosticLog>.weakToWeakObjects()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView else { return }
        logs.object(forKey: view)?.receive(message.body)
    }
}

enum DiagnosticScript {
    static let name = "agentWebKitDiagnostics"
    static let source = #"""
    (() => {
      const post=window.webkit.messageHandlers.agentWebKitDiagnostics.postMessage.bind(window.webkit.messageHandlers.agentWebKitDiagnostics);
      const now=performance.now.bind(performance), apply=Reflect.apply;
      const URLType=URL, queue=[];
      let dropped=0, timer=null;
      function origin(raw) {
        try { if(typeof raw!=='string'||!raw)return 'opaque'; const u=new URLType(raw,location.href); return /^https?:$/.test(u.protocol)?u.origin:'opaque'; }
        catch (_) { return 'opaque'; }
      }
      function flush() {
        timer=null;
        const events=queue.splice(0), lost=dropped; dropped=0;
        try { post({events,dropped:lost}); } catch (_) {}
      }
      function emit(event) {
        try {
          if(queue.length<100) queue.push({...event,pageTimeMs:now()}); else dropped++;
          if(timer===null) timer=setTimeout(flush,100);
        } catch (_) {}
      }
      function errorType(error) {
        try {
          for(const Type of [TypeError,RangeError,ReferenceError,SyntaxError,Error]) if(error instanceof Type) return Type.name;
        } catch (_) {}
        return 'other';
      }
      for(const level of ['warn','error']) {
        const original=console[level];
        console[level]=function(...args) {
          emit({kind:'console',level,argumentCount:Math.min(args.length,100),origin:origin(location.href)});
          return apply(original,this,args);
        };
      }
      addEventListener('error',event=>{
        try {
          if(event.target===window) emit({kind:'exception',errorType:errorType(event.error),origin:origin(event.filename),line:event.lineno,column:event.colno});
          else {
            const el=event.target, tag=el.localName;
            emit({kind:'resource-error',resourceType:['img','script','link','audio','video'].includes(tag)?tag:'other',origin:origin(el.currentSrc||el.src||el.href)});
          }
        } catch (_) {}
      },true);
      addEventListener('unhandledrejection',event=>emit({kind:'unhandled-rejection',errorType:errorType(event.reason),origin:origin(location.href)}));
      const fetchOriginal=window.fetch;
      window.fetch=function(...args) {
        const start=now(), requestOrigin=origin(args[0]);
        return apply(fetchOriginal,this,args).then(response=>{
          emit({kind:'fetch',outcome:'response',status:response.status,origin:origin(response.url),durationMs:now()-start});
          return response;
        },error=>{
          emit({kind:'fetch',outcome:'rejected',errorType:errorType(error),origin:requestOrigin,durationMs:now()-start});
          throw error;
        });
      };
      const xhrOrigins=new WeakMap(), open=XMLHttpRequest.prototype.open, send=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(...args) {
        const result=apply(open,this,args); xhrOrigins.set(this,origin(args[1])); return result;
      };
      XMLHttpRequest.prototype.send=function(...args) {
        const xhr=this, start=now(); let outcome='response';
        const failed=event=>{outcome=event.type;};
        function clean() {
          for(const name of ['error','abort','timeout']) xhr.removeEventListener(name,failed);
          xhr.removeEventListener('loadend',ended);
        }
        function ended() {
          clean();
          emit({kind:'xhr',outcome,status:xhr.status,origin:xhrOrigins.get(xhr)||'opaque',durationMs:now()-start});
        }
        for(const name of ['error','abort','timeout']) xhr.addEventListener(name,failed);
        xhr.addEventListener('loadend',ended);
        try { return apply(send,this,args); } catch(error) { clean(); throw error; }
      };
      addEventListener('pagehide',()=>{if(timer!==null)clearTimeout(timer);flush();});
      emit({kind:'capture-ready',origin:origin(location.href)});
    })();
    """#
}
