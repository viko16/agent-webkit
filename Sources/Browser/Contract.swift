import Foundation

// Static discovery only: importing this contract never creates AppKit or WebKit objects.
enum CLIContract {
    private static let arguments: [String: [String]] = [
        "help": ["COMMAND", "SUBCOMMAND"], "space.create": ["NAME"],
        "space.info": ["NAME_OR_ID"], "space.delete": ["NAME_OR_ID"],
        "space.suspend": ["NAME_OR_ID"], "space.resume": ["NAME_OR_ID"],
        "download.wait": ["ID"], "download.cancel": ["ID"],
        "upload": ["SELECTOR_OR_REF"] + (1...16).map { "FILE_PATH_\($0)" },
        "tab.new": ["URL"], "tab.close": ["ID"], "tab.default": ["ID"],
        "open": ["URL"], "evaluate": ["JAVASCRIPT"], "click": ["SELECTOR_OR_REF"],
        "fill": ["SELECTOR_OR_REF", "VALUE"], "wait": ["SELECTOR_OR_REF"], "dialog.respond": ["ID", "ACTION"]
    ]
    private static let optionDetails: [String: [String: Any]] = [
        "socket": ["type": "string", "description": "Unix socket path; overrides BROWSER_SOCKET"],
        "data-dir": ["type": "string", "description": "Registry directory; overrides BROWSER_DATA_DIR"],
        "space": ["type": "string", "description": "Explicit Space name or UUID"],
        "tab": ["type": "string", "description": "Tab UUID in this Space; omitted uses fixed CLI default, never GUI selection"],
        "frame": ["type": "string", "description": "Document ID from frame list in this Space/Tab; requires explicit --tab; snapshot/click/fill/wait only; stale_frame after navigation/removal/eviction; >>> remains same-origin; visibility is document-local"],
        "timeout": ["type": "integer", "unit": "ms", "minimum": 1, "maximum": 60000, "default": 15000],
        "proxy": ["type": "string", "description": "direct or http://127.0.0.1:PORT (1–65535); required at creation"],
        "ca-cert": ["type": "string", "description": "Single PEM/DER CA path; preserves system trust checks"],
        "ignore-certificate-errors": ["type": "flag", "description": "Explicit development-only TLS bypass for this Space"],
        "out": ["type": "string", "description": "PNG output path on daemon host"],
        "element": ["type": "string", "description": "Unique selector or full snapshot ref; scroll into view, crop visible border box through same-origin frame/open shadow scopes, then restore scrolling; unsupported frame transforms reject"],
        "full-page": ["type": "flag", "description": "Bounded vertical viewport tiles; max height 16000 CSS px, 32 million output pixels; restore scrolling; reject horizontal overflow or changing dimensions; fixed/sticky content may repeat; not atomic"],
        "all": ["type": "flag", "description": "Required explicit intent to stop the shared daemon and every Space; preview status.shutdownImpact first"],
        "await": ["type": "flag", "description": "Await the evaluated Promise within timeout"],
        "wait-for-navigation": ["type": "flag", "description": "Wait for navigation after one DOM click; not business verification"],
        "wait-for-popup": ["type": "flag", "description": "Wait for same-Space popup; value.newTabId identifies it, not login success"],
        "url": ["type": "string", "description": "Nonempty exact location.href, including SPA query/hash"],
        "text": ["type": "string", "description": "wait: nonempty visible innerText substring; dialog respond: prompt input (empty allowed), only with accept"],
        "state": ["type": "string", "enum": ["visible", "hidden", "attached", "detached", "enabled", "disabled"]],
        "clear": ["type": "flag", "description": "Clear received in-memory diagnostics before returning the snapshot"],
        "detail": ["type": "string", "enum": ["on", "off"], "description": "Opt-in bounded redacted details for this Tab's current document, at most 300000 ms; navigation/restart resets; off erases retained details"],
        "inspectable": ["type": "string", "enum": ["on", "off"], "description": "Public WKWebView.isInspectable for manual Safari investigation; off by default; no automatic Inspector launch; resets with view replacement/close/restart"]
    ]

    static func help(_ path: [String]) throws -> [String: Any] {
        guard !path.isEmpty else { return ["usage": usage] }
        let target = path.joined(separator: ".")
        let names = Request.arities.keys.sorted().filter { $0 == target || $0.hasPrefix(target + ".") }
        guard !names.isEmpty else { throw BrowserError("invalid_arguments", "未知帮助主题：\(path.joined(separator: " "))") }
        return ["usage": names.map(synopsis).joined(separator: "\n"), "commands": names.map(command)]
    }

    private static func requiredOptions(_ name: String) -> [String] {
        var keys = Request.allowedOptions(for: name).contains("space") ? ["space"] : []
        if name == "space.create" { keys.append("proxy") }
        if name == "screenshot" { keys.append("out") }
        if name == "shutdown" { keys.append("all") }
        return keys
    }

    private static func synopsis(_ name: String) -> String {
        let arity = Request.arities[name]!
        let args = (arguments[name] ?? []).enumerated().map { i, arg in i < arity.lowerBound ? arg : "[\(arg)]" }
        let flags = requiredOptions(name).map { optionDetails[$0]?["type"] as? String == "flag" ? "--\($0)" : "--\($0) VALUE" }
        return (["awb", name.replacingOccurrences(of: ".", with: " ")] + args + flags).joined(separator: " ")
    }

    private static func command(_ name: String) -> [String: Any] {
        let arity = Request.arities[name]!
        let required = requiredOptions(name)
        let options = Request.allowedOptions(for: name, includingClientOptions: true).sorted().map { key -> [String: Any] in
            var detail = optionDetails[key]!
            detail["name"] = key
            detail["required"] = required.contains(key)
            detail["availability"] = Request.clientOptions.contains(key) ? ["cli"] : ["cli", "ipc"]
            // Client routing options never cross the socket boundary.
            if !Request.clientOptions.contains(key) {
                detail["ipcType"] = "string"
                if detail["type"] as? String == "flag" { detail["ipcValue"] = "true" }
            }
            return detail
        }
        let result: String
        switch name {
        case "help": result = "help"
        case "capabilities": result = "capabilities"
        case "version": result = "version"
        case "daemon": result = "daemon"
        case "status": result = "status"
        case "shutdown": result = "shutdown"
        case "space.list": result = "spaces"
        case "space.create", "space.info", "space.suspend", "space.resume": result = "space"
        case "space.delete": result = "deletion"
        case "tab.list": result = "tabs"
        case "tab.new": result = "tab"
        case "tab.close": result = "tabClose"
        case "tab.default": result = "tabDefault"
        case "diagnostics": result = "diagnostics"
        case "dialog.list": result = "dialogs"
        case "dialog.respond": result = "dialogResponse"
        case "download.list", "download.wait", "download.cancel": result = "downloads"
        default: result = "page"
        }
        return ["command": name, "usage": synopsis(name),
                "args": ["names": arguments[name] ?? [], "minimum": arity.lowerBound, "maximum": arity.upperBound],
                "options": options, "resultSchema": result,
                "availability": name == "daemon" ? ["cli"] : ["cli", "ipc"],
                "offline": ["help", "capabilities", "version"].contains(name)]
    }

    // These schemas describe stable outer results. Page-controlled JSON stays unconstrained.
    private static func object(_ required: [String], _ properties: [String: Any] = [:]) -> [String: Any] {
        ["type": "object", "required": required, "properties": properties, "additionalProperties": true]
    }

    static var capabilities: [String: Any] {
        let string = ["type": "string"]
        let page = object(["spaceId", "space", "proxy", "network", "page", "value"], ["value": [:]])
        let tab = object(["tabId", "url", "title", "loading", "webContentTerminated", "unresponsive"])
        let space = object(["id", "name", "proxy", "defaultTabId", "tabs", "busy"])
        let shutdownImpact = object(["spaces", "websiteDataPreserved", "pageMemoryPreserved"], [
            "spaces": ["type": "array", "items": object(["spaceId", "name", "tabIds"], [
                "spaceId": string, "name": string, "tabIds": ["type": "array", "items": string]])],
            "websiteDataPreserved": ["const": true], "pageMemoryPreserved": ["const": false]])
        return [
            "schemaVersion": 1, "version": productVersion,
            "commands": Request.arities.keys.sorted().map(command),
            "constraints": [
                "frame": ["requires": ["tab"], "commands": ["snapshot", "click", "fill", "wait"]],
                "click": ["mutuallyExclusive": [["wait-for-navigation", "wait-for-popup"]]],
                "screenshot": ["mutuallyExclusive": [["element", "full-page"]]],
                "space.create": ["mutuallyExclusive": [["ca-cert", "ignore-certificate-errors"]]],
                "diagnostics": ["mutuallyExclusive": [["detail", "inspectable"]]],
                "dialog.respond": ["actions": ["accept", "dismiss"], "textRequires": ["type": "prompt", "action": "accept"]],
                "wait": ["mutuallyExclusive": [["url", "text", "state"]],
                         "urlRequiresNoSelector": true, "stateRequiresSelector": true],
                "cli": ["literalSeparator": "--", "duplicateOptions": "rejected", "help": "awb help [COMMAND [SUBCOMMAND]]"]
            ],
            "schemas": [
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "$defs": [
                    "request": object(["command", "args", "options"], [
                        "command": ["type": "string", "enum": Request.arities.keys.sorted()],
                        "args": ["type": "array", "items": string],
                        "options": ["type": "object", "additionalProperties": string]]),
                    "response": ["oneOf": [
                        object(["ok", "result"], ["ok": ["const": true], "result": [:]]),
                        object(["ok", "error"], ["ok": ["const": false], "error": object(["code", "message"], ["code": string, "message": string])])]],
                    "help": object(["usage"]), "capabilities": object(["schemaVersion", "version", "commands", "schemas"]),
                    "version": object(["version"]), "daemon": ["description": "Long-running CLI process; no command result; IPC daemon is unsupported"],
                    "status": object(["version", "pid", "ready", "spaces", "observer", "capabilities", "shutdownImpact"], ["shutdownImpact": shutdownImpact]),
                    "shutdown": object(["shutdown", "shutdownImpact"], ["shutdown": ["const": true], "shutdownImpact": shutdownImpact]), "space": space,
                    "spaces": ["type": "array", "items": space], "tab": tab,
                    "tabs": ["type": "array", "items": tab], "page": page,
                    "downloads": object(["spaceId", "tabId", "value"]),
                    "deletion": object(["deleted", "spaceId", "websiteDataRemoved", "dataStoreRemoved", "cleanupPending"]),
                    "tabClose": object(["closed", "defaultTabId"]), "tabDefault": object(["defaultTabId"]),
                    "diagnostics": object(["spaceId", "tabId", "busy", "networkBlocked", "networkErrorCode", "value"]),
                    "dialogs": object(["spaceId", "tabId", "busy", "value"], ["value": object(["dialogs", "limit"], [
                        "dialogs": ["type": "array", "items": object(["id", "type", "message", "defaultText", "expiresAtMs", "origin", "mainFrame"], [
                            "type": ["enum": ["alert", "confirm", "prompt"]]])]])]),
                    "dialogResponse": object(["spaceId", "tabId", "busy", "value"], ["value": object(["id", "type", "action", "handled", "businessOutcomeVerified"])])
                ]
            ],
            "errors": errorCodes,
            "exitCodes": ["0": "successful CLI response", "1": "structured failure"],
            "timing": ["unit": "ms", "fields": ["cliMs", "ipcRoundTripMs", "serverMs", "webkitMs"], "optional": true],
            "scope": [
                "platform": "macOS 14+; per-Space proxy requires macOS 14+ public WebKit support",
                "transport": "same-user local Unix socket; newline-delimited JSON; maximum message 8 MiB",
                "target": "explicit Space; fixed CLI default Tab or explicit Tab; independent of GUI selection",
                "concurrency": "one mutating/WebKit operation per Space; different Spaces independent",
                "shutdown": "requires explicit --all; status.shutdownImpact previews all affected Spaces/Tab IDs; successful reply reports the affected scope; busy rejects exit; website data retained, page memory lost",
                "lifecycle": "space suspend releases WebViews, retaining its data-store coordinator and IDs/URLs/website data/proxy/TLS; suspended Spaces restart without WebViews; resume starts loading; page actions resume on demand; state/list/info never wake; JS memory is lost",
                "input": "DOM synthetic; nativeVerified=false; businessOutcomeVerified=false",
                "snapshot": "same-origin frames and open shadow roots; frame list + explicit --tab/--frame selects cross-origin or nested documents for snapshot/click/fill/wait; >>> does not cross origins; closed roots unsupported",
                "frames": "128 most recently registered documents per Tab; opaque host-issued document IDs, epoch checked in the same JS turn as each operation; list validates live targets; no inferred parent routing; frame coordinates/visibility stay document-local; no --frame for evaluate/screenshots/upload",
                "screenshot": "viewport, --element or bounded --full-page PNG; mode/range and pixel dimensions; scroll restoration; full-page uses viewport tiles, reports best-effort consistency and fixed/lazy/virtualized/nested-scroll limits; no foreground activation",
                "recovery": "never automatically replay actions after timeout; inspect state/diagnostics; explicit reload/open can replace unresponsive view retaining Tab ID and Space data",
                "proxy": "direct rejects enabled system proxy; no VPN/content-filter bypass; loopback routing unverified; routeVerified=false",
                "dialogs": "explicit per-Space/Tab list/respond; no automatic confirm acceptance; queries and replies work while busy; deadlines dismiss safely; no foreground activation",
                "downloads": "per-Tab native WKDownload; private per-ID output directory; list/wait/cancel; timeout does not replay or cancel; 8 active, 64 records, 300000 ms lifetime; completed files retained after close/delete/restart, runtime records reset",
                "fileChooser": "native panel only for already active key window; background delegate cancels with state.page.fileChooser.requiresForeground=true; never activates a window",
                "upload": "1–16 explicit local absolute regular file paths; total at most 4194304 bytes; file input via isolated-world DataTransfer and synthetic input/change; method=dom-data-transfer, nativeVerified=false; no implicit submit; validate business result separately; accept attribute is a UI hint, not enforced",
                "unsupported": "native keyboard/mouse; complete DevTools network trace"
            ]
        ]
    }

    private static let errorCodes = [
        "already_running", "certificate_rejected", "data_removal_failed", "data_removal_timeout", "data_store_removal_timeout", "download_not_found", "download_failed",
        "download_cancel_timeout", "download_file_limit", "download_space_limit", "download_total_limit", "download_disk_limit", "download_budget_unavailable",
        "file_unreadable", "upload_too_large", "unsupported_upload_target", "upload_multiple_not_allowed", "upload_unavailable", "unsupported_screenshot_geometry", "screenshot_changed", "screenshot_too_large",
        "direct_system_proxy_conflict", "diagnostics_unavailable", "dialog_not_found", "dialog_already_handled", "dialog_expired", "dialog_cancelled", "dialog_capacity", "element_not_actionable", "element_not_editable", "element_readonly",
        "invalid_arguments", "invalid_certificate", "invalid_json_result", "invalid_name", "invalid_option",
        "invalid_proxy", "invalid_response", "invalid_selector", "invalid_timeout", "invalid_url", "ipc_error",
        "javascript_error", "last_tab", "message_too_large", "not_ready", "operation_failed", "persistence_failed", "png_failed", "resource_limit", "server_busy",
        "popup_failed", "popup_not_opened", "popup_store_mismatch", "proxy_required", "selector_count",
        "shutting_down", "snapshot_failed", "socket_path_too_long", "space_busy", "space_exists", "space_not_found", "space_suspended",
        "space_required", "stale_frame", "stale_ref", "tab_closed", "tab_not_found", "timeout", "unknown_command",
        "unsafe_socket_path", "unsupported_context", "unsupported_fill_type", "unsupported_navigation",
        "web_content_terminated", "web_content_unresponsive"
    ]
}
