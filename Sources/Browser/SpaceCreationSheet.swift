import AppKit

@MainActor
final class SpaceCreationSheet: NSViewController, NSTextFieldDelegate {
    private let name = NSTextField()
    private let mode = NSPopUpButton()
    private let proxy = NSTextField()
    private let advanced = NSButton(checkboxWithTitle: "显示 TLS 高级选项", target: nil, action: nil)
    private let tls = NSPopUpButton()
    private let ca = NSTextField()
    private let chooseCA = NSButton(title: "选择…", target: nil, action: nil)
    private var proxyRow = NSStackView()
    private var tlsRow = NSStackView()
    private var caRow = NSStackView()
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
        name.placeholderString = "以英文字母开头"
        name.setAccessibilityLabel("Space 名称")
        mode.addItems(withTitles: ["直连", "HTTP 代理"])
        mode.setAccessibilityLabel("连接方式")
        proxy.placeholderString = "http://127.0.0.1:端口"
        proxy.setAccessibilityLabel("代理地址")
        tls.addItems(withTitles: ["系统证书校验", "使用自定义 CA", "忽略证书错误"])
        tls.setAccessibilityLabel("证书策略")
        ca.placeholderString = "CA 证书文件的绝对路径"
        ca.setAccessibilityLabel("CA 证书路径")
        chooseCA.target = self; chooseCA.action = #selector(chooseCertificate)
        chooseCA.setAccessibilityLabel("选择 CA 证书文件")
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
        func row(_ text: String, _ controls: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: text)
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let line = NSStackView(views: [label] + controls)
            line.alignment = .firstBaseline; line.spacing = 8
            return line
        }
        let nameRow = row("Space 名称", [name])
        let modeRow = row("连接方式", [mode])
        proxyRow = row("代理地址", [proxy])
        tlsRow = row("证书策略", [tls])
        caRow = row("CA 证书", [ca, chooseCA])
        ca.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseCA.setContentHuggingPriority(.required, for: .horizontal)
        let divider = NSBox(); divider.boxType = .separator
        let actions = NSStackView(views: [NSView(), cancel, create])
        for control: NSView in [title, nameRow, divider, modeRow, proxyRow, advanced, tlsRow, caRow, errorLabel, actions] {
            stack.addArrangedSubview(control)
        }
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(14, after: nameRow)
        stack.setCustomSpacing(14, after: divider)
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 378)
        ])
        for item in [nameRow, divider, modeRow, proxyRow, tlsRow, caRow, errorLabel, actions] as [NSView] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        proxyRow.isHidden = mode.indexOfSelectedItem == 0
        tlsRow.isHidden = advanced.state != .on
        caRow.isHidden = tlsRow.isHidden || tls.indexOfSelectedItem != 1
        create.isEnabled = !submitting && !name.stringValue.isEmpty && (proxyRow.isHidden || !proxy.stringValue.isEmpty)
            && (tls.indexOfSelectedItem != 1 || !ca.stringValue.isEmpty)
        advanced.title = tlsRow.isHidden && tls.indexOfSelectedItem > 0
            ? "显示 TLS 高级选项（" + (tls.titleOfSelectedItem ?? "") + "）" : "显示 TLS 高级选项"
        preferredContentSize = view.fittingSize
    }
    @objc private func cancelSheet() { dismiss(self) }
    @objc private func chooseCertificate() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 CA 证书"; panel.prompt = "选择"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path, let self else { return }
            self.ca.stringValue = path
            self.inputChanged()
        }
    }
    @objc private func createSpace() {
        guard create.isEnabled, let submit else { return }
        var options = ["proxy": proxyRow.isHidden ? "direct" : proxy.stringValue]
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
        for control: NSControl in [name, mode, proxy, advanced, tls, ca, chooseCA, cancel] {
            control.isEnabled = !value
        }
        updateFields()
    }
}
