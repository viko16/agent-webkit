
// A prohibited background application cannot be the WindowServer's key window.
// Supply that precondition only during synchronous AppKit menu dispatch.
private final class ObserverProbeWindow: ObserverKeyWindow {
    var detachedToolbar: NSToolbar?
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
        case "hig-toolbar":
            if let width = request["width"].flatMap(Double.init), let content = window.contentView {
                window.setContentSize(NSSize(width: width, height: content.bounds.height))
            }
            if let testWindow = window as? ObserverProbeWindow {
                if request["hidden"] == "yes", let toolbar = window.toolbar {
                    testWindow.detachedToolbar = toolbar
                    window.toolbar = nil
                } else if request["hidden"] == "no", let toolbar = testWindow.detachedToolbar {
                    window.toolbar = toolbar
                    testWindow.detachedToolbar = nil
                }
            }
            window.displayIfNeeded()
            let visible = window.toolbar?.visibleItems?.map(\.itemIdentifier) ?? []
            let installed = window.toolbar?.items.map(\.itemIdentifier) ?? []
            return ["width": window.frame.width, "toolbarVisible": window.toolbar?.isVisible == true,
                    "overflow": installed.filter { !visible.contains($0) }.map(\.rawValue),
                    "sidebarCollapsed": split.splitViewItems.first?.isCollapsed == true,
                    "sidebarAnchor": spaceActions.window != nil && !spaceActions.isHiddenOrHasHiddenAncestor]
        case "hig-menu":
            guard let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == request["section"] }),
                  let item = menu.items.first(where: { $0.action.map(NSStringFromSelector) == request["selector"] }),
                  let selector = item.action else { return ["missing": true] }
            let enabled = item.target === self ? validateMenuItem(item) : item.isEnabled
            if (enabled && request["run"] == "yes") || request["run"] == "force" {
                dispatched = NSApp.sendAction(selector, to: item.target, from: item)
                try? await Task.sleep(for: .milliseconds(100))
            }
            let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            let matchingKeys = items.filter { $0.keyEquivalent == item.keyEquivalent && $0.keyEquivalentModifierMask == item.keyEquivalentModifierMask }
            return ["matchingKeys": matchingKeys.count, "enabled": enabled, "title": item.title, "dispatched": dispatched, "key": item.keyEquivalent,
                    "copied": NSPasteboard(name: .init(model.storagePath + ".hig-test")).string(forType: .string) ?? "",
                    "detailsHostRect": infoPopover.positioningRect.size == NSSize(width: 1, height: 1),
                    "downloadsHostRect": downloadsPopover.positioningRect.size == NSSize(width: 1, height: 1),
                    "details": infoPopover.isShown, "detailsVisible": infoPopover.contentViewController?.view.window?.isVisible == true,
                    "downloadsVisible": downloadsPopover.contentViewController?.view.window?.isVisible == true, "downloads": downloadsPopover.isShown, "zoom": displayed?.webView.pageZoom ?? 0]
        case "reopen-background":
            window.orderBack(nil)
        case "inspect-hig":
            window.contentView?.layoutSubtreeIfNeeded()
            return ["errorTextFocused": window.firstResponder === fullError, "title": window.title, "expanded": errorExpanded, "expandable": !errorDisclosure.isHidden,
                    "fullError": errorScroll.isHidden ? "" : fullError.string, "selectable": fullError.isSelectable,
                    "bounded": errorScroll.bounds.height <= 100, "editing": editingAddress, "address": address.stringValue,
                    "editor": address.currentEditor()?.string ?? "",
                    "ring": address.focusRingType != .none, "axLabel": address.cell?.accessibilityLabel() ?? "",
                    "axRole": address.cell?.accessibilityRole()?.rawValue ?? "", "axValue": address.cell?.accessibilityValue() as? String ?? "",
                    "axElement": address.cell?.isAccessibilityElement() == true, "axTitle": window.accessibilityTitle() ?? "",
                    "zoom": displayed?.webView.pageZoom ?? 0, "visible": window.isVisible]
        case "focus-error-text":
            return ["focused": window.makeFirstResponder(fullError) && window.firstResponder === fullError]
        case "expand-error":
            if !errorDisclosure.isHidden { click(errorDisclosure) }
        case "error-key":
            let probeWindow = window as? ObserverProbeWindow
            probeWindow?.dispatchAsKey = true
            defer { probeWindow?.dispatchAsKey = false }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "E", charactersIgnoringModifiers: "E", isARepeat: false, keyCode: 14)!
            return ["dispatched": window.performKeyEquivalent(with: event), "menuConflict": NSApp.mainMenu?.performKeyEquivalent(with: event) == true]
        case "address-escape":
            if let editor = address.currentEditor() as? NSTextView {
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            }
        case "address-appearance":
            address.appearance = request["appearance"].flatMap { NSAppearance(named: NSAppearance.Name($0)) }
            return ["appearance": address.effectiveAppearance.name.rawValue, "ring": address.focusRingType != .none,
                    "bezeled": address.isBezeled, "editor": address.currentEditor()?.string ?? ""]
        case "address-mouse":
            window.displayIfNeeded()
            let point = address.convert(NSPoint(x: address.bounds.midX, y: address.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            guard let root = window.contentView?.superview, let hit = root.hitTest(root.convert(point, from: nil)),
                  hit === address || hit.isDescendant(of: address) else {
                return ["hitField": false, "toolbarVisible": window.toolbar?.isVisible == true]
            }
            // Only the test process receives these events.
            NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
            let testWindow = window as? ObserverProbeWindow
            testWindow?.dispatchAsKey = true
            defer { testWindow?.dispatchAsKey = false }
            window.sendEvent(mouse(.leftMouseDown))
            return ["hitField": true]
        case "address-text-system":
            guard let editor = address.currentEditor() as? NSTextView else { return [:] }
            let board = NSPasteboard(name: .init(model.storagePath + ".address-test"))
            board.clearContents()
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            let types = editor.writablePasteboardTypes
            let wrote = editor.writeSelection(to: board, types: types)
            let copied = wrote && board.readObjects(forClasses: [NSString.self])?.first as? String == editor.string
            board.clearContents()
            board.setString("输入", forType: .string)
            let pasted = editor.readSelection(from: board, type: .string)
            editor.selectAll(nil)
            editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
            refresh()
            let marked = editor.hasMarkedText() && editor.string == "拼"
            editor.insertText("拼音", replacementRange: editor.markedRange())
            return ["copied": copied, "pasted": pasted, "marked": marked, "committed": editor.string]
        case "create-form-input":
            guard let sheet = split.presentedViewControllers?.last as? SpaceCreationSheet else { return [:] }
            return sheet.probeInput(name: request["name"], key: request["key"])
        case "address-key-loop":
            let probeWindow = window as? ObserverProbeWindow
            probeWindow?.dispatchAsKey = !window.isKeyWindow
            defer { probeWindow?.dispatchAsKey = false }
            let wasEditing = address.currentEditor() != nil
            if !wasEditing { focusSpaces(nil) }
            let control = wasEditing ? address : search
            let editor = control.currentEditor() as? NSTextView
            let reverse = request["reverse"] == "yes"
            editor?.doCommand(by: reverse ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:)))
            return ["fromEditor": editor != nil, "toAddress": address.currentEditor() != nil, "toSearch": search.currentEditor() != nil]
        case "address-backtab-entry":
            let probeWindow = window as? ObserverProbeWindow
            probeWindow?.dispatchAsKey = !window.isKeyWindow
            defer { probeWindow?.dispatchAsKey = false }
            guard let next = search.nextValidKeyView, next !== address, window.makeFirstResponder(next) else { return ["entered": false] }
            window.selectKeyView(preceding: next)
            return ["entered": address.currentEditor() != nil]
        case "details":
            if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .details }),
               let action = item.action, item.isEnabled {
                dispatched = NSApp.sendAction(action, to: item.target, from: item)
            }
        case "inspect-details":
            return ["tabID": SpaceDetailsView.probeDisplayedTab?.uuidString as Any? ?? NSNull(),
                    "visible": infoPopover.isShown && infoPopover.contentViewController?.view.window?.isVisible == true]
        case "close-others":
            if let menu = row?.contextMenuProvider?(),
               let index = menu.items.firstIndex(where: { $0.action == #selector(contextCloseOtherTabs(_:)) }),
               menu.items[index].isEnabled {
                menu.performActionForItem(at: index)
                dispatched = true
            }
        case "stop", "stop-delay-callback":
            if reloadButton.action == #selector(stopLoadingPage), reloadButton.isEnabled {
                displayed?.holdNextCancellation = action == "stop-delay-callback"
                click(reloadButton)
            }
        case "inspect-cancellation":
            return ["held": displayed?.heldCancellation != nil, "pending": displayed?.navigationPending == true]
        case "stop-subresources":
            guard let tab = displayed, !tab.navigationPending else { break }
            if reloadButton.action == #selector(stopLoadingPage) && reloadButton.isEnabled {
                click(reloadButton)
            } else {
                // Some WebKit versions keep the toolbar in reload mode for a background fetch.
                tab.stopLoadingByObserver()
                dispatched = true
            }
        case "release-cancellation":
            if let tab = displayed, let callback = tab.heldCancellation {
                tab.heldCancellation = nil
                callback()
                dispatched = true
            }
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
        case "address-return":
            let editor = NSTextView(); editor.string = request["text"] ?? ""
            beginAddressEditing()
            address.stringValue = editor.string
            dispatched = control(address, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        case "resume-empty": click(emptyAction)
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
        case "create-space": click(createButton)
        case "delete", "suspend", "resume":
            guard spaceActions.isEnabled, let menu = spaceActions.menu else { break }
            NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: spaceActions)
            if let index = menu.items.firstIndex(where: { ($0.representedObject as? Request)?.command == "space." + action }) {
                menu.performActionForItem(at: index)
                dispatched = true
            }
        case "dismiss-downloads": downloadsPopover.close()
        case "sheet":
            let buttons = controls(window.attachedSheet?.contentView).compactMap { $0 as? NSButton }
            click(buttons.first { $0.title == request["button"] })
        case "quit": dispatched = true; NSApp.terminate(nil)
        case "release-foreground":
            (window as? ObserverProbeWindow)?.releaseForeground()
        case "cmd-w", "shift-cmd-w", "cmd-l", "cmd-plus", "cmd-equals", "cmd-minus", "cmd-zero":
            let probeWindow = window as? ObserverProbeWindow
            if ProcessInfo.processInfo.environment["BROWSER_TEST_FOREGROUND"] == "1" {
                guard await probeWindow?.prepareForegroundShortcut() == true else { break }
            }
            simulatedKey = !window.isKeyWindow
            probeWindow?.dispatchAsKey = simulatedKey
            defer { probeWindow?.dispatchAsKey = false }
            let character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
            switch action {
            case "cmd-plus": (character, keyCode, modifiers) = ("+", 24, [.command, .shift])
            case "cmd-equals": (character, keyCode, modifiers) = ("=", 24, [.command])
            case "cmd-minus": (character, keyCode, modifiers) = ("-", 27, [.command])
            case "cmd-zero": (character, keyCode, modifiers) = ("0", 29, [.command])
            case "cmd-l": (character, keyCode, modifiers) = ("l", 37, [.command])
            case "shift-cmd-w": (character, keyCode, modifiers) = ("W", 13, [.command, .shift])
            default: (character, keyCode, modifiers) = ("w", 13, [.command])
            }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: keyCode)!
            dispatched = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        default: break
        }
        // Allow the control's MainActor task and sheet completion to run.
        if dispatched && !action.hasPrefix("stop") { try? await Task.sleep(for: .milliseconds(100)) }
        let activity = tabID.flatMap { currentSpace?.activity[$0] }
        let sheet = controls(window.attachedSheet?.contentView)
        let dialog = dialogArea.arrangedSubviews.first as? PageDialogView
        return ["dispatched": dispatched, "simulatedKey": simulatedKey, "visible": window.isVisible,
                "addressEnabled": address.isEnabled, "addressDisplay": address.stringValue,
                "findVisible": !pageFind.isHidden, "canGoForward": canTraverse(back: false),
                "findFeedback": controls(pageFind).compactMap { ($0 as? NSTextField)?.stringValue },
                "popupNoticeTabId": popupNotice.isHidden ? NSNull() as Any : announcedPopup?.id.uuidString as Any? ?? NSNull(),
                "downloadsSpaceId": downloadsPopover.isShown ? downloadsSpace?.record.id.uuidString as Any? ?? NSNull() : NSNull(),
                "dialogID": dialog?.dialogID as Any? ?? NSNull(),
                "promptText": controls(dialog).compactMap { $0 as? NSTextField }.first { $0.isEditable }?.stringValue as Any? ?? NSNull(),
                "tabWaiting": row?.titleButton.toolTip?.contains("网页等待回复") == true,
                "tabButtonWidth": row?.bounds.width ?? 0,
                "lastTabHelp": row?.closeButton.toolTip ?? "",
                "addressHint": addressHint.isHidden ? "" : addressHint.stringValue,
                "addressValue": address.stringValue, "footer": status.stringValue,
                "navigationErrorCode": (displayed?.navigationError as? BrowserError)?.code ?? "",
                "noticeAction": retry.title, "emptyAction": emptyAction.title, "emptyText": emptyText.stringValue,
                "bannerText": bannerText.stringValue, "retryVisible": !retry.isHiddenOrHasHiddenAncestor,
                "buttons": sheet.compactMap { ($0 as? NSButton)?.title },
                "sheetText": sheet.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " "),
                "executing": activity?.executing ?? 0, "recent": activity?.recent == true,
                "finished": activity?.agentFinishedAt.map { String(describing: Self.probeClock.duration(to: $0)) } as Any? ?? NSNull()]
    }
}
