import Foundation
import CoreGraphics
import ImageIO

/// Known geometry and pixel truth, independent of the fitter's own report.
func regressions() -> Bool {
    var failures = 0, checks = 0
    func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL"): \(label)")
    }
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftTake/DemoPanSource.jpg")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let scene = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("FAIL: missing bundled scene"); return false
    }
    func bytes(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        out.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return out
    }
    func meanError(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let x = bytes(a), y = bytes(b)
        var error = 0.0
        for i in x.indices where i % 4 != 3 { error += abs(Double(x[i]) - Double(y[i])) }
        return error / Double(a.width * a.height * 3)
    }
    func crop(_ offsets: [Int]) -> [CGImage] {
        offsets.map { scene.cropping(to: CGRect(x: $0, y: 0, width: 640, height: 480))! }
    }
    do {
        let offsets = [0, 210, 510, 740, 1060]
        let frames = crop(offsets)
        let s = try PanoramaStitcher.match(frames: frames)
        check(s.positions(slope: s.fittedSlope).map(\.x) == offsets, "uneven horizontal positions preserved")
        let strip = s.render(slope: s.fittedSlope)!
        let truth = scene.cropping(to: CGRect(x: 0, y: 0, width: 1700, height: 480))!
        let error = meanError(strip, truth)
        check(error < 1.5, "uneven panorama matches original scene (mean error \(error))")
        check(!s.isFullRotation, "open arc stays open")
        let reversed = try PanoramaStitcher.match(frames: frames.reversed())
        check(reversed.order == Array((0..<5).reversed()), "reverse capture order detected")
        check(meanError(reversed.render(slope: reversed.fittedSlope)!, truth) < 1.5, "reverse sequence has correct pixels")
        let reversedBase = reversed.positions(slope: reversed.fittedSlope)
        let reversedEdited = reversed.positions(slope: reversed.fittedSlope, adjustments: [1: .init(x: 2, y: -3)])
        check(zip(reversedBase, reversedEdited).enumerated().allSatisfy { k, pair in
            let selected = reversed.order[k] == 1
            return pair.1.x - pair.0.x == (selected ? 2 : 0)
                && pair.1.y - pair.0.y == (selected ? -3 : 0)
        }, "reverse sequences adjust the selected source rather than the assembly index")
        let canvas = CGSize(width: strip.width, height: strip.height)
        let reverseRegion = reversed.frameRegions(for: 1, slope: reversed.fittedSlope,
            adjustments: [1: .init(x: 2, y: -3)], displayedSlope: reversed.fittedSlope,
            displayedAdjustments: [:], canvas: canvas)
        check(reverseRegion.count == 1 && abs(reverseRegion[0].minX * canvas.width - 742) < 0.001,
              "reverse capture selection highlights the correct source position")
        let shiftedRegions = s.frameRegions(for: 0, slope: s.fittedSlope,
            adjustments: [0: .init(x: -5, y: 4)], displayedSlope: s.fittedSlope,
            displayedAdjustments: [:], canvas: canvas)
        check(shiftedRegions.count == 1 && abs(shiftedRegions[0].minX * canvas.width + 5) < 0.001
              && abs(shiftedRegions[0].minY * canvas.height - 4) < 0.001,
              "first-frame feedback stays in the displayed canvas before recropping")
        check(s.frameRegions(for: 99, slope: s.fittedSlope, adjustments: [:],
                            displayedSlope: s.fittedSlope, displayedAdjustments: [:], canvas: canvas).isEmpty,
              "invalid coverage source produces no highlight")
        let oneShot = try PanoramaStitcher.stitch(frames: frames)
        check(meanError(oneShot.strip, strip) == 0, "one-shot and interactive render agree")

        // Render perspective camera frames from a known cylindrical scene.
        // The fixture generator goes in the opposite direction to the production
        // warp, and supplies known angular positions rather than fitted offsets.
        let sourcePixels = bytes(scene)
        let focal = 640.0 * 0.8
        let perspective = (0..<5).map { frame -> CGImage in
            var pixels = [UInt8](repeating: 255, count: 640 * 480 * 4)
            for y in 0..<480 {
                for x in 0..<640 {
                    let angle = atan((Double(x) - 319.5) / focal)
                    let sx = 320 + Double(frame * 240) + focal * angle
                    let sy = 239.5 + (Double(y) - 239.5) * cos(angle)
                    let x0 = Int(sx), y0 = Int(sy)
                    let fx = sx - Double(x0), fy = sy - Double(y0)
                    for channel in 0..<3 {
                        let a = Double(sourcePixels[(y0 * scene.width + x0) * 4 + channel]) * (1 - fx)
                            + Double(sourcePixels[(y0 * scene.width + x0 + 1) * 4 + channel]) * fx
                        let b = Double(sourcePixels[((y0 + 1) * scene.width + x0) * 4 + channel]) * (1 - fx)
                            + Double(sourcePixels[((y0 + 1) * scene.width + x0 + 1) * 4 + channel]) * fx
                        pixels[(y * 640 + x) * 4 + channel] = UInt8(max(0, min(255, a * (1 - fy) + b * fy)))
                    }
                }
            }
            return CGImage(width: 640, height: 480, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: 640 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
        let projected = try PanoramaStitcher.match(frames: perspective)
        check(projected.cylindricalFocalRatio == 0.8, "perspective sweep recovers its known cylindrical projection")
        check(projected.order == Array(0..<5), "projected forward sequence retains capture order")
        let pixelsPerRadian = 639.0 / (2 * atan(639.0 / (2 * focal)))
        let expectedStep = 240.0 / focal * pixelsPerRadian
        check(projected.fits.allSatisfy { abs(Double($0.dx) - expectedStep) < 1 && $0.dy == 0 },
              "projection recovers known angular spacing and level")
        check(projected.fits.allSatisfy { $0.correlation > 0.98 }, "projected joins agree across their overlap")
        let projectedReverse = try PanoramaStitcher.match(frames: perspective.reversed())
        check(projectedReverse.order == Array((0..<5).reversed()), "projection handles reverse capture order")
        check(meanError(projected.render(slope: 0)!, projectedReverse.render(slope: 0)!) == 0,
              "forward and reverse projected panoramas have identical pixels")
        var manualProjection = PanoramaStitcher.Options()
        manualProjection.fixedOrder = Array((0..<5).reversed())
        let projectedManual = try PanoramaStitcher.match(frames: perspective.reversed(), options: manualProjection)
        check(meanError(projected.render(slope: 0)!, projectedManual.render(slope: 0)!) == 0,
              "projection respects explicitly arranged frames")
        var brokenProjection = perspective
        brokenProjection[2] = makeSolid(width: 640, height: 480)
        do {
            _ = try PanoramaStitcher.match(frames: brokenProjection)
            check(false, "projection cannot conceal a missing overlapping frame")
        } catch PanoramaStitcher.StitchError.noConfidentMatch {
            check(true, "projection cannot conceal a missing overlapping frame")
        }
        check(s.cylindricalFocalRatio == nil, "already-valid translation is not reprojected")

        // Feature recovery uses independent point correspondences, so exercise
        // its geometry against known crops rather than its own confidence score.
        func plane(_ image: CGImage) -> PanoramaStitcher.Plane {
            let rgba = bytes(image)
            var p = PanoramaStitcher.Plane(w: image.width, h: image.height)
            for i in 0..<(image.width * image.height) {
                for c in 0..<3 { p.px[i*3+c] = Float(rgba[i*4+c]) / 255 }
            }
            return p
        }
        let featureLeft = try PanoramaStitcher.featureFrame(plane(frames[0]))
        var changed = plane(frames[1])
        // An independently moving foreground patch plus an exposure change.
        for y in 0..<changed.h { for x in 0..<changed.w { for c in 0..<3 {
            let moving = (90..<180).contains(x) && (100..<340).contains(y)
            changed.set(x, y, c, moving ? Float((x * 13 + y * 17 + c * 31) % 251)/251
                        : changed.at(x,y,c) * 0.7 + 0.1)
        } } }
        let featureRight = try PanoramaStitcher.featureFrame(changed)
        let recoveredPair = try PanoramaStitcher.featurePair(featureLeft, featureRight, options: .init())
        check(recoveredPair?.fit.dx == 210 && recoveredPair?.fit.dy == 0,
              "feature consensus recovers known spacing despite moving foreground and exposure")
        func doubled(_ source: PanoramaStitcher.Plane) -> PanoramaStitcher.Plane {
            var output = PanoramaStitcher.Plane(w: source.w*2, h: source.h*2)
            for y in 0..<output.h { for x in 0..<output.w { for c in 0..<3 {
                output.set(x,y,c,source.at(x/2,y/2,c))
            } } }
            return output
        }
        let largeLeft = try PanoramaStitcher.featureFrame(doubled(plane(frames[0])))
        let largeRight = try PanoramaStitcher.featureFrame(doubled(changed))
        let largeFit = try PanoramaStitcher.featurePair(largeLeft, largeRight, options: .init())
        check(largeFit?.fit.dx == 420 && largeFit?.fit.dy == 0,
              "bounded feature analysis returns offsets in original image pixels")
        let wrongDirection = try PanoramaStitcher.featurePair(featureRight, featureLeft, options: .init())
        check(wrongDirection == nil, "feature matching rejects the wrong sweep direction")
        let blank = try PanoramaStitcher.featureFrame(plane(makeSolid(width: 640, height: 480)))
        check(try PanoramaStitcher.featurePair(featureLeft, blank, options: .init()) == nil,
              "feature matching rejects textureless overlap")
        let unrelated = try PanoramaStitcher.featureFrame(plane(frames.last!))
        check(try PanoramaStitcher.featurePair(featureLeft, unrelated, options: .init()) == nil,
              "feature matching rejects nonoverlapping scenery")
        var repeated = PanoramaStitcher.Plane(w: 640, h: 480)
        for y in 0..<480 { for x in 0..<640 { for c in 0..<3 {
            repeated.set(x,y,c, ((x / 16 + y / 16) % 2 == 0) ? 0.2 : 0.8)
        } } }
        let repetitive = try PanoramaStitcher.featureFrame(repeated)
        check(try PanoramaStitcher.featurePair(repetitive, repetitive, options: .init()) == nil,
              "feature matching rejects ambiguous repeated patterns")
        let featureProjection = try PanoramaStitcher.recoverFeatures(perspective.map(plane), options: .init())
        check(featureProjection?.focalRatio == 0.8 && featureProjection?.fits.allSatisfy {
            abs(Double($0.dx)-expectedStep) <= 2 && abs($0.dy) <= 1
        } == true, "feature recovery finds independently generated perspective geometry")
        check(featureProjection?.closing == nil, "feature recovery does not invent a closing overlap")
        let reverseFeatures = try PanoramaStitcher.recoverFeatures(perspective.reversed().map(plane), options: .init())
        check(reverseFeatures?.order == Array((0..<5).reversed()), "feature recovery accepts reverse captures")
        var wrongFeatureOrder = PanoramaStitcher.Options()
        wrongFeatureOrder.fixedOrder = Array((0..<5).reversed())
        check(try PanoramaStitcher.recoverFeatures(perspective.map(plane), options: wrongFeatureOrder) == nil,
              "feature recovery cannot override an invalid manual arrangement")

        // Different vertical positions as well as horizontal steps.
        let ys = [20, 23, 18, 25, 21]
        let drifting = zip(offsets, ys).map { x, y in
            scene.cropping(to: CGRect(x: x, y: y, width: 640, height: 400))!
        }
        let d = try PanoramaStitcher.match(frames: drifting)
        let dstrip = d.render(slope: d.fittedSlope)!
        let dtruth = scene.cropping(to: CGRect(x: 0, y: 25, width: 1700, height: 393))!
        check(meanError(dstrip, dtruth) < 1.5, "vertical offsets and common crop match original scene")
        let shuffled = crop([0,512,256,768,1024])
        for manual in [false, true] {
            var options = PanoramaStitcher.Options()
            if manual { options.fixedOrder = Array(0..<5) }
            do {
                _ = try PanoramaStitcher.match(frames: shuffled, options: options)
                check(false, "\(manual ? "manual" : "automatic") weak sequence rejected")
            } catch PanoramaStitcher.StitchError.noConfidentMatch {
                check(true, "\(manual ? "manual" : "automatic") weak sequence rejected")
            }
        }
        // Finder's fixedOrder path: frames handed in scrambled array order,
        // with fixedOrder supplying the true left-to-right sequence. This is
        // the positive case — automatic ordering on the same scrambled array
        // must fail (forward/reverse of the array as given isn't the true
        // sequence), while fixedOrder must still reproduce known geometry.
        let scramble = [2, 0, 3, 1, 4]              // frames[i] holds offsets[scramble[i]]
        var unscramble = [Int](repeating: 0, count: 5)
        for (i, original) in scramble.enumerated() { unscramble[original] = i }
        let scrambledFrames = scramble.map { frames[$0] }
        do {
            _ = try PanoramaStitcher.match(frames: scrambledFrames)
            check(false, "automatic order on scrambled input rejected")
        } catch PanoramaStitcher.StitchError.noConfidentMatch {
            check(true, "automatic order on scrambled input rejected")
        }
        var fixedOptions = PanoramaStitcher.Options()
        fixedOptions.fixedOrder = unscramble
        let fixedSession = try PanoramaStitcher.match(frames: scrambledFrames, options: fixedOptions)
        check(fixedSession.order == unscramble, "fixedOrder reproduces the supplied arrangement")
        let fixedStrip = fixedSession.render(slope: fixedSession.fittedSlope)!
        check(meanError(fixedStrip, truth) < 1.5, "fixedOrder result matches known-good geometry")
        // A seamless loop cut from a period of a larger image; the edge
        // discontinuity of this source is intentional and must be retained.
        let circumference = 2048
        let band = scene.cropping(to: CGRect(x: 0, y: 0, width: circumference, height: 480))!
        let loop = (0..<8).map { k -> CGImage in
            let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 640 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            for x in [-k * 256, circumference - k * 256] {
                ctx.draw(band, in: CGRect(x: x, y: 0, width: circumference, height: 480))
            }
            return ctx.makeImage()!
        }
        let closed = try PanoramaStitcher.match(frames: loop)
        let closedStrip = closed.render(slope: closed.fittedSlope)!
        check(closed.isFullRotation, "known loop detected")
        check(closedStrip.width == circumference, "closed strip contains exactly one turn")
        let loopRegions = closed.frameRegions(for: closed.order.last!, slope: closed.fittedSlope,
            adjustments: [:], displayedSlope: closed.fittedSlope, displayedAdjustments: [:],
            canvas: CGSize(width: closedStrip.width, height: closedStrip.height))
        check(loopRegions.count == 2 && loopRegions.contains { $0.minX < 0 }
              && loopRegions.contains { $0.maxX > 1 }, "closing source highlights both ends of the panorama")
        check(loopRegions.count == 2 && abs(loopRegions[1].minX - loopRegions[0].minX - 1) < 0.001,
              "wrapped previews are exactly one circumference apart")
        check(meanError(closedStrip, band) < 1.5, "closing overlap pixels match ground truth")
        check(closed.render(slope: closed.fittedSlope + 2)?.width == circumference, "Level keeps closed circumference")
        let edgeCorrections = [closed.order.first!: PanoramaStitcher.FrameAdjustment(x: -3, y: 2),
                               closed.order.last!: PanoramaStitcher.FrameAdjustment(x: 4, y: -2)]
        check(closed.render(slope: closed.fittedSlope, adjustments: edgeCorrections)?.width == circumference,
              "first and last photo corrections retain exactly one full turn")
    } catch { check(false, "unexpected stitch error: \(error)") }

    // C4: a Finder-picked oversized photo is rejected before the expensive
    // work starts, not silently downsampled or left to run unbounded — see
    // PanoramaStitcher.maxFrameDimension. The guard only inspects raw
    // CGImage dimensions, so tiny content is enough to exercise it cheaply.
    func makeSolid(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
    let limit = PanoramaStitcher.maxFrameDimension
    do {
        let small = makeSolid(width: 20, height: 20)
        _ = try PanoramaStitcher.match(frames: Array(repeating: small, count: PanoramaStitcher.maxFrameCount + 1))
        check(false, "oversized frame count rejected before matching")
    } catch PanoramaStitcher.StitchError.tooManyFrames {
        check(true, "oversized frame count rejected before matching")
    } catch { check(false, "wrong batch-size error: \(error)") }
    do {
        let large = makeSolid(width: limit, height: limit)
        let count = PanoramaStitcher.maxInputPixels / (limit * limit) + 1
        _ = try PanoramaStitcher.match(frames: Array(repeating: large, count: count))
        check(false, "pixel budget rejected before float-plane allocation")
    } catch PanoramaStitcher.StitchError.pixelBudgetExceeded {
        check(true, "pixel budget rejected before float-plane allocation")
    } catch { check(false, "wrong pixel-budget error: \(error)") }
    for (label, w, h) in [("width over the limit", limit + 1, 100), ("height over the limit", 100, limit + 1)] {
        do {
            _ = try PanoramaStitcher.match(frames: [makeSolid(width: w, height: h), makeSolid(width: w, height: h)])
            check(false, "oversized frame (\(label)) rejected")
        } catch PanoramaStitcher.StitchError.frameTooLarge(let gotW, let gotH) {
            check(gotW == w && gotH == h, "oversized frame (\(label)) reports its actual size (\(gotW)x\(gotH))")
        } catch { check(false, "oversized frame (\(label)) threw the wrong error: \(error)") }
    }
    do {
        // At the limit, not over it — must not be rejected by this guard
        // (a separate small-content match may still fail for its own
        // reasons, which is not what this checks).
        let atLimit = [makeSolid(width: limit, height: 100), makeSolid(width: limit, height: 100)]
        do {
            _ = try PanoramaStitcher.match(frames: atLimit)
        } catch PanoramaStitcher.StitchError.frameTooLarge {
            check(false, "a frame exactly at the limit is rejected by the size guard")
        } catch { /* any other error is unrelated to the size guard */ }
        check(true, "a frame exactly at the limit is not rejected by the size guard")
    }
    print("\(checks - failures)/\(checks) geometry regressions passed")
    return failures == 0
}
