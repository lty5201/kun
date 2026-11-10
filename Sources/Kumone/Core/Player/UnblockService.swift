import Foundation
import os.log

/// Resolves gray tracks through the Luoxue (落雪 / LX Music) custom source
/// script. This is the app's only fallback path — the former built-in
/// providers were removed outright, so nothing else can ever be called.
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "luoxue-source")

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
        /// Why resolution failed, shown to the user so a silent fallback to
        /// the trial clip never hides the real cause.
        var failureReason: String? = nil
    }

    static func resolve(
        _ track: Track,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        guard !attemptedSources.contains(.luoxue) else {
            return Resolution(source: nil, attemptedSources: [])
        }
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }
        do {
            let resolved = try await LuoxueSourceManager.shared.resolve(track: track)
            return Resolution(source: resolved, attemptedSources: [.luoxue])
        } catch {
            if Task.isCancelled { return Resolution(source: nil, attemptedSources: [.luoxue]) }
            log.error("source=luoxue operation=resolve error=\(error.localizedDescription, privacy: .public)")
            return Resolution(source: nil, attemptedSources: [.luoxue], failureReason: error.localizedDescription)
        }
    }
}
