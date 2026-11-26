import AppKit

@MainActor
final class SpaceCreationSheet: NSViewController, NSTextFieldDelegate {
    private let name = NSTextField()
    private let mode = NSPopUpButton()
    private let proxy = NSTextField()
    private let advanced = NSButton(checkboxWithTitle: "显示 TLS 高级选项", target: nil, action: nil)
    private let tls = NSPopUpButton()
    private let ca = NSTextField()
    private let create = NSButton(title: "创建", target: nil, action: nil)
    var submit: ((Request) -> Void)?

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let title = NSTextField(labelWithString: "新建 Space")
        title.font = .boldSystemFont(ofSize: 17)
        name.placeholderString = "名称（字母开头）"
        name.setAccessibilityLabel("Space 名称")
        mode.addItems(withTitles: ["Direct", "HTTP Proxy"])
        proxy.placeholderString = "http://127.0.0.1:端口"
        proxy.setAccessibilityLabel("代理地址")
        tls.addItems(withTitles: ["系统证书校验", "使用自定义 CA", "忽略证书错误"])
        ca.placeholderString = "CA 证书文件的绝对路径"
        ca.setAccessibilityLabel("CA 证书路径")
        for control: NSControl in [mode, advanced, tls] {
            control.target = self
            control.action = #selector(updateFields)
        }
        for field in [name, proxy, ca] {
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 310).isActive = true
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        create.target = self
        create.action = #selector(createSpace)
        create.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, create])
        for control: NSView in [title, name, mode, proxy, advanced, tls, ca, actions] {
            stack.addArrangedSubview(control)
        }
        view = stack
        updateFields()
    }

    func controlTextDidChange(_ notification: Notification) { updateFields() }
    @objc private func updateFields() {
        proxy.isHidden = mode.indexOfSelectedItem == 0
        tls.isHidden = advanced.state != .on
        ca.isHidden = tls.isHidden || tls.indexOfSelectedItem != 1
        create.isEnabled = !name.stringValue.isEmpty && (proxy.isHidden || !proxy.stringValue.isEmpty)
            && (tls.indexOfSelectedItem != 1 || !ca.stringValue.isEmpty)
        advanced.title = tls.isHidden && tls.indexOfSelectedItem > 0
            ? "显示 TLS 高级选项（" + (tls.titleOfSelectedItem ?? "") + "）" : "显示 TLS 高级选项"
        preferredContentSize = view.fittingSize
    }
    @objc private func cancelSheet() { dismiss(self) }
    @objc private func createSpace() {
        guard create.isEnabled else { return }
        var options = ["proxy": proxy.isHidden ? "direct" : proxy.stringValue]
        if tls.indexOfSelectedItem == 1 { options["ca-cert"] = ca.stringValue }
        if tls.indexOfSelectedItem == 2 { options["ignore-certificate-errors"] = "true" }
        dismiss(self)
        submit?(Request(command: "space.create", args: [name.stringValue], options: options))
    }
}
