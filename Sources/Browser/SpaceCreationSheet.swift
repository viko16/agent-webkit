import AppKit

@MainActor
final class SpaceCreationSheet: NSViewController, NSTextFieldDelegate {
    private let name = NSTextField()
    private let mode = NSPopUpButton()
    private let proxy = NSTextField()
    private let proxyHint = NSTextField(wrappingLabelWithString: "仅支持本机代理，如 Whistle：http://127.0.0.1:8899")
    private let advanced = NSButton()
    private let advancedLabel = NSTextField(labelWithString: "TLS 高级选项")
    private let progress = NSProgressIndicator()
    private let tls = NSPopUpButton()
    private let tlsWarning = NSTextField(wrappingLabelWithString: "仅限受控开发环境：将跳过证书链、域名和有效期校验。")
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
        proxyHint.font = .systemFont(ofSize: 11)
        proxyHint.textColor = .secondaryLabelColor
        tls.addItems(withTitles: ["系统证书校验", "使用自定义 CA", "忽略证书错误"])
        tls.setAccessibilityLabel("证书策略")
        tlsWarning.font = .systemFont(ofSize: 11)
        tlsWarning.textColor = .systemOrange
        ca.placeholderString = "CA 证书文件的绝对路径"
        ca.setAccessibilityLabel("CA 证书路径")
        chooseCA.target = self; chooseCA.action = #selector(chooseCertificate)
        chooseCA.setAccessibilityLabel("选择 CA 证书文件")
        advanced.setButtonType(.onOff)
        advanced.bezelStyle = .disclosure
        advanced.title = ""
        advanced.setAccessibilityLabel("TLS 高级选项")
        advanced.setAccessibilityRole(.disclosureTriangle)
        advancedLabel.setAccessibilityElement(false)
        let disclosure = NSStackView(views: [advanced, advancedLabel])
        disclosure.alignment = .centerY; disclosure.spacing = 4
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
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false; progress.isHidden = true
        progress.setAccessibilityLabel("正在创建 Space")
        let actions = NSStackView(views: [NSView(), progress, cancel, create])
        for control: NSView in [title, nameRow, divider, modeRow, proxyRow, proxyHint, disclosure, tlsRow, tlsWarning, caRow, errorLabel, actions] {
            stack.addArrangedSubview(control)
        }
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(14, after: nameRow)
        stack.setCustomSpacing(14, after: divider)
        stack.setCustomSpacing(4, after: proxyRow)
        stack.setCustomSpacing(4, after: tlsRow)
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
        for item in [nameRow, divider, modeRow, proxyRow, proxyHint, tlsRow, tlsWarning, caRow, errorLabel, actions] as [NSView] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
        updateFields()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.defaultButtonCell = create.cell as? NSButtonCell
        view.window?.makeFirstResponder(name)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.insertNewline(_:)) { createSpace(); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { cancelSheet(); return true }
        return false
    }
    func controlTextDidChange(_ notification: Notification) { inputChanged() }
    @objc private func inputChanged() {
        errorLabel.isHidden = true
        updateFields()
    }
    private func updateFields() {
        proxyRow.isHidden = mode.indexOfSelectedItem == 0
        proxyHint.isHidden = proxyRow.isHidden
        tlsRow.isHidden = advanced.state != .on
        tlsWarning.isHidden = tlsRow.isHidden || tls.indexOfSelectedItem != 2
        caRow.isHidden = tlsRow.isHidden || tls.indexOfSelectedItem != 1
        let trimmedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProxy = proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCA = ca.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        create.isEnabled = !submitting && !trimmedName.isEmpty && (proxyRow.isHidden || !trimmedProxy.isEmpty)
            && (tls.indexOfSelectedItem != 1 || !trimmedCA.isEmpty)
        let policy = tls.indexOfSelectedItem == 1 && trimmedCA.isEmpty ? "需选择 CA 证书" : tls.titleOfSelectedItem
        advancedLabel.stringValue = tlsRow.isHidden && tls.indexOfSelectedItem > 0
            ? "TLS 高级选项（" + (policy ?? "") + "）" : "TLS 高级选项"
        advanced.setAccessibilityLabel(advancedLabel.stringValue)
        advanced.setAccessibilityExpanded(!tlsRow.isHidden)
        preferredContentSize = view.fittingSize
    }
    @objc private func cancelSheet() { if !submitting { dismiss(self) } }
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
        let spaceName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var proxyAddress = proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxyRow.isHidden,
           proxyAddress.range(of: #"^127\.0\.0\.1:[0-9]+$"#, options: .regularExpression) != nil {
            proxyAddress = "http://" + proxyAddress
            proxy.stringValue = proxyAddress
        }
        var options = ["proxy": proxyRow.isHidden ? "direct" : proxyAddress]
        if tls.indexOfSelectedItem == 1 { options["ca-cert"] = ca.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tls.indexOfSelectedItem == 2 { options["ignore-certificate-errors"] = "true" }
        errorLabel.isHidden = true
        setSubmitting(true)
        submit(Request(command: "space.create", args: [spaceName], options: options))
    }

    func finishSubmission(error: String? = nil) {
        guard let error else { dismiss(self); return }
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        setSubmitting(false)
        if error.contains("代理") || error.contains("proxy") || error.contains("127.0.0.1") {
            if !proxyRow.isHidden { view.window?.makeFirstResponder(proxy) }
        } else if error.contains("CA") || error.contains("证书") {
            if !caRow.isHidden { view.window?.makeFirstResponder(ca) }
        } else {
            view.window?.makeFirstResponder(name)
        }
    }

    private func setSubmitting(_ value: Bool) {
        submitting = value
        create.title = value ? "正在创建…" : "创建"
        progress.isHidden = !value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        for control: NSControl in [name, mode, proxy, advanced, tls, ca, chooseCA, cancel] {
            control.isEnabled = !value
        }
        updateFields()
    }
}
