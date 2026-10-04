//
//  QTVRPanoramaWriter.swift
//  SwiftTake
//
//  Writes a QuickTime VR 1.0 single-node panorama movie from a stitched
//  cylindrical strip — the format the 1995 Authoring Tools' `p2mv` +
//  `msnm` pair produced, playable in QuickTime 2.5+ under the 'STpn'
//  panorama controller.
//
//  The emitted scaffolding mirrors the July 1995 QTVR CD movies beam
//  for beam (see Tools/QTVRHarness): flattened single-fork file, mdat
//  first; movie timescale 600 with 300 units per tile; scene track
//  DISABLED (tkhd flags 0x0E) holding 24 spatially-compressed tiles;
//  pano track ENABLED (flags 0x0F) on a gmhd/gmin base-media info with
//  media handler 'STpn', its tkhd carrying the player WINDOW size, its
//  single 64-byte sample the 'pHdr' node header; movie user data 'ctyp'
//  = 'STpn'.
//
//  Geometry: the strip arrives viewer-oriented (width = the full 360°
//  circumference). v1 players expect the image rotated 90° CCW, so the
//  stored frames are strip-height wide and the strip is diced along its
//  width into 24 tiles. The strip width is resampled to a multiple of
//  96 first — the Authoring Tools' own rule (24 tiles × 4px) — which is
//  the ONLY divisibility the format truly needs; Apple's files break
//  the documented height rule (768×125 tiles), so we don't enforce one.
//
//  Tiles are Photo JPEG ('jpeg'): period QuickTime decodes it natively
//  and modern ImageIO encodes it. Cinepak parity is a non-goal until
//  someone ships a Cinepak encoder.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Options

nonisolated struct QTVRPanoramaWriterOptions {
    /// Horizontal sweep the strip covers, in degrees. 360 (default)
    /// makes a wraparound panorama; anything less writes a partial arc
    /// (the period NoWrap workflow) — the player then stops at the
    /// edges instead of wrapping. The strip's full width always maps
    /// onto this sweep.
    var sweepDegrees: Double = 360
    /// Vertical pan limit (±degrees). Pass the stitcher's cylAngle/2
    /// when available; `nil` derives it from cylinder geometry
    /// (TN4's rendered-panorama formula: ±atan(h / (2·(w/2π)))).
    var vPanRange: Double?
    var defaultPan: Double = 0
    var defaultTilt: Double = 0
    var defaultZoom: Double = 65        // the corpus norm for "normal view"
    /// Player window size stored on the pano track (period default).
    var windowWidth: Int = 320
    var windowHeight: Int = 240
    var jpegQuality: Double = 0.9
}

nonisolated enum QTVRWriteError: Error, CustomStringConvertible {
    case badImage(String)
    case encodeFailed(String)
    case invalidOption(String)

    var description: String {
        switch self {
        case .badImage(let why): return "unusable panorama image: \(why)"
        case .encodeFailed(let why): return "tile encode failed: \(why)"
        case .invalidOption(let why): return "invalid panorama option: \(why)"
        }
    }
}

/// Every angle below is written through `Writer.fixed(_:)`, which converts
/// to Fixed 16.16 with `Int32((v * 65536).rounded())` — Swift's Double→Int32
/// conversion traps (crashes) on NaN, infinity, and any finite value whose
/// magnitude exceeds Int32 range (~32767.9998°), not just on non-finite
/// input. Each angle option also has a physical domain narrower than that
/// trap threshold, so validation rejects both: values that would crash the
/// conversion, and values that are finite but geometrically nonsensical.
private nonisolated enum QTVRAngleBounds {
    /// Horizontal sweep in degrees: more than one full turn (360°) is not
    /// a panorama this writer can express (the strip's width already maps
    /// onto exactly one sweep).
    static let sweepDegrees = 0.0 ... 360.0
    /// Vertical pan half-range: 90° (straight up/down) is the physical
    /// ceiling for a cylindrical panorama's vertical field.
    static let vPanRange = 0.0 ... 90.0
    /// Pan heading: conventionally [0, 360), but the corpus and the
    /// writer both tolerate the wrapped range either side of one turn.
    static let pan = -360.0 ... 360.0
    /// Tilt: bounded by looking straight up or down.
    static let tilt = -90.0 ... 90.0
    /// Zoom/field of view in degrees: must be a positive angle, and 180°
    /// (a full hemisphere) is the widest a rectilinear FOV can express.
    static let zoom = 0.0 ... 180.0

    static func validate(_ value: Double, _ range: ClosedRange<Double>,
                         excludingLowerBound: Bool, name: String) throws {
        guard value.isFinite, range.contains(value),
              !(excludingLowerBound && value == range.lowerBound) else {
            throw QTVRWriteError.invalidOption(
                "\(name) must be in \(excludingLowerBound ? "(" : "[")\(range.lowerBound), \(range.upperBound)], got \(value)")
        }
    }
}

// MARK: - Writer

nonisolated enum QTVRPanoramaWriter {

    static let tileCount = 24
    private static let timeScale: UInt32 = 600
    private static let tileDuration: UInt32 = 300

    /// Dice `panorama` (a viewer-oriented cylindrical strip: width =
    /// 360° of scene) and write a flattened v1 panorama movie.
    static func write(panorama: CGImage, to url: URL,
                      options: QTVRPanoramaWriterOptions = .init()) throws {
        guard panorama.width >= tileCount * 4, panorama.height >= 4 else {
            throw QTVRWriteError.badImage("\(panorama.width)x\(panorama.height) is too small")
        }
        // sweepDegrees is also a divisor below (impliedCircumference), so
        // it needs an explicit >0 in addition to the shared angle check.
        try QTVRAngleBounds.validate(options.sweepDegrees, QTVRAngleBounds.sweepDegrees,
                                     excludingLowerBound: true, name: "sweepDegrees")
        if let vPanRange = options.vPanRange {
            try QTVRAngleBounds.validate(vPanRange, QTVRAngleBounds.vPanRange,
                                         excludingLowerBound: true, name: "vPanRange")
        }
        try QTVRAngleBounds.validate(options.defaultPan, QTVRAngleBounds.pan,
                                     excludingLowerBound: false, name: "defaultPan")
        try QTVRAngleBounds.validate(options.defaultTilt, QTVRAngleBounds.tilt,
                                     excludingLowerBound: false, name: "defaultTilt")
        try QTVRAngleBounds.validate(options.defaultZoom, QTVRAngleBounds.zoom,
                                     excludingLowerBound: true, name: "defaultZoom")
        // windowWidth/Height reach tkhd as a Fixed 16.16 field, same as the
        // angles above: negative or huge Int traps UInt32(_:), and anything
        // at or above 32768 sets bit 31 of the shifted UInt32, which every
        // reader in this file (and the format's own Fixed convention)
        // interprets as a negative value on read-back.
        for (name, value) in [("windowWidth", options.windowWidth), ("windowHeight", options.windowHeight)] {
            guard value > 0, value <= 32767 else {
                throw QTVRWriteError.invalidOption("\(name) must be in [1, 32767], got \(value)")
            }
        }
        // jpegQuality only affects tile compression, not file structure —
        // sanitize rather than fail the whole export over a slider value.
        let jpegQuality = options.jpegQuality.isFinite
            ? min(1, max(0, options.jpegQuality)) : 0.9

        // Snap the circumference to the tile grid, then rotate CCW so
        // the strip's left edge becomes the BOTTOM of frame 0 — after
        // which dicing top-to-bottom walks the scene left-to-right,
        // matching how the period player maps increasing sample index
        // to increasing pan.
        let snappedWidth = max(96, (panorama.width / 96) * 96)
        let evenHeight = max(4, panorama.height & ~1)
        let strip = try resample(panorama, width: snappedWidth, height: evenHeight)
        let rotated = try rotateCCW(strip)

        let tileWidth = rotated.width                 // = strip height
        let tileHeight = rotated.height / tileCount   // = strip width / 24
        // Written as UInt16 below (tkhd/stsd); range-check before that
        // conversion traps instead of after.
        guard tileWidth > 0, tileWidth <= 65535, tileHeight > 0, tileHeight <= 65535 else {
            throw QTVRWriteError.badImage("tile \(tileWidth)x\(tileHeight) exceeds the format's 16-bit field")
        }

        var tiles: [Data] = []
        for i in 0 ..< tileCount {
            let rect = CGRect(x: 0, y: i * tileHeight, width: tileWidth, height: tileHeight)
            guard let tile = rotated.cropping(to: rect) else {
                throw QTVRWriteError.badImage("tile \(i) crop failed")
            }
            tiles.append(try encodeJPEG(tile, quality: jpegQuality))
        }

        // TN4 cylinder geometry; for partial arcs the radius comes from
        // the full-circle circumference the sweep implies, not the strip.
        let impliedCircumference = Double(strip.width) * 360.0 / options.sweepDegrees
        let vPan = options.vPanRange
            ?? (atan(Double(strip.height) / (2.0 * impliedCircumference / (2.0 * .pi)))
                * 180.0 / .pi)

        let movie = buildMovie(
            tiles: tiles, tileWidth: tileWidth, tileHeight: tileHeight,
            sceneSizeX: UInt32(tileWidth),            // rotated-image width  = pano height
            sceneSizeY: UInt32(rotated.height),       // rotated-image height = circumference
            vPanRange: vPan, options: options)
        try movie.write(to: url, options: .atomic)
    }

    // MARK: Image plumbing

    private static func resample(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        if image.width == width && image.height == height { return image }
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw QTVRWriteError.badImage("resample context") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw QTVRWriteError.badImage("resample") }
        return out
    }

    private static func rotateCCW(_ image: CGImage) throws -> CGImage {
        let w = image.height, h = image.width
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw QTVRWriteError.badImage("rotate context") }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw QTVRWriteError.badImage("rotate") }
        return out
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw QTVRWriteError.encodeFailed("destination") }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw QTVRWriteError.encodeFailed("finalize")
        }
        return data as Data
    }

    // MARK: Atom assembly

    private struct AtomBuilder {
        var data = Data()

        mutating func u8(_ v: UInt8)   { data.append(v) }
        mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
        mutating func u32(_ v: UInt32) {
            data.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
                                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        mutating func s32(_ v: Int32)  { u32(UInt32(bitPattern: v)) }
        mutating func fixed(_ v: Double) { s32(Int32((v * 65536.0).rounded())) }
        mutating func fourCC(_ s: String) { data.append(s.data(using: .macOSRoman)!) }
        mutating func zeros(_ n: Int)  { data.append(Data(count: n)) }
        mutating func raw(_ d: Data)   { data.append(d) }

        /// Identity transform, the only matrix the period files carry.
        mutating func identityMatrix() {
            u32(0x0001_0000); u32(0); u32(0)
            u32(0); u32(0x0001_0000); u32(0)
            u32(0); u32(0); u32(0x4000_0000)
        }
    }

    private static func atom(_ type: String, _ payload: Data) -> Data {
        var b = AtomBuilder()
        b.u32(UInt32(payload.count + 8))
        b.fourCC(type)
        b.raw(payload)
        return b.data
    }

    private static func atom(_ type: String, _ build: (inout AtomBuilder) -> Void) -> Data {
        var b = AtomBuilder()
        build(&b)
        return atom(type, b.data)
    }

    private static func buildMovie(tiles: [Data], tileWidth: Int, tileHeight: Int,
                                   sceneSizeX: UInt32, sceneSizeY: UInt32,
                                   vPanRange: Double,
                                   options: QTVRPanoramaWriterOptions) -> Data {
        let duration = UInt32(tiles.count) * tileDuration

        // ── mdat layout: 24 tiles, then the 64-byte pHdr sample.
        var mdatPayload = Data()
        var tileOffsets: [UInt32] = []
        let mdatStart: UInt32 = 8
        for tile in tiles {
            tileOffsets.append(mdatStart + UInt32(mdatPayload.count))
            mdatPayload.append(tile)
        }
        let panoSampleOffset = mdatStart + UInt32(mdatPayload.count)
        mdatPayload.append(panoramaHeaderSample(options: options))

        // ── pHdr sample constants
        let panoSampleSize = UInt32(64)

        // ── scene (video) track, DISABLED
        let sceneTrak = atom("trak") { t in
            t.raw(tkhd(trackID: 1, enabled: false, duration: duration,
                       width: tileWidth, height: tileHeight))
            t.raw(edts(duration: duration))
            t.raw(atom("mdia") { m in
                m.raw(mdhd(duration: duration))
                m.raw(hdlr(type: "mhlr", subtype: "vide"))
                m.raw(atom("minf") { mi in
                    mi.raw(atom("vmhd") { v in
                        v.u32(1)                        // version 0, flags 1 (per spec)
                        v.u16(0x0040)                   // ditherCopy
                        v.u16(0x8000); v.u16(0x8000); v.u16(0x8000)
                    })
                    mi.raw(hdlr(type: "dhlr", subtype: "alis"))
                    mi.raw(dinf())
                    mi.raw(atom("stbl") { s in
                        s.raw(atom("stsd") { sd in
                            sd.u32(0); sd.u32(1)
                            sd.raw(videoSampleDescription(width: tileWidth, height: tileHeight))
                        })
                        s.raw(atom("stts") { st in
                            st.u32(0); st.u32(1)
                            st.u32(UInt32(tiles.count)); st.u32(tileDuration)
                        })
                        s.raw(atom("stsc") { sc in
                            sc.u32(0); sc.u32(1)
                            sc.u32(1); sc.u32(1); sc.u32(1)
                        })
                        s.raw(atom("stsz") { sz in
                            sz.u32(0); sz.u32(0); sz.u32(UInt32(tiles.count))
                            for tile in tiles { sz.u32(UInt32(tile.count)) }
                        })
                        s.raw(atom("stco") { co in
                            co.u32(0); co.u32(UInt32(tileOffsets.count))
                            for off in tileOffsets { co.u32(off) }
                        })
                    })
                })
            })
        }

        // ── pano track, ENABLED; tkhd carries the player window size.
        let panoTrak = atom("trak") { t in
            t.raw(tkhd(trackID: 2, enabled: true, duration: duration,
                       width: options.windowWidth, height: options.windowHeight))
            t.raw(edts(duration: duration))
            t.raw(atom("mdia") { m in
                m.raw(mdhd(duration: duration))
                m.raw(hdlr(type: "mhlr", subtype: "STpn"))
                m.raw(atom("minf") { mi in
                    mi.raw(atom("gmhd") { g in
                        g.raw(atom("gmin") { gm in
                            gm.u32(0)
                            gm.u16(0x0040)
                            gm.u16(0x8000); gm.u16(0x8000); gm.u16(0x8000)
                            gm.u16(0)       // balance
                            gm.u16(0)
                        })
                    })
                    mi.raw(hdlr(type: "dhlr", subtype: "alis"))
                    mi.raw(dinf())
                    mi.raw(atom("stbl") { s in
                        s.raw(atom("stsd") { sd in
                            sd.u32(0); sd.u32(1)
                            sd.raw(panoramaDescription(
                                sceneSizeX: sceneSizeX, sceneSizeY: sceneSizeY,
                                tileCount: tiles.count, vPanRange: vPanRange,
                                sweepDegrees: options.sweepDegrees))
                        })
                        s.raw(atom("stts") { st in
                            st.u32(0); st.u32(1)
                            st.u32(1); st.u32(duration)
                        })
                        s.raw(atom("stsc") { sc in
                            sc.u32(0); sc.u32(1)
                            sc.u32(1); sc.u32(1); sc.u32(1)
                        })
                        s.raw(atom("stsz") { sz in
                            sz.u32(0); sz.u32(panoSampleSize); sz.u32(1)
                        })
                        s.raw(atom("stco") { co in
                            co.u32(0); co.u32(1); co.u32(panoSampleOffset)
                        })
                    })
                })
            })
        }

        let moov = atom("moov") { m in
            m.raw(atom("mvhd") { h in
                h.u32(0)                    // version/flags
                h.u32(0); h.u32(0)          // creation/modification
                h.u32(timeScale); h.u32(duration)
                h.u32(0x0001_0000)          // rate 1.0
                h.u16(0x0100)               // volume
                h.zeros(10)
                h.identityMatrix()
                h.zeros(24)                 // preview/poster/selection/current
                h.u32(3)                    // next track ID
            })
            m.raw(sceneTrak)
            m.raw(panoTrak)
            m.raw(atom("udta") { u in
                u.raw(atom("ctyp") { c in c.fourCC("STpn") })
            })
        }

        return atom("mdat", mdatPayload) + moov
    }

    // MARK: Track pieces

    private static func tkhd(trackID: UInt32, enabled: Bool, duration: UInt32,
                             width: Int, height: Int) -> Data {
        atom("tkhd") { b in
            // Flags: inMovie|inPreview|inPoster (0x0E), +enabled (0x01)
            // for the pano track — exactly the corpus values 14 / 15.
            b.u32(enabled ? 0x0000_000F : 0x0000_000E)
            b.u32(0); b.u32(0)
            b.u32(trackID)
            b.u32(0)
            b.u32(duration)
            b.zeros(8)
            b.u16(0); b.u16(0)              // layer, alternate group
            b.u16(0); b.u16(0)              // volume, reserved
            b.identityMatrix()
            b.u32(UInt32(width) << 16)
            b.u32(UInt32(height) << 16)
        }
    }

    private static func edts(duration: UInt32) -> Data {
        atom("edts") { e in
            e.raw(atom("elst") { l in
                l.u32(0); l.u32(1)
                l.u32(duration); l.u32(0); l.u32(0x0001_0000)
            })
        }
    }

    private static func mdhd(duration: UInt32) -> Data {
        atom("mdhd") { b in
            b.u32(0)
            b.u32(0); b.u32(0)
            b.u32(timeScale); b.u32(duration)
            b.u16(0); b.u16(0)              // language, quality
        }
    }

    private static func hdlr(type: String, subtype: String) -> Data {
        atom("hdlr") { b in
            b.u32(0)
            b.fourCC(type); b.fourCC(subtype)
            b.u32(0); b.u32(0); b.u32(0)    // manufacturer, flags, mask
            b.u8(0)                         // empty Pascal name
        }
    }

    private static func dinf() -> Data {
        atom("dinf") { d in
            d.raw(atom("dref") { r in
                r.u32(0); r.u32(1)
                r.raw(atom("alis") { a in a.u32(0x0000_0001) })   // self-reference
            })
        }
    }

    /// Standard 86-byte QuickTime video sample description for 'jpeg'.
    private static func videoSampleDescription(width: Int, height: Int) -> Data {
        var b = AtomBuilder()
        b.u32(86)
        b.fourCC("jpeg")
        b.zeros(6); b.u16(1)                // reserved, data ref index
        b.u16(0); b.u16(0)                  // version, revision
        b.fourCC("appl")
        b.u32(0); b.u32(512)                // temporal, spatial quality
        b.u16(UInt16(width)); b.u16(UInt16(height))
        b.u32(0x0048_0000); b.u32(0x0048_0000)   // 72 dpi
        b.u32(0)
        b.u16(1)                            // frames per sample
        var name = "Photo - JPEG".data(using: .macOSRoman)!
        b.u8(UInt8(name.count)); name.append(Data(count: 31 - name.count)); b.raw(name)
        b.u16(24)                           // depth
        b.u16(0xFFFF)                       // clut id −1 (no palette)
        return b.data
    }

    /// TN1035 PanoramaDescription, 152 bytes.
    private static func panoramaDescription(sceneSizeX: UInt32, sceneSizeY: UInt32,
                                            tileCount: Int, vPanRange: Double,
                                            sweepDegrees: Double) -> Data {
        var b = AtomBuilder()
        b.u32(152)
        b.fourCC("pano")
        b.zeros(6); b.u16(1)                // reserved, data ref index
        b.u16(0); b.u16(0)                  // major/minor version
        b.u32(1)                            // sceneTrackID
        b.u32(0)                            // loResSceneTrackID
        b.zeros(24)                         // reserved3
        b.u32(0)                            // hotSpotTrackID
        b.zeros(36)                         // reserved4
        b.fixed(0); b.fixed(sweepDegrees)   // hPanStart/End (<360 = no wrap)
        b.fixed(vPanRange); b.fixed(-vPanRange)
        b.fixed(0); b.fixed(0)              // min/max zoom = defaults
        b.u32(sceneSizeX); b.u32(sceneSizeY)
        b.u32(UInt32(tileCount))
        b.u16(0)                            // reserved5
        b.u16(1); b.u16(UInt16(tileCount))  // frames X/Y
        b.u16(32)                           // scene color depth
        b.u32(0); b.u32(0)                  // hot spot sizes
        b.u16(0)                            // reserved6
        b.u16(0); b.u16(0)                  // hot spot frames
        b.u16(0)                            // hot spot depth
        return b.data
    }

    /// The pano track's single media sample: a 64-byte 'pHdr' atom.
    private static func panoramaHeaderSample(options: QTVRPanoramaWriterOptions) -> Data {
        var b = AtomBuilder()
        b.u32(64)
        b.fourCC("pHdr")
        b.u32(0)                            // nodeID
        b.fixed(options.defaultPan)
        b.fixed(options.defaultTilt)
        b.fixed(options.defaultZoom)
        b.fixed(0); b.fixed(0); b.fixed(0)  // node min pan/tilt/zoom = defaults
        b.fixed(0); b.fixed(0); b.fixed(0)  // node max pan/tilt/zoom = defaults
        b.zeros(8)                          // reserved
        b.s32(0); b.s32(0)                  // name/comment string offsets
        return b.data
    }
}
