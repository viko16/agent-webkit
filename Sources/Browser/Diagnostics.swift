import Foundation
import WebKit

// No persistence, headers or bodies. Free-form details require temporary per-Tab opt-in.
@MainActor
final class DiagnosticLog: NSObject {
    private var events: [[String: Any]] = []
    private var nextID = 0
    private var dropped = 0
    static let limit = 200
    private var generation: String?
    private var detailExpiry: Date?
    private var detailDeadline: UInt64?
    private var expiryTask: Task<Void, Never>?
    private var navigationID = UUID().uuidString
    private var treeNavigations: [String: String] = [:]
    private var continuous = false
    private var includeInfo = false
    var captureConfigurationChanged: (() -> Void)?

    var detailGeneration: String? {
        // Background timers can be coalesced. Never accept or expose details past their deadline.
        if let expiry = detailExpiry, let deadline = detailDeadline,
           Date() >= expiry || monotonicNow() >= deadline { setDetail(false) }
        return generation
    }

    var configuration: [String: Any]? {
        guard let generation = detailGeneration, let detailExpiry else { return nil }
        return ["generation": generation, "expiresAtMs": detailExpiry.timeIntervalSince1970 * 1000, "includeInfo": includeInfo]
    }

    var documentStartConfiguration: [String: Any]? { continuous ? configuration : nil }

    func setDetail(_ enabled: Bool, continuous: Bool = false, includeInfo: Bool = false) {
        expiryTask?.cancel(); expiryTask = nil
        // Disabling also erases details already retained; preserve the existing summary ring.
        for index in events.indices { events[index].removeValue(forKey: "detail") }
        generation = enabled ? UUID().uuidString : nil
        self.continuous = enabled && continuous
        self.includeInfo = enabled && includeInfo
        detailExpiry = enabled ? Date().addingTimeInterval(300) : nil
        detailDeadline = enabled ? monotonicNow() + 300_000_000_000 : nil
        if enabled {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                self?.setDetail(false)
            }
        }
        captureConfigurationChanged?()
    }

    func beginNavigation(id: UUID?) {
        if !continuous, generation != nil { setDetail(false) }
        navigationID = (id ?? UUID()).uuidString
    }

    private static func documentIdentifier(_ raw: Any?) -> String? {
        guard let value = raw as? String, value.utf8.count == 32,
              value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return value
    }

    func associateDocumentTree(_ raw: Any?, navigation: UUID) {
        guard let tree = Self.documentIdentifier(raw), treeNavigations[tree] == nil else { return }
        if treeNavigations.count == Self.limit, let first = treeNavigations.keys.first {
            treeNavigations.removeValue(forKey: first)
        }
        let id = navigation.uuidString
        treeNavigations[tree] = id
        for index in events.indices where events[index]["documentTreeId"] as? String == tree {
            events[index]["navigationId"] = id
            if var detail = events[index]["detail"] as? [String: Any] {
                detail["navigationId"] = id
                events[index]["detail"] = detail
            }
        }
    }

    // Deliberately limited locator: no credentials, query, hash or dynamic path components.
    static func resource(_ raw: String) -> String {
        guard let url = URL(string: String(raw.prefix(2048))), origin(url) != "opaque" else { return "opaque" }
        let path = url.path.split(separator: "/").prefix(8).map { part -> String in
            let value = String(part)
            return value.range(of: "^[A-Za-z_-]{1,23}(?:\\.[A-Za-z]{1,8})?(?::[0-9]{1,7}){0,2}$", options: .regularExpression) != nil ? value : "[redacted]"
        }.joined(separator: "/")
        return origin(url) + "/" + path
    }

    static func redact(_ raw: String, limit: Int = 512) -> String {
        var value = String(raw.prefix(4096))
        // Redact URL-bearing text before key/value and token patterns.
        let urls = try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+"#)
        for match in urls.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            if let range = Range(match.range, in: value) { value.replaceSubrange(range, with: resource(String(value[range]))) }
        }
        for pattern in [#"(?i)\b(?:bearer|basic)\s+[^\s,;]+"#,
                        #"(?i)\b(?:password|passwd|token|secret|authorization|cookie|api[_-]?key)["']?\s*[=:]\s*(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s,;]+)"#,
                        #"\b[A-Za-z0-9_+/=-]{24,}\b"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(value.prefix(limit))
    }

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

    func native(_ kind: String, url: URL?, error: Error? = nil, cause: BrowserError? = nil, duration: Double? = nil, status: Int? = nil, navigationId: UUID? = nil) {
        let id = navigationId?.uuidString ?? navigationID
        var fields: [String: Any] = ["kind": kind, "origin": Self.origin(url), "navigationId": id]
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
            if detailGeneration != nil {
                let message = error.localizedDescription.isEmpty ? fields["reason"] as? String ?? "error" : error.localizedDescription
                fields["detail"] = ["message": Self.redact(message),
                                    "resource": url.map { Self.resource($0.absoluteString) } ?? "opaque",
                                    "navigationId": id]
            }
        }
        append(fields, source: "webkit")
    }

    func receive(_ body: Any, mainFrame: Bool) {
        guard let batch = body as? [String: Any], let entries = batch["events"] as? [[String: Any]] else { return }
        let generation = detailGeneration
        // Child diagnostics are opt-in and are discarded completely after disable or expiry.
        guard mainFrame || (continuous && generation != nil && batch["generation"] as? String == generation) else { return }
        let documentID = Self.documentIdentifier(batch["documentId"])
        let treeID = Self.documentIdentifier(batch["documentTreeId"])
        let nativeNavigation = treeID.flatMap { treeNavigations[$0] }
        if let count = batch["dropped"] as? Double, count.isFinite, count > 0 { dropped += Int(min(count, 1_000_000)) }
        dropped += max(0, entries.count - 100)
        // The page can forge this channel. Whitelist every retained field; never copy arbitrary data.
        let enums: [String: Set<String>] = [
            "kind": ["capture-ready", "console", "exception", "unhandled-rejection", "resource-error", "fetch", "xhr"],
            "level": includeInfo ? ["warn", "error", "log", "info"] : ["warn", "error"],
            "errorType": ["TypeError", "RangeError", "ReferenceError", "SyntaxError", "Error", "other"],
            "outcome": ["response", "rejected", "abort", "timeout", "error"],
            "resourceType": ["img", "script", "link", "audio", "video", "other"]]
        for entry in entries.prefix(100) {
            guard let kind = entry["kind"] as? String, enums["kind"]!.contains(kind) else { continue }
            if kind == "console", let level = entry["level"] as? String, !enums["level"]!.contains(level) { continue }
            var fields: [String: Any] = ["kind": kind, "mainFrame": mainFrame]
            fields["documentId"] = documentID
            fields["documentTreeId"] = treeID
            fields["navigationId"] = nativeNavigation
            for (key, choices) in enums {
                if let value = entry[key] as? String, choices.contains(value) { fields[key] = value }
            }
            for key in ["pageTimeMs", "durationMs", "status", "line", "column", "argumentCount"] {
                if let value = entry[key] as? Double, value.isFinite, (0...1_000_000_000).contains(value) { fields[key] = value }
            }
            if let raw = entry["origin"] as? String, raw.count <= 2048 {
                fields["origin"] = Self.origin(URL(string: raw))
            }
            if let generation, entry["generation"] as? String == generation,
               let raw = entry["detail"] as? [String: Any] {
                var detail: [String: Any] = ["navigationId": nativeNavigation as Any? ?? NSNull()]
                if let message = raw["message"] as? String { detail["message"] = Self.redact(message) }
                if let frames = raw["stack"] as? [String] { detail["stack"] = frames.prefix(8).map { Self.redact($0, limit: 256) } }
                if let resource = raw["resource"] as? String {
                    let unavailable = raw["resourcePathUnavailable"] as? Bool == true
                    detail["resource"] = unavailable ? Self.origin(URL(string: String(resource.prefix(2048)))) : Self.resource(resource)
                    if unavailable { detail["resourcePathUnavailable"] = true }
                }
                if let request = raw["requestId"] as? String,
                   request.range(of: "^(fetch|xhr)-[0-9]{1,10}$", options: .regularExpression) != nil {
                    detail["requestId"] = generation + ":" + (documentID ?? "unknown") + ":" + request
                }
                fields["detail"] = detail
            }
            append(fields, source: "page-script")
        }
    }

    func snapshot(clear: Bool) -> [String: Any] {
        let enabled = detailGeneration != nil
        if clear { events.removeAll(keepingCapacity: true); dropped = 0 }
        return ["events": events, "limit": Self.limit, "droppedEvents": dropped,
            "redacted": true, "persistent": false, "routeVerified": false,
            "detail": ["enabled": enabled, "expiresAtMs": detailExpiry.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? NSNull(),
                       "scope": continuous ? "tab-across-navigation" : "current-document", "includeInfo": includeInfo,
                       "maximumDurationMs": 300000, "messageLimit": 512, "stackLimit": 8],
            "coverage": ["native": "main-frame navigation responses/failures, operation deadlines and content termination",
                         "pageScript": continuous ? "document-start capture in main frame and iframes; console, exceptions, unhandled rejection, resource error, fetch and XHR"
                                                  : "main-frame console.warn/error, exceptions, unhandled rejection, resource error, fetch and XHR"],
            "limitations": ["Page-script entries can be forged, replaced or suppressed; they do not prove proxy routing.",
                "Page events carry a document ID and a document tree ID when observed. The navigation ID is attached only when the committed main document can be correlated; frame handshakes can be lost.",
                "No workers, WebSocket messages, complete resource trace or response bodies. Existing frames are enabled best-effort; page-cache restores may miss initialization.",
                "Fetch rejection may be network, CORS or policy failure; status 0 does not prove a failed request.",
                "Page batches may be delayed or lost on navigation/termination; clear only removes entries already received.",
                !enabled ? "Origins only; free-form messages, stacks and URL paths are omitted."
                    : "Opt-in details use bounded best-effort redaction, not a guarantee that arbitrary page text contains no sensitive information; page scripts remain untrusted."]]
    }
}

// Popup configurations can share a content controller. Route by WebKit's webView,
// never by a page-supplied Space/Tab ID, and do not retain closed tabs.
@MainActor
final class DiagnosticRouter: NSObject, WKScriptMessageHandler {
    static let shared = DiagnosticRouter()
    let logs = NSMapTable<WKWebView, DiagnosticLog>.weakToWeakObjects()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView else { return }
        logs.object(forKey: view)?.receive(message.body, mainFrame: message.frameInfo.isMainFrame)
    }
}

enum DiagnosticScript {
    static let name = "agentWebKitDiagnostics"
    static func source(configuration: [String: Any]?) -> String {
        guard let configuration, let data = try? jsonData(configuration) else { return source }
        return source.replacingOccurrences(of: "/* document-start mode */ null", with: String(decoding: data, as: UTF8.self))
    }

    static let source = #"""
    (() => {
      const post=window.webkit.messageHandlers.agentWebKitDiagnostics.postMessage.bind(window.webkit.messageHandlers.agentWebKitDiagnostics);
      const now=performance.now.bind(performance), apply=Reflect.apply;
      const URLType=URL, queue=[];
      const mainFrame=window===window.top;
      let dropped=0, timer=null, mode=/* document-start mode */ null, requestSequence=0;
      if(!mainFrame && !mode)return;
      const newId=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),n=>n.toString(16).padStart(2,'0')).join('');
      const documentId=newId();
      let documentTreeId=mainFrame?documentId:null;
      Object.defineProperty(window,'__agentWebKitDiagnosticTreeId',{get:()=>documentTreeId});
      const handshake='__agentWebKitDiagnosticTree';
      if(mainFrame) addEventListener('message',event=>{
        if(active() && event.data===handshake && event.source && event.source!==window)
          event.source.postMessage({[handshake]:documentTreeId},'*');
      });
      else addEventListener('message',event=>{
        if(event.source===window.top && typeof event.data?.[handshake]==='string')
          documentTreeId=event.data[handshake];
      });
      function requestTree() {
        if(!mainFrame && active()) window.top.postMessage(handshake,'*');
      }
      Object.defineProperty(window,'__agentWebKitDiagnosticMode',{configurable:true,value:config=>{
        if(timer!==null)clearTimeout(timer);
        flush(); mode=config;
        installInfoHooks();
        requestTree();
        return mode?.generation||null;
      }});
      function active() { return mode && Date.now()<mode.expiresAtMs; }
      function text(raw) {
        if(typeof raw!=='string')return '[object omitted]';
        try {
          let value=raw.slice(0,4096);
          // Values are read solely for local redaction during opt-in, never transmitted separately.
          const fields=document.querySelectorAll('input,textarea,select,[contenteditable]');
          if(fields.length>100)return '[redacted: form limit]';
          for(const field of fields) {
            const secret=typeof field.value==='string'?field.value:field.textContent;
            if(secret)value=value.split(secret.slice(0,4096)).join('[redacted]');
          }
          return value;
        } catch(_) { return '[redacted: unavailable]'; }
      }
      function details(message,error,resource,requestId) {
        if(!active())return {};
        try {
          const detail={};
          if(typeof message==='string')detail.message=text(message).slice(0,512);
          if(error && typeof error.stack==='string')detail.stack=error.stack.split('\n').slice(0,8).map(frame=>text(frame).slice(0,256));
          if(typeof resource==='string')detail.resource=text(new URLType(resource,location.href).href).slice(0,2048);
          if(requestId)detail.requestId=requestId;
          return {generation:mode.generation,detail};
        } catch(_) { return {}; }
      }
      function requestURL(raw) {
        try { return typeof raw==='string'?raw:raw instanceof URLType?raw.href:raw instanceof Request?raw.url:undefined; }
        catch(_) { return undefined; }
      }
      function origin(raw) {
        try { if(typeof raw!=='string'||!raw)return 'opaque'; const u=new URLType(raw,location.href); return /^https?:$/.test(u.protocol)?u.origin:'opaque'; }
        catch (_) { return 'opaque'; }
      }
      function flush() {
        timer=null;
        const events=queue.splice(0), lost=dropped; dropped=0;
        if(!events.length && !lost)return;
        try { post({events,dropped:lost,documentId,documentTreeId,generation:mode?.generation}); } catch (_) {}
      }
      function emit(event) {
        try {
          if(!mainFrame && !active())return;
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
      function wrapConsole(level) {
        const original=console[level];
        console[level]=function(...args) {
          if((level==='log'||level==='info') && !(active() && mode.includeInfo)) return apply(original,this,args);
          let extra={};
          if(active()) {
            try {
              const error=args.find(arg=>arg instanceof Error);
              const message=args.slice(0,4).map(arg=>typeof arg==='string'?arg:arg instanceof Error?arg.message:'[object omitted]').join(' ');
              extra=details(message,error,location.href);
            } catch(_) {}
          }
          emit({kind:'console',level,argumentCount:Math.min(args.length,100),origin:origin(location.href),...extra});
          return apply(original,this,args);
        };
      }
      let infoHooksInstalled=false;
      function installInfoHooks() {
        if(!mode?.includeInfo || infoHooksInstalled)return;
        infoHooksInstalled=true;
        for(const level of ['log','info']) wrapConsole(level);
      }
      for(const level of ['warn','error']) wrapConsole(level);
      installInfoHooks();
      addEventListener('error',event=>{
        try {
          if(event.target===window) emit({kind:'exception',errorType:errorType(event.error),origin:origin(event.filename),line:event.lineno,column:event.colno,...details(event.message,event.error,event.filename)});
          else {
            const el=event.target, tag=el.localName;
            const resource=el.currentSrc||el.src||el.href;
            emit({kind:'resource-error',resourceType:['img','script','link','audio','video'].includes(tag)?tag:'other',origin:origin(resource),...details(undefined,undefined,resource)});
          }
        } catch (_) {}
      },true);
      addEventListener('unhandledrejection',event=>{
        let extra={};
        if(active()) { try { extra=details(typeof event.reason==='string'?event.reason:event.reason?.message,event.reason,location.href); } catch(_) {} }
        emit({kind:'unhandled-rejection',errorType:errorType(event.reason),origin:origin(location.href),...extra});
      });
      const fetchOriginal=window.fetch;
      window.fetch=function(...args) {
        const start=now(), requestOrigin=origin(args[0]);
        const extra=active()?details(undefined,undefined,requestURL(args[0]),'fetch-'+(++requestSequence)):{};
        return apply(fetchOriginal,this,args).then(response=>{
          emit({kind:'fetch',outcome:'response',status:response.status,origin:origin(response.url),durationMs:now()-start,...extra});
          return response;
        },error=>{
          let failure=extra;
          if(active() && extra.generation===mode.generation) {
            try { failure=details(error?.message,error,requestURL(args[0]),extra.detail.requestId); } catch(_) {}
          }
          emit({kind:'fetch',outcome:'rejected',errorType:errorType(error),origin:requestOrigin,durationMs:now()-start,...failure});
          throw error;
        });
      };
      const xhrOrigins=new WeakMap(), xhrResources=new WeakMap(), open=XMLHttpRequest.prototype.open, send=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(...args) {
        const result=apply(open,this,args); xhrOrigins.set(this,origin(args[1]));
        xhrResources.set(this,active()?details(undefined,undefined,requestURL(args[1])):{}); return result;
      };
      XMLHttpRequest.prototype.send=function(...args) {
        const xhr=this, start=now(), requestOrigin=xhrOrigins.get(xhr)||'opaque';
        const saved=xhrResources.get(xhr);
        // Capture each send under its current generation; never recover URLs opened while capture was off.
        const extra=active()?{generation:mode.generation,detail:{
          ...(saved?.generation===mode.generation?saved.detail:{resource:requestOrigin,resourcePathUnavailable:true}),
          requestId:'xhr-'+(++requestSequence)
        }}:{};
        const terminalEvents=['load','error','abort','timeout'];
        let finished=false;
        function clean() {
          xhr.removeEventListener('readystatechange',ready,true);
          for(const name of terminalEvents) xhr.removeEventListener(name,ended,true);
        }
        function finish(outcome) {
          if(finished)return;
          finished=true;
          clean();
          emit({kind:'xhr',outcome,status:xhr.status,origin:requestOrigin,durationMs:now()-start,...extra});
        }
        // Capture before ordinary page callbacks can reopen/send this same object.
        // Status 0 needs the terminal event to distinguish load/error/abort/timeout.
        function ready() { if(xhr.readyState===4 && xhr.status!==0)finish('response'); }
        function ended(event) { finish(event.type==='load'?'response':event.type); }
        xhr.addEventListener('readystatechange',ready,true);
        for(const name of terminalEvents) xhr.addEventListener(name,ended,true);
        try { return apply(send,this,args); } catch(error) { clean(); throw error; }
      };
      addEventListener('pagehide',()=>{if(timer!==null)clearTimeout(timer);flush();});
      addEventListener('pageshow',event=>{
        if(!event.persisted)return;
        documentTreeId=mainFrame?newId():null;
        requestTree();
      });
      requestTree();
      emit({kind:'capture-ready',origin:origin(location.href)});
    })();
    """#
}
