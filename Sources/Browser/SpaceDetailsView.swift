import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class SpaceDetailsRefreshToken: ObservableObject {
    @Published var tick = 0
}

@MainActor
struct SpaceDetailsView: View {
    weak var space: Space?
    weak var model: BrowserModel?
    let activeTabProvider: () -> Tab?
    @ObservedObject var refreshToken: SpaceDetailsRefreshToken
    @State private var inspectable: Bool
    @State private var copiedKey: String?
    @State private var resetTask: Task<Void, Never>?

    init(space: Space, model: BrowserModel, activeTabProvider: @escaping () -> Tab?, refreshToken: SpaceDetailsRefreshToken) {
        self.space = space
        self.model = model
        self.activeTabProvider = activeTabProvider
        self.refreshToken = refreshToken
        _inspectable = State(initialValue: activeTabProvider()?.webView.isInspectable ?? false)
    }

    private func lifecycleLabel(for space: Space) -> (text: String, color: Color) {
        if space.configurationError != nil { return ("配置异常", .red) }
        if space.suspended { return ("已休眠", .secondary) }
        if space.busy { return ("运行中", .accentColor) }
        return ("活跃", .green)
    }

    private func certificatePolicy(for space: Space) -> String {
        if space.record.tls?.ignoreCertificateErrors == true { return "忽略证书错误" }
        return space.record.tls == nil ? "系统证书校验" : "系统证书及自定义 CA"
    }

    var body: some View {
        let _ = refreshToken.tick
        if let space {
            let tab = activeTabProvider()
            let badge = lifecycleLabel(for: space)
            let pendingStores = (model?.records ?? []).filter(\.deleting).map { (id: $0.id, name: $0.name) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstBaseline, spacing: 8) {
                    Text(space.record.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(badge.text)
                        .font(.caption)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(badge.color)
                        .background(badge.color.opacity(0.12), in: Capsule())
                }

                if let error = space.configurationError {
                    noticeBox(error.localizedDescription, color: .red)
                }
                if let blocked = space.resourceBlockedReason {
                    noticeBox(blocked, color: .orange)
                }
                if space.record.tls?.ignoreCertificateErrors == true {
                    noticeBox("当前 Space 忽略所有 TLS 证书错误，仅限受控开发环境使用。", color: .orange)
                }

                VStack(alignment: .leading, spacing: 10) {
                    infoRow(key: "space-id", label: "Space ID", value: space.record.id.uuidString, monospace: true, copyable: true)
                    if let tab {
                        infoRow(key: "tab-id", label: "当前标签页 ID", value: tab.id.uuidString, monospace: true, copyable: true)
                    }
                    infoRow(
                        key: "proxy",
                        label: "连接方式",
                        value: space.record.proxy == "direct" ? "直连" : space.record.proxy,
                        monospace: space.record.proxy != "direct",
                        copyable: space.record.proxy != "direct"
                    )
                    infoRow(key: "tls", label: "证书策略", value: certificatePolicy(for: space), monospace: false, copyable: false)
                    if let fingerprint = space.record.tls?.caSHA256 {
                        infoRow(key: "ca-sha256", label: "CA 指纹（SHA-256）", value: fingerprint, monospace: true, copyable: true)
                    }
                }

                if let tab, !tab.closed, !space.suspended {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前标签页排障")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("允许 Safari 网页检查器", isOn: $inspectable)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: inspectable) { _, enabled in
                                guard let liveTab = activeTabProvider(), !liveTab.closed else { return }
                                if liveTab.webView.isInspectable != enabled {
                                    liveTab.webView.isInspectable = enabled
                                }
                            }
                            .onChange(of: refreshToken.tick) { _, _ in
                                let actual = activeTabProvider()?.webView.isInspectable ?? false
                                if inspectable != actual { inspectable = actual }
                            }
                        HStack {
                            Text("详细诊断")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(tab.diagnostics.detailSummary)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }

                if !pendingStores.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("待清理数据容器（\(pendingStores.count)）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        ForEach(pendingStores, id: \.id) { item in
                            Text("\(item.name) · \(item.id.uuidString.prefix(8))…")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("将在下次启动时自动重试清理。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                Text("网站数据保存在此 Space 中，关闭窗口后服务继续运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 360)
            .onDisappear {
                resetTask?.cancel()
                resetTask = nil
            }
        }
    }

    private func noticeBox(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .font(.caption)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func infoRow(key: String, label: String, value: String, monospace: Bool, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstBaseline, spacing: 6) {
                Text(value)
                    .font(monospace ? .caption.monospaced() : .callout)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if copyable {
                    Button {
                        copyValue(value, key: key)
                    } label: {
                        Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedKey == key ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(copiedKey == key ? "已复制" : "复制\(label)")
                    .accessibilityLabel("复制\(label)")
                }
            }
        }
    }

    private func copyValue(_ value: String, key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return }
        copiedKey = key
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            if copiedKey == key { copiedKey = nil }
        }
    }
}
