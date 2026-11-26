import AppKit
import WebKit

@MainActor
final class ViewportPreview: NSViewController {
    private let webView: WKWebView
    private let viewport: NSSize
    private let image = NSImageView()
    private let message = NSTextField(labelWithString: "正在读取页面画面…")

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
        let done = NSButton(title: "完成", target: self, action: #selector(closePreview))
        done.keyEquivalent = "\r"
        let header = NSStackView(views: [title, NSView(), done])
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("完整页面视口的静态预览")
        message.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, image, message])
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
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: viewport)
        config.snapshotWidth = NSNumber(value: min(viewport.width, max(1, preferredContentSize.width - 32)))
        webView.takeSnapshot(with: config) { [weak self] snapshot, _ in
            guard let self else { return }
            self.image.image = snapshot
            self.message.stringValue = snapshot == nil ? "预览生成失败。关闭后可重试。" : "打开预览时的画面"
        }
    }

    @objc private func closePreview() { dismiss(self) }
}
