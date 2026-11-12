// Ported from Moumusic (jiajia2222/Moumusic, main f3e511a0):
// - the quality picker in platforms/ios/Sources/Kumone/Features/Player/NowPlayingView.swift
//   (private struct QualityPickerSheet: probe-driven list, served-quality warning)
// - the layout of kun's own AudioQualitySheet (top-two cards + rows)
// Moumusic has no file named AudioQualitySheet.swift; its picker is QualityPickerSheet.
// Moumusic is licensed under LGPL-3.0; the Moumusic source files carry no per-file
// license header, so none is reproduced here. Keep this attribution comment.
//
// This rewrite is NOT a copy of Moumusic's picker: Moumusic lists only tiers its
// per-track probe confirmed, via player.availableQualitiesForCurrentTrack() and
// player.selectQuality(_:) — neither exists in kun's PlayerService. This sheet
// instead lists QualitySupport.audioQualities(for: playbackSourceMode) (all 9 tiers;
// QualitySupport allows every tier, availability is decided at resolve time) and
// applies the choice through SettingsManager + the existing
// player.applyQualityChangeIfPlaying(). The served-quality / downgrade warning in
// Moumusic's picker is intentionally not reproduced: kun's PlayerService exposes
// only servedQuality: String? and has no servedQualityTrackKey /
// servedQualityMeasured / currentQuality / trackQualityOverride.
//
// Hard dependencies provided by other groups (this file does NOT compile without them):
// - QualitySupport (Core/Player/QualitySupport.swift, Moumusic verbatim):
//     allowedTiers(for: PlaybackSourceMode, track: Track?) -> Set<String>
//     audioQualities(for: PlaybackSourceMode) -> [AudioQuality]
//     rememberChoice(_:)
// - LXUserAPIService (Core/API/LXUserAPIService.swift, Moumusic verbatim):
//     @Published private(set) var sourceTierSupport: Set<String>   // lxType tokens, union of enabled sources
//     @Published private(set) var qualityCapabilities: [String: [String]] // per-platform declared tokens
//     @Published private(set) var sourceSupportKnown: Bool
//   iOS-only in Moumusic (whole file is #if os(iOS)); the sheet's LX references
//   are therefore #if os(iOS)-gated and macOS shows no support marks.
//   QualitySupport, by contrast, has no platform guard in Moumusic — the other
//   group's port must keep it compiling on macOS too.
// - Track.source / Track.sourceMetadata / Track.normalizedForLXPlayback()
//   (see Track-edits.md) and AudioQuality.lxType / .neteaseLevel /
//   .platformLabel(_:) / .sourceDisplayName (see SettingsManager-AudioQuality.swift).
//
// Support marks are honest by construction: when sourceSupportKnown == false
// (no source has reported yet) no mark is shown at all; when known, a tier shows
// "音源已声明" only if the current track's platform (or, failing that, the union
// of enabled sources) actually declared that tier's lxType. Nothing here claims
// a tier is playable on the official route: the official route still serves only
// what the logged-in account's membership allows (see the footnote in the sheet).
import SwiftUI

/// 当前歌曲音质 — 9 档全部列出（Moumusic 的 AudioQuality 顺序，最高在前）。
/// 选择只改偏好与记忆，不绕过任何会员判断。
struct AudioQualitySheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    // LXUserAPIService is iOS-only in Moumusic (its file is wrapped in
    // #if os(iOS)); this sheet compiles for macOS too, so the LX observation
    // and every support mark below are iOS-gated. On macOS the sheet still
    // lists all 9 tiers and still writes the preference — it just shows no
    // support marks.
    #if os(iOS)
    @StateObject private var lxAPI = LXUserAPIService.shared
    #endif
    @Environment(\.dismiss) private var dismiss

    /// The gold the old sheet used for its tier icons; kept for visual continuity.
    private let tierGold = Color(red: 0.82, green: 0.66, blue: 0.30)

    /// All tiers QualitySupport offers for the current source mode, in
    /// AudioQuality.allCases order (highest first). filtered by the allowed
    /// lxType set so the sheet stays correct if QualitySupport ever restricts
    /// a mode; with Moumusic's QualitySupport the filter is a no-op (it allows
    /// every tier) and all 9 rows appear.
    /// NOTE: .exhigh and .higher share one lxType ("320k") and one
    /// sourceDisplayName ("320 kbps"); they are still two rows because they are
    /// two distinct preferences (different displayName/badge). Moumusic's own
    /// picker dedupes by lxType; this sheet deliberately does not, per spec.
    private var tiers: [AudioQuality] {
        let allowed = QualitySupport.allowedTiers(
            for: settings.playbackSourceMode, track: player.currentTrack)
        return QualitySupport.audioQualities(for: settings.playbackSourceMode)
            .filter { allowed.contains($0.lxType) }
    }

    /// What is actually playing wins; otherwise the preference.
    /// kun's servedQuality is a NetEase level string (e.g. "jymaster", "sky",
    /// "exhigh") — NOT an lxType token as in Moumusic — so it is interpreted
    /// with init?(neteaseLevel:) first, then rawValue, then lxType.
    private var selected: AudioQuality {
        if let level = player.servedQuality,
           let served = AudioQuality(neteaseLevel: level)
               ?? AudioQuality(rawValue: level)
               ?? AudioQuality(lxType: level) {
            return served
        }
        return settings.audioQuality
    }

    /// Normalized platform code of the current track ("wy" / "tx" / "kg" /
    /// "mg" / "kw" / "sd"), for the per-platform capability lookup.
    private var currentPlatform: String? {
        player.currentTrack?.normalizedForLXPlayback().source
    }

    /// Honest support mark for one tier, or nil when nothing is known yet
    /// (no mark is shown then — never claim support without data).
    /// Per-platform declaration wins when the current track's platform has an
    /// entry in qualityCapabilities; otherwise the union of enabled sources.
    /// Comparison is on lxType so .exhigh and .higher (both "320k") agree.
    /// iOS-only: LXUserAPIService does not exist on macOS (see the property
    /// declaration above), so macOS always returns nil here.
    private func supportMark(for quality: AudioQuality) -> String? {
        #if os(iOS)
        guard lxAPI.sourceSupportKnown else { return nil }
        if let platform = currentPlatform,
           let declared = lxAPI.qualityCapabilities[platform], !declared.isEmpty {
            let declaredTypes = Set(declared.compactMap { AudioQuality(lxType: $0)?.lxType })
            return declaredTypes.contains(quality.lxType) ? "音源已声明" : "未声明"
        }
        return lxAPI.sourceTierSupport.contains(quality.lxType) ? "音源已声明" : "未声明"
        #else
        return nil
        #endif
    }

    /// Card variant of supportMark: true only when the tier is declared.
    /// Derived from supportMark (single source of truth) so the two can never
    /// disagree; nil when nothing is known yet.
    private func isSupported(_ quality: AudioQuality) -> Bool? {
        supportMark(for: quality).map { $0 == "音源已声明" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.primary.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            HStack {
                Text("当前歌曲音质")
                    .font(.headline)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "官方音源按账号会员提供对应音质，未开通时自动回落到可用音质；第三方音源按音源声明提供"))
                .accessibilityLabel(Text("说明"))
                Spacer()
                Text(settings.playbackSourceMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    // The top two tiers side by side, as in the old sheet.
                    HStack(spacing: 10) {
                        if tiers.count >= 2 {
                            qualityCard(tiers[0])
                            qualityCard(tiers[1])
                        }
                    }
                    .padding(.horizontal, 18)

                    VStack(spacing: 0) {
                        ForEach(tiers.dropFirst(2)) { quality in
                            qualityRow(quality)
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.quaternary.opacity(0.4))
                    )

                    Text("音质列表来自当前播放来源模式；「音源已声明」只表示第三方音源声明支持该档，实际以返回的音频为准。账号音源（官方）只提供账号会员对应的音质，选择更高档位不会绕过会员限制；未声明的档位仍可选择，播放时会按音源实际能力回落。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                }
                .padding(.vertical, 4)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
        .modifier(QualitySheetBackground())
    }

    // MARK: - Top cards (超清母带 / 高清环绕声)

    private func qualityCard(_ quality: AudioQuality) -> some View {
        let isSelected = quality == selected
        return Button {
            select(quality)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        switch quality {
                        case .master:
                            // 三叶母带卷盘.
                            ReelIcon(color: tierGold)
                                .frame(width: 30, height: 30)
                        case .atmos, .dolby, .surround:
                            // 多层同心椭圆波纹.
                            RippleIcon(color: tierGold)
                                .frame(width: 40, height: 30)
                        default:
                            Text(quality.badge)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(tierGold)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let supported = isSupported(quality), supported {
                        Text("音源已声明")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(quality.platformLabel(player.currentTrack?.source))
                            .font(.subheadline.weight(.semibold))
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(quality.sourceDisplayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(quality.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.accent.opacity(0.12))
                                     : AnyShapeStyle(.quaternary.opacity(0.4)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func qualityRow(_ quality: AudioQuality) -> some View {
        let isSelected = quality == selected
        return Button {
            select(quality)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.secondary.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Text(quality.badge)
                        .font(.system(size: 10, weight: .bold))
                        .minimumScaleFactor(0.6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(quality.platformLabel(player.currentTrack?.source))
                            .font(.subheadline.weight(.medium))
                        if let mark = supportMark(for: quality) {
                            Text(mark)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(mark == "音源已声明" ? .green : .secondary)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1)
                                .background(
                                    (mark == "音源已声明" ? Color.green : Color.secondary)
                                        .opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(quality.sourceDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ quality: AudioQuality) {
        QualitySupport.rememberChoice(quality)
        settings.audioQuality = quality
        // Switch the current song straight away instead of waiting for the
        // next one, like the old sheet. kun has no PlayerService.selectQuality
        // (Moumusic's trackQualityOverride path); applyQualityChangeIfPlaying
        // is the existing equivalent.
        player.applyQualityChangeIfPlaying()
        dismiss()
    }
}

// MARK: - Tier icons (kept from the old sheet, decoupled from old cases)

/// 多层同心椭圆波纹 — the spatial-audio card icon.
private struct RippleIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { layer in
                Ellipse()
                    .strokeBorder(
                        color.opacity(1 - Double(layer) * 0.22),
                        lineWidth: 1.6)
                    .frame(width: 15 + CGFloat(layer) * 12,
                           height: 10 + CGFloat(layer) * 9)
            }
        }
    }
}

/// 三叶母带卷盘 — the 超清母带 card icon: a reel outline with three leaves
/// around a hub.
private struct ReelIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: 2)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            ForEach(0..<3, id: \.self) { leaf in
                let angle = Double(leaf) * 2 * .pi / 3 - .pi / 2
                Circle()
                    .fill(color)
                    .frame(width: 5.5, height: 5.5)
                    .offset(x: 8 * cos(angle), y: 8 * sin(angle))
            }
        }
    }
}

/// The sheet's glass background needs iOS 16.4; the build targets 16.0.
private struct QualitySheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.4, *) {
            content.presentationBackground(.thinMaterial)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("AudioQualitySheet") {
    AudioQualitySheet()
        .environmentObject(SettingsManager.shared)
        .environmentObject(PlayerService.shared)
}
#endif
