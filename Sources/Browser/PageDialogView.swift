import AppKit

/// A page may be waiting for either the user or an IPC client. Keep controls
/// bound to this exact dialog even if another reply arrives during a click.
@MainActor
final class PageDialogView: NSStackView, NSTextFieldDelegate {
    let dialogID: String
    private let deadline: UInt64
    private weak var store: DialogStore?
    private let metaLabel = NSTextField(labelWithString: "")
    private let input = NSTextField()
    private var messageView: NSTextView?
    private var messageHeight: NSLayoutConstraint?
    private var replyEdited = false
    private var totalPending: Int
    private var countdownTask: Task<Void, Never>?
    private let isAlert: Bool

    init(_ dialog: DialogStore.Pending, totalPending: Int = 1, store: DialogStore) {
        dialogID = dialog.id
        deadline = dialog.deadline
        self.totalPending = max(1, totalPending)
        self.store = store
        isAlert = dialog.kind == "alert"
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)

        let origin = dialog.origin == "opaque" ? "来源不明的页面" : dialog.origin
        let heading = NSTextField(labelWithString: "网页对话框 · " + origin)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.toolTip = origin

        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [heading, NSView(), metaLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true

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
            messageView = message
            addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
            let height = scroll.heightAnchor.constraint(equalToConstant: 24)
            height.isActive = true
            messageHeight = height
        }
        let accept = NSButton(title: "确定", target: self, action: #selector(acceptDialog))
        accept.setAccessibilityLabel("确定网页对话框")
        let actions = NSStackView()
        let isPrompt = dialog.kind == "prompt"
        if isPrompt {
            if dialog.defaultPreview?.truncated == true {
                let hint = NSTextField(wrappingLabelWithString: "默认回复仅显示前 4096 个字符。直接确定会提交完整默认值，编辑后会替换全文。")
                hint.font = .systemFont(ofSize: 12)
                hint.textColor = .secondaryLabelColor
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
        if !isAlert {
            let cancel = NSButton(title: "取消", target: self, action: #selector(dismissDialog))
            cancel.setAccessibilityLabel("取消网页对话框")
            actions.addArrangedSubview(cancel)
        }
        actions.addArrangedSubview(accept)
        addArrangedSubview(actions)
        if isPrompt { actions.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true }
        updateMetaLabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePendingCount(_ count: Int) {
        let clamped = max(1, count)
        guard clamped != totalPending else { return }
        totalPending = clamped
        updateMetaLabel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countdownTask?.cancel()
        countdownTask = nil
        guard window != nil else { return }
        updateMetaLabel()
        countdownTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.updateMetaLabel()
                if monotonicNow() >= self.deadline { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    override func layout() {
        if bounds.width > 32, let messageView, let messageHeight,
           let container = messageView.textContainer, let layoutManager = messageView.layoutManager {
            let contentWidth = messageView.enclosingScrollView?.contentSize.width ?? 0
            let width = contentWidth > 32 ? contentWidth : bounds.width - 32
            if !container.widthTracksTextView, abs(container.containerSize.width - width) > 0.5 {
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: container)
            let used = ceil(layoutManager.usedRect(for: container).height) + 4
            let clamped = max(20, min(120, used))
            if abs(messageHeight.constant - clamped) > 0.5 {
                messageHeight.constant = clamped
            }
        }
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.systemOrange.withAlphaComponent(0.07).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill(using: .sourceOver)
        NSColor.separatorColor.setFill()
        let bottomY = isFlipped ? bounds.maxY - 1 : 0
        NSRect(x: 0, y: bottomY, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    private func updateMetaLabel() {
        let now = monotonicNow()
        let remaining = deadline > now ? Int(ceil(Double(deadline - now) / 1_000_000_000)) : 0
        var parts: [String] = []
        if totalPending > 1 { parts.append("还有 \(totalPending - 1) 个待处理") }
        parts.append("\(remaining)s 后自动取消")
        metaLabel.stringValue = parts.joined(separator: " · ")
    }

    func controlTextDidChange(_ notification: Notification) { replyEdited = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), !isAlert {
            dismissDialog()
            return true
        }
        return false
    }

    @objc private func acceptDialog() {
        _ = try? store?.respond(id: dialogID, action: "accept", text: replyEdited ? input.stringValue : nil)
    }
    @objc private func dismissDialog() {
        _ = try? store?.respond(id: dialogID, action: "dismiss", text: nil)
    }
}
