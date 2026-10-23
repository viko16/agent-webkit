import AppKit

@MainActor
final class ObserverWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let model: BrowserModel
    let window: NSWindow
    let table = NSTableView()
    let tabPicker = NSPopUpButton()
    let host = NSView()
    let label = NSTextField(labelWithString: "通过 CLI 创建 Space")
    var selectedSpace: UUID?
    var selectedTab: UUID?
    weak var displayed: Tab?

    init(model: BrowserModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 1220, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Agent WebKit"
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 760))
        window.contentView = root
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 760))
        scroll.autoresizingMask = [.height]; scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("space")); column.title = "Spaces"; column.width = 214
        table.addTableColumn(column); table.rowHeight = 46; table.delegate = self; table.dataSource = self
        scroll.documentView = table; root.addSubview(scroll)
        tabPicker.frame = NSRect(x: 234, y: 718, width: 970, height: 28)
        tabPicker.autoresizingMask = [.width,.minYMargin]; tabPicker.target = self; tabPicker.action = #selector(pickTab)
        root.addSubview(tabPicker)
        host.frame = NSRect(x: 220, y: 0, width: 1000, height: 700); host.autoresizingMask = [.width,.height]
        root.addSubview(host)
        label.frame = NSRect(x: 250, y: 360, width: 600, height: 40); root.addSubview(label)
        model.changed = { [weak self] in self?.refresh() }
        model.willRemove = { [weak self] space in
            guard let self else { return }
            if space.tabs.contains(where: { $0 === self.displayed }) { self.displayed?.park(); self.displayed = nil }
        }
        refresh()
        // orderBack does not make the window key and never activates the application.
        window.orderBack(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.spaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let space = model.spaces[row]
        let text = NSTextField(labelWithString: "\(space.record.name)\n\(space.record.proxy)")
        text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingTail
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard model.spaces.indices.contains(table.selectedRow) else { return }
        selectedSpace = model.spaces[table.selectedRow].record.id; selectedTab = nil; refresh()
    }
    @objc func pickTab() {
        guard let space = model.spaces.first(where: { $0.record.id == selectedSpace }), space.tabs.indices.contains(tabPicker.indexOfSelectedItem) else { return }
        selectedTab = space.tabs[tabPicker.indexOfSelectedItem].id; refresh()
    }
    func refresh() {
        table.reloadData()
        if !model.spaces.contains(where: { $0.record.id == selectedSpace }) { selectedSpace = model.spaces.first?.record.id; selectedTab = nil }
        guard let space = model.spaces.first(where: { $0.record.id == selectedSpace }) else {
            displayed?.park(); displayed = nil; tabPicker.removeAllItems(); label.isHidden = false; return
        }
        label.isHidden = true
        if !space.tabs.contains(where: { $0.id == selectedTab }) { selectedTab = space.record.defaultTab }
        tabPicker.removeAllItems()
        tabPicker.addItems(withTitles: space.tabs.map { "\($0.id.uuidString.prefix(8)) · \($0.webView.title ?? $0.webView.url?.absoluteString ?? "about:blank")" })
        guard let tab = space.tabs.first(where: { $0.id == selectedTab }) else { return }
        tabPicker.selectItem(at: space.tabs.firstIndex(where: { $0 === tab })!)
        guard displayed !== tab else { return }
        displayed?.park(); displayed = tab
        tab.webView.removeFromSuperview(); host.addSubview(tab.webView)
        tab.webView.frame = host.bounds; tab.webView.autoresizingMask = [.width,.height]
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}
