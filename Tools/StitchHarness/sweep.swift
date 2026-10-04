// Robustness sweep: does the stitcher hold up across frame counts and
// overlaps (i.e. across lenses / rig detents), or only on the one set it
// was written against?
//
// Truth is known by construction — frames are CUT at a fixed step — so
// each run either recovers that step and order or it does not.

import Foundation
import CoreGraphics
import ImageIO
import AppKit

func sliceScene(_ scene: CGImage, count: Int, step: Int) -> [CGImage] {
    (0..<count).compactMap {
        scene.cropping(to: CGRect(x: $0 * step, y: 0, width: 640, height: 480))
    }
}

/// One trial. Returns nil on success, or a description of what went wrong.
func trial(_ frames: [CGImage], expectStep: Int, count: Int) -> String? {
    guard frames.count == count else { return "only cut \(frames.count) frames" }
    do {
        let s = try PanoramaStitcher.match(frames: frames)
        guard let strip = s.render(slope: s.fittedSlope) else { return "render nil" }
        var bad: [String] = []
        if s.order != Array(0..<count) && s.order != Array((0..<count).reversed()) {
            bad.append("order \(s.order)")
        }
        if abs(s.step - expectStep) > 2 { bad.append("step \(s.step) vs \(expectStep)") }
        if abs(s.fittedSlope) > 2 { bad.append("slope \(s.fittedSlope)") }
        let expectW = 640 + (count - 1) * expectStep
        if abs(strip.width - expectW) > 12 { bad.append("width \(strip.width) vs \(expectW)") }
        return bad.isEmpty ? nil : bad.joined(separator: ", ")
    } catch { return "\(error)" }
}

func run() -> Bool {
    let repoScene = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftTake/DemoPanSource.jpg")
    let photo: CGImage? = CGImageSourceCreateWithURL(repoScene as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        .flatMap { img -> CGImage? in
            img.height > 480
                ? img.cropping(to: CGRect(x: 0, y: (img.height - 480) / 2,
                                          width: img.width, height: 480))
                : img
        }

    print("=== FRAME COUNT SWEEP — drawn scene, step 256 (60% overlap) ===")
    var pass = 0, fail = 0
    for n in [2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 15, 16] {
        DemoPanScene.sourceOverrideURL = nil          // force the drawn scene
        let frames = DemoPanScene.cgFrames(count: n, step: 256)
        let why = trial(frames, expectStep: 256, count: n)
        print("  n=\(String(format: "%2d", n))  \(why == nil ? "PASS" : "FAIL — \(why!)")")
        why == nil ? (pass += 1) : (fail += 1)
    }

    print("\n=== OVERLAP SWEEP — drawn scene, 6 frames (a lens/detent change) ===")
    for step in [96, 128, 192, 256, 320, 384, 448, 500, 512, 544] {
        let overlap = Int(((1 - Double(step) / 640) * 100).rounded())
        DemoPanScene.sourceOverrideURL = nil
        let frames = DemoPanScene.cgFrames(count: 6, step: step)
        let why: String?
        if step >= 512 {
            // At/outside the search boundary: a refusal is the correct
            // result, not an incorrectly compressed panorama.
            do {
                _ = try PanoramaStitcher.match(frames: frames)
                why = "accepted unsupported overlap"
            } catch PanoramaStitcher.StitchError.noConfidentMatch { why = nil }
            catch { why = "unexpected error: \(error)" }
        } else { why = trial(frames, expectStep: step, count: 6) }
        print("  step \(String(format: "%3d", step)) (\(String(format: "%2d", overlap))% overlap\(step >= 512 ? ", expect rejection" : ""))  "
              + "\(why == nil ? "PASS" : "FAIL — \(why!)")")
        why == nil ? (pass += 1) : (fail += 1)
    }

    guard let photo else { print("FAIL: missing DemoPanSource.jpg"); return false }
    print("\n=== REAL PHOTOGRAPH — \(photo.width)x\(photo.height), counts at 60% overlap ===")
    for n in [2, 3, 4, 5, 6, 7] where 640 + (n - 1) * 256 <= photo.width {
        let frames = sliceScene(photo, count: n, step: 256)
        let why = trial(frames, expectStep: 256, count: n)
        print("  n=\(String(format: "%2d", n))  \(why == nil ? "PASS" : "FAIL — \(why!)")")
        why == nil ? (pass += 1) : (fail += 1)
    }

    print("\n=== REAL PHOTOGRAPH — overlap range, 5 frames ===")
    for step in [128, 192, 256, 320, 384, 428] where 640 + 4 * step <= photo.width {
        let overlap = Int(((1 - Double(step) / 640) * 100).rounded())
        let frames = sliceScene(photo, count: 5, step: step)
        let why = trial(frames, expectStep: step, count: 5)
        print("  step \(String(format: "%3d", step)) (\(String(format: "%2d", overlap))% overlap\(step >= 512 ? ", expect rejection" : ""))  "
              + "\(why == nil ? "PASS" : "FAIL — \(why!)")")
        why == nil ? (pass += 1) : (fail += 1)
    }

    print("\n\(pass) passed, \(fail) failed")
    return fail == 0
}

// MARK: - Profile

/// Measures matching and rendering separately across several frame counts.
func profile() {
    let station = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftTake/DemoPanSourceStation.png")

    print("frames   match(s)  render(s)  total(s)   per-pair(ms)")
    for n in [2, 4, 5, 6, 8, 12, 16] {
        DemoPanScene.sourceOverrideURL = nil
        let frames = DemoPanScene.cgFrames(count: n, step: 256)
        guard frames.count == n else { continue }

        let t0 = Date()
        guard let session = try? PanoramaStitcher.match(frames: frames) else {
            print("  \(n)  match failed"); continue
        }
        let t1 = Date()
        _ = session.render(slope: session.fittedSlope)
        let t2 = Date()

        let match = t1.timeIntervalSince(t0), render = t2.timeIntervalSince(t1)
        // Both orderings are fitted in full, plus one wraparound test.
        let pairs = PanoramaStitcher.pairMatchCount(frames: n)
        print(String(format: "%5d %10.2f %10.2f %9.2f %14.1f",
                     n, match, render, match + render,
                     match / Double(pairs) * 1000))
    }

    print("\nthe two shipping scenes:")
    for (label, url, count) in [("iceShelf", shippedScene, 5), ("station", station, 6)] {
        guard let url else { continue }
        DemoPanScene.sourceOverrideURL = url
        let scene: DemoPanScene.Scene = label == "station" ? .station : .iceShelf
        let frames = DemoPanScene.cgFrames(count: count, scene: scene)
        let t0 = Date()
        guard let session = try? PanoramaStitcher.match(frames: frames) else { continue }
        let t1 = Date()
        _ = session.render(slope: session.fittedSlope)
        let t2 = Date()
        print(String(format: "  %-9@ n=%d  match %.2fs  render %.2fs  total %.2fs",
                     label as NSString, count,
                     t1.timeIntervalSince(t0), t2.timeIntervalSince(t1),
                     t2.timeIntervalSince(t0)))
    }
}
