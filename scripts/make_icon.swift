import AppKit

// Generate the app's own vector artwork at every macOS icon size, without dependencies.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 192, yRadius: 192)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
        NSColor.systemBlue.setFill(); background.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.30, blue: 0.82, alpha: 1),
                   ending: NSColor(srgbRed: 0.23, green: 0.72, blue: 0.94, alpha: 1))!.draw(in: background, angle: 65)
        for (rect, alpha) in [(NSRect(x: 334, y: 358, width: 482, height: 440), 0.35),
                              (NSRect(x: 260, y: 292, width: 482, height: 440), 0.65),
                              (NSRect(x: 186, y: 226, width: 482, height: 440), 1.0)] {
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 62, yRadius: 62).fill()
        }
        NSColor(srgbRed: 0.16, green: 0.43, blue: 0.86, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 290, y: 304, width: 274, height: 274)); ring.lineWidth = 18; ring.stroke()
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: 496, y: 516)); needle.line(to: NSPoint(x: 458, y: 414))
        needle.line(to: NSPoint(x: 356, y: 376)); needle.line(to: NSPoint(x: 394, y: 478)); needle.close()
        NSColor(srgbRed: 0.16, green: 0.43, blue: 0.86, alpha: 1).setFill(); needle.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
