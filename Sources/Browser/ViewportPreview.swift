import AppKit
import WebKit

private final class PreviewContainerStackView: NSStackView {
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class ViewportPreview: NSViewController {
    private let webView: WKWebView
    private let viewport: NSSize
    private let image = NSImageView()
    private let message = NSTextField(labelWithString: "正在读取页面画面…")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)

    init(webView: WKWebView, viewport: NSSize, available: NSSize) {
        self.webView = webView
        self.viewport = viewport
        super.init(nibName: nil, bundle: nil)
        let scale = min(1, min((available.width - 90) / viewport.width, (available.height - 160) / viewport.height))
        preferredContentSize = NSSize(width: max(360, viewport.width * scale + 32),
                                      height: max(160, viewport.height * scale + 84))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "固定视口预览 · \(Int(viewport.width)) × \(Int(viewport.height))")
        title.font = .boldSystemFont(ofSize: 14)
        refreshButton.target = self
        refreshButton.action = #selector(refreshSnapshot)
        refreshButton.setAccessibilityLabel("刷新固定视口预览")
        let done = NSButton(title: "完成", target: self, action: #selector(closePreview))
        done.keyEquivalent = "\r"
        let header = NSStackView(views: [title, NSView(), refreshButton, done])
        header.spacing = 8
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("完整页面视口的静态预览")
        message.textColor = .secondaryLabelColor
        let stack = PreviewContainerStackView(views: [header, image, message])
        stack.onCancel = { [weak self] in self?.closePreview() }
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        for child in [header, image] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        image.setContentHuggingPriority(.defaultLow, for: .vertical)
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        image.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.frame.size = preferredContentSize
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        captureSnapshot()
    }

    override func cancelOperation(_ sender: Any?) {
        closePreview()
    }

    @objc private func refreshSnapshot() {
        captureSnapshot()
    }

    private func captureSnapshot() {
        refreshButton.isEnabled = false
        message.stringValue = "正在读取页面画面…"
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: viewport)
        config.snapshotWidth = NSNumber(value: min(viewport.width, max(1, preferredContentSize.width - 32)))
        webView.takeSnapshot(with: config) { [weak self] snapshot, _ in
            guard let self else { return }
            self.refreshButton.isEnabled = true
            self.image.image = snapshot
            self.message.stringValue = snapshot == nil ? "预览生成失败。可点击刷新重试。" : "当前画面快照（按 Esc 或完成关闭）"
        }
    }

    @objc private func closePreview() { dismiss(self) }
}
