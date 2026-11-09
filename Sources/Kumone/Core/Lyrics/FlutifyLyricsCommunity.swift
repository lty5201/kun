import Foundation

// MARK: - String helpers used by the alignment code

extension String {
    /// Lowercased with all non-letter/non-number characters removed
    /// (Flutify's `_normalize`).
    func fRemovingNonLetters() -> String {
        String(String.UnicodeScalarView(unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// True when the string has at least one letter or number.
    var fHasLetterOrNumber: Bool {
        unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - Netease models

/// One song from the Netease search result.
struct NeteaseSong {
    var id: Int
    var name: String
    /// Multiple artists joined with ", " (same as FLyricsQuery.artist).
    var artists: String
    var album: String
    var durationMS: Int

    static func from(json: [String: Any]) -> NeteaseSong? {
        guard let id = json["id"] as? Int,
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        let artists = ((json["artists"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ")
        let album = (json["album"] as? [String: Any])?["name"] as? String ?? ""
        let duration = json["duration"] as? Int ?? 0
        return NeteaseSong(id: id, name: name, artists: artists, album: album, durationMS: duration)
    }
}

/// A song's original + translation lyrics (LRC text; empty when absent).
struct NeteaseLyricBundle: Equatable {
    var lrc: String = ""
    var tlyric: String = ""

    func encode() -> String {
        let object: [String: String] = ["lrc": lrc, "tlyric": tlyric]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ raw: String) -> NeteaseLyricBundle? {
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return nil
        }
        return NeteaseLyricBundle(lrc: json["lrc"] ?? "", tlyric: json["tlyric"] ?? "")
    }
}

/// One Netease request outcome. `networkError` means offline / timeout /
/// rate-control / server error — the caller must not treat the miss as final.
struct NeteaseResponse<T> {
    var value: T?
    var networkError: Bool = false
}

// MARK: - Netease client

/// Netease Cloud Music public web endpoints (https://music.163.com), no login.
///
/// - `POST /api/search/get`: keyword song search (`type=1`).
/// - `GET /api/song/lyric`: `lrc` original LRC, `tlyric` community
///   translation LRC (timed; many foreign songs have one).
///
/// "Not found" and "request failed" are distinct: 404 / empty results are a
/// miss; offline / timeout / plain 5xx retry at most twice, then report a
/// network error. 429 / 503-with-Retry-After honor the server cooldown.
///
/// Rate control (a non-200 business code such as -460/-462, or HTTP 403) is
/// also a network error but is never retried: Netease judges by egress IP, an
/// immediate retry is rejected the same way. Requests pause for the cooldown.
actor NeteaseClient {
    static let cooldownSeconds: TimeInterval = 600
    static let timeout: TimeInterval = 10

    private var cooldownUntil: Date?
    private let rateLimit = FSharedCooldown()
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Kun (lyrics)",
        "Referer": "https://music.163.com",
    ]

    /// Shared instance so the cooldown is process-wide.
    static let shared = NeteaseClient()

    /// Searches songs; no hits is an empty list.
    func search(_ keyword: String, limit: Int = 6) async -> NeteaseResponse<[NeteaseSong]> {
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        for (key, value) in Self.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "s=\(fQuery(keyword))&type=1&limit=\(limit)"
        request.httpBody = Data(body.utf8)
        return await retry {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if await self.rateLimit.observe(http) {
                    return NeteaseResponse(value: nil, networkError: true)
                }
                if http.statusCode == 403 { return await self.blocked() }
                if http.statusCode >= 500 {
                    return NeteaseResponse(value: nil, networkError: true)
                }
                guard http.statusCode == 200 else {
                    return NeteaseResponse(value: nil)
                }
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return NeteaseResponse(value: [])
            }
            if Self.rejected(json) { return await self.blocked() }
            let songs = ((json["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
            return NeteaseResponse(value: songs.compactMap(NeteaseSong.from(json:)))
        }
    }

    /// Fetches a song's original / translation lyrics; a miss is an empty bundle.
    func lyric(songId: Int) async -> NeteaseResponse<NeteaseLyricBundle> {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songId)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "tv", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.timeout
        for (key, value) in Self.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return await retry {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if await self.rateLimit.observe(http) {
                    return NeteaseResponse(value: nil, networkError: true)
                }
                if http.statusCode == 403 { return await self.blocked() }
                if http.statusCode >= 500 {
                    return NeteaseResponse(value: nil, networkError: true)
                }
                guard http.statusCode == 200 else {
                    return NeteaseResponse(value: nil)
                }
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return NeteaseResponse(value: NeteaseLyricBundle())
            }
            if Self.rejected(json) { return await self.blocked() }
            func text(_ key: String) -> String {
                ((json[key] as? [String: Any])?["lyric"] as? String) ?? ""
            }
            return NeteaseResponse(value: NeteaseLyricBundle(lrc: text("lrc"), tlyric: text("tlyric")))
        }
    }

    /// A non-200 business code: Netease rate control (-460 / -462 …) still
    /// answers HTTP 200 with the error only in the JSON `code`.
    private static func rejected(_ json: [String: Any]) -> Bool {
        if let code = json["code"] as? Int, code != 200 { return true }
        return false
    }

    private func blocked<T>() -> NeteaseResponse<T> {
        cooldownUntil = Date().addingTimeInterval(Self.cooldownSeconds)
        return NeteaseResponse(value: nil, networkError: true)
    }

    private var coolingDown: Bool {
        cooldownUntil.map { $0 > Date() } ?? false
    }

    private func retry<T>(_ request: @escaping () async -> NeteaseResponse<T>) async -> NeteaseResponse<T> {
        var attempt = 0
        while true {
            // No requests during cooldown (including the case where another
            // request got rate-controlled while waiting for a retry).
            if coolingDown { return NeteaseResponse(value: nil, networkError: true) }
            let result = await request()
            // Freshly rate-controlled (cooldown already entered): no retry.
            if !result.networkError || attempt >= 2 || coolingDown { return result }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(600_000_000 * UInt64(attempt)))
        }
    }
}

// MARK: - Netease translation source

/// Chinese translations from Netease's community `tlyric` (timed); the
/// original stays with whatever source produced it.
///
/// Flow: cache hit aligns directly → otherwise search "title + primary
/// artist" → (re-search by title alone when nothing matches) → pick the song
/// by base-title equality, artist match, close duration → fetch `lrc` /
/// `tlyric` → align onto the current original lines.
///
/// Alignment (the Netease timeline belongs to its own lyrics and need not
/// match ours):
/// 1. Text anchoring: translation lines first stick to the Netease original
///    lines by time, then back onto our lines by text. A merged Netease line
///    can span up to three of our consecutive lines and is only split when
///    the translation separators are unambiguous. Repeated lines (chorus)
///    stick to the nearest occurrence: the global offset of the two
///    timelines is estimated from sentences appearing exactly once, then the
///    nearest match by corrected time is picked — a missing chorus does not
///    shift later translations.
/// 2. Time-neighbor fallback: unanchored translations stick to the nearest
///    still-empty original line within ±1.5 s (after offset correction).
/// 3. A match rate below 40% means the wrong song: give up entirely; a
///    foreign-language line left as-is never masquerades as a translation.
enum NeteaseTranslationSource {
    /// Minimum fraction of non-empty original lines that must match.
    static let minCoverage = 0.4

    /// Chinese originals skip translation: Netease Chinese songs almost
    /// never have a tlyric, and skipping saves two requests per track.
    static func needsTranslation(_ originals: [FLyricLine]) -> Bool {
        fLyricLang(TranslationMerge.originalText(originals)) != .zh
    }

    /// Cache key: the track ID first (repeated searches for the same song
    /// give the same result; alignment is recomputed on read).
    static func cacheKey(_ query: FLyricsQuery) -> String {
        query.trackId.isEmpty
            ? "netease|v3|\(query.title) \(query.artist)"
            : "netease|v3|\(query.trackId)"
    }

    /// Fetches the translation for `originals`; the returned lines are
    /// index-aligned with `originals` (empty string when untranslated).
    static func find(_ query: FLyricsQuery, _ originals: [FLyricLine],
                     client: NeteaseClient = .shared,
                     cache: LyricsDiskCache = .shared) async -> (lines: [FLyricLine]?, networkError: Bool) {
        if originals.isEmpty || !needsTranslation(originals) { return (nil, false) }
        let loaded = await loadBundle(query, client: client, cache: cache)
        guard let bundle = loaded.bundle else {
            return (nil, loaded.networkError)
        }
        if bundle.tlyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (nil, false)
        }
        guard let aligned = align(bundle.lrc, bundle.tlyric, originals) else {
            return (nil, false)
        }
        return (aligned, false)
    }

    /// Netease's own original (with translation): shares the cache with the
    /// translation lookup.
    static func findLyrics(_ query: FLyricsQuery,
                           client: NeteaseClient = .shared,
                           cache: LyricsDiskCache = .shared) async -> FLyricsLookup {
        if query.title.trimmingCharacters(in: .whitespaces).isEmpty { return FLyricsLookup(lyrics: nil) }
        let loaded = await loadBundle(query, client: client, cache: cache)
        guard let bundle = loaded.bundle else {
            return FLyricsLookup(lyrics: nil, networkError: loaded.networkError)
        }
        return FLyricsLookup(
            lyrics: CommunityLyrics.build(lrc: bundle.lrc, tlyric: bundle.tlyric, provider: "music.163.com"))
    }

    /// Reads the cache, otherwise searches, fetches, and writes; a nil bundle
    /// means no usable result.
    static func loadBundle(_ query: FLyricsQuery, client: NeteaseClient, cache: LyricsDiskCache)
        async -> (bundle: NeteaseLyricBundle?, networkError: Bool) {
        let key = cacheKey(query)
        if let raw = await cache.read(key), let cached = NeteaseLyricBundle.decode(raw) {
            return (cached, false)
        }
        let song = await findSong(query, client: client)
        guard let found = song.value else {
            // A search that found nothing is also a definitive result (an
            // empty bundle is cached); network errors are not cached.
            if !song.networkError {
                await cache.write(key, NeteaseLyricBundle().encode())
            }
            return (nil, song.networkError)
        }
        let lyric = await client.lyric(songId: found.id)
        guard let bundle = lyric.value else {
            return (nil, lyric.networkError)
        }
        // "This song has no translation" is also definitive and gets cached.
        await cache.write(key, bundle.encode())
        return (bundle, false)
    }

    /// Song picking: exact title equality (Netease names usually carry no
    /// version suffix), every artist compared, duration within 5 s when both
    /// sides have one.
    private static func findSong(_ query: FLyricsQuery, client: NeteaseClient)
        async -> NeteaseResponse<NeteaseSong> {
        var networkError = false
        var first = true
        func search(_ keyword: String) async -> NeteaseResponse<[NeteaseSong]> {
            if !first { try? await Task.sleep(nanoseconds: 300_000_000) }
            first = false
            let response = await client.search(keyword)
            networkError = networkError || response.networkError
            return response
        }

        let title = baseTitle(query.title)
        var songs = (await search("\(title) \(query.primaryArtist)")).value ?? []
        // Re-searching by title alone is for the "found nothing" case: when
        // the first search hit a network error, re-searching is pointless.
        if pickSong(songs, query) == nil && !networkError {
            songs = (await search(title)).value ?? []
        }
        let pick = pickSong(songs, query)
        return NeteaseResponse(value: pick, networkError: pick == nil && networkError)
    }

    private static let versionWord = try! NSRegularExpression(
        pattern: #"\b(?:feat|ft|with|remaster\w*|live|version|ver|edit|re-?mix|mix|mono|stereo|acoustic|unplugged|from|deluxe|radio|explicit|clean|bonus|demo|single|album|extended|session)\b"#,
        options: [.caseInsensitive])
    private static let dashSuffix = try! NSRegularExpression(pattern: #"\s+[-–—]\s+(.+)$")
    private static let bracketed = try! NSRegularExpression(
        pattern: #"\s*[\(\[（【]([^\)\]）】]*)[\)\]）】]"#)

    /// The title without version suffixes (case preserved, used for search):
    /// " - xxx" suffixes and bracketed segments are dropped only when they
    /// contain a version marker; "Lemon（Cover 米津玄师）" / "（伴奏）" are
    /// different lyrics and stay — they simply won't match at picking time.
    static func baseTitle(_ title: String) -> String {
        var text = FLyricsTitle.search(title)
        if let dash = dashSuffix.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) {
            let suffix = (text as NSString).substring(with: dash.range(at: 1))
            if versionWord.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) != nil {
                text = (text as NSString).substring(to: dash.range.location)
            }
        }
        var rebuilt = ""
        var cursor = text.startIndex
        for match in bracketed.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let innerRange = Range(match.range(at: 1), in: text) else { continue }
            let inner = String(text[innerRange])
            let drop = versionWord.firstMatch(
                in: inner, range: NSRange(inner.startIndex..., in: inner)) != nil
            rebuilt += text[cursor..<whole.lowerBound]
            if !drop {
                rebuilt += text[whole]
            }
            cursor = whole.upperBound
        }
        rebuilt += text[cursor...]
        text = rebuilt
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title.trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// Picks the right song out of search results; nil when nothing is
    /// confident (a wrong-song translation is worse than none).
    /// Base-title equality is enough (remix / live versions are told apart
    /// by duration); exact equality first, original version next.
    static func pickSong(_ songs: [NeteaseSong], _ query: FLyricsQuery) -> NeteaseSong? {
        let wanted = baseTitle(query.title).lowercased()
        var best: NeteaseSong?
        var bestScore = -1
        for song in songs {
            guard baseTitle(song.name).lowercased() == wanted else { continue }
            let artistMatch = FArtistMatch.compare(query.artist, song.artists)
            // A comparable but mismatched artist: another song with the same
            // name (same standard as the LRCLIB selector).
            if artistMatch == .mismatch { continue }
            var score = 0
            if song.name.trimmingCharacters(in: .whitespaces).lowercased()
                == query.title.trimmingCharacters(in: .whitespaces).lowercased() {
                score = 2
            } else if baseTitle(song.name) == song.name.trimmingCharacters(in: .whitespaces) {
                score = 1
            }
            if artistMatch == .match { score += 4 }
            if query.durationMS > 0 && song.durationMS > 0 {
                if abs(song.durationMS - query.durationMS) > 5000 { continue }
                score += 2
            }
            if score > bestScore {
                bestScore = score
                best = song
            }
        }
        return best
    }

    /// Aligns the Netease `tlyric` onto our original lines; nil when the
    /// match is too thin or there is no real translation. The result is
    /// index-aligned with `originals` (empty string for untranslated lines,
    /// including the interlude empty lines in the original).
    static func align(_ lrc: String, _ tlyric: String, _ originals: [FLyricLine]) -> [FLyricLine]? {
        let refLines = FLrcParser.parse(lrc)
        let transLines = FLrcParser.parse(tlyric)
            .filter { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Non-empty original lines and their indexes into `originals`.
        let originalIdx = originals.indices.filter {
            !$0.words.fRemovingNonLetters().isEmpty
        }
        let originalLines = originalIdx.map { originals[$0] }
        if transLines.isEmpty || originalLines.isEmpty { return nil }

        var attached: [Int: String] = [:] // originalLines index → translation
        var usedOriginals = Set<Int>()
        var usedTrans = Set<Int>()

        // 1. Text anchoring: translation → (same time bucket) → Netease
        //    original → (same text) → our original.
        struct Span {
            var start: Int
            var end: Int
        }
        var byText: [String: [Span]] = [:]
        for i in originalLines.indices {
            var joined = ""
            // Only across genuinely adjacent, close-in-time originals —
            // never across empty lines / interludes, and never whole verses.
            var end = i
            while end < originalLines.count && end < i + 3 {
                if originalIdx[end] != originalIdx[i] + end - i
                    || originalLines[end].startTimeMS - originalLines[i].startTimeMS > 10000 {
                    break
                }
                joined += originalLines[end].words.fRemovingNonLetters()
                byText[joined, default: []].append(Span(start: i, end: end))
                end += 1
            }
        }
        // The Netease original of a translation line shares its 0.5 s time
        // bucket.
        let refTexts: [[String]] = transLines.map { trans in
            refLines.compactMap { ref in
                guard (Int(round(Double(ref.startTimeMS) / 500)) == Int(round(Double(trans.startTimeMS) / 500)))
                    && !ref.words.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return ref.words.fRemovingNonLetters()
            }
        }

        // The global offset of the two timelines (ours − Netease's): the
        // median over sentences appearing exactly once; choruses are then
        // matched by corrected nearest time.
        var deltas: [Int] = []
        for (ti, trans) in transLines.enumerated() {
            for text in refTexts[ti] {
                if let spans = byText[text], spans.count == 1 {
                    deltas.append(originalLines[spans[0].start].startTimeMS - trans.startTimeMS)
                }
            }
        }
        deltas.sort()
        let offset = deltas.isEmpty ? 0 : deltas[deltas.count / 2]

        for (ti, trans) in transLines.enumerated() {
            let expected = trans.startTimeMS + offset
            for text in refTexts[ti] {
                var best: Span?
                for span in byText[text] ?? [] {
                    if (span.start...span.end).contains(where: { usedOriginals.contains($0) }) {
                        continue
                    }
                    if best == nil || abs(originalLines[span.start].startTimeMS - expected)
                        < abs(originalLines[best!.start].startTimeMS - expected) {
                        best = span
                    }
                }
                guard let best else { continue }
                usedTrans.insert(ti)
                let parts = splitTranslation(
                    trans.words, Array(originalLines[best.start...best.end]))
                for i in best.start...best.end {
                    // Including untranslated English fragments: this position
                    // is matched and must not be taken by the time fallback.
                    usedOriginals.insert(i)
                    attached[i] = parts[i - best.start]
                }
                break
            }
        }

        // 2. Time-neighbor fallback: the nearest unused original line within
        //    ±1500 ms after offset correction.
        for (ti, trans) in transLines.enumerated() where !usedTrans.contains(ti) {
            var best = -1
            var bestDelta = 1501
            for i in originalLines.indices where !usedOriginals.contains(i) {
                let delta = abs(originalLines[i].startTimeMS - trans.startTimeMS - offset)
                if delta < bestDelta {
                    bestDelta = delta
                    best = i
                }
            }
            if best >= 0 {
                usedOriginals.insert(best)
                usedTrans.insert(ti)
                attached[best] = translatedText(trans.words, originalLines[best].words)
            }
        }

        if Double(usedOriginals.count) < Double(originalLines.count) * minCoverage
            || attached.values.allSatisfy({ $0.isEmpty }) {
            return nil
        }
        var byOriginal: [Int: String] = [:]
        for (key, value) in attached {
            byOriginal[originalIdx[key]] = value
        }
        return originals.enumerated().map { index, line in
            FLyricLine(startTimeMS: line.startTimeMS, words: byOriginal[index] ?? "")
        }
    }

    /// tlyric is a Chinese community translation; a foreign language left
    /// as-is or pure romaji is not a Chinese translation.
    static func translatedText(_ text: String, _ original: String) -> String {
        FScriptCounts(text)[.han] > 0 && text.fRemovingNonLetters() != original.fRemovingNonLetters()
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    private static let clauseBreak = try! NSRegularExpression(
        pattern: #"[\s　，,。！？!?；;／/|]+"#)
    private static let edgePunctuation = try! NSRegularExpression(
        pattern: #"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$"#, options: [.useUnicodeWordBoundaries])

    static func splitTranslation(_ text: String, _ originals: [FLyricLine]) -> [String] {
        var result = [String](repeating: "", count: originals.count)
        var start = 0
        var end = originals.count - 1
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Untranslated English inside a merged line often sits at the head or
        // tail. Prove the boundary with the original text first, so English
        // is not split word by word and the next English line is not left
        // under the previous Chinese one.
        while start < end {
            if let afterHead = removeCopiedEdge(remaining, originals[start].words) {
                remaining = afterHead
                start += 1
                continue
            }
            guard let beforeTail = removeCopiedEdge(remaining, originals[end].words, tail: true) else {
                break
            }
            remaining = beforeTail
            end -= 1
        }
        if start == end {
            result[start] = translatedText(remaining, originals[start].words)
            return result
        }
        let range = NSRange(remaining.startIndex..., in: remaining)
        let clauses = clauseBreak.matches(in: remaining, range: range)
            .compactMap { Range($0.range, in: remaining) }
        var parts: [String] = []
        var cursor = remaining.startIndex
        for matchRange in clauses {
            parts.append(String(remaining[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        parts.append(String(remaining[cursor...]))
        let filtered = parts.filter { !$0.fRemovingNonLetters().isEmpty }
        if filtered.count == end - start + 1
            && filtered.allSatisfy({ FScriptCounts($0)[.han] > 0 }) {
            for i in start...end {
                result[i] = translatedText(filtered[i - start], originals[i].words)
            }
        } else {
            // No unambiguous separators: keep the full translated sentence,
            // never split by character count or invent translations.
            result[start] = translatedText(remaining, originals[start].words)
        }
        return result
    }

    static func removeCopiedEdge(_ text: String, _ original: String, tail: Bool = false) -> String? {
        let needle = original.fRemovingNonLetters()
        let normalized = text.fRemovingNonLetters()
        if needle.isEmpty
            || !(tail ? normalized.hasSuffix(needle) : normalized.hasPrefix(needle)) {
            return nil
        }
        let letters = text.rangesOfLetters()
        let count = original.rangesOfLetters().count
        if count == 0 || count > letters.count { return nil }
        let cutIndex: String.Index
        if tail {
            cutIndex = letters[letters.count - count].lowerBound
        } else {
            cutIndex = letters[count - 1].upperBound
        }
        // "Oh（哦）" is an original word with a translation note, not an
        // untranslated "Oh": keep the whole phrase.
        let before = String(text[text.startIndex..<cutIndex])
        let after = String(text[cutIndex...])
        if tail ? openingBracket.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil
            : openingBracketAtStart.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil {
            return nil
        }
        // A word suffix ("art" inside "heart") is not an untranslated
        // original word.
        if cutIndex > text.startIndex && cutIndex < text.endIndex {
            let before = text.index(before: cutIndex)
            let left = text[before].unicodeScalars.first.flatMap { fScriptOf($0.value) }
            let right = text[cutIndex].unicodeScalars.first.flatMap { fScriptOf($0.value) }
            if left != nil && left == right { return nil }
        }
        let copied = tail ? String(text[cutIndex...]) : String(text[text.startIndex..<cutIndex])
        if copied.fRemovingNonLetters() != needle { return nil }
        let kept = tail ? String(text[text.startIndex..<cutIndex]) : String(text[cutIndex...])
        let trimmed = edgePunctuation.stringByReplacingMatches(
            in: kept, range: NSRange(kept.startIndex..., in: kept), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    private static let openingBracket = try! NSRegularExpression(pattern: #"[（(【\[]\s*$"#)
    private static let openingBracketAtStart = try! NSRegularExpression(pattern: #"^\s*[（(【\[]"#)
}

extension String {
    /// Ranges of individual letter/number characters, in order (Flutify's
    /// `_letters` matches).
    func rangesOfLetters() -> [Range<String.Index>] {
        FRegex.letters.matches(in: self, range: NSRange(startIndex..., in: self))
            .compactMap { Range($0.range, in: self) }
    }
}

enum FRegex {
    static let letters = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]"#)
}

// MARK: - QQ Music client

/// One song from QQ Music.
struct QQMusicSong {
    var id: Int
    var title: String
    var artists: String
    var durationMS: Int
    var songType: Int

    static func from(json: [String: Any], detail: Bool = false) -> QQMusicSong? {
        let rawId = json["id"] ?? json["songid"]
        let id = (rawId as? Int) ?? (rawId as? String).flatMap(Int.init)
        guard let title = (json["title"] ?? json["name"]) as? String,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let singer = json["singer"]
        let artists: String
        if let single = singer as? String {
            artists = single
        } else if let list = singer as? [[String: Any]] {
            artists = list.compactMap { $0["name"] as? String }.joined(separator: ", ")
        } else {
            artists = ""
        }
        if artists.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        guard let id, id > 0 else { return nil }
        let interval = json["interval"] as? Int
        let type = json["type"] as? Int
        if detail && (interval == nil || interval! <= 0 || type == nil || type! < 0) {
            return nil
        }
        return QQMusicSong(
            id: id, title: title, artists: artists,
            durationMS: (interval ?? 0) * 1000,
            songType: type ?? 0)
    }
}

/// A song's original + translation lyrics from QQ Music.
struct QQMusicLyrics: Equatable {
    var lrc: String = ""
    var tlyric: String = ""

    func encode() -> String {
        let object: [String: String] = ["lrc": lrc, "tlyric": tlyric]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ raw: String) -> QQMusicLyrics? {
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return nil
        }
        return QQMusicLyrics(lrc: json["lrc"] ?? "", tlyric: json["tlyric"] ?? "")
    }
}

/// A confirmed miss differs from an unavailable/malformed response: only the
/// former may be cached. Requests never use account credentials.
struct QQMusicResult<T> {
    var value: T?
    var networkError: Bool = false
}

/// QQ Music public endpoints; anonymous requests only. A 403 or a non-zero
/// response code blocks the client for one minute. Response size and total
/// request time are bounded; redirects are rejected; no immediate retries.
actor QQMusicClient {
    static let requestTimeout: TimeInterval = 3
    static let maxResponseBytes = 512 * 1024

    private var blockedUntil: Date?
    private let rateLimit = FSharedCooldown()

    /// Shared instance so the cooldown is process-wide.
    static let shared = QQMusicClient()

    func search(_ keyword: String) async -> QQMusicResult<[QQMusicSong]> {
        var components = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        components.queryItems = [
            URLQueryItem(name: "key", value: keyword),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let data = await request("GET", components.url!) else {
            return QQMusicResult(value: nil, networkError: true)
        }
        let result = (data["data"] as? [String: Any])
        let category = result?["song"] as? [String: Any]
        let songs = (category?["itemlist"] as? [[String: Any]]) ?? []
        if songs.isEmpty && (category?["itemlist"] == nil) {
            return QQMusicResult(value: nil, networkError: true)
        }
        let parsed = songs.prefix(10).compactMap { QQMusicSong.from(json: $0) }
        if !songs.isEmpty && parsed.isEmpty {
            return QQMusicResult(value: nil, networkError: true)
        }
        return QQMusicResult(value: parsed)
    }

    func detail(songId: Int) async -> QQMusicResult<QQMusicSong> {
        let data = await rpc("music.pf_song_detail_svr", "get_song_detail_yqq", ["song_id": songId])
        let trackInfo = data.flatMap { $0["track_info"] as? [String: Any] }
        guard let song = trackInfo.flatMap({ QQMusicSong.from(json: $0, detail: true) }),
              song.id == songId else {
            return QQMusicResult(value: nil, networkError: true)
        }
        return QQMusicResult(value: song)
    }

    func lyric(songId: Int, songType: Int = 0) async -> QQMusicResult<QQMusicLyrics> {
        // crypt=0 returns Base64 LRC, avoiding the encrypted QRC format
        // entirely.
        let data = await rpc("music.musichallSong.PlayLyricInfo", "GetPlayLyricInfo", [
            "songId": songId, "type": songType, "crypt": 0,
            "qrc": 0, "qrc_t": 0, "lrc_t": 0, "trans": 1, "trans_t": 0,
            "roma": 0, "roma_t": 0,
        ] as [String: Any])
        func decode(_ value: Any?) -> String {
            guard let value = value as? String,
                  let data = Data(base64Encoded: value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard let data, data["lyric"] is String, data["trans"] is String else {
            return QQMusicResult(value: nil, networkError: true)
        }
        return QQMusicResult(value: QQMusicLyrics(
            lrc: decode(data["lyric"]),
            tlyric: decode(data["trans"])))
    }

    private func rpc(_ module: String, _ method: String, _ param: [String: Any]) async -> [String: Any]? {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0, "format": "json", "uin": 0],
            "request": ["module": module, "method": method, "param": param],
        ]
        let json = await request("POST", URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: body)
        guard let response = json?["request"] as? [String: Any] else { return nil }
        if let code = response["code"] as? Int, code != 0 {
            blockedUntil = Date().addingTimeInterval(60)
        }
        guard (response["code"] as? Int) == 0, let data = response["data"] as? [String: Any] else {
            return nil
        }
        return data
    }

    /// Bounded, timed, redirect-rejecting request; no immediate retries.
    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil) async -> [String: Any]? {
        if await rateLimit.active() || (blockedUntil.map { $0 > Date() } ?? false) {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Mozilla/5.0 Kun (lyrics translation)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if await rateLimit.observe(http) { return nil }
                if http.statusCode == 403 {
                    blockedUntil = Date().addingTimeInterval(60)
                    return nil
                }
                guard http.statusCode == 200 else { return nil }
            }
            guard data.count <= Self.maxResponseBytes,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            if let code = json["code"] as? Int, code != 0 {
                blockedUntil = Date().addingTimeInterval(60)
                return nil
            }
            return json
        } catch {
            return nil
        }
    }
}

// MARK: - QQ translation source

/// Anonymous Chinese translations only; never replaces the original lyrics.
/// Quick search is followed by a detail check because its candidates lack
/// duration and song type. Source LRC text must also match the original lines.
enum QQTranslationSource {
    static func cacheKey(_ query: FLyricsQuery) -> String {
        query.trackId.isEmpty
            ? "qqmusic|v2|\(query.title) \(query.artist) \(query.durationMS)"
            : "qqmusic|v2|\(query.trackId)"
    }

    static func find(_ query: FLyricsQuery, _ originals: [FLyricLine],
                     client: QQMusicClient = .shared,
                     cache: LyricsDiskCache = .shared) async -> (lines: [FLyricLine]?, networkError: Bool) {
        if originals.isEmpty
            || query.title.trimmingCharacters(in: .whitespaces).isEmpty
            || query.artist.trimmingCharacters(in: .whitespaces).isEmpty
            || !NeteaseTranslationSource.needsTranslation(originals) {
            return (nil, false)
        }
        let loaded = await loadBundle(query, client: client, cache: cache)
        guard let bundle = loaded.bundle else {
            return (nil, loaded.networkError)
        }
        if bundle.tlyric.isEmpty || !hasTextAnchors(bundle.lrc, originals) {
            return (nil, false)
        }
        // The shared alignment handles offsets, repeated choruses, and
        // duplicate timestamps. QQ adds a text-overlap gate so timing alone
        // cannot match a song.
        guard let lines = NeteaseTranslationSource.align(bundle.lrc, bundle.tlyric, originals),
              FLyricsLanguage.of("und", lines.map(\.words).joined(separator: "\n")).hasPrefix("zh") else {
            return (nil, false)
        }
        return (lines, false)
    }

    /// QQ Music's own original (with translation): shares the cache with the
    /// translation lookup.
    static func findLyrics(_ query: FLyricsQuery,
                           client: QQMusicClient = .shared,
                           cache: LyricsDiskCache = .shared) async -> FLyricsLookup {
        if query.title.trimmingCharacters(in: .whitespaces).isEmpty
            || query.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            return FLyricsLookup(lyrics: nil)
        }
        let loaded = await loadBundle(query, client: client, cache: cache)
        guard let bundle = loaded.bundle else {
            return FLyricsLookup(lyrics: nil, networkError: loaded.networkError)
        }
        return FLyricsLookup(
            lyrics: CommunityLyrics.build(lrc: bundle.lrc, tlyric: bundle.tlyric, provider: "y.qq.com"))
    }

    private static func loadBundle(_ query: FLyricsQuery, client: QQMusicClient, cache: LyricsDiskCache)
        async -> (bundle: QQMusicLyrics?, networkError: Bool) {
        let key = cacheKey(query)
        if let raw = await cache.read(key), let cached = QQMusicLyrics.decode(raw) {
            return (cached, false)
        }
        let result = await findBundle(query, client: client)
        if result.networkError || result.value == nil {
            return (nil, result.networkError)
        }
        await cache.write(key, result.value!.encode())
        return (result.value!, false)
    }

    private static func findBundle(_ query: FLyricsQuery, client: QQMusicClient)
        async -> QQMusicResult<QQMusicLyrics> {
        let title = NeteaseTranslationSource.baseTitle(query.title)
        var candidate: QQMusicSong?
        for keyword in ["\(title) \(query.primaryArtist)".trimmingCharacters(in: .whitespaces), title] {
            let found = await client.search(keyword)
            if found.networkError { return QQMusicResult(value: nil, networkError: true) }
            var matched = (found.value ?? []).filter { Self.matches($0, query) }
            // Prefer a matching artist, then the exact requested version over
            // a normalized Live/Remix title. Smartbox itself has no duration.
            matched.sort { Self.rank($0, query) > Self.rank($1, query) }
            if let first = matched.first {
                candidate = first
                break
            }
        }
        guard let candidate else { return QQMusicResult(value: QQMusicLyrics()) }
        let detail = await client.detail(songId: candidate.id)
        guard let song = detail.value else {
            return QQMusicResult(value: nil, networkError: true)
        }
        if !matches(song, query)
            || (query.durationMS > 0 && abs(song.durationMS - query.durationMS) > 5000) {
            return QQMusicResult(value: QQMusicLyrics())
        }
        return await client.lyric(songId: song.id, songType: song.songType)
    }

    static func rank(_ song: QQMusicSong, _ query: FLyricsQuery) -> Int {
        let artist = FArtistMatch.compare(query.artist, song.artists) == .match ? 4 : 0
        let title: Int
        if song.title.trimmingCharacters(in: .whitespaces).lowercased()
            == query.title.trimmingCharacters(in: .whitespaces).lowercased() {
            title = 2
        } else if NeteaseTranslationSource.baseTitle(song.title) == song.title.trimmingCharacters(in: .whitespaces) {
            title = 1
        } else {
            title = 0
        }
        return artist + title
    }

    static func matches(_ song: QQMusicSong, _ query: FLyricsQuery) -> Bool {
        NeteaseTranslationSource.baseTitle(song.title).lowercased()
            == NeteaseTranslationSource.baseTitle(query.title).lowercased()
            && FArtistMatch.compare(query.artist, song.artists) != .mismatch
    }

    static func hasTextAnchors(_ lrc: String, _ originals: [FLyricLine]) -> Bool {
        let reference = Set(FLrcParser.parse(lrc)
            .map { $0.words.fRemovingNonLetters() }
            .filter { !$0.isEmpty })
        let texts = originals.map { $0.words.fRemovingNonLetters() }
        let count = texts.filter { !$0.isEmpty }.count
        var anchored = Set<Int>()
        for start in texts.indices {
            var joined = ""
            // Match the same bounded, adjacent spans the alignment accepts.
            // Do not join across interludes or allow timestamps alone to
            // identify a song.
            var end = start
            while end < texts.count && end < start + 3 {
                if texts[end].isEmpty
                    || originals[end].startTimeMS - originals[start].startTimeMS > 10000 {
                    break
                }
                joined += texts[end]
                if reference.contains(joined) {
                    for i in start...end { anchored.insert(i) }
                }
                end += 1
            }
        }
        return count > 0 && Double(anchored.count) >= Double(count) * 0.4
    }
}

// MARK: - Community lyrics builder (community_lyrics.dart)

/// Builds a synced-lyrics result from a community source's LRC original and
/// tlyric translation (QQ Music / Netease).
enum CommunityLyrics {
    private static let credit = try! NSRegularExpression(
        pattern: #"^\s*(作词|作曲|编曲|制作人?|词|曲|混音|母带|录音|监制|和声|Lyrics?|Composer|Arranger|Producer|Written by)\s*[:：]"#,
        options: [.caseInsensitive])

    /// Minimum non-empty lines to treat text as lyrics (filters "纯音乐，请欣赏").
    static let minLines = 4

    static func build(lrc: String, tlyric: String, provider: String) -> FSpotifyLyrics? {
        let allLines = FLrcParser.parse(lrc)
        let lines = allLines.filter {
            !($0.startTimeMS <= 30000 && credit.firstMatch(
                in: $0.words, range: NSRange($0.words.startIndex..., in: $0.words)) != nil)
        }
        if lines.filter({ !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count < minLines {
            return nil
        }
        let text = TranslationMerge.originalText(lines)
        let lang = fLyricLang(text)
        var translated: [FLyricLine]?
        if !tlyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lang != .zh {
            translated = NeteaseTranslationSource.align(lrc, tlyric, lines)
            if let translated,
               !FLyricsLanguage.of("und", translated.map(\.words).joined(separator: "\n")).hasPrefix("zh") {
                translated = nil
            }
        }
        return FSpotifyLyrics(
            syncType: "LINE_SYNCED",
            language: lang == .zh ? "zh" : (lang == .ja ? "ja" : (lang == .ko ? "ko" : "und")),
            provider: provider,
            translationProvider: translated == nil ? nil : provider,
            lines: lines.enumerated().map { index, line in
                FLyricLine(startTimeMS: line.startTimeMS, words: line.words,
                           translation: translated.flatMap { index < $0.count ? $0[index].words : "" })
            })
    }
}
