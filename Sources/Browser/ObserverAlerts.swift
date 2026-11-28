import AppKit

extension NSWindow {
    func confirmObserverAction(_ title: String, detail: String, action: String, destructive: Bool = false, critical: Bool = false, perform: @escaping () -> Void) {
        let alert = NSAlert.observerConfirmation(title, detail: detail, action: action, destructive: destructive, critical: critical)
        alert.beginSheetModal(for: self) { if $0 == .alertFirstButtonReturn { perform() } }
    }

    func presentObserverFailure(_ response: [String: Any]) {
        let message = (response["error"] as? [String: Any])?["message"] as? String ?? "操作未完成，请重试。"
        let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = message
        alert.beginSheetModal(for: self)
    }
}

extension NSAlert {
    static func observerConfirmation(_ title: String, detail: String, action: String, destructive: Bool, critical: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .warning
        alert.messageText = title; alert.informativeText = detail
        let actionButton = alert.addButton(withTitle: action)
        if destructive {
            actionButton.hasDestructiveAction = true
            actionButton.keyEquivalent = ""
        }
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1b}"
        return alert
    }
}
