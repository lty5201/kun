// Ported from Moumusic (jiajia2222/Moumusic, main f3e511a0):
// platforms/ios/Sources/Kumone/Core/Storage/LXSourceStore.swift
// (struct Source + lx-sources.json format + "lx.selectedSource" /
// "lx.enabledSources" UserDefaults keys).
// Moumusic is licensed under LGPL-3.0; the Moumusic source files carry no
// per-file license header, so none is reproduced here. Keep this attribution.
//
// One-time migration: kun's old Luoxue install format -> LXSourceStore format.
//   FROM: <Application Support>/Kumone/luoxue-sources.json
//         ([LuoxueInstalledSource]: UUID id + name + originURL + filePath
//         pointing at a separate .js file under Kumone/luoxue-scripts/)
//         plus the pre-multi-source single-script path in UserDefaults
//         "settings.luoxueScriptPath" (see LuoxueSourceManager
//         migrateLegacySingleScript()).
//   TO:   <Application Support>/Kumone/lx-sources.json
//         ([LXSourceRecord]: string id + name + description + version +
//         author + homepage + INLINE script + sourceURL) and the
//         "lx.enabledSources" / "lx.selectedSource" UserDefaults keys.
//
// This file is intentionally self-contained: it does NOT reference
// LXSourceStore (owned by another group, and `#if os(iOS)` while this file
// also compiles for macOS) so it compiles in kun today.
// LXSourceRecord below is field-for-field identical to Moumusic's
// LXSourceStore.Source; the local struct stays for the reason above.
// The retired Luoxue manifest shape is likewise re-declared locally
// (LegacyLuoxueInstalledSource) and the script-header parser is local
// (scriptMetadata(in:)) — the deleted Luoxue model files are not
// referenced anywhere in this file.
//
// Safety contract (do not weaken it):
// - Never deletes, moves or overwrites luoxue-sources.json or any .js file.
// - Never throws: every failure is logged and the function returns; the app
//   keeps working with whatever sources already exist.
// - Idempotent: a UserDefaults flag plus the target file's contents make
//   re-runs no-ops; a second run never duplicates entries.
// - No third-party script content is fetched, executed or uploaded here: the
//   script text is only copied from the user's own disk into the user's own
//   lx-sources.json, exactly as a manual re-import would.
//
// WHEN TO CALL (one line, owned by the LXSourceStore group):
//   Call LXMigration.migrateLegacyLuoxueSourcesIfNeeded() FIRST inside
//   LXSourceStore.init(), before it reads lx-sources.json — or, failing that,
//   from app startup before LXSourceStore.shared is touched for the first
//   time. LXSourceStore reads its file once in init; calling migration after
//   that first access is too late for that launch (the sources would only
//   appear after a restart). Do NOT call it from LuoxueSourceManager: that
//   manager is being retired and its init would be the wrong trigger.
//
// FALLBACK IF MIGRATION IS NOT FEASIBLE (e.g. the manifest is corrupt and
// unreadable, or the user deletes lx-sources.json mid-migration):
//   Do nothing destructive. The user re-imports their scripts through
//   LXSourceStore's normal import (which accepts .js files and JSON exports),
//   and the original luoxue-sources.json + .js files are still on disk
//   untouched for that. Never delete user scripts to "force" a clean state.
import Foundation
import os.log

enum LXMigration {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "lx-migration")

    /// Marker that a migration attempt finished with a written file (or with
    /// nothing to do). Checked first so re-runs are no-ops even if the user
    /// later deletes every LX source (without this, the next launch would
    /// resurrect the old Luoxue entries).
    private static let didRunKey = "kumone.lxMigrationDidRun.v1"

    /// Mirrors Moumusic's LXSourceStore.Source exactly (same fields, same
    /// order, same JSON key names). Encoded with a plain JSONEncoder so the
    /// file LXSourceStore reads is byte-compatible with Moumusic's.
    /// NOTE: LXSourceStore has since landed, but it is `#if os(iOS)` while
    /// this file also compiles for macOS, so this local record stays — the
    /// migration cannot reference LXSourceStore.Source here.
    private struct LXSourceRecord: Codable {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let homepage: String
        let script: String
        let sourceURL: String?
    }

    /// Shape of kun's retired Luoxue install manifest (luoxue-sources.json),
    /// as written by the deleted LuoxueSourceManager. Defined locally here —
    /// NOT resurrected from the deleted LuoxueSourceModels.swift — so the
    /// one-time migration can still read manifests written before the LX
    /// port. Unknown keys in old manifests (e.g. `contentHash`) are ignored
    /// by Decodable; `enabled` defaults to true so manifests written before
    /// that flag existed still decode.
    private struct LegacyLuoxueInstalledSource: Decodable {
        let id: UUID
        let name: String
        let originURL: String?
        let filePath: String
        // Defaulted so manifests written before the flag existed still
        // decode (synthesized Decodable uses decodeIfPresent here).
        var enabled: Bool = true

        init(id: UUID = UUID(), name: String, originURL: String?, filePath: String, enabled: Bool) {
            self.id = id
            self.name = name
            self.originURL = originURL
            self.filePath = filePath
            self.enabled = enabled
        }
    }

    /// Parses `@name` / `@description` / `@version` / `@author` comment
    /// headers out of a script (same rule the LX importer uses). Replaces
    /// the deleted LuoxueScriptMetadata.meta(in:). Only keys actually
    /// present in the script are returned, so the caller's `??` fallbacks
    /// (installed display name, "") keep working.
    private static func scriptMetadata(in script: String) -> [String: String] {
        func value(_ key: String) -> String {
            for line in script.components(separatedBy: .newlines) {
                guard let range = line.range(of: "@\(key)", options: .caseInsensitive) else { continue }
                let suffix = line[range.upperBound...]
                if let first = suffix.first,
                   !first.isWhitespace, first != ":", first != "=" {
                    continue
                }
                var result = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.first == ":" || result.first == "=" {
                    result.removeFirst()
                    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !result.isEmpty { return result }
            }
            return ""
        }
        var out: [String: String] = [:]
        for key in ["name", "description", "version", "author"] {
            let v = value(key)
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    /// One-time, idempotent, non-throwing migration. See the file header for
    /// the call site and the fallback.
    static func migrateLegacyLuoxueSourcesIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: didRunKey) { return }

        // If LX sources already exist (user imported, or a previous run wrote
        // them), adopt them as-is and never overwrite.
        if let existing = try? Data(contentsOf: lxSourcesURL),
           let sources = try? JSONDecoder().decode([LXSourceRecord].self, from: existing),
           !sources.isEmpty {
            defaults.set(true, forKey: didRunKey)
            log.info("lx-sources.json already has \(sources.count) source(s); skipping legacy migration")
            return
        }

        guard let manifest = try? Data(contentsOf: luoxueManifestURL),
              let installed = try? JSONDecoder().decode([LegacyLuoxueInstalledSource].self, from: manifest) else {
            // Distinguish "no manifest" from "corrupt manifest": only the
            // former delegates to the single-script path (which marks the run
            // done when there is nothing at all). A corrupt manifest is left
            // for a later launch — setting the flag here would permanently
            // block migration of a manifest the user later repairs.
            if !FileManager.default.fileExists(atPath: luoxueManifestURL.path) {
                migrateLegacySingleScriptIfPresent()
            } else {
                log.error("legacy migration: luoxue-sources.json is unreadable; will retry next launch")
            }
            return
        }

        var records: [LXSourceRecord] = []
        var seenIDs = Set<String>()
        var seenScripts = Set<String>()
        var extraRecordID: String?
        for entry in installed {
            guard seenIDs.insert(entry.id.uuidString).inserted else { continue }
            guard FileManager.default.fileExists(atPath: entry.filePath) else {
                log.error("skipping missing script file for '\(entry.name, privacy: .public)'")
                continue
            }
            guard let script = readScript(atPath: entry.filePath, name: entry.name) else { continue }
            guard seenScripts.insert(script).inserted else {
                log.info("skipping duplicate script '\(entry.name, privacy: .public)'")
                continue
            }
            records.append(record(for: entry, script: script))
        }

        // The pre-multi-source install kept a single path in UserDefaults
        // ("settings.luoxueScriptPath"); LuoxueSourceManager folds it into the
        // manifest on its own first load, but migration may run before that
        // ever happens, so pick it up here too if the manifest did not list it.
        // An empty manifest means "no installed sources": delegate to the
        // single-script path instead of looping over nothing.
        if installed.isEmpty {
            migrateLegacySingleScriptIfPresent()
            return
        }
        if let extra = legacySingleScriptRecord(excluding: installed) {
            extraRecordID = extra.id
            records.append(extra)
        }

        guard !records.isEmpty else {
            // Manifest existed but nothing was readable. Do NOT set didRunKey:
            // a later launch (e.g. after the user restores a script file)
            // should retry. Nothing was written or deleted.
            log.error("legacy migration: manifest present but no script could be read; will retry next launch")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: lxSourcesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: lxSourcesURL, options: .atomic)
        } catch {
            // Target write failed: leave everything untouched and retry next
            // launch (didRunKey stays unset).
            log.error("legacy migration: failed to write lx-sources.json: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Mirror Moumusic LXSourceStore's own key names ("lx.enabledSources",
        // "lx.selectedSource") and its selection rule: enabled sources in
        // manifest order; the first enabled one is selected; if the user had
        // disabled everything, selected stays nil (LXSourceStore.init derives
        // the same from an empty enabled list). Matched by id, not by index:
        // `records` may be shorter than `installed` when entries were skipped,
        // and the legacy single-script record (if any) is not in `installed`
        // at all, so its id is added explicitly.
        let enabledIDSet: Set<String> = Set(installed.filter(\.enabled).map { $0.id.uuidString })
            .union(extraRecordID.map { [$0] } ?? [])
        let enabledByID: [String] = records.filter { enabledIDSet.contains($0.id) }.map(\.id)
        defaults.set(enabledByID, forKey: "lx.enabledSources")
        defaults.set(enabledByID.first, forKey: "lx.selectedSource")
        defaults.set(true, forKey: didRunKey)
        log.info("legacy migration: migrated \(records.count) source(s) to lx-sources.json")
    }

    // MARK: - Record construction

    private static func record(for entry: LegacyLuoxueInstalledSource, script: String) -> LXSourceRecord {
        // Display metadata comes from the script's own @name/@description/
        // @version/@author comment headers when present (same parser kun's
        // importer already uses); the installed display name is the fallback.
        // `id` is the installed UUID as a string. kun's installed script files
        // are named "<uuid>.js", so the filename without extension is the same
        // value; the UUID is used because it is stable even for the legacy
        // single-script file, whose path may be an arbitrary user location.
        // `homepage` has no kun equivalent and stays empty; `sourceURL` keeps
        // the download URL the script was imported from (metadata only —
        // playback always uses the inlined local script).
        let meta = scriptMetadata(in: script)
        return LXSourceRecord(
            id: entry.id.uuidString,
            name: meta["name"] ?? entry.name,
            description: meta["description"] ?? "",
            version: meta["version"] ?? "",
            author: meta["author"] ?? "",
            homepage: "",
            script: script,
            sourceURL: entry.originURL
        )
    }

    private static func readScript(atPath path: String, name: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            log.error("skipping unreadable script for '\(name, privacy: .public)'")
            return nil
        }
        // Same 10 MB cap kun's installer enforces (LuoxueSourceManager.install).
        guard data.count <= 10 * 1024 * 1024 else {
            log.error("skipping oversize script for '\(name, privacy: .public)' (\(data.count) bytes)")
            return nil
        }
        let script = String(decoding: data, as: UTF8.self)
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("skipping empty script for '\(name, privacy: .public)'")
            return nil
        }
        return script
    }

    // MARK: - Legacy single-script path

    /// The manifest is missing/unreadable but the old single-script key may
    /// still name a script. Migrates just that one file (or does nothing).
    private static func migrateLegacySingleScriptIfPresent() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: SettingsManager.Keys.luoxueScriptPath),
              FileManager.default.fileExists(atPath: path) else {
            // No legacy key / no such file: nothing to migrate at all; mark
            // done so later launches skip the (cheap but pointless) check.
            defaults.set(true, forKey: didRunKey)
            return
        }
        // File exists but is unreadable/empty/oversize: do NOT set the flag;
        // a later launch should retry.
        guard let script = readScript(atPath: path, name: URL(fileURLWithPath: path).lastPathComponent) else {
            return
        }
        let entry = LegacyLuoxueInstalledSource(
            name: URL(fileURLWithPath: path).lastPathComponent,
            originURL: nil, filePath: path, enabled: true)
        let record = record(for: entry, script: script)
        do {
            try FileManager.default.createDirectory(
                at: lxSourcesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode([record]).write(to: lxSourcesURL, options: .atomic)
        } catch {
            log.error("legacy migration: failed to write lx-sources.json: \(error.localizedDescription, privacy: .public)")
            return
        }
        defaults.set([record.id], forKey: "lx.enabledSources")
        defaults.set(record.id, forKey: "lx.selectedSource")
        defaults.set(true, forKey: didRunKey)
        log.info("legacy migration: migrated single legacy script to lx-sources.json")
    }

    /// When the manifest decoded fine, the legacy key is only used if its path
    /// is not already one of the manifest entries.
    private static func legacySingleScriptRecord(
        excluding installed: [LegacyLuoxueInstalledSource]
    ) -> LXSourceRecord? {
        guard let path = UserDefaults.standard.string(forKey: SettingsManager.Keys.luoxueScriptPath),
              !installed.contains(where: { $0.filePath == path }),
              FileManager.default.fileExists(atPath: path),
              let script = readScript(atPath: path, name: URL(fileURLWithPath: path).lastPathComponent) else {
            return nil
        }
        let entry = LegacyLuoxueInstalledSource(
            name: URL(fileURLWithPath: path).lastPathComponent,
            originURL: nil, filePath: path, enabled: true)
        return record(for: entry, script: script)
    }

    // MARK: - Paths

    /// kun's manifest location (LuoxueSourceManager.manifestURL):
    /// <Application Support>/Kumone/luoxue-sources.json. Read-only here.
    private static var luoxueManifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Kumone", isDirectory: true)
            .appendingPathComponent("luoxue-sources.json")
    }

    /// Target location. DECISION — must be identical to the LXSourceStore
    /// group's LXSourceStore.fileURL, or the migration writes a file nobody
    /// reads. This draft uses kun's existing directory ("Kumone"); Moumusic
    /// used "Moumusic" (Application Support/Moumusic/lx-sources.json). If the
    /// LXSourceStore port keeps Moumusic's directory name, change this ONE
    /// computed property (and nothing else in this file) to match.
    private static var lxSourcesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Kumone", isDirectory: true)
            .appendingPathComponent("lx-sources.json")
    }
}
