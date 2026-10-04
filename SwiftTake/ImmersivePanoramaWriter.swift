// MARK: - ImmersivePanoramaWriter
//
// Writes the stitched strip as an EQUIRECTANGULAR photo with GPano
// metadata — the form modern headsets, Apple Vision Pro included, expect
// for a photo you can stand inside.
//
// Why this is not just the .mov renamed. A QuickTime VR panorama is
// CYLINDRICAL: the image is what you would get by wrapping a print
// around a tube, and the 1995 player un-warped it as you looked around.
// Every modern 360 viewer instead expects EQUIRECTANGULAR, where the
// vertical axis is latitude itself. The two agree along the horizon and
// diverge fast towards the poles, so handing a viewer a cylindrical strip
// and calling it 360 gives a picture that looks fine straight ahead and
// stretches wrongly the moment you look up. The reprojection below is the
// difference between the two:
//
//     cylindrical:     y = f · tan(latitude)
//     equirectangular: y = f · latitude
//
// Longitude maps linearly in BOTH, so columns are untouched and only rows
// move. That is why this costs one vertical resample rather than a full
// remap.
//
// What gets written: the occupied band only, plus GPano tags saying where
// that band sits in the full sphere. A 360 pan from a QuickTake covers
// maybe 30 degrees of the vertical, so writing the whole sphere would be
// mostly empty pixels — the CroppedArea tags exist exactly so a viewer can
// place a band correctly without them being stored.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImmersivePanoramaWriter {

    enum WriteError: LocalizedError {
        case badGeometry
        case destinationUnavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .badGeometry:           return "The panorama's geometry could not be resolved."
            case .destinationUnavailable: return "Could not create the immersive photo file."
            case .writeFailed:           return "Could not write the immersive photo."
            }
        }
    }

    /// Result of a write, for the caller to report or log.
    struct Written {
        let url: URL
        /// Pixel size of the band actually stored.
        let size: CGSize
        /// The sphere the band claims to be part of.
        let fullSize: CGSize
        /// Vertical coverage, degrees, top to bottom.
        let verticalFOV: Double
        let isFullSphere: Bool
    }

    /// Reproject and write.
    ///
    /// `sweepDegrees` is how much of the circle the strip covers — 360 for
    /// a full rotation. It comes from the stitcher, which MEASURES whether
    /// the last frame closes onto the first rather than assuming it.
    @discardableResult
    static func write(panorama strip: CGImage,
                      sweepDegrees: Double,
                      to url: URL) throws -> Written {
        let w = strip.width, h = strip.height
        guard w > 1, h > 1, sweepDegrees > 1, sweepDegrees <= 360 else {
            throw WriteError.badGeometry
        }

        // Pixels per radian of longitude. The strip's width covers exactly
        // the swept angle, which is what makes this recoverable at all.
        let sweep = sweepDegrees * .pi / 180
        let f = Double(w) / sweep

        // The sphere this band belongs to. Width is the full turn at the
        // same scale; equirectangular is 2:1 by definition (360 x 180).
        let fullWidth = Int((2 * .pi * f).rounded())
        let fullHeight = max(2, fullWidth / 2)

        // How far up and down the strip actually sees. atan, not a ratio:
        // the strip is cylindrical, so its top row is a TANGENT distance,
        // and treating it as an angle is the mistake this whole file is
        // about.
        let centreY = Double(h) / 2
        let maxLatitude = atan(centreY / f)

        // Where that band lands on the sphere. Latitude maps linearly to
        // rows here, which is the entire point of equirectangular.
        let topRow = Int((((.pi / 2) - maxLatitude) / .pi * Double(fullHeight)).rounded())
        let bottomRow = Int((((.pi / 2) + maxLatitude) / .pi * Double(fullHeight)).rounded())
        let bandHeight = max(1, bottomRow - topRow)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let src = context(from: strip, space: space),
              let out = CGContext(data: nil, width: w, height: bandHeight,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srcPixels = src.data, let outPixels = out.data
        else { throw WriteError.destinationUnavailable }

        let sp = srcPixels.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let op = outPixels.bindMemory(to: UInt8.self, capacity: w * bandHeight * 4)

        // One vertical resample. Rows only — longitude already agrees.
        for v in 0..<bandHeight {
            let latitude = (.pi / 2) - (Double(topRow + v) + 0.5) / Double(fullHeight) * .pi
            // Cylindrical inverse: where this latitude sits on the strip.
            let y = centreY - f * tan(latitude)
            let y0 = Int(floor(y))
            let frac = y - Double(y0)
            let a = min(max(y0, 0), h - 1)
            let b = min(max(y0 + 1, 0), h - 1)

            for x in 0..<w {
                let pa = (a * w + x) * 4
                let pb = (b * w + x) * 4
                let po = (v * w + x) * 4
                for c in 0..<4 {
                    let value = Double(sp[pa + c]) * (1 - frac) + Double(sp[pb + c]) * frac
                    op[po + c] = UInt8(min(255, max(0, value.rounded())))
                }
            }
        }

        guard let image = out.makeImage() else { throw WriteError.writeFailed }

        let isFullSphere = sweepDegrees >= 359.5
        let left = isFullSphere ? 0 : max(0, (fullWidth - w) / 2)

        // HEIC first, JPEG if that fails.
        //
        // HEIC is Apple's own format and the tidier answer, but encoding it
        // went wrong inside the sandboxed app while working fine from a
        // plain command-line tool against the same pixels and the same
        // folder — so something about the app's environment refuses it, and
        // a silent `catch` meant the file simply never appeared. JPEG is no
        // consolation prize here: GPano was designed for JPEG, every 360
        // viewer reads it, and nothing about a spherical photo needs HEIC.
        var url = url
        do {
            try encode(image, to: url, fullWidth: fullWidth, fullHeight: fullHeight,
                       left: left, top: topRow, isFullSphere: isFullSphere)
        } catch {
            url = url.deletingPathExtension().appendingPathExtension("jpg")
            try encode(image, to: url, fullWidth: fullWidth, fullHeight: fullHeight,
                       left: left, top: topRow, isFullSphere: isFullSphere)
        }

        return Written(url: url,
                       size: CGSize(width: w, height: bandHeight),
                       fullSize: CGSize(width: fullWidth, height: fullHeight),
                       verticalFOV: maxLatitude * 2 * 180 / .pi,
                       isFullSphere: isFullSphere)
    }

    private static func context(from image: CGImage, space: CGColorSpace) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// HEIC with a GPano XMP packet.
    ///
    /// HEIC because it is the format Apple's own camera writes and the one
    /// visionOS is happiest with. GPano because it is what actually tells a
    /// viewer this is a sphere rather than a very wide photograph — without
    /// it the same pixels are just a panorama, shown flat.
    private static func encode(_ image: CGImage, to url: URL,
                               fullWidth: Int, fullHeight: Int,
                               left: Int, top: Int,
                               isFullSphere: Bool) throws {
        let type = url.pathExtension.lowercased() == "jpg"
            ? UTType.jpeg.identifier : UTType.heic.identifier
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, type as CFString, 1, nil)
        else { throw WriteError.destinationUnavailable }

        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            "http://ns.google.com/photos/1.0/panorama/" as CFString,
            "GPano" as CFString, nil)

        func set(_ tag: String, _ value: String) {
            CGImageMetadataSetValueWithPath(
                metadata, nil, "GPano:\(tag)" as CFString, value as CFString)
        }
        set("ProjectionType", "equirectangular")
        // The flag a viewer looks at to decide between "wrap me around the
        // user" and "show a wide picture".
        set("UsePanoramaViewer", "True")
        set("FullPanoWidthPixels", "\(fullWidth)")
        set("FullPanoHeightPixels", "\(fullHeight)")
        set("CroppedAreaImageWidthPixels", "\(image.width)")
        set("CroppedAreaImageHeightPixels", "\(image.height)")
        set("CroppedAreaLeftPixels", "\(left)")
        set("CroppedAreaTopPixels", "\(top)")
        // Only claim a closed loop when the stitcher measured one. Claiming
        // it falsely makes a viewer join the two ends of a partial arc, so
        // the seam runs through scenery that was never photographed.
        if isFullSphere { set("StitchingSoftware", "SwiftTake") }

        CGImageDestinationAddImageAndMetadata(dest, image, metadata, nil)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.writeFailed }
    }
}
