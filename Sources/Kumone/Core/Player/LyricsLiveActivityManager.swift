// LyricsLiveActivityManager.swift — App-side owner of the lyrics Live Activity.
//
// Rules enforced here (user requirements):
//  1. App closed => island closes: the activity is ended with dismissalPolicy
//     .immediate on every path we control — playback pause/stop/track-end,
//     toggle off, app termination (applicationWillTerminate) and entering
//     background while not playing. A staleDate is set on every update so an
//     app that dies without running termination code still goes stale quickly.
//     LIMIT (Apple platform behaviour, not a bug in this file): if iOS kills a
//     suspended app (jetsam) or the user force-quits it, applicationWillTerminate
//     does not run and no app code can end the activity; it then lingers until
//     its 8-hour lifetime expires, the user dismisses it, or the stale date
//     marks it stale. See LiveActivity-edits.md §7.
//  2. The activity only ever starts when the user turned 歌词上岛 on (default
//     off) AND Live Activities are authorized. It never starts silently.
//  3. Lyric updates happen only when the line changes (the caller,
//     PlayerServiceIOS.updateLyricsCursor, already only fires on change; this
//     manager additionally dedupes identical ContentState).

#if os(iOS)
import ActivityKit
import Combine
import CoreLocation
import Foundation
import UIKit

/// Result of the first-time authorization check for 歌词上岛.
enum LyricsIslandAuthorization: Equatable {
    /// Live Activities enabled (and, on iOS 17.2+, frequent updates enabled).
    case granted
    /// Live Activities disabled, or frequent updates disabled: the caller must
    /// show an alert with a "去设置" button that opens the system Settings.
    case needsSettings(reason: String)
}

/// App-side owner of the lyrics Live Activity. iOS only; macOS has no island.
@MainActor
public final class LyricsLiveActivityManager: ObservableObject {
    public static let shared = LyricsLiveActivityManager()

    private var activity: Activity<LyricsLiveActivityAttributes>?
    private var lastState: LyricsLiveActivityAttributes.ContentState?
    private var cancellables = Set<AnyCancellable>()
    private let locationKeepAlive = LyricsLocationKeepAlive()
    /// Album-derived lyric color for the current track ("#RRGGBB"); white
    /// until the new cover loads or when there is no cover. Recomputed on
    /// every track change together with the cover (see updateArtwork).
    private var currentLyricColorHex: String = LyricsIslandCover.fallbackLyricColorHex
    /// Whether the current track's cover thumbnail is in the shared container.
    private var currentHasCover = false

    private init() {
        // Playback stopping anywhere (pause button, queue end, track cleared)
        // ends the island immediately — the player does not need to remember
        // to call us from every stop path.
        PlayerService.shared.$isPlaying
            .dropFirst()
            .sink { [weak self] playing in
                guard let self else { return }
                if !playing { self.endActivity() }
            }
            .store(in: &cancellables)
        PlayerService.shared.$currentTrack
            .dropFirst()
            .sink { [weak self] track in
                guard let self else { return }
                // A new track retires the old activity; the next lyric line
                // change starts a fresh one for the new song.
                if track == nil { self.endActivity() }
                else { self.resetArtworkForNewTrack() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Toggle + authorization

    /// First-time enable flow. Checks ActivityAuthorizationInfo before anything
    /// starts; never starts the activity while disabled.
    func authorizationStatus() -> LyricsIslandAuthorization {
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            return .needsSettings(reason: "当前未开启实时活动，灵动岛歌词无法显示。请在系统设置中为 Kumone 开启「实时活动」。")
        }
        if #available(iOS 17.2, *) {
            guard info.frequentPushesEnabled else {
                return .needsSettings(reason: "实时活动已开启，但「更频繁更新」未开启，歌词更新会被系统节流、容易停住。请在系统设置中为 Kumone 开启「更频繁更新」。")
            }
        }
        return .granted
    }

    /// Opens the system Settings app at this app's page.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Forwards the location toggle: asks for WhenInUse authorization only
    /// when the user enables the keep-alive switch. Never requests Always.
    func requestLocationAuthorizationIfNeeded() {
        locationKeepAlive.requestAuthorizationIfNeeded()
    }

    // MARK: - Album color + cover (visual spec)

    /// Called when the current track's artwork loads (NowPlayingManager).
    /// Derives the lyric color from the cover and writes a 96x96 thumbnail
    /// into the shared App Group container for the island pill. If an
    /// activity is already running, the new color/cover are pushed at once
    /// together with the current lyric state.
    func updateArtwork(_ image: UIImage?) {
        guard SettingsManager.shared.lyricsOnIsland else { return }
        guard let image else {
            currentLyricColorHex = LyricsIslandCover.fallbackLyricColorHex
            currentHasCover = false
            return
        }
        currentLyricColorHex = LyricsIslandCover.dominantLyricColorHex(from: image)
        currentHasCover = LyricsIslandCover.writeCoverThumbnail(image)
        guard var state = lastState, activity != nil else { return }
        state.lyricColorHex = currentLyricColorHex
        state.hasCover = currentHasCover
        guard state != lastState else { return }
        lastState = state
        Task { [activity] in await activity?.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
    }

    /// A new track starts with the fallback color and no cover until its own
    /// artwork loads, so the previous album's color/cover never leaks into
    /// the new song's island.
    private func resetArtworkForNewTrack() {
        currentLyricColorHex = LyricsIslandCover.fallbackLyricColorHex
        currentHasCover = false
        LyricsIslandCover.removeCover()
    }

    // MARK: - Lyric updates (called only when the line changes)

    /// Called from PlayerServiceIOS.updateLyricsCursor after it computes the
    /// new active line. Reads title/artist/progress from the player; the three
    /// lines come from ParsedLyrics around activeIndex.
    func lyricDidChange(previous: String?, current: String?, next: String?) {
        guard SettingsManager.shared.lyricsOnIsland else { return }
        guard let track = PlayerService.shared.currentTrack else { return }
        let state = LyricsLiveActivityAttributes.ContentState(
            title: track.name,
            artist: track.artistNames,
            previousLine: previous,
            currentLine: current,
            nextLine: next,
            isPlaying: PlayerService.shared.isPlaying,
            progress: PlayerService.shared.progress,
            duration: PlayerService.shared.duration,
            lyricColorHex: currentLyricColorHex,
            hasCover: currentHasCover
        )
        guard state != lastState else { return }
        lastState = state
        guard state.isPlaying else {
            endActivity()
            return
        }
        if let activity {
            // New song => new activity; same song => update in place.
            if activity.attributes.trackID == track.id {
                Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
            } else {
                endActivity()
                startActivity(trackID: track.id, state: state)
            }
        } else {
            startActivity(trackID: track.id, state: state)
        }
    }

    /// Re-publishes the last known lyric state (refresh button / deep link).
    /// Re-sends the same ContentState so a throttled or dropped update gets
    /// another chance. This does NOT lift Apple's update budget or the 8-hour
    /// lifetime — see LiveActivity-edits.md §7.
    func refreshActivity() {
        guard let state = lastState, let activity else { return }
        guard SettingsManager.shared.lyricsOnIsland, state.isPlaying else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
    }

    // MARK: - Lifecycle

    private func startActivity(trackID: Int, state: LyricsLiveActivityAttributes.ContentState) {
        guard authorizationStatus() == .granted else { return }
        guard Activity<LyricsLiveActivityAttributes>.activities.isEmpty else { return }
        do {
            activity = try Activity.request(
                attributes: LyricsLiveActivityAttributes(trackID: trackID),
                content: ActivityContent(state: state, staleDate: Self.staleDate())
            )
            locationKeepAlive.startIfEnabled()
        } catch {
            activity = nil
        }
    }

    /// Ends the activity with immediate dismissal: it disappears from the
    /// Dynamic Island and the Lock Screen at once instead of lingering.
    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        locationKeepAlive.stop()
        let finalState = activity.content.state
        Task { await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate) }
    }

    /// Called when the user turns 歌词上岛 off.
    func disable() {
        endActivity()
    }

    /// Called from applicationWillTerminate / entering background while idle.
    public func endForAppShutdown() {
        endActivity()
    }

    private static func staleDate() -> Date {
        // Five minutes: if the app dies without ending the activity, the Lock
        // Screen marks the lyrics stale quickly instead of showing a
        // fresh-looking frozen line for hours.
        Date().addingTimeInterval(300)
    }
}

// MARK: - Location keep-alive (opt-in, default OFF)

/// Keeps the app process awake in the background while the lyrics Live Activity
/// runs, so lyric updates can keep being attempted. Opt-in only, default off,
/// coarse accuracy, started only while an activity is running, stopped the
/// moment the activity ends.
///
/// What it does NOT do (read before enabling):
/// - It does NOT lift Apple's Live Activity update budget: updates can still be
///   throttled or dropped when the budget is spent, and the 8-hour lifetime
///   still applies. A frozen island can therefore persist even with keep-alive.
/// - It costs battery (background location) and is a privacy-sensitive
///   capability. The purpose string is in Info.plist.
/// - App Store review risk: Apple may reject background location whose purpose
///   is only to keep an app / Live Activity alive (Guidelines 2.5.4 / 5.1.1 —
///   background location must serve a core feature, not act as a keep-alive).
///   Sideloaded / TestFlight builds are less exposed, but TestFlight review
///   can still flag it. If review risk is unacceptable, leave the toggle off:
///   the island, the 3-line view and refresh all work without it.
@MainActor
final class LyricsLocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    /// Requests WhenInUse authorization only when the user enables the toggle.
    /// Never called implicitly; never requests Always.
    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func startIfEnabled() {
        guard SettingsManager.shared.lyricsIslandLocationKeepAlive else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else { return }
        guard !running else { return }
        running = true
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
    }

    // Location values are never read or stored: the updates exist only to keep
    // the process awake. Delegate methods are intentionally empty.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
#endif
