import AppKit

private final class CenteredTabCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 27, dy: 0), in: controlView)
    }
}

final class PageTabButton: NSButton {
    override class var cellClass: AnyClass? {
        get { CenteredTabCell.self }
        set {}
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (superview as? PageTabView)?.menu(for: event) ?? super.menu(for: event)
    }
}

final class PageTabView: NSView {
    let tabID: UUID
    let titleButton: NSButton
    let closeButton: NSButton
    var onMiddleClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var middleMouseDown = false
    private var isSelected: Bool

    init(tabID: UUID, titleButton: NSButton, closeButton: NSButton) {
        self.tabID = tabID
        self.titleButton = titleButton
        self.closeButton = closeButton
        isSelected = titleButton.state == .on
        super.init(frame: .zero)
        for button in [titleButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.imageHugsTitle = true
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.bezelStyle = .accessoryBarAction
        NSLayoutConstraint.activate([
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleButton.topAnchor.constraint(equalTo: topAnchor),
            titleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 30)
        ])
        syncAccessibilityActions()
        updateCloseButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selected: Bool, canClose: Bool) {
        isSelected = selected
        titleButton.state = selected ? .on : .off
        closeButton.isEnabled = canClose
        syncAccessibilityActions()
        updateCloseButton()
    }

    private func syncAccessibilityActions() {
        if closeButton.isEnabled {
            let action = NSAccessibilityCustomAction(name: "关闭标签页") { [weak closeButton] in
                guard let closeButton, closeButton.isEnabled else { return false }
                closeButton.performClick(nil)
                return true
            }
            titleButton.setAccessibilityCustomActions([action])
        } else {
            titleButton.setAccessibilityCustomActions([])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
        if let window {
            hovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            updateCloseButton()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateCloseButton() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateCloseButton() }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, closeButton.isEnabled {
            middleMouseDown = true
            return
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let wasDown = middleMouseDown
            middleMouseDown = false
            let location = convert(event.locationInWindow, from: nil)
            if wasDown, closeButton.isEnabled, bounds.contains(location) {
                onMiddleClick?()
                return
            }
        }
        super.otherMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    private func updateCloseButton() {
        closeButton.isHidden = !closeButton.isEnabled || !(isSelected || hovered)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let surface = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if isSelected {
            NSColor.controlBackgroundColor.setFill(); surface.fill()
            NSColor.separatorColor.setStroke(); surface.lineWidth = 1; surface.stroke()
        } else if hovered {
            NSColor.quaternaryLabelColor.setFill(); surface.fill()
        }
    }
}
