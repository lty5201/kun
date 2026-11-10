import Foundation
import CryptoKit

// MARK: - Query model

/// What the lyrics pipeline needs to know about a track
/// (Flutify's LyricsQuery).
struct FLyricsQuery {
    var trackId: String
    var title: String
    /// All artists, ", "-joined (matches how LRCLIB / Netease present them).
    var artist: String
    var album: String
    var durationMS: Int
    /// The first artist, used for searches where one name works better.
    var primaryArtist: String { artist.components(separatedBy: ", ").first ?? "" }
}

// MARK: - Result model

/// Lyrics fetch result, mirroring Flutify's SpotifyLyrics.
struct FSpotifyLyrics: Equatable {
    var syncType: String = "UNSYNCED"
    var language: String = "und"
    var provider: String = "lrclib.net"
    var translationProvider: String?
    var lines: [FLyricLine] = []
    var isSynced: Bool { syncType == "LINE_SYNCED" }
}

/// One lyrics lookup: `lyrics` nil means not found; `networkError` means the
/// miss may just be a network problem (the caller must not cache it).
struct FLyricsLookup {
    var lyrics: FSpotifyLyrics?
    var networkError: Bool = false
}

// MARK: - LRCLIB client

/// `https://lrclib.net` public lyrics database; no authentication needed.
///
/// - `GET /api/get`: exact match on title + artist + album + duration; a
///   mismatch returns 404 (the normal "no such record" case).
/// - `GET /api/search`: search by title/artist or full-text `q`.
///
/// 404 = not found. 429 / 503-with-Retry-After enter a shared cooldown.
/// Other 5xx / offline / timeout retry at most twice, and the miss is then
/// reported as a network error so it is not cached as final.
struct LRCLIBClient {
    static let baseUrl = "https://lrclib.net/api"
    static let timeout: TimeInterval = 12

    var userAgent: String = "Kun (https://github.com/lty5201/kun)"
    /// Shared cooldown across all instances of the client.
    private static let cooldown = FSharedCooldown()

    func get(track: String, artist: String, album: String = "", durationSec: Int = 0) async -> FLyricsResponse {
        var query = "track_name=\(fQuery(track))&artist_name=\(fQuery(artist))"
        if !album.isEmpty { query += "&album_name=\(fQuery(album))" }
        if durationSec > 0 { query += "&duration=\(durationSec)" }
        return await request("/get", query)
    }

    func search(track: String? = nil, artist: String? = nil, q: String? = nil) async -> FLyricsResponse {
        var parts: [String] = []
        if let track, !track.isEmpty { parts.append("track_name=\(fQuery(track))") }
        if let artist, !artist.isEmpty { parts.append("artist_name=\(fQuery(artist))") }
        if let q, !q.isEmpty { parts.append("q=\(fQuery(q))") }
        return await request("/search", parts.joined(separator: "&"))
    }

    private func request(_ path: String, _ query: String) async -> FLyricsResponse {
        guard let url = URL(string: "\(Self.baseUrl)\(path)?\(query)") else {
            return FLyricsResponse(candidates: [], networkError: true)
        }
        var attempt = 0
        while true {
            if await Self.cooldown.active() {
                return FLyricsResponse(candidates: [], networkError: true)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.timeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            var code = 0
            var body: Data?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                code = (response as? HTTPURLResponse)?.statusCode ?? 0
                body = data
                if await Self.cooldown.observe(response as? HTTPURLResponse) {
                    return FLyricsResponse(candidates: [], networkError: true)
                }
                if code == 200, let body,
                   let json = try? JSONSerialization.jsonObject(with: body) {
                    let candidates = LRCLIBCandidate.list(from: json)
                    return FLyricsResponse(candidates: candidates)
                }
            } catch {
                code = 0 // offline / timeout / TLS
            }
            if code == 404 { return FLyricsResponse(candidates: []) }
            let transient = code == 0 || code >= 500
            if !transient { return FLyricsResponse(candidates: []) }
            if attempt >= 2 {
                return FLyricsResponse(candidates: [], networkError: true)
            }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(600_000_000 * UInt64(attempt)))
        }
    }
}

func fQuery(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

/// A shared Retry-After cooldown (Flutify's RetryAfterCooldown).
actor FSharedCooldown {
    private var until: Date?

    func active() -> Bool {
        until.map { $0 > Date() } ?? false
    }

    /// Records 429 / Retry-After responses; true when the response starts a
    /// cooldown the caller must honor.
    func observe(_ response: HTTPURLResponse?) -> Bool {
        guard let response else { return false }
        if response.statusCode == 429 || response.statusCode == 503,
           let raw = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            until = Date().addingTimeInterval(seconds)
            return true
        }
        return false
    }
}

struct FLyricsResponse {
    var candidates: [LRCLIBCandidate]
    var networkError: Bool = false
}

// MARK: - LRCLIB candidate

/// One LRCLIB record (`/api/get` returns an object, `/api/search` an array).
///
/// Only records with synced lyrics are kept: plain-text lyrics add nothing
/// over what the player already has — the point of the fallback is the
/// timeline. Instrumental records are kept so the selector can recognize
/// "this song is an instrumental" and refuse to attach wrong lyrics.
final class LRCLIBCandidate {
    let trackName: String
    let artistName: String
    let albumName: String
    let synced: String
    /// Duration in seconds; 0 when unknown.
    let duration: Double
    let instrumental: Bool
    /// Rejected as a translation / romanization / whole-body mix (written by
    /// the selector; bilingual records are not rejected).
    var rejected = false

    init(trackName: String, artistName: String = "", albumName: String = "",
         synced: String, duration: Double = 0, instrumental: Bool = false) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.synced = synced
        self.duration = duration
        self.instrumental = instrumental
    }

    /// Parsed lines (empty for instrumentals), parsed once.
    lazy var lines: [FLyricLine] = instrumental ? [] : FLrcParser.parse(synced)

    /// Bilingual pairs split into original + translation; nil when the
    /// record is not a bilingual structure. Split once.
    lazy var mergedLines: [FLyricLine]? = lines.isEmpty ? nil : TranslationMerge.tryMerge(lines)

    /// All original-side text (the plain lyrics when not bilingual). The
    /// selector's language voting and scoring look at originals only.
    lazy var originalText: String = TranslationMerge.originalText(mergedLines ?? lines)

    /// Parses one record; nil when the structure is wrong or it has neither
    /// synced lyrics nor an instrumental marker.
    static func from(json: Any) -> LRCLIBCandidate? {
        guard let dict = json as? [String: Any] else { return nil }
        let instrumental = (dict["instrumental"] as? Bool) == true
        let synced = dict["syncedLyrics"] as? String
        if (synced == nil || synced?.isEmpty == true) && !instrumental { return nil }
        let duration = (dict["duration"] as? Double) ?? 0
        return LRCLIBCandidate(
            trackName: dict["trackName"] as? String ?? "",
            artistName: dict["artistName"] as? String ?? "",
            albumName: dict["albumName"] as? String ?? "",
            synced: synced ?? "",
            duration: duration,
            instrumental: instrumental)
    }

    /// Parses a `/api/get` (object) or `/api/search` (array) response.
    static func list(from json: Any) -> [LRCLIBCandidate] {
        let items = json as? [Any] ?? [json]
        return items.compactMap { from(json: $0) }
    }
}

// MARK: - TranslationMerge (translation_merge.dart)

/// Splits bilingual LRC records into "original + translation" lines.
///
/// Many lyric databases hold a bilingual variant of the same song: the
/// original and its translation share a timestamp (or differ by a fraction
/// of a second). Such a record is not "a translation, unusable" — after the
/// split both sides are available: the original keeps scrolling, the
/// translation lands in `FLyricLine.translation`. When no bilingual
/// structure is detected, returns nil and the caller treats the lyrics as a
/// normal record.
enum TranslationMerge {
    /// Tolerance when deciding that lines share a timestamp.
    private static let toleranceMS = 500
    /// A busy timestamp can stack original + multiple annotations (kana /
    /// romaji / translation); one original line carries at most two
    /// translation lines, joined together.
    private static let maxTranslationLines = 2

    /// Attempts the split; nil when not a bilingual structure. The returned
    /// line count matches the original line count (translation lines are
    /// absorbed).
    static func tryMerge(_ lines: [FLyricLine]) -> [FLyricLine]? {
        // Group by time adjacency (parsing is stably sorted, so same-time
        // lines keep their order): within tolerance of the previous line means
        // the same group. Empty lines are interlude markers and are kept
        // aside; translation credit lines are removed.
        var groups: [[FLyricLine]] = []
        var empties: [FLyricLine] = []
        for line in lines {
            if line.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                empties.append(line)
                continue
            }
            if FTranslationMarkers.isCreditLine(line.words) { continue }
            if let last = groups.last,
               line.startTimeMS - last[last.count - 1].startTimeMS <= toleranceMS {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }

        // A bilingual structure: a group with at least two known languages
        // counts as paired; the pair count is estimated as the group size
        // minus the largest same-language line count.
        var pairs = 0
        var nonEmpty = 0
        for group in groups {
            nonEmpty += group.count
            let counts = tagLineCounts(group)
            if counts.count < 2 { continue }
            let known = counts.values.reduce(0, +)
            let top = counts.values.max() ?? 0
            pairs += known - top
        }
        if pairs < 3 || pairs * 3 < nonEmpty { return nil }

        let originalTag = pickOriginalTag(groups)
        let translationTags = pickTranslationTags(groups, originalTag)

        var merged: [FLyricLine] = []
        for group in groups {
            if tagLineCounts(group).count < 2 {
                // Same-language multiple lines (fast songs: two lines within
                // 0.5 s) or undetectable language: keep line by line.
                merged.append(contentsOf: group)
                continue
            }
            merged.append(contentsOf: mergeGroup(group, originalTag, translationTags))
        }
        // The grouping can shuffle lines within 0.5 s; put the interlude
        // lines back and stably re-sort by time.
        merged.append(contentsOf: empties)
        let indexed = merged.enumerated().sorted { a, b in
            let difference = a.element.startTimeMS - b.element.startTimeMS
            return difference != 0 ? difference < 0 : a.offset < b.offset
        }.map(\.element)
        return indexed.isEmpty ? nil : indexed
    }

    /// All original-side text joined (for language voting / scoring).
    static func originalText(_ lines: [FLyricLine]) -> String {
        lines
            .filter { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.words)
            .joined(separator: "\n")
    }

    /// Line counts per known language inside a group (letter-less lines are
    /// not counted).
    private static func tagLineCounts(_ group: [FLyricLine]) -> [FLyricLang: Int] {
        var counts: [FLyricLang: Int] = [:]
        for line in group {
            let tag = fDetectLang(line.words)
            if tag != .unknown { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    /// Global language vote for the original language.
    ///
    /// 1. The language appearing in the most paired groups.
    /// 2. On a tie (a standard bilingual LRC has one line per side per group,
    ///    so ties are guaranteed): prefer non-Chinese — the translation
    ///    sources here (LRCLIB bilingual records, Netease tlyric) are almost
    ///    always Chinese translations, while "Chinese original + foreign
    ///    translation" records are rare. Track/artist names are not used:
    ///    Spotify localizes artist names and J-pop often uses English titles.
    /// 3. Still tied (e.g. Japanese + romaji + Chinese triple groups): the
    ///    language more often placed first inside the groups.
    private static func pickOriginalTag(_ groups: [[FLyricLine]]) -> FLyricLang {
        var presence: [FLyricLang: Int] = [:]
        var leading: [FLyricLang: Int] = [:]
        for group in groups {
            let tags = group.map { fDetectLang($0.words) }.filter { $0 != .unknown }
            if Set(tags).count < 2 { continue }
            for tag in Set(tags) {
                presence[tag, default: 0] += 1
            }
            if let first = tags.first {
                leading[first, default: 0] += 1
            }
        }
        var best = FLyricLang.unknown
        for tag in presence.keys {
            if best == .unknown || beats(tag, best, presence, leading) {
                best = tag
            }
        }
        return best
    }

    /// The group's original language: the global original when present,
    /// otherwise the group's first line language.
    private static func groupTag(_ tags: [FLyricLang], _ originalTag: FLyricLang) -> FLyricLang {
        if tags.contains(originalTag) { return originalTag }
        return tags.first(where: { $0 != .unknown }) ?? .unknown
    }

    /// Global translation languages: those appearing as "not the original"
    /// in at least half as many paired groups as the most frequent one.
    private static func pickTranslationTags(_ groups: [[FLyricLine]], _ originalTag: FLyricLang) -> Set<FLyricLang> {
        var presence: [FLyricLang: Int] = [:]
        for group in groups {
            let tags = group.map { fDetectLang($0.words) }
            let known = Set(tags.filter { $0 != .unknown })
            if known.count < 2 { continue }
            for tag in known where tag != groupTag(tags, originalTag) {
                presence[tag, default: 0] += 1
            }
        }
        if presence.isEmpty { return [] }
        let top = presence.values.max() ?? 0
        return Set(presence.filter { $0.value * 2 >= top }.keys)
    }

    private static func beats(_ a: FLyricLang, _ b: FLyricLang,
                              _ presence: [FLyricLang: Int], _ leading: [FLyricLang: Int]) -> Bool {
        let pa = presence[a] ?? 0, pb = presence[b] ?? 0
        if pa != pb { return pa > pb }
        // Tie: Chinese is usually the translation.
        if (a == .zh) != (b == .zh) { return b == .zh }
        return (leading[a] ?? 0) > (leading[b] ?? 0)
    }

    /// Splits one paired group: original-language lines become their own
    /// original lines; translation-language lines attach by nearest time to
    /// an original line as translations; lines in neither language (a stray
    /// third language) stay as normal lyric lines.
    private static func mergeGroup(_ group: [FLyricLine], _ originalTag: FLyricLang,
                                   _ translationTags: Set<FLyricLang>) -> [FLyricLine] {
        let tags = group.map { fDetectLang($0.words) }
        let tag = groupTag(tags, originalTag)

        var originals: [Int] = []
        var translations: [Int: [String]] = [:]
        var out: [FLyricLine] = []
        for (index, _) in group.enumerated() where tags[index] == tag {
            originals.append(index)
            translations[index] = []
        }
        for index in group.indices where tags[index] != tag {
            let line = group[index]
            // Letter-less lines (punctuation / musical notes only) are not
            // translations; unknown or non-translation languages are real
            // lyric lines.
            if tags[index] == .unknown || !translationTags.contains(tags[index]) {
                out.append(FLyricLine(startTimeMS: line.startTimeMS, words: line.words))
                continue
            }
            // Nearest original in time; on equal distance the one with fewer
            // translations, then the earlier one.
            var target: Int?
            for original in originals {
                if translations[original]?.count ?? 0 >= maxTranslationLines { continue }
                if target == nil {
                    target = original
                    continue
                }
                let d = abs(group[original].startTimeMS - line.startTimeMS)
                let bestD = abs(group[target!].startTimeMS - line.startTimeMS)
                if d < bestD || (d == bestD
                    && (translations[original]?.count ?? 0) < (translations[target!]?.count ?? 0)) {
                    target = original
                }
            }
            if let target {
                translations[target]?.append(line.words)
            }
        }
        for original in originals {
            let line = group[original]
            out.append(FLyricLine(
                startTimeMS: line.startTimeMS,
                words: line.words,
                translation: (translations[original] ?? []).joined(separator: " / ")))
        }
        return out
    }
}

// MARK: - TranslationFilter (translation_filter.dart)

/// Recognizes LRCLIB "translation / romanization" records: those are not the
/// song's real lyrics and are never used. Bilingual records (original +
/// translation at the same timestamp) are no longer rejected — they split
/// into original + translation; only mixing without a pair structure and
/// marker labels are rejected here.
enum TranslationFilter {
    /// True when the record must not be used. `title` is the current track
    /// name.
    static func isRejected(_ candidate: LRCLIBCandidate, _ title: String) -> Bool {
        let nameMatch = candidate.trackName.trimmingCharacters(in: .whitespaces).lowercased()
            == title.trimmingCharacters(in: .whitespaces).lowercased()
        if !nameMatch,
           FTranslationMarkers.hasMarker("\(candidate.trackName) \(candidate.artistName) \(candidate.albumName)") {
            return true
        }
        // Bilingual records split fine: the original stays, the translation
        // rides along — that is not a "translation-only" record.
        if candidate.mergedLines != nil { return false }
        let head = String(candidate.synced.prefix(600))
        if FTranslationMarkers.hasMarker(head) { return true }
        return isMixed(candidate.lines)
    }

    /// A whole-body bilingual mix without per-line pairs.
    static func isMixed(_ lines: [FLyricLine]) -> Bool {
        var total = 0, cjk = 0, latin = 0, cyrillic = 0
        for line in lines {
            if line.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            total += 1
            switch fLineFamily(line.words) {
            case 0: cjk += 1
            case 1: latin += 1
            case 2: cyrillic += 1
            default: break
            }
        }
        if total < 4 { return false }
        let big = [cjk, latin, cyrillic].filter { $0 * 5 >= total * 2 }.count
        return big >= 2
    }
}

// MARK: - LRCLIBSelector (lrclib_selector.dart)

/// The chosen record: the LRC original (script converted when needed) and
/// the detected song language.
struct LRCLIBSelection {
    var synced: String
    var lang: FLyricLang
}

/// Picks the "original-language" synced lyrics out of LRCLIB's candidates.
///
/// Rules:
/// - Song language = original language, decided by majority vote across
///   candidate lyrics — originals dominate a song's records, translations
///   and romanizations are the minority. Track/artist names only break ties.
///   Bilingual candidates are split first; voting and scoring only look at
///   the original side.
/// - An artist mismatch (a different song with the same title) excludes the
///   candidate: wrong lyrics are worse than none.
/// - Translation-only / romanization / whole-body mixes drop to the
///   "last resort" tier, used only when nothing else exists.
/// - Scoring: language match dominates; matching artist, exact title, and
///   close duration add points; Chinese also aligns simplified/traditional
///   glyph usage.
enum LRCLIBSelector {
    /// Candidates whose artist is comparable and does not match.
    private static func otherArtist(_ candidate: LRCLIBCandidate, _ query: FLyricsQuery) -> Bool {
        FArtistMatch.compare(query.artist, candidate.artistName) == .mismatch
    }

    /// When the title + artist metadata has more traditional-only
    /// characters than simplified ones, the song wants traditional lyrics.
    static func wantsTraditional(_ query: FLyricsQuery) -> Bool {
        let meta = "\(query.title) \(query.artist)"
        let traditional = ZhScript.countTraditional(meta)
        return traditional > 0 && traditional > ZhScript.countSimplified(meta)
    }

    static func select(_ all: [LRCLIBCandidate], _ query: FLyricsQuery) -> LRCLIBSelection? {
        var candidates = all.filter { !otherArtist($0, query) }
        let title = query.title
        let durationSec = Double(query.durationMS) / 1000.0

        // Missing artist info (e.g. a remote track not yet filled in) means
        // many same-title songs: only accept same-title candidates whose
        // duration matches (±5 s); no duration means no lyrics rather than
        // wrong lyrics.
        if query.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates = candidates.filter {
                sameTitle($0.trackName, title)
                    && durationSec > 0 && $0.duration > 0
                    && abs($0.duration - durationSec) <= 5
            }
            if candidates.isEmpty { return nil }
        }

        // Instrumental guard: a candidate matching title + artist + duration
        // marked instrumental, with no equally matching worded version,
        // means the song is an instrumental — no lyrics at all.
        if isInstrumental(candidates, query) { return nil }

        let wantHant = wantsTraditional(query)
        for index in candidates.indices {
            candidates[index].rejected = !candidates[index].lines.isEmpty
                && TranslationFilter.isRejected(candidates[index], title)
        }
        let target = decideSongLang(candidates, query)

        var best: LRCLIBCandidate?
        var alt: LRCLIBCandidate?
        var bestScore = -Double.infinity
        var altScore = -Double.infinity
        for candidate in candidates where !candidate.lines.isEmpty {
            let score = score(candidate, target, title, durationSec, wantHant)
                + (sameArtist(candidate, query) ? 15 : 0)
            if candidate.rejected {
                if score - 40 > altScore {
                    altScore = score - 40
                    alt = candidate
                }
            } else if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        // Everything rejected by the translation rules: a last resort —
        // worded lyrics beat none.
        guard let pick = best ?? alt else { return nil }

        // Simplified/traditional glyph alignment: convert character by
        // character when the library only has the other variant.
        var synced = pick.synced
        if target == .zh {
            let t = ZhScript.countTraditional(synced)
            let s = ZhScript.countSimplified(synced)
            if !wantHant && t >= 3 && t > s {
                synced = ZhScript.convert(synced, toSimplified: true)
            } else if wantHant && s >= 3 && s > t {
                synced = ZhScript.convert(synced, toSimplified: false)
            }
        }
        return LRCLIBSelection(synced: synced, lang: target)
    }

    /// Song language: candidates vote (same title / close duration votes are
    /// heavier); the title and artist text each cast a small vote.
    static func decideSongLang(_ candidates: [LRCLIBCandidate], _ query: FLyricsQuery) -> FLyricLang {
        var votes: [FLyricLang: Double] = [:]
        func vote(_ lang: FLyricLang, _ weight: Double) {
            guard lang != .unknown else { return }
            votes[lang, default: 0] += weight
        }

        let durationSec = Double(query.durationMS) / 1000.0
        for candidate in candidates {
            if candidate.lines.isEmpty || candidate.rejected || otherArtist(candidate, query) { continue }
            var weight = 1.0
            if sameTitle(candidate.trackName, query.title) { weight += 1 }
            if sameArtist(candidate, query) { weight += 1 }
            if durationSec > 0 && candidate.duration > 0 {
                let difference = abs(candidate.duration - durationSec)
                if difference <= 3 {
                    weight += 1
                } else if difference > 20 {
                    weight *= 0.3 // a very different duration is likely another song
                }
            }
            vote(fLyricLang(candidate.originalText), weight)
        }
        vote(fDetectLang(query.title), 1.5)
        vote(fDetectLang(query.artist), 0.5)

        var best = FLyricLang.unknown
        var bestValue = 0.0
        for (lang, value) in votes where value > bestValue {
            bestValue = value
            best = lang
        }
        return best
    }

    private static func score(_ candidate: LRCLIBCandidate, _ target: FLyricLang,
                              _ title: String, _ durationSec: Double, _ wantHant: Bool) -> Double {
        var score = fLangScore(target, candidate.originalText)
        if target == .zh {
            let t = ZhScript.countTraditional(candidate.originalText)
            let s = ZhScript.countSimplified(candidate.originalText)
            if t >= 3 || s >= 3 {
                score += (t > s) == wantHant ? 10 : -25
            }
        }
        if sameTitle(candidate.trackName, title) { score += 12 }
        if durationSec > 0 && candidate.duration > 0 {
            let difference = abs(candidate.duration - durationSec)
            if difference <= 3 {
                score += 10
            } else if difference <= 8 {
                score += 4
            } else if difference > 20 {
                score -= 15
            }
        }
        return score
    }

    /// The current track is an instrumental when an "exact match" (same
    /// title, matching artist, duration within 5 s) is marked instrumental
    /// and no equally exact worded version exists.
    private static func isInstrumental(_ candidates: [LRCLIBCandidate], _ query: FLyricsQuery) -> Bool {
        let durationSec = Double(query.durationMS) / 1000.0
        func exact(_ candidate: LRCLIBCandidate) -> Bool {
            sameTitle(candidate.trackName, query.title)
                && sameArtist(candidate, query)
                && (durationSec <= 0 || candidate.duration <= 0
                    || abs(candidate.duration - durationSec) <= 5)
        }
        var instrumentalExact = false
        for candidate in candidates where exact(candidate) {
            if candidate.instrumental {
                instrumentalExact = true
            } else if !candidate.lines.isEmpty {
                return false // an exact worded version exists: not instrumental
            }
        }
        return instrumentalExact
    }

    private static func sameArtist(_ candidate: LRCLIBCandidate, _ query: FLyricsQuery) -> Bool {
        FArtistMatch.compare(query.artist, candidate.artistName) == .match
    }

    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        FLyricsTitle.search(a).lowercased() == FLyricsTitle.search(b).lowercased()
    }
}

// MARK: - LRCLIB translation (lrclib_translation.dart)

/// LRCLIB has no translation endpoint or reliable language field. Other-
/// language records must match the song and its timeline; arbitrary
/// line-index pairing is never safe. Bilingual records also provide
/// original-text anchors.
enum LRCLIBTranslation {
    private static let translationSuffix: NSRegularExpression = {
        // "(Simplified Chinese) Translation" / 「中文翻译」/ 「双语」etc.
        try! NSRegularExpression(
            pattern: #"\s*(?:[-–—]\s*|[\[(（【])(?:simplified chinese|traditional chinese|chinese|english|japanese|中文|日本語|日语|日語|简体中文|繁體中文|简体|繁體|简中|繁中)?\s*(?:translation|translated|翻译|翻譯|中译|中譯|译词|譯詞|双语|雙語|訳|訳詞)(?:\s*[\])）】])?\s*$"#,
            options: [.caseInsensitive])
    }()

    private static func text(_ value: String) -> String {
        value.lowercased().fRemovingNonLetters()
    }

    private static func title(_ value: String) -> String {
        let cleaned = translationSuffix.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        return text(ZhScript.convert(FLyricsTitle.search(cleaned), toSimplified: true))
    }

    static func select(_ candidates: [LRCLIBCandidate], _ query: FLyricsQuery,
                       _ original: FSpotifyLyrics, _ target: String) -> [String]? {
        guard original.isSynced else { return nil }
        let wanted = FLyricsLanguage.normalize(target)
        var best: [String]?
        var bestScore = -1
        for candidate in candidates {
            if candidate.instrumental || title(candidate.trackName) != title(query.title) {
                continue
            }
            let artist = FArtistMatch.compare(query.artist, candidate.artistName)
            if artist == .mismatch { continue }
            if query.durationMS > 0 && candidate.duration > 0,
               abs(candidate.duration * 1000 - Double(query.durationMS)) > 3000 {
                continue
            }
            var groups: [Int: [String]] = [:]
            for line in candidate.lines where !line.words.trimmingCharacters(in: .whitespaces).isEmpty {
                groups[line.startTimeMS, default: []].append(
                    line.words.trimmingCharacters(in: .whitespaces))
            }
            var result = [String](repeating: "", count: original.lines.count)
            var used = Set<Int>()
            var matched = 0, anchors = 0, nonEmpty = 0
            for (index, line) in original.lines.enumerated() {
                if text(line.words).isEmpty { continue }
                nonEmpty += 1
                let exact = groups[line.startTimeMS] != nil && !used.contains(line.startTimeMS)
                let times: [Int]
                if exact {
                    times = [line.startTimeMS]
                } else {
                    times = groups.keys.filter {
                        !used.contains($0) && abs($0 - line.startTimeMS) <= 350
                    }
                }
                // Ambiguous adjacent timestamps are safer to omit than guess.
                if times.count != 1 { continue }
                let time = times[0]
                let words = groups[time] ?? []
                let anchored = words.contains { text($0) == text(line.words) }
                let translated = words.filter {
                    text($0) != text(line.words) && targetText($0, wanted, candidate)
                }
                if translated.count != 1 { continue }
                used.insert(time)
                result[index] = translated[0]
                matched += 1
                if anchored { anchors += 1 }
            }
            if nonEmpty < 3 || matched < 3 || Double(matched) / Double(nonEmpty) < 0.8 { continue }
            let bilingual = Double(anchors) / Double(matched) >= 0.8
            if !bilingual {
                // Pure translated LRC requires a known artist/duration, full
                // alignment, and no extra sung lines (a different
                // edit/version must not slip in).
                if artist != .match || query.durationMS <= 0 || candidate.duration <= 0
                    || matched != nonEmpty || groups.count != nonEmpty
                    || groups.values.contains(where: { $0.count != 1 }) {
                    continue
                }
            }
            let tag = wanted.hasPrefix("zh") ? "zh" : (wanted == "ja" ? "und" : wanted)
            let language = FLyricsLanguage.of(tag, result.joined(separator: "\n"))
            if !FLyricsLanguage.matches(language, wanted) { continue }
            let scoreValue = matched + anchors * 2
            if scoreValue > bestScore {
                bestScore = scoreValue
                best = result
            }
        }
        return best
    }

    private static func targetText(_ text: String, _ target: String, _ candidate: LRCLIBCandidate) -> Bool {
        let counts = FScriptCounts(text)
        if target.hasPrefix("zh") {
            return counts[.han] > 0 && counts[.kana] == 0 && counts[.hangul] == 0
                && FLyricsLanguage.matches(FLyricsLanguage.chineseScript(text), target)
        }
        // Japanese lines can contain only kanji; the assembled translation
        // must still identify as Japanese (including kana), checked by the
        // caller.
        if target == "ja" {
            return counts[.hangul] == 0 && (counts[.kana] > 0 || counts[.han] > 0)
        }
        if target == "ko" { return counts[.hangul] > 0 }
        // Latin letters alone cannot distinguish English from other
        // languages or romanization: require an explicit translation label.
        if target == "en" {
            let metadata = "\(candidate.trackName)\n\(candidate.synced)"
            return fLyricLang(text) == .latin && englishLabel.firstMatch(
                in: metadata, range: NSRange(metadata.startIndex..., in: metadata)) != nil
        }
        return false
    }

    private static let englishLabel = try! NSRegularExpression(
        pattern: #"english\s+(?:translation|translated)|(?:translation|translated)\s*[:：]?\s*english|英译|英譯"#,
        options: [.caseInsensitive])
}

// MARK: - Disk cache (lyrics_disk_cache.dart)

/// Community lyric databases (LRCLIB, Netease, QQ) are rate limited: cache
/// responses on disk so a repeat play costs nothing. Keys embed a version so
/// a rule upgrade can invalidate old results. A generation counter lets a
/// global "refresh lyrics" invalidate in-flight writes.
actor LyricsDiskCache {
    /// Shared instance: one cache directory for the whole app.
    static let shared = LyricsDiskCache()

    private let directory: URL
    private var generation = 0

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Kumone/LyricsCache", isDirectory: true)
    }

    func read(_ key: String) -> String? {
        let url = directory.appendingPathComponent(safeName(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ key: String, _ lrc: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(safeName(key))
        try? lrc.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeName(key)))
    }

    func clear() {
        generation += 1
        try? FileManager.default.removeItem(at: directory)
    }

    /// File-system-safe key names.
    private func safeName(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
