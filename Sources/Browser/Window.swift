import AppKit

private final class AddressField: NSTextField {
    var willFocus: (() -> Void)?
    override func selectText(_ sender: Any?) {
        willFocus?()
        super.selectText(sender)
    }
    override func mouseDown(with event: NSEvent) {
        willFocus?()
        super.mouseDown(with: event)
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("observer.sidebar")
    static let address = Self("observer.address")
    static let copyCommand = Self("observer.copyCommand")
    static let details = Self("observer.details")
    static let newTab = Self("observer.newTab")
}

/// Keep the native button's keyboard/accessibility behavior with a quieter tab surface.
private final class PageTabButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if state == .on {
            NSColor.controlBackgroundColor.setFill(); shape.fill()
            NSColor.labelColor.withAlphaComponent(0.22).setStroke(); shape.lineWidth = 1; shape.stroke()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.05).setFill(); shape.fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.035).setFill(); shape.fill()
        }
        let color = state == .on ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.7)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph
        ]
        let text = title as NSString
        let textWidth = min(text.size(withAttributes: attributes).width, max(0, bounds.width - 48))
        let left = (bounds.width - textWidth - 22) / 2
        image?.withSymbolConfiguration(.init(paletteColors: [color]))?.draw(
            in: NSRect(x: left, y: (bounds.height - 14) / 2, width: 14, height: 14),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let height = text.size(withAttributes: attributes).height
        text.draw(in: NSRect(x: left + 22, y: (bounds.height - height) / 2, width: textWidth, height: height), withAttributes: attributes)
    }
}

@MainActor
final class ObserverWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let model: BrowserModel
    let window: NSWindow
    private let split = NSSplitViewController()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let host = NSView()
    private let address = AddressField()
    private let addressContainer = NSBox()
    private let addressIcon = NSImageView()
    private let addressDisplay = NSTextField(labelWithString: "")
    private var editingAddress = false
    private var addressDraft = ""
    private let reloadButton = NSButton()
    private let tabStack = NSStackView()
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let security = NSTextField(labelWithString: "")
    private let spaceCount = NSTextField(labelWithString: "")
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "浏览会话，各自独立")
    private let emptyText = NSTextField(wrappingLabelWithString: "")
    private let banner = NSStackView()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "重新加载", target: nil, action: nil)
    private var refreshing = false
    private var selectedSpace: UUID?
    private var selectedTabs: [UUID: UUID] = [:]
    private var filteredSpaces: [Space] = []
    private weak var displayed: Tab?
    private var tabSignature = ""
    private var transientMessage: String?
    private let selectionKey: String
    private let socketPath: String
    private let infoPopover = NSPopover()
    private var creatingTab = false
    private var tabWidths: [NSLayoutConstraint] = []

    init(model: BrowserModel, socketPath: String) {
        self.model = model
        self.socketPath = socketPath
        selectionKey = "observer.selection.\(model.storagePath)"
        window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 1220, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: String] {
            selectedSpace = saved["space"].flatMap(UUID.init(uuidString:))
            for (key, value) in saved {
                if let space = UUID(uuidString: key), let tab = UUID(uuidString: value) { selectedTabs[space] = tab }
            }
        }
        window.title = "Agent WebKit"; window.titleVisibility = .hidden
        window.toolbarStyle = .unified; window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false; window.delegate = self
        split.splitView.dividerStyle = .thin
        configureSidebar(); configureContent()
        window.contentViewController = split
        NSLayoutConstraint.activate([
            search.centerYAnchor.constraint(equalTo: tabStack.centerYAnchor),
            spaceCount.firstBaselineAnchor.constraint(equalTo: status.firstBaselineAnchor)
        ])
        window.setContentSize(NSSize(width: 1220, height: 800))
        window.setFrameAutosaveName(selectionKey + ".frame")
        window.setFrameUsingName(selectionKey + ".frame")
        let toolbar = NSToolbar(identifier: "AgentWebKit.Observer.Toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        model.changed = { [weak self] in self?.refresh() }
        model.observerState = { [weak self] in
            guard let self else { return [:] }
            return ["visible": self.window.isVisible,
                    "spaceId": self.selectedSpace?.uuidString as Any? ?? NSNull(),
                    "tabId": self.displayed?.id.uuidString as Any? ?? NSNull()]
        }
        model.willRemove = { [weak self] space in
            guard let self else { return }
            if space.tabs.contains(where: { $0 === self.displayed }) { self.displayed?.park(); self.displayed = nil }
        }
        refresh()
        // Agent activity never makes this window key or activates the application.
        window.orderBack(nil)
    }

    private var currentSpace: Space? { model.spaces.first { $0.record.id == selectedSpace } }
    private func configureSidebar() {
        let controller = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = .sidebar; effect.blendingMode = .behindWindow
        controller.view = effect
        let item = NSSplitViewItem(sidebarWithViewController: controller)
        // One continuous titlebar avoids a separate backdrop edge drifting from the split divider.
        item.allowsFullHeightLayout = false
        item.minimumThickness = 200; item.maximumThickness = 280
        item.preferredThicknessFraction = 0.19
        split.addSplitViewItem(item)
        let heading = NSTextField(labelWithString: "Spaces")
        heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor
        search.placeholderAttributedString = NSAttributedString(string: "搜索 Space", attributes: [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.7)])
        search.textColor = .labelColor; search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.setAccessibilityLabel("搜索 Space")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("space")))
        table.headerView = nil; table.rowHeight = 46; table.style = .sourceList
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsEmptySelection = false
        table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("Spaces")
        scroll.documentView = table
        spaceCount.font = .systemFont(ofSize: 12); spaceCount.textColor = .secondaryLabelColor
        [heading, search, scroll, spaceCount].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview($0) }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            heading.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: spaceCount.topAnchor, constant: -12),
            spaceCount.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20)
        ])
    }

    private func configureContent() {
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
        let tabs = NSScrollView(); tabs.drawsBackground = false; tabs.hasHorizontalScroller = false
        tabStack.orientation = .horizontal; tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        tabStack.translatesAutoresizingMaskIntoConstraints = false; tabs.documentView = tabStack
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabs.contentView.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabs.contentView.topAnchor),
            tabStack.heightAnchor.constraint(equalToConstant: 38)
        ])
        tabs.heightAnchor.constraint(equalToConstant: 38).isActive = true
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.heightAnchor.constraint(equalToConstant: 2).isActive = true
        banner.orientation = .horizontal; banner.spacing = 10
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "页面需要处理")!)
        warning.contentTintColor = .systemOrange
        bannerText.font = .systemFont(ofSize: 12); bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retry.target = self; retry.action = #selector(reloadPage); retry.bezelStyle = .rounded
        [warning, bannerText, retry].forEach { banner.addArrangedSubview($0) }
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let footer = NSStackView(views: [status, NSView(), security])
        footer.orientation = .horizontal; footer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for label in [status, security] {
            label.font = .systemFont(ofSize: 12); label.textColor = .labelColor.withAlphaComponent(0.7)
            label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        [tabs, progress, banner, host, footer].forEach {
            column.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor; icon.symbolConfiguration = .init(pointSize: 46, weight: .light)
        emptyTitle.font = .systemFont(ofSize: 23, weight: .semibold)
        emptyText.font = .systemFont(ofSize: 13); emptyText.textColor = .secondaryLabelColor; emptyText.alignment = .center
        let open = NSButton(title: "打开网页", target: self, action: #selector(startBrowsing(_:))); open.bezelStyle = .rounded
        empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 14
        [icon, emptyTitle, emptyText, open].forEach { empty.addArrangedSubview($0) }
        empty.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: host.centerXAnchor), empty.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
            emptyText.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        ])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .flexibleSpace, .address, .flexibleSpace, .copyCommand, .details, .newTab]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.autovalidates = false
        if id == .address {
            address.isEditable = true; address.isSelectable = true; address.isBezeled = false
            address.delegate = self; address.target = self; address.action = #selector(openAddress(_:))
            address.willFocus = { [weak self] in self?.beginAddressEditing() }
            address.drawsBackground = false; address.textColor = .clear
            address.focusRingType = .none
            address.alignment = .left; address.font = .systemFont(ofSize: 13); address.lineBreakMode = .byTruncatingMiddle
            address.placeholderString = "输入网址"; address.setAccessibilityLabel("页面地址")
            address.translatesAutoresizingMaskIntoConstraints = false
            let field = addressContainer
            field.boxType = .custom; field.cornerRadius = 18
            field.borderWidth = 0.5; field.borderColor = .separatorColor; field.fillColor = .controlBackgroundColor
            field.contentViewMargins = .zero
            field.translatesAutoresizingMaskIntoConstraints = false
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载")
            reloadButton.target = self; reloadButton.action = #selector(reloadPage)
            reloadButton.isBordered = false; reloadButton.bezelStyle = .texturedRounded
            reloadButton.contentTintColor = .labelColor; reloadButton.toolTip = "重新加载（⌘R）"
            reloadButton.setAccessibilityLabel("重新加载")
            reloadButton.translatesAutoresizingMaskIntoConstraints = false
            let content = field.contentView!
            addressIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            addressIcon.contentTintColor = .secondaryLabelColor; addressIcon.isHidden = true
            addressIcon.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(addressIcon); content.addSubview(address); content.addSubview(reloadButton)
            addressDisplay.font = address.font; addressDisplay.alignment = .center
            addressDisplay.lineBreakMode = .byTruncatingMiddle
            addressDisplay.translatesAutoresizingMaskIntoConstraints = false
            addressDisplay.setAccessibilityElement(false)
            content.addSubview(addressDisplay, positioned: .below, relativeTo: address)
            let preferred = field.widthAnchor.constraint(equalToConstant: 560)
            preferred.priority = .defaultHigh; preferred.isActive = true
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
                field.heightAnchor.constraint(equalToConstant: 36),
                addressIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                addressIcon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                addressIcon.widthAnchor.constraint(equalToConstant: 16),
                addressIcon.heightAnchor.constraint(equalToConstant: 16),
                address.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
                address.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                addressDisplay.leadingAnchor.constraint(equalTo: address.leadingAnchor),
                addressDisplay.trailingAnchor.constraint(equalTo: address.trailingAnchor),
                addressDisplay.centerYAnchor.constraint(equalTo: address.centerYAnchor),
                address.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -6),
                reloadButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
                reloadButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                reloadButton.widthAnchor.constraint(equalToConstant: 24),
                reloadButton.heightAnchor.constraint(equalToConstant: 26)
            ])
            item.view = field; item.label = "页面地址"
        } else {
            let values: (String, String, Selector)
            switch id {
            case .sidebar: values = ("显示／隐藏侧边栏（⌃⌘S）", "sidebar.left", #selector(toggleSidebar(_:)))
            case .copyCommand: values = ("复制 Agent 接管命令", "square.and.arrow.up", #selector(copyCommand))
            case .details: values = ("Space 信息", "info.circle", #selector(showDetails))
            case .newTab: values = ("新建标签页（⌘T）", "plus", #selector(newTab(_:)))
            default: return nil
            }
            item.label = values.0; item.toolTip = values.0
            item.image = NSImage(systemSymbolName: values.1, accessibilityDescription: values.0)
            item.action = values.2; item.isBordered = true
        }
        return item
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredSpaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSpaces.indices.contains(row) else { return nil }
        let space = filteredSpaces[row]; let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        let title = NSTextField(labelWithString: space.record.name); title.font = .systemFont(ofSize: 13, weight: .medium)
        let route = space.record.proxy == "direct" ? (space.networkError == nil ? "直连" : "直连已暂停") : "Whistle"
        let subtitle = NSTextField(labelWithString: "\(route) · \(space.tabStates.count) 个标签页\(space.suspended ? " · 已休眠" : space.busy ? " · 运行中" : "")")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] { label.lineBreakMode = .byTruncatingTail }
        let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        [icon, labels].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = title; cell.imageView = icon
        cell.toolTip = "\(space.record.name)\n\(space.record.id.uuidString)\n\(space.record.proxy)"
        return cell
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { refresh() }
        if notification.object as? NSTextField === address { addressDraft = address.stringValue }
    }
    private func beginAddressEditing() {
        guard !editingAddress else { return }
        editingAddress = true
        address.textColor = .labelColor; addressDisplay.isHidden = true
        addressContainer.borderWidth = 3; addressContainer.borderColor = .keyboardFocusIndicatorColor
        addressIcon.isHidden = false
        addressDraft = address.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === address else { return }
        editingAddress = false
        address.textColor = .clear; addressDisplay.isHidden = false
        addressContainer.borderWidth = 0.5; addressContainer.borderColor = .separatorColor
        addressIcon.isHidden = true
        updateStatus()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === address, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window.makeFirstResponder(nil); updateStatus(); return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, filteredSpaces.indices.contains(table.selectedRow) else { return }
        selectedSpace = filteredSpaces[table.selectedRow].record.id
        transientMessage = nil; saveSelection(); refresh()
    }
    @objc private func pickTab(_ sender: NSButton) {
        guard let space = currentSpace, space.tabs.indices.contains(sender.tag) else { return }
        selectedTabs[space.record.id] = space.tabs[sender.tag].id
        transientMessage = nil; saveSelection(); refresh()
        if tabStack.arrangedSubviews.indices.contains(sender.tag) { let view = tabStack.arrangedSubviews[sender.tag]; view.scrollToVisible(view.bounds) }
    }
    private func saveSelection() {
        var saved = Dictionary(uniqueKeysWithValues: selectedTabs.map { ($0.key.uuidString, $0.value.uuidString) })
        saved["space"] = selectedSpace?.uuidString; UserDefaults.standard.set(saved, forKey: selectionKey)
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        filteredSpaces = model.spaces.filter { search.stringValue.isEmpty || $0.record.name.localizedCaseInsensitiveContains(search.stringValue) }
        if !filteredSpaces.contains(where: { $0.record.id == selectedSpace }) {
            selectedSpace = filteredSpaces.first?.record.id
            saveSelection()
        }
        table.reloadData()
        if let row = filteredSpaces.firstIndex(where: { $0.record.id == selectedSpace }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        spaceCount.stringValue = search.stringValue.isEmpty ? "\(model.spaces.count) 个 Space · 本机服务" : "找到 \(filteredSpaces.count) 个 Space"
        guard let space = currentSpace else {
            displayed?.park(); displayed = nil; empty.isHidden = false
            emptyTitle.stringValue = "浏览会话，各自独立"
            emptyText.stringValue = "先打开网页，再让 Agent 继续。\n首次新建会创建 personal Space，使用直连和系统证书校验。"
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }; tabSignature = ""
            updateStatus(); return
        }
        let selected = selectedTabs[space.record.id] ?? space.record.defaultTab
        let tab = space.tabs.first { $0.id == selected } ?? space.tabs.first { $0.id == space.record.defaultTab }
        if !space.suspended { selectedTabs[space.record.id] = tab?.id }
        let blank = space.suspended || tab?.persistedURL == "about:blank"
        empty.isHidden = !blank
        if space.suspended {
            emptyTitle.stringValue = "Space 已休眠"
            emptyText.stringValue = "网站数据和标签页地址已保留。\n点击打开网页恢复；页面内存和未提交表单不会恢复。"
        } else if blank {
            emptyTitle.stringValue = "新标签页"
            emptyText.stringValue = "在地址栏输入网址，按回车打开。\n准备好后，点工具栏的分享按钮复制 Agent 接管命令。"
        }
        let signature = space.tabs.map { "\($0.id)|\($0.webView.title ?? "")|\($0.persistedURL)" }.joined() + "\(tab?.id.uuidString ?? "")\(space.record.defaultTab)"
        if signature != tabSignature {
            tabSignature = signature; tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }; tabWidths = []
            for (index, candidate) in space.tabs.enumerated() {
                let title = candidate.webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? (candidate.persistedURL == "about:blank" ? "新标签页" : URL(string: candidate.persistedURL)?.host ?? "页面")
                let button = PageTabButton(title: title, target: self, action: #selector(pickTab(_:)))
                button.setButtonType(.toggle); button.isBordered = false
                (button.cell as? NSButtonCell)?.highlightsBy = []
                (button.cell as? NSButtonCell)?.showsStateBy = []
                button.state = candidate === tab ? .on : .off; button.tag = index
                button.font = .systemFont(ofSize: 13, weight: candidate === tab ? .medium : .regular)
                button.setAccessibilityRole(.radioButton)
                button.setAccessibilityValue(candidate === tab ? 1 : 0)
                button.contentTintColor = candidate === tab ? .labelColor : .secondaryLabelColor
                button.cell?.lineBreakMode = .byTruncatingTail
                button.image = NSImage(systemSymbolName: candidate.id == space.record.defaultTab ? "pin" : "globe", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.toolTip = "\(title)\n\(candidate.persistedURL)\n\(candidate.id == space.record.defaultTab ? "CLI 默认标签页 · " : "")\(candidate.id.uuidString)"
                button.setAccessibilityLabel("\(title)\(candidate.id == space.record.defaultTab ? "，CLI 默认标签页" : "")")
                let width = button.widthAnchor.constraint(equalToConstant: 220)
                width.isActive = true; tabWidths.append(width)
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true; tabStack.addArrangedSubview(button)
            }
            resizeTabs()
        }
        if displayed !== tab {
            // An unfinished address belongs to the tab where it was typed.
            window.endEditing(for: address)
            displayed?.park(); displayed = tab
            if let tab {
                tab.webView.removeFromSuperview(); host.addSubview(tab.webView)
                tab.webView.frame = host.bounds; tab.webView.autoresizingMask = [.width, .height]
            }
        }
        tab?.webView.isHidden = blank
        // A view hidden for the blank state must become visible when parked in another Space.
        if blank { host.addSubview(empty, positioned: .above, relativeTo: tab?.webView) }
        updateStatus()
    }

    private func updateStatus() {
        let space = currentSpace; let tab = displayed
        let url = tab?.persistedURL == "about:blank" ? "" : tab?.persistedURL ?? ""
        if !editingAddress {
            let components = URLComponents(string: url)
            let display = ["http", "https"].contains(components?.scheme?.lowercased() ?? "")
                ? components?.host ?? url : url
            addressDisplay.stringValue = display
            if address.stringValue != url { address.stringValue = url }
        }
        address.toolTip = tab?.persistedURL
        address.placeholderString = "输入网址"
        address.isEnabled = tab != nil && !model.restoring && !creatingTab
        progress.doubleValue = tab?.webView.isLoading == true ? max(0.03, tab?.webView.estimatedProgress ?? 0) : 0
        progress.alphaValue = tab?.webView.isLoading == true ? 1 : 0
        status.stringValue = model.restoring ? "正在恢复会话…" : transientMessage ?? (tab == nil ? "准备就绪" : space?.busy == true ? "正在处理页面…" : tab?.webView.isLoading == true ? "正在加载…" : tab?.id == space?.record.defaultTab ? "Agent 默认标签页" : "可通过分享按钮交给 Agent")
        let insecure = space?.record.tls?.ignoreCertificateErrors == true
        let tls = insecure ? "未校验证书" : space?.record.tls == nil ? "系统证书校验" : "自定义 CA"
        let networkError = space?.networkError
        security.stringValue = space.map { "\($0.record.proxy == "direct" ? "直连" : "Whistle")\(networkError == nil ? "" : "已暂停") · \(tls)" } ?? ""
        security.textColor = insecure || networkError != nil ? .systemOrange : .labelColor.withAlphaComponent(0.7)
        reloadButton.isEnabled = canReload
        let error = networkError?.localizedDescription ?? tab?.lastNavigationRejection?.localizedDescription ?? (tab?.unresponsive == true ? "页面未响应。重新加载可恢复标签页；上次操作可能已部分生效。" : tab?.navigationError?.localizedDescription)
        bannerText.stringValue = error ?? ""; banner.isHidden = error == nil; retry.isEnabled = space?.busy == false && !model.restoring
        for item in window.toolbar?.items ?? [] where [.copyCommand, .details].contains(item.itemIdentifier) {
            item.isEnabled = tab != nil
        }
        window.toolbar?.items.first { $0.itemIdentifier == .newTab }?.isEnabled = canCreateTab
    }
    private var canCreateTab: Bool { !model.restoring && !creatingTab && currentSpace?.busy != true }
    private var canReload: Bool { displayed != nil && currentSpace?.busy == false && !model.restoring }
    private func resizeTabs() {
        let available = host.bounds.width - 20 - CGFloat(max(0, tabWidths.count - 1)) * 6
        let width = min(240, max(140, available / CGFloat(max(1, tabWidths.count))))
        tabWidths.forEach { $0.constant = width }
    }
    func windowDidResize(_ notification: Notification) { resizeTabs() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reloadPage) { return canReload }
        if menuItem.action == #selector(newTab(_:)) { return canCreateTab }
        if menuItem.action == #selector(focusAddress(_:)) { return address.isEnabled }
        return true
    }
    @objc func focusAddress(_ sender: Any?) {
        guard address.isEnabled else { return }
        beginAddressEditing()
        window.makeFirstResponder(address); address.selectText(nil)
        beginAddressEditing()
    }
    @objc private func startBrowsing(_ sender: Any?) {
        if let space = currentSpace, space.suspended {
            Task { @MainActor in
                let result = await model.handle(Request(command: "space.resume", args: [space.record.id.uuidString], options: [:]))
                if result["ok"] as? Bool != true { presentFailure(result) }
                refresh()
            }
            return
        }
        if displayed == nil { newTab(sender) } else { focusAddress(sender) }
    }
    @objc func newTab(_ sender: Any?) {
        guard canCreateTab else { NSSound.beep(); return }
        let spaceID = currentSpace?.record.id
        creatingTab = true; updateStatus()
        Task { @MainActor in
            defer { creatingTab = false; refresh(); focusAddress(nil) }
            let request: Request
            if let spaceID {
                request = Request(command: "tab.new", args: [], options: ["space": spaceID.uuidString])
            } else {
                request = Request(command: "space.create", args: ["personal"], options: ["proxy": "direct"])
            }
            let response = await model.handle(request)
            guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
                presentFailure(response); return
            }
            if let spaceID, let value = result["tabId"] as? String, let tabID = UUID(uuidString: value) {
                selectedSpace = spaceID; selectedTabs[spaceID] = tabID
            } else if let space = model.spaces.first(where: { $0.record.name == "personal" }) {
                selectedSpace = space.record.id; selectedTabs[space.record.id] = space.record.defaultTab
            }
            search.stringValue = ""; transientMessage = nil; saveSelection()
            refresh()
            if let view = tabStack.arrangedSubviews.last { view.scrollToVisible(view.bounds) }
        }
    }
    @objc private func openAddress(_ sender: Any?) {
        guard let space = currentSpace, let tab = displayed, !space.busy, !model.restoring else { NSSound.beep(); return }
        let input = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        // Bare domains and local host:port addresses use HTTPS; explicit HTTP is preserved.
        let url = input.contains("://") || input == "about:blank" ? input : "https://" + input
        guard let parsed = URLComponents(string: url),
              url == "about:blank" || (["http", "https"].contains(parsed.scheme?.lowercased() ?? "") && !(parsed.host ?? "").isEmpty && !input.contains(where: \.isWhitespace)) else {
            presentFailure(["error": ["message": "请输入完整网址，例如 https://example.com。"]]); return
        }
        window.makeFirstResponder(nil); transientMessage = nil
        Task { @MainActor in
            window.endEditing(for: address)
            window.makeFirstResponder(tab.webView)
            let result = await model.handle(Request(command: "open", args: [url], options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
            if result["ok"] as? Bool != true { presentFailure(result) }
            refresh()
        }
    }
    private func presentFailure(_ response: [String: Any]) {
        let message = (response["error"] as? [String: Any])?["message"] as? String ?? "操作未完成，请重试。"
        transientMessage = message; updateStatus()
        let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc func reloadPage() {
        guard canReload, let space = currentSpace, let tab = displayed else { NSSound.beep(); return }
        Task { @MainActor in
            let result = await model.handle(Request(command: "reload", args: [], options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
            if result["ok"] as? Bool != true, selectedSpace == space.record.id { transientMessage = (result["error"] as? [String: Any])?["message"] as? String }
            refresh()
        }
    }
    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        transientMessage = message; updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.transientMessage = nil; self?.updateStatus() }
    }
    private var socketArgument: String {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentWebKit/browser.sock").path
        return socketPath == standard ? "" : " --socket '" + socketPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    @objc private func copyCommand() {
        guard let space = currentSpace, let tab = displayed else { return }
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let command = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        copy(command + " snapshot --space \(space.record.id.uuidString) --tab \(tab.id.uuidString)" + socketArgument, message: "已复制接管命令，粘贴给 Agent 即可继续")
    }
    @objc private func showDetails(_ sender: Any?) {
        guard let space = currentSpace else { return }
        if infoPopover.isShown { infoPopover.close(); return }
        let title = NSTextField(labelWithString: space.record.name); title.font = .systemFont(ofSize: 17, weight: .semibold)
        let details = NSTextField(wrappingLabelWithString: "Space ID\n\(space.record.id.uuidString)\n\n网络\n\(space.record.proxy)\n\n证书\n\(security.stringValue)\n\nCLI 默认标签页\n\(space.record.defaultTab.uuidString)\n\n切换窗口中的标签页不会改变 CLI 的默认目标。网站数据保存在此 Space 中，关闭窗口后服务继续运行。")
        details.font = .systemFont(ofSize: 12); details.isSelectable = true
        let stack = NSStackView(views: [title, details]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let controller = NSViewController(); controller.view = stack
        infoPopover.contentViewController = controller; infoPopover.behavior = .transient
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .details }) {
            infoPopover.show(relativeTo: item)
        }
    }
    @objc func toggleSidebar(_ sender: Any?) { split.toggleSidebar(sender) }
    @objc func focusSpaces(_ sender: Any?) {
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(sender) }
        window.makeFirstResponder(search)
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }
    private func cycleTab(_ delta: Int) {
        guard let space = currentSpace, let index = space.tabs.firstIndex(where: { $0 === displayed }) else { return }
        selectedTabs[space.record.id] = space.tabs[(index + delta + space.tabs.count) % space.tabs.count].id
        saveSelection(); refresh()
        if let index = space.tabs.firstIndex(where: { $0 === displayed }), tabStack.arrangedSubviews.indices.contains(index) {
            let view = tabStack.arrangedSubviews[index]; view.scrollToVisible(view.bounds)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { saveSelection(); sender.orderOut(nil); return false }
}
