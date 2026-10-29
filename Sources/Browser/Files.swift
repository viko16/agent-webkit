import AppKit
import WebKit

@MainActor
final class DownloadStore: NSObject, WKDownloadDelegate {
    private struct Entry {
        let id: String
        var download: WKDownload?
        var status = "running"
        var path: URL?
        var filename = ""
        var error: String?
        var timer: DispatchWorkItem?
    }
    var directory: URL?
    private var entries: [Entry] = []
    private var stopped = false
    var hasActive: Bool { entries.contains { $0.status == "running" } }

    func begin(_ download: WKDownload) {
        guard !stopped else {
            download.cancel(nil); return
        }
        if entries.count == 64, let index = entries.firstIndex(where: { $0.status != "running" }) { entries.remove(at: index) }
        let id = UUID().uuidString
        guard entries.filter({ $0.status == "running" }).count < 8 else {
            entries.append(Entry(id: id, status: "failed", error: "download_capacity"))
            download.cancel(nil); return
        }
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { try? self?.cancel(id, reason: "download_expired") } }
        entries.append(Entry(id: id, download: download, timer: timer))
        download.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timer)
    }

    private func index(_ download: WKDownload) -> Int? { entries.firstIndex { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let index = index(download), entries[index].status == "running", let directory else { completionHandler(nil); return }
        do {
            let folder = directory.appendingPathComponent(entries[index].id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let leaf = String((suggestedFilename as NSString).lastPathComponent.prefix(128))
            let name = leaf.isEmpty || [".", "..", "/"].contains(leaf) ? "download" : leaf
            let path = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: path.path) else { throw BrowserError("download_failed", "下载路径已存在") }
            entries[index].path = path; entries[index].filename = name
            completionHandler(path)
        } catch {
            finish(index, status: "failed", error: error.localizedDescription)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = index(download), entries[index].status == "running" else { return }
        finish(index, status: "completed")
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let index = index(download), entries[index].status == "running" else { return }
        finish(index, status: "failed", error: error.localizedDescription)
    }
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use the originating Tab's existing per-Space trust policy.
        if let tab = download.webView?.navigationDelegate as? Tab, !tab.closed {
            tab.authenticate(challenge, affectsPage: false, completionHandler: completionHandler)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        decisionHandler(["http", "https"].contains(scheme ?? "") ? .allow : .cancel)
    }

    private func finish(_ index: Int, status: String, error: String? = nil) {
        entries[index].status = status; entries[index].error = error
        entries[index].timer?.cancel(); entries[index].timer = nil
        entries[index].download = nil
        // Completed downloads are user files; incomplete data is never reported as a result.
        if status != "completed", let path = entries[index].path {
            try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
        }
    }
    func cancel(_ id: String, reason: String = "download_cancelled") throws {
        guard let index = entries.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { throw BrowserError("download_not_found", "目标 Tab 中没有该下载") }
        guard entries[index].status == "running" else { return }
        let download = entries[index].download
        let path = entries[index].path
        finish(index, status: "cancelled", error: reason)
        download?.cancel { _ in
            guard let path else { return }
            try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
        }
    }
    func stop() {
        stopped = true
        for id in entries.filter({ $0.status == "running" }).map(\.id) { try? cancel(id) }
    }
    func item(_ id: String) throws -> [String: Any] {
        guard let entry = entries.first(where: { $0.id.lowercased() == id.lowercased() }) else { throw BrowserError("download_not_found", "目标 Tab 中没有该下载") }
        return summary(entry)
    }
    private func summary(_ entry: Entry) -> [String: Any] {
        ["id": entry.id, "status": entry.status, "filename": entry.filename,
         "path": entry.status == "completed" ? entry.path?.path as Any? ?? NSNull() : NSNull(),
         "bytesReceived": entry.download?.progress.completedUnitCount ?? (entry.path.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0),
         "error": entry.error as Any? ?? NSNull(), "requiresForeground": false]
    }
    func snapshot() -> [String: Any] { ["downloads": entries.map(summary), "limit": 64, "activeLimit": 8, "lifetimeMs": 300000] }
}

@MainActor
final class FileChooser {
    private var panel: NSOpenPanel?
    private var reply: (([URL]?) -> Void)?
    private(set) var state: [String: Any] = ["status": "idle", "requiresForeground": true]

    func present(webView: WKWebView, parameters: WKOpenPanelParameters, completion: @escaping ([URL]?) -> Void) {
        guard panel == nil else { completion(nil); return }
        guard NSApp.isActive, let window = webView.window, window.isKeyWindow else {
            state = ["status": "requires_foreground", "requiresForeground": true]
            completion(nil); return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        self.panel = panel; reply = completion
        state = ["status": "pending", "requiresForeground": true]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, self.panel === panel else { return }
            self.finish(result == .OK ? panel.urls : nil)
        }
    }
    private func finish(_ urls: [URL]?) {
        let completion = reply; reply = nil; panel = nil
        state = ["status": urls == nil ? "cancelled" : "selected", "requiresForeground": true]
        completion?(urls)
    }
    func stop() {
        let panel = panel
        finish(nil)
        panel?.cancel(nil)
    }
}
