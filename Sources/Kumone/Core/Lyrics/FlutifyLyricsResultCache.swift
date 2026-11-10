import Foundation

/// Whole-result disk cache for the lyrics pipeline.
///
/// The per-source caches keep each provider's raw answer, but a replayed
/// track still walked the whole source chain: LRCLIB's "no record" was not
/// cached, so every play of a song whose lyrics came from QQ Music or
/// Netease re-queried LRCLIB first (get + several searches, with their
/// 600 ms gaps), and the translation pass re-queried its LRCLIB candidates
/// once the ten-minute in-memory window expired.
///
/// This cache stores the *final* resolved lyrics — original and translation
/// already merged — under the track key, so a previously resolved song is
/// served with zero network traffic. Network failures are never cached; a
/// definitive "no lyrics anywhere" is, mirroring the per-source pattern.
enum FlutifyLyricsResultCache {
    /// Cached "no lyrics anywhere" — distinct from a network failure.
    static let negativeMarker = "none"

    /// Codable snapshot of `FSpotifyLyrics` (which itself is a plain struct).
    struct Snapshot: Codable {
        var syncType: String
        var language: String
        var provider: String
        var translationProvider: String?
        var lines: [Line]

        struct Line: Codable {
            var startTimeMS: Int
            var words: String
            var translation: String?
        }

        init(_ lyrics: FSpotifyLyrics) {
            syncType = lyrics.syncType
            language = lyrics.language
            provider = lyrics.provider
            translationProvider = lyrics.translationProvider
            lines = lyrics.lines.map {
                Line(startTimeMS: $0.startTimeMS, words: $0.words, translation: $0.translation)
            }
        }

        var lyrics: FSpotifyLyrics {
            FSpotifyLyrics(
                syncType: syncType,
                language: language,
                provider: provider,
                translationProvider: translationProvider,
                lines: lines.map {
                    FLyricLine(startTimeMS: $0.startTimeMS, words: $0.words, translation: $0.translation)
                })
        }
    }

    /// What a cache read produced.
    enum Entry {
        /// A previously resolved result, served offline.
        case lyrics(FSpotifyLyrics)
        /// Definitively no lyrics on any source; replays stay offline too.
        case negative
        /// Not cached yet — resolve online (per-source caches still apply).
        case miss
    }

    /// Key layout: whether the translation prefetch ran is part of the key,
    /// so toggling 「显示歌词翻译」 re-resolves instead of serving the other
    /// variant. Tracks without an ID fall back to title + artist.
    static func key(_ query: FLyricsQuery, translation: Bool) -> String {
        let id = query.trackId.isEmpty
            ? "\(query.title) | \(query.artist)"
            : query.trackId
        return "resolved|\(translation ? "full" : "orig")|v1|\(id)"
    }

    static func read(key: String) async -> Entry {
        guard let raw = await LyricsDiskCache.shared.read(key) else { return .miss }
        if raw == negativeMarker { return .negative }
        guard let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.lyrics.lines.isEmpty
        else { return .miss }
        return .lyrics(snapshot.lyrics)
    }

    static func write(key: String, lyrics: FSpotifyLyrics) async {
        guard !lyrics.lines.isEmpty,
              let data = try? JSONEncoder().encode(Snapshot(lyrics)),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        await LyricsDiskCache.shared.write(key, raw)
    }

    static func writeNegative(key: String) async {
        await LyricsDiskCache.shared.write(key, negativeMarker)
    }
}
