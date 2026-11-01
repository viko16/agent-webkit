import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor
extension Tab {
    func upload(target: String, paths: [String]) async throws -> Any {
        var remaining = 4 * 1024 * 1024
        var files: [[String: Any]] = []
        for path in paths {
            guard path.hasPrefix("/") else { throw BrowserError("invalid_arguments", "上传必须给出本机绝对文件路径") }
            let url = URL(fileURLWithPath: path)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: path) else { throw BrowserError("file_unreadable", "上传路径不是可读普通文件") }
                guard (values.fileSize ?? Int.max) <= remaining else { throw BrowserError("upload_too_large", "每次上传总大小最多 4 MiB") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: remaining + 1) ?? Data()
                guard data.count <= remaining else { throw BrowserError("upload_too_large", "每次上传总大小最多 4 MiB") }
                remaining -= data.count
                files.append(["name": url.lastPathComponent, "data": data.base64EncodedString(),
                              "type": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                              "modified": (values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000])
            } catch let error as BrowserError { throw error }
            catch { throw BrowserError("file_unreadable", error.localizedDescription) }
        }
        let payload = String(decoding: try jsonData(files), as: UTF8.self)
        return try await runJS("""
        (()=>{
          const el=window.__agentWebKit.resolve(\(try quoteJS(target)));
          if(el.localName!=='input'||el.type!=='file') throw new Error('unsupported_upload_target');
          if(el.matches(':disabled')||el.getAttribute('aria-disabled')==='true') throw new Error('element_not_actionable');
          const files=\(payload);
          if(files.length>1&&!el.multiple) throw new Error('upload_multiple_not_allowed');
          const realm=el.ownerDocument.defaultView;
          if(typeof realm.DataTransfer!=='function'||typeof realm.File!=='function') throw new Error('upload_unavailable');
          const transfer=new realm.DataTransfer();
          for(const file of files){
            const raw=atob(file.data), bytes=new Uint8Array(raw.length);
            for(let i=0;i<raw.length;i++) bytes[i]=raw.charCodeAt(i);
            transfer.items.add(new realm.File([bytes],file.name,{type:file.type,lastModified:file.modified}));
          }
          el.files=transfer.files;
          if(el.files.length!==files.length) throw new Error('upload_unavailable');
          el.dispatchEvent(new realm.Event('input',{bubbles:true,composed:true}));
          el.dispatchEvent(new realm.Event('change',{bubbles:true,composed:true}));
          return {method:'dom-data-transfer',nativeVerified:false,requiresForeground:false,businessOutcomeVerified:false,
                  files:files.map(f=>({name:f.name,size:atob(f.data).length,type:f.type}))};
        })()
        """, world: DOM.world)
    }
}

private actor DownloadBudget {
    struct Usage: Sendable {
        var total: Int64 = 0
        var spaces: [String: Int64] = [:]
        var files: [String: Int64] = [:]
        var free: Int64 = 0
    }
    static let shared = DownloadBudget()
    private var cached: [String: (time: UInt64, usage: Usage)] = [:]
    private var inFlight: [String: Task<Usage, Error>] = [:]

    func usage(_ root: URL, refresh: Bool = false) async throws -> Usage {
        let root = root.resolvingSymlinksInPath()
        // A transfer may finish while a shared scan is already returning older
        // file sizes. Final validation must observe a scan started after finish.
        if refresh { return try await Task.detached(priority: .utility) { try Self.scan(root) }.value }
        let key = root.path
        if let pending = inFlight[key] { return try await pending.value }
        if let cached = cached[key], milliseconds(from: cached.time) < 100 { return cached.usage }
        let task = Task.detached(priority: .utility) { try Self.scan(root) }
        inFlight[key] = task
        do {
            let result = try await task.value
            cached[key] = (monotonicNow(), result); inFlight[key] = nil
            return result
        } catch { inFlight[key] = nil; throw error }
    }

    private static func scan(_ root: URL) throws -> Usage {
        let manager = FileManager.default
        let attributes = try manager.attributesOfFileSystem(forPath: root.deletingLastPathComponent().path)
        guard let free = attributes[.systemFreeSize] as? NSNumber else { throw BrowserError("download_budget_unavailable", "无法读取磁盘剩余空间") }
        var result = Usage(free: free.int64Value)
        guard manager.fileExists(atPath: root.path) else { return result }
        var failure: Error?
        func disappeared(_ error: Error) -> Bool {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in
            if disappeared(error) { return true }
            failure = error; return false
        }) else {
            throw BrowserError("download_budget_unavailable", "无法读取下载目录占用")
        }
        let componentCount = root.pathComponents.count
        func add(_ left: Int64, _ right: Int64) -> Int64 {
            let (sum, overflow) = left.addingReportingOverflow(right)
            return overflow ? Int64.max : sum
        }
        for case let url as URL in iterator {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
            catch { if disappeared(error) { continue }; throw error }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            result.total = add(result.total, bytes)
            let canonical = url.resolvingSymlinksInPath()
            result.files[canonical.path] = bytes
            let components = canonical.pathComponents
            if components.count > componentCount + 1 {
                let space = components[componentCount]
                result.spaces[space] = add(result.spaces[space] ?? 0, bytes)
            }
        }
        if let failure { throw failure }
        return result
    }
}

@MainActor
final class DownloadStore: NSObject, WKDownloadDelegate {
    private struct Entry {
        let id: String
        var download: WKDownload?
        var status = "running"
        var path: URL?
        var filename = ""
        var error: String?
        var cleanupError: String?
        var bytesReceived: Int64 = 0
        var cancelling = false
        var finishing = false
        var timer: DispatchWorkItem?
    }
    private struct Limits {
        let file: Int64
        let space: Int64
        let total: Int64
        let free: Int64
        init() {
            let environment = ProcessInfo.processInfo.environment
            func value(_ name: String, _ fallback: Int64, zeroAllowed: Bool = false) -> Int64 {
                guard let raw = environment["BROWSER_DOWNLOAD_" + name], let value = Int64(raw), value >= (zeroAllowed ? 0 : 1) else { return fallback }
                return value
            }
            file = value("MAX_FILE_BYTES", 512 * 1024 * 1024)
            space = value("MAX_SPACE_BYTES", 2 * 1024 * 1024 * 1024)
            total = value("MAX_TOTAL_BYTES", 8 * 1024 * 1024 * 1024)
            free = value("MIN_FREE_BYTES", 512 * 1024 * 1024, zeroAllowed: true)
        }
        var summary: [String: Any] { ["fileBytes": file, "spaceBytes": space, "totalBytes": total, "minFreeBytes": free] }
    }
    var directory: URL?
    private var entries: [Entry] = []
    private var stopped = false
    private let limits = Limits()
    private var monitor: Timer?
    private var monitorTask: Task<Void, Never>?
    var hasActive: Bool { entries.contains { $0.status == "running" } }

    func begin(_ download: WKDownload) {
        guard !stopped else {
            download.cancel(nil); return
        }
        if entries.count >= 64, let index = entries.firstIndex(where: { $0.status != "running" && !$0.finishing }) { entries.remove(at: index) }
        let id = UUID().uuidString
        guard entries.filter({ $0.status == "running" || $0.finishing }).count < 8 else {
            entries.append(Entry(id: id, status: "failed", error: "download_capacity"))
            download.cancel(nil); return
        }
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.requestCancel(id, reason: "download_expired") } }
        entries.append(Entry(id: id, download: download, timer: timer))
        download.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timer)
        if monitor == nil {
            monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    // File progress remains enforceable even while a large directory scan is pending.
                    for entry in self.entries where entry.status == "running" && !entry.cancelling && !entry.finishing {
                        if self.received(entry) > self.limits.file {
                            self.requestCancel(entry.id, reason: "download_file_limit", status: "failed")
                        }
                    }
                    guard self.monitorTask == nil else { return }
                    self.monitorTask = Task { [weak self] in
                        guard let self else { return }
                        await self.checkLimits()
                        self.monitorTask = nil
                    }
                }
            }
        }
    }

    private func index(_ download: WKDownload) -> Int? { entries.firstIndex { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let index = index(download), entries[index].status == "running", let directory else { completionHandler(nil); return }
        let id = entries[index].id
        Task {
            do {
                if let error = try await limitError(id, expected: response.expectedContentLength) { throw error }
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == "running", !entries[index].cancelling, !stopped else { completionHandler(nil); return }
                let folder = directory.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let leaf = String((suggestedFilename as NSString).lastPathComponent.prefix(128))
                let name = leaf.isEmpty || [".", "..", "/"].contains(leaf) ? "download" : leaf
                let path = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: path.path) else { throw BrowserError("download_failed", "下载路径已存在") }
                entries[index].path = path; entries[index].filename = name
                completionHandler(path)
            } catch {
                if let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == "running", !entries[index].cancelling {
                    finish(index, status: "failed", error: (error as? BrowserError)?.code ?? "download_budget_unavailable")
                }
                completionHandler(nil)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = index(download), entries[index].status == "running", !entries[index].cancelling, !entries[index].finishing else { return }
        entries[index].finishing = true
        let id = entries[index].id
        entries[index].timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let index = self.entries.firstIndex(where: { $0.id == id }), self.entries[index].finishing else { return }
                // A deadline bounds the result, not the detached file-system work.
                self.finish(index, status: "failed", error: "download_budget_timeout")
            }
        }
        entries[index].timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timer)
        Task {
            let validationError: String?
            do {
                let error = try await limitError(id, refresh: true)
                validationError = error?.code
            } catch {
                validationError = "download_budget_unavailable"
            }
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            if entries[index].status == "running" {
                finish(index, status: validationError == nil ? "completed" : "failed", error: validationError)
            }
            entries[index].finishing = false
            if entries[index].status != "completed" {
                // Only the returning scan releases file access. Never revive a timed-out result.
                cleanup(index)
            }
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let index = index(download), entries[index].status == "running", !entries[index].cancelling else { return }
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
        guard entries[index].status == "running" else { return }
        entries[index].bytesReceived = received(entries[index])
        entries[index].status = status; entries[index].error = error
        entries[index].timer?.cancel(); entries[index].timer = nil
        entries[index].download = nil
        // Completed downloads are user files; incomplete data is never reported as a result.
        if status != "completed", !entries[index].finishing { cleanup(index) }
        if !hasActive { monitor?.invalidate(); monitor = nil }
    }
    private func cleanup(_ index: Int) {
        if let directory {
            let folder = directory.appendingPathComponent(entries[index].id, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            } catch { entries[index].cleanupError = error.localizedDescription }
        }
    }
    private func requestCancel(_ id: String, reason: String = "download_cancelled", status: String = "cancelled") {
        guard let index = entries.firstIndex(where: { $0.id.lowercased() == id.lowercased() }),
              entries[index].status == "running", !entries[index].cancelling else { return }
        // WebKit has already stopped writing. The final budget check owns the
        // terminal result; cancelling a finished WKDownload need not acknowledge again.
        guard !entries[index].finishing else { return }
        entries[index].cancelling = true
        guard let download = entries[index].download else { finish(index, status: status, error: reason); return }
        let entryID = entries[index].id
        // Keep the store alive after Tab.close until WebKit has stopped writing.
        download.cancel { [self] _ in
            guard let index = entries.firstIndex(where: { $0.id == entryID }), entries[index].status == "running" else { return }
            finish(index, status: status, error: reason)
        }
    }
    func cancelAndWait(_ id: String) async throws {
        guard entries.contains(where: { $0.id.lowercased() == id.lowercased() }) else { throw BrowserError("download_not_found", "目标 Tab 中没有该下载") }
        requestCancel(id)
        let started = monotonicNow()
        while try item(id)["status"] as? String == "running" {
            guard milliseconds(from: started) < 5000 else { throw BrowserError("download_cancel_timeout", "下载尚未确认终态，可能仍在取消或最终校验；仍被跟踪，未提前清除文件") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    func stop() {
        stopped = true
        for id in entries.filter({ $0.status == "running" }).map(\.id) { requestCancel(id) }
    }
    private func received(_ entry: Entry) -> Int64 {
        // Final validation may be stuck in file-system I/O. Its deadline and
        // ordinary state queries must not repeat metadata reads on the main actor.
        let inspectFile = entry.status == "running" && !entry.finishing
        return max(entry.bytesReceived, max(entry.download?.progress.completedUnitCount ?? 0,
            inspectFile ? entry.path.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0 : 0))
    }
    private func limitError(_ id: String, expected: Int64 = 0, refresh: Bool = false) async throws -> BrowserError? {
        guard let directory else { return BrowserError("download_failed", "下载目录不可用") }
        guard let initialIndex = entries.firstIndex(where: { $0.id == id }), entries[initialIndex].status == "running", !entries[initialIndex].cancelling else { return nil }
        if max(received(entries[initialIndex]), expected) > limits.file { return BrowserError("download_file_limit", "下载超过单文件字节限额") }
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        let usage = try await DownloadBudget.shared.usage(root, refresh: refresh)
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == "running", !entries[index].cancelling else { return nil }
        let accounted = entries[index].path.flatMap { usage.files[$0.resolvingSymlinksInPath().path] } ?? 0
        let bytes = max(received(entries[index]), accounted)
        entries[index].bytesReceived = bytes
        let expected = max(0, expected)
        if max(bytes, expected) > limits.file { return BrowserError("download_file_limit", "下载超过单文件字节限额") }
        let reservation = max(0, max(bytes, expected) - accounted)
        let spaceBytes = usage.spaces[directory.deletingLastPathComponent().lastPathComponent] ?? 0
        if spaceBytes > limits.space || reservation > limits.space - spaceBytes { return BrowserError("download_space_limit", "下载超过 Space 累计字节限额") }
        let totalBytes = usage.total
        if totalBytes > limits.total || reservation > limits.total - totalBytes { return BrowserError("download_total_limit", "下载超过应用累计字节限额") }
        if usage.free < limits.free || reservation > usage.free - limits.free { return BrowserError("download_disk_limit", "磁盘剩余空间不足") }
        return nil
    }
    private func checkLimits() async {
        let ids = entries.filter { $0.status == "running" && !$0.cancelling && !$0.finishing }.map(\.id)
        for id in ids {
            do {
                if let error = try await limitError(id) { requestCancel(id, reason: error.code, status: "failed") }
            } catch { requestCancel(id, reason: "download_budget_unavailable", status: "failed") }
        }
    }
    func item(_ id: String) throws -> [String: Any] {
        guard let entry = entries.first(where: { $0.id.lowercased() == id.lowercased() }) else { throw BrowserError("download_not_found", "目标 Tab 中没有该下载") }
        return summary(entry)
    }
    private func summary(_ entry: Entry) -> [String: Any] {
        ["id": entry.id, "status": entry.status, "filename": entry.filename,
         "path": entry.status == "completed" ? entry.path?.path as Any? ?? NSNull() : NSNull(),
         "bytesReceived": received(entry),
         "error": entry.error as Any? ?? NSNull(), "cleanupError": entry.cleanupError as Any? ?? NSNull(), "requiresForeground": false]
    }
    func snapshot() -> [String: Any] { ["downloads": entries.map(summary), "limit": 64, "activeLimit": 8, "lifetimeMs": 300000, "limits": limits.summary] }
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
