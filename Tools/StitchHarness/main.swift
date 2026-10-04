// Stitcher harness.
//
// Runs `SwiftTake/PanoramaStitcher.swift` over a directory of frames and
// prints one deterministic digest line per set. Any diff vs baseline.txt
// means the geometry the stitcher solves has changed — stop and explain
// before shipping.
//
// Frames are fed in the SAME orientation the app feeds them: straight off
// the decoder, 640x480, QuickPan content lying on its side. Rotating them
// before they reach the harness would skip the one decision most worth
// regression-testing.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Frames in filename order. Direction is the stitcher's to work out.
func frames(in dir: URL) -> [(String, CGImage)] {
    let exts: Set<String> = ["tiff", "tif", "png", "jpg", "jpeg"]
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil)) ?? []
    return files
        .filter { exts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { u in load(u).map { (u.lastPathComponent, $0) } }
}

func digest(_ label: String, _ dir: URL, writePNG: URL? = nil) {
    let loaded = frames(in: dir)
    guard loaded.count >= 2 else {
        print("\(label): SKIP (\(loaded.count) frame(s))")
        return
    }
    let images = loaded.map { $0.1 }
    let started = Date()
    do {
        let session = try PanoramaStitcher.match(frames: images)
        guard let strip = session.render(slope: session.fittedSlope) else {
            print("\(label): FAIL (render returned nil)")
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        var line = "\(label): n=\(images.count)"
        line += " order=\(session.order.map(String.init).joined(separator: ","))"
        line += " step=\(session.step)"
        line += " slope=\(session.fittedSlope)"
        line += " strip=\(strip.width)x\(strip.height)"
        line += String(format: " overlap=%.3f", session.overlap)
        line += " full=\(session.isFullRotation)"
        if let f = session.impliedHFOV { line += String(format: " hfov=%.1f", f) }
        if let s = session.sweepDegrees { line += String(format: " sweep=%.1f", s) }
        print(line)
        FileHandle.standardError.write(
            String(format: "    (%.2fs)\n", elapsed).data(using: .utf8)!)

        if let out = writePNG,
           let dest = CGImageDestinationCreateWithURL(
               out as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, strip, nil)
            _ = CGImageDestinationFinalize(dest)
        }
    } catch {
        print("\(label): ERROR \(error)")
    }
}

/// The synthetic pan, checked against truth known by construction.
///
/// This is the only case where the right answer is not a matter of
/// judgement: the frames were CUT from one image at a fixed step, so the
/// stitcher either recovers that step and that order or it does not.
/// The photograph that ships, found relative to this source file. The
/// harness has no app bundle, so without this it would quietly fall back
/// to the drawn scene and report the demo green having never looked at
/// what users actually see.
let shippedScene: URL? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // StitchHarness
        .deletingLastPathComponent()          // Tools
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent("SwiftTake/DemoPanSource.jpg")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}()

func checkDemo(_ label: String, photograph: Bool, writePNG: URL?,
               scene: DemoPanScene.Scene = .iceShelf, override: URL? = nil) -> Bool {
    DemoPanScene.sourceOverrideURL = photograph ? (override ?? shippedScene) : nil
    if photograph && shippedScene == nil {
        print("\(label): SKIP (DemoPanSource.jpg not in the tree)")
        return true
    }

    let count = photograph ? scene.frameCount : 5
    let images = DemoPanScene.cgFrames(count: count, scene: scene)
    guard images.count == count else {
        print("\(label): FAIL (generated \(images.count) of \(count) frames)")
        return false
    }
    guard images.allSatisfy({ $0.width == 640 && $0.height == 480 }) else {
        print("\(label): FAIL (frames are not 640x480)")
        return false
    }

    let expectedWidth = DemoPanScene.sceneWidth(count: count, scene: scene)

    do {
        let session = try PanoramaStitcher.match(frames: images)
        guard let strip = session.render(slope: session.fittedSlope) else {
            print("\(label): FAIL (render returned nil)")
            return false
        }
        if let out = writePNG,
           let dest = CGImageDestinationCreateWithURL(
               out as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, strip, nil)
            _ = CGImageDestinationFinalize(dest)
        }

        var failures: [String] = []
        // Order, as cut.
        if session.order != Array(0..<count) {
            failures.append("order \(session.order) != \(Array(0..<count))")
        }
        // Step, derived from the frames themselves rather than assumed:
        // the scene may be the bundled photograph or the drawing, and they
        // are different widths. Within a pixel, since the fit is a mean
        // over four pairs and the offsets are rounded per frame.
        let expectedStep = Int((Double(expectedWidth - 640)
                                / Double(count - 1)).rounded())
        if abs(session.step - expectedStep) > 1 {
            failures.append("step \(session.step) != \(expectedStep)")
        }
        // Level camera: the frames were cut from one row, so any slope is
        // the fitter inventing a tilt that is not there.
        if abs(session.fittedSlope) > 1 {
            failures.append("slope \(session.fittedSlope) != 0 (frames are level)")
        }
        // No rotation. Cut in landscape, so a strip taller than it is wide
        // means `upright` turned them and the aspect-ratio bug is back. A
        // few rows short of 480 is not rotation — it is the trim that
        // follows a fitted slope — so this checks the shape, not the exact
        // height, which the slope check above already covers.
        if strip.height > strip.width {
            failures.append("strip is \(strip.width)x\(strip.height) — frames were rotated")
        }
        if abs(strip.width - expectedWidth) > 8 {
            failures.append("strip width \(strip.width) != ~\(expectedWidth)")
        }
        if session.isFullRotation {
            failures.append("reported a full rotation for a partial arc")
        }

        let line = "\(label): n=\(count) order=\(session.order.map(String.init).joined(separator: ","))"
            + " step=\(session.step) slope=\(session.fittedSlope)"
            + " strip=\(strip.width)x\(strip.height)"
            + String(format: " overlap=%.3f", session.overlap)
        if failures.isEmpty {
            print("\(line) — OK")
            return true
        }
        print("\(line) — FAIL")
        for f in failures { print("    \(f)") }
        return false
    } catch {
        print("\(label): ERROR \(error)")
        return false
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: stitchharness <dir> [--png out.png]")
    print("       stitchharness --sweep")
    print("       stitchharness --regressions")
    print("       stitchharness --demo [--png out.png]")
    exit(2)
}

if args[0] == "--sweep" { exit(run() ? 0 : 1) }
if args[0] == "--regressions" { exit(regressions() ? 0 : 1) }
if args[0] == "--profile" { profile(); exit(0) }

if args[0] == "--demo" {
    var out: URL?
    if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
        out = URL(fileURLWithPath: args[i + 1])
    }
    // Both scenes. The drawing is the exact regression — perfect input,
    // so any drift is the stitcher's. The photograph is what ships, and
    // is the harder case by far.
    func repoFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftTake/\(name)")
    }
    let drawn = checkDemo("demo/drawn", photograph: false, writePNG: nil)
    let ice = checkDemo("demo/iceShelf  (QT200)", photograph: true,
                        writePNG: out, scene: .iceShelf)
    let station = checkDemo("demo/station  (QT200)", photograph: true,
                            writePNG: nil, scene: .station,
                            override: repoFile("DemoPanSourceStation.png"))
    let interior = checkDemo("demo/interior (QT200)", photograph: true,
                             writePNG: nil, scene: .interior,
                             override: repoFile("DemoPanSourceInterior.png"))
    exit(drawn && ice && station && interior ? 0 : 1)
}
let dir = URL(fileURLWithPath: args[0])
var png: URL?
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    png = URL(fileURLWithPath: args[i + 1])
}
digest(dir.lastPathComponent, dir, writePNG: png)
