import SwiftUI

@MainActor
struct SpaceDownloadsView: View {
    weak var space: Space?
    let onError: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let groups = (space?.tabs ?? []).enumerated().compactMap { index, tab in
                let items = tab.downloads.listItems
                let title = tab.webView.title ?? URL(string: tab.persistedURL)?.host
                return items.isEmpty ? nil : (id: tab.id, index: index + 1, title: title, store: tab.downloads, items: items)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("下载").font(.headline)
                    Spacer()
                    Text(space?.record.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                if groups.isEmpty {
                    Text("此 Space 暂无下载记录").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(groups, id: \.id) { group in
                                Text("标签页 \(group.index)" + (group.title.map { " · " + $0 } ?? ""))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                ForEach(group.items) { item in
                                    downloadRow(item, store: group.store)
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(340, groups.reduce(0) { $0 + 34 + 78 * $1.items.count })))
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private func downloadRow(_ item: DownloadStore.ListItem, store: DownloadStore) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(item.name)
                Spacer()
                if item.canCancel {
                    Button("取消") {
                        Task {
                            do { try await store.cancelAndWait(item.id) }
                            catch { onError(error.localizedDescription) }
                        }
                    }
                    .help("取消下载「" + item.name + "」")
                } else if let url = item.file {
                    Button("在访达中显示") {
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            onError("原位置已找不到这个文件。")
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            if item.status == "running" {
                if item.expected > 0 {
                    ProgressView(value: Double(min(item.received, item.expected)), total: Double(item.expected))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(statusText(item)).font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func statusText(_ item: DownloadStore.ListItem) -> String {
        func bytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
        switch item.status {
        case "running":
            return "正在下载 · " + bytes(item.received) + (item.expected > 0 ? " / " + bytes(item.expected) : "")
        case "finishing": return "正在校验 · " + bytes(item.received)
        case "waitingForCleanup": return "下载失败，等待文件检查结束后可休眠"
        case "cancelling": return "正在取消"
        case "completed": return "已完成 · " + bytes(item.received)
        case "cancelled": return "已取消"
        default: return "下载失败" + (item.error.map { " · " + $0 } ?? "")
        }
    }
}
