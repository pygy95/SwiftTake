// MARK: - FujiQualityClassifier
//
// Fine(HQ) vs Normal(SQ) classification for the QuickTake 200 / Fuji DS-7
// family. Both modes are 640×480, so the only honest discriminator is JPEG
// compression: real bits-per-pixel from the byte length and pixel count —
// NOT the (flat, non-discriminating) declared EXIF CompressedBitsPerPixel,
// which is 2.0 on Fine and doesn't separate the modes.
//
// One threshold and one formula, shared by the pre-download (size-only) and
// post-download (measured-JPEG) checks the manager used to spell out twice.
//
// `nonisolated`: pure ImageIO math with no main-actor state; the manager
// keeps thin adapters around these for its own call sites.

import Foundation
import ImageIO
import CoreGraphics

nonisolated enum FujiQualityClassifier {
    /// QT200 Fine threshold, in actual compressed bits-per-pixel. Fine and
    /// Normal form cleanly-separated clusters:
    ///   Fine:   2.227–2.358 bpp (85–90 KB)
    ///   Normal: 1.657–1.683 bpp (63–65 KB)
    /// 1.95 sits mid-gap with comfortable margin on both sides.
    static let fineBitsPerPixel = 1.95

    /// Best-effort Fine(HQ) / Normal(SQ) for a QT200 JPEG buffer. Returns
    /// true for Fine, false for Normal, nil when the image can't be measured.
    /// Computes the real bits-per-pixel from the JPEG byte length and its
    /// pixel count — NOT the (non-discriminating) declared EXIF tag.
    static func isFine(jpeg: [UInt8]) -> Bool? {
        let data = Data(jpeg)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let bpp = Double(data.count) * 8.0 / Double(w * h)
        NSLog("[Fuji] quality bpp=%.3f (%d bytes, %dx%d)", bpp, data.count, w, h)
        return bpp >= fineBitsPerPixel
    }

    /// Fine(HQ)/Normal(SQ) from the camera-reported compressed byte size
    /// alone — no full download. QT200 frames are all 640×480, so size →
    /// bits-per-pixel is the same discriminator `isFine(jpeg:)` uses. Lets
    /// the gallery show the badge on a thumbnail before import.
    static func isFine(fromSizeBytes bytes: Int) -> Bool {
        Double(bytes) * 8.0 / (640.0 * 480.0) >= fineBitsPerPixel
    }
}
