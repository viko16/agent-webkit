
extension SpaceCreationSheet {
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
        submit = { [weak self] request in
            options = request.options
            self?.finishSubmission()
        }
        create.performClick(nil)
        return ["enabledWithoutCA": enabledWithoutCA, "options": options]
    }
}
