import AppKit

final class ChromeBarView: NSStackView {
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
