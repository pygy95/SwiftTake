import AppKit
import ImageIO
import Darwin

@main
struct PanoramaChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ passed: Bool, _ description: String) {
            checks += 1
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(description)")
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftTake/DemoPanSource.jpg")
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let scene = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            FileHandle.standardError.write(Data("Missing panorama fixture: \(sourceURL.path)\n".utf8))
            exit(1)
        }
        let frames = (0..<4).map { scene.cropping(to: CGRect(x: $0 * 240, y: 0, width: 640, height: 480))! }
        let s = try PanoramaStitcher.match(frames: frames)
        let strip = s.render(slope: s.fittedSlope)!
        let composition = PanoramaComposition(session: s, sources: frames, initial: strip,
                                              look: FinishedLookSettings(enhanced: false, hdr: false, headroom: 1.5))
        func settle() async {
            let deadline = ContinuousClock.now + .seconds(10)
            while composition.isRendering && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        check(composition.canSave, "initial completed render can be saved")
        composition.slope += 1
        check(!composition.canSave, "Save blocked immediately after Level changes")
        composition.slope += 2
        composition.slope -= 1
        let latest = composition.slope
        await settle()
        check(composition.renderedSlope == latest && composition.canSave, "latest slider adjustment wins")
        composition.isSaving = true
        check(!composition.canSave, "duplicate save blocked during export")
        composition.isSaving = false
        composition.slope = 1000
        await settle()
        check(!composition.canSave && composition.saveError != nil, "failed render cannot save stale pixels")
        composition.resetToAuto()
        await settle()
        check(composition.canSave && composition.saveError == nil, "Auto recovers after a failed render")

        let originalPositions = s.positions(slope: s.fittedSlope)
        let beforeRegions = composition.photoRegions(for: 1)
        for source in s.order {
            let region = composition.photoRegions(for: source)[0]
            check(composition.photo(at: CGPoint(x: region.midX, y: 0.5)) == source,
                  "preview click selects source \(source) at its centre through overlapping coverage")
        }
        check(composition.photo(at: CGPoint(x: -0.1, y: 0.5)) == nil
              && composition.photo(at: CGPoint(x: 0.5, y: 1.1)) == nil
              && composition.photo(at: CGPoint(x: CGFloat.nan, y: 0.5)) == nil,
              "preview clicks outside the image or with invalid coordinates select nothing")
        let reversedFrames = Array(frames.reversed())
        let reversedSession = try PanoramaStitcher.match(frames: reversedFrames)
        let reversedComposition = PanoramaComposition(session: reversedSession, sources: reversedFrames,
            initial: reversedSession.render(slope: reversedSession.fittedSlope),
            look: FinishedLookSettings(enhanced: false, hdr: false, headroom: 1.5))
        check(reversedSession.order == Array(s.order.reversed())
              && reversedSession.order.allSatisfy { source in
                  let region = reversedComposition.photoRegions(for: source)[0]
                  return reversedComposition.photo(at: CGPoint(x: region.midX, y: 0.5)) == source
              }, "preview selection respects source identity in a right-to-left panorama")
        let adjustmentPreview = await composition.adjustmentPreview(for: 1)
        check(adjustmentPreview?.width == frames[1].width && adjustmentPreview?.height == frames[1].height,
              "live source preview retains full prepared-frame resolution")
        check(await composition.adjustmentPreview(for: -1) == nil, "invalid preview source is rejected")
        composition.nudgePhoto(1, x: 3, y: -2)
        let pendingRegions = composition.photoRegions(for: 1)
        check(composition.hasPendingPhotoAdjustments && beforeRegions.count == 1 && pendingRegions.count == 1
              && abs((pendingRegions[0].minX - beforeRegions[0].minX) * Double(strip.width) - 3) < 0.001
              && abs((pendingRegions[0].minY - beforeRegions[0].minY) * Double(strip.height) + 2) < 0.001,
              "selected coverage moves immediately before the blend finishes")
        check(!composition.canSave, "Save blocks immediately for a per-photo adjustment")
        composition.nudgePhoto(1, x: -1, y: 1)
        composition.nudgePhoto(2, y: 2)
        await settle()
        check(composition.canSave && composition.adjustment(for: 1) == .init(x: 2, y: -1),
              "rapid photo adjustments publish only the latest state")
        check(!composition.hasPendingPhotoAdjustments, "live source overlay retires after the final blend")
        let adjustedPositions = s.positions(slope: s.fittedSlope, adjustments: composition.adjustments)
        check(zip(originalPositions, adjustedPositions).enumerated().allSatisfy { index, pair in
            let expected = composition.adjustment(for: s.order[index])
            return pair.1.x - pair.0.x == expected.x && pair.1.y - pair.0.y == expected.y
        }, "each correction moves only its selected photo, not later photos")
        let expectedImage = s.render(slope: s.fittedSlope, adjustments: composition.adjustments)!
        check((composition.strip!.dataProvider!.data! as Data) == (expectedImage.dataProvider!.data! as Data),
              "the saveable preview contains the corrected render pixels")
        composition.resetPhoto(1)
        check(composition.adjustments[1] == nil && composition.adjustments[2] != nil,
              "Reset Photo preserves other photo corrections")
        composition.resetPhotos()
        check(composition.hasPendingPhotoAdjustments, "Reset All also supplies immediate movement feedback")
        await settle()
        check(composition.photoRegions(for: 1) == beforeRegions, "reset restores source coverage exactly")
        check(composition.canSave && composition.adjustments.isEmpty
              && (composition.strip!.dataProvider!.data! as Data) == (strip.dataProvider!.data! as Data),
              "Reset All restores the automatic image exactly")
        composition.nudgePhoto(1, x: 100, y: -100)
        check(composition.adjustment(for: 1) == .init(x: 20, y: -20), "photo corrections are bounded")
        composition.isSaving = true
        composition.nudgePhoto(1, x: -1)
        composition.resetPhotos()
        check(composition.adjustment(for: 1) == .init(x: 20, y: -20), "photo corrections cannot mutate during save")
        composition.isSaving = false
        composition.resetPhotos()
        await settle()
        check(s.render(slope: s.fittedSlope, adjustments: [s.order[0]: .init(x: -10, y: 0)]) != nil,
              "moving the first photo left safely normalizes the render canvas")
        check(s.render(slope: s.fittedSlope, adjustments: [s.order[1]: .init(x: 1000, y: 0)]) == nil,
              "non-overlapping manual geometry fails safely")

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("PanoramaHarness-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let sentinel = folder.appendingPathComponent("keep.txt")
        let original = Data("existing file must survive".utf8)
        try original.write(to: sentinel)
        // PNG encoding succeeds; invalid interactive geometry then fails.
        let tiny = strip.cropping(to: CGRect(x: 0, y: 0, width: 20, height: 20))!
        do {
            _ = try PanoramaExport.write(strip: tiny, sweepDegrees: .nan, destination: folder)
            check(false, "mid-export failure reported")
        } catch { check(true, "mid-export failure reported") }
        check(try fm.contentsOfDirectory(atPath: folder.path) == ["keep.txt"], "failed export removes staged outputs")
        check(try Data(contentsOf: sentinel) == original, "failed export preserves existing files")
        do {
            _ = try PanoramaExport.write(strip: strip, sweepDegrees: 90, destination: sentinel)
            check(false, "unwritable destination reported")
        } catch { check(true, "unwritable destination reported") }
        let first = try PanoramaExport.write(strip: strip, sweepDegrees: 90, destination: folder)
        let snapshots = try first.map { try Data(contentsOf: $0) }
        let second = try PanoramaExport.write(strip: strip, sweepDegrees: 90, destination: folder)
        check(first.count == 3 && second.count == 3, "both saves publish all three formats")
        check(Set(first + second).count == 6, "rapid repeated saves have distinct filenames")
        check(try first.enumerated().allSatisfy { try Data(contentsOf: $0.element) == snapshots[$0.offset] }, "second save does not overwrite first")
        check(try fm.contentsOfDirectory(atPath: folder.path).count == 7, "successful export leaves no staging files")
        let savedPNG = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(first[0] as CFURL, nil)!, 0, nil)!
        check(savedPNG.width == strip.width && savedPNG.height == strip.height, "saved PNG retains render dimensions")
        check(first[1].pathExtension == "html", "interactive export is a browser document, not a legacy movie")
        let html = try String(contentsOf: first[1], encoding: .utf8)
        check(html.contains("data:image/png;base64,") && html.contains("canvas"), "interactive document includes its own image and viewer")
        check(!html.contains("__IMAGE__") && !html.contains("__SWEEP__") && !html.contains("__ASPECT__"), "all viewer parameters are resolved")
        check(html.contains("connect-src 'none'") && !html.contains("<script src="), "interactive export has no network dependency")
        func embeddedImage(in document: String) -> CGImage? {
            guard let start = document.range(of: "data:image/png;base64,")?.upperBound,
                  let end = document[start...].firstIndex(of: "\""),
                  let data = Data(base64Encoded: String(document[start..<end])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let embedded = embeddedImage(in: html)
        check(embedded?.width == strip.width && embedded?.height == strip.height,
              "embedded image decodes independently with the panorama dimensions")
        let note = "QuickPan estimates between selected photos: 6–7 & <test>"
        let assisted = try PanoramaExport.write(strip: strip, sweepDegrees: 90, destination: folder,
                                                alignmentNote: note)
        let assistedHTML = try String(contentsOf: assisted[1], encoding: .utf8)
        check(assistedHTML.contains("6–7 &amp; &lt;test&gt;"), "estimated joins survive HTML export with escaped text")
        check(!assistedHTML.contains("__ALIGNMENT_NOTE__") && !html.contains("__ALIGNMENT_NOTE__"),
              "alignment placeholder resolved with and without assistance")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(assisted[0] as CFURL, nil)!, 0, nil)! as NSDictionary
        let pngProperties = properties[kCGImagePropertyPNGDictionary] as? NSDictionary
        check(pngProperties?[kCGImagePropertyPNGDescription] as? String == note,
              "PNG metadata preserves estimated joins")
        check(assisted.allSatisfy { $0.lastPathComponent.contains("QuickPan") }, "all assisted formats identified by filename")
        let inApp = try InteractivePanoramaWriter.document(panorama: strip, sweepDegrees: 90, embedded: true)
        let inAppImage = embeddedImage(in: inApp)
        check(inAppImage?.width == embedded?.width && inAppImage?.height == embedded?.height,
              "in-app preview preserves the exported image dimensions")
        check(inApp.contains("const sweep = \(Double.pi / 2),") && !inApp.contains("__EMBEDDED_STYLE__"),
              "in-app preview retains coverage and resolves presentation settings")
        // The embedded rule may group the header with other native-only chrome.
        let hiddenHeaderRule = #"(?m)^\s*header(?:\s*,\s*\.[\w-]+)*\s*\{[^}]*\bdisplay\s*:\s*none(?:\s*!important)?\s*[;}]"#
        check(inApp.range(of: hiddenHeaderRule, options: .regularExpression) != nil
              && html.range(of: hiddenHeaderRule, options: .regularExpression) == nil,
              "embedded presentation leaves the standalone export header intact")
        let completeURL = folder.appendingPathComponent("complete.html")
        try InteractivePanoramaWriter.write(panorama: strip, sweepDegrees: 360, to: completeURL)
        let complete = try String(contentsOf: completeURL, encoding: .utf8)
        check(complete.contains("const sweep = \(2 * Double.pi),"), "complete panorama retains full-circle coverage")
        check(!first.contains(where: { $0.pathExtension == "mov" }), "modern Save does not emit unsupported QTVR")
        for invalid in [Double.nan, .infinity, -.infinity, 0, 361] {
            do {
                try InteractivePanoramaWriter.write(panorama: strip, sweepDegrees: invalid,
                                                     to: folder.appendingPathComponent("invalid.html"))
                check(false, "invalid browser-viewer coverage rejected")
            } catch { check(!fm.fileExists(atPath: folder.appendingPathComponent("invalid.html").path), "invalid browser-viewer coverage rejected without a file") }
        }
        check(first[2].pathExtension == "heic" || first[2].pathExtension == "jpg", "immersive export reports actual format")

        // --- init must not block the main actor applying the Look --------
        //
        // Measured before this fix: `Self.finished` ran synchronously in
        // `init` and took ~390ms on a realistic full-rotation QuickTake 200
        // strip (12600x1200 — the "twelve 1600x1200" case documented in
        // `QuickTakeSerialManager`), a plainly user-noticeable main-actor
        // stall. `init` now shows the raw strip immediately and applies the
        // Look off-main, the same guarded path a Level change already uses.
        func makeGradientStrip(width: Int, height: Int) -> CGImage {
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            for x in 0..<width {
                let r = UInt8((Double(x) / Double(max(1, width - 1))) * 255)
                let g = UInt8(255 - Int(r))
                for y in 0..<height {
                    let i = (y * width + x) * 4
                    buf[i] = r; buf[i + 1] = g; buf[i + 2] = 128; buf[i + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(buf) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let bigStrip = makeGradientStrip(width: 12600, height: 1200)
        let enhancedLook = FinishedLookSettings(enhanced: true, hdr: false, headroom: 1.5)
        let initStart = ContinuousClock.now
        let timed = PanoramaComposition(session: s, sources: frames, initial: bigStrip, look: enhancedLook)
        let initElapsed = ContinuousClock.now - initStart
        print("Finding 2 measurement: init with a 12600x1200 enhanced strip returned in \(initElapsed)")
        check(initElapsed < .milliseconds(50),
              "init returns immediately even at a full-rotation QuickTake 200 strip size")
        check(timed.strip != nil, "the raw strip is visible immediately, before the Look pass finishes")
        check(!timed.canSave, "Save is blocked while the off-main Look pass is still running")
        let lookDeadline = ContinuousClock.now + .seconds(10)
        while timed.isRendering && ContinuousClock.now < lookDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        check(timed.canSave, "Save becomes available once the off-main Look pass publishes")

        // --- C4: larger-image safety — measure, don't guess ---------------
        //
        // Reported numbers, not a pass/fail assertion: an input limit or
        // bounded downsampling is only worth adding if these show a real
        // risk (excessive time or memory), and only with a stated,
        // user-visible limit — never a silent quality cut.
        func residentMemoryBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? UInt64(info.resident_size_max) : 0
        }
        func syntheticFrames(count: Int, frameWidth: Int, frameHeight: Int, overlap: Double) -> [CGImage] {
            let step = Int(Double(frameWidth) * (1 - overlap))
            let sceneWidth = step * (count - 1) + frameWidth
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: sceneWidth, height: frameHeight, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Distinguishable vertical bands so overlapping regions actually
            // correlate — a blank scene would let any offset "match".
            for x in stride(from: 0, to: sceneWidth, by: 37) {
                let hue = Double(x % 481) / 481.0
                ctx.setFillColor(CGColor(srgbRed: hue, green: 1 - hue, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 37, height: frameHeight))
            }
            let scene = ctx.makeImage()!
            return (0..<count).map { i in
                scene.cropping(to: CGRect(x: i * step, y: 0, width: frameWidth, height: frameHeight))!
            }
        }
        for (label, n, w, h) in [("12 x 1600x1200 (realistic multi-frame pan)", 12, 1600, 1200),
                                 ("6 x 4000x3000 (deliberately large)", 6, 4000, 3000)] {
            let before = residentMemoryBytes()
            let frames = syntheticFrames(count: n, frameWidth: w, frameHeight: h, overlap: 0.5)
            let start = ContinuousClock.now
            do {
                let result = try PanoramaStitcher.stitch(frames: frames)
                let elapsed = ContinuousClock.now - start
                let after = residentMemoryBytes()
                let peakMB = Double(after) / 1_048_576
                let deltaMB = Double(after >= before ? after - before : 0) / 1_048_576
                print("MEASURED \(label): strip \(result.strip.width)x\(result.strip.height), " +
                      "wall \(elapsed), peak RSS \(String(format: "%.1f", peakMB)) MB " +
                      "(+\(String(format: "%.1f", deltaMB)) MB over this test)")
            } catch {
                print("MEASURED \(label): stitch threw \(error) after \(ContinuousClock.now - start)")
            }
        }

        print("\(checks - failures)/\(checks) composition and export checks passed")
        if failures != 0 { exit(1) }
    }
}
