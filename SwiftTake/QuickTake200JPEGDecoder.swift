// MARK: - QuickTake200JPEGDecoder
//
// Decodes finished QuickTake 200 JPEGs from serial transfers or local files
// with ImageIO. Raw Bayer decompression, demosaicing and the QT100/150 Kodak
// matrix do not apply here. The calling renderer applies the selected look.

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum QuickTake200DecodeError: Error {
    case notAJPEG
    case decodeFailed
}

// ImageIO supplies the decoded colour space. SwiftTake does not bundle the
// external Fujifilm ICC profile examined during camera research.

/// Decoded image and available JPEG metadata. Metadata fields are optional.
nonisolated struct QuickTake200DecodedImage {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    /// Capture timestamp from EXIF if present, else nil. The manager
    /// falls back to file mtime or the current time when nil.
    let captureDate: Date?
    /// True iff the JPEG carried a parseable EXIF dictionary at all.
    /// Diagnostic only; callers don't need to special-case it.
    let hadExif: Bool
    /// Embedded EXIF thumbnail if one was present in the JFIF, else nil.
    let embeddedThumbnail: NSImage?
}

// `nonisolated` overrides the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, same as `QTKDecoder`: this is a pure ImageIO decoder with no
// main-actor state, and it's run inside `Task.detached` off the main actor so
// large-JPEG decodes don't jank the UI. Without this, the static `decode`/
// `thumbnail` methods are implicitly `@MainActor` and calling them off-actor is
// an error in the Swift 6 language mode.
nonisolated enum QuickTake200JPEGDecoder {

    /// Decode camera or local JPEG bytes through ImageIO and extract available
    /// metadata. No external camera ICC profile is injected into the image.
    static func decode(_ data: Data) throws -> QuickTake200DecodedImage {
        // Require a JPEG start-of-image marker before invoking ImageIO.
        guard data.count >= 3,
              data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF else {
            throw QuickTake200DecodeError.notAJPEG
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw QuickTake200DecodeError.decodeFailed
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw QuickTake200DecodeError.decodeFailed
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Pull whatever metadata exists. Most QT200 files won't have
        // full EXIF, so every key here is treated as optional.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exifDict = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let captureDate = extractCaptureDate(exif: exifDict, tiff: tiffDict)
        let hadExif = exifDict != nil && !(exifDict?.isEmpty ?? true)

        // Try for an embedded thumbnail. ImageIO will manufacture one
        // from the full image if no thumbnail is embedded, which is
        // fine for us — we just want SOMETHING small for the gallery.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ]
        let embeddedThumbnail: NSImage? = {
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
        }()

        return QuickTake200DecodedImage(
            image: nsImage,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            captureDate: captureDate,
            hadExif: hadExif,
            embeddedThumbnail: embeddedThumbnail
        )
    }

    /// Lightweight gallery thumbnail straight from JPEG bytes (the camera's
    /// full image, or a cached copy). Reuses the proven EXIF/embedded-thumb
    /// extraction without the full `decode(_:)` (no full-res CGImage build, no
    /// date parsing). ImageIO generates a thumbnail when none is embedded;
    /// invalid image data returns nil.
    static func thumbnail(from data: Data, maxPixelSize: Int = 256) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
    }

    /// EXIF "compressed bits per pixel" if present — a quality signal (higher
    /// ⇒ less compression ⇒ Fine/HQ). nil when the file carries no such tag,
    /// which is the common case for these 1997 files. HARDWARE-VERIFY: the
    /// Fine/Normal threshold isn't pinned, so callers should treat a missing
    /// value as "unknown" rather than guessing.
    static func compressedBitsPerPixel(from data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        return exif[kCGImagePropertyExifCompressedBitsPerPixel] as? Double
    }

    /// Cheap EXIF-only capture-date read (no full image decode) — used to name
    /// imported files by date/time (the P.I.E. trick) so they sort in shot
    /// order. Returns nil when the JPEG carries no parseable date.
    static func captureDate(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return extractCaptureDate(exif: props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                                  tiff: props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    }

    /// Pull a capture date out of the JPEG metadata if any field has
    /// one. Tries EXIF DateTimeOriginal → EXIF DateTimeDigitized →
    /// TIFF DateTime, in that order. Returns nil if no field parses;
    /// the caller is expected to fall back to file mtime.
    private static func extractCaptureDate(exif: [CFString: Any]?, tiff: [CFString: Any]?) -> Date? {
        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        ]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current

        for value in candidates {
            if let v = value, let date = formatter.date(from: v) {
                return date
            }
        }
        return nil
    }
}
