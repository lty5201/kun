// Ported from Moumusic (jiajia2222/Moumusic, main f3e511a0) platforms/ios/Sources/Kumone/Core/API/LXCatalogService.swift + Core/API/NeteaseTrackMatcher.swift — LGPL-3.0-only; kun adaptation, see draft-a README.md.
import Foundation

/// kun-adapted catalogue side for the LX engine: only the two call sites
/// LXUserAPIService needs (`search` and `matchingTrack`).
///
/// What is NOT ported (deliberate): Moumusic's Kuwo / Kugou / QQ / Migu search
/// adapters (LXCatalogService.swift lines 279-523: searchKuwo, searchKugou,
/// searchMigu, searchQQ, plus fetch helpers / md5 / zzc signing in lines 524-1324).
/// kun's only catalogue search is MusicAPI.search, which searches NetEase (cloudsearch) and nothing
/// else, so this file can only serve the "wy" platform. Cross-platform matching
/// therefore works one way only: a non-NetEase track CAN be matched onto NetEase
/// (the LX source then plays the NetEase match), but a NetEase track CANNOT be
/// matched onto kw/kg/tx/mg — matchingTrack returns nil there and the caller
/// (LXUserAPIService) skips that platform and tries the next one. checkSelectedSource
/// has the same behaviour: only "wy" gets a real catalogue probe, the other
/// platforms fall back to the bundled local test track (sourceCheckTrack).
/// Restoring full cross-platform matching means porting those four adapters.
enum LXCatalogPlatform: String, CaseIterable, Identifiable {
    case aggregate
    case kw
    case kg
    case tx
    case wy
    case mg
    case sd

    /// Catalogue adapters that are actually supported by the app UI.
    static var catalogueCases: [LXCatalogPlatform] {
        allCases.filter { $0 != .sd }
    }

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .aggregate: return "聚合"
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .tx: return "QQ 音乐"
        case .wy: return "网易云"
        case .mg: return "咪咕"
        case .sd: return "汽水音乐"
        }
    }
    var sourceID: String? {
        switch self {
        case .aggregate: return nil
        case .kw: return "kw"
        case .kg: return "kg"
        case .tx: return "tx"
        case .wy: return "wy"
        case .mg: return "mg"
        case .sd: return "sd"
        }
    }

    static func displayName(for rawValue: String?) -> String {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "wy", "163", "netease", "neteasecloudmusic", "netease-cloud-music", "cloudmusic":
            return "网易云"
        case "kw", "kuwo": return "酷我"
        case "kg", "kugou": return "酷狗"
        case "tx", "qq", "qqmusic", "qq-music": return "QQ 音乐"
        case "mg", "migu": return "咪咕"
        case "sd", "soda", "sodamusic", "soda-music", "qishui", "qishui-music": return "汽水音乐"
        case "": return "未知"
        default: return rawValue ?? "未知"
        }
    }
}

enum LXCatalogError: LocalizedError {
    case invalidResponse
    case unsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "平台返回了无法识别的结果"
        case .unsupported: return "当前平台暂不支持此功能"
        case .unavailable: return "搜索服务暂时不可用"
        }
    }
}

enum LXCatalogService {
    static func search(_ keyword: String, platform: LXCatalogPlatform,
                       page: Int = 1, limit: Int = 30) async throws -> [Track] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        switch platform {
        case .wy:
            return try await searchNetease(keyword, page: page, limit: limit)
        case .aggregate:
            // kun has only the NetEase catalogue search, so "aggregate" is NetEase-only.
            return try await searchNetease(keyword, page: page, limit: limit)
        case .kw, .kg, .tx, .mg, .sd:
            // No kun search adapter for these platforms (see file header).
            // Callers use try? and fall back, so this surfaces as "no match".
            throw LXCatalogError.unsupported
        }
    }

    private static func searchNetease(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        let result = try await MusicAPI.search(keyword, type: .songs,
                                               limit: max(1, min(limit, 100)),
                                               offset: max(0, page - 1) * limit)
        return (result.songs ?? []).map { $0.withSource("wy") }
    }

    /// Find the same song on another catalogue platform before asking the LX
    /// User API to resolve it. Reusing the original platform's ID is unsafe:
    /// a Kuwo RID is not a Kugou hash, QQ mid, or NetEase song ID, and doing so
    /// is what makes a cross-platform fallback return the wrong song.
    /// kun limitation: only matching ONTO "wy" can succeed (see file header).
    static func matchingTrack(_ sourceTrack: Track, on platform: String) async -> Track? {
        guard let platform = LXCatalogPlatform(rawValue: platform), platform != .aggregate else {
            return nil
        }
        let keyword = [sourceTrack.name, sourceTrack.artistNames]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !keyword.isEmpty,
              let candidates = try? await search(keyword, platform: platform, page: 1, limit: 12),
              !candidates.isEmpty else { return nil }
        return bestCandidate(for: sourceTrack, in: candidates)
    }

    // MARK: - Matching (adapted from Moumusic NeteaseTrackMatcher.swift)

    /// Title must match exactly after normalisation; artists must overlap when
    /// both sides name any; duration must agree within 12 s. Best score wins.
    private static func bestCandidate(for track: Track, in candidates: [Track]) -> Track? {
        let targetTitle = normalizedTitle(track.name)
        guard !targetTitle.isEmpty else { return nil }
        return candidates.compactMap { candidate -> (track: Track, score: Int)? in
            guard let score = score(track: track, candidate: candidate, targetTitle: targetTitle) else { return nil }
            return (candidate, score)
        }
        .max { lhs, rhs in lhs.score < rhs.score }
        .map(\.track)
    }

    private static func score(track: Track, candidate: Track, targetTitle: String) -> Int? {
        guard normalizedTitle(candidate.name) == targetTitle else { return nil }
        let targetArtists = artistTokens(track.artistNames)
        let candidateArtists = artistTokens(candidate.artistNames)
        if !targetArtists.isEmpty && !candidateArtists.isEmpty,
           targetArtists.isDisjoint(with: candidateArtists) {
            return nil
        }
        var result = 100
        if !targetArtists.isEmpty && !candidateArtists.isEmpty {
            result += targetArtists.intersection(candidateArtists).count * 60
        }
        if track.duration > 0, candidate.duration > 0 {
            let difference = abs(track.duration - candidate.duration)
            guard difference <= 12 else { return nil }
            result += max(0, 30 - Int(difference.rounded()) * 3)
        }
        return result
    }

    private static func normalizedTitle(_ value: String) -> String {
        var title = value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: .current)
        for marker in ["(live)", "（live）", "live", "(remix)", "（remix）",
                       "remix", "(dj)", "（dj）", "dj", "(伴奏)", "（伴奏）",
                       "伴奏", "(纯音乐)", "（纯音乐）", "纯音乐"] {
            title = title.replacingOccurrences(of: marker, with: "")
        }
        return title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func artistTokens(_ value: String) -> Set<String> {
        Set(value
            .components(separatedBy: ["/", "&", "、", ",", "，", ";", "；", "\\"])
            .map { normalizedTitle($0) }
            .filter { !$0.isEmpty })
    }
}
