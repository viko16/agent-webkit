import AppKit
import WebKit

@MainActor
final class PageFindBar: NSStackView, NSSearchFieldDelegate {
    private let query = NSSearchField()
    private let result = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private weak var page: WKWebView?
    private var document: Int?
    private var revision = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal; spacing = 6
        edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        query.placeholderString = "页内查找"; query.setAccessibilityLabel("页内查找"); query.delegate = self
        query.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let width = query.widthAnchor.constraint(equalToConstant: 230)
        width.priority = .defaultHigh; width.isActive = true
        result.font = .systemFont(ofSize: 12); result.textColor = .secondaryLabelColor
        for (button, symbol, label, action) in [
            (previous, "chevron.up", "上一个匹配", #selector(findPrevious)),
            (next, "chevron.down", "下一个匹配", #selector(findNext))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.setAccessibilityLabel(label); button.toolTip = label
            button.bezelStyle = .rounded; button.target = self; button.action = action
            button.isEnabled = false
        }
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        [NSView(), query, previous, next, result, done].forEach(addArrangedSubview)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let bottomY = isFlipped ? bounds.maxY - 1 : 0
        NSRect(x: 0, y: bottomY, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    func bind(to webView: WKWebView?, document sequence: Int?) {
        guard page !== webView || document != sequence else { return }
        if !isHidden { hide() }
        query.stringValue = ""; result.stringValue = ""
        previous.isEnabled = false; next.isEnabled = false
        page = webView; document = sequence
    }

    var isEditingQuery: Bool { !isHidden && query.currentEditor() != nil }
    func canPerform(_ action: NSTextFinder.Action) -> Bool {
        page != nil && (action == .showFindInterface || !query.stringValue.isEmpty)
    }
    func perform(_ action: NSTextFinder.Action) {
        guard canPerform(action) else { return }
        isHidden = false
        if action == .showFindInterface {
            window?.makeFirstResponder(query); query.selectText(nil)
        } else { find(backwards: action == .previousMatch) }
    }
    func controlTextDidChange(_ notification: Notification) { find(backwards: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
        }
        return false
    }
    @objc private func findPrevious() { find(backwards: true) }
    @objc private func findNext() { find(backwards: false) }
    private func find(backwards: Bool) {
        guard let page else { return }
        revision += 1
        let current = revision, text = query.stringValue
        previous.isEnabled = !text.isEmpty; next.isEnabled = !text.isEmpty
        result.stringValue = ""
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards; configuration.wraps = true
        page.find(text, configuration: configuration) { [weak self] match in
            guard let self, self.revision == current, !text.isEmpty else { return }
            self.result.stringValue = match.matchFound ? "已找到" : "未找到"
        }
    }
    private func hide() {
        isHidden = true; revision += 1
        page?.find("") { _ in }
    }
    @objc private func close() {
        hide()
        window?.makeFirstResponder(page)
    }
}
