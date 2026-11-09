import Foundation

/// The only playback path besides the official stream: the Luoxue (落雪 /
/// LX Music) custom user source script configured in Settings.
///
/// The former built-in providers were removed entirely — there is exactly one
/// selectable source, so there is no per-source toggle to keep in sync.
enum AudioSourceID: String, CaseIterable, Hashable {
    case luoxue

    var displayName: String {
        switch self {
        case .luoxue: return String(localized: "落雪自定义源")
        }
    }
}

struct ResolvedAudioSource {
    let id: AudioSourceID
    let displayName: String
    let url: URL
}
