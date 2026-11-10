import Foundation

/// The lyrics pipeline entry point: Flutify's lyrics system ported to Kumone.
///
/// Source order for originals (Flutify's default, minus Spotify): LRCLIB
/// first — it is a dedicated lyrics database — then QQ Music and Netease as
/// community fallbacks. The first source returning line-synced lyrics wins;
/// later sources are not requested.
///
/// Translations: when 「显示歌词翻译」 is on, foreign-language originals are
/// prefetched with a Chinese translation (QQ first, Netease as backup,
/// LRCLIB bilingual records last). Chinese originals skip translation —
/// Netease Chinese songs almost never have a tlyric.
///
/// Query inputs (title, artists) are sent to whichever source is actually
/// queried. A network failure is never cached: the next open retries.
actor FlutifyLyricsService {
    static let shared = FlutifyLyricsService()

    /// What the player needs from one resolve.
    struct ResolvedLyrics {
        /// Kumone's lyric model, ready for the UI.
        var parsed: ParsedLyrics
        /// The raw LRC of the original (for the AutoMix sidecar).
        var rawLRC: String?
    }

    private let lrclib = LRCLIBClient()
    private let cache = LyricsDiskCache.shared

    /// Recent candidate responses (10 minutes), so the translation pass
    /// after an original resolve does not re-query LRCLIB.
    private var recent: [String: (at: Date, response: FLyricsResponse)] = [:]

    private init() {}

    /// Resolves lyrics (with translation prefetch) for a track.
    func resolve(track: Track) async -> ResolvedLyrics? {
        let query = FLyricsQuery(track: track)
        guard !query.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // 1. Original: LRCLIB → QQ Music → Netease, first line-synced hit wins.
        guard var lyrics = await resolveOriginal(query) else { return nil }

        // 2. Optional Chinese translation prefetch for foreign originals.
        let translationEnabled = await MainActor.run {
            SettingsManager.shared.showLyricsTranslation
        }
        if translationEnabled {
            if let translated = await attachTranslation(query, lyrics) {
                lyrics = translated
            }
        }

        return ResolvedLyrics(
            parsed: FlutifyLyricsService.parsed(from: lyrics),
            rawLRC: originalLRC(for: lyrics))
    }

    /// Resolves only the original, without the translation prefetch
    /// (used where the caller manages translations itself).
    func resolveOriginalLyrics(track: Track) async -> ResolvedLyrics? {
        let query = FLyricsQuery(track: track)
        guard !query.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let lyrics = await resolveOriginal(query) else { return nil }
        return ResolvedLyrics(
            parsed: FlutifyLyricsService.parsed(from: lyrics),
            rawLRC: originalLRC(for: lyrics))
    }

    // MARK: - Original resolution

    private func resolveOriginal(_ query: FLyricsQuery) async -> FSpotifyLyrics? {
        // LRCLIB: exact get, then searches; cached by track.
        if let found = await findLrclib(query) {
            return found
        }
        // QQ Music: original + translation in one bundle.
        let qqLookup = await QQTranslationSource.findLyrics(query)
        if let lyrics = qqLookup.lyrics, lyrics.isSynced { return lyrics }
        // Netease.
        let neteaseLookup = await NeteaseTranslationSource.findLyrics(query)
        if let lyrics = neteaseLookup.lyrics, lyrics.isSynced { return lyrics }
        return nil
    }

    private func findLrclib(_ query: FLyricsQuery) async -> FSpotifyLyrics? {
        if query.title.trimmingCharacters(in: .whitespaces).isEmpty { return nil }

        let key = "v5|\(query.trackId)"
        // Cache hit: parse and split any embedded bilingual pairs again.
        if let hit = await cache.read(key) {
            let lines = TranslationMerge.tryMerge(FLrcParser.parse(hit))
            if let lines, !lines.isEmpty {
                return lyrics(fromLines: lines)
            }
        }

        let response = await collectLrclibCandidates(query)
        guard let selection = LRCLIBSelector.select(response.candidates, query) else {
            return nil
        }
        let lines = FLrcParser.parse(selection.synced)
        if lines.isEmpty { return nil }
        await cache.write(key, selection.synced)
        return lyrics(fromLines: TranslationMerge.tryMerge(lines) ?? lines,
                      lang: selection.lang)
    }

    /// Query plan (ported from Flutify's LrclibLyricsSource, candidates stop
    /// early): exact get → title + primary artist search → title-only search
    /// (when fewer than 4 candidates) → full-text `q` search including the
    /// opposite script variant of the title (when fewer than 3 candidates).
    private func collectLrclibCandidates(_ query: FLyricsQuery) async -> FLyricsResponse {
        var candidates: [LRCLIBCandidate] = []
        var networkError = false
        var first = true
        func gap() async {
            if !first {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            first = false
        }

        let title = FLyricsTitle.search(query.title)

        await gap()
        let exact = await lrclib.get(
            track: query.title, artist: query.artist, album: query.album,
            durationSec: Int((Double(query.durationMS) / 1000.0).rounded()))
        networkError = networkError || exact.networkError
        candidates += exact.candidates
        if networkError { return FLyricsResponse(candidates: candidates, networkError: true) }

        await gap()
        let byArtist = await lrclib.search(track: title, artist: query.primaryArtist)
        networkError = networkError || byArtist.networkError
        candidates += byArtist.candidates
        if networkError { return FLyricsResponse(candidates: candidates, networkError: true) }

        // Translated records can live beside an already plentiful set of
        // originals.
        await gap()
        let byTitle = await lrclib.search(track: title)
        networkError = networkError || byTitle.networkError
        candidates += byTitle.candidates
        if networkError { return FLyricsResponse(candidates: candidates, networkError: true) }

        if candidates.count < 3 {
            let altTitle: String?
            if fDetectLang("\(title) \(query.artist)") == .zh {
                let wantHant = LRCLIBSelector.wantsTraditional(query)
                let converted = ZhScript.convert(title, toSimplified: !wantHant)
                altTitle = converted != title ? converted : nil
            } else {
                altTitle = nil
            }
            var queries: [String] = []
            if !query.primaryArtist.isEmpty {
                queries.append("\(title) \(query.primaryArtist)")
            }
            queries.append(title)
            if let altTitle { queries.append(altTitle) }
            for q in queries {
                if candidates.count >= 3 { break }
                await gap()
                let result = await lrclib.search(q: q)
                networkError = networkError || result.networkError
                candidates += result.candidates
                if networkError { break }
            }
        }

        return FLyricsResponse(candidates: candidates, networkError: networkError)
    }

    private func lyrics(fromLines lines: [FLyricLine], lang: FLyricLang? = nil) -> FSpotifyLyrics {
        let language = lang ?? fLyricLang(TranslationMerge.originalText(lines))
        return FSpotifyLyrics(
            syncType: "LINE_SYNCED",
            language: language == .zh ? "zh" : (language == .ja ? "ja" : (language == .ko ? "ko" : "und")),
            provider: "lrclib.net",
            lines: lines)
    }

    private func originalLRC(for lyrics: FSpotifyLyrics) -> String? {
        // Reconstruct a plain LRC from the resolved lines (the sidecar only
        // needs text + timeline).
        guard !lyrics.lines.isEmpty else { return nil }
        return lyrics.lines.map {
            let minutes = $0.startTimeMS / 60000
            let seconds = Double($0.startTimeMS % 60000) / 1000.0
            return String(format: "[%02d:%05.2f]%@", minutes, seconds, $0.words)
        }.joined(separator: "\n")
    }

    // MARK: - Translation prefetch

    /// Adds a Chinese translation to a foreign-language original. Complete
    /// embedded translations are kept as-is; partial ones are only replaced
    /// by a more complete source that loses no lines.
    private func attachTranslation(_ query: FLyricsQuery, _ lyrics: FSpotifyLyrics) async -> FSpotifyLyrics? {
        guard lyrics.isSynced, !lyrics.lines.isEmpty else { return nil }
        // Preload only adds Chinese translations to foreign originals.
        let body = lyrics.lines.map(\.words).joined(separator: "\n")
        if FLyricsLanguage.of("und", body).hasPrefix("zh") { return nil }

        let inline = lyrics.lines.map(\.translation).map { $0 ?? "" }
        if inline.allSatisfy({ !$0.isEmpty }) { return nil } // complete embedded

        // Target: the script of any existing partial translation, else zh-Hans.
        var target = "zh-Hans"
        if let existing = inline.first(where: { !$0.isEmpty }) {
            target = FLyricsLanguage.of("und", inline.joined(separator: "\n"))
        }

        // QQ first, then Netease, then LRCLIB bilingual records.
        let qqResult = await QQTranslationSource.find(query, lyrics.lines)
        if let qqLines = qqResult.lines { return merged(lyrics, translation: qqLines) }
        let neteaseResult = await NeteaseTranslationSource.find(query, lyrics.lines)
        if let neteaseLines = neteaseResult.lines { return merged(lyrics, translation: neteaseLines) }
        if let selected = LRCLIBTranslation.select(await lrclibCandidatesFor(query), query, lyrics, target) {
            let lines = lyrics.lines.enumerated().map { index, line in
                FLyricLine(startTimeMS: line.startTimeMS, words: line.words,
                           translation: index < selected.count ? selected[index] : "")
            }
            return merged(lyrics, translation: lines)
        }
        return nil
    }

    private func merged(_ lyrics: FSpotifyLyrics, translation: [FLyricLine]) -> FSpotifyLyrics {
        var out = lyrics
        out.translationProvider = "community"
        out.lines = lyrics.lines.enumerated().map { index, line in
            FLyricLine(startTimeMS: line.startTimeMS, words: line.words,
                       translation: index < translation.count ? translation[index].words : line.translation)
        }
        return out
    }

    private func lrclibCandidatesFor(_ query: FLyricsQuery) async -> [LRCLIBCandidate] {
        let key = "\(query.trackId)|\(query.title)|\(query.artist)"
        if let entry = recent[key], Date().timeIntervalSince(entry.at) < 600 {
            return entry.response.candidates
        }
        let response = await collectLrclibCandidates(query)
        if !response.networkError {
            if recent.count >= 8 { recent.removeValue(forKey: recent.keys.first ?? "") }
            recent[key] = (Date(), response)
        }
        return response.candidates
    }

    // MARK: - Conversion to Kumone's model

    /// Converts Flutify's lines into Kumone's `ParsedLyrics`: a line is sung
    /// until the next one starts (capped at six seconds), its time is spread
    /// across its characters for the karaoke wipe, and Japanese lines get
    /// their romaji / furigana annotations.
    static func parsed(from lyrics: FSpotifyLyrics) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = lyrics.provider
        out.translationContributor = lyrics.translationProvider

        var lines: [LyricLine] = []
        for (index, line) in lyrics.lines.enumerated() {
            let time = Double(line.startTimeMS) / 1000
            let next = index + 1 < lyrics.lines.count
                ? Double(lyrics.lines[index + 1].startTimeMS) / 1000 : .infinity
            let end = min(max(next, time), time + 6)
            let words = LyricsParser.spreadWords(line.words, from: time, to: end)
            lines.append(LyricLine(
                id: index, time: time, end: end, text: line.words,
                translation: line.translation.flatMap { $0.isEmpty ? nil : $0 },
                words: words))
        }
        guard !lines.isEmpty else { return out }

        // Readings are only meaningful for Japanese lyrics: annotate the
        // kanji and drop stray annotations on everything else.
        if RomajiTranscriber.isJapanese(lines.map(\.text)) {
            for i in lines.indices {
                lines[i].romaji = RomajiTranscriber.transcribe(lines[i].text)
                lines[i].furigana = Furigana.segments(for: lines[i].text)
            }
        }
        out.lines = lines
        return out
    }
}

// MARK: - Query construction

extension FLyricsQuery {
    init(track: Track) {
        self.init(
            trackId: String(track.id),
            title: track.name,
            artist: track.artists.map(\.name).joined(separator: ", "),
            album: track.album.name,
            durationMS: track.durationMS)
    }
}
