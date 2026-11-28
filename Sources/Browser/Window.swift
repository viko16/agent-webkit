import AppKit
import SwiftUI

// Supply the complete URL before AppKit populates its shared field editor, for both
// mouse editing and key-view selection. The field draws its own bezel and focus ring.
private final class AddressCell: NSTextFieldCell {
    var willEdit: (() -> Void)?
    override func edit(withFrame frame: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        willEdit?()
        super.edit(withFrame: frame, in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame frame: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        willEdit?()
        super.select(withFrame: frame, in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}

// A custom toolbar field and the content views live in separate AppKit key-view loops.
// Treat the address as the stop immediately following the sidebar search field.
private class ObserverKeyWindow: NSWindow {
    weak var spaceSearch: NSSearchField?
    weak var locationField: NSTextField?

    private var addressInLoop: NSTextField? {
        guard let field = locationField, toolbar?.isVisible == true, field.window === self,
              !field.isHiddenOrHasHiddenAncestor, field.canBecomeKeyView else { return nil }
        return field
    }
    override func selectKeyView(following view: NSView) {
        if let search = spaceSearch, !search.isHiddenOrHasHiddenAncestor, let address = addressInLoop {
            if view === search, makeFirstResponder(address) { return }
            if view === address { super.selectKeyView(following: search); return }
        }
        super.selectKeyView(following: view)
    }
    override func selectKeyView(preceding view: NSView) {
        if let search = spaceSearch, !search.isHiddenOrHasHiddenAncestor, let address = addressInLoop {
            if view === address, search.canBecomeKeyView, makeFirstResponder(search) { return }
            if view.previousValidKeyView === search, makeFirstResponder(address) { return }
        }
        super.selectKeyView(preceding: view)
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
final class ObserverWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSPopoverDelegate {
    let model: BrowserModel
    let window: NSWindow
    private let split = NSSplitViewController()
    private lazy var sidebar = ObserverSidebar(owner: self,
        select: { [weak self] in self?.selectSpace($0) },
        isRefreshing: { [weak self] in self?.refreshing == true },
        isCreatingTab: { [weak self] in self?.creatingTab == true },
        createTab: { [weak self] in self?.createTab(in: $0, opening: nil) },
        details: { [weak self] in self?.presentDetails(for: $0, relativeTo: $1, of: $2, preferredEdge: .maxX) },
        copyID: { [weak self] in self?.copySpaceID($0) },
        request: { [weak self] in self?.performObserverRequest($0) })
    private let page = ObserverPageContent(actions: .init(
        showViewport: #selector(showViewport), showBusyTab: #selector(showBusyTab),
        showPopup: #selector(showAnnouncedPopup), dismissPopup: #selector(dismissPopupNotice),
        startBrowsing: #selector(startBrowsing(_:)), recheckProxy: #selector(recheckSystemProxy),
        dismissNotice: #selector(dismissPageNotice), retryNavigation: #selector(retryFailedNavigation)))
    private let address = NSTextField()
    private var addressWidth: NSLayoutConstraint?
    private var editingAddress = false
    private var addressWasEdited = false
    private var addressDraft = ""
    private let reloadButton = NSButton()
    private let pageFind = PageFindBar()
    private weak var announcedPopup: Tab?
    private let handoff = NSButton(title: "交给 Agent", target: nil, action: nil)
    private var copiedTab: UUID?
    private var copyFeedbackExpiry: Task<Void, Never>?
    private var refreshing = false
    private var selectedSpace: UUID? {
        didSet {
            if selectedSpace != oldValue { infoPopover.close() }
        }
    }
    private var selectedTabs: [UUID: UUID] = [:]
    private weak var displayed: Tab?
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
    private var activityExpiry: Task<Void, Never>?
    private var creatingTab = false
    private lazy var tabStrip = ObserverTabStrip(owner: self,
        currentSpace: { [weak self] in self?.currentSpace },
        selectedID: { [weak self] in self?.selectedTabs[$0.record.id] },
        selectTab: { [weak self] in self?.selectTab(at: $0, in: $1) },
        request: { [weak self] in self?.performObserverRequest($0) },
        copyURL: { [weak self] url in
            guard let self, self.copyToPasteboard(url) else { return }
            self.showTransientMessage("已复制网址")
        },
        handoff: { [weak self] in self?.copyHandoffCommand(space: $0, tab: $1) })

    init(model: BrowserModel, socketPath: String) {
        self.model = model
        self.socketPath = socketPath
        selectionKey = "observer.selection.\(model.storagePath)"
        let observerWindow = ObserverKeyWindow(contentRect: NSRect(x: 120, y: 140, width: 1220, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window = observerWindow
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: String] {
            selectedSpace = saved["space"].flatMap(UUID.init(uuidString:))
            for (key, value) in saved {
                if let space = UUID(uuidString: key), let tab = UUID(uuidString: value) { selectedTabs[space] = tab }
            }
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "Agent WebKit"; window.titleVisibility = .hidden
        window.toolbarStyle = .unified; window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false; window.delegate = self
        split.splitView.dividerStyle = .thin
        sidebar.install(in: split, owner: self, performSpaceAction: #selector(performSpaceMenuAction(_:)),
                        prepareSpaceMenu: #selector(prepareSpaceMenu(_:)))
        page.install(in: split, owner: self, tabBar: tabStrip.tabBar, pageFind: pageFind)
        window.contentViewController = split
        NSLayoutConstraint.activate([
            sidebar.countBaseline.constraint(equalTo: page.statusBaseline)
        ])
        window.setContentSize(NSSize(width: 1220, height: 800))
        window.setFrameAutosaveName(selectionKey + ".frame")
        window.setFrameUsingName(selectionKey + ".frame")
        let toolbar = NSToolbar(identifier: "AgentWebKit.Observer.Toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        observerWindow.spaceSearch = sidebar.search; observerWindow.locationField = address
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
            let cell = AddressCell(textCell: "")
            cell.willEdit = { [weak self] in self?.beginAddressEditing() }
            address.cell = cell
            address.isEditable = true; address.isSelectable = true
            address.isBezeled = true; address.bezelStyle = .roundedBezel; address.focusRingType = .default
            address.delegate = self; address.target = self; address.action = #selector(openAddress(_:))
            address.font = .systemFont(ofSize: 13); address.lineBreakMode = .byTruncatingMiddle
            address.placeholderString = "输入网址"; cell.setAccessibilityLabel("页面地址")
            let field = NSStackView(views: [address, reloadButton])
            field.alignment = .centerY; field.spacing = 4
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载")
            reloadButton.target = self; reloadButton.action = #selector(reloadPage)
            reloadButton.isBordered = false; reloadButton.bezelStyle = .texturedRounded
            reloadButton.contentTintColor = .labelColor; reloadButton.toolTip = "重新加载（⌘R）"
            reloadButton.setAccessibilityLabel("重新加载")
            reloadButton.translatesAutoresizingMaskIntoConstraints = false
            let preferred = field.widthAnchor.constraint(equalToConstant: preferredAddressWidth)
            preferred.priority = .defaultHigh; preferred.isActive = true
            addressWidth = preferred
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
                field.heightAnchor.constraint(equalToConstant: 36),
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

    @objc func copyCurrentSpaceID() {
        if let id = currentSpace?.record.id { copySpaceID(id) }
    }
    private func copySpaceID(_ spaceID: UUID) {
        guard copyToPasteboard(spaceID.uuidString) else { return }
        showTransientMessage("已复制 Space ID")
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === sidebar.search { refresh() }
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
        page.setAddressHint(message)
        address.setAccessibilityHelp(message)
    }
    private func clearAddressHint() {
        page.setAddressHint(nil)
        address.setAccessibilityHelp(nil)
    }
    private func beginAddressEditing() {
        guard !editingAddress else { return }
        editingAddress = true
        addressWasEdited = displayed?.pendingAddressDraft != nil
        let url = displayed?.persistedURL
        address.stringValue = displayed?.pendingAddressDraft ?? (url == "about:blank" ? "" : url ?? "")
        address.alignment = .natural
        addressDraft = address.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === address else { return }
        finishAddressEditing()
    }
    private func finishAddressEditing() {
        guard editingAddress else { return }
        clearAddressHint()
        editingAddress = false
        updateStatus()
    }
    private func endAddressSession() {
        guard editingAddress else { return }
        if addressWasEdited { displayed?.pendingAddressDraft = addressDraft }
        window.endEditing(for: address)
        finishAddressEditing()
    }
    func windowDidResignKey(_ notification: Notification) { endAddressSession() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if control === sidebar.search, selector == #selector(NSResponder.insertNewline(_:)) {
            sidebar.chooseSearchResult(in: window)
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
        window.makeFirstResponder(nil); finishAddressEditing(); return true
    }
    private func selectSpace(_ space: Space) {
        selectedSpace = space.record.id
        transientMessage = nil; saveSelection(); refresh()
    }
    private func selectTab(at index: Int, in space: Space) {
        guard space.tabs.indices.contains(index) else { return }
        selectedTabs[space.record.id] = space.tabs[index].id
        transientMessage = nil; saveSelection(); refresh()
        tabStrip.scrollToTab(at: index)
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
        sidebar.updateFilter(spaces: model.spaces)
        if currentSpace == nil, selectedSpace != model.spaces.first?.record.id {
            selectedSpace = model.spaces.first?.record.id
            saveSelection()
        }
        window.title = currentSpace.map { "\($0.record.name) — Agent WebKit" } ?? "Agent WebKit"
        sidebar.refresh(model: model, selectedID: selectedSpace, currentSpace: currentSpace)
        activityExpiry?.cancel()
        page.prepareEmptyState(restoring: model.restoring, creatingTab: creatingTab, space: currentSpace, hasSpaces: !model.spaces.isEmpty)
        guard let space = currentSpace else {
            endAddressSession()
            displayed?.park(); displayed = nil
            page.showNoSpace(searching: !sidebar.search.stringValue.isEmpty)
            tabStrip.clear()
            updateStatus(); return
        }
        let selected = selectedTabs[space.record.id]
        let tab = space.tabs.first { $0.id == selected } ?? space.tabs.first
        if let tab, selected != tab.id {
            selectedTabs[space.record.id] = tab.id
            saveSelection()
        }
        let blank = page.showEmptyState(in: space, tab: tab, selected: selected)
        let now = ContinuousClock.now
        if let expiry = space.activity.values.compactMap(\.recentUntil).filter({ $0 > now }).min() {
            activityExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(until: expiry, clock: .continuous) }
                catch { return }
                self?.refresh()
            }
        }
        tabStrip.refresh(in: space, activeTab: tab)
        if displayed !== tab {
            // An unfinished address belongs to the tab where it was typed.
            pageActionError = nil
            clearAddressHint()
            endAddressSession()
            displayed?.park(); displayed = tab
            if let tab {
                tab.inputFocusConflict = { [weak self] in
                    guard let self else { return false }
                    return self.editingAddress || (self.window.isKeyWindow && (self.sidebar.search.currentEditor() != nil || self.pageFind.isEditingQuery))
                }
                tab.mount(in: page.host)
            }
        }
        tab?.webView.isHidden = blank
        // A view hidden for the blank state must become visible when parked in another Space.
        if blank { page.bringEmptyStateForward(over: tab) }
        updateStatus()
    }

    @objc func closeOtherTabs(_ sender: NSMenuItem) {
        guard let space = currentSpace, let tab = displayed else { return }
        tabStrip.closeOtherTabs(in: space, keeping: tab.id)
    }
    private func updateStatus() {
        let space = currentSpace; let tab = displayed
        pageFind.bind(to: tab?.persistedURL == "about:blank" ? nil : tab?.webView, document: tab?.navigationSequence)
        tab?.hasUnreadPopupNotice = false
        announcedPopup = tab.flatMap { opener in
            space?.tabs.last { $0.hasUnreadPopupNotice && $0.openerTabID == opener.id }
        }
        page.updatePopup(announcedPopup, tab: tab)
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
        page.updateDialogs(for: tab)
        let url = tab?.persistedURL == "about:blank" ? "" : tab?.persistedURL ?? ""
        if !editingAddress {
            let compact: String
            if var origin = URLComponents(string: url), let scheme = origin.scheme?.lowercased(),
               ["http", "https"].contains(scheme), origin.host != nil {
                origin.user = nil; origin.password = nil
                origin.path = ""; origin.query = nil; origin.fragment = nil
                if origin.port == (scheme == "https" ? 443 : 80) { origin.port = nil }
                compact = origin.string ?? url
            } else { compact = url }
            address.alignment = .center
            if address.stringValue != compact { address.stringValue = compact }
        }
        address.toolTip = tab?.persistedURL
        address.placeholderString = "输入网址"
        address.isEnabled = (tab != nil || model.spaces.isEmpty) && !model.restoring && !creatingTab
        let isLoading = tab?.webView.isLoading == true
        page.updateProgress(for: tab, loading: isLoading)
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
        if editingAddress, addressWasEdited, space?.busy == true { tab?.pendingAddressDraft = addressDraft }
        handoff.isEnabled = tab != nil
        handoff.title = copiedTab != nil && copiedTab == tab?.id ? "已复制 ✓" : "交给 Agent"
        handoff.setAccessibilityLabel(copiedTab != nil && copiedTab == tab?.id ? "已复制接管命令" : "交给 Agent，复制当前页面的接管命令")
        let networkError = space?.networkError
        let proxyState = proxyRecovery(networkError)
        if proxyState != .blocked || checkedBlockedProxySpace != selectedSpace { checkedBlockedProxySpace = nil }
        let recheckProxy = proxyState != .ready
        let networkPaused = recheckProxy || networkError != nil
        page.updateFooter(for: space, tab: tab, restoring: model.restoring, networkPaused: networkPaused,
                          editingAddress: editingAddress, transientMessage: transientMessage, loading: isLoading)
        if let notice = pageActionError, notice.tab != tab?.id || notice.navigation != tab?.navigationSequence ||
            (notice.clearsAfterLoad && tab?.navigationPending == false && tab?.webView.isLoading == false) {
            pageActionError = nil
        }
        page.updateNotice(for: space, tab: tab, networkError: networkError, actionMessage: pageActionError?.message,
                          proxyState: proxyState, checkedBlockedProxy: checkedBlockedProxySpace != nil, canReload: canReload)
        window.toolbar?.items.first { $0.itemIdentifier == .copyCommand }?.isEnabled = tab != nil
        window.toolbar?.items.first { $0.itemIdentifier == .details }?.isEnabled = space != nil
        window.toolbar?.items.first { $0.itemIdentifier == .downloads }?.isEnabled = space != nil
        window.toolbar?.items.first { $0.itemIdentifier == .newTab }?.isEnabled = canCreateTab
        window.toolbar?.items.first { $0.itemIdentifier == .back }?.isEnabled = canTraverse(back: true)
        window.toolbar?.items.first { $0.itemIdentifier == .forward }?.isEnabled = canTraverse(back: false)
    }
    private var canCreateTab: Bool {
        !model.restoring && !creatingTab && currentSpace?.busy != true && (sidebar.search.stringValue.isEmpty || sidebar.hasSelection)
    }
    private var canReload: Bool { displayed != nil && currentSpace?.busy == false && !model.restoring }
    private var canStopLoading: Bool {
        displayed?.webView.isLoading == true && !model.restoring && currentSpace?.busyOrigin != .agent
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
        let lastTab = currentSpace?.record.tabs.count == 1
        if menuItem.action == #selector(closeCurrentTab(_:)) { menuItem.title = lastTab ? "隐藏观察窗口" : "关闭当前标签页" }
        if menuItem.action == #selector(toggleSpaceSuspension(_:)) || menuItem.action == #selector(deleteCurrentSpace(_:)) {
            ObserverSidebar.bindSpaceAction(menuItem, space: currentSpace, delete: menuItem.action == #selector(deleteCurrentSpace(_:)))
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = split.splitViewItems.first?.isCollapsed == true ? "显示侧边栏" : "隐藏侧边栏"
        }
        guard window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else { return false }
        if let key = NSApp.keyWindow, key !== window, isMainMenuItem(menuItem) { return false }
        if menuItem.action == #selector(closeCurrentTab(_:)) {
            if lastTab { return window.isKeyWindow }
            guard window.isKeyWindow, let space = currentSpace, let tab = displayed else { return false }
            return !space.busy && space.tabs.count > 1 && (space.activity[tab.id]?.executing ?? 0) == 0
        }
        if menuItem.action == #selector(createSpace) { return !model.restoring }
        if menuItem.action == #selector(copyCommand) { return displayed != nil }
        if menuItem.action == #selector(closeOtherTabs(_:)) {
            guard let space = currentSpace, let tab = displayed else { return false }
            return tabStrip.canCloseOthers(in: space, keeping: tab.id)
        }
        if menuItem.action == #selector(showDetails(_:)) || menuItem.action == #selector(showDownloads) || menuItem.action == #selector(copyCurrentSpaceID) { return currentSpace != nil }
        if menuItem.action == #selector(toggleSpaceSuspension(_:)) || menuItem.action == #selector(deleteCurrentSpace(_:)) { return sidebar.actionsEnabled }
        if menuItem.action == #selector(reloadPage) { return canReload }
        if menuItem.action == #selector(stopLoadingPage) { return canStopLoading }
        if menuItem.action == #selector(zoomIn(_:)) { return canZoom && (displayed?.webView.pageZoom ?? 1) < 3.0 }
        if menuItem.action == #selector(zoomOut(_:)) { return canZoom && (displayed?.webView.pageZoom ?? 1) > 0.5 }
        if menuItem.action == #selector(resetZoom(_:)) { return canZoom && abs((displayed?.webView.pageZoom ?? 1) - 1.0) > 0.01 }
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
        if window.makeFirstResponder(address) { address.currentEditor()?.selectAll(nil) }
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
                window.presentObserverFailure(response); return
            }
            // Target the IDs acknowledged by creation, even if the observer selection changed.
            let createdSpace = spaceID ?? (result["id"] as? String).flatMap(UUID.init(uuidString:))
            let tabs = result["tabs"] as? [[String: Any]]
            let createdTab = (result["tabId"] as? String ?? tabs?.first?["tabId"] as? String).flatMap(UUID.init(uuidString:))
            guard let createdSpace, let createdTab else { refresh(); return }
            selectedSpace = createdSpace; selectedTabs[createdSpace] = createdTab
            sidebar.search.stringValue = ""; transientMessage = nil; saveSelection()
            refresh()
            tabStrip.scrollToLastTab()
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
    private var canZoom: Bool {
        guard let space = currentSpace, displayed != nil, !space.busy, !model.restoring, window.attachedSheet == nil else { return false }
        return !space.activity.values.contains { $0.executing > 0 }
    }
    @objc func zoomIn(_ sender: Any?) { adjustZoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { adjustZoom(by: -0.1) }
    @objc func resetZoom(_ sender: Any?) { if canZoom { displayed?.webView.pageZoom = 1.0 } }
    private func adjustZoom(by delta: CGFloat) {
        guard canZoom, let webView = displayed?.webView else { return }
        let next = ((webView.pageZoom + delta) * 10).rounded() / 10
        webView.pageZoom = min(3.0, max(0.5, next))
    }
    @objc func selectTabShortcut(_ sender: NSMenuItem) {
        guard let space = currentSpace, space.tabs.count > 1 else { return }
        let index = sender.tag == 9 ? space.tabs.count - 1 : sender.tag - 1
        selectTab(at: index, in: space)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard window.isKeyWindow, window.attachedSheet == nil, let space = currentSpace else { return }
        if space.record.tabs.count == 1 { hideWindow(sender); return }
        guard let tab = displayed, !space.busy, (space.activity[tab.id]?.executing ?? 0) == 0 else { return }
        closeTab(spaceID: space.record.id, tabID: tab.id)
    }
    private func closeTab(spaceID: UUID, tabID: UUID) {
        performObserverRequest(Request(command: "tab.close", args: [], options: ["space": spaceID.uuidString, "tab": tabID.uuidString]))
    }
    @objc func createSpace() {
        guard !model.restoring, window.attachedSheet == nil else { return }
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
                self.sidebar.search.stringValue = ""
                self.selectedSpace = id
                self.transientMessage = nil
                self.saveSelection()
                self.refresh()
                sheet.finishSubmission()
            }
        }
        split.presentAsSheet(sheet)
    }
    @objc func toggleSpaceSuspension(_ sender: NSMenuItem) { performSpaceMenuAction(sender) }
    @objc func deleteCurrentSpace(_ sender: NSMenuItem) { performSpaceMenuAction(sender) }
    @objc private func prepareSpaceMenu(_ notification: Notification) {
        guard let space = currentSpace else { return }
        sidebar.prepareActions(for: space)
    }
    @objc private func performSpaceMenuAction(_ item: NSMenuItem) {
        guard window.attachedSheet == nil, sidebar.actionsEnabled, let request = item.representedObject as? Request,
              let space = currentSpace, request.args.first == space.record.id.uuidString else { return }
        if request.command == "space.resume" && !space.suspended || request.command == "space.suspend" && space.suspended { return }
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
                    title = "关闭“\(ObserverTabStrip.title(of: target))”？"
                    let location = URL(string: target.persistedURL)?.host ?? target.persistedURL
                    detail = "\(space.record.name) · \(location)\n\(detail)"
                }
                let destructive = ["tab.close", "space.delete"].contains(request.command)
                let critical = request.command == "space.delete"
                window.confirmObserverAction(title, detail: detail, action: action, destructive: destructive, critical: critical) {
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
                } else { window.presentObserverFailure(response) }
                return
            }
            transientExpiry?.cancel(); transientExpiry = nil
            if request.command == "space.delete" {
                transientMessage = result["cleanupPending"] as? Bool == true ? "Space 已移除，数据容器仍待清理。" : "Space 及网站数据已删除。"
            } else { transientMessage = nil }
            refresh()
        }
    }
    @objc private func dismissPageNotice() {
        if pageActionError != nil { pageActionError = nil }
        else { displayed?.observerDismissedRejection = true }
        updateStatus()
    }
    private func proxyRecovery(_ networkError: BrowserError?) -> ObserverPageContent.ProxyRecovery {
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
    @objc func copyCommand() {
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
    private func showPopover(_ popover: NSPopover, toolbarItemID: NSToolbarItem.Identifier) {
        if let toolbar = window.toolbar, toolbar.isVisible,
           let item = toolbar.visibleItems?.first(where: { $0.itemIdentifier == toolbarItemID }) {
            popover.show(relativeTo: item)
            return
        }
        if split.splitViewItems.first?.isCollapsed == false, sidebar.showPopover(popover) { return }
        let anchor = NSRect(x: max(0, page.host.bounds.maxX - 1), y: max(0, page.host.bounds.maxY - 1), width: 1, height: 1)
        popover.show(relativeTo: anchor, of: page.host, preferredEdge: .maxY)
    }
    @objc func showDetails(_ sender: Any?) {
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
    @objc func showDownloads() {
        guard let space = currentSpace else { return }
        if downloadsPopover.isShown { downloadsPopover.close(); return }
        infoPopover.close()
        downloadsSpace = space
        downloadsPopover.behavior = .transient
        downloadsPopover.delegate = self
        let content = SpaceDownloadsView(space: space, refreshToken: downloadsRefreshToken) { [weak self, weak space] message in
            guard let self, let space, self.currentSpace === space else { return }
            self.downloadsPopover.close()
            self.window.presentObserverFailure(["error": ["message": message]])
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
        window.makeFirstResponder(sidebar.search)
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }
    private func cycleTab(_ delta: Int) {
        guard let space = currentSpace, let index = space.tabs.firstIndex(where: { $0 === displayed }) else { return }
        selectedTabs[space.record.id] = space.tabs[(index + delta + space.tabs.count) % space.tabs.count].id
        saveSelection(); refresh()
        if let index = space.tabs.firstIndex(where: { $0 === displayed }) {
            tabStrip.scrollToTab(at: index)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { saveSelection(); sender.orderOut(nil); return false }
}
