import AppKit

@MainActor
final class ObserverPageContent: NSObject {
    enum ProxyRecovery { case ready, blocked, needsReload }

    struct Actions {
        let showViewport: Selector
        let showBusyTab: Selector
        let showPopup: Selector
        let dismissPopup: Selector
        let startBrowsing: Selector
        let recheckProxy: Selector
        let dismissNotice: Selector
        let retryNavigation: Selector
    }

    private let actions: Actions
    let host = NSView()
    private let addressHint = NSTextField(labelWithString: "")
    private let addressHintBar = ChromeBarView()
    private let dialogArea = NSStackView()
    private let popupNotice = ChromeBarView()
    private let popupNoticeText = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let busyTarget = NSButton(title: "查看执行页", target: nil, action: nil)
    private let security = NSTextField(labelWithString: "")
    private let viewportButton = NSButton(title: "", target: nil, action: nil)
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "浏览会话，各自独立")
    private let emptyText = NSTextField(wrappingLabelWithString: "")
    private let emptyAction = NSButton(title: "打开网页", target: nil, action: nil)
    private let emptyCreateSpace = NSButton(title: "新建 Space…", target: nil, action: nil)
    private let banner = ChromeBarView()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private let errorTextLayout = NSLayoutManager()
    private let errorMessageColumn = NSStackView()
    private let errorDisclosure = NSButton(title: "展开", target: nil, action: nil)
    private let errorScroll = NSScrollView()
    private let fullError = NSTextView()
    private var errorExpanded = false
    private var errorTab: UUID?
    private let retry = NSButton(title: "重新加载", target: nil, action: nil)

    init(actions: Actions) { self.actions = actions }

    var statusBaseline: NSLayoutYAxisAnchor { status.firstBaselineAnchor }

    func install(in split: NSSplitViewController, owner: ObserverWindow, tabBar: NSView, pageFind: PageFindBar) {
        let controller = NSViewController(); controller.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(viewController: controller))
        let column = NSStackView()
        column.orientation = .vertical; column.spacing = 0; column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            column.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.heightAnchor.constraint(equalToConstant: 2).isActive = true
        banner.orientation = .horizontal; banner.spacing = 10
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        banner.fillColor = .controlBackgroundColor
        banner.tintColor = NSColor.systemOrange.withAlphaComponent(0.07)
        banner.bottomBorder = true
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "页面需要处理")!)
        warning.contentTintColor = .systemOrange
        bannerText.font = .systemFont(ofSize: 12); bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerText.maximumNumberOfLines = 2
        retry.target = owner; retry.action = #selector(ObserverWindow.reloadPage); retry.bezelStyle = .rounded
        errorMessageColumn.orientation = .vertical
        errorMessageColumn.alignment = .leading
        errorMessageColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fullError.isEditable = false; fullError.isSelectable = true; fullError.drawsBackground = false
        fullError.font = bannerText.font; fullError.textColor = .labelColor
        fullError.setAccessibilityLabel("完整错误信息")
        fullError.isVerticallyResizable = true; fullError.isHorizontallyResizable = false
        fullError.autoresizingMask = [.width]; fullError.textContainer?.widthTracksTextView = true
        errorScroll.documentView = fullError; errorScroll.hasVerticalScroller = true
        errorScroll.autohidesScrollers = true; errorScroll.drawsBackground = false
        errorScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        for view in [bannerText, errorScroll] as [NSView] {
            errorMessageColumn.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: errorMessageColumn.widthAnchor).isActive = true
        }
        errorScroll.isHidden = true
        errorDisclosure.target = self; errorDisclosure.action = #selector(toggleErrorDetails)
        errorDisclosure.bezelStyle = .rounded; errorDisclosure.isHidden = true
        errorDisclosure.keyEquivalent = "E"
        errorDisclosure.keyEquivalentModifierMask = [.command, .shift]
        errorDisclosure.toolTip = "展开或收起完整错误信息（⇧⌘E）"
        errorDisclosure.setAccessibilityHelp(errorDisclosure.toolTip)
        errorMessageColumn.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateErrorDisclosure),
            name: NSView.frameDidChangeNotification, object: errorMessageColumn)
        [warning, errorMessageColumn, errorDisclosure, retry].forEach { banner.addArrangedSubview($0) }
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.clipsToBounds = true
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        viewportButton.target = owner; viewportButton.action = actions.showViewport
        viewportButton.bezelStyle = .inline
        viewportButton.toolTip = "缩放查看整个固定视口"
        busyTarget.bezelStyle = .inline; busyTarget.target = owner; busyTarget.action = actions.showBusyTab
        let footer = ChromeBarView(views: [status, busyTarget, NSView(), viewportButton, security])
        footer.orientation = .horizontal; footer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        footer.fillColor = .windowBackgroundColor
        footer.topBorder = true
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for label in [status, security] {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        dialogArea.orientation = .vertical
        dialogArea.isHidden = true
        let viewPopup = NSButton(title: "查看新标签页", target: owner, action: actions.showPopup)
        let dismissNotice = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提示")!,
                                     target: owner, action: actions.dismissPopup)
        dismissNotice.isBordered = false; dismissNotice.toolTip = "关闭提示"
        popupNoticeText.font = .systemFont(ofSize: 13)
        popupNoticeText.lineBreakMode = .byTruncatingTail
        popupNoticeText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popupNotice.orientation = .horizontal; popupNotice.spacing = 10
        popupNotice.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        popupNotice.fillColor = .controlBackgroundColor
        popupNotice.bottomBorder = true
        [popupNoticeText, NSView(), viewPopup, dismissNotice].forEach { popupNotice.addArrangedSubview($0) }
        addressHint.font = .systemFont(ofSize: 12)
        addressHint.textColor = .systemRed
        addressHint.alignment = .center
        addressHint.lineBreakMode = .byTruncatingTail
        addressHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressHint.isHidden = true
        addressHintBar.orientation = .vertical
        addressHintBar.alignment = .centerX
        addressHintBar.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 5, right: 16)
        addressHintBar.fillColor = .controlBackgroundColor
        addressHintBar.tintColor = NSColor.systemRed.withAlphaComponent(0.06)
        addressHintBar.bottomBorder = true
        addressHintBar.addArrangedSubview(addressHint)
        addressHint.widthAnchor.constraint(lessThanOrEqualTo: addressHintBar.widthAnchor, constant: -32).isActive = true
        addressHintBar.isHidden = true
        [tabBar, addressHintBar, progress, popupNotice, banner, dialogArea, pageFind, host, footer].forEach {
            column.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor; icon.symbolConfiguration = .init(pointSize: 46, weight: .light)
        emptyTitle.font = .systemFont(ofSize: 23, weight: .semibold)
        emptyText.font = .systemFont(ofSize: 13); emptyText.textColor = .secondaryLabelColor; emptyText.alignment = .center
        emptyAction.target = owner; emptyAction.action = actions.startBrowsing; emptyAction.bezelStyle = .rounded
        emptyCreateSpace.target = owner; emptyCreateSpace.action = #selector(ObserverWindow.createSpace); emptyCreateSpace.bezelStyle = .rounded
        let emptyButtons = NSStackView(views: [emptyAction, emptyCreateSpace])
        emptyButtons.orientation = .horizontal; emptyButtons.spacing = 8
        empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 14
        [icon, emptyTitle, emptyText, emptyButtons].forEach { empty.addArrangedSubview($0) }
        empty.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: host.centerXAnchor), empty.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
            emptyText.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        ])
    }

    func prepareEmptyState(restoring: Bool, creatingTab: Bool, space: Space?, hasSpaces: Bool) {
        emptyAction.title = "打开网页"
        emptyText.maximumNumberOfLines = 0
        emptyText.toolTip = nil
        emptyAction.isEnabled = !restoring && !creatingTab && space?.busy != true
        emptyCreateSpace.isEnabled = !restoring
        emptyCreateSpace.isHidden = hasSpaces
    }

    func showNoSpace(searching: Bool) {
        empty.isHidden = searching
        emptyTitle.stringValue = "浏览会话，各自独立"
        emptyText.stringValue = "在地址栏输入网址，按回车打开。\n首次打开会创建 personal Space，使用直连和系统证书校验。"
    }

    func showEmptyState(in space: Space, tab: Tab?, selected: UUID?) -> Bool {
        let blank = space.suspended || tab?.persistedURL == "about:blank"
        empty.isHidden = !blank
        if space.suspended {
            emptyTitle.stringValue = "“\(space.record.name)”已休眠"
            let target = space.record.tabs.first { $0.id == selected } ?? space.record.tabs.first
            let destination = target.map {
                if let title = $0.title, !title.isEmpty { return title }
                if $0.url == "about:blank" { return "新标签页" }
                return URL(string: $0.url)?.observerDisplayAddress ?? "上次的页面"
            } ?? "新标签页"
            emptyText.stringValue = "恢复后将打开 \(space.record.tabs.count) 个标签页，回到“\(destination)”。\n网站数据已保留，未提交的表单内容已清除。"
            emptyText.maximumNumberOfLines = 3
            emptyText.toolTip = destination
            emptyAction.title = "恢复 Space"
        } else if blank {
            emptyTitle.stringValue = "新标签页"
            emptyText.stringValue = "在地址栏输入网址，按回车打开。\n准备好后，点「交给 Agent」复制接管命令。"
        }
        return blank
    }

    func bringEmptyStateForward(over tab: Tab?) {
        host.addSubview(empty, positioned: .above, relativeTo: tab?.webView)
    }

    func setAddressHint(_ message: String?) {
        if let message { addressHint.stringValue = message }
        addressHint.isHidden = message == nil
        addressHintBar.isHidden = message == nil
    }

    func updatePopup(_ announcedPopup: Tab?, tab: Tab?) {
        popupNotice.isHidden = announcedPopup == nil
        if let popup = announcedPopup {
            let title = popup.webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: popup.persistedURL)?.host
            popupNoticeText.stringValue = title.map { "此网页打开了新标签页「\($0)」" } ?? "此网页打开了新标签页"
            popupNoticeText.toolTip = popupNoticeText.stringValue
        }
        viewportButton.isHidden = tab?.fixedViewport == nil
        if let size = tab?.fixedViewport {
            viewportButton.title = "预览 \(Int(size.width)) × \(Int(size.height))"
        }
    }

    func updateDialogs(for tab: Tab?) {
        let pendingDialog = tab?.dialogs.firstPending
        let pendingCount = tab?.dialogs.pendingCount ?? 0
        let previousDialog = dialogArea.arrangedSubviews.first as? PageDialogView
        if previousDialog?.dialogID != pendingDialog?.id {
            previousDialog?.removeFromSuperview()
            if let pendingDialog, let tab {
                let view = PageDialogView(pendingDialog, totalPending: pendingCount, store: tab.dialogs)
                dialogArea.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: dialogArea.widthAnchor).isActive = true
            }
            dialogArea.isHidden = pendingDialog == nil
        } else if pendingDialog != nil {
            previousDialog?.updatePendingCount(pendingCount)
        }
    }

    func updateProgress(for tab: Tab?, loading isLoading: Bool) {
        progress.doubleValue = isLoading ? max(0.03, tab?.webView.estimatedProgress ?? 0) : 0
        progress.alphaValue = isLoading ? 1 : 0
    }

    func updateFooter(for space: Space?, tab: Tab?, restoring: Bool, networkPaused: Bool,
                      editingAddress: Bool, transientMessage: String?, loading isLoading: Bool) {
        let runningTab = space?.tabs.first { $0.id == space?.busyTabID }
        busyTarget.isHidden = runningTab == nil || runningTab === tab
        if tab?.dialogs.firstPending != nil { status.stringValue = "网页等待回复" }
        else if restoring { status.stringValue = "正在恢复会话…" }
        else if networkPaused { status.stringValue = "网络连接已暂停" }
        else if space?.busy == true {
            let name = runningTab.map(ObserverTabStrip.title(of:)) ?? "当前 Space"
            status.stringValue = editingAddress ? "「\(name)」执行中，结束后按回车打开" : "「\(name)」正在执行"
        }
        else if let transientMessage { status.stringValue = transientMessage }
        else if space?.suspended == true { status.stringValue = "Space 已休眠" }
        else if isLoading { status.stringValue = "正在加载…" }
        else { status.stringValue = "准备就绪" }
        status.toolTip = status.stringValue
        let scheme = tab.flatMap { URL(string: $0.committedDocumentURL)?.scheme?.lowercased() }
        let connection: String
        switch scheme {
        case "http": connection = "HTTP（未加密）"
        case "https": connection = "HTTPS"
        default: connection = "无网页连接"
        }
        let insecureHTTPS = scheme == "https" && space?.record.tls?.ignoreCertificateErrors == true
        let warning = networkPaused ? "网络已暂停" : insecureHTTPS ? "允许证书错误" : nil
        security.stringValue = space == nil ? "" : [connection, warning].compactMap { $0 }.joined(separator: " · ")
        security.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        security.toolTip = space.map { "当前页：\(connection)\nSpace 证书策略：\(certificatePolicy(of: $0))" }
    }

    func updateNotice(for space: Space?, tab: Tab?, networkError: BrowserError?, actionMessage: String?,
                      proxyState: ProxyRecovery, checkedBlockedProxy: Bool, canReload: Bool) {
        let recheckProxy = proxyState != .ready
        let networkPaused = recheckProxy || networkError != nil
        let rejection = tab?.observerDismissedRejection == true ? nil : tab?.lastNavigationRejection
        let error = networkError?.localizedDescription ?? actionMessage ?? rejection?.localizedDescription ?? (tab?.unresponsive == true ? "页面未响应。重新加载可恢复标签页；上次操作可能已部分生效。" : tab?.navigationError?.localizedDescription)
        let failedNavigation = !networkPaused && actionMessage == nil && rejection == nil && tab?.unresponsive == false && tab?.hasFailedNavigation == true
        let target = failedNavigation ? tab?.failedNavigationTarget : nil
        if checkedBlockedProxy {
            bannerText.stringValue = "系统代理仍已开启。关闭后可再次检查。"
        } else if recheckProxy {
            bannerText.stringValue = proxyState == .needsReload ? "系统代理设置已更改。重新检查后可恢复此页面。" : "直连已暂停。请关闭系统代理，然后重新检查。"
        } else if actionMessage == nil && rejection?.code == "unsupported_navigation" {
            bannerText.stringValue = "未打开此链接。浏览器支持 HTTP、HTTPS 和 about:blank，当前页面已保留。"
        } else if let target, let error {
            let address = target.url.observerDisplayAddress
            let detail = error.replacingOccurrences(of: target.url.absoluteString, with: address)
            bannerText.stringValue = "无法打开 \(address)\n\(detail)"
        } else {
            bannerText.stringValue = error ?? ""
        }
        if errorTab != tab?.id || fullError.string != bannerText.stringValue || error == nil {
            errorExpanded = false
            errorTab = tab?.id
            fullError.string = bannerText.stringValue
            fullError.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        bannerText.toolTip = bannerText.stringValue
        banner.isHidden = error == nil
        let dismissible = rejection != nil || actionMessage != nil
        if recheckProxy {
            retry.title = "重新检查"; retry.action = actions.recheckProxy
        } else if dismissible {
            retry.title = "忽略"; retry.action = actions.dismissNotice
        } else {
            retry.title = failedNavigation ? "重试此网址" : "重新加载"
            retry.action = failedNavigation ? actions.retryNavigation : #selector(ObserverWindow.reloadPage)
        }
        retry.isHidden = (networkError != nil && !recheckProxy) || (failedNavigation && target?.isGET != true)
        updateErrorDisclosure()
        retry.isEnabled = recheckProxy ? space != nil && space?.busy == false : dismissible || canReload
    }

    @objc private func toggleErrorDetails() {
        guard !errorDisclosure.isHiddenOrHasHiddenAncestor, banner.window?.attachedSheet == nil else { return }
        errorExpanded.toggle()
        updateErrorDisclosure()
    }
    @objc private func updateErrorDisclosure() {
        // Measure at the width the compact text would have without the disclosure button.
        let width = errorMessageColumn.bounds.width + (errorDisclosure.isHidden ? 0 : errorDisclosure.bounds.width + banner.spacing)
        let font = bannerText.font ?? NSFont.systemFont(ofSize: 12)
        let height = (bannerText.stringValue as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let truncated = !banner.isHidden && width > 0 && ceil(height) > 2 * ceil(errorTextLayout.defaultLineHeight(for: font))
        if !truncated { errorExpanded = false }
        errorDisclosure.isHidden = !truncated
        errorDisclosure.title = errorExpanded ? "收起" : "展开"
        errorDisclosure.setAccessibilityLabel(errorExpanded ? "收起错误信息" : "展开完整错误信息")
        errorDisclosure.setAccessibilityExpanded(errorExpanded)
        errorScroll.isHidden = !errorExpanded
        bannerText.isHidden = errorExpanded
    }
    private func certificatePolicy(of space: Space) -> String {
        if space.record.tls?.ignoreCertificateErrors == true { return "忽略证书错误" }
        return space.record.tls == nil ? "系统证书校验" : "系统证书及自定义 CA"
    }
}
