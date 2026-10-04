// MARK: - PhotoExporter
//
// The state-independent tail of a photo import: optional date-stamp
// burn-in, colour-space tagging, and an atomic encode to disk. Every
// input arrives in `ExportJob`, snapshotted by the caller on the main
// actor; nothing here reads app, camera, or user-defaults state.
//
// `nonisolated` (the project defaults to `@MainActor`): pure CG / ImageIO /
// AppKit-drawing work, run inside `Task.detached` so a per-photo encode
// doesn't hitch the UI.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated enum PhotoExporter {

    /// Inputs for one detached export, snapshotted by the caller.
    ///
    /// `@unchecked Sendable`: `CGImage` and the ImageIO property dictionary
    /// are not formally `Sendable`. Callers must pass immutable values —
    /// `CGImage` is immutable, so sharing it across actors is safe even
    /// though the caller keeps its own reference (e.g. for the preview).
    struct ExportJob: @unchecked Sendable {
        let cgImage: CGImage
        let properties: [String: Any]
        let stampEnabled: Bool
        let captureDate: Date?
        let useP3: Bool
        let formatUTI: String
        let fileURL: URL
        /// Defaults to the safe choice: refuse rather than silently replace.
        /// A caller that already has the user's consent to overwrite this
        /// exact file (the camera-batch Replace decision) passes `.replace`.
        let collisionMode: AtomicFileWriter.CollisionMode
        /// Optional thread-safe guard for one-shot exports.
        let isCurrent: @Sendable () -> Bool

        init(cgImage: CGImage, properties: [String: Any], stampEnabled: Bool, captureDate: Date?,
             useP3: Bool, formatUTI: String, fileURL: URL,
             collisionMode: AtomicFileWriter.CollisionMode = .exclusive,
             isCurrent: @escaping @Sendable () -> Bool = { true }) {
            self.cgImage = cgImage
            self.properties = properties
            self.stampEnabled = stampEnabled
            self.captureDate = captureDate
            self.useP3 = useP3
            self.formatUTI = formatUTI
            self.fileURL = fileURL
            self.collisionMode = collisionMode
            self.isCurrent = isCurrent
        }
    }

    /// Thrown when the encode step fails. The atomic rename can additionally
    /// surface a `POSIXError`. Both reach the user as "Save error: …".
    private enum ExportError: LocalizedError {
        case cannotCreateFile(URL)
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile:
                return "the destination folder isn’t writable (check the folder in Settings → Image, or pick a new one)."
            case .writeFailed:
                return "couldn’t finish writing — the disk may be full."
            }
        }
    }

    /// Stamp before colour-space tagging. An invalid capture date stamps
    /// "now" without that fallback reaching the metadata.
    ///
    /// Re-renders through a tagged colour space so ImageIO embeds a profile.
    /// HDR needs its own space: the decoder outputs Float16 extended-linear
    /// sRGB with values > 1.0. An 8-bit context clamps those to white, and
    /// ImageIO won't emit extended-linear anyway, so convert to Rec.2100 PQ
    /// at 16 bits and encode from there. HDR is detected from the image's
    /// float components, not a flag, so it can't disagree with the decoder.
    ///
    /// Shared by `performExport` and `encodeToTemporary` so the two entry
    /// points can never disagree on what actually gets rasterised.
    private static func renderForExport(_ job: ExportJob) -> CGImage {
        let stampedCG: CGImage = {
            guard job.stampEnabled else { return job.cgImage }
            return stampDate(on: job.cgImage, at: job.captureDate ?? Date()) ?? job.cgImage
        }()
        let isHDR = stampedCG.bitmapInfo.contains(.floatComponents)
        let targetSpaceName: CFString = isHDR
            ? CGColorSpace.itur_2100_PQ
            : (job.useP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        let targetSpace = CGColorSpace(name: targetSpaceName)
            ?? stampedCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return recolor(stampedCG, to: targetSpace, hdr: isHDR) ?? stampedCG
    }

    /// Encodes `image` (already stamped/colour-tagged by `renderForExport`)
    /// to `url` in `job.formatUTI`. A nil destination means the folder isn't
    /// writable (scope inactive, read-only volume, bad path) — a save error,
    /// not a decode failure. `Finalize` returns false on an I/O failure —
    /// most commonly a full disk.
    private static func encodeImage(_ image: CGImage, job: ExportJob, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, job.formatUTI as CFString, 1, nil) else {
            throw ExportError.cannotCreateFile(job.fileURL)
        }
        CGImageDestinationAddImage(destination, image, job.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(job.fileURL)
        }
    }

    /// Stamp (optional) → colour-space re-render → atomic encode + publish,
    /// all in one call. Only a write failure throws (`ExportError` from the
    /// encode, `POSIXError`/`AtomicFileWriter` errors from publication).
    static func performExport(_ job: ExportJob) throws -> URL? {
        let taggedImage = renderForExport(job)
        try AtomicFileWriter.write(to: job.fileURL, collisionMode: job.collisionMode, isCurrent: job.isCurrent) { temporary in
            try encodeImage(taggedImage, job: job, to: temporary)
        }
        return job.fileURL
    }

    /// Stage the encoded image without publishing; remove the stage on failure.
    static func encodeToTemporary(_ job: ExportJob) throws -> URL {
        let taggedImage = renderForExport(job)
        let temporary = AtomicFileWriter.temporaryURL(besides: job.fileURL)
        do {
            try encodeImage(taggedImage, job: job, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return temporary
    }

    /// Encode off-main, then check the owning job and publish without another
    /// suspension. The encoder adapter lets tests pause a real staged export.
    @MainActor
    static func exportOffMain(
        _ job: ExportJob,
        isCurrent: () -> Bool,
        encode: @escaping @Sendable (ExportJob) throws -> URL = { try encodeToTemporary($0) }
    ) async throws -> URL? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let temporary = try await Task.detached(priority: .userInitiated) {
            try encode(job)
        }.value
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard !Task.isCancelled, isCurrent() else { return nil }
        try AtomicFileWriter.publish(temporary, to: job.fileURL,
                                     collisionMode: job.collisionMode, isCurrent: job.isCurrent)
        return job.fileURL
    }

    /// Redraws `image` into a fresh CGContext backed by `colorSpace` so the
    /// result advertises that space (and embeds its ICC profile on write).
    ///
    /// `.noneSkipLast`, not `.premultipliedLast`: QuickTake images are opaque,
    /// and an alpha-tagged context makes ImageIO warn and strip the alpha
    /// anyway. Byte layout is identical; only byte 4 is reinterpreted. 8-bit
    /// for SDR; 16-bit for HDR, where 8 would clamp away the PQ headroom.
    private static func recolor(_ image: CGImage, to colorSpace: CGColorSpace,
                                hdr: Bool = false) -> CGImage? {
        let width = image.width
        let height = image.height
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | (hdr ? CGBitmapInfo.byteOrder16Little.rawValue
                   : CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: hdr ? 16 : 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Burns an "MM DD 'YY" date stamp into the bottom-right corner. Returns
    /// a new CGImage; the source is not mutated. Sizing and placement are
    /// keyed to the long edge (~3.8% font, ~3% inset) so HQ and SQ frames get
    /// a proportionally identical stamp. Font: Monaco, falling back to Courier
    /// then the system fixed-pitch font. Returns nil if the stamp context
    /// can't be created, which lets the caller fall back to the unstamped image.
    static func stampDate(on image: CGImage, at date: Date) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM dd ''yy"
        let stamp = formatter.string(from: date)

        // `.noneSkipLast` for the same opaque-image reason as `recolor`.
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let longEdge = CGFloat(max(width, height))
        let fontSize = max(13, longEdge * 0.038)

        let stampFont: NSFont = {
            if let monaco = NSFont(name: "Monaco", size: fontSize) {
                return monaco
            }
            if let courierBold = NSFont(name: "Courier-Bold", size: fontSize) {
                return courierBold
            }
            if let courier = NSFont(name: "Courier", size: fontSize) {
                return courier
            }
            return NSFont.userFixedPitchFont(ofSize: fontSize)
                ?? NSFont.boldSystemFont(ofSize: fontSize)
        }()

        // Dark outline for legibility on any background; soft drop shadow for depth.
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.78)
        glow.shadowBlurRadius = max(1.2, fontSize * 0.13)
        glow.shadowOffset = NSSize(width: 0, height: -1)

        // Burnt-amber date-imprint colour.
        let stampColor = NSColor(srgbRed: 0.93, green: 0.46, blue: 0.06, alpha: 1.0)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: stampFont,
            .foregroundColor: stampColor,
            .shadow: glow,
            .kern: fontSize * 0.04,
        ]
        let attributed = NSAttributedString(string: stamp, attributes: attributes)
        let textSize = attributed.size()

        let inset = longEdge * 0.03
        let drawRect = CGRect(
            x: CGFloat(width) - textSize.width - inset,
            y: inset,
            width: textSize.width + 4,
            height: textSize.height + 4
        )

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        attributed.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }
}
