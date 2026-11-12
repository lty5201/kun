// LyricsLiveActivityAttributes.swift — True Live Activity (Dynamic Island / Lock Screen) attributes.
//
// Ported pattern: standard ActivityKit (iOS 16.1+). No Moumusic/kun prior art —
// neither project ships a Live Activity; the system Now Playing lyrics on
// dynamic-island-lyrics (NowPlayingManager.updateCurrentLyric) stays as fallback.
//
// This file lives in KumoneCore and MUST be public: the LyricsLiveActivity widget
// extension links KumoneCore and requests/updates activities with this exact type.
// Everything dynamic goes in ContentState (updatable); the static attributes hold
// only the track id. Keep every update well under Apple's 4 KB payload limit:
// three short lyric lines + title/artist + numbers.

#if os(iOS)
import ActivityKit
import Foundation

/// Lyrics Live Activity: the Dynamic Island / Lock Screen companion to the
/// system Now Playing lyric (which writes the current line into the Now Playing
/// artist field). When this activity runs, the island shows its compact view;
/// the Lock Screen shows the three-line lyrics card below the Now Playing card.
public struct LyricsLiveActivityAttributes: ActivityAttributes {
    /// Lyric color when there is no cover or color extraction fails: white.
    public static let fallbackLyricColorHex = "#FFFFFF"

    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        /// Line before the current one; nil at the start of the song.
        public var previousLine: String?
        /// Current line; nil before the first timed line (then the first line is used).
        public var currentLine: String?
        /// Line after the current one; nil at the last line.
        public var nextLine: String?
        public var isPlaying: Bool
        public var progress: TimeInterval
        public var duration: TimeInterval
        /// Album-derived lyric color as "#RRGGBB" (white fallback when there
        /// is no cover or extraction fails). Drives the current line in the
        /// compact pill, the expanded view and the lock-screen 3-line view.
        public var lyricColorHex: String
        /// Whether a cover thumbnail is available in the shared App Group
        /// container (see LyricsIslandCover). The extension shows it in the
        /// compact pill (trailing) and the minimal view.
        public var hasCover: Bool

        public init(
            title: String,
            artist: String,
            previousLine: String? = nil,
            currentLine: String? = nil,
            nextLine: String? = nil,
            isPlaying: Bool,
            progress: TimeInterval,
            duration: TimeInterval,
            lyricColorHex: String = "#FFFFFF",
            hasCover: Bool = false
        ) {
            self.title = title
            self.artist = artist
            self.previousLine = previousLine
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
            self.progress = progress
            self.duration = duration
            self.lyricColorHex = lyricColorHex
            self.hasCover = hasCover
        }
    }

    /// NetEase track id of the song this activity belongs to. A new track ends
    /// the old activity and starts a fresh one (see LyricsLiveActivityManager).
    public var trackID: Int

    public init(trackID: Int) {
        self.trackID = trackID
    }
}
#endif
