import AppKit

@MainActor
final class ObserverTabStrip: NSObject, NSMenuItemValidation {
    private weak var owner: ObserverWindow?
    private let currentSpace: () -> Space?
    private let selectedID: (Space) -> UUID?
    private let selectTab: (Int, Space) -> Void
    private let request: (Request) -> Void
    private let copyURL: (String) -> Void
    private let handoff: (Space, Tab) -> Void
    let tabBar = ChromeBarView()
    private let tabStack = NSStackView()
    private let allTabs = NSPopUpButton(frame: .zero, pullsDown: true)
    private var tabWidths: [NSLayoutConstraint] = []
    private var tabSignature = ""

    init(owner: ObserverWindow, currentSpace: @escaping () -> Space?, selectedID: @escaping (Space) -> UUID?,
         selectTab: @escaping (Int, Space) -> Void, request: @escaping (Request) -> Void,
         copyURL: @escaping (String) -> Void, handoff: @escaping (Space, Tab) -> Void) {
        self.owner = owner
        self.currentSpace = currentSpace
        self.selectedID = selectedID
        self.selectTab = selectTab
        self.request = request
        self.copyURL = copyURL
        self.handoff = handoff
        super.init()
        let tabs = NSScrollView(); tabs.drawsBackground = false; tabs.hasHorizontalScroller = false
        tabStack.orientation = .horizontal; tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        tabs.documentView = tabStack
        tabs.heightAnchor.constraint(equalToConstant: 38).isActive = true
        allTabs.addItem(withTitle: "")
        allTabs.item(at: 0)?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        allTabs.imagePosition = .imageOnly
        (allTabs.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        (allTabs.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        allTabs.bezelStyle = .accessoryBarAction
        allTabs.toolTip = "显示所有标签页"
        allTabs.setAccessibilityLabel("显示所有标签页")
        allTabs.widthAnchor.constraint(equalToConstant: 32).isActive = true
        allTabs.isHidden = true
        tabBar.orientation = .horizontal; tabBar.distribution = .fill; tabBar.spacing = 0
        tabBar.bottomBorder = true
        tabBar.addArrangedSubview(tabs); tabBar.addArrangedSubview(allTabs)
        tabBar.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resizeTabs(_:)), name: NSView.frameDidChangeNotification, object: tabBar)
    }

    func clear() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabSignature = ""
        tabWidths = []
        allTabs.isHidden = true
    }

    func scrollToTab(at index: Int) {
        guard tabStack.arrangedSubviews.indices.contains(index) else { return }
        let view = tabStack.arrangedSubviews[index]
        view.scrollToVisible(view.bounds)
    }

    func scrollToLastTab() {
        if let view = tabStack.arrangedSubviews.last { view.scrollToVisible(view.bounds) }
    }

    func refresh(in space: Space, activeTab tab: Tab?) {
        let signature = space.tabs.map {
            let activity = space.activity[$0.id]
            return "\($0.id)|\($0.webView.title ?? "")|\($0.persistedURL)|\(activity?.executing ?? 0)|\(activity?.recent == true)|\($0.dialogs.pendingCount)|\($0.downloads.hasActive)"
        }.joined() + "\(tab?.id.uuidString ?? "")|\(space.busy)"
        if signature != tabSignature {
            tabSignature = signature
            updateTabs(in: space, activeTab: tab)
        }
    }

    private func updateTabs(in space: Space, activeTab: Tab?) {
        allTabs.menu?.items.dropFirst().forEach { allTabs.menu?.removeItem($0) }
        let existing = tabStack.arrangedSubviews.compactMap { $0 as? PageTabView }
        let canReuse = existing.count == space.tabs.count && zip(existing, space.tabs).allSatisfy { $0.tabID == $1.id }
        if !canReuse {
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            tabWidths = []
        }
        for (index, candidate) in space.tabs.enumerated() {
            let title = Self.title(of: candidate)
            let isSelected = candidate === activeTab
            let item = NSMenuItem(title: title, action: #selector(selectListedTab(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = candidate.id
            item.state = isSelected ? .on : .off; item.toolTip = candidate.persistedURL
            allTabs.menu?.addItem(item)

            let activity = space.activity[candidate.id]
            let running = (activity?.executing ?? 0) > 0
            let (symbol, activityLabel, symbolColor): (String, String, NSColor?)
            if candidate.dialogs.hasPending { (symbol, activityLabel, symbolColor) = ("exclamationmark.bubble.fill", "网页等待回复", .systemOrange) }
            else if running { (symbol, activityLabel, symbolColor) = ("hourglass", "正在执行操作", .controlAccentColor) }
            else if candidate.downloads.hasActive { (symbol, activityLabel, symbolColor) = ("arrow.down.circle.fill", "正在下载", .controlAccentColor) }
            else if activity?.recent == true { (symbol, activityLabel, symbolColor) = ("globe", "最近 5 分钟有 Agent 活动", nil) }
            else { (symbol, activityLabel, symbolColor) = ("globe", "", nil) }
            let lastTabHint = space.tabs.count == 1 ? "每个 Space 至少保留一个标签页。要释放页面，可休眠 Space。" : ""
            let tooltip = [title, candidate.persistedURL, activityLabel, lastTabHint, candidate.id.uuidString].filter { !$0.isEmpty }.joined(separator: "\n")
            let canClose = space.tabs.count > 1 && !space.busy && !running
            let baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: activityLabel)
            let tabImage = symbolColor.flatMap { baseImage?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? baseImage

            let row: PageTabView
            if canReuse {
                row = existing[index]
            } else {
                let button = PageTabButton(title: title, target: self, action: #selector(pickTab(_:)))
                button.setButtonType(.toggle); button.isBordered = false
                (button.cell as? NSButtonCell)?.highlightsBy = []
                (button.cell as? NSButtonCell)?.showsStateBy = []
                button.setAccessibilityRole(.radioButton)
                button.cell?.lineBreakMode = .byTruncatingTail
                button.imagePosition = .imageLeading
                let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签页")!, target: self, action: #selector(closeTabButton(_:)))
                close.isBordered = false
                close.identifier = NSUserInterfaceItemIdentifier(candidate.id.uuidString)
                button.state = isSelected ? .on : .off
                close.isEnabled = canClose
                row = PageTabView(tabID: candidate.id, titleButton: button, closeButton: close)
                let spaceID = space.record.id
                let tabID = candidate.id
                row.onMiddleClick = { [weak self] in self?.closeTab(spaceID: spaceID, tabID: tabID) }
                row.contextMenuProvider = { [weak self] in self?.makeTabContextMenu(spaceID: spaceID, tabID: tabID) }
                let width = row.widthAnchor.constraint(equalToConstant: 220)
                width.isActive = true; tabWidths.append(width)
                tabStack.addArrangedSubview(row)
            }
            let button = row.titleButton
            button.title = title
            button.tag = index
            button.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
            button.setAccessibilityValue(isSelected ? 1 : 0)
            button.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
            button.image = tabImage
            button.toolTip = tooltip
            button.setAccessibilityHelp(lastTabHint.isEmpty ? nil : lastTabHint)
            button.setAccessibilityLabel([title, activityLabel].filter { !$0.isEmpty }.joined(separator: "，"))

            let close = row.closeButton
            close.toolTip = lastTabHint.isEmpty ? "关闭 " + title : lastTabHint
            close.setAccessibilityLabel("关闭 " + title)
            close.setAccessibilityHelp(lastTabHint.isEmpty ? nil : lastTabHint)
            row.toolTip = tooltip
            row.update(selected: isSelected, canClose: canClose)
        }
        resizeTabs()
    }

    private struct TabMenuTarget {
        let spaceID: UUID
        let tabID: UUID
    }

    private func makeTabContextMenu(spaceID: UUID, tabID: UUID) -> NSMenu? {
        guard let owner, let space = owner.model.spaces.first(where: { $0.record.id == spaceID }),
              let tab = space.tabs.first(where: { $0.id == tabID }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = TabMenuTarget(spaceID: spaceID, tabID: tabID)
        let running = (space.activity[tabID]?.executing ?? 0) > 0
        let canOperate = !space.busy && !owner.model.restoring && owner.window.attachedSheet == nil

        let reloadItem = NSMenuItem(title: "重新加载", action: #selector(contextReloadTab(_:)), keyEquivalent: "")
        reloadItem.target = self; reloadItem.representedObject = target; reloadItem.isEnabled = canOperate
        menu.addItem(reloadItem)

        let copyURLItem = NSMenuItem(title: "复制网址", action: #selector(contextCopyTabURL(_:)), keyEquivalent: "")
        copyURLItem.target = self; copyURLItem.representedObject = tab.persistedURL
        copyURLItem.isEnabled = tab.persistedURL != "about:blank"
        menu.addItem(copyURLItem)

        let handoffItem = NSMenuItem(title: "交给 Agent", action: #selector(contextHandoffTab(_:)), keyEquivalent: "")
        handoffItem.target = self; handoffItem.representedObject = target
        menu.addItem(handoffItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "关闭标签页", action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self; closeItem.representedObject = target
        closeItem.isEnabled = space.tabs.count > 1 && canOperate && !running
        menu.addItem(closeItem)

        let closeOthersItem = NSMenuItem(title: "关闭其他标签页", action: #selector(contextCloseOtherTabs(_:)), keyEquivalent: "")
        closeOthersItem.target = self; closeOthersItem.representedObject = target
        closeOthersItem.isEnabled = canCloseOthers(in: space, keeping: tabID)
        menu.addItem(closeOthersItem)
        return menu
    }

    @objc private func contextReloadTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget else { return }
        request(Request(command: "reload", args: [], options: ["space": target.spaceID.uuidString, "tab": target.tabID.uuidString]))
    }
    @objc private func contextCopyTabURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        copyURL(url)
    }
    @objc private func contextHandoffTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget,
              let space = owner?.model.spaces.first(where: { $0.record.id == target.spaceID }),
              let tab = space.tabs.first(where: { $0.id == target.tabID }) else { return }
        handoff(space, tab)
    }
    @objc private func contextCloseTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget else { return }
        closeTab(spaceID: target.spaceID, tabID: target.tabID)
    }
    func canCloseOthers(in space: Space, keeping tabID: UUID) -> Bool {
        owner?.model.restoring == false && !space.busy && owner?.window.attachedSheet == nil && space.tabs.count > 1
            && space.tabs.contains { $0.id == tabID }
            && !space.tabs.contains { $0.id != tabID && (space.activity[$0.id]?.executing ?? 0) > 0 }
    }
    @objc private func contextCloseOtherTabs(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget,
              let space = owner?.model.spaces.first(where: { $0.record.id == target.spaceID }) else { return }
        closeOtherTabs(in: space, keeping: target.tabID)
    }
    func closeOtherTabs(in space: Space, keeping tabID: UUID) {
        guard let owner, canCloseOthers(in: space, keeping: tabID) else { return }
        let others = space.tabs.filter { $0.id != tabID }
        guard !others.isEmpty else { return }
        var impacts: [(tabID: UUID, impact: ObserverImpact?)] = []
        var downloadCount = 0
        var dialogCount = 0
        var recentCount = 0
        for tab in others {
            do {
                let impact = try space.observerImpact("tab.close", tabID: tab.id)
                impacts.append((tab.id, impact))
                if let impact {
                    downloadCount += impact.downloads.count
                    dialogCount += impact.dialogs.count
                    if impact.recentActivity != nil { recentCount += 1 }
                }
            } catch {
                owner.window.presentObserverFailure(failure(error))
                return
            }
        }
        func executeBatch() {
            Task { @MainActor in
                for entry in impacts {
                    let request = Request(command: "tab.close", args: [], options: ["space": space.record.id.uuidString, "tab": entry.tabID.uuidString])
                    var consent = entry.impact
                    while true {
                        var changedImpact: ObserverImpact?
                        let origin = RequestOrigin.closingOtherTabs(keeping: tabID, consent: consent)
                        let response = await owner.model.handle(request, origin: origin) { changedImpact = $0 }
                        if let impact = changedImpact {
                            let alert = NSAlert.observerConfirmation("标签页状态已变化，继续关闭？",
                                detail: impact.detail + "\n取消将停止本次操作，已关闭的标签页不会恢复。",
                                action: "关闭并继续", destructive: true)
                            guard await alert.beginSheetModal(for: owner.window) == .alertFirstButtonReturn else { return }
                            consent = impact
                            continue
                        }
                        if response["ok"] as? Bool != true,
                           (response["error"] as? [String: Any])?["code"] as? String != "tab_not_found" {
                            owner.window.presentObserverFailure(response)
                            return
                        }
                        break
                    }
                }
                owner.refresh()
            }
        }
        let hasImpact = downloadCount > 0 || dialogCount > 0 || recentCount > 0
        if hasImpact {
            var lines = ["将关闭「\(space.record.name)」中的其余 \(others.count) 个标签页。"]
            if downloadCount > 0 { lines.append("将中断 \(downloadCount) 项活跃下载。") }
            if dialogCount > 0 { lines.append("将关闭 \(dialogCount) 个待处理的网页对话框。") }
            if recentCount > 0 { lines.append("其中 \(recentCount) 个标签页在最近 5 分钟内有 Agent 操作。") }
            owner.window.confirmObserverAction("关闭其他 \(others.count) 个标签页？", detail: lines.joined(separator: "\n"), action: "关闭其他标签页", destructive: true) {
                executeBatch()
            }
        } else {
            executeBatch()
        }
    }

    @objc private func pickTab(_ sender: NSButton) {
        guard let space = currentSpace() else { return }
        sender.state = .on
        selectTab(sender.tag, space)
    }
    static func title(of tab: Tab) -> String {
        if let title = tab.webView.title, !title.isEmpty { return title }
        return tab.persistedURL == "about:blank" ? "新标签页" : URL(string: tab.persistedURL)?.host ?? "页面"
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        owner?.validateMenuItem(item) ?? false
    }

    @objc private func selectListedTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let space = currentSpace(),
              let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(index, space)
    }
    @objc private func resizeTabs(_ notification: Notification? = nil) {
        guard tabBar.bounds.width > 0, !tabWidths.isEmpty else { return }
        let count = CGFloat(tabWidths.count)
        let available = tabBar.bounds.width - tabStack.edgeInsets.left - tabStack.edgeInsets.right - (count - 1) * tabStack.spacing
        let longest = tabStack.arrangedSubviews.compactMap { ($0 as? PageTabView)?.titleButton.intrinsicContentSize.width }.max() ?? 0
        let fits = available / count >= max(140, longest + 54)
        allTabs.isHidden = fits
        let width = max(140, floor((available - (fits ? 0 : 32)) / count))
        for constraint in tabWidths where constraint.constant != width { constraint.constant = width }
        tabStack.frame.size = NSSize(width: count * width + (count - 1) * tabStack.spacing + tabStack.edgeInsets.left + tabStack.edgeInsets.right, height: 38)
        tabStack.layoutSubtreeIfNeeded()
        if let space = currentSpace(), let selected = selectedID(space),
           let index = space.tabs.firstIndex(where: { $0.id == selected }), tabStack.arrangedSubviews.indices.contains(index) {
            let active = tabStack.arrangedSubviews[index]
            active.scrollToVisible(active.bounds)
        }
    }
    @objc private func closeTabButton(_ sender: NSButton) {
        guard let space = currentSpace(), let raw = sender.identifier?.rawValue, let tabID = UUID(uuidString: raw) else { return }
        closeTab(spaceID: space.record.id, tabID: tabID)
    }
    private func closeTab(spaceID: UUID, tabID: UUID) {
        request(Request(command: "tab.close", args: [], options: ["space": spaceID.uuidString, "tab": tabID.uuidString]))
    }
}
