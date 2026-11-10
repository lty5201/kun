import Foundation

// MARK: - Installed source model

/// One installed Luoxue (落雪 / LX Music) custom-source script.
///
/// Multiple scripts can be installed side by side; enabled ones are tried in
/// list order when resolving a gray track, first hit wins.
struct LuoxueInstalledSource: Codable, Identifiable, Equatable {
    /// Stable UUID; also the script file's name on disk.
    let id: UUID
    /// Display name — the script's `@name` metadata when available, else the
    /// file / URL name.
    var name: String
    /// The URL an online import downloaded the script from (nil for local or
    /// pasted imports). Kept so the row can show it and re-download on refresh.
    var originURL: String?
    /// Absolute path of the installed script inside app support.
    var filePath: String
    /// Whether the source participates in resolution.
    var enabled: Bool
    /// When the source was installed (newest last).
    var addedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        originURL: String? = nil,
        filePath: String,
        enabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.originURL = originURL
        self.filePath = filePath
        self.enabled = enabled
        self.addedAt = addedAt
    }

    var fileURL: URL { URL(fileURLWithPath: filePath) }
}

// MARK: - Per-source load state

/// Load state of one installed script, for the management UI.
enum LuoxueSourceState: Equatable {
    case idle
    case loading
    case ready(sources: [String])
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var summaryText: String {
        switch self {
        case .idle: return String(localized: "未载入")
        case .loading: return String(localized: "载入中…")
        case .ready(let sources): return String(localized: "已载入（\(sources.joined(separator: "、"))）")
        case .failed(let message): return String(localized: "载入失败：\(message)")
        }
    }
}

// MARK: - URL conversion

/// Converts shared links of GitHub / Gitee / GitLab blob pages into the raw
/// direct link the importer downloads, mirroring the reference app's
/// 「支持 GitHub/Gitee/GitLab 链接自动转换为 raw 直链」.
enum LuoxueURLConverter {
    /// Returns the direct link for a user-supplied script URL, or nil when the
    /// input is not an http(s) URL at all.
    static func directLink(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path

        // github.com/{user}/{repo}/blob/{branch}/{...path} → raw
        if host == "github.com" || host == "www.github.com" {
            if let raw = convert(path: path,
                                 marker: "/blob/", rawHost: "raw.githubusercontent.com",
                                 markerReplacement: "/") { return raw }
            // github.com/{user}/{repo}/raw/{branch}/{...path} → raw
            if let raw = convert(path: path,
                                 marker: "/raw/", rawHost: "raw.githubusercontent.com",
                                 markerReplacement: "/") { return raw }
            return trimmed
        }

        // gitee.com/{user}/{repo}/blob/{branch}/{...path} → raw
        if host == "gitee.com" || host == "www.gitee.com" {
            if let raw = convert(path: path,
                                 marker: "/blob/", rawHost: "gitee.com",
                                 markerReplacement: "/raw/") { return raw }
            return trimmed
        }

        // gitlab.com/{user}/{repo}/-/blob/{branch}/{...path} → raw
        if host == "gitlab.com" || host == "www.gitlab.com" {
            if let raw = convert(path: path,
                                 marker: "/blob/", rawHost: "gitlab.com",
                                 markerReplacement: "/raw/") { return raw }
            return trimmed
        }

        // Already a raw / CDN direct link, or any other host: use as-is.
        return trimmed
    }

    private static func convert(
        path: String,
        marker: String,
        rawHost: String,
        markerReplacement: String
    ) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let afterMarker = String(path[range.upperBound...])
        guard !afterMarker.isEmpty else { return nil }
        let beforeMarker = String(path[..<range.lowerBound])
        return "https://\(rawHost)\(beforeMarker)\(markerReplacement)\(afterMarker)"
    }

    /// A jsdelivr mirror of a GitHub raw link, used as a fallback when
    /// raw.githubusercontent.com is unreachable.
    static func jsdelivrFallback(for directLink: String) -> String? {
        guard let url = URL(string: directLink),
              let host = url.host?.lowercased(),
              host == "raw.githubusercontent.com" else { return nil }
        // /{user}/{repo}/{branch}/{...path}
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let user = parts[0], repo = parts[1], branch = parts[2], rest = parts[3...].joined(separator: "/")
        return "https://cdn.jsdelivr.net/gh/\(user)/\(repo)@\(branch)/\(rest)"
    }
}

// MARK: - Script metadata

/// Extracts display metadata from an LX Music user script's leading comment
/// block (the `@name` / `@version` headers the ecosystem uses).
enum LuoxueScriptMetadata {
    static func name(in script: String, fallback: String) -> String {
        // The LX Music ecosystem writes metadata as comment headers, e.g.
        //   // @name 某音源
        //   /*!
        //    * @name 某音源
        //    */
        if let regex = try? NSRegularExpression(pattern: "@name\\s+([^\\r\\n*]+)"),
           let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
           let range = Range(match.range(at: 1), in: script) {
            let value = script[range]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return fallback
    }
}
