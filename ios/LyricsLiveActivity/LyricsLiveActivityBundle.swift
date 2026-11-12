// LyricsLiveActivityBundle.swift — Widget Extension entry point.
//
// Target: LyricsLiveActivity (app-extension, XcodeGen — see LiveActivity-edits.md).
// The extension links KumoneCore for LyricsLiveActivityAttributes; it owns no
// playback state. All lyric data arrives in the Activity ContentState pushed
// from the app; the extension never touches the network or location
// (Live Activities run sandboxed: no network, no location updates).
//
// Visual spec (user screenshot, 07:52):
// - Compact pill: LEFT = current lyric line in the album-derived color
//   (white fallback when there is no cover), truncated with ellipsis; no song
//   title / artist / extra controls in the pill. RIGHT = album cover as a
//   small rounded thumbnail (shared App Group file; music-note icon fallback).
// - Expanded: title/artist + 3 lyric lines + progress + play/pause + next.
// - Minimal: cover only.
// - Lock Screen: 3 lines (previous dimmed / current bold in the album color /
//   next dimmed) + refresh link bottom-left + "K" mark bottom-right.
// Previous/next lines use the same album color at 55% opacity.

#if os(iOS)
import ActivityKit
import KumoneCore
import SwiftUI
import WidgetKit

@main
struct LyricsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsLiveActivityAttributes.self) { context in
            // Lock Screen: the lyrics card below the system Now Playing card.
            LockScreenLyricsView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded: title/artist + three lyric lines + progress + controls.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Refresh: deep-links back into the app, which re-publishes
                    // the current lyric line (see KumoneIOSApp onOpenURL).
                    Link(destination: URL(string: "kumone://lyrics-refresh")!) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        LyricsThreeLinesView(state: context.state)
                        if context.state.duration > 0 {
                            ProgressView(value: context.state.progress, total: context.state.duration)
                                .tint(Color(hex: context.state.lyricColorHex))
                        }
                        HStack(spacing: 24) {
                            Spacer()
                            Link(destination: URL(string: "kumone://toggle-play")!) {
                                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                            Link(destination: URL(string: "kumone://next-track")!) {
                                Image(systemName: "forward.fill")
                                    .font(.title3)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } compactLeading: {
                // Current lyric line only — no title / artist / extra controls.
                Text(context.state.currentLine ?? context.state.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: context.state.lyricColorHex))
                    .lineLimit(1)
            } compactTrailing: {
                // Album cover thumbnail inside the pill.
                IslandCoverThumbnail(size: 28)
            } minimal: {
                // Cover only.
                IslandCoverThumbnail(size: 24)
            }
        }
    }
}

/// Album cover thumbnail from the shared App Group container; falls back to a
/// music-note icon when the container is unavailable (App Group not
/// registered) or the track has no cover.
struct IslandCoverThumbnail: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let image = LyricsIslandCover.loadCoverImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Three lyric lines: previous (dimmed album color), current (bold album
/// color), next (dimmed album color). Used by the Lock Screen view and the
/// expanded island bottom region.
struct LyricsThreeLinesView: View {
    var state: LyricsLiveActivityAttributes.ContentState

    var body: some View {
        let lyricColor = Color(hex: state.lyricColorHex)
        VStack(alignment: .leading, spacing: 6) {
            if let previous = state.previousLine {
                Text(previous)
                    .font(.subheadline)
                    .foregroundStyle(lyricColor.opacity(0.55))
                    .lineLimit(1)
            }
            Text(state.currentLine ?? "♪")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(lyricColor)
                .lineLimit(1)
            if let next = state.nextLine {
                Text(next)
                    .font(.subheadline)
                    .foregroundStyle(lyricColor.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}

/// Lock Screen lyrics card: 3 lines + bottom row (refresh left, K mark right),
/// matching the screenshot the user sent.
struct LockScreenLyricsView: View {
    var context: ActivityViewContext<LyricsLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.state.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            LyricsThreeLinesView(state: context.state)
            HStack {
                // Refresh: re-requests / re-publishes the current lyric line so
                // a stuck island can be refreshed without restarting playback.
                // Falls back to the in-app button in Settings > 歌词 if Link
                // does not fire in this context.
                Link(destination: URL(string: "kumone://lyrics-refresh")!) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                }
                Spacer()
                Text("K")
                    .font(.headline)
                    .fontWeight(.bold)
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

extension Color {
    /// "#RRGGBB" (as stored in ContentState.lyricColorHex) → Color.
    /// Anything unparseable becomes white, the documented fallback.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .white
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
#endif
