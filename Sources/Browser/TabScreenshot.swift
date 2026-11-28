import AppKit

@MainActor
enum TabScreenshot {
    private static func fullPageBitmap(in tab: Tab, token: String,
                                       snapshotBitmap: (CGRect) async throws -> NSBitmapImageRep)
        async throws -> (bitmap: NSBitmapImageRep, range: [String: Any], tiles: Int) {
        let literal = try quoteJS(token)
        guard let info = try await tab.runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
              let width = info["width"], let height = info["height"], let viewportWidth = info["viewportWidth"], let viewportHeight = info["viewportHeight"],
              [width,height,viewportWidth,viewportHeight].allSatisfy({ $0.isFinite && $0 > 0 }) else { throw BrowserError("snapshot_failed", "无效整页范围") }
        guard width <= viewportWidth else { throw BrowserError("unsupported_screenshot_geometry", "整页截图暂不支持横向溢出；请截取元素或视口") }
        let scaleX = tab.webView.bounds.width / viewportWidth, scaleY = tab.webView.bounds.height / viewportHeight
        let backing = tab.webView.window?.backingScaleFactor ?? 2
        let pixelScale = Double(max(scaleX, scaleY) * backing)
        guard height <= 16000, width * height * pixelScale * pixelScale <= 32_000_000 else {
            throw BrowserError("screenshot_too_large", "整页截图最多16000 CSS px高、预计3200万像素")
        }
        var canvas: CGContext?
        var outputWidth = 0, outputHeight = 0, tiles = 0
        var pixelScaleY = 0.0
        for y in stride(from: 0.0, to: height, by: viewportHeight) {
            _ = try await tab.runJS("window.__agentWebKit.scrollScreenshot(\(literal),\(min(y, max(0, height - viewportHeight))))", world: DOM.world)
            try await Task.sleep(nanoseconds: 50_000_000)
            guard let state = try await tab.runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
                  state["width"] == width, state["height"] == height, state["viewportWidth"] == viewportWidth, state["viewportHeight"] == viewportHeight,
                  let actualY = state["y"], let actualX = state["x"], abs(actualX) < 1 else {
                throw BrowserError("screenshot_changed", "分块期间页面尺寸、文档或视口改变；未写成功文件")
            }
            let tileHeight = min(viewportHeight, height - y), offset = y - actualY
            guard offset >= 0, offset + tileHeight <= viewportHeight else {
                throw BrowserError("unsupported_screenshot_geometry", "页面滚动吸附或脚本阻止了目标分块定位")
            }
            let tile = try await snapshotBitmap(CGRect(x: 0, y: max(0, offset) * scaleY, width: width * scaleX, height: tileHeight * scaleY))
            if canvas == nil {
                outputWidth = tile.pixelsWide; pixelScaleY = Double(tile.pixelsHigh) / tileHeight
                outputHeight = Int((height * pixelScaleY).rounded())
                guard Double(outputWidth) * Double(outputHeight) <= 32_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw BrowserError("screenshot_too_large", "整页像素范围超限或无法分配画布")
                }
                canvas = context
            }
            guard tile.pixelsWide == outputWidth, abs(Double(tile.pixelsHigh) - tileHeight * pixelScaleY) <= 1,
                  let image = tile.cgImage else { throw BrowserError("screenshot_changed", "分块像素比例改变") }
            let start = Int((y * pixelScaleY).rounded()), end = Int(((y + tileHeight) * pixelScaleY).rounded())
            canvas!.draw(image, in: CGRect(x: 0, y: outputHeight - end, width: outputWidth, height: end - start))
            tiles += 1
        }
        guard let final = try await tab.runJS("window.__agentWebKit.pageScreenshotBounds(\(literal))", world: DOM.world) as? [String: Double],
              final["width"] == width, final["height"] == height,
              final["viewportWidth"] == viewportWidth, final["viewportHeight"] == viewportHeight else {
            throw BrowserError("screenshot_changed", "最后分块完成后页面范围改变；未写成功文件")
        }
        guard let image = canvas?.makeImage() else { throw BrowserError("snapshot_failed", "没有生成整页图像") }
        return (NSBitmapImageRep(cgImage: image), ["x": 0, "y": 0, "width": width, "height": height, "coordinateSpace": "document-css"], tiles)
    }

    static func capture(in tab: Tab, path: String, element: String?, fullPage: Bool,
                        snapshotBitmap: (CGRect) async throws -> NSBitmapImageRep,
                        sameDocument: () -> Bool) async throws -> [String: Any] {
        let viewBounds = tab.webView.bounds
        let sequence = tab.navigationSequence
        func requireUnchangedGeometry() throws {
            guard tab.webView.bounds == viewBounds, tab.navigationSequence == sequence, sameDocument() else {
                throw BrowserError("screenshot_changed", "截图期间文档或 WebView 尺寸改变；未写成功文件")
            }
        }
        let viewport = try await tab.cssViewport()
        try requireUnchangedGeometry()
        let cssWidth = viewport.width, cssHeight = viewport.height
        var rect = viewBounds
        var token: String?
        var tiles = 1
        var range: [String: Any] = ["x": 0, "y": 0, "width": viewBounds.width, "height": viewBounds.height, "coordinateSpace": "view-points"]
        func restore() async throws {
            guard let current = token else { return }
            token = nil
            let previousDeadline = tab.deadline
            tab.deadline = monotonicNow() + 1_000_000_000
            defer { tab.deadline = previousDeadline }
            guard try await tab.runJS("window.__agentWebKit.restoreScreenshot(\(try quoteJS(current)))", world: DOM.world) as? Bool == true else {
                throw BrowserError("screenshot_changed", "截图期间页面改变，未能还原全部滚动位置")
            }
        }
        do {
            var bitmap: NSBitmapImageRep
            if fullPage {
                guard let current = try await tab.runJS("window.__agentWebKit.prepareScreenshot('html')", world: DOM.world) as? String else {
                    throw BrowserError("snapshot_failed", "无法准备整页截图")
                }
                token = current
                let result = try await fullPageBitmap(in: tab, token: current, snapshotBitmap: snapshotBitmap)
                bitmap = result.bitmap; range = result.range; tiles = result.tiles
            } else {
                if let element {
                    guard let current = try await tab.runJS("window.__agentWebKit.prepareScreenshot(\(try quoteJS(element)))", world: DOM.world) as? String else {
                        throw BrowserError("snapshot_failed", "无法准备元素截图")
                    }
                    token = current
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard let bounds = try await tab.runJS("window.__agentWebKit.screenshotBounds(\(try quoteJS(current)))", world: DOM.world) as? [String: Any],
                          let x = bounds["x"] as? Double, let y = bounds["y"] as? Double,
                          let width = bounds["width"] as? Double, let height = bounds["height"] as? Double,
                          let viewportWidth = bounds["viewportWidth"] as? Double, let viewportHeight = bounds["viewportHeight"] as? Double,
                          viewportWidth > 0, viewportHeight > 0 else { throw BrowserError("snapshot_failed", "无效元素截图范围") }
                    guard viewportWidth == cssWidth, viewportHeight == cssHeight else {
                        throw BrowserError("screenshot_changed", "截图期间 CSS 视口改变；未写成功文件")
                    }
                    let scaleX = viewBounds.width / viewportWidth, scaleY = viewBounds.height / viewportHeight
                    rect = CGRect(x: x * scaleX, y: y * scaleY, width: width * scaleX, height: height * scaleY).intersection(viewBounds)
                    guard !rect.isEmpty else { throw BrowserError("element_not_actionable", "元素完全位于可截图范围之外") }
                    range = ["x": x, "y": y, "width": width, "height": height, "coordinateSpace": "main-viewport-css", "clipped": bounds["clipped"] ?? false]
                }
                try requireUnchangedGeometry()
                bitmap = try await snapshotBitmap(rect)
            }
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw BrowserError("png_failed", "无法编码 PNG")
            }
            try await restore()
            guard try await tab.cssViewport() == viewport else {
                throw BrowserError("screenshot_changed", "截图期间 CSS 视口改变；未写成功文件")
            }
            try requireUnchangedGeometry()
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
            let capturedWidth = fullPage ? range["width"] as? Double ?? cssWidth : cssWidth * rect.width / viewBounds.width
            let capturedHeight = fullPage ? range["height"] as? Double ?? cssHeight : cssHeight * rect.height / viewBounds.height
            return ["path": url.path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "requiresForeground": false,
                    "cssViewport": ["width": cssWidth, "height": cssHeight, "devicePixelRatio": viewport.devicePixelRatio],
                    "pixelsPerCssPixel": ["x": Double(bitmap.pixelsWide) / capturedWidth, "y": Double(bitmap.pixelsHigh) / capturedHeight],
                    "mode": fullPage ? "full-page" : element == nil ? "viewport" : "element", "range": range, "scrollRestored": true,
                    "tiles": tiles, "captureConsistency": fullPage ? "best-effort" : "single-snapshot",
                    "limitations": fullPage ? ["Fixed/sticky content can repeat across tiles", "Lazy and virtualized content is captured only as rendered; dimensions must remain stable", "Nested scroll containers are not expanded; dynamic pixels are not atomic across tiles"] : []]
        } catch let originalError {
            do { try await restore() }
            catch { throw BrowserError((originalError as? BrowserError)?.code ?? "snapshot_failed", "\(originalError.localizedDescription)；滚动还原未完成：\(error.localizedDescription)") }
            throw originalError
        }
    }
}
