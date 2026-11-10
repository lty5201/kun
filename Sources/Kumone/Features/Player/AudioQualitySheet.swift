import SwiftUI

/// 当前歌曲音质 — the quality sheet the NetEase app shows from the player:
/// every tier with its description and VIP badge, the current selection
/// checkmarked. The top two tiers render as the reference app's pair of
/// cards, the rest as rows.
struct AudioQualitySheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    /// The gold the reference sheet uses for its tier icons.
    private let tierGold = Color(red: 0.82, green: 0.66, blue: 0.30)

    /// All tiers, best first (matching the official sheet's order).
    private var tiers: [AudioQuality] {
        AudioQuality.allCases
            .filter(\.showsInSheet)
            .sorted { $0.sheetOrder < $1.sheetOrder }
    }

    private var selected: AudioQuality {
        // What is actually playing wins; otherwise the preference.
        if let level = player.servedQuality, let served = AudioQuality(rawValue: level) {
            return served
        }
        return settings.audioQuality
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
                .help(String(localized: "未开通对应会员时自动回落到可用音质"))
                .accessibilityLabel(Text("说明"))
                Spacer()
                Text(String(localized: "设置不同网络音质"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    // The reference app puts the top two tiers side by side.
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
                }
                .padding(.vertical, 4)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
        .modifier(QualitySheetBackground())
    }

    // MARK: - Top cards (沉浸环绕声 / 超清母带)

    private func qualityCard(_ quality: AudioQuality) -> some View {
        let isSelected = quality == selected
        return Button {
            select(quality)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if quality == .sky {
                            // 多层同心椭圆波纹 — the reference sheet's ripple.
                            RippleIcon(color: tierGold)
                                .frame(width: 40, height: 30)
                        } else {
                            // 三叶母带卷盘 — the reference sheet's reel.
                            ReelIcon(color: tierGold)
                                .frame(width: 30, height: 30)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let badge = quality.tierBadge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(tierGold, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(quality.displayName)
                            .font(.subheadline.weight(.semibold))
                        if let tag = quality.cardTag {
                            Text(tag)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(tierGold.opacity(0.9))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    tierGold.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 3))
                        }
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let english = quality.englishName {
                        Text(english)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(quality.detailText)
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

    /// The reference sheet draws the 臻音全景声 row with a diamond outline and
    /// the 高清臻音 row with equalizer level bars; Hi-Res shows a plain "H"
    /// and the rest their short badge text.
    @ViewBuilder
    private func rowIcon(_ quality: AudioQuality) -> some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 34, height: 34)
            switch quality {
            case .vivid:
                // 钻石线框 — hollow rotated-square outline.
                DiamondOutlineIcon(color: tierGold)
            case .jyeffect:
                // 多段均衡器电平柱.
                EQBarsIcon(color: tierGold)
            case .hires:
                Text("H")
                    .font(.system(size: 13, weight: .bold))
                    .minimumScaleFactor(0.6)
            default:
                Text(quality.badge)
                    .font(.system(size: 10, weight: .bold))
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private func qualityRow(_ quality: AudioQuality) -> some View {
        let isSelected = quality == selected
        return Button {
            select(quality)
        } label: {
            HStack(spacing: 12) {
                rowIcon(quality)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(quality.displayName)
                            .font(.subheadline.weight(.medium))
                        if let english = quality.englishName {
                            Text(english)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let badge = quality.tierBadge {
                            Text(badge)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1)
                                .background(
                                    badge == "SVIP" ? AnyShapeStyle(tierGold)
                                        : AnyShapeStyle(.red.opacity(0.75)),
                                    in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(quality.detailText)
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
        settings.audioQuality = quality
        // Switch the current song straight away instead of waiting for the
        // next one, like the official app.
        player.applyQualityChangeIfPlaying()
        dismiss()
    }
}

// MARK: - The reference sheet's hand-drawn tier icons

/// 多层同心椭圆波纹 — the 沉浸环绕声 card icon.
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

/// 钻石线框 — the 臻音全景声 row icon.
private struct DiamondOutlineIcon: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(color, lineWidth: 1.6)
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(45))
    }
}

/// 多段均衡器电平柱 — the 高清臻音 row icon.
private struct EQBarsIcon: View {
    let color: Color

    private let heights: [CGFloat] = [7, 13, 16, 11, 5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.6, height: heights[index])
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
