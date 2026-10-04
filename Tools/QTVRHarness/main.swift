// QTVR parser harness: parse every movie in the corpus and print one
// deterministic digest line per file. Any diff vs baseline.txt = the
// parser's reading of the period files changed = stop and explain.
//
// The corpus (gitignored; regenerate with extract_corpus.py) carries
// two layouts: flattened .mov files, and .mov+.moov pairs for
// authoring-form movies whose atoms live in the resource fork.
import Foundation

setbuf(stdout, nil)

// --writer-checks needs no external corpus (synthetic strip only), so it
// runs standalone and is safe to wire into check.sh. It targets the writer
// directly: invalid sweepDegrees must be rejected, and a partial-arc write
// must round-trip through the same parser with the expected hPan range.
if CommandLine.arguments.contains("--writer-checks") {
    let ok = runWriterChecks() && runStszCapCheck()
    exit(ok ? 0 : 1)
}

let corpusURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()                    // Tools/QTVRHarness
    .deletingLastPathComponent()                    // Tools
    .deletingLastPathComponent()                    // repo root
    .appendingPathComponent("Research/QTVR/corpus")

func fmt(_ d: Double) -> String {
    // Two decimals is exact for every Fixed 16.16 value the corpus uses
    // and keeps the baseline free of float-noise.
    String(format: "%.2f", d)
}

let files = (try? FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "mov" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !files.isEmpty else {
    print("### no corpus at \(corpusURL.path) — run extract_corpus.py first")
    exit(1)
}

var failures = 0
for url in files {
    let name = url.deletingPathExtension().lastPathComponent
    do {
        let mediaData = try Data(contentsOf: url)
        let moovURL = url.deletingPathExtension().appendingPathExtension("moov")
        let file: QTVRFile
        let layout: String
        if let moovData = try? Data(contentsOf: moovURL) {
            file = try QTVRFile.parse(moovData: moovData, mediaData: mediaData)
            layout = "rsrc"
        } else {
            file = try QTVRFile.parse(fileData: mediaData)
            layout = "flat"
        }

        var fields: [String] = [
            "kind=\(file.kind.rawValue)",
            "layout=\(layout)",
            "ctyp=\(file.controllerType ?? "-")",
            "tracks=\(file.tracks.count)",
        ]
        for t in file.tracks {
            fields.append("t\(t.trackID)[\(t.sampleFormat) en=\(t.isEnabled ? 1 : 0) n=\(t.sampleCount) \(t.width)x\(t.height)]")
        }
        if let p = file.panoramaDescription {
            fields.append("pano[scene=\(p.sceneTrackID) hs=\(p.hotSpotTrackID) "
                + "h=\(fmt(p.hPanStart))..\(fmt(p.hPanEnd)) v=\(fmt(p.vPanTop))..\(fmt(p.vPanBottom)) "
                + "z=\(fmt(p.minimumZoom))..\(fmt(p.maximumZoom)) "
                + "img=\(p.sceneSizeX)x\(p.sceneSizeY) tiles=\(p.sceneNumFramesX)x\(p.sceneNumFramesY) "
                + "depth=\(p.sceneColorDepth)]")
        }
        if let h = file.panoramaHeader {
            fields.append("pHdr[node=\(h.nodeID) def=\(fmt(h.defHPan))/\(fmt(h.defVPan))/\(fmt(h.defZoom))]")
        }
        if !file.panoramaSampleAtoms.isEmpty {
            let atoms = file.panoramaSampleAtoms.keys.sorted().joined(separator: ",")
            fields.append("sampleAtoms=\(atoms)")
        }
        if let o = file.objectInfo {
            fields.append("NAVG[\(o.numberOfColumns)x\(o.numberOfRows) loop=\(o.loopSize) "
                + "dur=\(o.frameDuration) type=\(o.movieType) fov=\(fmt(o.fieldOfView)) "
                + "h=\(fmt(o.startHPan))..\(fmt(o.endHPan)) v=\(fmt(o.startVPan))..\(fmt(o.endVPan)) "
                + "init=\(fmt(o.initialHPan))/\(fmt(o.initialVPan))]")
        }
        print("\(name) | \(fields.joined(separator: " "))")
    } catch {
        print("\(name) | PARSE-FAIL \(error)")
        failures += 1
    }
}
if failures > 0 {
    print("### \(failures) file(s) failed to parse")
    exit(2)
}

// ── Writer self-test: synthesize a strip, write a v1 pano, parse it
// back with the same parser that reads the period corpus, and check
// the pixels survive the rotate/dice round trip. The digest line is
// structural only (JPEG byte sizes vary by OS encoder), so it is
// baseline-stable.
import CoreGraphics
import ImageIO

func syntheticStrip(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Position-coded flat colors, robust to JPEG: hue by pan octant,
    // brightness by vertical band. Any tile-order or rotation mistake
    // relocates a color block and fails the sample checks.
    for x in stride(from: 0, to: width, by: 32) {
        for y in stride(from: 0, to: height, by: 32) {
            let fx = CGFloat(x) / CGFloat(width)
            let fy = CGFloat(y) / CGFloat(height)
            ctx.setFillColor(CGColor(srgbRed: fx, green: fy, blue: 1 - fx, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 32, height: 32))
        }
    }
    return ctx.makeImage()!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let ctx = CGContext(data: nil, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

do {
    let strip = syntheticStrip(width: 2880, height: 720)
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("qtvr-selftest.mov")
    try QTVRPanoramaWriter.write(panorama: strip, to: outURL)
    let written = try Data(contentsOf: outURL)
    let parsed = try QTVRFile.parse(fileData: written)

    var fields: [String] = [
        "kind=\(parsed.kind.rawValue)",
        "ctyp=\(parsed.controllerType ?? "-")",
        "tracks=\(parsed.tracks.count)",
    ]
    for t in parsed.tracks {
        fields.append("t\(t.trackID)[\(t.sampleFormat) en=\(t.isEnabled ? 1 : 0) n=\(t.sampleCount) \(t.width)x\(t.height)]")
    }
    if let p = parsed.panoramaDescription {
        fields.append("pano[scene=\(p.sceneTrackID) h=\(fmt(p.hPanStart))..\(fmt(p.hPanEnd)) "
            + "v=\(fmt(p.vPanTop))..\(fmt(p.vPanBottom)) img=\(p.sceneSizeX)x\(p.sceneSizeY) "
            + "tiles=\(p.sceneNumFramesX)x\(p.sceneNumFramesY)]")
    }
    if let h = parsed.panoramaHeader {
        fields.append("pHdr[node=\(h.nodeID) def=\(fmt(h.defHPan))/\(fmt(h.defVPan))/\(fmt(h.defZoom))]")
    }

    // Decode every tile, un-rotate the strip, and spot-check pixels
    // against the source at block centres (JPEG-safe: flat 32px blocks,
    // tolerance ±24).
    var reassembleOK = true
    if let scene = parsed.tracks.first(where: { $0.sampleFormat == "jpeg" }),
       let pano = parsed.panoramaDescription {
        let tileW = Int(pano.sceneSizeX)
        let tileH = Int(pano.sceneSizeY) / Int(pano.numFrames)
        let ctx = CGContext(data: nil, width: Int(pano.sceneSizeY), height: tileW,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Undo the 90° CCW: rotate each decoded tile back and lay the
        // strip out left-to-right in sample order.
        for (i, offset) in scene.chunkOffsets.enumerated() {
            let size = Int(scene.sampleSizes[i])
            let tileData = written.subdata(in: Int(offset) ..< Int(offset) + size)
            guard let src = CGImageSourceCreateWithData(tileData as CFData, nil),
                  let tile = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                reassembleOK = false; break
            }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i * tileH), y: 0)
            ctx.translateBy(x: CGFloat(tileH), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tileW, height: tileH))
            ctx.restoreGState()
        }
        if reassembleOK, let rebuilt = ctx.makeImage() {
            let sx = Double(rebuilt.width) / Double(strip.width)
            let sy = Double(rebuilt.height) / Double(strip.height)
            for (px, py) in [(16, 16), (1440, 360), (2864, 704), (720, 48), (2160, 680)] {
                let want = pixel(strip, px, py)
                let got = pixel(rebuilt, Int(Double(px) * sx), Int(Double(py) * sy))
                if abs(want.r - got.r) > 24 || abs(want.g - got.g) > 24 || abs(want.b - got.b) > 24 {
                    reassembleOK = false
                    fields.append("pixelFail@\(px),\(py) want=\(want) got=\(got)")
                    break
                }
            }
        }
    } else {
        reassembleOK = false
    }
    fields.append("roundtrip=\(reassembleOK ? "PASS" : "FAIL")")
    print("WRITER-SELFTEST | \(fields.joined(separator: " "))")
    if !reassembleOK { exit(3) }
} catch {
    print("WRITER-SELFTEST | FAIL \(error)")
    exit(3)
}

// MARK: - Writer checks (no corpus needed)

func runWriterChecks() -> Bool {
    var failures = 0, checks = 0
    func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL"): \(label)")
    }

    let strip = syntheticStrip(width: 2880, height: 720)
    let tmp = FileManager.default.temporaryDirectory

    // Every angle option the writer converts with `fixed(_:)` — NaN, +/-inf,
    // a huge finite value (the fixed-point Int32 conversion can trap on
    // these even when they're finite), and a value just past the option's
    // own bound must all be rejected without a leftover file; the bound
    // itself must still write and round-trip with the expected value.
    struct OptionCase {
        let name: String
        let justOverBound: Double
        let boundaryValid: Double
        let apply: (inout QTVRPanoramaWriterOptions, Double) -> Void
        let readBack: (QTVRFile) -> Double?
    }
    let optionCases: [OptionCase] = [
        OptionCase(name: "sweepDegrees", justOverBound: 360.0001, boundaryValid: 360,
                  apply: { $0.sweepDegrees = $1 },
                  readBack: { $0.panoramaDescription?.hPanEnd }),
        OptionCase(name: "vPanRange", justOverBound: 90.0001, boundaryValid: 90,
                  apply: { $0.vPanRange = $1 },
                  readBack: { $0.panoramaDescription?.vPanTop }),
        OptionCase(name: "defaultPan", justOverBound: 360.0001, boundaryValid: 360,
                  apply: { $0.defaultPan = $1 },
                  readBack: { $0.panoramaHeader?.defHPan }),
        OptionCase(name: "defaultTilt", justOverBound: 90.0001, boundaryValid: 90,
                  apply: { $0.defaultTilt = $1 },
                  readBack: { $0.panoramaHeader?.defVPan }),
        OptionCase(name: "defaultZoom", justOverBound: 180.0001, boundaryValid: 180,
                  apply: { $0.defaultZoom = $1 },
                  readBack: { $0.panoramaHeader?.defZoom }),
    ]
    for option in optionCases {
        for bad in [Double.nan, Double.infinity, -Double.infinity, 1e12, option.justOverBound] {
            var options = QTVRPanoramaWriterOptions()
            option.apply(&options, bad)
            let url = tmp.appendingPathComponent("qtvr-\(option.name)-reject.mov")
            try? FileManager.default.removeItem(at: url)
            do {
                try QTVRPanoramaWriter.write(panorama: strip, to: url, options: options)
                check(false, "\(option.name) = \(bad) rejected")
            } catch {
                check(!FileManager.default.fileExists(atPath: url.path),
                      "\(option.name) = \(bad) rejected without leaving a file")
            }
        }
        var options = QTVRPanoramaWriterOptions()
        option.apply(&options, option.boundaryValid)
        let url = tmp.appendingPathComponent("qtvr-\(option.name)-boundary.mov")
        do {
            try QTVRPanoramaWriter.write(panorama: strip, to: url, options: options)
            let parsed = try QTVRFile.parse(fileData: try Data(contentsOf: url))
            let got = option.readBack(parsed)
            check(got.map { abs($0 - option.boundaryValid) < 0.01 } ?? false,
                  "\(option.name) boundary value \(option.boundaryValid) writes and round-trips (got \(String(describing: got)))")
        } catch {
            check(false, "\(option.name) boundary value \(option.boundaryValid): \(error)")
        }
    }

    // A partial arc (90°) must round-trip through the real parser with
    // the expected hPan range, not the 360° full-wrap default.
    var partial = QTVRPanoramaWriterOptions()
    partial.sweepDegrees = 90
    let partialURL = tmp.appendingPathComponent("qtvr-partial-arc.mov")
    do {
        try QTVRPanoramaWriter.write(panorama: strip, to: partialURL, options: partial)
        let parsed = try QTVRFile.parse(fileData: try Data(contentsOf: partialURL))
        if let pano = parsed.panoramaDescription {
            check(abs(pano.hPanStart - 0) < 0.01, "partial arc hPanStart is 0 (got \(pano.hPanStart))")
            check(abs(pano.hPanEnd - 90) < 0.01, "partial arc hPanEnd is 90 (got \(pano.hPanEnd))")
        } else {
            check(false, "partial arc write produced a parseable pano description")
        }
    } catch {
        check(false, "partial arc write/parse: \(error)")
    }

    // The existing full 360° default must still round-trip unchanged.
    let fullURL = tmp.appendingPathComponent("qtvr-full-arc.mov")
    do {
        try QTVRPanoramaWriter.write(panorama: strip, to: fullURL)
        let parsed = try QTVRFile.parse(fileData: try Data(contentsOf: fullURL))
        if let pano = parsed.panoramaDescription {
            check(abs(pano.hPanEnd - 360) < 0.01, "default 360° write keeps hPanEnd 360 (got \(pano.hPanEnd))")
        } else {
            check(false, "default 360° write produced a parseable pano description")
        }
    } catch {
        check(false, "default 360° write/parse: \(error)")
    }

    // windowWidth/windowHeight are Int (not Double), so NaN/inf don't apply —
    // only negative, zero, and out-of-16-bit-range values are constructible.
    // They land on the pano track's tkhd (trackID 2).
    struct IntOptionCase {
        let name: String
        let bad: [Int]
        let boundaryValid: Int
        let apply: (inout QTVRPanoramaWriterOptions, Int) -> Void
        let readBack: (QTVRFile) -> Double?
    }
    let intCases: [IntOptionCase] = [
        IntOptionCase(name: "windowWidth", bad: [-1, 0, 32768, 65536, 1_000_000_000_000],
                     boundaryValid: 32767, apply: { $0.windowWidth = $1 },
                     readBack: { $0.tracks.first { $0.trackID == 2 }?.windowWidth }),
        IntOptionCase(name: "windowHeight", bad: [-1, 0, 32768, 65536, 1_000_000_000_000],
                     boundaryValid: 32767, apply: { $0.windowHeight = $1 },
                     readBack: { $0.tracks.first { $0.trackID == 2 }?.windowHeight }),
    ]
    for option in intCases {
        for bad in option.bad {
            var options = QTVRPanoramaWriterOptions()
            option.apply(&options, bad)
            let url = tmp.appendingPathComponent("qtvr-\(option.name)-reject.mov")
            try? FileManager.default.removeItem(at: url)
            do {
                try QTVRPanoramaWriter.write(panorama: strip, to: url, options: options)
                check(false, "\(option.name) = \(bad) rejected")
            } catch {
                check(!FileManager.default.fileExists(atPath: url.path),
                      "\(option.name) = \(bad) rejected without leaving a file")
            }
        }
        var options = QTVRPanoramaWriterOptions()
        option.apply(&options, option.boundaryValid)
        let url = tmp.appendingPathComponent("qtvr-\(option.name)-boundary.mov")
        do {
            try QTVRPanoramaWriter.write(panorama: strip, to: url, options: options)
            let parsed = try QTVRFile.parse(fileData: try Data(contentsOf: url))
            let got = option.readBack(parsed)
            check(got.map { abs($0 - Double(option.boundaryValid)) < 0.01 } ?? false,
                  "\(option.name) boundary value \(option.boundaryValid) writes and round-trips (got \(String(describing: got)))")
        } catch {
            check(false, "\(option.name) boundary value \(option.boundaryValid): \(error)")
        }
    }

    // tileWidth (= strip height, post-rotation) must fit the format's
    // 16-bit fields — an oversized panorama should be rejected cleanly
    // rather than trap in the UInt16(_:) conversion at encode time.
    do {
        let tall = syntheticStrip(width: 480, height: 70_000)
        let url = tmp.appendingPathComponent("qtvr-tall-reject.mov")
        try? FileManager.default.removeItem(at: url)
        do {
            try QTVRPanoramaWriter.write(panorama: tall, to: url)
            check(false, "70000px-tall panorama rejected")
        } catch {
            check(!FileManager.default.fileExists(atPath: url.path),
                  "70000px-tall panorama rejected without leaving a file (\(error))")
        }
    }

    // jpegQuality only affects tile compression, not file structure, so the
    // writer clamps rather than rejects — NaN/inf fall back to the default
    // (0.9), out-of-range finite values clamp to [0, 1]. Every case must
    // still produce a valid, parseable file (no trap, no broken output).
    for quality in [Double.nan, .infinity, -.infinity, 5.0, -5.0, 1e12] {
        var options = QTVRPanoramaWriterOptions()
        options.jpegQuality = quality
        let url = tmp.appendingPathComponent("qtvr-jpegQuality.mov")
        do {
            try QTVRPanoramaWriter.write(panorama: strip, to: url, options: options)
            let parsed = try QTVRFile.parse(fileData: try Data(contentsOf: url))
            check(parsed.panoramaDescription != nil, "jpegQuality \(quality) sanitized, file still parses")
        } catch {
            check(false, "jpegQuality \(quality): \(error)")
        }
    }

    print("\(checks - failures)/\(checks) writer checks passed")
    return failures == 0
}

// A uniform-size stsz atom's sample count is an unchecked 32-bit field
// from the file; without a cap, `Array(repeating:count:)` on a hostile
// count could allocate gigabytes. Patch the writer's own pano-track
// stsz (uniform=64, count=1) to a huge count and confirm parsing
// completes quickly and clamps sampleCount instead of hanging/crashing.
func runStszCapCheck() -> Bool {
    var checks = 0, failures = 0
    func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL"): \(label)")
    }
    do {
        let strip = syntheticStrip(width: 2880, height: 720)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qtvr-stsz-patch.mov")
        try QTVRPanoramaWriter.write(panorama: strip, to: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        let marker: [UInt8] = Array("stsz".utf8)
        var patched = false
        var i = 0
        while i + 4 <= bytes.count {
            if Array(bytes[i ..< i + 4]) == marker {
                // payload: version/flags(4) uniform(4) count(4) ...
                let uniformOffset = i + 4 + 4
                let countOffset = uniformOffset + 4
                if countOffset + 4 <= bytes.count {
                    let uniform = (UInt32(bytes[uniformOffset]) << 24) | (UInt32(bytes[uniformOffset + 1]) << 16)
                        | (UInt32(bytes[uniformOffset + 2]) << 8) | UInt32(bytes[uniformOffset + 3])
                    if uniform != 0 {
                        // This is the pano track's uniform stsz — patch its
                        // count to the largest 32-bit value.
                        bytes[countOffset] = 0xFF; bytes[countOffset + 1] = 0xFF
                        bytes[countOffset + 2] = 0xFF; bytes[countOffset + 3] = 0xFF
                        patched = true
                        break
                    }
                }
            }
            i += 1
        }
        check(patched, "found a uniform stsz atom to patch")
        guard patched else { print("\(checks - failures)/\(checks) stsz-cap checks passed"); return failures == 0 }
        let patchedURL = FileManager.default.temporaryDirectory.appendingPathComponent("qtvr-stsz-patched.mov")
        try Data(bytes).write(to: patchedURL)
        let start = Date()
        let parsed = try QTVRFile.parse(fileData: Data(bytes))
        let elapsed = Date().timeIntervalSince(start)
        check(elapsed < 5, "patched-count parse completes quickly (\(elapsed)s)")
        let panoTrack = parsed.tracks.first { $0.sampleFormat != "jpeg" }
        check((panoTrack?.sampleCount ?? Int.max) <= 100_000,
              "sampleCount capped instead of matching the hostile count (\(panoTrack?.sampleCount ?? -1))")
    } catch {
        check(false, "stsz-cap check: \(error)")
    }
    print("\(checks - failures)/\(checks) stsz-cap checks passed")
    return failures == 0
}
