import SwiftUI

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires
    // NetEase's newer tiers; the API degrades to whatever the account can
    // actually stream, same as the official app's sheet.
    case jyeffect
    case vivid
    case sky
    case jymaster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高 HQ")
        case .lossless: return String(localized: "无损 SQ")
        case .hires: return String(localized: "高解析度无损")
        case .jyeffect: return String(localized: "高清臻音")
        case .vivid: return String(localized: "臻音全景声")
        case .sky: return String(localized: "沉浸环绕声")
        case .jymaster: return String(localized: "超清母带")
        }
    }

    /// The English tier name the official sheet prints beside the Chinese one.
    var englishName: String? {
        switch self {
        case .sky: return "Surround Audio"
        case .jymaster: return "Master"
        case .vivid: return "Audio Vivid"
        case .jyeffect: return "Spatial Audio"
        case .hires: return "Hi-Res"
        default: return nil
        }
    }

    /// The small tag printed next to a top card's title (沉浸环绕声 carries
    /// 听感升级 in the official sheet).
    var cardTag: String? {
        switch self {
        case .sky: return String(localized: "听感升级")
        default: return nil
        }
    }

    var badge: String {
        switch self {
        case .standard: return String(localized: "标")
        case .higher: return String(localized: "较高")
        case .exhigh: return "HQ"
        case .lossless: return "SQ"
        case .hires: return "Hi-Res"
        case .jyeffect: return String(localized: "臻音")
        case .vivid: return String(localized: "全景声")
        case .sky: return String(localized: "环绕声")
        case .jymaster: return String(localized: "母带")
        }
    }

    /// The sheet's secondary line, matching the official app's wording.
    var detailText: String {
        switch self {
        case .standard: return String(localized: "128kbps")
        case .higher: return String(localized: "192kbps")
        case .exhigh: return String(localized: "近 CD 音质的细节体验，最高320kbps")
        case .lossless: return String(localized: "高保真无损音质，最高48kHz/16bit")
        case .hires: return String(localized: "更饱满清晰的高解析度音质，最高192kHz/24bit")
        case .jyeffect: return String(localized: "高频细节还原与清晰沉浸感，96kHz/24bit")
        case .vivid: return String(localized: "沉浸三维空间音频，最高7.1.4声道")
        case .sky: return String(localized: "环绕音感 最高5.1声道")
        case .jymaster: return String(localized: "极致细节 192kHz/24bit")
        }
    }

    /// The badge shown beside the tier name: SVIP / VIP tiers follow the
    /// official sheet (臻音全景声、沉浸环绕声、超清母带 are SVIP; 高清臻音、
    /// Hi-Res、无损 are VIP; the free tiers carry none).
    var tierBadge: String? {
        switch self {
        case .jymaster, .sky, .vivid: return "SVIP"
        case .jyeffect, .hires, .lossless: return "VIP"
        case .standard, .higher, .exhigh: return nil
        }
    }

    /// Order in the quality sheet, best first — matches the official app.
    var sheetOrder: Int {
        switch self {
        case .sky: return 0
        case .jymaster: return 1
        case .vivid: return 2
        case .jyeffect: return 3
        case .hires: return 4
        case .lossless: return 5
        case .exhigh: return 6
        case .higher: return 7
        case .standard: return 8
        }
    }

    /// 较高 exists in the API but the official sheet leaves it out.
    var showsInSheet: Bool { self != .higher }
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
        static let customSourceHeaders = "settings.customSourceHeaders"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
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
    /// Luoxue custom source loaded.
    var canResolveUnblockedTracks: Bool {
        LuoxueSourceManager.shared.ensureLoadedFromSettings()
        return enableUnblock && LuoxueSourceManager.shared.isReady
    }

    /// Extra request headers for custom-source playback and downloads, one
    /// `Name: value` per line. 网盘 sources serve links that only answer to
    /// a specific User-Agent / Referer / Cookie, so the user can add them
    /// here once instead of per song.
    @Published var customSourceHeaders: String {
        didSet { UserDefaults.standard.set(customSourceHeaders, forKey: Keys.customSourceHeaders) }
    }

    var parsedCustomSourceHeaders: [String: String] {
        var parsed: [String: String] = [:]
        for line in customSourceHeaders.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            parsed[name] = value
        }
        return parsed
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
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
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
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
        customSourceHeaders = defaults.string(forKey: Keys.customSourceHeaders) ?? ""
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
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
