// Checks ImmersivePanoramaWriter's geometry and metadata against values
// derived independently here, so a wrong reprojection cannot pass by
// agreeing with itself.

import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

func testStrip(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Horizon line dead centre plus latitude bands, so a vertical
    // mis-mapping shows up as the horizon moving off centre.
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 2 - 1, width: width, height: 2))
    return ctx.makeImage()!
}

func check(_ label: String, _ actual: Int, _ expected: Int, tolerance: Int = 1) -> Bool {
    let ok = abs(actual - expected) <= tolerance
    print("    \(ok ? "ok  " : "FAIL") \(label): \(actual) (expected ~\(expected))")
    return ok
}

var allPassed = true

for (sweep, w, h) in [(360.0, 2352, 480), (67.5, 1017, 628), (180.0, 2000, 500)] {
    print("sweep \(sweep)°, strip \(w)x\(h)")
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("immersive_\(Int(sweep)).heic")
    do {
        let r = try ImmersivePanoramaWriter.write(
            panorama: testStrip(width: w, height: h), sweepDegrees: sweep, to: url)

        // Independent derivation.
        let f = Double(w) / (sweep * .pi / 180)
        let expFull = Int((2 * .pi * f).rounded())
        let expMaxLat = atan(Double(h) / 2 / f)
        let expBand = Int((2 * expMaxLat / .pi * Double(expFull / 2)).rounded())

        allPassed = check("full width", Int(r.fullSize.width), expFull) && allPassed
        allPassed = check("full height", Int(r.fullSize.height), expFull / 2) && allPassed
        allPassed = check("band height", Int(r.size.height), expBand, tolerance: 2) && allPassed
        allPassed = check("band width", Int(r.size.width), w) && allPassed
        let sphereOK = (sweep >= 359.5) == r.isFullSphere
        print("    \(sphereOK ? "ok  " : "FAIL") fullSphere: \(r.isFullSphere)")
        allPassed = sphereOK && allPassed

        // 2:1, or it is not equirectangular.
        let ratio = r.fullSize.width / r.fullSize.height
        let ratioOK = abs(ratio - 2) < 0.01
        print("    \(ratioOK ? "ok  " : "FAIL") sphere aspect: \(String(format: "%.4f", ratio))")
        allPassed = ratioOK && allPassed

        // Metadata must survive the encode.
        // The writer may fall back from HEIC to JPEG. Validate the file it
        // actually returned, not a missing/stale file at the requested path.
        guard let src = CGImageSourceCreateWithURL(r.url as CFURL, nil),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else {
            print("    FAIL no metadata written"); allPassed = false; continue
        }
        for (tag, expected) in [("ProjectionType", "equirectangular"),
                                ("UsePanoramaViewer", "True"),
                                ("FullPanoWidthPixels", "\(expFull)"),
                                ("CroppedAreaImageHeightPixels", "\(Int(r.size.height))")] {
            let v = CGImageMetadataCopyStringValueWithPath(md, nil, "GPano:\(tag)" as CFString)
            let got = (v as String?) ?? "<missing>"
            let ok = got == expected
            print("    \(ok ? "ok  " : "FAIL") GPano:\(tag) = \(got)")
            allPassed = ok && allPassed
        }

        // The horizon must land in the middle of the band. This is the
        // check that actually catches a bad tan()/linear mix-up.
        if let out = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let c = CGContext(data: nil, width: out.width, height: out.height,
                              bitsPerComponent: 8, bytesPerRow: out.width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(out, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
            let p = c.data!.bindMemory(to: UInt8.self, capacity: out.width * out.height * 4)
            var reddest = 0, best = -1
            for y in 0..<out.height {
                let i = (y * out.width + out.width / 2) * 4
                let score = Int(p[i]) - Int(p[i + 2])
                if score > best { best = score; reddest = y }
            }
            allPassed = check("horizon row", reddest, out.height / 2, tolerance: 2) && allPassed
        }
        print("    wrote \(r.url.lastPathComponent) — \(Int(r.size.width))x\(Int(r.size.height)), vFOV \(String(format: "%.1f", r.verticalFOV))°")
    } catch {
        print("    FAIL \(error)"); allPassed = false
    }
    print("")
}

// The writer's HEIC-then-JPEG fallback catches only the first encode; if
// BOTH fail (e.g. the destination directory itself refuses writes), the
// second error must propagate rather than leaving a dead file or a
// clobbered prior export. A read-only directory forces a real
// CGImageDestination failure — not a simulated one — for both attempts.
print("atomicity: destination directory refuses writes")
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("immersive-readonly-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    let target = dir.appendingPathComponent("blocked.heic")
    do {
        _ = try ImmersivePanoramaWriter.write(
            panorama: testStrip(width: 960, height: 240), sweepDegrees: 360, to: target)
        print("    FAIL write succeeded against a read-only directory"); allPassed = false
    } catch {
        let heicLeft = FileManager.default.fileExists(atPath: target.path)
        let jpgLeft = FileManager.default.fileExists(
            atPath: target.deletingPathExtension().appendingPathExtension("jpg").path)
        let clean = !heicLeft && !jpgLeft
        print("    \(clean ? "ok  " : "FAIL") write threw (\(error)) and left no file behind")
        allPassed = clean && allPassed
    }
} catch {
    print("    FAIL could not set up the read-only fixture: \(error)"); allPassed = false
}
print("")

print(allPassed ? "ALL PASSED" : "FAILURES ABOVE")
exit(allPassed ? 0 : 1)
