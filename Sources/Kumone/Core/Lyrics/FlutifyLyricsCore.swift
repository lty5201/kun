import Foundation

// MARK: - Line model (Flutify)

/// A timed lyric line as Flutify's lyrics pipeline models it: milliseconds
/// plus words, with an optional same-index translation.
struct FLyricLine: Hashable {
    var startTimeMS: Int
    var words: String
    var translation: String?

    init(startTimeMS: Int, words: String, translation: String? = nil) {
        self.startTimeMS = startTimeMS
        self.words = words
        self.translation = translation
    }
}

// MARK: - Script / language detection (lyric_script.dart)

enum FScript: Int, CaseIterable {
    case han, kana, hangul, cyrillic, greek, thai, arabic, hebrew, latin, other
}

enum FLyricLang: Int, CaseIterable {
    case zh, ja, ko, latin, cyrillic, greek, thai, arabic, hebrew, unknown
}

/// Which script a UTF-16 code unit belongs to; punctuation/digits are nil.
func fScriptOf(_ c: UInt32) -> FScript? {
    if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { return .latin }
    if (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0xF900 && c <= 0xFAFF) {
        return .han
    }
    if (c >= 0x3040 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0xFF66 && c <= 0xFF9F) {
        return .kana
    }
    if (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F) {
        return .hangul
    }
    if c >= 0x0400 && c <= 0x052F { return .cyrillic }
    if (c >= 0x0370 && c <= 0x03FF) || (c >= 0x1F00 && c <= 0x1FFF) { return .greek }
    if c >= 0x0E00 && c <= 0x0E7F { return .thai }
    if (c >= 0x0600 && c <= 0x06FF) || (c >= 0x0750 && c <= 0x077F)
        || (c >= 0xFB50 && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF) {
        return .arabic
    }
    if c >= 0x0590 && c <= 0x05FF { return .hebrew }
    if (c >= 0x00C0 && c <= 0x024F) || (c >= 0x1E00 && c <= 0x1EFF) { return .latin }
    if fIsOtherLetter(c) { return .other }
    return nil
}

private func fIsOtherLetter(_ c: UInt32) -> Bool {
    (c >= 0x0530 && c <= 0x058F)   // Armenian
        || (c >= 0x0900 && c <= 0x0DFF)   // Indic
        || (c >= 0x0E80 && c <= 0x0FFF)   // Lao / Tibetan
        || (c >= 0x10A0 && c <= 0x10FF)   // Georgian
        || (c >= 0x1780 && c <= 0x17FF)   // Khmer
}

/// Per-script character counts over a piece of text.
struct FScriptCounts {
    private var counts = [Int](repeating: 0, count: FScript.allCases.count)

    init(_ text: String) {
        for unit in text.utf16 {
            if let script = fScriptOf(UInt32(unit)) {
                counts[script.rawValue] += 1
            }
        }
    }

    subscript(script: FScript) -> Int { counts[script.rawValue] }
    var total: Int { counts.reduce(0, +) }
}

/// Language by "which script appears" — for short texts like titles/artists.
func fDetectLang(_ text: String) -> FLyricLang {
    let counts = FScriptCounts(text)
    if counts[.kana] > 0 { return .ja }
    if counts[.hangul] > 0 { return .ko }
    if counts[.han] > 0 { return .zh }
    if counts[.cyrillic] > 0 { return .cyrillic }
    if counts[.greek] > 0 { return .greek }
    if counts[.thai] > 0 { return .thai }
    if counts[.arabic] > 0 { return .arabic }
    if counts[.hebrew] > 0 { return .hebrew }
    if counts[.latin] > 0 { return .latin }
    return .unknown
}

/// Main language of a lyric body: Japanese always mixes kana, Chinese/Korean
/// songs often mix English, so threshold ratios rather than a plain max.
func fLyricLang(_ text: String) -> FLyricLang {
    let counts = FScriptCounts(text)
    let total = counts.total
    if total < 1 { return .unknown }
    if Double(counts[.kana]) / Double(total) >= 0.05 { return .ja }
    if Double(counts[.hangul]) / Double(total) >= 0.15 { return .ko }
    if Double(counts[.han]) / Double(total) >= 0.15 { return .zh }
    let order: [(FScript, FLyricLang)] = [
        (.latin, .latin), (.cyrillic, .cyrillic), (.greek, .greek),
        (.thai, .thai), (.arabic, .arabic), (.hebrew, .hebrew),
    ]
    var best = FLyricLang.unknown
    var bestCount = 0
    for (script, lang) in order where counts[script] > bestCount {
        bestCount = counts[script]
        best = lang
    }
    return best
}

/// 0...100: how well the lyric script matches the target language. Same-CJK
/// neighbours earn partial credit so ties don't flip at random. Unknown
/// target scores a flat 50.
func fLangScore(_ target: FLyricLang, _ text: String) -> Double {
    let counts = FScriptCounts(text)
    let total = Double(counts.total)
    if total < 1 { return 0 }
    func ratio(_ s: FScript) -> Double { Double(counts[s]) / total }
    let han = ratio(.han), kana = ratio(.kana), hangul = ratio(.hangul), latin = ratio(.latin)
    let exact: Double
    let near: Double
    switch target {
    case .zh: exact = han; near = kana + hangul
    case .ja: exact = kana + han * 0.6; near = han * 0.4
    case .ko: exact = hangul; near = han * 0.25
    case .latin: exact = latin; near = ratio(.greek) * 0.2
    case .cyrillic: exact = ratio(.cyrillic); near = 0
    case .greek: exact = ratio(.greek); near = latin * 0.2
    case .thai: exact = ratio(.thai); near = 0
    case .arabic: exact = ratio(.arabic); near = 0
    case .hebrew: exact = ratio(.hebrew); near = 0
    case .unknown: return 50
    }
    let far = max(0, min(1, 1 - exact - near))
    let score = exact + near * 0.5 - far * 0.5
    return max(0, min(100, score * 100))
}

/// Dominant script family of one line: 0 CJK, 1 Latin, 2 Cyrillic, 3 Greek,
/// 4 Thai, 5 Arabic, 6 Hebrew, 7 other; -1 when it has no letters.
func fLineFamily(_ text: String) -> Int {
    var family = [Int](repeating: 0, count: 8)
    var best = -1
    var bestCount = 0
    for unit in text.utf16 {
        guard let script = fScriptOf(UInt32(unit)) else { continue }
        let f: Int
        switch script {
        case .han, .kana, .hangul: f = 0
        case .latin: f = 1
        case .cyrillic: f = 2
        case .greek: f = 3
        case .thai: f = 4
        case .arabic: f = 5
        case .hebrew: f = 6
        case .other: f = 7
        }
        family[f] += 1
        if family[f] > bestCount {
            bestCount = family[f]
            best = f
        }
    }
    return best
}

// MARK: - ZhScript (zh_script.dart)

enum ZhScript {
    private static let toSimplifiedMap: [UInt32: UInt32] = {
        Dictionary(uniqueKeysWithValues: zip(zhTradToSimpFrom, zhTradToSimpTo))
    }()
    private static let toTraditionalMap: [UInt32: UInt32] = {
        Dictionary(uniqueKeysWithValues: zip(zhSimpToTradFrom, zhSimpToTradTo))
    }()

    /// Count of traditional-only characters.
    static func countTraditional(_ text: String) -> Int {
        var count = 0
        for unit in text.utf16 where toSimplifiedMap[UInt32(unit)] != nil {
            count += 1
        }
        return count
    }

    /// Count of simplified-only characters.
    static func countSimplified(_ text: String) -> Int {
        var count = 0
        for unit in text.utf16 where toTraditionalMap[UInt32(unit)] != nil {
            count += 1
        }
        return count
    }

    /// Convert to simplified (`toSimplified` true) or traditional.
    static func convert(_ text: String, toSimplified: Bool) -> String {
        let map = toSimplified ? toSimplifiedMap : toTraditionalMap
        var scalars = [Unicode.Scalar]()
        scalars.reserveCapacity(text.count)
        var changed = false
        for scalar in text.unicodeScalars {
            if let mapped = map[scalar.value] {
                if let mappedScalar = Unicode.Scalar(mapped) {
                    scalars.append(mappedScalar)
                    changed = true
                    continue
                }
            }
            scalars.append(scalar)
        }
        return changed ? String(String.UnicodeScalarView(scalars)) : text
    }
}

// MARK: - LyricsLanguage (lyrics_language.dart)

enum FLyricsLanguage {
    static func normalize(_ tag: String) -> String {
        let parts = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .split(separator: "-")
            .map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "" }
        if first != "zh" { return first }
        if parts.contains("hant") { return "zh-Hant" }
        if parts.contains("hans") { return "zh-Hans" }
        if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return "zh-Hant" }
        if parts.contains(where: { ["cn", "sg", "my"].contains($0) }) { return "zh-Hans" }
        return "zh"
    }

    static func of(_ tag: String, _ text: String) -> String {
        let code = normalize(tag)
        if code == "zh" { return chineseScript(text) }
        if !code.isEmpty && code != "und" { return code }
        switch fLyricLang(text) {
        case .zh: return chineseScript(text)
        case .ja: return "ja"
        case .ko: return "ko"
        default: return "und"
        }
    }

    static func chineseScript(_ text: String) -> String {
        let traditional = ZhScript.countTraditional(text)
        let simplified = ZhScript.countSimplified(text)
        if traditional > simplified { return "zh-Hant" }
        if simplified > traditional { return "zh-Hans" }
        return "zh"
    }

    static func excluded(_ source: String, _ exclusion: String) -> Bool {
        let code = normalize(exclusion)
        return source == code
            || (code == "zh" && source.hasPrefix("zh"))
            || (source == "zh" && code.hasPrefix("zh"))
    }

    static func matches(_ code: String, _ target: String) -> Bool {
        code == target || (code == "zh" && target.hasPrefix("zh"))
    }
}

// MARK: - LyricsTitle (lyrics_title.dart)

/// Removes featured-artist credits without erasing mix/live/version labels.
enum FLyricsTitle {
    private static let credit = try! NSRegularExpression(
        pattern: #"\s*[\[(（]\s*(?:feat\.\s*|ft\.\s*|(?:feat|ft|featuring)\s+)[^\])）]+[\])）]"#,
        options: [.caseInsensitive])
    private static let trailingCredit = try! NSRegularExpression(
        pattern: #"\s+(?:[-–—]\s*)?(?:feat\.\s*|ft\.\s*|(?:feat|ft|featuring)\s+)[^\[\]()（）]+$"#,
        options: [.caseInsensitive])
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    static func search(_ title: String) -> String {
        var text = stringByReplacing(title, credit, "")
        text = stringByReplacing(text, trailingCredit, "")
        text = stringByReplacing(text, whitespace, " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func stringByReplacing(_ text: String, _ regex: NSRegularExpression, _ replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}

// MARK: - ArtistMatcher (artist_match.dart)

enum FArtistMatch {
    /// At least one artist lines up.
    case match
    /// Both sides use the same script yet no artist lines up: most likely a
    /// different song with the same title — unusable.
    case mismatch
    /// Not comparable (one side empty, or different scripts).
    case unknown

    private static let separator = try! NSRegularExpression(
        pattern: #"\s*(?:,|&|/|;|\+|、|，|\bfeat\.?|\bft\.?|\bwith\b|\bx\b|\band\b|\bvs\.?)\s*"#,
        options: [.caseInsensitive])
    private static let nonWord = try! NSRegularExpression(
        pattern: #"[^\p{L}\p{N}]+"#, options: [.caseInsensitive])

    static func compare(_ queryArtist: String, _ candidateArtist: String) -> FArtistMatch {
        let a = normalize(queryArtist)
        let b = normalize(candidateArtist)
        if a.isEmpty || b.isEmpty { return .unknown }
        let langA = fDetectLang(a), langB = fDetectLang(b)
        if langA == .unknown || langA != langB { return .unknown }

        let namesA = names(a), namesB = names(b)
        let wordsA = Set(namesA.flatMap { $0 })
        let wordsB = Set(namesB.flatMap { $0 })
        func covered(_ names: [[String]], _ words: Set<String>) -> Bool {
            names.contains { name in name.allSatisfy(words.contains) }
        }
        return covered(namesA, wordsB) || covered(namesB, wordsA) ? .match : .mismatch
    }

    private static func normalize(_ artist: String) -> String {
        let text = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ZhScript.countTraditional(text) > 0 ? ZhScript.convert(text, toSimplified: true) : text
    }

    private static func names(_ artist: String) -> [[String]] {
        let ns = artist as NSString
        let range = NSRange(artist.startIndex..., in: artist)
        var parts: [String] = []
        var cursor = 0
        for match in separator.matches(in: artist, range: range) {
            if match.range.location > cursor {
                parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            parts.append(ns.substring(from: cursor))
        }
        return parts.compactMap { name in
            let words = words(in: name)
            return words.isEmpty ? nil : words
        }
    }

    private static func words(in name: String) -> [String] {
        let ns = name as NSString
        let range = NSRange(name.startIndex..., in: name)
        var words: [String] = []
        var cursor = 0
        for match in nonWord.matches(in: name, range: range) {
            if match.range.location > cursor {
                words.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            words.append(ns.substring(from: cursor))
        }
        return words.filter { !$0.isEmpty }
    }
}

// MARK: - TranslationMarkers (translation_markers.dart)

enum FTranslationMarkers {
    static let words = [
        "translation", "translated", "romanization", "romanized", "romanised",
        "romaji", "pronunciation", "phonetic", "pinyin",
        "翻譯", "翻译", "中譯", "中译", "羅馬音", "罗马音", "音譯", "音译",
        "空耳", "拼音", "注音", "對照", "对照",
    ]

    static func hasMarker(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let low = text.lowercased()
        return words.contains { low.contains($0) }
    }

    /// Credit lines inside lyric bodies: a marker followed by a colon or "by".
    static func isCreditLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return zhCredit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            || enCredit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            || byCredit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// 「（中文）翻译：」「歌词翻譯 by」「译：」「罗马音：」…，可带前导括号。
    private static let zhCredit = try! NSRegularExpression(
        pattern: #"^[\(（\[【]?\s*(?:中文|中|英文|日文|韩文|韓文|歌词|歌詞)?\s*(?:翻譯|翻译|譯文|译文|中譯|中译|音譯|音译|羅馬音|罗马音|拼音|注音|對照|对照|空耳|譯|译)\s*(?:[:：]|by\b)"#,
        options: [.caseInsensitive])

    /// 「Translation: xxx」「Translated by xxx」「Lyrics translation by xxx」「Romaji: xxx」.
    private static let enCredit = try! NSRegularExpression(
        pattern: #"^[\(\[]?\s*(?:lyrics?\s+)?(?:english\s+|chinese\s+)?(?:translation|translated|romanization|romanized|romanised|romaji|pinyin)\s*(?:[:：]|by\b)"#,
        options: [.caseInsensitive])

    /// 「by: xxx」「by：xxx」.
    private static let byCredit = try! NSRegularExpression(
        pattern: #"^[\(\[]?\s*by\s*[:：]"#, options: [.caseInsensitive])
}

// MARK: - LrcParser (lrc_parser.dart)

/// LRC line-synced parsing: `[mm:ss.xx]words`, multiple timestamps per line.
/// Untagged lines (metadata, plain text) are skipped; results sort by time.
/// Empty lines are kept — they mark interludes.
enum FLrcParser {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)

    static func parse(_ lrc: String) -> [FLyricLine] {
        var lines: [FLyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let range = NSRange(line.startIndex..., in: line)
            let matches = tag.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
            var text = line
            // Replace from the end so earlier match ranges stay valid.
            for match in matches.reversed() {
                text = (text as NSString).replacingCharacters(
                    in: match.range, with: "")
            }
            text = text.trimmingCharacters(in: .whitespaces)
            for match in matches {
                let ns = line as NSString
                let minutes = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let ms = minutes * 60000 + Int((seconds * 1000).rounded())
                lines.append(FLyricLine(startTimeMS: ms, words: text))
            }
        }
        // Stable sort: same-time lines keep their original order (the
        // translation of a pair follows its original).
        return lines.enumerated()
            .sorted { a, b in
                let difference = a.element.startTimeMS - b.element.startTimeMS
                return difference != 0 ? difference < 0 : a.offset < b.offset
            }
            .map(\.element)
    }
}
