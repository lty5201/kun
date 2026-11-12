// Ported from Moumusic (jiajia2222/Moumusic, main f3e511a0) platforms/ios/Sources/Kumone/Core/Player/QualitySupport.swift — LGPL-3.0-only; kun adaptation, see draft-a README.md.
import Foundation

/// Audio tiers are no longer filtered by a source-capability check: every tier can be chosen. Whether a song
/// really has a tier is decided when it is played (and by the per-song probe in the quality picker).
@MainActor
enum QualitySupport {
    private static let preferredKey = "moumusic.audioQuality.preferred"

    static func allowedTiers(for mode: PlaybackSourceMode, track: Track? = nil) -> Set<String> {
        Set(AudioQuality.allCases.map(\.lxType))
    }

    static func audioQualities(for mode: PlaybackSourceMode) -> [AudioQuality] {
        AudioQuality.allCases
    }

    static func rememberChoice(_ quality: AudioQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: preferredKey)
    }

    /// An earlier version lowered the default quality when a source did not declare it; put the user's own
    /// choice back.
    static func normalizeSelection() {
        let settings = SettingsManager.shared
        guard let stored = UserDefaults.standard.string(forKey: preferredKey).flatMap(AudioQuality.init(rawValue:)),
              stored != settings.audioQuality else { return }
        settings.audioQuality = stored
    }
}
