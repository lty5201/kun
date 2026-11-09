import Foundation
import Combine
import os.log

/// Lifecycle of the installed Luoxue (落雪 / LX Music) custom source script.
enum LuoxueSourceState: Equatable {
    case idle
    case loading
    case ready(sources: [String])
    case failed(String)
}

/// Owns the Luoxue custom source script: installation, (re)loading and the
/// gray-track stream resolution that goes through it.
///
/// Published state is meant for the Settings UI; `isReady` is a lock-guarded
/// flag that playback code may read from any thread. The JavaScript runtime
/// itself is confined to `LuoxueScriptRuntime`'s serial queue.
final class LuoxueSourceManager: ObservableObject {
    static let shared = LuoxueSourceManager()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "luoxue-source")

    @Published private(set) var state: LuoxueSourceState = .idle
    @Published private(set) var scriptName: String?

    private let runtime = LuoxueScriptRuntime()
    private let lock = NSLock()
    private var ready = false
    private var currentCapabilities: [String: LuoxueScriptRuntime.Capability] = [:]
    private var autoLoadAttempted = false

    private init() {}

    /// True once a script has loaded and reported its sources.
    var isReady: Bool {
        lock.withLock { ready }
    }

    /// Source keys the loaded script declared (e.g. "wy", "kw", "tx").
    var supportedSourceKeys: [String] {
        lock.withLock { currentCapabilities.keys.sorted() }
    }

    /// Whether Settings should offer a reload button (a script is installed
    /// and either loaded or failed).
    var needsReload: Bool {
        switch state {
        case .ready, .failed:
            return SettingsManager.shared.luoxueScriptPath != nil
        default:
            return false
        }
    }

    /// Whether the script can serve NetEase tracks — the only platform this
    /// player talks to.
    var supportsNetEase: Bool {
        lock.withLock { currentCapabilities["wy"] != nil }
    }

    /// Kicks off the one automatic load attempt from the persisted path. Safe
    /// to call repeatedly from any thread.
    @discardableResult
    func ensureLoadedFromSettings() -> Bool {
        lock.lock()
        if autoLoadAttempted {
            lock.unlock()
            return isReady
        }
        autoLoadAttempted = true
        guard let path = SettingsManager.shared.luoxueScriptPath else {
            lock.unlock()
            return false
        }
        lock.unlock()
        Task { await load(path: path) }
        return isReady
    }

    /// Copies the picked script into app support, records it in settings and
    /// loads it.
    @MainActor
    func install(scriptAt url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let destination = try installDirectory().appendingPathComponent("luoxue-source.js")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            let name = url.lastPathComponent
            let path = destination.path
            SettingsManager.shared.luoxueScriptPath = path
            await load(path: path, name: name)
        } catch {
            Self.log.error("install failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                state = .failed(String(localized: "脚本安装失败"))
                scriptName = nil
            }
            setReady(false, capabilities: [:])
        }
    }

    /// Reloads the persisted script (Settings button).
    @MainActor
    func reload() async {
        if let path = SettingsManager.shared.luoxueScriptPath {
            await load(path: path)
        }
    }

    private func installDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Kumone", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func load(path: String, name: String? = nil) async {
        await MainActor.run { state = .loading }
        do {
            let script = try String(contentsOfFile: path, encoding: .utf8)
            guard !script.isEmpty else {
                setReady(false, capabilities: [:])
                await MainActor.run { state = .failed(String(localized: "脚本文件为空")) }
                return
            }
            let env = Self.environmentName()
            let version = Self.appVersion()
            let capabilities = try await runtime.load(script: script, env: env, version: version)
            setReady(!capabilities.isEmpty, capabilities: capabilities)
            let keys = capabilities.keys.sorted()
            await MainActor.run {
                scriptName = name ?? (scriptName ?? URL(fileURLWithPath: path).lastPathComponent)
                state = capabilities.isEmpty
                    ? .failed(String(localized: "脚本未声明任何来源"))
                    : .ready(sources: keys)
            }
            if !capabilities.isEmpty && capabilities["wy"] == nil {
                Self.log.warning("script has no 'wy' source; NetEase tracks cannot resolve")
            }
        } catch {
            setReady(false, capabilities: [:])
            let message = error.localizedDescription
            await MainActor.run { state = .failed(message) }
            Self.log.error("load failed: \(message, privacy: .public)")
        }
    }

    private func setReady(_ value: Bool, capabilities: [String: LuoxueScriptRuntime.Capability]) {
        lock.lock()
        ready = value
        currentCapabilities = capabilities
        lock.unlock()
    }

    /// Resolves a gray track's stream URL through the loaded script.
    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        guard isReady else { throw LuoxueScriptError.notLoaded }
        let quality = Self.lxQuality(
            for: SettingsManager.shared.audioQuality,
            supported: lock.withLock { currentCapabilities["wy"]?.qualitys }
        )
        let url = try await runtime.resolveMusicURL(source: "wy", songID: track.id, quality: quality)
        return ResolvedAudioSource(
            id: .luoxue,
            displayName: AudioSourceID.luoxue.displayName,
            url: url
        )
    }

    // MARK: - Quality mapping

    /// Maps the app's playback quality onto the quality tokens LX Music
    /// scripts use, falling back to whatever the script supports.
    static func lxQuality(for quality: AudioQuality, supported: [String]?) -> String {
        let preference: [AudioQuality: [String]] = [
            .standard: ["128k"],
            .higher: ["320k", "128k"],
            .exhigh: ["320k", "128k"],
            .lossless: ["flac", "320k", "128k"],
            .hires: ["flac24bit", "flac", "320k", "128k"],
        ]
        let order = preference[quality] ?? ["320k", "128k"]
        guard let supported, !supported.isEmpty else { return order.first ?? "128k" }
        for candidate in order where supported.contains(candidate) {
            return candidate
        }
        return supported.first ?? "128k"
    }

    private static func environmentName() -> String {
        #if os(iOS)
        return "mobile"
        #else
        return "desktop"
        #endif
    }

    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version! : "1.0.0"
    }
}
