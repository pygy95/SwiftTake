// Behavioural checks for the decode/render helpers split out of
// QuickTakeSerialManager: QuickTakeThumbnailRenderer, CameraImageRenderer and
// FujiQualityClassifier. Synthetic buffers and ImageIO-encoded JPEGs only —
// no camera, no personal photos. Every assertion is on an externally
// observable outcome (a returned image's pixels or dimensions, a nil result,
// a parsed date), not on a helper's internals.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

@main
struct CameraRenderingChecks {
    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1
            print("PASS: " + name)
        }

        // ── helpers ──────────────────────────────────────────────────

        /// Rasterise into a fixed top-consistent RGBA8/sRGB buffer so pixels
        /// are inspectable regardless of the image's own backing format.
        /// (CoreGraphics draws origin-bottom-left, so row 0 here is the
        /// image's BOTTOM row — fine for uniform fills and column checks, and
        /// for "do two buffers differ".)
        func rgba(_ image: NSImage?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            let w = cg.width, h = cg.height
            guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = buf.withUnsafeMutableBytes { p in
                guard let ctx = CGContext(
                    data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? (w, h, buf) : nil
        }

        func allColorChannels(_ b: (w: Int, h: Int, px: [UInt8]), equal v: UInt8) -> Bool {
            for i in 0..<(b.w * b.h) where !(b.px[i*4] == v && b.px[i*4+1] == v && b.px[i*4+2] == v) {
                return false
            }
            return true
        }

        /// A solid-colour JPEG with optional EXIF DateTimeOriginal, via ImageIO.
        func synthJPEG(width: Int, height: Int, gray: CGFloat = 0.5,
                       quality: CGFloat = 0.8, exifDate: String? = nil) -> [UInt8] {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let cg = ctx.makeImage()!

            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(
                out, "public.jpeg" as CFString, 1, nil)!
            var props: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            if let exifDate {
                props[kCGImagePropertyExifDictionary] = [
                    kCGImagePropertyExifDateTimeOriginal: exifDate
                ] as [CFString: Any]
            }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            precondition(CGImageDestinationFinalize(dest), "JPEG encode failed")
            return [UInt8](out as Data)
        }

        func solidImage(_ w: Int, _ h: Int) -> NSImage {
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.setFillColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let cg = ctx.makeImage()!
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }

        let plainLook = FinishedLookSettings(enhanced: false, hdr: false, headroom: 1.5)
        let enhancedLook = FinishedLookSettings(enhanced: true, hdr: false, headroom: 1.5)

        // ═════════════════════════════════════════════════════════════
        // QuickTakeThumbnailRenderer — model gate & length gate
        // ═════════════════════════════════════════════════════════════
        let good = QuickTakeThumbnailRenderer.expectedByteCount   // 2400
        check(good == 80 * 60 / 2, "thumb: expectedByteCount is 2400")

        check(QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0, count: good), model: .qt200) == nil,
            "thumb: non-QTK model (qt200) rejected even at correct length")
        check(QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0, count: good), model: .fujiDS7) == nil,
            "thumb: non-QTK model (fujiDS7) rejected")

        for model in [QuickTakeModel.qt100, .qt150] {
            let tag = model == .qt100 ? "qt100" : "qt150"
            check(QuickTakeThumbnailRenderer.renderImage(
                from: [UInt8](repeating: 0xFF, count: 100), model: model) == nil,
                "thumb(\(tag)): short buffer (100 B) rejected")
            check(QuickTakeThumbnailRenderer.renderImage(
                from: [UInt8](repeating: 0xFF, count: good - 1), model: model) == nil,
                "thumb(\(tag)): truncated buffer (2399 B) rejected")
            check(QuickTakeThumbnailRenderer.renderImage(
                from: [UInt8](repeating: 0xFF, count: good + 1), model: model) == nil,
                "thumb(\(tag)): oversize buffer (2401 B) rejected")
            check(QuickTakeThumbnailRenderer.renderImage(
                from: [], model: model) == nil,
                "thumb(\(tag)): empty buffer rejected")
        }

        // ── QT100 synthetic-nibble behaviour ─────────────────────────
        // QT100 packs two pixels per byte, hi nibble first, row-major.
        // expand(n) = (n*255)/15  ⇒  0x0→0, 0xF→255.
        let qt100Black = QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0x00, count: good), model: .qt100)
        let b100Black = rgba(qt100Black)
        check(b100Black?.w == 80 && b100Black?.h == 60, "thumb(qt100): output is 80x60")
        check(b100Black.map { allColorChannels($0, equal: 0) } == true,
              "thumb(qt100): all-0x00 nibbles → black frame")

        let qt100White = QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0xFF, count: good), model: .qt100)
        check(rgba(qt100White).map { allColorChannels($0, equal: 255) } == true,
              "thumb(qt100): all-0xFF nibbles → white frame")

        // 0xF0 ⇒ every byte is (hi=0xF→255, lo=0x0→0) ⇒ columns alternate
        // 255,0,255,0…  Column alternation survives the vertical flip.
        let qt100Alt = rgba(QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0xF0, count: good), model: .qt100))!
        check(qt100Alt.px[0] == 255 && qt100Alt.px[4] == 0 && qt100Alt.px[8] == 255,
              "thumb(qt100): 0xF0 nibbles → alternating bright/dark columns")

        // ── QT150 synthetic-nibble behaviour ─────────────────────────
        // QT150 uses a 60-byte + 20-byte block pair per two rows; every one
        // of the 4800 pixels is written across the two blocks.
        let qt150White = rgba(QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0xFF, count: good), model: .qt150))
        check(qt150White?.w == 80 && qt150White?.h == 60, "thumb(qt150): output is 80x60")
        check(qt150White.map { allColorChannels($0, equal: 255) } == true,
              "thumb(qt150): all-0xFF → every pixel written white (block dance covers all)")
        check(rgba(QuickTakeThumbnailRenderer.renderImage(
            from: [UInt8](repeating: 0x00, count: good), model: .qt150))
            .map { allColorChannels($0, equal: 0) } == true,
            "thumb(qt150): all-0x00 → black frame")

        // QT100 and QT150 decoders genuinely differ on the same bytes:
        // first 60 bytes 0xFF, remainder 0x00.
        var split = [UInt8](repeating: 0x00, count: good)
        for i in 0..<60 { split[i] = 0xFF }
        let split100 = rgba(QuickTakeThumbnailRenderer.renderImage(from: split, model: .qt100))!
        let split150 = rgba(QuickTakeThumbnailRenderer.renderImage(from: split, model: .qt150))!
        check(split100.px != split150.px,
              "thumb: QT100 vs QT150 decoders produce different output for one buffer")

        // ── QT150 non-uniform pixel ordering (explicit positional check) ──
        // Read the decoded thumbnail straight from its CGImage backing
        // (top-first, no re-raster flip): grayscale byte at (x,y).
        func topRows(_ image: NSImage?) -> (w: Int, h: Int, gray: (Int, Int) -> UInt8)? {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = cg.dataProvider?.data else { return nil }
            let w = cg.width, h = cg.height, bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
            // The returned closure owns its bytes after the image and CFData go away.
            let pixels = [UInt8](data as Data)
            return (w, h, { x, y in pixels[y * bpr + x * bpp] })
        }
        // Only the first 60-byte block of the first row-pair is 0xF nibbles
        // (→255); the other 2340 bytes are 0x00. The QT150 block dance writes
        // that first block as 3 nibbles per even column — evenX, evenX+1 on
        // pixel row 0 and evenX on pixel row 1 — so:
        //   row 0  : every column 255
        //   row 1  : even columns 255, odd columns 0 (odd columns come from
        //            the 20-byte second block, which is empty)
        //   rows 2+: 0
        var q150order = [UInt8](repeating: 0x00, count: good)
        for i in 0..<60 { q150order[i] = 0xFF }
        let ord = topRows(QuickTakeThumbnailRenderer.renderImage(from: q150order, model: .qt150))!
        check((0..<ord.w).allSatisfy { ord.gray($0, 0) == 255 },
              "thumb(qt150): first-block-only buffer fully writes row 0")
        check((0..<ord.w).allSatisfy { x in ord.gray(x, 1) == (x % 2 == 0 ? 255 : 0) },
              "thumb(qt150): row 1 alternates by column parity (block 1 evens, empty block 2 odds)")
        check((0..<ord.w).allSatisfy { ord.gray($0, 2) == 0 }
              && (0..<ord.w).allSatisfy { ord.gray($0, 40) == 0 },
              "thumb(qt150): rows past the first pair stay black")
        // The QT100 decoder reads the SAME bytes purely row-major (byte i →
        // pixels 2i, 2i+1), so row 1 splits at column 40, not by parity.
        let ord100 = topRows(QuickTakeThumbnailRenderer.renderImage(from: q150order, model: .qt100))!
        check((0..<40).allSatisfy { ord100.gray($0, 1) == 255 }
              && (40..<80).allSatisfy { ord100.gray($0, 1) == 0 },
              "thumb(qt100): same bytes row-major → row 1 splits at column 40, not by parity")

        // ═════════════════════════════════════════════════════════════
        // CameraImageRenderer.applyFinishedLook
        // ═════════════════════════════════════════════════════════════
        check(CameraImageRenderer.applyFinishedLook(nil, enhancedLook) == nil,
              "look: nil image → nil")
        let src = solidImage(32, 24)
        let passthrough = CameraImageRenderer.applyFinishedLook(src, plainLook)
        check(passthrough != nil, "look: plain look returns the image (no-op)")
        let plainDims = rgba(passthrough)
        check(plainDims?.w == 32 && plainDims?.h == 24, "look: plain look preserves dimensions")
        let looked = CameraImageRenderer.applyFinishedLook(src, enhancedLook)
        let lookedDims = rgba(looked)
        check(looked != nil && lookedDims?.w == 32 && lookedDims?.h == 24,
              "look: enhanced look returns a same-size rendered image")

        // ═════════════════════════════════════════════════════════════
        // CameraImageRenderer.render — branch selection
        // ═════════════════════════════════════════════════════════════
        let jpeg640 = synthJPEG(width: 640, height: 480)

        // Fuji/QT200: JPEG decode path.
        let fujiRendered = CameraImageRenderer.render(
            model: .qt200, header: [], imageData: jpeg640,
            options: .init(look: plainLook, demoServesFinishedImages: false))
        let fujiDims = rgba(fujiRendered)
        check(fujiDims?.w == 640 && fujiDims?.h == 480,
              "render(qt200): decodes the JPEG to 640x480")

        check(CameraImageRenderer.render(
            model: .qt200, header: [], imageData: [0x00, 0x01, 0x02, 0x03, 0x04],
            options: .init(look: plainLook, demoServesFinishedImages: false)) == nil,
            "render(qt200): non-JPEG bytes → nil")

        // Demo QT100 serving a finished stand-in: JPEG (SOI) + demo flag ⇒
        // JPEG path, NOT the Bayer decoder. Proven by the odd 100x80 size
        // surviving.
        let demoJPEG = synthJPEG(width: 100, height: 80)
        let demoRendered = CameraImageRenderer.render(
            model: .qt100, header: [], imageData: demoJPEG,
            options: .init(look: plainLook, demoServesFinishedImages: true))
        let demoDims = rgba(demoRendered)
        check(demoDims?.w == 100 && demoDims?.h == 80,
              "render(qt100 demo): SOI + demo flag → JPEG path (100x80 preserved)")

        // Same bytes WITHOUT the demo flag: falls to the QTK branch, which
        // needs a real >24-byte header; an empty header yields empty QTK data
        // and the decoder returns nil.
        check(CameraImageRenderer.render(
            model: .qt100, header: [], imageData: demoJPEG,
            options: .init(look: plainLook, demoServesFinishedImages: false)) == nil,
            "render(qt100): no demo flag + empty header → QTK branch → nil")
        check(CameraImageRenderer.render(
            model: .qt150, header: [UInt8](repeating: 7, count: 10),
            imageData: [UInt8](repeating: 0xAB, count: 200),
            options: .init(look: plainLook, demoServesFinishedImages: false)) == nil,
            "render(qt150): short header (10 B) → QTK branch → nil")

        // ── Successful QT150 render of the committed IMAGE03.QTK ─────────
        // The prior render() checks only prove rejection of bad input; this
        // proves the QT150 Bayer path yields a real photo for plain AND NewTake.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IMAGE03.QTK")
        let fixture = try Data(contentsOf: fixtureURL)

        // (a) Directly through the QTK decoder on the real committed container.
        let qtkPlain = rgba(QTKDecoder().decode(data: fixture, enhanced: false, hdrEnabled: false))
        let qtkNewTake = rgba(QTKDecoder().decode(data: fixture, enhanced: true, hdrEnabled: false))
        check(qtkPlain?.w == 640 && qtkPlain?.h == 480,
              "IMAGE03.QTK: plain QT150 decode returns a 640x480 image")
        check(qtkNewTake?.w == 640 && qtkNewTake?.h == 480,
              "IMAGE03.QTK: NewTake QT150 decode returns a 640x480 image")
        check(qtkPlain != nil && !allColorChannels(qtkPlain!, equal: 0)
              && !allColorChannels(qtkPlain!, equal: 255),
              "IMAGE03.QTK: plain decode is a real photo, not a flat frame")
        check(qtkPlain != nil && qtkNewTake != nil && qtkPlain!.px != qtkNewTake!.px,
              "IMAGE03.QTK: NewTake changes pixels vs plain (enhance path ran)")

        // Truncating the same real capture's payload (valid header intact)
        // must fail decode, not hand back a reader-exhausted, partly-garbage
        // image built on top of the fixture's own header.
        let halfTruncated = fixture.prefix(736 + (fixture.count - 736) / 2)
        check(QTKDecoder().decode(data: Data(halfTruncated), enhanced: false, hdrEnabled: false) == nil,
              "IMAGE03.QTK: payload truncated to 50% fails decode instead of returning a garbage image")

        // (b) Through CameraImageRenderer.render's QTK branch. buildQTKData
        // rebuilds a qt150 container from (header, payload); the decoder reads
        // only magic + dims (bytes 544..547) + checkVal + the payload at
        // offset 736, all of which this split reproduces from IMAGE03.QTK, so
        // the Bayer bytes decoded are the fixture's own.
        var qt150Header = [UInt8](repeating: 0, count: 64)
        qt150Header[8] = fixture[546]; qt150Header[9] = fixture[547]    // width bytes → fileHeader[546/547]
        qt150Header[10] = fixture[544]; qt150Header[11] = fixture[545]  // height bytes → fileHeader[544/545]
        let qt150Payload = Array(fixture[736...])
        let renderPlain = rgba(CameraImageRenderer.render(
            model: .qt150, header: qt150Header, imageData: qt150Payload,
            options: .init(look: plainLook, demoServesFinishedImages: false)))
        let renderNewTake = rgba(CameraImageRenderer.render(
            model: .qt150, header: qt150Header, imageData: qt150Payload,
            options: .init(look: enhancedLook, demoServesFinishedImages: false)))
        check(renderPlain?.w == 640 && renderPlain?.h == 480,
              "render(qt150): IMAGE03.QTK payload renders to 640x480 (success path, not rejection)")
        check(renderPlain != nil && renderNewTake != nil && renderPlain!.px != renderNewTake!.px,
              "render(qt150): plain vs NewTake differ on the real IMAGE03.QTK payload")

        check(renderPlain != nil && qtkPlain != nil && renderPlain!.px == qtkPlain!.px,
              "render(qt150): plain pixels match the unchanged direct QTK decoder")
        check(renderNewTake != nil && qtkNewTake != nil && renderNewTake!.px == qtkNewTake!.px,
              "render(qt150): NewTake pixels match the unchanged direct QTK decoder")

        // ═════════════════════════════════════════════════════════════
        // Metadata extraction (QuickTake200JPEGDecoder)
        // ═════════════════════════════════════════════════════════════
        let dated = synthJPEG(width: 320, height: 240, exifDate: "1996:05:09 14:14:32")
        let capture = QuickTake200JPEGDecoder.captureDate(from: Data(dated))
        check(capture != nil, "meta: EXIF DateTimeOriginal is parsed")
        if let capture {
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: capture)
            check(c.year == 1996 && c.month == 5 && c.day == 9,
                  "meta: parsed capture date is 1996-05-09")
        }
        check(QuickTake200JPEGDecoder.captureDate(from: Data(synthJPEG(width: 32, height: 32))) == nil,
              "meta: JPEG without a date field → nil capture date")

        let decoded = try QuickTake200JPEGDecoder.decode(Data(synthJPEG(width: 320, height: 240)))
        check(decoded.pixelWidth == 320 && decoded.pixelHeight == 240,
              "meta: decode reports 320x240 geometry")

        // ═════════════════════════════════════════════════════════════
        // FujiQualityClassifier — Fine/Normal thresholds
        // ═════════════════════════════════════════════════════════════
        check(FujiQualityClassifier.fineBitsPerPixel == 1.95,
              "fuji: Fine threshold constant is 1.95 bpp")
        // 640x480 = 307200 px.  76800 B * 8 / 307200 = 2.0 bpp  ⇒ Fine.
        check(FujiQualityClassifier.isFine(fromSizeBytes: 76_800) == true,
              "fuji: 76800 B (2.0 bpp) classified Fine")
        check(FujiQualityClassifier.isFine(fromSizeBytes: 90_000) == true,
              "fuji: 90 KB (~2.34 bpp) classified Fine")
        check(FujiQualityClassifier.isFine(fromSizeBytes: 64_000) == false,
              "fuji: 64 KB (~1.67 bpp) classified Normal")
        check(FujiQualityClassifier.isFine(fromSizeBytes: 60_000) == false,
              "fuji: 60 KB (~1.56 bpp) classified Normal")
        check(FujiQualityClassifier.isFine(jpeg: [0x00, 0x01, 0x02]) == nil,
              "fuji: unmeasurable bytes → nil")
        check(FujiQualityClassifier.isFine(jpeg: synthJPEG(width: 640, height: 480)) != nil,
              "fuji: a valid 640x480 JPEG yields a definite Fine/Normal verdict")

        print("\nAll \(passed) camera-rendering checks passed.")
    }
}
