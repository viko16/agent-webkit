
extension SpaceCreationSheet {
    func probeInput(name value: String?, key: String?) -> [String: Any] {
        if let value { name.stringValue = value; inputChanged() }
        var handled = false
        if let key, let window = view.window {
            let cancel = key == "escape"
            let text = cancel ? "\u{1b}" : "\r"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: cancel ? 53 : 36)!
            handled = window.performKeyEquivalent(with: event)
            if !handled, let editor = window.firstResponder as? NSTextView {
                editor.doCommand(by: cancel ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:)))
                handled = submitting || view.window?.sheetParent == nil
            }
        }
        return ["handled": handled, "name": name.stringValue, "error": errorLabel.isHidden ? "" : errorLabel.stringValue,
                "enabled": create.isEnabled, "tls": tls.indexOfSelectedItem]
    }
    // Compiled into the test sheet's source file so these are the real controls and actions.
    func probeCollapsedTLS(_ policy: Int) -> [String: Any] {
        _ = view
        name.stringValue = "test-policy"
        advanced.performClick(nil)
        tls.selectItem(at: policy)
        updateFields()
        advanced.performClick(nil)
        let enabledWithoutCA = create.isEnabled
        if policy == 1 {
            advanced.performClick(nil)
            ca.stringValue = "/tmp/fixture-ca.pem"
            mode.selectItem(at: 1)
            proxy.stringValue = "http://127.0.0.1:8080"
            finishSubmission(error: "测试校验错误")
            view.layoutSubtreeIfNeeded()
            let left = name.convert(name.bounds, to: view).minX
            let labelLeft = caRow.convert(caRow.bounds, to: view).minX
            let right = view.bounds.maxX - chooseCA.convert(chooseCA.bounds, to: view).maxX
            let retainsForm = name.stringValue == "test-policy" && proxy.stringValue == "http://127.0.0.1:8080"
                && ca.stringValue == "/tmp/fixture-ca.pem" && !errorLabel.isHidden && create.isEnabled
            guard retainsForm, left > labelLeft, labelLeft >= 16, abs(labelLeft - right) < 1,
                  !chooseCA.isHiddenOrHasHiddenAncestor else { return ["layoutOrValuesLost": true] }
            mode.selectItem(at: 0)
            advanced.performClick(nil)
        }
        var options: [String: String] = [:]
        var sends = 0
        var progressAndRetry = false
        submit = { [weak self] request in
            guard let self else { return }
            sends += 1
            if sends == 1 {
                let blocked = !create.isEnabled && !cancel.isEnabled && submitting && !progress.isHidden && create.title == "正在创建…"
                createSpace()
                finishSubmission(error: "测试校验错误")
                progressAndRetry = blocked && sends == 1 && create.isEnabled && cancel.isEnabled && !submitting
                    && progress.isHidden && create.title == "创建" && !errorLabel.isHidden && advanced.bezelStyle == .disclosure
                    && name.stringValue == "test-policy" && tls.indexOfSelectedItem == policy
                return
            }
            options = request.options
            finishSubmission()
        }
        create.performClick(nil)
        create.performClick(nil)
        return ["progressAndRetry": progressAndRetry && sends == 2, "enabledWithoutCA": enabledWithoutCA, "options": options]
    }
}
