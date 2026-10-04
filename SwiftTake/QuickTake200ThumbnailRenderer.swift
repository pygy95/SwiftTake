// MARK: - QuickTake200ThumbnailRenderer
//
// Renders a QuickTake 200 / Fuji DS-7 camera-side thumbnail — the payload
// returned by PIC_GET_THUMB (opcode 0x00) — into an NSImage for the gallery.
//
// The camera-side thumbnail is a fixed
// ~10,500-byte block described as "60 × 175". That's exactly 60·175 = 10,500
// bytes, i.e. one byte per pixel. The exact pixel LAYOUT (orientation, and
// whether it's raw 8-bit grayscale, a small JPEG, or a packed format) is not
// yet confirmed from a real device dump — diagnostics Section E now captures
// the first bytes so this can be pinned down.
//
// Strategy, robust to that uncertainty:
//   1. Hand the bytes to ImageIO first. If the camera actually returns a small
//      JFIF/JPEG thumbnail (plausible — the QT200 is a JPEG camera), ImageIO
//      decodes it exactly and we're done, no guessing.
//   2. Otherwise treat the buffer as raw 8-bit grayscale at the documented
//      dimensions, trying both orientations.
//   3. If neither is plausible, return nil and let the caller fall back to the
//      placeholder.
//
// HARDWARE-VERIFY: once a real `PIC_GET_THUMB 0x00` byte dump is in hand
// (diagnostics Section E), confirm the branch that fires and delete the others.

import Foundation
import AppKit
import ImageIO
import CoreGraphics

enum QuickTake200ThumbnailRenderer {

    /// Render the raw `PIC_GET_THUMB` payload into a gallery image, or nil if
    /// the bytes don't resolve to anything plausible.
    static func render(_ bytes: [UInt8]) -> NSImage? {
        guard !bytes.isEmpty else { return nil }

        // HARDWARE-CONFIRMED: the QT200 PIC_GET_THUMB block is the photo's
        // EXIF/APP1 segment. Diagnostics show NO second JPEG (`FF D8`) inside,
        // and the EXIF IFD1 describes an 80×60 thumbnail — i.e. an *uncompressed*
        // TIFF-strip thumbnail, not an embedded JPEG. Parse IFD1 directly.
        if let info = ExifThumbnail.parse(bytes), let image = info.render() {
            return image
        }

        // (Rare) embedded-JPEG path, if a sibling camera ever stores one.
        if let embedded = embeddedThumbnailJPEG(in: bytes),
           let image = decodeCompleteJPEG(embedded) {
            return image
        }
        return nil
    }

    /// Parsed EXIF IFD1 thumbnail descriptor (the "thumbnail of the main image"
    /// directory) and the raw thumbnail bytes, extracted from a QT200
    /// PIC_GET_THUMB / JPEG EXIF block.
    struct ExifThumbnail {
        let width: Int
        let height: Int
        let compression: Int           // 1 = uncompressed, 6 = JPEG
        let photometric: Int           // 2 = RGB, 6 = YCbCr (TIFF PhotometricInterpretation)
        let samplesPerPixel: Int
        let data: [UInt8]              // the thumbnail strip / JPEG bytes

        /// Human-readable summary for the diagnostic report.
        var summary: String {
            "\(width)×\(height), compression \(compression), photometric \(photometric), spp \(samplesPerPixel), \(data.count) data bytes"
        }

        /// Walk APP1 → TIFF → IFD0.next → IFD1 and pull the thumbnail. nil if the
        /// block isn't an EXIF block or has no IFD1 thumbnail.
        static func parse(_ b: [UInt8]) -> ExifThumbnail? {
            // Find "Exif\0\0" then the TIFF header.
            guard b.count > 20 else { return nil }
            var tiff = -1
            var k = 0
            while k < min(b.count - 6, 64) {
                if b[k] == 0x45, b[k+1] == 0x78, b[k+2] == 0x69, b[k+3] == 0x66, b[k+4] == 0, b[k+5] == 0 {
                    tiff = k + 6; break
                }
                k += 1
            }
            guard tiff > 0, tiff + 8 <= b.count else { return nil }
            let little = b[tiff] == 0x49
            func u16(_ o: Int) -> Int {
                guard o + 2 <= b.count else { return 0 }
                return little ? Int(b[o]) | Int(b[o+1]) << 8 : Int(b[o]) << 8 | Int(b[o+1])
            }
            func u32(_ o: Int) -> Int {
                guard o + 4 <= b.count else { return 0 }
                return little
                    ? Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24
                    : Int(b[o]) << 24 | Int(b[o+1]) << 16 | Int(b[o+2]) << 8 | Int(b[o+3])
            }
            let ifd0 = tiff + u32(tiff + 4)
            guard ifd0 + 2 <= b.count else { return nil }
            let n0 = u16(ifd0)
            let nextOff = ifd0 + 2 + n0 * 12
            let ifd1rel = u32(nextOff)
            guard ifd1rel != 0 else { return nil }
            let ifd1 = tiff + ifd1rel
            guard ifd1 + 2 <= b.count else { return nil }
            let n1 = u16(ifd1)

            var w = 0, h = 0, compression = 1, photometric = 2, spp = 3
            var jpegOff = 0, jpegLen = 0, stripOff = 0, stripLen = 0
            for i in 0..<n1 {
                let e = ifd1 + 2 + i * 12
                guard e + 12 <= b.count else { break }
                let tag = u16(e)
                switch tag {
                case 0x0100: w = u32(e + 8)
                case 0x0101: h = u32(e + 8)
                case 0x0103: compression = u16(e + 8)
                case 0x0106: photometric = u16(e + 8)
                case 0x0111: stripOff = u32(e + 8)
                case 0x0115: spp = u16(e + 8)
                case 0x0117: stripLen = u32(e + 8)
                case 0x0201: jpegOff = u32(e + 8)
                case 0x0202: jpegLen = u32(e + 8)
                default: break
                }
            }
            // Prefer JPEG (0x0201) if present, else the uncompressed strips.
            let off: Int, len: Int
            if jpegOff > 0, jpegLen > 0 { off = tiff + jpegOff; len = jpegLen }
            else if stripOff > 0, stripLen > 0 { off = tiff + stripOff; len = stripLen }
            else { return nil }
            let end = min(off + len, b.count)
            guard off >= 0, off < end else { return nil }
            return ExifThumbnail(width: w, height: h, compression: compression,
                                 photometric: photometric, samplesPerPixel: spp,
                                 data: Array(b[off..<end]))
        }

        /// Turn the extracted thumbnail bytes into an NSImage.
        func render() -> NSImage? {
            // JPEG-compressed thumbnail.
            if compression == 6 || data.first == 0xFF {
                return QuickTake200ThumbnailRenderer.decodeCompleteJPEG(Data(data))
            }
            guard width > 0, height > 0 else { return nil }
            // HARDWARE-CONFIRMED on the QT200: photometric 6 (YCbCr), 80×60,
            // 9600 bytes = 2 bytes/px = YCbCr 4:2:2.
            if photometric == 6, data.count >= width * height * 2 {
                return QuickTake200ThumbnailRenderer.ycbcr422Image(data, width: width, height: height)
            }
            // RGB / grayscale uncompressed forms (other siblings).
            if data.count >= width * height * 3 {
                return QuickTake200ThumbnailRenderer.rgbImage(data, width: width, height: height)
            }
            if data.count >= width * height {
                return QuickTake200ThumbnailRenderer.grayscaleImage(data, width: width, height: height)
            }
            return nil
        }
    }

    /// Diagnostic helper: one-line description of the EXIF thumbnail in a block.
    static func describe(_ bytes: [UInt8]) -> String {
        guard let info = ExifThumbnail.parse(bytes) else { return "no EXIF IFD1 thumbnail found" }
        let firstBytes = info.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "EXIF IFD1 thumbnail: \(info.summary); first bytes \(firstBytes)"
    }

    /// Extract the embedded thumbnail JPEG from an EXIF block: the outer JPEG
    /// starts `FF D8` at offset 0; the embedded IFD1 thumbnail is a second,
    /// complete `FF D8 … FF D9` JPEG inside it. Returns those bytes, or nil.
    private static func embeddedThumbnailJPEG(in bytes: [UInt8]) -> Data? {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        // Find the second SOI (FF D8 FF) — the embedded thumbnail's start.
        var start: Int?
        var i = 2
        while i < bytes.count - 2 {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD8, bytes[i + 2] == 0xFF { start = i; break }
            i += 1
        }
        guard let s = start else { return nil }
        // Find its EOI (FF D9), or take the rest of the block.
        var end = bytes.count
        var j = s + 2
        while j < bytes.count - 1 {
            if bytes[j] == 0xFF, bytes[j + 1] == 0xD9 { end = j + 2; break }
            j += 1
        }
        return Data(bytes[s..<end])
    }

    private static func decodeCompleteJPEG(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Decode a TIFF chunky YCbCr 4:2:2 thumbnail (the QT200 PIC_GET_THUMB
    /// format) into an RGB NSImage. Each 4-byte group is `[Y0, Y1, Cb, Cr]` and
    /// covers two horizontal pixels; chroma is shared. BT.601 full-range coeffs.
    private static func ycbcr422Image(_ data: [UInt8], width: Int, height: Int) -> NSImage? {
        let groupsPerRow = width / 2
        let bytesPerRow = groupsPerRow * 4
        guard groupsPerRow > 0, data.count >= bytesPerRow * height else { return nil }

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        func clamp(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }

        for y in 0..<height {
            for g in 0..<groupsPerRow {
                let base = y * bytesPerRow + g * 4
                let y0 = Int(data[base]), y1 = Int(data[base + 1])
                let cb = Int(data[base + 2]) - 128, cr = Int(data[base + 3]) - 128
                let rOff = (1402 * cr) / 1000
                let gOff = (-344 * cb - 714 * cr) / 1000
                let bOff = (1772 * cb) / 1000
                for (k, yy) in [(0, y0), (1, y1)] {
                    let p = (y * width + g * 2 + k) * 3
                    rgb[p]     = clamp(yy + rOff)
                    rgb[p + 1] = clamp(yy + gOff)
                    rgb[p + 2] = clamp(yy + bOff)
                }
            }
        }
        return rgbImage(rgb, width: width, height: height)
    }

    /// Build an NSImage from `width*height*3` bytes interpreted as 8-bit RGB.
    private static func rgbImage(_ bytes: [UInt8], width: Int, height: Int) -> NSImage? {
        let count = width * height * 3
        guard bytes.count >= count else { return nil }
        let pixels = Array(bytes.prefix(count))
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    /// Build an NSImage from `width*height` bytes interpreted as 8-bit gray.
    private static func grayscaleImage(_ bytes: [UInt8], width: Int, height: Int) -> NSImage? {
        let count = width * height
        guard bytes.count >= count else { return nil }
        let pixels = Array(bytes.prefix(count))
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
