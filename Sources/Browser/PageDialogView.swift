import AppKit

/// A page may be waiting for either the user or an IPC client. Keep controls
/// bound to this exact dialog even if another reply arrives during a click.
@MainActor
final class PageDialogView: NSStackView, NSTextFieldDelegate {
    let dialogID: String
    private weak var store: DialogStore?
    private let input = NSTextField()
    private var replyEdited = false

    init(_ dialog: DialogStore.Pending, store: DialogStore) {
        dialogID = dialog.id
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)

        let origin = dialog.origin == "opaque" ? "来源不明的页面" : dialog.origin
        let heading = NSTextField(labelWithString: "网页对话框 · " + origin)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.toolTip = origin
        addArrangedSubview(heading)
        heading.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32).isActive = true

        if !dialog.message.text.isEmpty {
            let scroll = NSTextView.scrollableTextView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.autohidesScrollers = true
            let message = scroll.documentView as! NSTextView
            message.isEditable = false
            message.drawsBackground = false
            message.font = .systemFont(ofSize: 13)
            message.textColor = .labelColor
            message.textContainer?.lineFragmentPadding = 0
            message.string = dialog.message.text + (dialog.message.truncated ? "\n（消息过长，仅显示前 4096 个字符）" : "")
            message.setAccessibilityLabel("网页消息")
            addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        let accept = NSButton(title: "确定", target: self, action: #selector(acceptDialog))
        accept.setAccessibilityLabel("确定网页对话框")
        let actions = NSStackView()
        let isPrompt = dialog.kind == "prompt"
        if isPrompt {
            if dialog.defaultPreview?.truncated == true {
                let hint = NSTextField(wrappingLabelWithString: "默认回复仅显示前 4096 个字符。直接确定会提交完整默认值，编辑后会替换全文。")
                hint.font = .systemFont(ofSize: 12)
                addArrangedSubview(hint)
                hint.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
            }
            input.stringValue = dialog.defaultPreview?.text ?? ""
            input.placeholderString = "输入回复"
            input.setAccessibilityLabel("网页对话框回复")
            input.target = self
            input.delegate = self
            input.action = #selector(acceptDialog)
            actions.addArrangedSubview(input)
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        if dialog.kind != "alert" {
            let cancel = NSButton(title: "取消", target: self, action: #selector(dismissDialog))
            cancel.setAccessibilityLabel("取消网页对话框")
            actions.addArrangedSubview(cancel)
        }
        actions.addArrangedSubview(accept)
        addArrangedSubview(actions)
        if isPrompt { actions.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ notification: Notification) { replyEdited = true }

    @objc private func acceptDialog() {
        _ = try? store?.respond(id: dialogID, action: "accept", text: replyEdited ? input.stringValue : nil)
    }
    @objc private func dismissDialog() {
        _ = try? store?.respond(id: dialogID, action: "dismiss", text: nil)
    }
}
