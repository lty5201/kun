import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 自定义源管理：导入兼容 lx-music 格式的第三方音源脚本。
///
/// Mirrors the reference app's page: online import (direct link, with
/// GitHub/Gitee/GitLab blob links auto-converted to raw), local import,
/// clipboard import, a source health check, and the list of installed
/// sources with per-source enable / refresh / delete.
struct LuoxueSourcesPage: View {
    @ObservedObject private var manager = LuoxueSourceManager.shared

    @State private var linkInput = ""
    @State private var importing = false
    @State private var showingFileImporter = false
    @State private var checking = false
    @State private var checkResults: [UUID: LuoxueSourceManager.CheckResult] = [:]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            onlineImportSection
            installedSection
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "自定义源管理"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showingFileImporter,
            // .folder so whole folders of scripts are pickable, matching the
            // advertised batch import.
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                importLocalBatch(urls)
            case .failure:
                break
            }
        }
        .onAppear {
            _ = manager.ensureLoadedFromSettings()
        }
        .overlay(alignment: .top) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: errorMessage)
    }

    // MARK: - 在线导入

    private var onlineImportSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note.house.fill")
                        .foregroundStyle(Theme.accent)
                    Text("导入兼容 lx-music 格式的第三方音源脚本")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("在线导入")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    TextField(String(localized: "输入脚本直链 (latest.js)"), text: $linkInput)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { importOnline() }

                    Button {
                        importOnline()
                    } label: {
                        if importing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: 24, height: 24)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(importing || linkInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(Text("在线导入"))
                }

                Text("支持 GitHub/Gitee/GitLab 链接自动转换为 raw 直链")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    sourceActionButton(
                        title: String(localized: "本地导入"),
                        icon: "folder",
                        action: { showingFileImporter = true })
                    sourceActionButton(
                        title: String(localized: "粘贴导入"),
                        icon: "doc.on.clipboard",
                        action: importFromClipboard)
                    sourceActionButton(
                        title: String(localized: "音源体检"),
                        icon: "waveform.path.ecg",
                        action: runHealthCheck,
                        busy: checking)
                }

                Text("本地导入支持一次选择多个脚本，或直接选择整个文件夹批量导入")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }

    private func sourceActionButton(
        title: String, icon: String, action: @escaping () -> Void, busy: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(title).font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 已导入音源

    private var installedSection: some View {
        Section {
            if manager.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有导入音源")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            } else {
                ForEach(manager.entries) { entry in
                    LuoxueSourceRow(
                        entry: entry,
                        checkDetail: checkResults[entry.id]?.detail,
                        onToggle: { enabled in
                            manager.setEnabled(enabled, id: entry.id)
                        },
                        onRefresh: {
                            Task { await manager.refreshOnline(id: entry.id) }
                        },
                        onDelete: {
                            manager.remove(id: entry.id)
                            checkResults.removeValue(forKey: entry.id)
                        })
                }
            }
        } header: {
            Text("已导入音源")
        } footer: {
            if !manager.entries.isEmpty {
                Text("开关控制该源是否参与解析；多个源同时开启时按列表顺序依次尝试。刷新会重新下载在线源并重载脚本。")
            }
        }
    }

    // MARK: - Actions

    private func importOnline() {
        guard !importing else { return }
        importing = true
        errorMessage = nil
        let input = linkInput
        Task {
            defer { importing = false }
            do {
                try await manager.installOnline(urlString: input)
                linkInput = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importLocalBatch(_ urls: [URL]) {
        errorMessage = nil
        importing = true
        Task {
            defer { importing = false }
            let result = await manager.installLocalBatch(scriptsAt: urls)
            if result.failures.isEmpty {
                if result.installed > 0 {
                    ToastCenter.shared.show(String(localized: "已导入 \(result.installed) 个音源"))
                }
            } else {
                let names = result.failures.map(\.name).joined(separator: "、")
                errorMessage = String(localized: "已导入 \(result.installed) 个，失败 \(result.failures.count) 个：\(names)")
            }
        }
    }

    private func importFromClipboard() {
        errorMessage = nil
        #if os(macOS)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        let text = UIPasteboard.general.string ?? ""
        #endif
        guard !text.isEmpty else {
            errorMessage = String(localized: "剪贴板是空的")
            return
        }
        Task {
            do {
                try await manager.installFromClipboard(text: text)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runHealthCheck() {
        guard !checking else { return }
        checking = true
        checkResults = [:]
        errorMessage = nil
        Task {
            let results = await manager.checkAll()
            checkResults = Dictionary(results.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
            checking = false
        }
    }
}

// MARK: - One installed source row

private struct LuoxueSourceRow: View {
    let entry: LuoxueSourceManager.Entry
    let checkDetail: String?
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void
    let onDelete: () -> Void

    private var statusText: String {
        if let checkDetail { return checkDetail }
        return entry.state.summaryText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let url = entry.originURL {
                        Text(url)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { entry.enabled },
                    set: onToggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(2)

            HStack {
                Spacer()
                Button {
                    onRefresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var isLoading: Bool {
        if case .loading = entry.state { return true }
        return false
    }

    private var statusColor: Color {
        if let checkDetail {
            return .secondary
        }
        switch entry.state {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

#if DEBUG
#Preview("LuoxueSourcesPage") {
    NavigationStack {
        LuoxueSourcesPage()
            .environmentObject(SettingsManager.shared)
    }
}
#endif
