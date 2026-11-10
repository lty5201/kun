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
        .presentationBackground(.thinMaterial)
    }

    // MARK: - Top cards (沉浸环绕声 / 超清母带)

    private func qualityCard(_ quality: AudioQuality) -> some View {
        let isSelected = quality == selected
        return Button {
            select(quality)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: quality == .sky ? "circle.circle.dotted" : "waveform")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(tierGold)
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
    /// the 高清臻音 row with equalizer bars; the rest use their short badge.
    @ViewBuilder
    private func rowIcon(_ quality: AudioQuality) -> some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 34, height: 34)
            switch quality {
            case .vivid:
                Image(systemName: "diamond")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tierGold)
            case .jyeffect:
                Image(systemName: "equalizer")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tierGold)
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
        dismiss()
    }
}

#if DEBUG
#Preview("AudioQualitySheet") {
    AudioQualitySheet()
        .environmentObject(SettingsManager.shared)
        .environmentObject(PlayerService.shared)
}
#endif
