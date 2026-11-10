import Foundation
import Combine
import os.log

/// Owns the installed Luoxue (落雪 / LX Music) custom-source scripts:
/// installation (local / online / pasted), the enabled list and the
/// gray-track stream resolution that goes through them.
///
/// Multiple scripts may be installed at once; each gets its own
/// `LuoxueScriptRuntime` (its own JSContext on its own serial queue).
/// Enabled sources are tried in list order, first successful resolution wins.
///
/// Published state is meant for the management UI; `isReady` is a
/// lock-guarded flag that playback code may read from any thread.
@MainActor
final class LuoxueSourceManager: ObservableObject {
    static let shared = LuoxueSourceManager()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "luoxue-source")

    /// One row in the management UI: the persisted record plus its live
    /// load state.
    struct Entry: Identifiable, Equatable {
        var source: LuoxueInstalledSource
        var state: LuoxueSourceState

        var id: UUID { source.id }
        var name: String { source.name }
        var originURL: String? { source.originURL }
        var enabled: Bool { source.enabled }
    }

    @Published private(set) var entries: [Entry] = []

    /// Result of an import attempt, for the management UI to surface.
    enum ImportError: LocalizedError, Equatable {
        case invalidURL
        case downloadFailed(String)
        case emptyScript
        case tooLarge
        case notJavaScript

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "不是有效的脚本链接")
            case .downloadFailed(let reason): return String(localized: "下载失败：\(reason)")
            case .emptyScript: return String(localized: "脚本内容为空")
            case .tooLarge: return String(localized: "脚本文件过大（上限 10 MB）")
            case .notJavaScript: return String(localized: "内容不像 JavaScript 脚本")
            }
        }
    }

    /// Health-check outcome for one installed source.
    struct CheckResult: Equatable {
        let sourceID: UUID
        var ok: Bool
        var detail: String
    }

    private var runtimes: [UUID: LuoxueScriptRuntime] = [:]
    /// Lock-guarded readiness flags, readable from any actor (playback code
    /// polls `isReady` off the main actor). Held by a nonisolated Sendable
    /// store so `nonisolated` accessors can reach it.
    private let readiness = LuoxueReadinessStore()
    private var autoLoadAttempted = false

    /// Immutable `let` of a Sendable type: safe to touch from any context.
    private final class LuoxueReadinessStore: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var netEase = false

        func set(ready: Bool, netEase: Bool) {
            lock.withLock {
                self.ready = ready
                self.netEase = netEase
            }
        }

        var isReady: Bool { lock.withLock { ready } }
        var supportsNetEase: Bool { lock.withLock { netEase } }
    }

    /// Shared ephemeral session for online script downloads.
    private let downloadSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        downloadSession = URLSession(configuration: configuration)
        loadPersisted()
    }

    // MARK: - Read-only state for playback

    /// True once at least one enabled script has loaded and reported sources.
    nonisolated var isReady: Bool {
        readiness.isReady
    }

    /// Whether any enabled loaded script can serve NetEase tracks — the only
    /// platform this player talks to.
    nonisolated var supportsNetEase: Bool {
        readiness.supportsNetEase
    }

    /// Whether at least one source is installed at all.
    var hasInstalledSources: Bool { !entries.isEmpty }

    // MARK: - Persistence

    private var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("luoxue-sources.json")
    }

    private var scriptsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Kumone/luoxue-scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadPersisted() {
        // Migrate the pre-multi-source single-script setting first.
        migrateLegacySingleScript()

        guard let data = try? Data(contentsOf: manifestURL),
              let saved = try? JSONDecoder().decode([LuoxueInstalledSource].self, from: data) else {
            entries = []
            return
        }
        entries = saved
            .filter { FileManager.default.fileExists(atPath: $0.filePath) }
            .sorted { $0.addedAt < $1.addedAt }
            .map { Entry(source: $0, state: .idle) }
    }

    /// The first release stored one script path in
    /// `settings.luoxueScriptPath`; fold it into the new list once.
    private func migrateLegacySingleScript() {
        let key = SettingsManager.Keys.luoxueScriptPath
        guard let legacyPath = UserDefaults.standard.string(forKey: key),
              FileManager.default.fileExists(atPath: legacyPath) else { return }

        let name = URL(fileURLWithPath: legacyPath).lastPathComponent
        let migrated = LuoxueInstalledSource(
            name: name, originURL: nil, filePath: legacyPath, enabled: true)
        var current: [LuoxueInstalledSource] = (try? JSONDecoder().decode(
            [LuoxueInstalledSource].self,
            from: (try? Data(contentsOf: manifestURL)) ?? Data())) ?? []
        if !current.contains(where: { $0.filePath == legacyPath }) {
            current.append(migrated)
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: manifestURL, options: .atomic)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        Self.log.info("migrated legacy single script: \(name, privacy: .public)")
    }

    private func persist() {
        let sources = entries.map(\.source)
        if let data = try? JSONEncoder().encode(sources) {
            do { try data.write(to: manifestURL, options: .atomic) }
            catch { Self.log.error("persist failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Auto load

    /// Loads every enabled script once, after the first access. Safe to call
    /// repeatedly from any thread.
    @discardableResult
    nonisolated func ensureLoadedFromSettings() -> Bool {
        Task { @MainActor in
            guard !autoLoadAttempted else { return }
            autoLoadAttempted = true
            for index in entries.indices where entries[index].enabled {
                await loadEntry(at: index)
            }
        }
        return isReady
    }

    // MARK: - Import

    /// Imports scripts picked from the local file picker (本地导入). Multiple
    /// files can be selected at once, and a selected folder has every `.js`
    /// inside imported. Each script becomes its own source; per-file failures
    /// are reported in `failures` so one bad file does not abort the batch.
    @discardableResult
    func installLocalBatch(scriptsAt urls: [URL]) async -> (installed: Int, failures: [(name: String, error: String)]) {
        // Expand directories into their .js contents.
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                files += children.filter { $0.pathExtension.lowercased() == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(url)
            }
        }

        var installed = 0
        var failures: [(name: String, error: String)] = []
        for url in files {
            do {
                try await installLocal(scriptAt: url)
                installed += 1
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        return (installed, failures)
    }

    /// Imports a script from a local file (fileImporter / 本地导入).
    func installLocal(scriptAt url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        try await install(data: data, name: name, originURL: nil)
    }

    /// Downloads and installs a script from a URL (在线导入). GitHub / Gitee /
    /// GitLab blob links are converted to raw direct links first; GitHub raw
    /// falls back to a jsdelivr mirror when unreachable.
    func installOnline(urlString: String) async throws {
        guard let direct = LuoxueURLConverter.directLink(from: urlString) else {
            throw ImportError.invalidURL
        }
        guard let url = URL(string: direct) else { throw ImportError.invalidURL }

        let script: String
        do {
            script = try await downloadScript(from: url)
        } catch ImportError.downloadFailed(let reason) {
            // One retry through the jsdelivr mirror for GitHub links.
            if let mirror = LuoxueURLConverter.jsdelivrFallback(for: direct),
               let mirrorURL = URL(string: mirror) {
                script = try await downloadScript(from: mirrorURL)
            } else {
                throw ImportError.downloadFailed(reason)
            }
        }

        let name = URL(fileURLWithPath: direct).lastPathComponent
        try await install(script: script, name: name, originURL: direct)
    }

    /// Imports from the clipboard (粘贴导入): a URL is downloaded, anything
    /// else is treated as script text itself.
    func installFromClipboard(text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if LuoxueURLConverter.directLink(from: trimmed) != nil {
            try await installOnline(urlString: trimmed)
        } else {
            guard !trimmed.isEmpty else { throw ImportError.emptyScript }
            try await install(script: trimmed, name: String(localized: "粘贴的脚本"), originURL: nil)
        }
    }

    private func downloadScript(from url: URL) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await downloadSession.data(from: url)
        } catch {
            throw ImportError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ImportError.downloadFailed("HTTP \(http.statusCode)")
        }
        guard data.count <= 10 * 1024 * 1024 else { throw ImportError.tooLarge }
        guard let script = String(data: data, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyScript
        }
        return script
    }

    private func install(data: Data, name: String, originURL: String?) async throws {
        guard let script = String(data: data, encoding: .utf8),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyScript
        }
        try await install(script: script, name: name, originURL: originURL)
    }

    /// Writes the script to app support, records it and loads it.
    private func install(script: String, name: String, originURL: String?) async throws {
        guard script.count <= 10 * 1024 * 1024 else { throw ImportError.tooLarge }
        // A very light sanity check: LX scripts are JavaScript.
        guard script.contains("lx") || script.contains("global") || script.contains("function")
            || script.contains("=>") else {
            throw ImportError.notJavaScript
        }

        let source = LuoxueInstalledSource(
            name: LuoxueScriptMetadata.name(in: script, fallback: name),
            originURL: originURL,
            filePath: scriptsDirectory.appendingPathComponent("\(UUID().uuidString).js").path,
            enabled: true)
        do {
            try script.data(using: .utf8)?.write(to: source.fileURL, options: .atomic)
        } catch {
            throw ImportError.downloadFailed(error.localizedDescription)
        }

        entries.append(Entry(source: source, state: .loading))
        persist()
        Self.log.info("installed source: \(source.name, privacy: .public)")
        await loadEntry(at: entries.count - 1)
    }

    // MARK: - Per-source lifecycle

    /// Reloads one installed source (刷新).
    func refresh(id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        await loadEntry(at: index)
    }

    /// Re-downloads an online source from its origin URL, then reloads.
    func refreshOnline(id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let origin = entries[index].originURL else {
            await refresh(id: id)
            return
        }
        do {
            guard let direct = LuoxueURLConverter.directLink(from: origin),
                  let url = URL(string: direct) else { throw ImportError.invalidURL }
            let script: String
            do {
                script = try await downloadScript(from: url)
            } catch ImportError.downloadFailed(let reason) {
                guard let mirror = LuoxueURLConverter.jsdelivrFallback(for: direct),
                      let mirrorURL = URL(string: mirror) else { throw ImportError.downloadFailed(reason) }
                script = try await downloadScript(from: mirrorURL)
            }
            try? script.data(using: .utf8)?.write(to: entries[index].source.fileURL, options: .atomic)
            if let name = extractName(from: script, existing: entries[index].name) {
                entries[index].source = updateName(entries[index].source, name)
                persist()
            }
        } catch {
            entries[index].state = .failed(error.localizedDescription)
        }
        await loadEntry(at: index)
    }

    private func extractName(from script: String, existing: String) -> String? {
        let name = LuoxueScriptMetadata.name(in: script, fallback: existing)
        return name == existing ? nil : name
    }

    private func updateName(_ source: LuoxueInstalledSource, _ name: String) -> LuoxueInstalledSource {
        var updated = source
        updated.name = name
        return updated
    }

    /// Enables / disables a source without reloading it (开关).
    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].source.enabled = enabled
        persist()
        if enabled, case .idle = entries[index].state {
            Task { await loadEntry(at: index) }
        }
        refreshReadiness()
    }

    /// Deletes a source and its script file (删除).
    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let source = entries[index].source
        entries.remove(at: index)
        runtimes.removeValue(forKey: id)
        persist()
        try? FileManager.default.removeItem(at: source.fileURL)
        Self.log.info("removed source: \(source.name, privacy: .public)")
        refreshReadiness()
    }

    private func loadEntry(at index: Int) async {
        let source = entries[index].source
        entries[index].state = .loading
        do {
            let script = try String(contentsOfFile: source.filePath, encoding: .utf8)
            guard !script.isEmpty else {
                entries[index].state = .failed(String(localized: "脚本文件为空"))
                refreshReadiness()
                return
            }
            let runtime = runtimes[source.id] ?? LuoxueScriptRuntime()
            runtimes[source.id] = runtime
            let capabilities = try await runtime.load(
                script: script, env: Self.environmentName(), version: Self.appVersion())
            let keys = capabilities.keys.sorted()
            entries[index].state = capabilities.isEmpty
                ? .failed(String(localized: "脚本未声明任何来源"))
                : .ready(sources: keys)
            if !capabilities.isEmpty && capabilities["wy"] == nil {
                Self.log.warning("source \(source.name, privacy: .public) has no 'wy' source")
            }
        } catch {
            entries[index].state = .failed(error.localizedDescription)
            Self.log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        var ready = false
        var netEase = false
        for entry in entries where entry.enabled {
            if case .ready(let sources) = entry.state, !sources.isEmpty {
                ready = true
                if sources.contains("wy") { netEase = true }
            }
        }
        readiness.set(ready: ready, netEase: netEase)
    }

    // MARK: - Health check (音源体检)

    /// Reloads every installed source and reports per-source status.
    func checkAll() async -> [CheckResult] {
        var results: [CheckResult] = []
        for index in entries.indices {
            await loadEntry(at: index)
            let entry = entries[index]
            let ok: Bool
            let detail: String
            switch entry.state {
            case .ready(let sources):
                ok = sources.contains("wy")
                detail = ok
                    ? String(localized: "正常，支持网易云（\(sources.joined(separator: "、"))）")
                    : String(localized: "已载入但不支持网易云（\(sources.joined(separator: "、"))）")
            case .failed(let message):
                ok = false
                detail = String(localized: "载入失败：\(message)")
            case .loading:
                ok = false
                detail = String(localized: "载入中")
            case .idle:
                ok = false
                detail = String(localized: "未载入")
            }
            results.append(CheckResult(sourceID: entry.id, ok: ok, detail: detail))
        }
        return results
    }

    // MARK: - Resolution

    /// Resolves a gray track's stream URL through the enabled sources, in
    /// list order; the first script that produces a URL wins.
    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let qualityPreference = SettingsManager.shared.audioQuality
        for entry in entries where entry.enabled {
            guard let runtime = runtimes[entry.id] else { continue }
            let allCapabilities = await runtime.capabilities()
            let quality = Self.lxQuality(
                for: qualityPreference,
                supported: allCapabilities["wy"]?.qualitys)
            do {
                let url = try await runtime.resolveMusicURL(source: "wy", songID: track.id, quality: quality)
                return ResolvedAudioSource(
                    id: .luoxue,
                    displayName: AudioSourceID.luoxue.displayName,
                    url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.error("source=\(entry.name, privacy: .public) resolve failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        throw LuoxueScriptError.notLoaded
    }

    // MARK: - Quality mapping

    /// Maps the app's playback quality onto the quality tokens LX Music
    /// scripts use, falling back to whatever the script supports.
    static func lxQuality(for quality: AudioQuality, supported: [String]?) -> String {
        let preference: [AudioQuality: [String]] = [
            .standard: ["128k"],
            .higher: ["192k", "320k", "128k"],
            .exhigh: ["320k", "128k"],
            .lossless: ["flac", "320k", "128k"],
            .hires: ["flac24bit", "flac", "320k", "128k"],
            .jyeffect: ["flac24bit", "flac", "320k", "128k"],
            .vivid: ["flac24bit", "flac", "320k", "128k"],
            .sky: ["flac24bit", "flac", "320k", "128k"],
            .jymaster: ["flac24bit", "flac", "320k", "128k"],
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
