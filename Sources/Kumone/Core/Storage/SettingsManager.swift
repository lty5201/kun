import SwiftUI

// Ported from Moumusic (jiajia2222/Moumusic, main f3e511a0):
// platforms/ios/Sources/Kumone/Core/Storage/SettingsManager.swift
// (AudioQuality + PlaybackSourceMode, copied verbatim).
// License note: the Moumusic source file carries no per-file license header;
// the Moumusic repository itself is licensed under LGPL-3.0 (its LICENSE file).

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    // allCases is used by the player and download pickers. Keep the order
    // highest-to-lowest so the best declared source tier appears first.
    case master
    case atmos
    case dolby
    case surround
    case hires
    case lossless
    case exhigh
    case higher
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .master: return "超清母带"
        case .atmos: return "高清环绕声"
        case .dolby: return "杜比全景声"
        case .surround: return "沉浸环绕声"
        case .hires: return "Hi-Res"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    var badge: String {
        switch self {
        case .master: return "超清母带"
        case .atmos: return "高清环绕声"
        case .dolby: return "杜比全景声"
        case .surround: return "沉浸环绕声"
        case .hires: return "高解析"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    var lxType: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "atmos"
        case .dolby: return "dolby"
        case .surround: return "surround"
        case .hires: return "flac24bit"
        case .lossless: return "flac"
        case .exhigh, .higher: return "320k"
        case .standard: return "128k"
        }
    }

    /// Technical label shown in the picker. It never claims a tier that the
    /// active source did not advertise.
    var sourceDisplayName: String {
        switch self {
        case .master: return "超清母带 / Master"
        case .atmos: return "高清环绕声 / Spatial"
        case .dolby: return "杜比全景声 / Dolby Atmos"
        case .surround: return "沉浸环绕声 / Surround"
        case .hires: return "Hi-Res / FLAC 24-bit"
        case .lossless: return "无损 FLAC"
        case .exhigh, .higher: return "320 kbps"
        case .standard: return "128 kbps"
        }
    }

    /// The tier's name on the song's own platform (QQ 臻品 / 酷狗 蝰蛇 / 咪咕 PQ·HQ·SQ·ZQ ...); NetEase and
    /// anything else keep the app's generic names.
    func platformLabel(_ source: String?) -> String {
        switch (source ?? "").lowercased() {
        case "tx", "qq", "qqmusic", "qq-music":
            switch self {
            case .master: return "臻品母带"
            case .atmos: return "臻品全景声"
            case .dolby: return "杜比全景声"
            case .surround: return "臻品全景声 5.1"
            case .hires: return "Hi-Res 臻品音质"
            case .lossless: return "SQ 无损品质"
            case .exhigh, .higher: return "HQ 高品质"
            case .standard: return "标准音质"
            }
        case "kg", "kugou":
            switch self {
            case .master: return "蝰蛇超清母带"
            case .atmos: return "蝰蛇全景声"
            case .dolby, .surround: return "蝰蛇超清音质"
            case .hires: return "Hi-Res 超清音质"
            case .lossless: return "无损音质"
            case .exhigh, .higher: return "高品质"
            case .standard: return "标准音质"
            }
        case "mg", "migu":
            switch self {
            case .master: return "ZQ 臻品母带"
            case .atmos, .dolby, .surround: return "3D 臻品全景声"
            case .hires: return "ZQ Hi-Res"
            case .lossless: return "SQ 无损"
            case .exhigh, .higher: return "HQ 高品"
            case .standard: return "PQ 标准"
            }
        case "kw", "kuwo":
            switch self {
            case .master, .atmos, .dolby, .surround, .hires: return "Hi-Res 无损"
            case .lossless: return "无损音质"
            case .exhigh, .higher: return "超品音质"
            case .standard: return "标准音质"
            }
        default:
            return sourceDisplayName
        }
    }

    init?(lxType: String) {        switch lxType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "master", "jymaster", "master_quality", "master-quality": self = .master
        case "atmos", "immersive": self = .atmos
        case "dolby", "dolby-atmos", "dolbyatmos": self = .dolby
        case "surround", "spatial", "spatial-audio": self = .surround
        case "128", "128k", "m4a", "mp3": self = .standard
        case "320", "320k": self = .exhigh
        case "flac", "lossless", "ape": self = .lossless
        case "flac24bit", "flac24", "hires", "highres": self = .hires
        default: return nil
        }
    }

    var isPlatformSpecific: Bool {
        switch self {
        case .master, .atmos, .dolby, .surround: return true
        default: return false
        }
    }

    /// These tiers are not treated as available NetEase account privileges
    /// for a non-VIP account. A third-party LX source may still advertise one
    /// of them, but the player must label that route explicitly.
    var requiresNeteaseVIP: Bool {
        switch self {
        case .master, .atmos, .dolby, .surround, .hires: return true
        default: return false
        }
    }

    /// NetEase's official account endpoint uses different level names from
    /// LX User API. Keep this mapping in one place so the player can request
    /// an account URL without changing the third-party source protocol.
    var neteaseLevel: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "jyeffect"
        case .dolby: return "dolby"
        case .surround: return "sky"
        case .hires: return "hires"
        case .lossless: return "lossless"
        case .exhigh, .higher: return "exhigh"
        case .standard: return "standard"
        }
    }

    init?(neteaseLevel: String) {
        switch neteaseLevel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "jymaster", "master": self = .master
        case "jyeffect", "atmos", "immersive": self = .atmos
        case "dolby", "dolby_atmos": self = .dolby
        case "sky", "surround", "spatial": self = .surround
        case "hires", "highres": self = .hires
        case "lossless", "flac": self = .lossless
        case "exhigh", "higher": self = .exhigh
        case "standard", "128k": self = .standard
        default: return nil
        }
    }

    /// Converts a provider response into a display label. This is deliberately
    /// separate from `displayName`: that property describes a requested tier,
    /// while this helper describes what the provider actually reported.
    static func resolvedDisplayName(_ rawValue: String?) -> String {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return "未知"
        }
        if rawValue.lowercased() == "unknown" {
            return "未知（音源未返回音质字段）"
        }
        if let quality = AudioQuality(lxType: rawValue) {
            return quality.sourceDisplayName
        }
        if let bitrate = Int(rawValue.lowercased()
            .replacingOccurrences(of: "kbps", with: "")
            .replacingOccurrences(of: "k", with: "")) {
            return "\(bitrate) kbps"
        }
        return rawValue.uppercased()
    }

    static func isUnknownResolvedQuality(_ rawValue: String?) -> Bool {
        rawValue?.lowercased() == "unknown" || rawValue == nil
    }

    /// Returns a comparable rank for a provider-reported result.  This is
    /// intentionally separate from the request enum because providers may
    /// return a concrete bitrate such as 192k that is not a selectable tier.
    static func resolvedRank(_ rawValue: String?) -> Int? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              rawValue.lowercased() != "unknown" else {
            return nil
        }
        if let quality = AudioQuality(lxType: rawValue) {
            switch quality {
            case .master: return 900
            case .atmos: return 850
            case .dolby: return 840
            case .surround: return 830
            case .hires: return 800
            case .lossless: return 700
            case .exhigh, .higher: return 320
            case .standard: return 128
            }
        }
        let numeric = rawValue.lowercased()
            .replacingOccurrences(of: "kbps", with: "")
            .replacingOccurrences(of: "k", with: "")
        return Int(numeric)
    }
}

extension AudioQuality {
    /// One-time migration for values stored by kun's old enum.
    /// Old NetEase-level raw values "jyeffect" / "sky" / "vivid" have no case
    /// in the new enum; they fall back to .exhigh (the safe non-VIP tier)
    /// instead of being promoted to a VIP tier.
    /// Do NOT use init?(neteaseLevel:) for this migration: it would map
    /// "jyeffect" -> .atmos and "sky" -> .surround.
    init?(migratingLegacyRawValue rawValue: String) {
        if let quality = AudioQuality(rawValue: rawValue) {
            self = quality
            return
        }
        switch rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "jymaster", "master": self = .master
        case "jyeffect", "sky", "vivid": self = .exhigh
        default: return nil
        }
    }
}

/// Maps an LX quality token back to a kun AudioQuality rawValue for cache keys
/// and servedQuality. Unknown tokens (including "unknown", which means the
/// source gave no tier field) map to nil — never store "unknown" in a cache
/// key or in the UI.
func normalizedLevel(_ lxQuality: String) -> String? {
    AudioQuality(lxType: lxQuality)?.rawValue
}

/// Selects which authorized playback route is attempted first on iOS.
/// `automatic` is the safe default: prefer a logged-in account source for the
/// matching catalogue, then fall back to enabled LX sources when it cannot
/// provide a full-length URL.
enum PlaybackSourceMode: String, CaseIterable, Identifiable {
    case automatic
    case official
    case thirdParty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "自动（账号优先，三方备用）")
        case .official: return String(localized: "账号音源（官方）")
        case .thirdParty: return String(localized: "第三方音源")
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return String(localized: "优先使用已登录账号的完整音频；账号不可用时按已启用的 LX 音源顺序回退")
        case .official:
            return String(localized: "网易云、QQ 音乐、酷狗按对应平台使用已登录账号的官方播放；未登录或不可用时不会偷偷换源")
        case .thirdParty:
            return String(localized: "只使用已导入并启用的 LX 音源")
        }
    }
}


enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case immersive
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        }
    }
}

/// Layout used by the full-width now-playing page — iPhone landscape and
/// iPad — where `NowPlayingMode`'s compact layouts no longer apply. Kept
/// separate so a phone in portrait can stay on 黑胶 while landscape opens on
/// a lyrics-first page.
public enum LandscapeNowPlayingStyle: String, CaseIterable, Identifiable {
    /// Artwork and transport on the left, lyrics on the right (the original
    /// full-width page).
    case classic
    /// Lyrics fill the page, with a small header and a floating transport
    /// capsule at the bottom.
    case immersive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return String(localized: "经典双栏")
        case .immersive: return String(localized: "沉浸歌词")
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Internal rather than private: `AudioCache` reads its own limit straight
    /// from `UserDefaults` before any settings object exists, and must spell
    /// the key the same way.
    enum Keys {
        static let quality = "settings.audioQuality"
        static let playbackSourceMode = "settings.playbackSourceMode"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let landscapeNowPlayingStyle = "settings.landscapeNowPlayingStyle"
        static let openAlbumOnArtworkClick = "settings.openAlbumOnArtworkClick"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"  // migrated to `annotation`
        static let annotation = "settings.lyricsAnnotation"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        static let luoxueScriptPath = "settings.luoxueScriptPath"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        static let lyricsOnIsland = "settings.lyricsOnIsland"
        static let lyricsIslandLocationKeepAlive = "settings.lyricsIslandLocationKeepAlive"
        #if os(macOS)
        static let menuBarPlayer = "settings.showMenuBarPlayer"
        static let automix = "settings.automixEnabled"
        static let automixTransitions = "settings.automixTransitions"
        static let automixOrder = "settings.automixOrder"
        static let automixStems = "settings.automixStems"
        static let loudnessCompensation = "settings.loudnessCompensation"
        static let audioCacheLimit = "settings.audioCacheLimit"
        static let outputDevice = "settings.outputDeviceUID"
        #endif
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
        static let enableAudioCache = "settings.enableAudioCache"
        static let audioCacheSizeMB = "settings.audioCacheSizeMB"
        static let audioCacheAutomatic = "settings.audioCacheAutomatic"
        #if os(iOS)
        static let soundEffectPreset = "settings.soundEffectPreset"
        static let customEqualizerGains = "settings.customEqualizerGains"
        #endif
        // Flutify lyrics settings
        static let lyricsAutoTranslate = "settings.lyricsAutoTranslate"
        static let lyricsExcludeInterface = "settings.lyricsExcludeInterface"
        static let lyricsExcludedLanguages = "settings.lyricsExcludedLanguages"
        static let lyricsScale = "settings.lyricsScale"
        static let lyricsAlign = "settings.lyricsAlign"
        static let lyricsFocusPosition = "settings.lyricsFocusPosition"
        static let lyricsFallback = "settings.lyricsFallback"
        static let lyricsSourceOrder = "settings.lyricsSourceOrder"
        static let lyricsBilingual = "settings.lyricsBilingual"
    }

    /// Flutify's `LyricsSource`: the four sources the lyrics chain uses. Not
    /// every source is wired into this app's player, but the setting (and its
    /// persisted order) is kept 1:1 with Flutify so the source-priority list
    /// in settings reads the same and can be reordered.
    enum LyricsSourceKind: String, CaseIterable, Identifiable, Codable {
        case spotify
        case qqMusic
        case netease
        case lrclib

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .qqMusic: return "QQ 音乐"
            case .netease: return "网易云音乐"
            case .lrclib: return "LRCLIB"
            }
        }

        var roleText: String {
            switch self {
            case .spotify: return "原文，自带译文"
            case .lrclib: return "原文与译文"
            default: return "原文与中文译词"
            }
        }

        static let defaultOrder: [LyricsSourceKind] = [.spotify, .qqMusic, .netease, .lrclib]

        /// Same normalisation as Flutify: drop unknown / duplicate entries,
        /// then append anything missing in the default order.
        static func parseOrder(_ raw: [String]) -> [LyricsSourceKind] {
            var seen: [LyricsSourceKind] = []
            for name in raw {
                if let source = LyricsSourceKind(rawValue: name), !seen.contains(source) {
                    seen.append(source)
                }
            }
            for source in defaultOrder where !seen.contains(source) {
                seen.append(source)
            }
            return seen
        }
    }

    /// Flutify's `LyricsAlign`.
    enum LyricsAlign: String, CaseIterable, Identifiable {
        case left
        case center

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .left: return "左对齐"
            case .center: return "居中"
            }
        }
    }

    /// Flutify's lyrics scaling bounds (`minLyricsScale` / `maxLyricsScale`).
    static let lyricsScaleRange: ClosedRange<Double> = 0.7...1.6
    /// Flutify's focus-position bounds.
    static let lyricsFocusPositionRange: ClosedRange<Double> = 0.05...0.55

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    @Published var playbackSourceMode: PlaybackSourceMode {
        didSet { UserDefaults.standard.set(playbackSourceMode.rawValue, forKey: Keys.playbackSourceMode) }
    }


    static let audioCacheSizeRangeMB = 100...10_000
    static let audioCacheSizeStepMB = 100

    /// Use locally stored audio files before resolving a remote source and
    /// retain completed remote playback for future requests.
    @Published var enableAudioCache: Bool {
        didSet { UserDefaults.standard.set(enableAudioCache, forKey: Keys.enableAudioCache) }
    }

    /// Size the song cache from the device's free space instead of
    /// `audioCacheSizeMB`; see `AutomaticCacheLimit`.
    @Published var audioCacheAutomatic: Bool {
        didSet { UserDefaults.standard.set(audioCacheAutomatic, forKey: Keys.audioCacheAutomatic) }
    }

    static func normalizedAudioCacheSizeMB(_ value: Int) -> Int {
        let boundedValue = min(
            max(value, audioCacheSizeRangeMB.lowerBound),
            audioCacheSizeRangeMB.upperBound
        )
        let distanceFromLowerBound = boundedValue - audioCacheSizeRangeMB.lowerBound
        return audioCacheSizeRangeMB.lowerBound
            + Int((Double(distanceFromLowerBound) / Double(audioCacheSizeStepMB)).rounded())
                * audioCacheSizeStepMB
    }

    @Published var audioCacheSizeMB: Int {
        didSet {
            let normalizedValue = Self.normalizedAudioCacheSizeMB(audioCacheSizeMB)
            guard normalizedValue == audioCacheSizeMB else {
                audioCacheSizeMB = normalizedValue
                return
            }
            UserDefaults.standard.set(audioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }

    @Published var landscapeNowPlayingStyle: LandscapeNowPlayingStyle {
        didSet {
            UserDefaults.standard.set(
                landscapeNowPlayingStyle.rawValue, forKey: Keys.landscapeNowPlayingStyle
            )
        }
    }

    @Published var openAlbumOnArtworkClick: Bool {
        didSet { UserDefaults.standard.set(openAlbumOnArtworkClick, forKey: Keys.openAlbumOnArtworkClick) }
    }

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    // MARK: - Flutify lyrics settings (1:1 with the LyricsSection)
    //
    // Every item Flutify's lyrics section exposes, in the same order, so a
    // user coming from Flutify finds the same switches and sliders.

    @Published var lyricsAutoTranslate: Bool {
        didSet { UserDefaults.standard.set(lyricsAutoTranslate, forKey: Keys.lyricsAutoTranslate) }
    }

    @Published var lyricsExcludeInterfaceLanguage: Bool {
        didSet { UserDefaults.standard.set(lyricsExcludeInterfaceLanguage, forKey: Keys.lyricsExcludeInterface) }
    }

    @Published var lyricsExcludedLanguages: [String] {
        didSet { UserDefaults.standard.set(lyricsExcludedLanguages, forKey: Keys.lyricsExcludedLanguages) }
    }

    @Published var lyricsScale: Double {
        didSet { UserDefaults.standard.set(lyricsScale, forKey: Keys.lyricsScale) }
    }

    @Published var lyricsAlign: LyricsAlign {
        didSet { UserDefaults.standard.set(lyricsAlign.rawValue, forKey: Keys.lyricsAlign) }
    }

    @Published var lyricsFocusPosition: Double {
        didSet { UserDefaults.standard.set(lyricsFocusPosition, forKey: Keys.lyricsFocusPosition) }
    }

    @Published var lyricsFallback: Bool {
        didSet { UserDefaults.standard.set(lyricsFallback, forKey: Keys.lyricsFallback) }
    }

    @Published var lyricsSourceOrder: [LyricsSourceKind] {
        didSet { UserDefaults.standard.set(lyricsSourceOrder.map(\.rawValue), forKey: Keys.lyricsSourceOrder) }
    }

    @Published var lyricsBilingual: Bool {
        didSet { UserDefaults.standard.set(lyricsBilingual, forKey: Keys.lyricsBilingual) }
    }

    /// Check for updates on launch. When off, no update sheet appears
    /// automatically; the user can still check manually (#42).
    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
            #if os(macOS)
            UpdaterManager.shared.setAutomaticChecks(autoCheckUpdates)
            #endif
        }
    }

    /// Reading shown for Japanese lyrics: a romaji line above, furigana over
    /// the kanji, or nothing.
    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.annotation) }
    }

    /// Karaoke-style word-by-word highlighting: the service's own timing when the
    /// Resolve gray tracks from the Luoxue (LX Music) custom source script.
    @Published var enableUnblock: Bool {
        didSet { UserDefaults.standard.set(enableUnblock, forKey: Keys.unblock) }
    }

    /// Whether gray tracks can be resolved: unblock enabled and at least one
    /// LX third-party source selected and loaded.
    var canResolveUnblockedTracks: Bool {
#if os(iOS)
        LXUserAPIService.shared.ensureSelectedSourceLoaded()
        return enableUnblock && LXSourceStore.shared.selectedSource != nil
#else
        return false
#endif
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }

    /// True Live Activity lyrics on the Dynamic Island / Lock Screen. Default off.
    @Published var lyricsOnIsland: Bool {
        didSet { UserDefaults.standard.set(lyricsOnIsland, forKey: Keys.lyricsOnIsland) }
    }
    /// Opt-in location keep-alive for the lyrics Live Activity. Default off.
    @Published var lyricsIslandLocationKeepAlive: Bool {
        didSet { UserDefaults.standard.set(lyricsIslandLocationKeepAlive, forKey: Keys.lyricsIslandLocationKeepAlive) }
    }
    #if os(macOS)

    /// The AutoMix master switch. Off means no per-track analysis at all, and
    /// every sub-setting below is inert. Opt-in: AutoMix costs CPU (analysis),
    /// sometimes network (the order's candidates) and sometimes GPU (stems),
    /// so it does not turn itself on. macOS-only for now (spec §7).
    @Published var automixEnabled: Bool {
        didSet { UserDefaults.standard.set(automixEnabled, forKey: Keys.automix) }
    }

    /// Beat-matched / crossfaded hand-overs between queue tracks. Off still
    /// gives gapless playback, and off is *only* a statement about the seam:
    /// analysis still runs when another sub-setting below wants it.
    @Published var automixTransitionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixTransitionsEnabled,
                                      forKey: Keys.automixTransitions)
        }
    }

    /// The `.autoMix` queue order — reorder the queue by how well the seams
    /// come out. It scores candidates, which means downloading tracks the
    /// listener has not asked for yet, so it is off by default even under an
    /// AutoMix that is on.
    @Published var automixOrderEnabled: Bool {
        didSet { UserDefaults.standard.set(automixOrderEnabled, forKey: Keys.automixOrder) }
    }

    /// Let a hand-over separate stems on the GPU. Real money in heat and
    /// battery, and it needs a model on disk, so it is opt-in on top of
    /// opt-in; without it every gesture plays its whole-mix form.
    @Published var automixStemsEnabled: Bool {
        didSet { UserDefaults.standard.set(automixStemsEnabled, forKey: Keys.automixStems) }
    }

    /// Even out mastering loudness differences between songs, so the next
    /// track does not arrive several dB louder. Needs AutoMix's per-track
    /// analysis, so it is inert while AutoMix is off.
    @Published var loudnessCompensationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(loudnessCompensationEnabled,
                                      forKey: Keys.loudnessCompensation)
        }
    }

    /// Audio cache LRU limit in bytes; 0 = unlimited. AudioCache reads the
    /// same defaults key at startup and receives changes from here.
    @Published var audioCacheLimit: Int64 {
        didSet {
            UserDefaults.standard.set(audioCacheLimit, forKey: Keys.audioCacheLimit)
            Task { await EngineAudioCache.shared.setLimitBytes(audioCacheLimit) }
        }
    }

    /// CoreAudio UID of the chosen output device; "" follows the system
    /// default. UID rather than the numeric AudioDeviceID, which is not
    /// stable across launches. Written by `AudioOutputController`.
    @Published var outputDeviceUID: String {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: Keys.outputDevice) }
    }
    #endif

    /// Lock the desktop-lyrics capsule to the horizontal centre of the screen
    /// instead of the free-drag position (#48).
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    static let mainWindowAmbientBackgroundIntensityRange = 0.5...1.5

    #if os(macOS)
    /// Default song-cache ceiling, shared with `AudioCache` so the two cannot
    /// disagree about what "unset" means.
    nonisolated static let defaultAudioCacheLimit: Int64 = 2_147_483_648  // 2 GB
    #endif

    /// Artwork-tinted overlay on the main app interface.
    @Published var showMainWindowAmbientBackground: Bool {
        didSet {
            UserDefaults.standard.set(
                showMainWindowAmbientBackground,
                forKey: Keys.mainWindowAmbientBackground
            )
        }
    }

    /// Multiplier applied to the main interface's artwork tint.
    @Published var mainWindowAmbientBackgroundIntensity: Double {
        didSet {
            UserDefaults.standard.set(
                mainWindowAmbientBackgroundIntensity,
                forKey: Keys.mainWindowAmbientBackgroundIntensity
            )
        }
    }

    #if os(iOS)
    @Published var soundEffectPreset: SoundEffectPreset {
        didSet {
            UserDefaults.standard.set(soundEffectPreset.rawValue, forKey: Keys.soundEffectPreset)
            publishSoundEffectParameters()
        }
    }

    @Published private(set) var customEqualizerGains: [Float] {
        didSet {
            let normalized = EqualizerConfiguration(gains: customEqualizerGains).gains
            guard normalized == customEqualizerGains else {
                customEqualizerGains = normalized
                return
            }
            UserDefaults.standard.set(
                normalized.map(Double.init), forKey: Keys.customEqualizerGains)
            if soundEffectPreset == .custom { publishSoundEffectParameters() }
        }
    }

    var customEqualizerConfiguration: EqualizerConfiguration {
        EqualizerConfiguration(gains: customEqualizerGains)
    }

    var isCustomEqualizerEnabled: Bool {
        soundEffectPreset == .custom
    }

    func selectSoundEffect(_ preset: SoundEffectPreset) {
        soundEffectPreset = preset
    }

    func setCustomEqualizerEnabled(_ isEnabled: Bool) {
        if isEnabled {
            soundEffectPreset = .custom
        } else if soundEffectPreset == .custom {
            soundEffectPreset = .original
        }
    }

    func updateCustomEqualizerGain(at index: Int, to value: Float) {
        guard customEqualizerGains.indices.contains(index) else { return }
        var gains = customEqualizerGains
        gains[index] = min(
            max(value, EqualizerConfiguration.gainRange.lowerBound),
            EqualizerConfiguration.gainRange.upperBound)
        customEqualizerGains = gains
        if soundEffectPreset != .custom { soundEffectPreset = .custom }
    }

    func resetCustomEqualizer() {
        customEqualizerGains = EqualizerConfiguration.flat.gains
        if soundEffectPreset != .custom { soundEffectPreset = .custom }
    }

    private func publishSoundEffectParameters() {
        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: soundEffectPreset,
            custom: customEqualizerConfiguration))
    }
    #endif

    private init() {
        let defaults = UserDefaults.standard
        let storedQuality = defaults.string(forKey: Keys.quality)
            .flatMap(AudioQuality.init(migratingLegacyRawValue:)) ?? .exhigh
        audioQuality = storedQuality
        playbackSourceMode = defaults.string(forKey: Keys.playbackSourceMode)
            .flatMap(PlaybackSourceMode.init(rawValue:)) ?? .automatic
        enableAudioCache = defaults.object(forKey: Keys.enableAudioCache) as? Bool ?? true
        // A size somebody chose stays chosen; the untouched default becomes automatic.
        audioCacheAutomatic = defaults.object(forKey: Keys.audioCacheAutomatic) as? Bool
            ?? (defaults.object(forKey: Keys.audioCacheSizeMB) as? Int).map { $0 == AudioCache.defaultMaximumSizeMB } ?? true
        let storedAudioCacheSizeMB = defaults.object(forKey: Keys.audioCacheSizeMB) as? Int
            ?? AudioCache.defaultMaximumSizeMB
        let normalizedAudioCacheSizeMB = Self.normalizedAudioCacheSizeMB(storedAudioCacheSizeMB)
        audioCacheSizeMB = normalizedAudioCacheSizeMB
        defaults.set(normalizedAudioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        landscapeNowPlayingStyle = defaults.string(forKey: Keys.landscapeNowPlayingStyle)
            .flatMap(LandscapeNowPlayingStyle.init) ?? .classic
        openAlbumOnArtworkClick = defaults.object(forKey: Keys.openAlbumOnArtworkClick) as? Bool ?? true
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        // Carry over the old on/off romaji toggle for anyone who had it on.
        lyricsAnnotation = defaults.string(forKey: Keys.annotation).flatMap(LyricsAnnotation.init)
            ?? (defaults.bool(forKey: Keys.showRomaji) ? .romaji : .off)
        enableUnblock = defaults.object(forKey: Keys.unblock) as? Bool ?? true
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        lyricsOnIsland = defaults.object(forKey: Keys.lyricsOnIsland) as? Bool ?? false
        lyricsIslandLocationKeepAlive = defaults.object(forKey: Keys.lyricsIslandLocationKeepAlive) as? Bool ?? false
        #if os(macOS)
        automixEnabled = defaults.object(forKey: Keys.automix) as? Bool ?? false
        automixTransitionsEnabled =
            defaults.object(forKey: Keys.automixTransitions) as? Bool ?? true
        automixOrderEnabled = defaults.object(forKey: Keys.automixOrder) as? Bool ?? false
        automixStemsEnabled = defaults.object(forKey: Keys.automixStems) as? Bool ?? false
        loudnessCompensationEnabled =
            defaults.object(forKey: Keys.loudnessCompensation) as? Bool ?? true
        audioCacheLimit = (defaults.object(forKey: Keys.audioCacheLimit) as? Int64)
            ?? Self.defaultAudioCacheLimit
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice) ?? ""
        #endif
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        showMainWindowAmbientBackground = defaults.object(
            forKey: Keys.mainWindowAmbientBackground
        ) as? Bool ?? true
        let storedAmbientBackgroundIntensity = defaults.object(
            forKey: Keys.mainWindowAmbientBackgroundIntensity
        ) as? Double ?? 1
        mainWindowAmbientBackgroundIntensity = min(
            max(storedAmbientBackgroundIntensity, Self.mainWindowAmbientBackgroundIntensityRange.lowerBound),
            Self.mainWindowAmbientBackgroundIntensityRange.upperBound
        )
        #if os(iOS)
        soundEffectPreset = SoundEffectPreferences.preset(
            from: defaults, key: Keys.soundEffectPreset)
        customEqualizerGains = SoundEffectPreferences.customConfiguration(
            from: defaults, key: Keys.customEqualizerGains).gains
        #endif

        // Flutify lyrics settings: defaults identical to Flutify's
        // `AppPreferences` (lyricsScale 1.0, focus 0.16, fallback on, source
        // order spotify → qq → netease → lrclib, no excluded languages, auto
        // translate + exclude interface on, bilingual off).
        lyricsAutoTranslate = defaults.object(forKey: Keys.lyricsAutoTranslate) as? Bool ?? true
        lyricsExcludeInterfaceLanguage =
            defaults.object(forKey: Keys.lyricsExcludeInterface) as? Bool ?? true
        lyricsExcludedLanguages =
            defaults.stringArray(forKey: Keys.lyricsExcludedLanguages) ?? []
        let storedLyricsScale = defaults.object(forKey: Keys.lyricsScale) as? Double ?? 1
        lyricsScale = min(max(storedLyricsScale, Self.lyricsScaleRange.lowerBound),
                          Self.lyricsScaleRange.upperBound)
        lyricsAlign = defaults.string(forKey: Keys.lyricsAlign).flatMap(LyricsAlign.init) ?? .left
        let storedLyricsFocusPosition = defaults.object(forKey: Keys.lyricsFocusPosition) as? Double ?? 0.16
        lyricsFocusPosition = min(max(storedLyricsFocusPosition, Self.lyricsFocusPositionRange.lowerBound),
                                  Self.lyricsFocusPositionRange.upperBound)
        lyricsFallback = defaults.object(forKey: Keys.lyricsFallback) as? Bool ?? true
        lyricsSourceOrder = Self.LyricsSourceKind.parseOrder(
            defaults.stringArray(forKey: Keys.lyricsSourceOrder) ?? [])
        lyricsBilingual = defaults.object(forKey: Keys.lyricsBilingual) as? Bool ?? false

        // Every stored property is assigned by now, so it is finally safe to
        // publish the DSP parameters (calling it earlier trips Swift's
        // definite-initialization check on the iOS target).
        #if os(iOS)
        publishSoundEffectParameters()
        #endif
    }
}
