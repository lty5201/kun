import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
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
    /// Import outcome shown as an alert: the root toast overlay is covered
    /// by the settings sheet this page lives in, so a toast here is invisible.
    @State private var importAlertMessage: String?
    @State private var showImportAlert = false
    /// On-page record of the last import attempts, so problems can be
    /// diagnosed from a screenshot when nothing else happens.
    @State private var activityLog: [String] = []

    private func logActivity(_ line: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        activityLog.append("\(time) \(line)")
        if activityLog.count > 10 { activityLog.removeFirst(activityLog.count - 10) }
    }

    var body: some View {
        Form {
            onlineImportSection
            installedSection
            activityLogSection
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "自定义源管理"))
        .alert(
            String(localized: "导入结果"),
            isPresented: $showImportAlert
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(importAlertMessage ?? "")
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // 本地导入 presents the picker straight from UIKit (see
        // `presentNativePicker`): every SwiftUI layer — fileImporter and even
        // a sheet-wrapped UIKit picker — proved unreliable on a page nested
        // inside the settings sheet on some devices.
        #else
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
        #endif
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

    private var activityLogSection: some View {
        Section(String(localized: "导入记录")) {
            if activityLog.isEmpty {
                Text("暂无记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(activityLog, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

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
                    TextField(String(localized: "输入脚本 URL（支持 GitHub）"), text: $linkInput)
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
                        action: {
                            #if os(iOS)
                            presentNativePicker()
                            #else
                            showingFileImporter = true
                            #endif
                        })
                    sourceActionButton(
                        title: String(localized: "粘贴导入"),
                        icon: "doc.on.clipboard",
                        action: importFromClipboard)
                    sourceActionButton(
                        title: String(localized: "音源健康检测"),
                        icon: "waveform.path.ecg",
                        action: runHealthCheck,
                        busy: checking)
                }

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
                    Text("暂无自定义源")
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
                Text("开关控制该源是否参与解析；多个源同时开启时共用一个引擎、按列表顺序依次尝试，全部失败时自动降级音质并切换下一个源。")
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

    #if os(iOS)
    /// Presents the system document picker directly from UIKit. On some
    /// devices every SwiftUI-mediated path (fileImporter, and a sheet-wrapped
    /// UIKit picker) opened the picker but never delivered the picked file
    /// when this page is nested inside the settings sheet. Presenting from
    /// the top-most view controller with a retained UIKit delegate removes
    /// every SwiftUI layer from the path.
    private func presentNativePicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
            let root = window.rootViewController else {
            logActivity("错误：找不到窗口控制器")
            return
        }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        // asCopy: true — the system copies the picked files into the app's
        // tmp first, so reading them needs no security scope and cannot fail
        // on provider quirks.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .folder], asCopy: true)
        picker.allowsMultipleSelection = true
        let presenter = IOSPickerPresenter.shared
        presenter.onPick = { urls in
            logActivity("系统回调：收到 \(urls.count) 个文件")
            guard !urls.isEmpty else { return }
            importLocalBatch(urls)
        }
        presenter.onCancel = { logActivity("已取消选择") }
        picker.delegate = presenter
        top.present(picker, animated: true) {
            logActivity("选择器已显示在屏幕上")
        }
        logActivity("已请求弹出选择器（顶层：\(String(describing: type(of: top)))）")
    }
    #endif

    private func importLocalBatch(_ urls: [URL]) {
        errorMessage = nil
        importing = true
        logActivity("已选择 \(urls.count) 个文件，开始读取…")
        Task {
            defer { importing = false }
            let result = await manager.installLocalBatch(scriptsAt: urls)
            logActivity("完成：成功 \(result.installed) 个，跳过重复 \(result.skipped.count) 个，失败 \(result.failures.count) 个")
            for skipped in result.skipped {
                logActivity("跳过：\(skipped)")
            }
            for failure in result.failures {
                logActivity("失败：\(failure.name) — \(failure.error)")
            }
            var parts: [String] = []
            if result.installed > 0 {
                parts.append(String(localized: "已导入 \(result.installed) 个音源，请稍候其在列表中完成加载"))
            }
            if !result.skipped.isEmpty {
                parts.append(String(localized: "跳过 \(result.skipped.count) 个重复音源"))
            }
            if !result.failures.isEmpty {
                let names = result.failures.map(\.name).joined(separator: "、")
                parts.append(String(localized: "失败 \(result.failures.count) 个：\(names)"))
            }
            if parts.isEmpty {
                // Never silent: an empty result means nothing was even read.
                importAlertMessage = String(localized: "没有读取到任何脚本文件，请确认选择的是 .js 文件")
            } else {
                importAlertMessage = parts.joined(separator: "，")
            }
            showImportAlert = true
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
                    } else {
                        Text("该源还没有绑定 URL")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
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

#if os(iOS)
/// Retained singleton holding the document-picker delegate: the picker is
/// presented straight from UIKit (see `presentNativePicker` below), so nothing
/// depends on SwiftUI's presentation bookkeeping staying alive.
private final class IOSPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = IOSPickerPresenter()
    var onPick: (([URL]) -> Void)?
    var onCancel: (() -> Void)?

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        let callback = onPick
        clear()
        callback?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let callback = onCancel
        clear()
        callback?()
    }

    private func clear() {
        onPick = nil
        onCancel = nil
    }
}
#endif

#if DEBUG
#Preview("LuoxueSourcesPage") {
    NavigationStack {
        LuoxueSourcesPage()
            .environmentObject(SettingsManager.shared)
    }
}
#endif
