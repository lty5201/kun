// LyricsLiveActivityCover.swift — Shared App Group + artwork helpers for the
// lyrics Live Activity (Dynamic Island / Lock Screen).
//
// Lives in KumoneCore so the app (which writes the cover + derives the lyric
// color) and the LyricsLiveActivity widget extension (which reads the cover)
// share one definition. iOS only; the Live Activity needs iOS 16.1+.
//
// Why an App Group file instead of stuffing the image into ContentState:
// a single Live Activity update is capped at ~4 KB, which a useful cover
// thumbnail does not reliably fit. The cover is therefore written as a small
// JPEG into the shared container and the ContentState only carries
// `hasCover` + the album-derived `lyricColorHex`.
//
// Manual step: the App Group `group.sb.moe.kumone-ios` must exist for the
// App ID (Apple Developer portal ▸ Identifiers ▸ App Groups) and be enabled
// in the provisioning profile, otherwise the app/extension cannot open the
// shared container and the island falls back to a music-note icon. The
// entitlements for both targets are in the repo
// (ios/Config/KumoneIOS.entitlements, ios/LyricsLiveActivity/LyricsLiveActivity.entitlements).

#if os(iOS)
import CoreGraphics
import Foundation
import UIKit

/// Shared container + artwork helpers for the lyrics Live Activity.
public enum LyricsIslandCover {
    /// App Group shared by the app and the LyricsLiveActivity extension.
    public static let appGroupIdentifier = "group.sb.moe.kumone-ios"

    /// Lyric color when there is no cover or color extraction fails: white.
    /// (The earlier gold/orange default from the screenshot was replaced by
    /// user request: no cover / extraction failure => white, never gold.)
    public static let fallbackLyricColorHex = "#FFFFFF"

    private static let coverFileName = "lyrics-cover.jpg"

    public static func sharedCoverURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(coverFileName)
    }

    /// The cover thumbnail the extension shows in the compact pill / minimal view.
    public static func loadCoverImage() -> UIImage? {
        guard let url = sharedCoverURL(),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    /// Downscales the artwork to a 96x96 JPEG and writes it into the shared
    /// container. Returns false when the container is unavailable (App Group
    /// not registered) or the image cannot be encoded.
    @discardableResult
    public static func writeCoverThumbnail(_ image: UIImage) -> Bool {
        guard let url = sharedCoverURL() else { return false }
        let target = CGSize(width: 96, height: 96)
        let renderer = UIGraphicsImageRenderer(size: target)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = thumb.jpegData(compressionQuality: 0.7) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Removes the shared cover (new track without artwork, activity ended).
    public static func removeCover() {
        guard let url = sharedCoverURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Derives the lyric color from the album cover: the most frequent
    /// saturated, mid-brightness color, brightness-clamped so it stays
    /// readable on the black Dynamic Island pill and the lock screen.
    /// Falls back to white when there is no usable color; never returns
    /// black / near-black.
    public static func dominantLyricColorHex(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return fallbackLyricColorHex }
        let size = 16
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return fallbackLyricColorHex }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets: [UInt32: Int] = [:]
        var totalR = 0, totalG = 0, totalB = 0, total = 0
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(size * size) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            totalR += r; totalG += g; totalB += b; total += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : Double(mx - mn) / Double(mx)
            let lum = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255.0
            // Skip gray / near-black / near-white pixels: they carry no album color.
            guard sat > 0.25, lum > 0.12, lum < 0.92 else { continue }
            let key = UInt32((r / 32) << 10 | (g / 32) << 5 | (b / 32))
            buckets[key, default: 0] += 1
        }
        guard total > 0 else { return fallbackLyricColorHex }
        let picked: (r: Int, g: Int, b: Int)
        if let best = buckets.max(by: { $0.value < $1.value }) {
            let k = best.key
            picked = (Int((k >> 10) & 31) * 32 + 16, Int((k >> 5) & 31) * 32 + 16, Int(k & 31) * 32 + 16)
        } else {
            picked = (totalR / total, totalG / total, totalB / total)
        }
        // Clamp brightness so the text stays readable on black.
        var (r, g, b) = (Double(picked.r) / 255, Double(picked.g) / 255, Double(picked.b) / 255)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        if lum < 0.35 {
            let f = 0.35 / max(lum, 0.01)
            r = min(1, r * f); g = min(1, g * f); b = min(1, b * f)
        }
        // Never black / near-black on the black pill.
        if r < 0.08, g < 0.08, b < 0.08 { return fallbackLyricColorHex }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
#endif
