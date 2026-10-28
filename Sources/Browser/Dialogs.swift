import Foundation

@MainActor
final class DialogStore {
    private struct Pending {
        let id: String
        let kind: String
        let message: String
        let defaultText: String?
        let origin: String
        let mainFrame: Bool
        let deadline: UInt64
        let expiresAt: Double
        let reply: (Bool, String?) -> Void
        let timer: DispatchWorkItem
    }
    private var pending: [Pending] = []
    private var ended: [(id: String, code: String)] = []
    private var lastExpiry: UInt64 = 0
    var automaticallyDismissed: (() -> Void)?
    static let limit = 8

    var hasPending: Bool { !pending.isEmpty }
    var pendingCount: Int { expire(); return pending.count }
    func expired(since start: UInt64) -> Bool { lastExpiry >= start }

    func present(kind: String, message: String, defaultText: String? = nil, origin: String,
                 mainFrame: Bool, deadline operationDeadline: UInt64?, reply: @escaping (Bool, String?) -> Void) {
        expire()
        let id = UUID().uuidString
        guard pending.count < Self.limit else {
            remember(id, code: "dialog_capacity")
            automaticallyDismissed?(); reply(false, nil)
            return
        }
        let now = monotonicNow()
        let deadline = min(operationDeadline ?? now + 15_000_000_000, now + 60_000_000_000)
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.expire() } }
        pending.append(Pending(id: id, kind: kind, message: message, defaultText: defaultText,
                               origin: origin, mainFrame: mainFrame, deadline: deadline,
                               expiresAt: Date().timeIntervalSince1970 * 1000 + Double(deadline > now ? deadline - now : 0) / 1_000_000,
                               reply: reply, timer: timer))
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(deadline > now ? deadline - now : 0) / 1_000_000_000, execute: timer)
    }

    private func remember(_ id: String, code: String) {
        if ended.count == 16 { ended.removeFirst() }
        ended.append((id, code))
    }

    private func finish(_ id: String, accepted: Bool, text: String?, code: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        entry.timer.cancel()
        remember(id, code: code)
        if code != "dialog_already_handled" { automaticallyDismissed?() }
        // Remove before invoking WebKit: a reply can cause another dialog to arrive.
        entry.reply(accepted, text)
    }

    private func expire() {
        let ids = pending.filter { monotonicNow() >= $0.deadline }.map(\.id)
        if !ids.isEmpty { lastExpiry = monotonicNow() }
        for id in ids { finish(id, accepted: false, text: nil, code: "dialog_expired") }
    }

    func cancelAll(code: String) {
        if code == "dialog_expired", !pending.isEmpty { lastExpiry = monotonicNow() }
        for id in pending.map(\.id) { finish(id, accepted: false, text: nil, code: code) }
    }

    func snapshot() -> [String: Any] {
        expire()
        return ["dialogs": pending.map { entry -> [String: Any] in
            ["id": entry.id, "type": entry.kind, "message": String(entry.message.prefix(4096)),
             "messageTruncated": entry.message.count > 4096,
             "defaultText": entry.defaultText.map { String($0.prefix(4096)) } as Any? ?? NSNull(),
             "defaultTextTruncated": entry.defaultText.map { $0.count > 4096 } ?? false,
             "origin": entry.origin, "mainFrame": entry.mainFrame, "expiresAtMs": entry.expiresAt,
             "requiresForeground": false]
        }, "limit": Self.limit, "requiresForeground": false,
        "lastEnded": ended.last.map { ["id": $0.id, "code": $0.code] } as Any? ?? NSNull()]
    }

    func respond(id: String, action: String, text: String?) throws -> [String: Any] {
        expire()
        guard let entry = pending.first(where: { $0.id == id }) else {
            let code = ended.last(where: { $0.id == id })?.code ?? "dialog_not_found"
            throw BrowserError(code, "对话框不存在或已结束；重新 dialog list 核对当前目标（\(code)）")
        }
        guard text == nil || (entry.kind == "prompt" && action == "accept") else {
            throw BrowserError("invalid_arguments", "--text 只用于接受 prompt；其他响应不接收文本")
        }
        finish(id, accepted: action == "accept", text: text ?? entry.defaultText ?? "", code: "dialog_already_handled")
        return ["id": id, "type": entry.kind, "action": action, "handled": true,
                "requiresForeground": false, "businessOutcomeVerified": false]
    }
}
