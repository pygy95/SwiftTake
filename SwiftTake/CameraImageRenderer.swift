// MARK: - CameraImageRenderer
//
// Turns raw camera image bytes into a displayable NSImage, choosing the
// decode path from the model's storage format:
//
//   • QuickTake 100/150 — proprietary QTK Bayer container, rebuilt with
//     `QTKFormatter` and developed by `QTKDecoder`; the Enhanced / HDR
//     Look is part of that develop.
//   • QuickTake 200 / Fuji DS-7 / Samsung SSC-350N — standard JFIF JPEG,
//     decoded by `QuickTake200JPEGDecoder`; the Look is applied as a
//     post-process because there is no Bayer stage to fold it into.
//   • Demo stand-ins — DRAWN images that arrive as JPEG whichever camera
//     is simulated, so a QTK-format demo photo that opens with an SOI
//     marker is taken through the JPEG path instead of the Bayer decoder
//     (which would make green garbage of it).
//
// The manager owns the `@Published` / `@MainActor` state; it snapshots the
// relevant bits into `Options` and calls `render`. This type holds none of
// its own.

import AppKit
import Foundation

enum CameraImageRenderer {

    /// The pieces of manager state a render needs, snapshotted on the main
    /// actor so the decode itself never touches `@Published` state.
    struct Options {
        /// The finished-image Look (Enhanced / HDR / headroom). Drives both
        /// the QTK develop parameters and the finished-JPEG post-process.
        var look: FinishedLookSettings
        /// True when a demo camera that hands over finished (drawn) images is
        /// connected. Only then can a QTK-format model actually be carrying a
        /// JPEG stand-in rather than a Bayer mosaic.
        var demoServesFinishedImages: Bool
    }

    /// Decode raw camera image bytes into a displayable image, per the model's
    /// storage format. Returns `nil` if decoding fails.
    static func render(model: QuickTakeModel,
                       header: [UInt8],
                       imageData: [UInt8],
                       options: Options) -> NSImage? {
        // Demo stand-ins are drawn rather than photographed, so there is no
        // Bayer mosaic behind them and they arrive as JPEG whichever camera
        // is being simulated. Checked before the QTK branch so the demo
        // QuickTake 150 shows pictures instead of the green garbage a Bayer
        // decode makes of a JPEG. A real QT100/150 payload is compressed
        // mosaic and never opens with an SOI marker, so this cannot catch
        // one — and it is gated on the demo camera regardless.
        if model.usesQTKFormat, options.demoServesFinishedImages,
           imageData.count > 3, imageData[0] == 0xFF, imageData[1] == 0xD8, imageData[2] == 0xFF {
            return applyFinishedLook(
                (try? QuickTake200JPEGDecoder.decode(Data(imageData)))?.image, options.look)
        }
        if model.usesQTKFormat {
            let qtkData = QTKFormatter.buildQTKData(model: model, imageHeader: header, imageData: imageData)
            return QTKDecoder().decode(
                data: qtkData, enhanced: options.look.enhanced,
                hdrEnabled: options.look.hdr, hdrHeadroom: options.look.headroom
            )
        }
        // Fuji/QT200: standard JFIF JPEG, already display-referred sRGB.
        // No Bayer decode to hook into, but the Look's post-process is not
        // Bayer-specific — only the transfer curve is, and FinishedImageLook
        // supplies the sRGB one.
        return applyFinishedLook(
            (try? QuickTake200JPEGDecoder.decode(Data(imageData)))?.image,
            options.look)
    }

    /// Apply the Look to an already-finished image — the QT200 family,
    /// whose JPEGs arrive from the camera fully rendered.
    ///
    /// Falls back to the untouched image on any failure. A look is a
    /// nicety; a missing photo is not, and this runs mid-import.
    ///
    /// `nonisolated`: the import loop's detached decode tasks call this
    /// directly, off the main actor, as well as `render`.
    nonisolated static func applyFinishedLook(
        _ image: NSImage?, _ look: FinishedLookSettings
    ) -> NSImage? {
        guard let image, look.enhanced || look.hdr,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }
        return FinishedImageLook.render(cg, enhanced: look.enhanced,
                                        hdr: look.hdr, headroom: look.headroom) ?? image
    }
}
