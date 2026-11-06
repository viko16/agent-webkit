import AppKit

extension BackgroundKey {
    var event: (characters: String, ignoring: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .enter: return ("\r", "\r", 36, [])
        case .tab: return ("\t", "\t", 48, [])
        case .escape: return ("\u{1b}", "\u{1b}", 53, [])
        case .left: return ("\u{f702}", "\u{f702}", 123, [])
        case .right: return ("\u{f703}", "\u{f703}", 124, [])
        case .up: return ("\u{f700}", "\u{f700}", 126, [])
        case .down: return ("\u{f701}", "\u{f701}", 125, [])
        case .backspace: return ("\u{7f}", "\u{7f}", 51, [])
        case .delete: return ("\u{f728}", "\u{f728}", 117, [])
        case .shiftLeft: return ("\u{f702}", "\u{f702}", 123, .shift)
        case .optionLeft: return ("\u{f702}", "\u{f702}", 123, .option)
        case .controlB: return ("\u{2}", "b", 11, .control)
        case .shiftX: return ("X", "x", 7, .shift)
        }
    }
}

extension Tab {
    private func inputWindow() throws -> NSWindow {
        guard !closed else { throw BrowserError("tab_closed", "标签页已关闭") }
        guard !terminated else { throw BrowserError("web_content_terminated", "请重新加载页面并 focus") }
        guard !unresponsive else { throw BrowserError("web_content_unresponsive", "请重新加载页面并 focus") }
        guard !navigationPending, !webView.isLoading else { throw BrowserError("input_target_changed", "导航尚未结束，请先观察页面并重新 focus") }
        guard deadline.map({ monotonicNow() < $0 }) ?? true else { throw BrowserError("timeout", "尚未发送原生输入，命令已超时") }
        guard let window = webView.window else { throw BrowserError("input_unavailable", "目标 WebView 尚未挂载到窗口") }
        let responder = window.firstResponder as? NSView
        let inPage = responder.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
        let editing = responder is NSTextView || (responder as? NSTextField)?.currentEditor() != nil
        if window !== backingWindow, !inPage,
           inputFocusConflict?() == true || (responder != nil && (!editing || window.isKeyWindow || NSApp.isActive)) {
            throw BrowserError("input_focus_conflict", "观察窗口的焦点位于其他控件；请先结束操作，后台输入不会抢走其焦点")
        }
        return window
    }

    /// Dispatch to the actual owner after GUI reparenting; never activate or post global input.
    private func withInputResponder(_ body: () throws -> Void) throws {
        let window = try inputWindow(), previous = window.firstResponder
        let view = previous as? NSView
        let inPage = view.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
        guard inPage || window.makeFirstResponder(webView) else { throw BrowserError("input_focus_failed", "目标窗口拒绝 WebView responder") }
        defer {
            if window !== backingWindow, !inPage { window.makeFirstResponder(previous) }
        }
        try body()
    }

    func focus(target: String) async throws -> [String: Any] {
        inputDocumentEpoch = nil
        let window = try inputWindow()
        let sequence = navigationSequence
        guard let state = try await runJS("window.__agentWebKit.focus(\(try quoteJS(target)))", world: DOM.world) as? [String: Any],
              let epoch = state["epoch"] as? String, sequence == navigationSequence else {
            throw BrowserError("input_target_changed", "聚焦期间文档已改变，请重新确认目标")
        }
        let result = try await inputObservation(epoch: epoch, target: target)
        guard sequence == navigationSequence, webView.window === window else {
            throw BrowserError("input_target_changed", "聚焦期间文档或宿主窗口已改变，请重新确认目标")
        }
        try withInputResponder({})
        inputDocumentEpoch = epoch
        return result.merging(["method": "dom-focus-and-appkit-responder", "focused": true, "responderAccepted": true]) { _, new in new }
    }

    private func inputObservation(epoch: String, target: String? = nil) async throws -> [String: Any] {
        let targetLiteral = try target.map(quoteJS) ?? "null"
        guard var state = try await runJS("window.__agentWebKit.inputState(\(try quoteJS(epoch)),\(targetLiteral))", world: DOM.world) as? [String: Any] else {
            throw BrowserError("input_unavailable", "无法读取输入状态；动作可能已生效")
        }
        state.removeValue(forKey: "epoch")
        state["nativeVerified"] = false
        state["physicalInput"] = false
        state["userActivationVerified"] = false
        state["businessOutcomeVerified"] = false
        state["requiresForeground"] = false
        return state
    }

    func key(_ key: BackgroundKey) async throws -> [String: Any] {
        guard let epoch = inputDocumentEpoch else { throw BrowserError("input_focus_required", "请先对该 Tab 显式 focus；加载、休眠或重启后需重新聚焦") }
        let window = try inputWindow()
        let sequence = navigationSequence
        guard let state = try await runJS("window.__agentWebKit.inputState(\(try quoteJS(epoch)))", world: DOM.world) as? [String: Any],
              state["actionable"] as? Bool == true else { throw BrowserError("input_focus_required", "当前主文档没有可操作焦点，请先 focus") }
        guard sequence == navigationSequence, webView.window === window else { throw BrowserError("input_target_changed", "发送前文档或宿主窗口已改变；未重试输入") }
        let spec = key.event
        try withInputResponder {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let window = webView.window,
                      let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: spec.modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: spec.characters, charactersIgnoringModifiers: spec.ignoring, isARepeat: false, keyCode: spec.code) else {
                    throw BrowserError("input_unavailable", "无法构造目标按键；输入可能部分生效，请先观察")
                }
                if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
            }
        }
        return try await inputObservation(epoch: epoch).merging([
            "method": "appkit-directed", "key": key.rawValue, "dispatched": true,
            "eventDeliveryVerified": false, "defaultBehaviorVerified": false,
            "eventTrust": "not-observed; host-constructed NSEvent, not physical input"
        ]) { _, new in new }
    }
}
