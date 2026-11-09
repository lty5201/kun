import SwiftUI

/// Flutify's lyrics settings, presented as its own page so the entry is
/// always visible from Settings (not hidden behind another toggle).
///
/// Items and their order mirror Flutify's `LyricsSection` 1:1:
/// auto-translate, exclude interface, excluded languages, size, alignment,
/// focus position, fallback, source order, bilingual.
struct LyricsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsManager
    @State private var editingExcludedLanguages = false
    @State private var excludedLanguagesInput = ""

    var body: some View {
        Form {
            Section {
                Toggle("自动翻译歌词", isOn: $settings.lyricsAutoTranslate)
                Text("自动查找已有译文。中文译词按曲名、歌手优先查询 QQ 音乐，缺失或不完整时查网易云，启用补全时最后查 LRCLIB；只采用不丢失已译行的更完整版本。简繁体跟随界面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("翻译")
            }

            Section {
                Toggle("不自动翻译界面语言", isOn: $settings.lyricsExcludeInterfaceLanguage)
                Button {
                    excludedLanguagesInput = settings.lyricsExcludedLanguages.joined(separator: ", ")
                    editingExcludedLanguages = true
                } label: {
                    HStack {
                        Text("其他不自动翻译的语言")
                        Spacer()
                        Text(settings.lyricsExcludedLanguages.isEmpty
                             ? "留空" : settings.lyricsExcludedLanguages.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text("用逗号分隔：en, ja, zh-Hans（简体）, zh-Hant（繁体）；zh 排除全部中文，留空清除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("不翻译的语言")
            }

            Section("外观") {
                HStack {
                    Text("歌词字号")
                    Spacer()
                    Text("\(Int(settings.lyricsScale * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $settings.lyricsScale,
                    in: SettingsManager.lyricsScaleRange,
                    step: 0.05
                )
                HStack {
                    Text("70%")
                    Spacer()
                    Text("160%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("对齐方式", selection: $settings.lyricsAlign) {
                    ForEach(SettingsManager.LyricsAlign.allCases) { align in
                        Text(align.displayName).tag(align)
                    }
                }

                HStack {
                    Text("当前行位置")
                    Spacer()
                    Text("\(Int(settings.lyricsFocusPosition * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("调整当前歌词在可见歌词区域中的高度，数值越大越靠下。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $settings.lyricsFocusPosition,
                    in: SettingsManager.lyricsFocusPositionRange,
                    step: 0.01
                )
            }

            Section("来源") {
                Toggle("补全歌词", isOn: $settings.lyricsFallback)
                Text("Spotify 没有逐行同步歌词时，从 LRCLIB 开放歌词库补全，并按原唱语言挑选")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LyricsSourceOrderList(
                    order: $settings.lyricsSourceOrder,
                    lrclibEnabled: settings.lyricsFallback)

                Toggle("社区歌词翻译", isOn: $settings.lyricsBilingual)
                Text("加载歌词时预取中文译词，优先 QQ 音乐，缺失或不完整时查网易云，启用补全时最后查 LRCLIB，也供任务栏歌词使用。关闭后仍可手动或自动查询；曲名与歌手会发送到查询来源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("歌词")
        .navigationBarTitleDisplayMode(.inline)
        .alert("其他不自动翻译的语言", isPresented: $editingExcludedLanguages) {
            TextField("语言代码", text: $excludedLanguagesInput)
                .autocorrectionDisabled()
            Button("保存") {
                settings.lyricsExcludedLanguages = Self.parseLanguages(excludedLanguagesInput)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请输入语言代码，例如 en、ja、zh-Hans、zh-Hant")
        }
    }

    /// Same parsing as Flutify: comma / whitespace separated, `_` → `-`,
    /// deduplicated, order-preserving.
    static func parseLanguages(_ value: String) -> [String] {
        value
            .lowercased()
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .reduce(into: [String]()) { out, item in
                if !out.contains(item) { out.append(item) }
            }
    }
}

/// The four sources in priority order; drag the handle to reorder (higher
/// is queried first). Mirrors Flutify's `LyricsSourceOrderTile`.
private struct LyricsSourceOrderList: View {
    @Binding var order: [SettingsManager.LyricsSourceKind]
    let lrclibEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("歌词来源优先级")
                .font(.subheadline)
            Text("拖动右侧手柄调整顺序，越靠前越优先。原文与中文译词都按此顺序在各来源之间查找。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(order) { source in
                    HStack(spacing: 10) {
                        Text("\(order.firstIndex(of: source).map { $0 + 1 } ?? 0)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                                .foregroundStyle(source == .lrclib && !lrclibEnabled
                                                 ? Color.secondary : Color.primary)
                            Text(source.roleText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .onMove { from, to in
                    order.move(fromOffsets: IndexSet(from), toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: CGFloat(order.count * 56))
            .scrollDisabled(true)
            .background(Color.clear)
            .environment(\.defaultMinListRowHeight, 52)
        }
    }
}

#if DEBUG
#Preview("LyricsSettingsPage") {
    NavigationStack {
        LyricsSettingsPage()
            .environmentObject(SettingsManager.shared)
    }
}
#endif
