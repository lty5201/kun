import Foundation
import Combine
import CryptoKit
import os.log

/// Owns the installed Luoxue (落雪 / LX Music) custom-source scripts:
/// installation (local / online / pasted), the enabled list and the
/// gray-track stream resolution that goes through them.
///
/// Exactly like the reference app (畅怡守/KMusic), every ENABLED script is
/// loaded into ONE shared engine (one JSContext on one serial queue) in list
/// order; each script registers request handlers into a shared list.
/// Resolution walks handlers in registration order and qualities within each
/// handler until one produces a URL — the reference app's
/// `resolveMusicUrlWithFallback` / `retryWithLowerQualityIfPossible`
/// / "retry with next JS handler" chain.
///
/// Any change to the enabled set reloads the whole engine.
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
        case noScriptsInFolder
        case duplicate(existingName: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "不是有效的脚本链接")
            case .downloadFailed(let reason): return String(localized: "下载失败：\(reason)")
            case .emptyScript: return String(localized: "脚本内容为空")
            case .tooLarge: return String(localized: "脚本文件过大（上限 10 MB）")
            case .notJavaScript: return String(localized: "内容不像 JavaScript 脚本")
            case .noScriptsInFolder: return String(localized: "文件夹里没有 .js 脚本")
            case .duplicate(let existingName): return String(localized: "音源重复：与已导入的「\(existingName)」内容相同，已跳过")
            }
        }
    }

    /// Health-check outcome for one installed source.
    struct CheckResult: Equatable {
        let sourceID: UUID
        var ok: Bool
        var detail: String
    }

    /// The ONE shared engine every enabled script is loaded into.
    private var engine: LxScriptEngine?
    /// True when the enabled set / script files changed since the last load.
    private var engineDirty = true
    /// Guards against overlapping reloads.
    private var engineLoading = false
    /// Last loaded `sourceId -> qualitys`, merged across every script.
    private var engineCapabilities: [String: [String]] = [:]
    /// Lock-guarded readiness flags, readable from any actor (playback code
    /// polls `isReady` off the main actor). Held by a nonisolated Sendable
    /// store so `nonisolated` accessors can reach it.
    private let readiness = LuoxueReadinessStore()
    private var autoLoadAttempted = false
    private var lastAutoLoadAttempt: Date?

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

    // MARK: - Duplicate detection

    /// Content fingerprint for duplicate detection: SHA-256 over the script
    /// with line endings unified and surrounding whitespace stripped, so
    /// files that differ only by CRLF vs LF or a trailing newline still match.
    private static func scriptFingerprint(_ script: String) -> String {
        let normalized = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The display name of an installed source whose script content matches,
    /// or nil when this script is new. Entries installed before the
    /// `contentHash` field existed are hashed from their stored file on the
    /// fly.
    private func existingDuplicate(of script: String) -> String? {
        let fingerprint = Self.scriptFingerprint(script)
        for entry in entries {
            if let stored = entry.source.contentHash {
                if stored == fingerprint { return entry.source.name }
            } else if let text = try? String(contentsOfFile: entry.source.filePath, encoding: .utf8),
                      Self.scriptFingerprint(text) == fingerprint {
                return entry.source.name
            }
        }
        return nil
    }

    // MARK: - Auto load

    /// Loads every enabled script into the shared engine once, after the
    /// first access. Safe to call repeatedly from any thread.
    @discardableResult
    nonisolated func ensureLoadedFromSettings() -> Bool {
        Task { @MainActor in
            // Retry failed loads with a cooldown instead of loading only once
            // per session: a source whose init timed out on a slow network at
            // launch gets another chance on the next playback attempt.
            let now = Date()
            if autoLoadAttempted,
               let last = lastAutoLoadAttempt,
               now.timeIntervalSince(last) < 30 {
                return
            }
            autoLoadAttempted = true
            lastAutoLoadAttempt = now
            if engineDirty || !isReady { await reloadEngine() }
        }
        return isReady
    }

    // MARK: - Import

    /// All enabled sources failed to resolve a track; carries one line per
    /// source so the user can see exactly which source failed and why.
    struct AggregateResolveError: LocalizedError {
        let failures: [String]

        var errorDescription: String? {
            if failures.isEmpty {
                return String(localized: "没有已启用的自定义源")
            }
            let shown = failures.prefix(6).joined(separator: "；")
            if failures.count > 6 {
                return shown + String(localized: "；等\(failures.count)个源全部失败")
            }
            return shown
        }
    }

    /// Imports scripts picked from the local file picker (本地导入). Multiple
    /// files can be selected at once, and a selected folder has every `.js`
    /// inside imported. Each script becomes its own source; per-file failures
    /// are reported in `failures` so one bad file does not abort the batch.
    ///
    /// Everything is read while the picker's security scope is held: listing
    /// a picked folder — and reading its children — is silently refused by the
    /// sandbox without it, which used to make 本地导入 fail wholesale.
    @discardableResult
    func installLocalBatch(scriptsAt urls: [URL]) async -> (installed: Int, skipped: [String], failures: [(name: String, error: String)]) {
        var picked: [(name: String, data: Data)] = []
        var failures: [(name: String, error: String)] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // fileExists alone cannot tell a folder from a file for a scoped
            // URL the sandbox has not granted yet, so ask the URL itself.
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? FileManager.default.fileExists(atPath: url.path, isDirectory: nil)

            do {
                if isFolder {
                    let children = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension.lowercased() == "js" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    guard !children.isEmpty else { throw ImportError.noScriptsInFolder }
                    for child in children {
                        picked.append((name: child.lastPathComponent, data: try Self.readPickedFile(child)))
                    }
                } else {
                    picked.append((name: url.lastPathComponent, data: try Self.readPickedFile(url)))
                }
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }

        var installed = 0
        var skipped: [String] = []
        for item in picked {
            do {
                try await install(data: item.data, name: item.name, originURL: nil)
                installed += 1
            } catch ImportError.duplicate(let existingName) {
                // Duplicate content: keep exactly one copy, report the skip
                // separately from real failures.
                skipped.append("\(item.name)（与「\(existingName)」相同）")
            } catch {
                failures.append((item.name, error.localizedDescription))
            }
        }
        return (installed, skipped, failures)
    }

    /// Imports a script handed to the app by the system — the Files app's
    /// 长按 → 分享 → 零音乐 (Open In) path, registered via
    /// CFBundleDocumentTypes. Returns a user-facing result message.
    @discardableResult
    func importOpenedFile(at url: URL) async -> String {
        guard url.pathExtension.lowercased() == "js" else {
            return String(localized: "只支持导入 .js 音源脚本")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Self.readPickedFile(url)
            let script = String(data: data, encoding: .utf8) ?? ""
            try await install(data: data, name: url.lastPathComponent, originURL: nil)
            let name = LuoxueScriptMetadata.name(in: script, fallback: url.lastPathComponent)
            return String(localized: "已导入音源：\(name)")
        } catch {
            return String(localized: "导入失败：\(error.localizedDescription)")
        }
    }

    /// Imports a script from a local file (fileImporter / 本地导入).
    func installLocal(scriptAt url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Self.readPickedFile(url)
        let name = url.lastPathComponent
        try await install(data: data, name: name, originURL: nil)
    }

    /// Reads a file picked from the document picker. A plain
    /// `Data(contentsOf:)` fails on iCloud Drive placeholders ("no such
    /// file"); the coordinated read lets the file provider download the item
    /// first, and is also the retry path when the plain read fails.
    private static func readPickedFile(_ url: URL) throws -> Data {
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        var data: Data?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        if let data, !data.isEmpty {
            return data
        }
        if let coordinatorError { throw coordinatorError }
        throw CocoaError(.fileReadNoSuchFile, userInfo: [
            NSFilePathErrorKey: url.path,
        ])
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

        // Duplicate-import detection: identical content (modulo line endings
        // and surrounding whitespace) is imported once, no matter how many
        // copies are picked or pasted.
        if let existingName = existingDuplicate(of: script) {
            throw ImportError.duplicate(existingName: existingName)
        }

        let source = LuoxueInstalledSource(
            name: LuoxueScriptMetadata.name(in: script, fallback: name),
            originURL: originURL,
            filePath: scriptsDirectory.appendingPathComponent("\(UUID().uuidString).js").path,
            enabled: true,
            contentHash: Self.scriptFingerprint(script))
        do {
            try script.data(using: .utf8)?.write(to: source.fileURL, options: .atomic)
        } catch {
            throw ImportError.downloadFailed(error.localizedDescription)
        }

        entries.append(Entry(source: source, state: .loading))
        persist()
        Self.log.info("installed source: \(source.name, privacy: .public)")
        // Load in the background: with a 10 s init grace period, awaiting the
        // load here would hold the batch-import alert hostage. The entry
        // already shows 加载中 in the list.
        engineDirty = true
        Task { await reloadEngine() }
    }

    // MARK: - Per-source lifecycle

    /// Reloads one installed source (刷新). With the single shared engine,
    /// refreshing one source reloads the whole engine.
    func refresh(id: UUID) async {
        await reloadEngine()
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
        await reloadEngine()
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

    /// Enables / disables a source (开关). The shared engine only loads
    /// enabled scripts, so any toggle reloads it.
    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].source.enabled = enabled
        persist()
        entries[index].state = .idle
        engineDirty = true
        refreshReadiness()
        Task { await reloadEngine() }
    }

    /// Deletes a source and its script file (删除).
    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let source = entries[index].source
        entries.remove(at: index)
        persist()
        try? FileManager.default.removeItem(at: source.fileURL)
        Self.log.info("removed source: \(source.name, privacy: .public)")
        engineDirty = true
        refreshReadiness()
        Task { await reloadEngine() }
    }

    /// Loads every ENABLED script into a fresh shared engine — the reference
    /// app's `loadScripts`: one context, every script in list order, each
    /// with its own `currentScriptInfo`. Per-script outcomes come back in
    /// `scriptResults` and feed the per-row states in the UI.
    private func reloadEngine() async {
        guard !engineLoading else { return }
        engineLoading = true
        defer { engineLoading = false }

        let enabledEntries = entries.filter(\.enabled)
        for index in entries.indices where entries[index].enabled {
            entries[index].state = .loading
        }

        guard !enabledEntries.isEmpty else {
            engine = nil
            engineCapabilities = [:]
            engineDirty = false
            for index in entries.indices { entries[index].state = .idle }
            refreshReadiness()
            return
        }

        var inputs: [LxScriptInput] = []
        for entry in enabledEntries {
            guard let script = try? String(contentsOfFile: entry.source.filePath, encoding: .utf8),
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                entries.firstIndex(where: { $0.id == entry.id }).map { entries[$0].state = .failed(String(localized: "脚本文件为空")) }
                continue
            }
            inputs.append(LxScriptInput(
                id: entry.id,
                name: entry.name,
                meta: LuoxueScriptMetadata.meta(in: script),
                script: script))
        }

        let newEngine = LxScriptEngine()
        do {
            let result = try await newEngine.load(
                scripts: inputs,
                env: Self.environmentName(),
                version: Self.appVersion())
            engine = newEngine
            engineCapabilities = result.capabilities
            engineDirty = false
            for index in entries.indices where entries[index].enabled {
                let entry = entries[index]
                if let scriptResult = result.scriptResults[entry.id] {
                    if let error = scriptResult.error {
                        entries[index].state = .failed(error)
                    } else if scriptResult.sources.isEmpty {
                        entries[index].state = .failed(String(localized: "脚本未声明任何来源"))
                    } else {
                        entries[index].state = .ready(sources: scriptResult.sources)
                        if !scriptResult.sources.contains("wy") {
                            Self.log.warning("source \(entry.name, privacy: .public) has no 'wy' source")
                        }
                    }
                } else {
                    entries[index].state = .failed(String(localized: "脚本文件为空"))
                }
            }
        } catch {
            Self.log.error("load failed: \(error.localizedDescription, privacy: .public)")
            engine = nil
            engineCapabilities = [:]
            for index in entries.indices where entries[index].enabled {
                entries[index].state = .failed(error.localizedDescription)
            }
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
        engineDirty = true
        await reloadEngine()
        for entry in entries {
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

    /// The UA presented to the file host when playing a custom-source stream.
    /// AVPlayer's own UA (`AppleCoreMedia/…`) is refused by many 网盘 hosts;
    /// the LX mobile UA is what the script itself fetched the link with.
    static let playbackUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "lx-music-mobile/2.12.0 Mobile Safari/605.1.15"

    /// Headers every custom-source request carries: the LX mobile UA first,
    /// overridden by whatever the script itself returned for this link.
    static func mergedPlaybackHeaders(scriptHeaders: [String: String]) -> [String: String] {
        var headers = ["User-Agent": playbackUserAgent]
        for (name, value) in scriptHeaders {
            headers[name] = value
        }
        return headers
    }

    /// The `musicInfo` payload handed to scripts, matching the reference
    /// app's rich NetEase mapping — scripts read any of `songmid`, `songId`,
    /// `hash`, `strMediaMid`, `copyrightId` or `mediaId` depending on which
    /// platform they route to.
    static func musicInfoPayload(for track: Track) -> [String: Any] {
        let id = String(track.id)
        return [
            "songmid": id,
            "id": id,
            "songId": id,
            "hash": id,
            "strMediaMid": id,
            "copyrightId": id,
            "mediaId": id,
            "name": track.name,
            "singer": track.artistNames,
            "source": "wy",
            "interval": Int(track.duration),
            "albumName": track.album.name,
            "albumId": String(track.album.id),
        ]
    }

    /// Resolves a gray track's stream URL through the shared engine: every
    /// registered handler in order, every quality candidate within each
    /// handler (best first), then — the reference app's final fallback — the
    /// last link the script itself fetched via `lx.request`.
    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        if engineDirty || engine == nil || !isReady {
            await reloadEngine()
        }
        guard let engine else {
            throw AggregateResolveError(failures: [])
        }
        let candidates = Self.lxQualityCandidates(
            for: SettingsManager.shared.audioQuality,
            supported: engineCapabilities["wy"])
        do {
            let resolved = try await engine.resolve(
                source: "wy",
                musicInfo: Self.musicInfoPayload(for: track),
                qualities: candidates)
            if resolved.fromRequestCapture {
                Self.log.warning("all handlers failed; using captured request URL")
            }
            return ResolvedAudioSource(
                id: .luoxue,
                displayName: AudioSourceID.luoxue.displayName,
                url: resolved.url,
                headers: Self.mergedPlaybackHeaders(scriptHeaders: resolved.headers))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("resolve failed: \(error.localizedDescription, privacy: .public)")
            throw AggregateResolveError(failures: [error.localizedDescription])
        }
    }

    // MARK: - Quality mapping

    /// Maps the app's playback quality onto the quality tokens LX Music
    /// scripts use, falling back to whatever the script supports. The leading
    /// `atmos` / `master` entries are tokens some resolvers add beyond the
    /// standard LX set — scripts that do not declare them skip to the next
    /// candidate, so the order is safe everywhere.
    static func lxQuality(for quality: AudioQuality, supported: [String]?) -> String {
        let preference: [AudioQuality: [String]] = [
            .standard: ["128k"],
            .higher: ["192k", "320k", "128k"],
            .exhigh: ["320k", "128k"],
            .lossless: ["flac", "320k", "128k"],
            .hires: ["hires", "flac24bit", "flac", "320k", "128k"],
            .jyeffect: ["flac24bit", "flac", "320k", "128k"],
            .vivid: ["atmos", "flac24bit", "flac", "320k", "128k"],
            .sky: ["atmos", "flac24bit", "flac", "320k", "128k"],
            .jymaster: ["master", "flac24bit", "flac", "320k", "128k"],
        ]
        let order = preference[quality] ?? ["320k", "128k"]
        guard let supported, !supported.isEmpty else { return order.first ?? "128k" }
        for candidate in order where supported.contains(candidate) {
            return candidate
        }
        return supported.first ?? "128k"
    }

    /// All quality candidates to try, best first — supports the
    /// retry-with-lower-quality fallback for VIP-gated tracks.
    static func lxQualityCandidates(for quality: AudioQuality, supported: [String]?) -> [String] {
        let preference: [AudioQuality: [String]] = [
            .standard: ["128k"],
            .higher: ["192k", "320k", "128k"],
            .exhigh: ["320k", "128k"],
            .lossless: ["flac", "320k", "128k"],
            .hires: ["hires", "flac24bit", "flac", "320k", "128k"],
            .jyeffect: ["flac24bit", "flac", "320k", "128k"],
            .vivid: ["atmos", "flac24bit", "flac", "320k", "128k"],
            .sky: ["atmos", "flac24bit", "flac", "320k", "128k"],
            .jymaster: ["master", "flac24bit", "flac", "320k", "128k"],
        ]
        let order = preference[quality] ?? ["320k", "128k"]
        guard let supported, !supported.isEmpty else { return order }
        let filtered = order.filter { supported.contains($0) }
        // Fall back to whatever the source does support so the candidate
        // list is never empty.
        return filtered.isEmpty ? [supported[0]] : filtered
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
