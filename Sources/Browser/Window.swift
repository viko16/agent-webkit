import AppKit
import SwiftUI

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

private final class ChromeBarView: NSStackView {
    var fillColor: NSColor?
    var tintColor: NSColor?
    var topBorder = false
    var bottomBorder = false

    override func draw(_ dirtyRect: NSRect) {
        if let fillColor {
            fillColor.setFill()
            bounds.fill()
        }
        if let tintColor {
            tintColor.setFill()
            bounds.fill(using: .sourceOver)
        }
        NSColor.separatorColor.setFill()
        if topBorder {
            let topY = isFlipped ? 0 : bounds.maxY - 1
            NSRect(x: 0, y: topY, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
        if bottomBorder {
            let bottomY = isFlipped ? bounds.maxY - 1 : 0
            NSRect(x: 0, y: bottomY, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("observer.sidebar")
    static let back = Self("observer.back")
    static let forward = Self("observer.forward")
    static let address = Self("observer.address")
    static let copyCommand = Self("observer.copyCommand")
    static let details = Self("observer.details")
    static let downloads = Self("observer.downloads")
    static let newTab = Self("observer.newTab")
}

@MainActor
final class ObserverWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSPopoverDelegate, NSMenuDelegate {
    let model: BrowserModel
    let window: NSWindow
    private let split = NSSplitViewController()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let noSearchResults = NSStackView()
    private let clearSearchButton = NSButton(title: "清除搜索", target: nil, action: nil)
    private let createFromSearch = NSButton(title: "新建 Space", target: nil, action: nil)
    private let host = NSView()
    private let address = AddressField()
    private let addressContainer = NSBox()
    private var addressWidth: NSLayoutConstraint?
    private let addressIcon = NSImageView()
    private let addressDisplay = NSTextField(labelWithString: "")
    private let addressHint = NSTextField(labelWithString: "")
    private let addressHintBar = ChromeBarView()
    private var editingAddress = false
    private var addressWasEdited = false
    private var addressDraft = ""
    private let reloadButton = NSButton()
    private let tabStack = NSStackView()
    private let tabBar = ChromeBarView()
    private let allTabs = NSPopUpButton(frame: .zero, pullsDown: true)
    private let pageFind = PageFindBar()
    private let dialogArea = NSStackView()
    private let popupNotice = ChromeBarView()
    private let popupNoticeText = NSTextField(labelWithString: "")
    private weak var announcedPopup: Tab?
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let busyTarget = NSButton(title: "查看执行页", target: nil, action: nil)
    private let handoff = NSButton(title: "交给 Agent", target: nil, action: nil)
    private var copiedTab: UUID?
    private var copyFeedbackExpiry: Task<Void, Never>?
    private let security = NSTextField(labelWithString: "")
    private let viewportButton = NSButton(title: "", target: nil, action: nil)
    private let spaceCount = NSTextField(labelWithString: "")
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "浏览会话，各自独立")
    private let emptyText = NSTextField(wrappingLabelWithString: "")
    private let emptyAction = NSButton(title: "打开网页", target: nil, action: nil)
    private let emptyCreateSpace = NSButton(title: "新建 Space…", target: nil, action: nil)
    private let banner = ChromeBarView()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "重新加载", target: nil, action: nil)
    private var refreshing = false
    private var selectedSpace: UUID? {
        didSet {
            if selectedSpace != oldValue { infoPopover.close() }
        }
    }
    private var selectedTabs: [UUID: UUID] = [:]
    private var filteredSpaces: [Space] = []
    private weak var displayed: Tab?
    private var tabSignature = ""
    private var transientMessage: String?
    private var transientExpiry: Task<Void, Never>?
    private struct PageActionError {
        let tab: UUID
        let navigation: Int
        let message: String
        let clearsAfterLoad: Bool
    }
    private var pageActionError: PageActionError?
    private var checkedBlockedProxySpace: UUID?
    private let selectionKey: String
    private let socketPath: String
    private let infoPopover = NSPopover()
    private weak var detailsState: SpaceDetailsState?
    private weak var infoSpace: Space?
    private let downloadsPopover = NSPopover()
    private let downloadsRefreshToken = DownloadsRefreshToken()
    private weak var downloadsSpace: Space?
    private let createButton = NSButton()
    private let spaceActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let suspensionItem = NSMenuItem()
    private let deleteItem = NSMenuItem(title: "删除 Space…", action: nil, keyEquivalent: "")
    private var activityExpiry: Task<Void, Never>?
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
        model.tabsCommitted = { [weak self] spaceID, before, after in
            guard let self, let selected = self.selectedTabs[spaceID],
                  !after.contains(where: { $0.id == selected }),
                  let index = before.firstIndex(where: { $0.id == selected }) else { return }
            // A close shifts the right neighbor into the vacated index.
            self.selectedTabs[spaceID] = after.isEmpty ? nil : after[min(index, after.count - 1)].id
            self.saveSelection()
        }
        model.willRemove = { [weak self] space in
            guard let self else { return }
            if space.tabs.contains(where: { $0 === self.displayed }) { self.displayed?.park(); self.displayed = nil }
            if self.infoSpace === space { self.infoPopover.close() }
            // Suspension keeps the Space and its selected tab. Deletion has detached it.
            if !self.model.spaces.contains(where: { $0 === space }) {
                self.selectedTabs.removeValue(forKey: space.record.id)
                self.saveSelection()
            }
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
        item.allowsFullHeightLayout = true
        item.minimumThickness = 200; item.maximumThickness = 280
        item.preferredThicknessFraction = 0.19
        split.addSplitViewItem(item)
        let heading = NSTextField(labelWithString: "Spaces")
        heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor
        search.placeholderString = "搜索 Space"
        search.textColor = .labelColor; search.font = .systemFont(ofSize: 13)
        search.delegate = self
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
        createFromSearch.target = self
        createFromSearch.action = #selector(createSpace)
        let searchActions = NSStackView(views: [clearSearchButton, createFromSearch])
        noSearchResults.orientation = .vertical
        noSearchResults.alignment = .centerX
        noSearchResults.addArrangedSubview(noMatches)
        noSearchResults.addArrangedSubview(searchActions)
        spaceCount.font = .systemFont(ofSize: 12); spaceCount.textColor = .secondaryLabelColor
        spaceCount.lineBreakMode = .byTruncatingTail
        spaceCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        createButton.target = self
        createButton.action = #selector(createSpace)
        createButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        createButton.toolTip = "新建 Space"
        createButton.setAccessibilityLabel("新建 Space")
        spaceActions.addItem(withTitle: "")
        spaceActions.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        (spaceActions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        spaceActions.toolTip = "所选 Space 的更多操作"
        spaceActions.setAccessibilityLabel("所选 Space 的更多操作")
        for item in [suspensionItem, deleteItem] {
            item.target = self
            item.action = #selector(performSpaceMenuAction(_:))
        }
        spaceActions.menu?.addItem(suspensionItem)
        spaceActions.menu?.addItem(.separator())
        spaceActions.menu?.addItem(deleteItem)
        NotificationCenter.default.addObserver(self, selector: #selector(prepareSpaceMenu(_:)),
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
        retry.target = self; retry.action = #selector(reloadPage); retry.bezelStyle = .rounded
        [warning, bannerText, retry].forEach { banner.addArrangedSubview($0) }
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.clipsToBounds = true
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        viewportButton.target = self; viewportButton.action = #selector(showViewport)
        viewportButton.bezelStyle = .inline
        viewportButton.toolTip = "缩放查看整个固定视口"
        busyTarget.bezelStyle = .inline; busyTarget.target = self; busyTarget.action = #selector(showBusyTab)
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
        let viewPopup = NSButton(title: "查看新标签页", target: self, action: #selector(showAnnouncedPopup))
        let dismissNotice = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提示")!,
                                     target: self, action: #selector(dismissPopupNotice))
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
        emptyAction.target = self; emptyAction.action = #selector(startBrowsing(_:)); emptyAction.bezelStyle = .rounded
        emptyCreateSpace.target = self; emptyCreateSpace.action = #selector(createSpace); emptyCreateSpace.bezelStyle = .rounded
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

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .address, .flexibleSpace, .downloads, .copyCommand, .details, .newTab]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
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
            let preferred = field.widthAnchor.constraint(equalToConstant: preferredAddressWidth)
            preferred.priority = .defaultHigh; preferred.isActive = true
            addressWidth = preferred
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
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
        } else if id == .copyCommand {
            handoff.target = self; handoff.action = #selector(copyCommand)
            handoff.bezelStyle = .texturedRounded
            item.label = "交给 Agent"; item.toolTip = "复制当前页面的接管命令"
            item.action = #selector(copyCommand); item.view = handoff
        } else {
            let values: (String, String, Selector)
            switch id {
            case .sidebar: values = ("显示／隐藏侧边栏（⌃⌘S）", "sidebar.left", #selector(toggleSidebar(_:)))
            case .back: values = ("后退（⌘[）", "chevron.backward", #selector(goBack))
            case .forward: values = ("前进（⌘]）", "chevron.forward", #selector(goForward))
            case .details: values = ("Space 信息", "info.circle", #selector(showDetails))
            case .downloads: values = ("下载", "arrow.down.circle", #selector(showDownloads))
            case .newTab: values = ("新建标签页（⌘T）", "plus", #selector(newTab(_:)))
            default: return nil
            }
            item.label = values.0; item.toolTip = values.0
            item.image = NSImage(systemSymbolName: values.1, accessibilityDescription: values.0)
            item.action = values.2; item.isBordered = true
        }
        switch id {
        case .address, .copyCommand, .newTab: item.visibilityPriority = .high
        case .details, .downloads: item.visibilityPriority = .low
        default: break
        }
        return item
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
        guard menu === table.menu else { return }
        menu.removeAllItems()
        let noSheet = window.attachedSheet == nil
        let row = table.clickedRow
        guard filteredSpaces.indices.contains(row) else {
            let createItem = NSMenuItem(title: "新建 Space…", action: #selector(createSpace), keyEquivalent: "")
            createItem.target = self
            createItem.isEnabled = !model.restoring && noSheet
            menu.addItem(createItem)
            return
        }
        let space = filteredSpaces[row]
        let canMutate = !space.busy && !model.restoring && noSheet
        let newTabItem = NSMenuItem(title: "新建标签页", action: #selector(contextNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self; newTabItem.representedObject = space.record.id; newTabItem.isEnabled = canMutate && !creatingTab
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
        guard let spaceID = sender.representedObject as? UUID, !model.restoring, !creatingTab,
              let space = model.spaces.first(where: { $0.record.id == spaceID }), !space.busy else { return }
        createTab(in: spaceID, opening: nil)
    }
    @objc private func contextShowDetails(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID,
              let space = model.spaces.first(where: { $0.record.id == spaceID }) else { return }
        if let row = filteredSpaces.firstIndex(where: { $0.record.id == spaceID }) {
            let rect = table.rect(ofRow: row)
            presentDetails(for: space, relativeTo: rect, of: table, preferredEdge: .maxX)
        } else {
            presentDetails(for: space)
        }
    }
    @objc private func contextCopySpaceID(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID, copyToPasteboard(spaceID.uuidString) else { return }
        showTransientMessage("已复制 Space ID")
    }
    @objc private func contextSpaceRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request else { return }
        performObserverRequest(request)
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { refresh() }
        if notification.object as? NSTextField === address {
            addressWasEdited = true
            addressDraft = address.stringValue
            clearAddressHint()
            if currentSpace?.busy == true || displayed?.pendingAddressDraft != nil {
                displayed?.pendingAddressDraft = addressDraft
            }
        }
    }
    private func showAddressHint(_ message: String) {
        addressHint.stringValue = message
        addressHint.isHidden = false
        addressHintBar.isHidden = false
        address.setAccessibilityHelp(message)
    }
    private func clearAddressHint() {
        addressHint.isHidden = true
        addressHintBar.isHidden = true
        address.setAccessibilityHelp(nil)
    }
    private func beginAddressEditing() {
        guard !editingAddress else { return }
        editingAddress = true
        addressWasEdited = displayed?.pendingAddressDraft != nil
        if let draft = displayed?.pendingAddressDraft { address.stringValue = draft }
        address.textColor = .labelColor; addressDisplay.isHidden = true
        addressContainer.borderWidth = 3; addressContainer.borderColor = .keyboardFocusIndicatorColor
        addressIcon.isHidden = false
        addressDraft = address.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === address else { return }
        clearAddressHint()
        editingAddress = false
        address.textColor = .clear; addressDisplay.isHidden = false
        addressContainer.borderWidth = 0.5; addressContainer.borderColor = .separatorColor
        addressIcon.isHidden = true
        updateStatus()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === search, selector == #selector(NSResponder.insertNewline(_:)) {
            if !search.stringValue.isEmpty, !filteredSpaces.isEmpty {
                let index = filteredSpaces.indices.contains(table.selectedRow) ? table.selectedRow : 0
                selectSpace(filteredSpaces[index])
                window.makeFirstResponder(table)
            }
            return true
        }
        if control === address, selector == #selector(NSResponder.insertNewline(_:)), currentSpace?.busy == true {
            displayed?.pendingAddressDraft = addressDraft
            updateStatus()
            return true
        }
        if control === address, selector == #selector(NSResponder.insertNewline(_:)) {
            addressDraft = textView.string
            openAddress(address)
            return true
        }
        guard control === address, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        displayed?.pendingAddressDraft = nil
        clearAddressHint()
        window.makeFirstResponder(nil); updateStatus(); return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        guard filteredSpaces.indices.contains(table.selectedRow) else { refresh(); return }
        selectSpace(filteredSpaces[table.selectedRow])
    }
    private func selectSpace(_ space: Space) {
        selectedSpace = space.record.id
        transientMessage = nil; saveSelection(); refresh()
    }
    @objc private func clearSearch() {
        search.stringValue = ""
        refresh()
        window.makeFirstResponder(search)
    }
    @objc private func pickTab(_ sender: NSButton) {
        guard let space = currentSpace else { return }
        sender.state = .on
        selectTab(at: sender.tag, in: space)
    }
    private func selectTab(at index: Int, in space: Space) {
        guard space.tabs.indices.contains(index) else { return }
        selectedTabs[space.record.id] = space.tabs[index].id
        transientMessage = nil; saveSelection(); refresh()
        if tabStack.arrangedSubviews.indices.contains(index) { let view = tabStack.arrangedSubviews[index]; view.scrollToVisible(view.bounds) }
    }
    @objc private func showAnnouncedPopup() {
        guard let space = currentSpace, let popup = announcedPopup,
              let index = space.tabs.firstIndex(where: { $0 === popup }) else { return }
        selectTab(at: index, in: space)
    }
    @objc private func dismissPopupNotice() {
        announcedPopup?.hasUnreadPopupNotice = false
        refresh()
    }
    private func saveSelection() {
        var saved = Dictionary(uniqueKeysWithValues: selectedTabs.map { ($0.key.uuidString, $0.value.uuidString) })
        saved["space"] = selectedSpace?.uuidString; UserDefaults.standard.set(saved, forKey: selectionKey)
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        filteredSpaces = model.spaces.filter { search.stringValue.isEmpty || $0.record.name.localizedCaseInsensitiveContains(search.stringValue) }
        if currentSpace == nil, selectedSpace != model.spaces.first?.record.id {
            selectedSpace = model.spaces.first?.record.id
            saveSelection()
        }
        noSearchResults.isHidden = search.stringValue.isEmpty || !filteredSpaces.isEmpty
        table.enclosingScrollView?.isHidden = !noSearchResults.isHidden
        table.reloadData()
        if let row = filteredSpaces.firstIndex(where: { $0.record.id == selectedSpace }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        spaceCount.stringValue = search.stringValue.isEmpty ? "\(model.spaces.count) 个 Space · 本机服务" : "找到 \(filteredSpaces.count) 个 Space"
        let pending = model.records.filter(\.deleting).count
        if pending > 0 { spaceCount.stringValue += " · \(pending) 待清理" }
        spaceCount.toolTip = spaceCount.stringValue
        createButton.isEnabled = !model.restoring
        createFromSearch.isEnabled = createButton.isEnabled
        spaceActions.isEnabled = table.selectedRow >= 0 && currentSpace?.busy == false && !model.restoring
        activityExpiry?.cancel()
        emptyAction.title = "打开网页"
        emptyText.maximumNumberOfLines = 0
        emptyText.toolTip = nil
        emptyAction.isEnabled = !model.restoring && !creatingTab && currentSpace?.busy != true
        emptyCreateSpace.isEnabled = !model.restoring
        emptyCreateSpace.isHidden = !model.spaces.isEmpty
        guard let space = currentSpace else {
            displayed?.park(); displayed = nil; empty.isHidden = !search.stringValue.isEmpty
            emptyTitle.stringValue = "浏览会话，各自独立"
            emptyText.stringValue = "在地址栏输入网址，按回车打开。\n首次打开会创建 personal Space，使用直连和系统证书校验。"
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }; tabSignature = ""
            tabWidths = []; allTabs.isHidden = true
            updateStatus(); return
        }
        let selected = selectedTabs[space.record.id]
        let tab = space.tabs.first { $0.id == selected } ?? space.tabs.first
        if let tab, selected != tab.id {
            selectedTabs[space.record.id] = tab.id
            saveSelection()
        }
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
        let now = ContinuousClock.now
        if let expiry = space.activity.values.compactMap(\.recentUntil).filter({ $0 > now }).min() {
            activityExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(until: expiry, clock: .continuous) }
                catch { return }
                self?.refresh()
            }
        }
        let signature = space.tabs.map {
            let activity = space.activity[$0.id]
            return "\($0.id)|\($0.webView.title ?? "")|\($0.persistedURL)|\(activity?.executing ?? 0)|\(activity?.recent == true)|\($0.dialogs.pendingCount)|\($0.downloads.hasActive)"
        }.joined() + "\(tab?.id.uuidString ?? "")|\(space.busy)"
        if signature != tabSignature {
            tabSignature = signature
            updateTabs(in: space, activeTab: tab)
        }
        if displayed !== tab {
            // An unfinished address belongs to the tab where it was typed.
            pageActionError = nil
            clearAddressHint()
            window.endEditing(for: address)
            displayed?.park(); displayed = tab
            if let tab {
                tab.inputFocusConflict = { [weak self] in
                    guard let self else { return false }
                    return self.editingAddress || (self.window.isKeyWindow && (self.search.currentEditor() != nil || self.pageFind.isEditingQuery))
                }
                tab.mount(in: host)
            }
        }
        tab?.webView.isHidden = blank
        // A view hidden for the blank state must become visible when parked in another Space.
        if blank { host.addSubview(empty, positioned: .above, relativeTo: tab?.webView) }
        updateStatus()
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
            let title = tabTitle(candidate)
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
        guard let space = model.spaces.first(where: { $0.record.id == spaceID }),
              let tab = space.tabs.first(where: { $0.id == tabID }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = TabMenuTarget(spaceID: spaceID, tabID: tabID)
        let running = (space.activity[tabID]?.executing ?? 0) > 0
        let canOperate = !space.busy && !model.restoring && window.attachedSheet == nil

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

        let otherTabs = space.tabs.filter { $0.id != tabID }
        let anyOtherExecuting = otherTabs.contains { (space.activity[$0.id]?.executing ?? 0) > 0 }
        let closeOthersItem = NSMenuItem(title: "关闭其他标签页", action: #selector(contextCloseOtherTabs(_:)), keyEquivalent: "")
        closeOthersItem.target = self; closeOthersItem.representedObject = target
        closeOthersItem.isEnabled = !otherTabs.isEmpty && canOperate && !anyOtherExecuting
        menu.addItem(closeOthersItem)
        return menu
    }

    @objc private func contextReloadTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget else { return }
        performObserverRequest(Request(command: "reload", args: [], options: ["space": target.spaceID.uuidString, "tab": target.tabID.uuidString]))
    }
    @objc private func contextCopyTabURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String, copyToPasteboard(url) else { return }
        showTransientMessage("已复制网址")
    }
    @objc private func contextHandoffTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget,
              let space = model.spaces.first(where: { $0.record.id == target.spaceID }),
              let tab = space.tabs.first(where: { $0.id == target.tabID }) else { return }
        copyHandoffCommand(space: space, tab: tab)
    }
    @objc private func contextCloseTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget else { return }
        closeTab(spaceID: target.spaceID, tabID: target.tabID)
    }
    @objc private func contextCloseOtherTabs(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TabMenuTarget,
              let space = model.spaces.first(where: { $0.record.id == target.spaceID }),
              !space.busy, !model.restoring,
              space.tabs.contains(where: { $0.id == target.tabID }) else { return }
        let others = space.tabs.filter { $0.id != target.tabID }
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
                presentFailure(failure(error))
                return
            }
        }
        func executeBatch() {
            Task { @MainActor in
                for entry in impacts {
                    guard let liveSpace = self.model.spaces.first(where: { $0.record.id == target.spaceID }),
                          liveSpace.tabs.contains(where: { $0.id == target.tabID }),
                          liveSpace.tabs.count > 1 else { break }
                    let request = Request(command: "tab.close", args: [], options: ["space": target.spaceID.uuidString, "tab": entry.tabID.uuidString])
                    let origin: RequestOrigin = entry.impact.map(RequestOrigin.confirmed) ?? .observer
                    var changedImpact: ObserverImpact?
                    let response = await self.model.handle(request, origin: origin) { changedImpact = $0 }
                    if let impact = changedImpact {
                        self.confirm("标签页状态已变化，继续关闭？", detail: impact.detail, action: "关闭标签页", destructive: true) {
                            self.performObserverRequest(request, origin: .confirmed(impact))
                        }
                        break
                    }
                    if response["ok"] as? Bool != true {
                        let code = (response["error"] as? [String: Any])?["code"] as? String
                        if code != "tab_not_found" {
                            self.presentFailure(response)
                            break
                        }
                    }
                }
                self.refresh()
            }
        }
        let hasImpact = downloadCount > 0 || dialogCount > 0 || recentCount > 0
        if hasImpact {
            var lines = ["将关闭「\(space.record.name)」中的其余 \(others.count) 个标签页。"]
            if downloadCount > 0 { lines.append("将中断 \(downloadCount) 项活跃下载。") }
            if dialogCount > 0 { lines.append("将关闭 \(dialogCount) 个待处理的网页对话框。") }
            if recentCount > 0 { lines.append("其中 \(recentCount) 个标签页在最近 5 分钟内有 Agent 操作。") }
            confirm("关闭其他 \(others.count) 个标签页？", detail: lines.joined(separator: "\n"), action: "关闭其他标签页", destructive: true) {
                executeBatch()
            }
        } else {
            executeBatch()
        }
    }

    private func updateStatus() {
        let space = currentSpace; let tab = displayed
        pageFind.bind(to: tab?.persistedURL == "about:blank" ? nil : tab?.webView, document: tab?.navigationSequence)
        tab?.hasUnreadPopupNotice = false
        announcedPopup = tab.flatMap { opener in
            space?.tabs.last { $0.hasUnreadPopupNotice && $0.openerTabID == opener.id }
        }
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
        if infoPopover.isShown {
            if let infoSpace, !model.spaces.contains(where: { $0 === infoSpace }) { infoPopover.close() }
            else { detailsState?.objectWillChange.send() }
        }
        if downloadsPopover.isShown {
            if downloadsSpace !== space { downloadsPopover.close() }
            else { downloadsRefreshToken.tick &+= 1 }
        }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .downloads }) {
            let active = space?.tabs.contains { $0.downloads.hasActive } == true
            item.isEnabled = space != nil
            item.toolTip = active ? "下载（有下载正在进行）" : "查看此 Space 的下载"
            item.image = NSImage(systemSymbolName: active ? "arrow.down.circle.fill" : "arrow.down.circle",
                                 accessibilityDescription: item.toolTip)
        }
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
        let url = tab?.persistedURL == "about:blank" ? "" : tab?.persistedURL ?? ""
        if !editingAddress {
            if var origin = URLComponents(string: url), let scheme = origin.scheme?.lowercased(),
               ["http", "https"].contains(scheme), origin.host != nil {
                origin.user = nil; origin.password = nil
                origin.path = ""; origin.query = nil; origin.fragment = nil
                if origin.port == (scheme == "https" ? 443 : 80) { origin.port = nil }
                addressDisplay.stringValue = origin.string ?? url
            } else { addressDisplay.stringValue = url }
            if address.stringValue != url { address.stringValue = url }
        }
        address.toolTip = tab?.persistedURL
        address.placeholderString = "输入网址"
        address.isEnabled = (tab != nil || model.spaces.isEmpty) && !model.restoring && !creatingTab
        let isLoading = tab?.webView.isLoading == true
        progress.doubleValue = isLoading ? max(0.03, tab?.webView.estimatedProgress ?? 0) : 0
        progress.alphaValue = isLoading ? 1 : 0
        if isLoading {
            reloadButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "停止加载")
            reloadButton.action = #selector(stopLoadingPage)
            reloadButton.toolTip = "停止加载（⌘.）"
            reloadButton.setAccessibilityLabel("停止加载")
            reloadButton.isEnabled = canStopLoading
        } else {
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载")
            reloadButton.action = #selector(reloadPage)
            reloadButton.toolTip = "重新加载（⌘R）"
            reloadButton.setAccessibilityLabel("重新加载")
            reloadButton.isEnabled = canReload
        }
        let runningTab = space?.tabs.first { $0.id == space?.busyTabID }
        if editingAddress, addressWasEdited, space?.busy == true { tab?.pendingAddressDraft = addressDraft }
        busyTarget.isHidden = runningTab == nil || runningTab === tab
        handoff.isEnabled = tab != nil
        handoff.title = copiedTab != nil && copiedTab == tab?.id ? "已复制 ✓" : "交给 Agent"
        handoff.setAccessibilityLabel(copiedTab != nil && copiedTab == tab?.id ? "已复制接管命令" : "交给 Agent，复制当前页面的接管命令")
        let networkError = space?.networkError
        let proxyState = proxyRecovery(networkError)
        if proxyState != .blocked || checkedBlockedProxySpace != selectedSpace { checkedBlockedProxySpace = nil }
        let recheckProxy = proxyState != .ready
        let networkPaused = recheckProxy || networkError != nil
        if pendingDialog != nil { status.stringValue = "网页等待回复" }
        else if model.restoring { status.stringValue = "正在恢复会话…" }
        else if networkPaused { status.stringValue = "网络连接已暂停" }
        else if space?.busy == true {
            let name = runningTab.map(tabTitle) ?? "当前 Space"
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
        if let notice = pageActionError, notice.tab != tab?.id || notice.navigation != tab?.navigationSequence ||
            (notice.clearsAfterLoad && tab?.navigationPending == false && tab?.webView.isLoading == false) {
            pageActionError = nil
        }
        let rejection = tab?.observerDismissedRejection == true ? nil : tab?.lastNavigationRejection
        let actionMessage = pageActionError?.message
        let error = networkError?.localizedDescription ?? actionMessage ?? rejection?.localizedDescription ?? (tab?.unresponsive == true ? "页面未响应。重新加载可恢复标签页；上次操作可能已部分生效。" : tab?.navigationError?.localizedDescription)
        let failedNavigation = !networkPaused && actionMessage == nil && rejection == nil && tab?.unresponsive == false && tab?.hasFailedNavigation == true
        let target = failedNavigation ? tab?.failedNavigationTarget : nil
        if checkedBlockedProxySpace != nil {
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
        bannerText.toolTip = bannerText.stringValue
        banner.isHidden = error == nil
        let dismissible = rejection != nil || actionMessage != nil
        if recheckProxy {
            retry.title = "重新检查"; retry.action = #selector(recheckSystemProxy)
        } else if dismissible {
            retry.title = "忽略"; retry.action = #selector(dismissPageNotice)
        } else {
            retry.title = failedNavigation ? "重试此网址" : "重新加载"
            retry.action = failedNavigation ? #selector(retryFailedNavigation) : #selector(reloadPage)
        }
        retry.isHidden = (networkError != nil && !recheckProxy) || (failedNavigation && target?.isGET != true)
        retry.isEnabled = recheckProxy ? space != nil && space?.busy == false : dismissible || canReload
        window.toolbar?.items.first { $0.itemIdentifier == .copyCommand }?.isEnabled = tab != nil
        window.toolbar?.items.first { $0.itemIdentifier == .details }?.isEnabled = space != nil
        window.toolbar?.items.first { $0.itemIdentifier == .newTab }?.isEnabled = canCreateTab
        window.toolbar?.items.first { $0.itemIdentifier == .back }?.isEnabled = canTraverse(back: true)
        window.toolbar?.items.first { $0.itemIdentifier == .forward }?.isEnabled = canTraverse(back: false)
    }
    private var canCreateTab: Bool {
        !model.restoring && !creatingTab && currentSpace?.busy != true && (search.stringValue.isEmpty || table.selectedRow >= 0)
    }
    private var canReload: Bool { displayed != nil && currentSpace?.busy == false && !model.restoring }
    private var canStopLoading: Bool {
        displayed?.webView.isLoading == true && !model.restoring && currentSpace?.busyOrigin != .agent
    }
    private func tabTitle(_ tab: Tab) -> String {
        if let title = tab.webView.title, !title.isEmpty { return title }
        return tab.persistedURL == "about:blank" ? "新标签页" : URL(string: tab.persistedURL)?.host ?? "页面"
    }
    @objc private func selectListedTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let space = currentSpace,
              let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(at: index, in: space)
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
        if let space = currentSpace, let selected = selectedTabs[space.record.id],
           let index = space.tabs.firstIndex(where: { $0.id == selected }), tabStack.arrangedSubviews.indices.contains(index) {
            let active = tabStack.arrangedSubviews[index]
            active.scrollToVisible(active.bounds)
        }
    }
    private var preferredAddressWidth: CGFloat { min(560, max(150, window.frame.width - 510)) }
    func windowDidResize(_ notification: Notification) { addressWidth?.constant = preferredAddressWidth }
    private func isMainMenuItem(_ menuItem: NSMenuItem) -> Bool {
        var current = menuItem.menu
        while let menu = current {
            if menu === NSApp.mainMenu { return true }
            current = menu.supermenu
        }
        return false
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = split.splitViewItems.first?.isCollapsed == true ? "显示侧边栏" : "隐藏侧边栏"
        }
        guard window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else { return false }
        if let key = NSApp.keyWindow, key !== window, isMainMenuItem(menuItem) { return false }
        if menuItem.action == #selector(closeCurrentTab(_:)) {
            guard window.isKeyWindow, let space = currentSpace, let tab = displayed else { return false }
            return !space.busy && space.tabs.count > 1 && (space.activity[tab.id]?.executing ?? 0) == 0
        }
        if menuItem.action == #selector(reloadPage) { return canReload }
        if menuItem.action == #selector(stopLoadingPage) { return canStopLoading }
        if menuItem.action == #selector(zoomIn(_:)) { return displayed != nil && (displayed?.webView.pageZoom ?? 1) < 3.0 }
        if menuItem.action == #selector(zoomOut(_:)) { return displayed != nil && (displayed?.webView.pageZoom ?? 1) > 0.5 }
        if menuItem.action == #selector(resetZoom(_:)) { return displayed != nil && abs((displayed?.webView.pageZoom ?? 1) - 1.0) > 0.01 }
        if menuItem.action == #selector(newTab(_:)) { return canCreateTab }
        if menuItem.action == #selector(focusAddress(_:)) { return address.isEnabled }
        if menuItem.action == #selector(goBack) { return canTraverse(back: true) }
        if menuItem.action == #selector(goForward) { return canTraverse(back: false) }
        if menuItem.action == #selector(nextTab(_:)) || menuItem.action == #selector(previousTab(_:)) {
            return (currentSpace?.tabs.count ?? 0) > 1
        }
        if menuItem.action == #selector(selectTabShortcut(_:)) {
            let count = currentSpace?.tabs.count ?? 0
            if count <= 1 { return false }
            return menuItem.tag == 9 || menuItem.tag <= count
        }
        if menuItem.action == #selector(findInPage(_:)), let action = NSTextFinder.Action(rawValue: menuItem.tag) {
            return pageFind.canPerform(action)
        }
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
            performObserverRequest(Request(command: "space.resume", args: [space.record.id.uuidString], options: [:]))
            return
        }
        focusAddress(sender)
    }
    @objc func newTab(_ sender: Any?) {
        guard canCreateTab else { NSSound.beep(); return }
        createTab(in: currentSpace?.record.id, opening: nil)
    }
    private func createTab(in spaceID: UUID?, opening url: String?) {
        creatingTab = true; updateStatus()
        Task { @MainActor in
            let request: Request
            if let spaceID {
                request = Request(command: "tab.new", args: [], options: ["space": spaceID.uuidString])
            } else {
                request = Request(command: "space.create", args: ["personal"], options: ["proxy": "direct"])
            }
            let response = await model.handle(request, origin: .observer)
            creatingTab = false
            guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
                presentFailure(response); return
            }
            // Target the IDs acknowledged by creation, even if the observer selection changed.
            let createdSpace = spaceID ?? (result["id"] as? String).flatMap(UUID.init(uuidString:))
            let tabs = result["tabs"] as? [[String: Any]]
            let createdTab = (result["tabId"] as? String ?? tabs?.first?["tabId"] as? String).flatMap(UUID.init(uuidString:))
            guard let createdSpace, let createdTab else { refresh(); return }
            selectedSpace = createdSpace; selectedTabs[createdSpace] = createdTab
            search.stringValue = ""; transientMessage = nil; saveSelection()
            refresh()
            if let view = tabStack.arrangedSubviews.last { view.scrollToVisible(view.bounds) }
            if let url {
                window.makeFirstResponder(displayed?.webView)
                performObserverRequest(Request(command: "open", args: [url], options: ["space": createdSpace.uuidString, "tab": createdTab.uuidString]))
            } else { focusAddress(nil) }
        }
    }
    @objc private func openAddress(_ sender: Any?) {
        guard address.isEnabled, currentSpace?.busy != true else { NSSound.beep(); return }
        let input = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        // Loopback targets default to HTTP; remote hosts default to HTTPS; explicit schemes are preserved.
        let hasExplicitScheme = input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
        let loopbackHost = input.range(
            of: #"^(?:localhost|127\.0\.0\.1|\[::1\])(?::[0-9]+)?(?:[/#?]|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let hostWithPort = input.range(
            of: #"^(?:localhost|\[::1\]|[A-Z0-9-]+(?:\.[A-Z0-9-]+)+):[0-9]+(?:[/#?]|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let url: String
        if hasExplicitScheme && !hostWithPort && !loopbackHost {
            url = input
        } else if loopbackHost {
            url = "http://" + input
        } else {
            url = "https://" + input
        }
        guard let parsed = URLComponents(string: url),
              url == "about:blank" || (["http", "https"].contains(parsed.scheme?.lowercased() ?? "") && !(parsed.host ?? "").isEmpty && !input.contains(where: \.isWhitespace)) else {
            showAddressHint("请输入有效网址，例如 https://example.com 或 localhost:5173。")
            return
        }
        displayed?.pendingAddressDraft = nil
        clearAddressHint()
        window.makeFirstResponder(nil); transientMessage = nil
        if model.spaces.isEmpty { createTab(in: nil, opening: url); return }
        guard let space = currentSpace, let tab = displayed else { return }
        Task { @MainActor in
            window.endEditing(for: address)
            window.makeFirstResponder(tab.webView)
            performObserverRequest(Request(command: "open", args: [url], options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
        }
    }

    private func canTraverse(back: Bool) -> Bool {
        guard canReload, let tab = displayed, !tab.terminated, !tab.unresponsive,
              !tab.navigationPending, !tab.webView.isLoading else { return false }
        return back ? tab.webView.canGoBack : tab.webView.canGoForward
    }
    @objc func goBack() { traverse(back: true) }
    @objc func goForward() { traverse(back: false) }
    private func traverse(back: Bool) {
        guard canTraverse(back: back), let space = currentSpace, let tab = displayed else { return }
        performObserverRequest(Request(command: back ? "back" : "forward", args: [],
            options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
    }
    @objc func findInPage(_ sender: NSMenuItem) {
        guard let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        pageFind.perform(action)
    }
    @objc func stopLoadingPage() {
        guard canStopLoading else { return }
        displayed?.stopLoadingByObserver()
    }
    @objc func zoomIn(_ sender: Any?) { adjustZoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { adjustZoom(by: -0.1) }
    @objc func resetZoom(_ sender: Any?) { displayed?.webView.pageZoom = 1.0 }
    private func adjustZoom(by delta: CGFloat) {
        guard let webView = displayed?.webView else { return }
        let next = ((webView.pageZoom + delta) * 10).rounded() / 10
        webView.pageZoom = min(3.0, max(0.5, next))
    }
    @objc func selectTabShortcut(_ sender: NSMenuItem) {
        guard let space = currentSpace, space.tabs.count > 1 else { return }
        let index = sender.tag == 9 ? space.tabs.count - 1 : sender.tag - 1
        selectTab(at: index, in: space)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard window.isKeyWindow, let space = currentSpace, let tab = displayed else { return }
        closeTab(spaceID: space.record.id, tabID: tab.id)
    }
    @objc private func closeTabButton(_ sender: NSButton) {
        guard let space = currentSpace, let raw = sender.identifier?.rawValue, let tabID = UUID(uuidString: raw) else { return }
        closeTab(spaceID: space.record.id, tabID: tabID)
    }
    private func closeTab(spaceID: UUID, tabID: UUID) {
        performObserverRequest(Request(command: "tab.close", args: [], options: ["space": spaceID.uuidString, "tab": tabID.uuidString]))
    }
    private func confirm(_ title: String, detail: String, action: String, destructive: Bool = false, critical: Bool = false, perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .warning
        alert.messageText = title; alert.informativeText = detail
        let actionButton = alert.addButton(withTitle: action)
        if destructive {
            actionButton.hasDestructiveAction = true
            actionButton.keyEquivalent = ""
        }
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { perform() } }
    }
    @objc private func createSpace() {
        let sheet = SpaceCreationSheet()
        sheet.submit = { [weak self, weak sheet] request in
            guard let self, let sheet else { return }
            Task { @MainActor in
                let response = await self.model.handle(request, origin: .observer)
                guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
                      let raw = result["id"] as? String, let id = UUID(uuidString: raw) else {
                    sheet.finishSubmission(error: (response["error"] as? [String: Any])?["message"] as? String ?? "创建失败，请重试。")
                    return
                }
                self.search.stringValue = ""
                self.selectedSpace = id
                self.transientMessage = nil
                self.saveSelection()
                self.refresh()
                sheet.finishSubmission()
            }
        }
        split.presentAsSheet(sheet)
    }
    @objc private func prepareSpaceMenu(_ notification: Notification) {
        guard let space = currentSpace else { return }
        suspensionItem.title = space.suspended ? "恢复 Space" : "休眠 Space…"
        let target = [space.record.id.uuidString]
        suspensionItem.representedObject = Request(command: space.suspended ? "space.resume" : "space.suspend", args: target, options: [:])
        deleteItem.representedObject = Request(command: "space.delete", args: target, options: [:])
    }
    @objc private func performSpaceMenuAction(_ item: NSMenuItem) {
        guard spaceActions.isEnabled, let request = item.representedObject as? Request,
              request.args.first == currentSpace?.record.id.uuidString else { return }
        performObserverRequest(request)
    }

    private func performObserverRequest(_ request: Request, origin: RequestOrigin = .observer) {
        Task { @MainActor in
            var confirmation: ObserverImpact?
            let response = await model.handle(request, origin: origin) { confirmation = $0 }
            if let impact = confirmation {
                let action: String
                switch request.command {
                case "tab.close": action = "关闭标签页"
                case "space.delete": action = "删除 Space"
                case "space.suspend": action = "休眠 Space"
                case "reload": action = "重新加载页面"
                case "back": action = "后退"
                case "forward": action = "前进"
                default: action = "前往网址"
                }
                var title = "\(action)（\(impact.spaceName)）？"
                var detail = impact.detail
                if request.command == "tab.close",
                   let space = model.spaces.first(where: { $0.record.id == impact.spaceID }),
                   let target = space.tabs.first(where: { $0.id.uuidString == request.options["tab"] }) {
                    title = "关闭“\(tabTitle(target))”？"
                    let location = URL(string: target.persistedURL)?.host ?? target.persistedURL
                    detail = "\(space.record.name) · \(location)\n\(detail)"
                }
                let destructive = ["tab.close", "space.delete"].contains(request.command)
                let critical = request.command == "space.delete"
                confirm(title, detail: detail, action: action, destructive: destructive, critical: critical) {
                    self.performObserverRequest(request, origin: .confirmed(impact))
                }
                return
            }
            guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
                if ["open", "reload", "back", "forward"].contains(request.command) {
                    guard let tab = displayed, tab.id.uuidString == request.options["tab"],
                          selectedSpace?.uuidString == request.options["space"] else { return }
                    let error = response["error"] as? [String: Any]
                    let message = error?["message"] as? String ?? "页面操作未完成。"
                    let visibleRejection = tab.observerDismissedRejection ? nil : tab.lastNavigationRejection
                    if currentSpace?.networkError == nil, tab.navigationError?.localizedDescription != message,
                       visibleRejection?.localizedDescription != message {
                        pageActionError = PageActionError(tab: tab.id, navigation: tab.navigationSequence, message: message,
                                                          clearsAfterLoad: error?["code"] as? String == "timeout" && tab.navigationPending)
                    }
                    refresh()
                } else if request.command == "space.suspend",
                          let targetSpace = model.spaces.first(where: { $0.record.id.uuidString == request.args.first }),
                          targetSpace.tabs.contains(where: { $0.downloads.hasActive }) {
                    let alert = NSAlert()
                    alert.messageText = "下载期间无法休眠"
                    alert.informativeText = "等「\(targetSpace.record.name)」的下载完成，或在下载列表中取消后，再休眠此 Space。"
                    alert.addButton(withTitle: "管理下载")
                    let cancelButton = alert.addButton(withTitle: "取消")
                    cancelButton.keyEquivalent = "\u{1b}"
                    alert.beginSheetModal(for: window) { [weak self = self, weak targetSpace] response in
                        guard let self, let targetSpace, response == .alertFirstButtonReturn,
                              self.model.spaces.contains(where: { $0 === targetSpace }) else { return }
                        if self.currentSpace !== targetSpace { self.selectSpace(targetSpace) }
                        if self.currentSpace === targetSpace { self.showDownloads() }
                    }
                } else { presentFailure(response) }
                return
            }
            transientExpiry?.cancel(); transientExpiry = nil
            if request.command == "space.delete" {
                transientMessage = result["cleanupPending"] as? Bool == true ? "Space 已移除，数据容器仍待清理。" : "Space 及网站数据已删除。"
            } else { transientMessage = nil }
            refresh()
        }
    }
    private func presentFailure(_ response: [String: Any]) {
        let message = (response["error"] as? [String: Any])?["message"] as? String ?? "操作未完成，请重试。"
        let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc private func dismissPageNotice() {
        if pageActionError != nil { pageActionError = nil }
        else { displayed?.observerDismissedRejection = true }
        updateStatus()
    }
    private enum ProxyRecovery { case ready, blocked, needsReload }
    private func proxyRecovery(_ networkError: BrowserError?) -> ProxyRecovery {
        if networkError?.code == "direct_system_proxy_conflict" { return .blocked }
        if (displayed?.navigationError as? BrowserError)?.code == "direct_system_proxy_conflict" { return .needsReload }
        return .ready
    }
    @objc private func recheckSystemProxy() {
        switch proxyRecovery(currentSpace?.networkError) {
        case .blocked:
            checkedBlockedProxySpace = selectedSpace
            refresh()
        case .needsReload: reloadPage()
        case .ready: refresh()
        }
    }
    @objc func reloadPage() {
        guard canReload, let space = currentSpace, let tab = displayed else { NSSound.beep(); return }
        performObserverRequest(Request(command: "reload", args: [], options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
    }
    @objc private func retryFailedNavigation() {
        guard canReload, let space = currentSpace, let tab = displayed,
              let target = tab.failedNavigationTarget, target.isGET else { return }
        performObserverRequest(Request(command: "open", args: [target.url.absoluteString],
            options: ["space": space.record.id.uuidString, "tab": tab.id.uuidString]))
    }
    @objc private func showBusyTab() {
        guard let space = currentSpace, let id = space.busyTabID,
              space.tabs.contains(where: { $0.id == id }) else { return }
        selectedTabs[space.record.id] = id
        saveSelection(); refresh()
    }
    private var socketArgument: String {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentWebKit/browser.sock").path
        return socketPath == standard ? "" : " --socket '" + socketPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private var cliCommandName: String {
        let currentExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        if socketArgument.isEmpty, let currentExecutable,
           ["/opt/homebrew/bin/awb", "/usr/local/bin/awb"].contains(where: {
               FileManager.default.isExecutableFile(atPath: $0)
                   && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == currentExecutable
           }) {
            return "awb"
        }
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    @discardableResult
    private func copyToPasteboard(_ value: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
    private func showTransientMessage(_ message: String) {
        transientMessage = message
        updateStatus()
        transientExpiry?.cancel()
        transientExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.transientMessage == message else { return }
            self.transientMessage = nil
            self.updateStatus()
        }
    }
    @objc private func copyCommand() {
        guard let space = currentSpace, let tab = displayed else { return }
        copyHandoffCommand(space: space, tab: tab)
    }
    private func copyHandoffCommand(space: Space, tab: Tab) {
        let text = "\(cliCommandName) snapshot --space \(space.record.id.uuidString) --tab \(tab.id.uuidString)\(socketArgument)"
        guard copyToPasteboard(text) else { return }
        copiedTab = tab.id
        if tab !== displayed {
            showTransientMessage("已复制接管命令")
        } else {
            updateStatus()
        }
        NSAccessibility.post(element: handoff, notification: .announcementRequested,
                             userInfo: [.announcement: "已复制接管命令", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        copyFeedbackExpiry?.cancel()
        copyFeedbackExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.copiedTab = nil; self?.updateStatus()
        }
    }
    private func certificatePolicy(of space: Space) -> String {
        if space.record.tls?.ignoreCertificateErrors == true { return "忽略证书错误" }
        return space.record.tls == nil ? "系统证书校验" : "系统证书及自定义 CA"
    }
    private func showPopover(_ popover: NSPopover, toolbarItemID: NSToolbarItem.Identifier) {
        if let item = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier == toolbarItemID }) {
            popover.show(relativeTo: item)
        } else if spaceActions.window != nil, !spaceActions.isHiddenOrHasHiddenAncestor {
            popover.show(relativeTo: spaceActions.bounds, of: spaceActions, preferredEdge: .maxX)
        } else {
            let anchor = NSRect(x: max(0, host.bounds.maxX - 1), y: max(0, host.bounds.maxY - 1), width: 1, height: 1)
            popover.show(relativeTo: anchor, of: host, preferredEdge: .maxY)
        }
    }
    @objc private func showDetails(_ sender: Any?) {
        guard let space = currentSpace else { return }
        if infoPopover.isShown && infoSpace === space { infoPopover.close(); return }
        presentDetails(for: space)
    }
    private func presentDetails(for space: Space, relativeTo rect: NSRect? = nil, of view: NSView? = nil, preferredEdge: NSRectEdge = .maxY) {
        downloadsPopover.close()
        if infoPopover.isShown { infoPopover.close() }
        infoSpace = space
        let state = SpaceDetailsState()
        detailsState = state
        let content = SpaceDetailsView(space: space, model: model, activeTabProvider: { [weak self, weak space] in
            guard let self, let space else { return nil }
            if space === self.currentSpace { return self.displayed }
            return space.tabs.first { $0.id == self.selectedTabs[space.record.id] } ?? space.tabs.first
        }, state: state)
        infoPopover.contentViewController = NSHostingController(rootView: content)
        infoPopover.behavior = .transient
        infoPopover.delegate = self
        if let rect, let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor {
            infoPopover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        } else {
            showPopover(infoPopover, toolbarItemID: .details)
        }
    }
    @objc private func showViewport() {
        guard let tab = displayed, let viewport = tab.fixedViewport else { return }
        split.presentAsSheet(ViewportPreview(webView: tab.webView, viewport: viewport, available: window.frame.size))
    }
    @objc private func showDownloads() {
        guard let space = currentSpace else { return }
        if downloadsPopover.isShown { downloadsPopover.close(); return }
        infoPopover.close()
        downloadsSpace = space
        downloadsPopover.behavior = .transient
        downloadsPopover.delegate = self
        let content = SpaceDownloadsView(space: space, refreshToken: downloadsRefreshToken) { [weak self, weak space] message in
            guard let self, let space, self.currentSpace === space else { return }
            self.downloadsPopover.close()
            self.presentFailure(["error": ["message": message]])
        }
        downloadsPopover.contentViewController = NSHostingController(rootView: content)
        showPopover(downloadsPopover, toolbarItemID: .downloads)
    }
    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === downloadsPopover, !downloadsPopover.isShown {
            downloadsPopover.contentViewController = nil
            downloadsSpace = nil
        } else if notification.object as? NSPopover === infoPopover, !infoPopover.isShown {
            infoPopover.contentViewController = nil
            infoSpace = nil
        }
    }
    @objc func hideWindow(_ sender: Any?) { window.performClose(sender) }
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
