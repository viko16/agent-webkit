// Standalone public-API experiment, never linked into the browser product.
import AppKit
import WebKit

@MainActor
final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var view: WKWebView!
    var panel: NSPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        view.navigationDelegate = self
        view.loadHTMLString("<style>html,body{margin:0}div{height:700px}#a{background:red}#b{background:lime}#c{background:blue}</style><div id=a></div><div id=b></div><div id=c></div>", baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("{\"error\":\"probe_timeout\"}"); exit(2) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1000, height: 2100)
        view.takeSnapshot(with: configuration) { image, error in
            do {
                if let error { throw error }
                guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "probe", code: 1) }
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                print("{\"width\":\(bitmap.pixelsWide),\"height\":\(bitmap.pixelsHigh),\"viewHeight\":700,\"requestedHeight\":2100}")
                exit(0)
            } catch {
                let data = try! JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
                print(String(decoding: data, as: UTF8.self)); exit(1)
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = Probe(); app.delegate = probe
    withExtendedLifetime(probe) { app.run() }
}
