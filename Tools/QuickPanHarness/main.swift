import Foundation
import CoreGraphics
import ImageIO

/// Independently rendered camera views at known angles, including an untextured
/// overlap. No camera or personal photographs are required.
@main struct QuickPanChecks {
    static func main() async throws {
        var failures = 0, checks = 0
        func check(_ passed: Bool, _ label: String) {
            checks += 1; if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(label)")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftTake/DemoPanSource.jpg")
        let scene = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        var source = [UInt8](repeating: 0, count: scene.width * scene.height * 4)
        source.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: scene.width, height: scene.height,
                                bitsPerComponent: 8, bytesPerRow: scene.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(scene, in: CGRect(x: 0, y: 0, width: scene.width, height: scene.height))
        }
        let step = Double.pi / 8, w = 480, h = 360, focal = 900.0
        // A synthetic focal length giving roughly `overlapFraction` overlap
        // at the given detent angle, so wider rings (fewer, larger steps)
        // still render frames that actually share image content. Solving
        // the matcher's own calibration formula backwards for a target step.
        func focalForStep(angle: Double, overlapFraction: Double = 0.3) -> Double {
            let targetStep = (1 - overlapFraction) * Double(w)
            let halfFOV = angle * Double(w-1) / (2 * targetStep)
            return Double(w-1) / (2 * tan(halfFOV))
        }
        // `stepAngle` defaults to the original 16-stop QuickPan detent so
        // every call below is unchanged; other rings pass their own angle.
        // The blanked strip is derived from the true geometric overlap for
        // whatever (stepAngle, focalLength) pair is in play, padded outward
        // so it fully covers the overlap rather than leaving a textured
        // sliver at an edge that a different detent angle would shift.
        func frame(_ position: Double, blankOverlap: Bool = true, blankClosing: Bool = false,
                   focalLength: Double = 900, stepAngle: Double = step) -> CGImage {
            let focal = focalLength
            let halfFOV = atan((Double(w-1)) / (2 * focal))
            let overlapLow = max(0, stepAngle - halfFOV)
            let pad = 0.1 * max(halfFOV - overlapLow, 0.02)
            let blankLow = max(0, overlapLow - pad), blankHigh = halfFOV + pad
            var pixels = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let ray = atan((Double(x) - Double(w-1)/2) / focal)
                var angle = position * stepAngle + ray
                if angle < 0 { angle += 2 * .pi }
                if angle >= 2 * .pi { angle -= 2 * .pi }
                let blank = (blankOverlap && blankHigh > blankLow && (5 * stepAngle + blankLow ... 5 * stepAngle + blankHigh).contains(angle))
                    || (blankClosing && blankHigh > blankLow && (2 * .pi - blankHigh ... 2 * .pi - blankLow).contains(angle))
                let sx = angle / (2 * .pi) * Double(scene.width) + Double(scene.width) / 4
                let sy = 239.5 + (Double(y) - Double(h-1)/2) * cos(ray)
                let x0 = Int(sx) % scene.width, x1 = (x0+1) % scene.width, y0 = Int(sy)
                let fx = sx - floor(sx), fy = sy - floor(sy)
                for c in 0..<3 {
                    let a = Double(source[(y0*scene.width+x0)*4+c])*(1-fx) + Double(source[(y0*scene.width+x1)*4+c])*fx
                    let b = Double(source[((y0+1)*scene.width+x0)*4+c])*(1-fx) + Double(source[((y0+1)*scene.width+x1)*4+c])*fx
                    pixels[(y*w+x)*4+c] = blank ? 180 : UInt8(max(0,min(255,a*(1-fy)+b*fy)))
                }
            } }
            return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                           space:CGColorSpace(name:CGColorSpace.sRGB)!,
                           bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider:CGDataProvider(data:Data(pixels) as CFData)!,decode:nil,
                           shouldInterpolate:false,intent:.defaultIntent)!
        }
        let frames = (0..<16).map { frame(Double($0)) }
        var options = PanoramaStitcher.Options(); options.quickPanAssisted = true
        let session = try PanoramaStitcher.match(frames: frames, options: options)
        let expected = step * Double(w-1) / (2 * atan(Double(w-1)/(2*focal)))
        check(session.order == Array(0..<16), "known capture order recovered")
        check(abs(Double(session.step)-expected) <= 2, "known angular spacing recovered")
        check(session.isFullRotation, "measured closing seam identifies full rotation")
        check(session.estimatedJoins.contains(5), "blank overlap identified as estimated")
        check(session.estimatedJoins.allSatisfy { session.fits[$0].correlation == 0 }, "estimates do not invent confidence")
        check(session.alignmentNote?.contains("6–7") == true, "estimated source positions identified")
        let reverse = try PanoramaStitcher.match(frames: frames.reversed(), options: options)
        check(reverse.order == Array((0..<16).reversed()) && reverse.step == session.step,
              "reverse sweep preserves geometry")
        let partial = try PanoramaStitcher.match(frames: Array(frames.prefix(12)), options: options)
        check(!partial.isFullRotation && (partial.sweepDegrees ?? 360) < 360, "partial sweep stays open")
        let unclosed = try PanoramaStitcher.match(frames: (0..<16).map { frame(Double($0), blankClosing: true) }, options: options)
        check(unclosed.alignmentNote?.contains("Closing seam unverified") == true, "unverified closing seam is disclosed")
        check(!unclosed.isFullRotation, "sixteen frames do not prove closure without image evidence")
        let wide = try PanoramaStitcher.match(frames: (0..<16).map { frame(Double($0), blankOverlap: false, focalLength: 400) }, options: options)
        let wideStep = step * Double(w-1) / (2 * atan(Double(w-1)/800))
        check(abs(Double(wide.step)-wideStep) <= 2 && wide.isFullRotation, "wider lens calibrated from the same detent angle")
        var manual = options; manual.fixedOrder = Array((0..<16).reversed())
        let fixed = try PanoramaStitcher.match(frames: frames.reversed(), options: manual)
        check(fixed.step == session.step, "explicit source order is respected")
        func rejects(_ input: [CGImage], _ label: String, using config: PanoramaStitcher.Options? = nil) {
            do { _ = try PanoramaStitcher.match(frames: input, options: config ?? options); check(false,label) }
            catch PanoramaStitcher.StitchError.quickPanMismatch { check(true,label) }
            catch { check(false,"\(label): unexpected \(error)") }
        }
        var uneven = frames; uneven[9] = frame(9.3)
        rejects(uneven,"uneven textured spacing rejected")
        var skipped = frames; skipped.remove(at: 9)
        rejects(skipped,"skipped textured position rejected")
        var repeated = frames; repeated[9] = repeated[8]
        rejects(repeated,"repeated textured position rejected")
        var shuffled = frames; shuffled.swapAt(9, 12)
        rejects(shuffled,"misordered textured sequence rejected")
        rejects(Array(repeating:frames[0],count:16),"no independent spacing evidence rejected")
        rejects(Array(frames.prefix(5)),"too few calibration frames rejected")
        manual.fixedOrder = Array(repeating:0,count:16)
        rejects(frames,"invalid manual permutation rejected",using:manual)
        do { _ = try PanoramaStitcher.match(frames:frames); check(false,"image-only path refuses blank gap") }
        catch PanoramaStitcher.StitchError.noConfidentMatch { check(true,"image-only path refuses blank gap") }
        let cancelled = Task.detached { try PanoramaStitcher.match(frames: frames, options: options) }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false,"cancelled assistance stops") }
        catch is CancellationError { check(true,"cancelled assistance stops") }

        // MARK: - Configurable stops-per-revolution (KW-2, KiWi+ rings, custom)
        //
        // Every QT150-era disc SwiftTake now declares explicitly, plus one
        // count (24) with no factory disc at all, proving the geometry is
        // derived from `degrees = 360 / stops` rather than tied to any one
        // wheel. 16 keeps its own dedicated checks above as the legacy default.
        func checkRing(stops: Int) {
            let label = "\(stops)-stop ring"
            let angle = 2 * Double.pi / Double(stops)
            // A fine detent (many stops) needs a disproportionately long
            // synthetic focal to hold a fixed 30% overlap, which pushes the
            // rendered projection far past every seed-stage ratio candidate
            // (0.8/1.25/2.0 x width) and the fixture frames stop sharing
            // recognisable correspondences at all. Targeting more overlap
            // at fine detents keeps the synthetic lens in a range the seed
            // search can actually bracket — a fixture concession, not a
            // change to any production threshold.
            let focal = focalForStep(angle: angle, overlapFraction: stops >= 24 ? 0.7 : 0.3)
            var opts = PanoramaStitcher.Options(); opts.quickPanAssisted = true; opts.quickPanStops = stops
            // No injected blank here: the blank-overlap estimation path has
            // its own dedicated coverage (legacy 16-stop and the 18-stop
            // sparse case below). At the 6-stop minimum the fixed "position
            // 5" blank location would collide with the closing join itself,
            // which would test a fixture artifact, not production behaviour.
            let full = (0..<stops).map { frame(Double($0), blankOverlap: false, focalLength: focal, stepAngle: angle) }
            do {
                let session = try PanoramaStitcher.match(frames: full, options: opts)
                let expected = angle * Double(w-1) / (2 * atan(Double(w-1)/(2*focal)))
                check(session.order == Array(0..<stops), "\(label): known capture order recovered")
                check(abs(Double(session.step)-expected) <= 2, "\(label): known angular spacing recovered")
                check(session.isFullRotation, "\(label): full-count sequence with closing evidence completes")
                check(session.quickPanStops == stops, "\(label): session records the declared stops")
                let reverse = try PanoramaStitcher.match(frames: full.reversed(), options: opts)
                check(reverse.order == Array((0..<stops).reversed()) && reverse.step == session.step,
                      "\(label): reverse direction preserves geometry")
                // Only meaningful when it is actually shorter than the full
                // ring — at the 6-stop floor every valid length IS the ring.
                let partialCount = max(7, stops * 2 / 3)
                if partialCount < stops {
                    let partial = try PanoramaStitcher.match(frames: Array(full.prefix(partialCount)), options: opts)
                    check(!partial.isFullRotation && (partial.sweepDegrees ?? 360) < 360, "\(label): partial sweep stays open")
                }
            } catch { check(false, "\(label): expected a match, got \(error)") }
            // One frame short of a full turn must never be forced closed by
            // count — except at the 6-stop floor, where one short drops
            // below the absolute minimum and must be rejected outright.
            var oneShort = options; oneShort.quickPanAssisted = true; oneShort.quickPanStops = stops
            if stops - 1 >= 6 {
                do {
                    let short = try PanoramaStitcher.match(frames: Array(full.dropLast()), options: oneShort)
                    check(!short.isFullRotation, "\(label): one frame short of the full count stays open")
                } catch { check(false, "\(label): one-short sweep: unexpected \(error)") }
            } else {
                do { _ = try PanoramaStitcher.match(frames: Array(full.dropLast()), options: oneShort)
                     check(false, "\(label): one short of the 6-frame floor is rejected") }
                catch PanoramaStitcher.StitchError.quickPanMismatch {
                    check(true, "\(label): one short of the 6-frame floor is rejected") }
                catch { check(false, "\(label): one short of the 6-frame floor: unexpected \(error)") }
            }
        }
        for stops in [6, 12, 14, 18, 20, 24, 32] { checkRing(stops: stops) }

        // Sparse evidence on an 18-stop ring: the default blanked overlap
        // (join 6–7) plus a blank closing seam. Estimation must still cover
        // the gaps, and frame count alone must not manufacture the missing
        // last-to-first evidence.
        let stops18 = 18, angle18 = 2 * Double.pi / Double(stops18), focal18 = focalForStep(angle: angle18)
        var opts18 = options; opts18.quickPanStops = stops18
        let sparse18 = (0..<stops18).map { frame(Double($0), blankClosing: true, focalLength: focal18, stepAngle: angle18) }
        do {
            let session = try PanoramaStitcher.match(frames: sparse18, options: opts18)
            check(!session.isFullRotation, "18-stop ring: sparse gaps never force closure by count alone")
            check(session.alignmentNote?.contains("Closing seam unverified") == true,
                  "18-stop ring: unverified closing seam disclosed")
            check((session.sweepDegrees ?? 360) < 360, "18-stop ring: sweep remains open without closing evidence")
            check(session.estimatedJoins.contains(5), "18-stop ring: default blank overlap still estimated")
        } catch { check(false, "18-stop ring sparse-gap case: unexpected \(error)") }

        // Frame count may never exceed the declared stops — more consecutive
        // shots than positions on the ring means at least one detent repeated.
        // A valid full-count baseline (checkRing(18) and the legacy 16-stop
        // `session` above) already proves these fixtures match when sized
        // correctly, so these rejections are not vacuous.
        let full18 = (0..<stops18).map { frame(Double($0), blankOverlap: false, focalLength: focal18, stepAngle: angle18) }
        var opts18Declared = options; opts18Declared.quickPanStops = stops18
        var repeatedStart19 = full18; repeatedStart19.append(full18[0])
        do { _ = try PanoramaStitcher.match(frames: repeatedStart19, options: opts18Declared)
             check(false, "19 frames with a repeated start rejected for an 18-stop ring") }
        catch PanoramaStitcher.StitchError.quickPanMismatch {
            check(true, "19 frames with a repeated start rejected for an 18-stop ring") }
        catch { check(false, "19 frames for an 18-stop ring: unexpected \(error)") }

        var declared16Input18 = frames; declared16Input18.append(contentsOf: [frames[0], frames[1]])
        do { _ = try PanoramaStitcher.match(frames: declared16Input18, options: options) // default quickPanStops = 16
             check(false, "18 frames rejected when declared as a 16-stop ring") }
        catch PanoramaStitcher.StitchError.quickPanMismatch {
            check(true, "18 frames rejected when declared as a 16-stop ring") }
        catch { check(false, "18 frames declared as a 16-stop ring: unexpected \(error)") }

        // Skipped/repeated/misordered rejection generalizes past the 16-stop
        // default — a 12-stop ring must reject the same error shapes.
        let stops12 = 12, angle12 = 2 * Double.pi / Double(stops12), focal12 = focalForStep(angle: angle12)
        var opts12 = options; opts12.quickPanStops = stops12
        let frames12 = (0..<stops12).map { frame(Double($0), focalLength: focal12, stepAngle: angle12) }
        func rejects12(_ input: [CGImage], _ label: String) {
            do { _ = try PanoramaStitcher.match(frames: input, options: opts12); check(false, label) }
            catch PanoramaStitcher.StitchError.quickPanMismatch { check(true, label) }
            catch { check(false, "\(label): unexpected \(error)") }
        }
        // Index 8, not 6 — the default blank overlap already sits at join 5
        // (positions 5–6); corrupting a position inside that blanked region
        // would leave the corrupted join with no texture to reject it by.
        var uneven12 = frames12; uneven12[8] = frame(8.3, focalLength: focal12, stepAngle: angle12)
        rejects12(uneven12, "12-stop ring: uneven spacing rejected")
        var skipped12 = frames12; skipped12.remove(at: 8)
        rejects12(skipped12, "12-stop ring: skipped position rejected")
        var repeated12 = frames12; repeated12[8] = repeated12[7]
        rejects12(repeated12, "12-stop ring: repeated position rejected")

        // Invalid/unsupported stop counts are rejected before any pixel work,
        // independent of an otherwise-valid frame set.
        func rejectsStops(_ stops: Int, _ label: String) {
            var invalid = options; invalid.quickPanStops = stops
            do { _ = try PanoramaStitcher.match(frames: frames, options: invalid); check(false, label) }
            catch PanoramaStitcher.StitchError.quickPanMismatch { check(true, label) }
            catch { check(false, "\(label): unexpected \(error)") }
        }
        rejectsStops(5, "stops below the 6...32 resource limit rejected")
        rejectsStops(33, "stops above the 6...32 resource limit rejected")

        print("\(checks-failures)/\(checks) QuickPan checks passed")
        if failures > 0 { exit(1) }
    }
}
