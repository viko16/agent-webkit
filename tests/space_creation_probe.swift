
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
