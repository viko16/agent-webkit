import AppKit

@MainActor
final class ObserverSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let table = NSTableView()
    let search = NSSearchField()
    private let noSearchResults = NSStackView()
    private let clearSearchButton = NSButton(title: "清除搜索", target: nil, action: nil)
    private let createFromSearch = NSButton(title: "新建 Space", target: nil, action: nil)
    private let spaceCount = NSTextField(labelWithString: "")
    private let createButton = NSButton()
    private let spaceActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let suspensionItem = NSMenuItem()
    private let deleteItem = NSMenuItem(title: "删除 Space…", action: nil, keyEquivalent: "")
    private var filteredSpaces: [Space] = []
    private weak var owner: ObserverWindow?
    private let select: (Space) -> Void
    private let isRefreshing: () -> Bool
    private let isCreatingTab: () -> Bool
    private let createTab: (UUID) -> Void
    private let details: (Space, NSRect?, NSView?) -> Void
    private let copyID: (UUID) -> Void
    private let request: (Request) -> Void

    init(owner: ObserverWindow, select: @escaping (Space) -> Void, isRefreshing: @escaping () -> Bool,
         isCreatingTab: @escaping () -> Bool, createTab: @escaping (UUID) -> Void,
         details: @escaping (Space, NSRect?, NSView?) -> Void, copyID: @escaping (UUID) -> Void,
         request: @escaping (Request) -> Void) {
        self.owner = owner
        self.select = select
        self.isRefreshing = isRefreshing
        self.isCreatingTab = isCreatingTab
        self.createTab = createTab
        self.details = details
        self.copyID = copyID
        self.request = request
    }

    func install(in split: NSSplitViewController, owner: ObserverWindow,
                 performSpaceAction: Selector, prepareSpaceMenu: Selector) {
        let controller = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = .sidebar; effect.blendingMode = .behindWindow
        controller.view = effect
        let item = NSSplitViewItem(sidebarWithViewController: controller)
        item.allowsFullHeightLayout = true
        item.minimumThickness = 200; item.maximumThickness = 280
        item.preferredThicknessFraction = 0.19
        split.addSplitViewItem(item)
        let heading = NSTextField(labelWithString: "Spaces")
        heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor
        search.placeholderString = "搜索 Space"
        search.textColor = .labelColor; search.font = .systemFont(ofSize: 13)
        search.delegate = owner
        search.setAccessibilityLabel("搜索 Space")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("space")))
        table.headerView = nil; table.rowHeight = 46; table.style = .sourceList
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("Spaces")
        let sidebarMenu = NSMenu()
        sidebarMenu.autoenablesItems = false
        sidebarMenu.delegate = self
        table.menu = sidebarMenu
        scroll.documentView = table
        let noMatches = NSTextField(labelWithString: "没有匹配的 Space")
        noMatches.textColor = .secondaryLabelColor
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearch)
        createFromSearch.target = owner
        createFromSearch.action = #selector(ObserverWindow.createSpace)
        let searchActions = NSStackView(views: [clearSearchButton, createFromSearch])
        noSearchResults.orientation = .vertical
        noSearchResults.alignment = .centerX
        noSearchResults.addArrangedSubview(noMatches)
        noSearchResults.addArrangedSubview(searchActions)
        spaceCount.font = .systemFont(ofSize: 12); spaceCount.textColor = .secondaryLabelColor
        spaceCount.lineBreakMode = .byTruncatingTail
        spaceCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        createButton.target = owner
        createButton.action = #selector(ObserverWindow.createSpace)
        createButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        createButton.toolTip = "新建 Space"
        createButton.setAccessibilityLabel("新建 Space")
        spaceActions.addItem(withTitle: "")
        spaceActions.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        (spaceActions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        spaceActions.toolTip = "所选 Space 的更多操作"
        spaceActions.setAccessibilityLabel("所选 Space 的更多操作")
        for item in [suspensionItem, deleteItem] {
            item.target = owner
            item.action = performSpaceAction
        }
        spaceActions.menu?.addItem(suspensionItem)
        spaceActions.menu?.addItem(.separator())
        spaceActions.menu?.addItem(deleteItem)
        NotificationCenter.default.addObserver(owner, selector: prepareSpaceMenu,
                                               name: NSPopUpButton.willPopUpNotification, object: spaceActions)
        for button in [createButton, spaceActions] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let actions = NSStackView(views: [createButton, spaceActions])
        actions.spacing = 2
        [heading, search, scroll, noSearchResults, actions, spaceCount].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview($0) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: effect.safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            actions.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            heading.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: spaceCount.topAnchor, constant: -8),
            noSearchResults.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            noSearchResults.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            spaceCount.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            spaceCount.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -14)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredSpaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSpaces.indices.contains(row) else { return nil }
        let space = filteredSpaces[row]; let cell = NSTableCellView()
        let waiting = space.tabs.contains { $0.dialogs.hasPending }
        let icon = NSImageView(image: NSImage(systemSymbolName: waiting ? "exclamationmark.bubble.fill" : "square.stack",
                                              accessibilityDescription: waiting ? "网页等待回复" : nil)!)
        icon.contentTintColor = waiting ? .systemOrange : .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        let title = NSTextField(labelWithString: space.record.name); title.font = .systemFont(ofSize: 13, weight: .medium)
        let route = space.record.proxy == "direct" ? "直连" : "HTTP 代理"
        let state = [waiting ? "等待回复" : nil, space.networkError != nil ? "网络已暂停" : nil,
                     space.suspended ? "已休眠" : space.busy ? "运行中" : nil].compactMap { $0 }
        let summary = (state + [route, "\(space.tabStates.count) 个标签页"]).joined(separator: " · ")
        let subtitle = NSTextField(labelWithString: summary)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle; subtitle.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        for label in [title, subtitle] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        [icon, labels].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = title; cell.imageView = icon
        cell.toolTip = "\(space.record.name)\n\(summary)\n\(space.record.id.uuidString)\n\(space.record.proxy)"
        return cell
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let owner, menu === table.menu else { return }
        menu.removeAllItems()
        let model = owner.model
        let noSheet = owner.window.attachedSheet == nil
        let row = table.clickedRow
        guard filteredSpaces.indices.contains(row) else {
            let createItem = NSMenuItem(title: "新建 Space…", action: #selector(ObserverWindow.createSpace), keyEquivalent: "")
            createItem.target = owner
            createItem.isEnabled = !model.restoring && noSheet
            menu.addItem(createItem)
            return
        }
        let space = filteredSpaces[row]
        let canMutate = !space.busy && !model.restoring && noSheet
        let newTabItem = NSMenuItem(title: "新建标签页", action: #selector(contextNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self; newTabItem.representedObject = space.record.id; newTabItem.isEnabled = canMutate && !isCreatingTab()
        menu.addItem(newTabItem)

        let detailsItem = NSMenuItem(title: "Space 信息", action: #selector(contextShowDetails(_:)), keyEquivalent: "")
        detailsItem.target = self; detailsItem.representedObject = space.record.id; detailsItem.isEnabled = noSheet
        menu.addItem(detailsItem)

        let copyIDItem = NSMenuItem(title: "复制 Space ID", action: #selector(contextCopySpaceID(_:)), keyEquivalent: "")
        copyIDItem.target = self; copyIDItem.representedObject = space.record.id
        menu.addItem(copyIDItem)

        menu.addItem(.separator())

        let suspendItem = NSMenuItem(title: space.suspended ? "恢复 Space" : "休眠 Space…", action: #selector(contextSpaceRequest(_:)), keyEquivalent: "")
        suspendItem.target = self; suspendItem.isEnabled = canMutate
        suspendItem.representedObject = Request(command: space.suspended ? "space.resume" : "space.suspend", args: [space.record.id.uuidString], options: [:])
        menu.addItem(suspendItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(title: "删除 Space…", action: #selector(contextSpaceRequest(_:)), keyEquivalent: "")
        removeItem.target = self; removeItem.isEnabled = canMutate
        removeItem.representedObject = Request(command: "space.delete", args: [space.record.id.uuidString], options: [:])
        menu.addItem(removeItem)
    }
    @objc private func contextNewTab(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID, let model = owner?.model, !model.restoring, !isCreatingTab(),
              let space = model.spaces.first(where: { $0.record.id == spaceID }), !space.busy else { return }
        createTab(spaceID)
    }
    @objc private func contextShowDetails(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID,
              let space = owner?.model.spaces.first(where: { $0.record.id == spaceID }) else { return }
        if let row = filteredSpaces.firstIndex(where: { $0.record.id == spaceID }) {
            let rect = table.rect(ofRow: row)
            details(space, rect, table)
        } else {
            details(space, nil, nil)
        }
    }
    @objc private func contextCopySpaceID(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID else { return }
        copyID(spaceID)
    }
    @objc private func contextSpaceRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request else { return }
        self.request(request)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing() else { return }
        guard filteredSpaces.indices.contains(table.selectedRow) else { owner?.refresh(); return }
        select(filteredSpaces[table.selectedRow])
    }
    @objc private func clearSearch() {
        search.stringValue = ""
        owner?.refresh()
        owner?.window.makeFirstResponder(search)
    }

    func updateFilter(spaces: [Space]) {
        filteredSpaces = spaces.filter { search.stringValue.isEmpty || $0.record.name.localizedCaseInsensitiveContains(search.stringValue) }
    }

    func refresh(model: BrowserModel, selectedID: UUID?, currentSpace: Space?) {
        noSearchResults.isHidden = search.stringValue.isEmpty || !filteredSpaces.isEmpty
        table.enclosingScrollView?.isHidden = !noSearchResults.isHidden
        table.reloadData()
        if let row = filteredSpaces.firstIndex(where: { $0.record.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        spaceCount.stringValue = search.stringValue.isEmpty ? "\(model.spaces.count) 个 Space · 本机服务" : "找到 \(filteredSpaces.count) 个 Space"
        let pending = model.records.filter(\.deleting).count
        if pending > 0 { spaceCount.stringValue += " · \(pending) 待清理" }
        spaceCount.toolTip = spaceCount.stringValue
        createButton.isEnabled = !model.restoring
        createFromSearch.isEnabled = createButton.isEnabled
        spaceActions.isEnabled = table.selectedRow >= 0 && currentSpace?.busy == false && !model.restoring
    }

    func chooseSearchResult(in window: NSWindow) {
        if !search.stringValue.isEmpty, !filteredSpaces.isEmpty {
            let index = filteredSpaces.indices.contains(table.selectedRow) ? table.selectedRow : 0
            select(filteredSpaces[index])
            window.makeFirstResponder(table)
        }
    }

    var countBaseline: NSLayoutYAxisAnchor { spaceCount.firstBaselineAnchor }
    var hasSelection: Bool { table.selectedRow >= 0 }
    var actionsEnabled: Bool { spaceActions.isEnabled }

    func showPopover(_ popover: NSPopover) -> Bool {
        guard spaceActions.window != nil, !spaceActions.isHiddenOrHasHiddenAncestor else { return false }
        popover.show(relativeTo: spaceActions.bounds, of: spaceActions, preferredEdge: .maxX)
        return true
    }

    func prepareActions(for space: Space) {
        Self.bindSpaceAction(suspensionItem, space: space, delete: false)
        Self.bindSpaceAction(deleteItem, space: space, delete: true)
    }

    static func bindSpaceAction(_ item: NSMenuItem, space: Space?, delete: Bool) {
        item.title = delete ? "删除 Space…" : space?.suspended == true ? "恢复 Space" : "休眠 Space…"
        item.representedObject = space.map {
            Request(command: delete ? "space.delete" : $0.suspended ? "space.resume" : "space.suspend", args: [$0.record.id.uuidString], options: [:])
        }
    }
}
