import AppKit

@MainActor
final class SpaceCreationSheet: NSViewController, NSTextFieldDelegate {
    private let name = NSTextField()
    private let mode = NSPopUpButton()
    private let proxy = NSTextField()
    private let advanced = NSButton(checkboxWithTitle: "显示 TLS 高级选项", target: nil, action: nil)
    private let tls = NSPopUpButton()
    private let ca = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let create = NSButton(title: "创建", target: nil, action: nil)
    private var submitting = false
    var submit: ((Request) -> Void)?

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let title = NSTextField(labelWithString: "新建 Space")
        title.font = .boldSystemFont(ofSize: 17)
        name.placeholderString = "名称（以英文字母开头）"
        name.setAccessibilityLabel("Space 名称")
        mode.addItems(withTitles: ["Direct", "HTTP Proxy"])
        proxy.placeholderString = "http://127.0.0.1:端口"
        proxy.setAccessibilityLabel("代理地址")
        tls.addItems(withTitles: ["系统证书校验", "使用自定义 CA", "忽略证书错误"])
        ca.placeholderString = "CA 证书文件的绝对路径"
        ca.setAccessibilityLabel("CA 证书路径")
        for control: NSControl in [mode, advanced, tls] {
            control.target = self
            control.action = #selector(inputChanged)
        }
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        for field in [name, proxy, ca] {
            field.delegate = self
        }
        cancel.target = self
        cancel.action = #selector(cancelSheet)
        cancel.keyEquivalent = "\u{1b}"
        create.target = self
        create.action = #selector(createSpace)
        create.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, create])
        for control: NSView in [title, name, errorLabel, mode, proxy, advanced, tls, ca, actions] {
            stack.addArrangedSubview(control)
        }
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 310)
        ])
        for field in [name, errorLabel, proxy, ca] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
        updateFields()
    }

    func controlTextDidChange(_ notification: Notification) { inputChanged() }
    @objc private func inputChanged() {
        errorLabel.isHidden = true
        updateFields()
    }
    private func updateFields() {
        proxy.isHidden = mode.indexOfSelectedItem == 0
        tls.isHidden = advanced.state != .on
        ca.isHidden = tls.isHidden || tls.indexOfSelectedItem != 1
        create.isEnabled = !submitting && !name.stringValue.isEmpty && (proxy.isHidden || !proxy.stringValue.isEmpty)
            && (tls.indexOfSelectedItem != 1 || !ca.stringValue.isEmpty)
        advanced.title = tls.isHidden && tls.indexOfSelectedItem > 0
            ? "显示 TLS 高级选项（" + (tls.titleOfSelectedItem ?? "") + "）" : "显示 TLS 高级选项"
        preferredContentSize = view.fittingSize
    }
    @objc private func cancelSheet() { dismiss(self) }
    @objc private func createSpace() {
        guard create.isEnabled, let submit else { return }
        var options = ["proxy": proxy.isHidden ? "direct" : proxy.stringValue]
        if tls.indexOfSelectedItem == 1 { options["ca-cert"] = ca.stringValue }
        if tls.indexOfSelectedItem == 2 { options["ignore-certificate-errors"] = "true" }
        errorLabel.isHidden = true
        setSubmitting(true)
        submit(Request(command: "space.create", args: [name.stringValue], options: options))
    }

    func finishSubmission(error: String? = nil) {
        guard let error else { dismiss(self); return }
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        setSubmitting(false)
    }

    private func setSubmitting(_ value: Bool) {
        submitting = value
        for control: NSControl in [name, mode, proxy, advanced, tls, ca, cancel] {
            control.isEnabled = !value
        }
        updateFields()
    }
}
