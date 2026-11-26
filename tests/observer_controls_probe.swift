
// A prohibited background application cannot be the WindowServer's key window.
// Supply that precondition only during synchronous AppKit menu dispatch.
private final class ObserverProbeWindow: NSWindow {
    var dispatchAsKey = false
    private var previousApp: NSRunningApplication?

    func prepareForegroundShortcut() async -> Bool {
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        makeKeyAndOrderFront(nil)
        for _ in 0..<80 where !NSApp.isActive || !super.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return NSApp.isActive && super.isKeyWindow
    }

    func releaseForeground() {
        orderOut(nil)
        if NSApp.isActive { previousApp?.activate(options: []) }
        NSApp.setActivationPolicy(.prohibited)
        previousApp = nil
    }
    override var isKeyWindow: Bool { dispatchAsKey || super.isKeyWindow }
}

extension ObserverWindow {
    private static let probeClock = ContinuousClock.now

    func probeControls(_ action: String, request: [String: String]) async -> [String: Any] {
        let tabID = request["tab"].flatMap(UUID.init(uuidString:))
        let row = tabStack.arrangedSubviews.compactMap { $0 as? PageTabView }.first {
            $0.closeButton.identifier?.rawValue == tabID?.uuidString
        }
        var dispatched = false
        var simulatedKey = false
        func click(_ button: NSButton?) {
            guard let button, button.isEnabled else { return }
            dispatched = true
            button.performClick(nil)
        }
        func controls(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { controls($0) }
        }
        switch action {
        case "submit-address":
            guard address.isEnabled, let url = request["url"] else { break }
            focusAddress(nil)
            address.stringValue = url
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: address))
            dispatched = address.sendAction(address.action, to: address.target)
        case "type-find":
            if let field = controls(pageFind).compactMap({ $0 as? NSSearchField }).first {
                field.stringValue = request["text"] ?? ""
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                dispatched = true
            }
        case "history-back", "history-forward", "show-find":
            let selector = action == "show-find" ? #selector(findInPage(_:)) : action == "history-back" ? #selector(goBack) : #selector(goForward)
            let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            if let item = items.first(where: { $0.action == selector }), validateMenuItem(item) {
                dispatched = NSApp.sendAction(selector, to: item.target, from: item)
            }
        case "search-return":
            guard await (window as? ObserverProbeWindow)?.prepareForegroundShortcut() == true,
                  window.makeFirstResponder(search) else { break }
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            window.sendEvent(enter)
            dispatched = true
        case "expire-history":
            if let tabID { currentSpace?.activity[tabID]?.agentFinishedAt = .now.advanced(by: .seconds(-301)); refresh() }
        case "pick": click(row?.titleButton)
        case "view-popup":
            if !popupNotice.isHidden { click(controls(popupNotice).compactMap { $0 as? NSButton }.first { $0.title == "查看新标签页" }) }
        case "edit-prompt":
            let prompt = controls(dialogArea).compactMap { $0 as? NSTextField }.first { $0.isEditable }
            if let prompt {
                prompt.stringValue = request["text"] ?? ""
                prompt.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: prompt))
            }
        case "answer-dialog":
            click(controls(dialogArea).compactMap { $0 as? NSButton }.first { $0.title == request["button"] })
        case "close": click(row?.closeButton)
        case "reload": click(reloadButton)
        case "retry-navigation":
            if !retry.isHiddenOrHasHiddenAncestor { click(retry) }
        case "delete": click(deleteButton)
        case "suspend": click(suspendButton)
        case "dismiss-downloads": downloadsPopover.close()
        case "sheet":
            let buttons = controls(window.attachedSheet?.contentView).compactMap { $0 as? NSButton }
            click(buttons.first { $0.title == request["button"] })
        case "quit": dispatched = true; NSApp.terminate(nil)
        case "release-foreground":
            (window as? ObserverProbeWindow)?.releaseForeground()
        case "cmd-w", "shift-cmd-w":
            let probeWindow = window as? ObserverProbeWindow
            if ProcessInfo.processInfo.environment["BROWSER_TEST_FOREGROUND"] == "1" {
                guard await probeWindow?.prepareForegroundShortcut() == true else { break }
            }
            simulatedKey = !window.isKeyWindow
            probeWindow?.dispatchAsKey = simulatedKey
            defer { probeWindow?.dispatchAsKey = false }
            let shift = action == "shift-cmd-w"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: shift ? "W" : "w", charactersIgnoringModifiers: shift ? "W" : "w",
                                         isARepeat: false, keyCode: 13)!
            dispatched = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        default: break
        }
        // Allow the control's MainActor task and sheet completion to run.
        if dispatched { try? await Task.sleep(for: .milliseconds(100)) }
        let activity = tabID.flatMap { currentSpace?.activity[$0] }
        let sheet = controls(window.attachedSheet?.contentView)
        let dialog = dialogArea.arrangedSubviews.first as? PageDialogView
        return ["dispatched": dispatched, "simulatedKey": simulatedKey, "visible": window.isVisible,
                "addressEnabled": address.isEnabled, "addressDisplay": addressDisplay.stringValue,
                "findVisible": !pageFind.isHidden, "canGoForward": canTraverse(back: false),
                "findFeedback": controls(pageFind).compactMap { ($0 as? NSTextField)?.stringValue },
                "popupNoticeTabId": popupNotice.isHidden ? NSNull() as Any : announcedPopup?.id.uuidString as Any? ?? NSNull(),
                "downloadsSpaceId": downloadsPopover.isShown ? downloadsSpace?.record.id.uuidString as Any? ?? NSNull() : NSNull(),
                "dialogID": dialog?.dialogID as Any? ?? NSNull(),
                "promptText": controls(dialog).compactMap { $0 as? NSTextField }.first { $0.isEditable }?.stringValue as Any? ?? NSNull(),
                "tabWaiting": row?.titleButton.toolTip?.contains("网页等待回复") == true,
                "tabButtonWidth": row?.bounds.width ?? 0,
                "lastTabHelp": row?.closeButton.toolTip ?? "",
                "bannerText": bannerText.stringValue, "retryVisible": !retry.isHiddenOrHasHiddenAncestor,
                "buttons": sheet.compactMap { ($0 as? NSButton)?.title },
                "sheetText": sheet.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " "),
                "executing": activity?.executing ?? 0, "recent": activity?.recent == true,
                "finished": activity?.agentFinishedAt.map { String(describing: Self.probeClock.duration(to: $0)) } as Any? ?? NSNull()]
    }
}
