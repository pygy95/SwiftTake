// Aligns overlapping frames in capture order (or its reverse), compensates
// exposure, and blends a strip for flat and panoramic export. Pair offsets
// are retained: handheld pans need not have a constant step. This is a
// translation/stretch model with a bounded cylindrical fallback, not a
// general projective panorama solver.

import Foundation
import CoreGraphics
import Accelerate

// Pure image/geometry work, including nested options and immutable sessions,
// is used by detached tasks and must not inherit the UI actor.
nonisolated struct PanoramaStitcher {

    // MARK: Types

    /// What the matcher recovers for one overlapping pair.
    struct PairFit {
        var dx: Int
        var dy: Int
        /// Vertical scale of the right frame relative to the left. 1.0 =
        /// none. An off-level pan head produces this; Apple solved for it
        /// and reported it as "vert. stretch".
        var vStretch: Double
        var correlation: Double
    }

    struct Result {
        let strip: CGImage
        /// Left-to-right frame order, as decided by measurement.
        let order: [Int]
        let step: Int
        let slope: Int
        let fits: [PairFit]
        /// Overlap as a fraction of frame width, from the fitted step.
        let overlap: Double
        /// Horizontal field of view implied by the fitted step, given the
        /// sweep the caller declares. Apple's tool solved this rather than
        /// being told it.
        let impliedHFOV: Double?
        let croppedRows: Int
        /// True when the LAST frame overlaps the FIRST — i.e. the rig came
        /// all the way round. Measured, not assumed: writing a 360° movie
        /// for a partial arc makes the player wrap through scenery that
        /// was never shot, and writing a partial one for a full rotation
        /// leaves a seam the viewer can walk off.
        let isFullRotation: Bool
        /// Degrees the sequence covers, if a full rotation was detected
        /// (360) or the caller declared a sweep. Nil when unknown.
        let sweepDegrees: Double?
    }

    struct Options {
        /// Total sweep the sequence covers, degrees. Used only to imply a
        /// field of view for reporting; geometry does not depend on it.
        var sweepDegrees: Double?
        /// Bands the overlap is split into for correlation.
        var bands: Int = 5
        /// Bounds on the per-pair search, as a fraction of frame width.
        /// 0.10 = frames may overlap as much as 90%.
        ///
        /// Was 0.20, which quietly refused anything past 80%. Someone
        /// panning in small careful increments — or using a wide lens on a
        /// fixed detent — lands there easily, and the failure was not a
        /// refusal: the search pegged at its floor and returned a
        /// plausible-looking wrong answer. A sweep at 85% overlap measured
        /// the step as 170 when the truth was 96.
        var minStepFraction: Double = 0.10
        /// 0.80 = frames may overlap as little as 20%.
        ///
        /// Was 0.60, which quietly capped the app at 40% overlap. A pan
        /// shot with less did not fail — the search pegged at the ceiling
        /// and returned a panorama that looked plausible and was
        /// horizontally compressed, which is the worst way to be wrong.
        /// Caught by the demo photograph: cut at 33% overlap, it measured
        /// the step as exactly 0.60 x 640.
        var maxStepFraction: Double = 0.80
        var maxVerticalDrift: Int = 24
        /// Every join must pass, including a manually arranged sequence.
        /// A good mean can otherwise conceal a completely unrelated pair.
        var minimumCorrelation: Double = 0.60
        /// Vertical-stretch refinement, ± this fraction. Apple searched
        /// the equivalent; 2% covers a rig several degrees off level.
        var stretchRange: Double = 0.02
        var stretchSteps: Int = 5
        /// Minimum correlation gain before a fitted stretch is accepted.
        /// Below this the pair keeps its translation-only fit — a free
        /// parameter always fits something, and resampling to chase noise
        /// costs sharpness for nothing.
        var minStretchGain: Double = 0.02
        /// Frame order the caller INSISTS on, left to right. Nil measures
        /// it, which is the default and the right answer whenever the
        /// frames arrive as a run — a gallery selection is already in
        /// capture order, so there is nothing to decide but direction.
        ///
        /// Set only when the caller knows something the pixels do not:
        /// files gathered in Finder from anywhere, in any order. A fixed
        /// order still has to pass the same per-pair confidence checks.
        var fixedOrder: [Int]?
        /// Explicit opt-in for consecutive rig-detent spacing (QuickPan and
        /// compatible tripod heads).
        var quickPanAssisted = false
        /// Stops per full revolution for the declared rig, validated against
        /// `quickPanStopsRange`. 16 preserves the original QuickPan detent
        /// and is the default for existing callers that only set
        /// `quickPanAssisted`.
        var quickPanStops: Int = 16
        var featherPixels: Int = 70
        var blendLevels: Int = 6
    }

    enum StitchError: Error, CustomStringConvertible {
        case tooFewFrames(Int)
        case mismatchedSizes
        case noConfidentMatch
        case quickPanMismatch
        case renderFailed
        case frameTooLarge(width: Int, height: Int)
        case tooManyFrames
        case pixelBudgetExceeded
        var description: String {
            switch self {
            case .tooFewFrames(let n): return "Need at least 2 frames to stitch, got \(n)."
            case .mismatchedSizes:     return "All frames must share the same pixel dimensions."
            case .noConfidentMatch:    return "Could not find a confident overlap between frames."
            case .quickPanMismatch:   return "These photos don't provide enough consistent detail for the selected tripod spacing. Use at least 6 consecutive shots, with no skipped or repeated starting position, and enough evidence across the set to confirm it."
            case .renderFailed:        return "Could not render the stitched panorama."
            case .frameTooLarge(let w, let h):
                return "Photo \(w)\u{00d7}\(h) is too large for a panorama — each side must be \(maxFrameDimension)px or less."
            case .tooManyFrames:
                return "Choose at most \(maxFrameCount) photos for one panorama."
            case .pixelBudgetExceeded:
                return "Those photos contain more than 24 megapixels in total. Select fewer photos for this panorama."
            }
        }
    }

    /// Bounds apply before float-plane allocation. The pixel budget admits
    /// the measured twelve-frame 1600x1200 case without allowing an unbounded batch.
    static let maxFrameDimension = 1600
    static let maxFrameCount = 32
    static let maxInputPixels = 24_000_000
    /// Valid stops-per-revolution for QuickPan-style rig assistance: wide
    /// enough for every known KiWi/QuickPan disc (12/14/16/18/20) plus other
    /// consecutive-detent heads, bounded by the frame-count resource limit.
    static let quickPanStopsRange = 6...32

    /// Shared "N°" formatting for a declared stops-per-revolution, used by
    /// both the session's alignment note and the retry control's display.
    static func quickPanAngleLabel(stops: Int) -> String {
        let degrees = 360.0 / Double(stops)
        return degrees == degrees.rounded()
            ? String(format: "%.0f\u{00b0}", degrees)
            : String(format: "%.1f\u{00b0}", degrees)
    }

    // MARK: Plane

    /// Planar float RGB. The whole pipeline works in float: gain
    /// compensation, pyramid blending and stretch resampling all need
    /// headroom above 1.0 and below 0, and quantising between stages was
    /// what cost the decoder its HDR before.
    struct Plane {
        var w: Int, h: Int
        var px: [Float]          // interleaved RGB
        init(w: Int, h: Int) { self.w = w; self.h = h; px = [Float](repeating: 0, count: w*h*3) }
        @inline(__always) func at(_ x: Int, _ y: Int, _ c: Int) -> Float { px[(y*w + x)*3 + c] }
        @inline(__always) mutating func set(_ x: Int, _ y: Int, _ c: Int, _ v: Float) { px[(y*w + x)*3 + c] = v }
        func luma() -> [Float] {
            var out = [Float](repeating: 0, count: w*h)
            for i in 0..<(w*h) {
                out[i] = 0.299*px[i*3] + 0.587*px[i*3+1] + 0.114*px[i*3+2]
            }
            return out
        }
    }

    /// A completed match, held so the assembly can be re-run cheaply.
    ///
    /// Matching is the expensive half — a 2-D search per pair, seconds on
    /// a handful of frames. Assembly (gain, seam, blend) is fast. Keeping
    /// them apart is what lets the Level control re-render live instead of
    /// re-solving geometry that has not changed.
    struct FrameAdjustment: Equatable, Sendable {
        var x = 0
        var y = 0
    }

    final class Session {
        fileprivate let planes: [Plane]
        fileprivate let options: Options
        let order: [Int]
        /// Mean spacing for reporting only; assembly uses individual fits.
        let step: Int
        /// The slope the matcher fitted. `Auto` returns here.
        let fittedSlope: Int
        let fits: [PairFit]
        let overlap: Double
        let impliedHFOV: Double?
        let isFullRotation: Bool
        let sweepDegrees: Double?
        fileprivate let closingFit: PairFit?
        /// Fitted projection parameter, not a calibrated lens specification.
        let cylindricalFocalRatio: Double?
        /// Distinguishes local-patch confidence from whole-overlap correlation.
        let usesFeatureAlignment: Bool
        let rollCorrectionDegrees: Double
        /// Indices into `fits`, identifying joins estimated from the rig.
        let estimatedJoins: [Int]
        let usesQuickPanAssistance: Bool
        /// Declared stops per revolution, when `usesQuickPanAssistance` is
        /// true. Nil for image-only sessions, which carry no rig geometry.
        let quickPanStops: Int?

        /// Small previews use the same orientation and projection as the blend.
        func thumbnail(for source: Int) -> CGImage? {
            guard planes.indices.contains(source) else { return nil }
            let frame = planes[source]
            let scale = min(1, 96.0 / Double(max(frame.w, frame.h)))
            var small = Plane(w: max(1, Int(Double(frame.w) * scale)),
                              h: max(1, Int(Double(frame.h) * scale)))
            for y in 0..<small.h {
                for x in 0..<small.w {
                    for c in 0..<3 {
                        small.set(x, y, c, frame.at(x * frame.w / small.w, y * frame.h / small.h, c))
                    }
                }
            }
            return cgImage(from: small)
        }

        func frameCenters(slope: Int, adjustments: [Int: FrameAdjustment]) -> [Double] {
            let points = positions(slope: slope, adjustments: adjustments)
            let start = points.map(\.x).min() ?? 0
            let automatic = positions(slope: slope)
            let width = closingFit.map { automatic.last!.x + $0.dx }
                ?? ((points.map(\.x).max() ?? 0) - start + planes[0].w)
            return points.map { min(1, max(0, Double($0.x - start + planes[0].w / 2) / Double(width))) }
        }

        /// Source coverage in the displayed strip's coordinates. Pending edits
        /// stay relative to that strip until its replacement is ready. A source
        /// spanning the closing seam appears at both ends of a full rotation.
        func frameRegions(for source: Int, slope: Int, adjustments: [Int: FrameAdjustment],
                          displayedSlope: Int, displayedAdjustments: [Int: FrameAdjustment],
                          canvas: CGSize) -> [CGRect] {
            guard let index = order.firstIndex(of: source), canvas.width > 0, canvas.height > 0 else { return [] }
            let displayed = positions(slope: displayedSlope, adjustments: displayedAdjustments)
            let position = positions(slope: slope, adjustments: adjustments)[index]
            let x = CGFloat(position.x - (displayed.map(\.x).min() ?? 0))
            let y = CGFloat(position.y - (displayed.map(\.y).max() ?? 0))
            let frame = planes[source]
            let offsets: [CGFloat] = isFullRotation ? [-canvas.width, 0, canvas.width] : [0]
            return offsets.compactMap { offset in
                let rect = CGRect(x: x + offset, y: y, width: CGFloat(frame.w), height: CGFloat(frame.h))
                guard rect.intersects(CGRect(origin: .zero, size: canvas)) else { return nil }
                return CGRect(x: rect.minX / canvas.width, y: rect.minY / canvas.height,
                              width: rect.width / canvas.width, height: rect.height / canvas.height)
            }
        }

        /// A single prepared source for immediate edit feedback. Its projection,
        /// orientation and exposure gains match the current assembly; final seam
        /// blending still comes from `render` and is the only saveable image.
        func adjustmentPreview(for source: Int, slope: Int,
                               adjustments: [Int: FrameAdjustment]) -> CGImage? {
            guard planes.indices.contains(source), !Task.isCancelled else { return nil }
            let points = positions(slope: slope, adjustments: adjustments)
            let automatic = positions(slope: slope)
            let closingDistance = closingFit.map { automatic.last!.x + $0.dx + points[0].x - points.last!.x }
            let gains = gainCompensate(planes, order: order, positions: points, closingDistance: closingDistance)
            guard !Task.isCancelled else { return nil }
            var frame = planes[source]
            for i in frame.px.indices { frame.px[i] *= Float(gains[source][i % 3]) }
            return cgImage(from: frame)
        }

        /// Source positions in the selected sequence, not camera slot numbers.
        var alignmentNote: String? {
            guard usesQuickPanAssistance, let quickPanStops else { return nil }
            // Truthful regardless of ring: only the 16-stop case is the
            // original QuickPan disc, so only it is named that way.
            let provenance = quickPanStops == 16 ? "QuickPan spacing"
                : "\(quickPanStops)-stop tripod spacing (\(PanoramaStitcher.quickPanAngleLabel(stops: quickPanStops)))"
            let closing = order.count == quickPanStops && !isFullRotation ? ". Closing seam unverified." : ""
            guard !estimatedJoins.isEmpty else { return "\(provenance) · all adjacent joins image-verified" + closing }
            let pairs = estimatedJoins.map { i in
                let a = order[i] + 1, b = order[i + 1] + 1
                return "\(min(a, b))–\(max(a, b))"
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return "\(provenance) estimates between selected photos: " + pairs.joined(separator: ", ") + closing
        }

        init(planes: [Plane], options: Options, order: [Int], step: Int,
                         fittedSlope: Int, fits: [PairFit], overlap: Double,
                         impliedHFOV: Double?, isFullRotation: Bool, sweepDegrees: Double?,
                         closingFit: PairFit?, cylindricalFocalRatio: Double? = nil,
                         usesFeatureAlignment: Bool = false, rollCorrectionDegrees: Double = 0,
                         estimatedJoins: [Int] = [], usesQuickPanAssistance: Bool = false,
                         quickPanStops: Int? = nil) {
            self.planes = planes; self.options = options; self.order = order
            self.step = step; self.fittedSlope = fittedSlope; self.fits = fits
            self.overlap = overlap; self.impliedHFOV = impliedHFOV
            self.isFullRotation = isFullRotation; self.sweepDegrees = sweepDegrees
            self.closingFit = closingFit
            self.cylindricalFocalRatio = cylindricalFocalRatio
            self.usesFeatureAlignment = usesFeatureAlignment
            self.rollCorrectionDegrees = rollCorrectionDegrees
            self.estimatedJoins = estimatedJoins
            self.usesQuickPanAssistance = usesQuickPanAssistance
            self.quickPanStops = quickPanStops
        }

        /// Positions in assembly order. The Level control adds a correction
        /// to the measured path instead of discarding each pair's offset.
        func positions(slope: Int, adjustments: [Int: FrameAdjustment] = [:]) -> [(x: Int, y: Int)] {
            var positions = [(x: 0, y: 0)]
            for fit in fits {
                let last = positions.last!
                positions.append((last.x + fit.dx, last.y + fit.dy))
            }
            if let closingFit {
                let circumference = positions.last!.x + closingFit.dx
                let drift = positions.last!.y + closingFit.dy
                for k in positions.indices {
                    let fraction = Double(positions[k].x) / Double(circumference)
                    // A level correction must be periodic on a closed pan.
                    // A linear shear would reopen the vertical closing seam.
                    let level = Double(slope - fittedSlope) * Double(order.count)
                        / (2 * .pi) * sin(2 * .pi * fraction)
                    positions[k].y += Int((level - Double(drift) * fraction).rounded())
                }
            } else {
                for k in positions.indices { positions[k].y += k * (slope - fittedSlope) }
            }
            for k in order.indices {
                let adjustment = adjustments[order[k]] ?? FrameAdjustment()
                positions[k].x += adjustment.x
                positions[k].y += adjustment.y
            }
            return positions
        }

        func render(slope: Int, adjustments: [Int: FrameAdjustment] = [:]) -> CGImage? {
            guard !Task.isCancelled else { return nil }
            let automatic = positions(slope: slope)
            let circumference = closingFit.map { automatic.last!.x + $0.dx }
            let positions = positions(slope: slope, adjustments: adjustments)
            let closingDistance = circumference.map { $0 + positions[0].x - positions.last!.x }
            // Manual corrections must keep consecutive frames overlapping.
            // Reject an invalid layout before pixel indexing or allocation.
            let distances = zip(positions, positions.dropFirst()).map { $1.x - $0.x }
                + (closingDistance.map { [$0] } ?? [])
            guard distances.allSatisfy({ $0 > 0 && $0 < planes[0].w }),
                  (positions.map(\.y).max()! - positions.map(\.y).min()!) < planes[0].h else { return nil }
            let gains = gainCompensate(planes, order: order, positions: positions,
                                       closingDistance: closingDistance)
            guard let out = assemble(planes, order: order, positions: positions,
                                     gains: gains, options: options,
                                     circumference: circumference), !Task.isCancelled else { return nil }
            return cgImage(from: out.plane)
        }
    }

    /// How many pair matches `match` will run for `n` frames, so a caller
    /// can size a progress bar before any work starts.
    ///
    /// It is not `n - 1`. The frame ORDER is decided by measurement, so
    /// both candidate orderings are fitted in full, and one more match
    /// closes the last frame onto the first to test for a full rotation.
    static func pairMatchCount(frames n: Int) -> Int {
        n >= 2 ? (n - 1) * 2 + 1 : 0
    }

    /// Reports `(completed, total)` pair matches. Called on whatever
    /// thread the match is running on, which is never the main one.
    typealias MatchProgress = (Int, Int) -> Void

    /// Match only — no assembly. For callers that will drive `render`.
    ///
    /// Cancellable at pair boundaries — see `fitSequence`. Throws
    /// `CancellationError` in that case, which callers should treat as
    /// "the user changed their mind", not as a failure to report.
    static func match(frames input: [CGImage], options: Options = Options(),
                      refining: (() -> Void)? = nil, progress: MatchProgress? = nil) throws -> Session {
        var prepared = try prepare(input, options: options)
        if options.quickPanAssisted {
            refining?()
            return try matchQuickPan(prepared, options: options)
        }
        var completed = 0
        let total = pairMatchCount(frames: prepared.count)
        let tick = { completed += 1; progress?(completed, total) }
        let order: [Int], chosen: SequenceFit
        var focalRatio: Double?
        var featureRecovery: FeatureRecovery?
        do {
            (order, chosen) = try chooseOrder(prepared, options: options, tick: tick)
        } catch StitchError.noConfidentMatch {
            refining?()
            // A rotating camera produces perspective changes that translation
            // alone cannot explain. Try one shared projection for the entire
            // sequence; every join must still meet the original confidence and
            // search-boundary requirements. Already-valid matches stay intact.
            var best: (planes: [Plane], order: [Int], fit: SequenceFit, ratio: Double)?
            for ratio in [0.8, 1.25, 2.0] {
                try Task.checkCancellation()
                let projected = try prepared.map { try cylindricalProjection($0, focalRatio: ratio) }
                do {
                    let (candidateOrder, fit) = try chooseOrder(projected, options: options)
                    guard fit.fits.allSatisfy({ usable($0, width: projected[0].w, options: options) }) else { continue }
                    if let previous = best, fit.meanCorrelation <= previous.fit.meanCorrelation { continue }
                    best = (projected, candidateOrder, fit, ratio)
                } catch StitchError.noConfidentMatch { continue }
            }
            if let best {
                prepared = best.planes
                order = best.order
                chosen = best.fit
                focalRatio = best.ratio
            } else if let recovery = try recoverFeatures(prepared, options: options) {
                prepared = recovery.planes
                order = recovery.order
                chosen = SequenceFit(fits: recovery.fits,
                                     meanCorrelation: recovery.fits.map(\.correlation).reduce(0,+)
                                         / Double(recovery.fits.count))
                focalRatio = recovery.focalRatio
                featureRecovery = recovery
            } else { throw StitchError.noConfidentMatch }
        }
        let step  = Int((chosen.fits.map { Double($0.dx) }.reduce(0,+) / Double(chosen.fits.count)).rounded())
        let slope = Int((chosen.fits.map { Double($0.dy) }.reduce(0,+) / Double(chosen.fits.count)).rounded())
        guard chosen.fits.allSatisfy({ usable($0, width: prepared[0].w, options: options) }) else {
            throw StitchError.noConfidentMatch
        }
        let corrected = applyStretches(prepared, order: order, fits: chosen.fits)
        let w = prepared[0].w
        try Task.checkCancellation()
        // A feature-recovered sequence must also close with independent feature
        // evidence. Whole-wall brightness correlation can invent a closing join.
        let closing: PairFit
        if let recovery = featureRecovery {
            closing = recovery.closing ?? PairFit(dx: 0, dy: 0, vStretch: 1, correlation: 0)
        } else {
            closing = matchPair(prepared[order[order.count-1]], prepared[order[0]], options: options)
        }
        tick()
        let span = chosen.fits.map(\.dx).reduce(0, +)
        let verticalClosure = chosen.fits.map(\.dy).reduce(0, +) + closing.dy
        let isFull = prepared.count >= 3 && span + closing.dx > w
            && usable(closing, width: w, options: options)
            && closing.correlation > max(0.75, chosen.meanCorrelation * 0.9)
            && abs(verticalClosure) <= max(4, prepared.count)
        let hfov = options.sweepDegrees.map { sweep -> Double in
            (sweep / Double(prepared.count - 1)) * Double(w) / Double(step)
        }
        return Session(planes: corrected, options: options, order: order, step: step,
                       fittedSlope: slope, fits: chosen.fits,
                       overlap: Double(w - step) / Double(w), impliedHFOV: hfov,
                       isFullRotation: isFull,
                       sweepDegrees: isFull ? 360 : options.sweepDegrees,
                       closingFit: isFull ? closing : nil,
                       cylindricalFocalRatio: focalRatio,
                       usesFeatureAlignment: featureRecovery != nil,
                       rollCorrectionDegrees: (featureRecovery?.roll ?? 0) * 180 / .pi)
    }

    /// Inverse cylindrical mapping with bilinear sampling. Crop to the common
    /// valid vertical extent, so black corners never become matching evidence.
    /// Keeping width fixed bounds memory and preserves the pair-search limits.
    static func cylindricalProjection(_ p: Plane, focalRatio: Double) throws -> Plane {
        guard p.w > 1, p.h > 1 else { throw StitchError.noConfidentMatch }
        let focal = Double(p.w) * focalRatio
        let halfAngle = atan(Double(p.w - 1) / (2 * focal))
        let scale = Double(p.w - 1) / (2 * halfAngle)
        let height = max(1, Int(Double(p.h - 1) * cos(halfAngle) * scale / focal))
        var output = Plane(w: p.w, h: height)
        for x in 0..<output.w {
            if x.isMultiple(of: 32) { try Task.checkCancellation() }
            let angle = (Double(x) - Double(output.w - 1) / 2) / scale
            let sx = min(Double(p.w - 1), max(0, focal * tan(angle) + Double(p.w - 1) / 2))
            let x0 = min(p.w - 2, Int(sx)), fx = Float(sx - Double(x0))
            for y in 0..<height {
                let sy = min(Double(p.h - 1), max(0,
                    (Double(y) - Double(height - 1) / 2) * focal / (scale * cos(angle)) + Double(p.h - 1) / 2))
                let y0 = min(p.h - 2, Int(sy)), fy = Float(sy - Double(y0))
                for c in 0..<3 {
                    let top = p.at(x0, y0, c) * (1 - fx) + p.at(x0 + 1, y0, c) * fx
                    let bottom = p.at(x0, y0 + 1, c) * (1 - fx) + p.at(x0 + 1, y0 + 1, c) * fx
                    output.set(x, y, c, top * (1 - fy) + bottom * fy)
                }
            }
        }
        return output
    }

    private static func prepare(_ input: [CGImage], options: Options) throws -> [Plane] {
        guard input.count >= 2 else { throw StitchError.tooFewFrames(input.count) }
        guard input.count <= maxFrameCount else { throw StitchError.tooManyFrames }
        if let oversized = input.first(where: {
            $0.width > maxFrameDimension || $0.height > maxFrameDimension
        }) {
            throw StitchError.frameTooLarge(width: oversized.width, height: oversized.height)
        }
        guard input.reduce(0, { $0 + $1.width * $1.height }) <= maxInputPixels else {
            throw StitchError.pixelBudgetExceeded
        }
        guard input.allSatisfy({ $0.width == input[0].width && $0.height == input[0].height }) else {
            throw StitchError.mismatchedSizes
        }
        var planes = try input.map { try plane(from: $0) }
        planes = upright(planes, options: options)
        return planes
    }

    private static func chooseOrder(_ planes: [Plane], options: Options,
                                    tick: () -> Void = {}) throws -> ([Int], SequenceFit) {
        let n = planes.count

        // Manual order controls the sequence, not the confidence threshold.
        // `match` validates every fitted pair before constructing a session.
        if let fixed = options.fixedOrder,
           fixed.count == n, Set(fixed) == Set(0..<n) {
            let fit = try fitSequence(planes, order: fixed, options: options, tick: tick)
            // The unused half of the budget still has to be spent, or the
            // progress bar the caller sized with `pairMatchCount` stops
            // short of the end and looks stalled.
            for _ in 0..<(n - 1) { tick() }
            guard fit.fits.allSatisfy({ usable($0, width: planes[0].w, options: options) }) else {
                throw StitchError.noConfidentMatch
            }
            return (fixed, fit)
        }

        let forward = Array(0..<n), reverse = Array((0..<n).reversed())
        let f = try fitSequence(planes, order: forward, options: options, tick: tick)
        let r = try fitSequence(planes, order: reverse, options: options, tick: tick)
        let fValid = f.fits.allSatisfy { usable($0, width: planes[0].w, options: options) }
        let rValid = r.fits.allSatisfy { usable($0, width: planes[0].w, options: options) }
        guard fValid || rValid else { throw StitchError.noConfidentMatch }
        let useForward = fValid && (!rValid || f.meanCorrelation >= r.meanCorrelation)
        let chosen = useForward ? f : r
        return (useForward ? forward : reverse, chosen)
    }

    // MARK: - Entry point

    static func stitch(frames input: [CGImage], options: Options = Options()) throws -> Result {
        let session = try match(frames: input, options: options)
        guard let strip = session.render(slope: session.fittedSlope) else { throw StitchError.renderFailed }
        return Result(strip: strip, order: session.order, step: session.step,
                      slope: session.fittedSlope, fits: session.fits, overlap: session.overlap,
                      impliedHFOV: session.impliedHFOV,
                      croppedRows: session.planes[0].h - strip.height,
                      isFullRotation: session.isFullRotation, sweepDegrees: session.sweepDegrees)
    }

    private static func usable(_ fit: PairFit, width: Int, options: Options) -> Bool {
        fit.correlation.isFinite && fit.correlation >= options.minimumCorrelation
            && !stepIsPegged(fit.dx, frameWidth: width, options: options)
    }

    // MARK: - Matching

    private struct SequenceFit {
        var fits: [PairFit]
        var meanCorrelation: Double
    }

    /// In a left-to-right ordering, frame R sits `dx` to the RIGHT of L, so
    /// L's right edge overlaps R's left edge. One convention, used
    /// everywhere — mixing two is how the ordering got inverted twice.
    private static func fitSequence(_ p: [Plane], order: [Int], options: Options,
                                    tick: () -> Void = {}) throws -> SequenceFit {
        var fits: [PairFit] = []
        for k in 0..<(order.count - 1) {
            // The pair boundary is the cancellation point. Testing inside
            // `matchPair` would mean a branch per candidate offset across
            // a search that runs millions of them, to shorten a wait that
            // is already bounded by one pair — a couple of seconds — no
            // matter how large the set is.
            try Task.checkCancellation()
            fits.append(matchPair(p[order[k]], p[order[k+1]], options: options))
            tick()
        }
        let mean = fits.map(\.correlation).reduce(0,+) / Double(max(1, fits.count))
        return SequenceFit(fits: fits, meanCorrelation: mean)
    }

    /// True when the fitted step sits on the rim of the search window.
    ///
    /// The window cannot express an offset outside itself, so when the real
    /// overlap falls beyond it the search does not fail — it returns the
    /// nearest edge, which assembles into a panorama that looks plausible
    /// and is geometrically wrong. That is the worst way to be wrong, and it
    /// is how BOTH range bugs in this file presented: capped at 40% overlap
    /// it reported step 384 for a true 428, and floored at 80% it reported
    /// 170 for a true 96.
    ///
    /// A result on the rim is therefore treated as no result. Better to tell
    /// the user their frames overlap too much or too little than to hand
    /// them a compressed panorama and let them wonder.
    static func stepIsPegged(_ step: Int, frameWidth w: Int, options: Options) -> Bool {
        let lo = max(8, Int(Double(w) * options.minStepFraction))
        let hi = min(w - 8, Int(Double(w) * options.maxStepFraction))
        return step <= lo || step >= hi
    }

    static func matchPair(_ L: Plane, _ R: Plane, options: Options) -> PairFit {
        let lum = L.luma(), rum = R.luma()
        let w = L.w, h = L.h
        let lo = max(8, Int(Double(w) * options.minStepFraction))
        let hi = min(w - 8, Int(Double(w) * options.maxStepFraction))
        var best = PairFit(dx: lo, dy: 0, vStretch: 1.0, correlation: -2)

        // COARSE-TO-FINE translation search.
        //
        // The exhaustive version cost 1.35 s per pair, which is 63 s for a
        // 16-frame rotation — a wait nobody should be asked for. It
        // evaluated ~9,400 correlations over the full overlap.
        //
        // Searching a quarter-scale copy first cuts the work two ways at
        // once: a quarter of the offsets in each axis, over a sixteenth of
        // the pixels. The winner is then refined at full resolution in a
        // small window, so the ANSWER is still a full-resolution answer —
        // only the hunting for it is cheap.
        //
        // This is Apple's `-offset` plus a bounded `-range` in a different
        // dress: they seeded each pair from a nominal offset, we seed it
        // from a downsampled search. Same insight — never search the whole
        // space at full cost when something cheaper can say roughly where
        // to look.
        let (cw, ch, cLum) = downsample4(lum, w: w, h: h)
        let (_, _, cRum)   = downsample4(rum, w: w, h: h)
        var coarse = (dx: lo/4, dy: 0, c: -2.0)
        for dx in max(2, lo/4)...max(3, hi/4) {
            for dy in -(options.maxVerticalDrift/4)...(options.maxVerticalDrift/4) {
                let c = bandedNCC(cLum, cRum, w: cw, h: ch, dx: dx, dy: dy, bands: options.bands, minimumOverlap: 10)
                if c > coarse.c { coarse = (dx, dy, c) }
            }
        }

        // Refine at full resolution. The window is ±6, comfortably more
        // than the ±4 of positional uncertainty a 4x downsample can
        // introduce, so the coarse pass cannot cost accuracy — only time.
        let seedX = coarse.dx * 4, seedY = coarse.dy * 4
        for dx in max(lo, seedX - 6)...min(hi, seedX + 6) {
            for dy in max(-options.maxVerticalDrift, seedY - 6)...min(options.maxVerticalDrift, seedY + 6) {
                let c = bandedNCC(lum, rum, w: w, h: h, dx: dx, dy: dy, bands: options.bands)
                if c > best.correlation { best = PairFit(dx: dx, dy: dy, vStretch: 1.0, correlation: c) }
            }
        }

        // Refine vertical stretch around the winning translation. Apple
        // solved this per pair and called it "vert. stretch".
        guard options.stretchSteps > 1 else { return best }
        let translationOnly = best
        let half = (options.stretchSteps - 1) / 2
        for s in -half...half where s != 0 {
            let f = 1.0 + options.stretchRange * Double(s) / Double(half)
            let stretched = verticalStretch(rum, w: w, h: h, factor: f)
            for dy in max(-options.maxVerticalDrift, best.dy - 3)...min(options.maxVerticalDrift, best.dy + 3) {
                let c = bandedNCC(lum, stretched, w: w, h: h, dx: best.dx, dy: dy, bands: options.bands)
                if c > best.correlation {
                    best = PairFit(dx: best.dx, dy: dy, vStretch: f, correlation: c)
                }
            }
        }

        // Only KEEP the stretch if it earns its place. A free parameter
        // will always fit *something*, and on the reference set it solved
        // to mixed signs (1.02, 1.01, 0.98) for gains of +0.03, +0.006 and
        // +0.009 — a consistently off-level rig should give a consistent
        // sign, so that is noise being fitted, not geometry being
        // recovered. Resampling every frame to chase it would cost real
        // sharpness for nothing.
        //
        // Same principle as the constrained step/slope fit: prefer the
        // simpler model unless the data insists otherwise. A rig tilted
        // enough for stretch to matter clears this easily.
        if best.correlation - translationOnly.correlation < options.minStretchGain {
            return translationOnly
        }
        return best
    }

    /// Normalised cross-correlation over horizontal bands, averaged.
    /// Banding is Apple's design: a whole-overlap match is dominated by
    /// whichever part of the scene has the most contrast, and near/far
    /// content disagrees under parallax.
    private static func bandedNCC(_ a: [Float], _ b: [Float], w: Int, h: Int,
                                  dx: Int, dy: Int, bands: Int, minimumOverlap: Int = 40) -> Double {
        let ay0 = max(0, dy), ay1 = min(h, h + dy)
        guard ay1 - ay0 > bands * 4, w - dx > minimumOverlap else { return -2 }
        let bandH = (ay1 - ay0) / bands
        var total = 0.0, norm = 0.0, used = 0
        for band in 0..<bands {
            let y0 = ay0 + band * bandH
            let y1 = (band == bands - 1) ? ay1 : y0 + bandH
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            var count = 0
            for y in y0..<y1 {
                let by = y - dy
                if by < 0 || by >= h { continue }
                for x in dx..<w {
                    let va = Double(a[y*w + x])
                    let vb = Double(b[by*w + (x - dx)])
                    sa += va; sb += vb; saa += va*va; sbb += vb*vb; sab += va*vb
                    count += 1
                }
            }
            guard count > 64 else { continue }
            let cnt = Double(count)
            let cov = sab - sa*sb/cnt
            let va = saa - sa*sa/cnt, vb = sbb - sb*sb/cnt
            guard va > 1e-9, vb > 1e-9 else { continue }
            // POOL the bands — accumulate covariance and its normaliser
            // separately — rather than averaging each band's coefficient.
            //
            // Averaging coefficients equally was a real bug: the top band
            // of an outdoor frame is plain sky with almost no variance, so
            // its correlation is meaningless noise, and giving it the same
            // vote as a detailed band dragged a true 0.96 down to 0.55.
            // The optimiser then chased that noise, and the vertical
            // stretch ran away to whatever bound it was given.
            //
            // Pooling weights each band by its own signal strength, so a
            // featureless band contributes nearly nothing without being
            // explicitly excluded. Per-band mean subtraction is retained —
            // that is what makes banding worth doing, since it stops a
            // brightness gradient across the frame from biasing the match.
            total += cov
            norm += (va*vb).squareRoot()
            used += 1
        }
        return used > 0 && norm > 1e-9 ? total / norm : -2
    }

    /// Quarter-scale copy by two box-halvings. Box rather than a proper
    /// filter because this feeds a correlation search, not the output: a
    /// little aliasing shifts the peak by well under the ±6 refine window,
    /// and the full-resolution pass is what decides the answer.
    private static func downsample4(_ src: [Float], w: Int, h: Int) -> (Int, Int, [Float]) {
        func half(_ a: [Float], _ aw: Int, _ ah: Int) -> (Int, Int, [Float]) {
            let nw = max(1, aw/2), nh = max(1, ah/2)
            var out = [Float](repeating: 0, count: nw*nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    let x0 = x*2, y0 = y*2
                    let x1 = min(x0+1, aw-1), y1 = min(y0+1, ah-1)
                    out[y*nw + x] = (a[y0*aw + x0] + a[y0*aw + x1]
                                   + a[y1*aw + x0] + a[y1*aw + x1]) * 0.25
                }
            }
            return (nw, nh, out)
        }
        let (w2, h2, d2) = half(src, w, h)
        return half(d2, w2, h2)
    }

    private static func verticalStretch(_ src: [Float], w: Int, h: Int, factor: Double) -> [Float] {
        var out = [Float](repeating: 0, count: w*h)
        let mid = Double(h) / 2
        for y in 0..<h {
            let sy = mid + (Double(y) - mid) / factor
            let y0 = Int(sy.rounded(.down)), fy = Float(sy - Double(y0))
            let ya = min(max(0, y0), h-1), yb = min(max(0, y0+1), h-1)
            for x in 0..<w {
                out[y*w + x] = src[ya*w + x]*(1-fy) + src[yb*w + x]*fy
            }
        }
        return out
    }

    private static func applyStretches(_ p: [Plane], order: [Int], fits: [PairFit]) -> [Plane] {
        // Stretches compound along the chain: if frame 2 is 1% taller than
        // frame 1, and 3 is 1% taller than 2, then 3 is ~2% taller than 1.
        var out = p
        var cumulative = 1.0
        for k in 1..<order.count {
            cumulative *= fits[k-1].vStretch
            guard abs(cumulative - 1.0) > 1e-4 else { continue }
            out[order[k]] = stretchPlane(p[order[k]], factor: 1.0 / cumulative)
        }
        return out
    }

    private static func stretchPlane(_ src: Plane, factor: Double) -> Plane {
        var out = Plane(w: src.w, h: src.h)
        let mid = Double(src.h) / 2
        for y in 0..<src.h {
            let sy = mid + (Double(y) - mid) / factor
            let y0 = Int(sy.rounded(.down)), fy = Float(sy - Double(y0))
            let ya = min(max(0, y0), src.h-1), yb = min(max(0, y0+1), src.h-1)
            for x in 0..<src.w {
                for c in 0..<3 {
                    out.set(x, y, c, src.at(x, ya, c)*(1-fy) + src.at(x, yb, c)*fy)
                }
            }
        }
        return out
    }

    // MARK: - Gain

    /// Per-channel exposure match, least squares in log space with mean
    /// gain pinned to 1. Per-channel because a low sun makes one frame
    /// differ in COLOUR as well as brightness, which a single scalar
    /// cannot express — measured as a 0.055 red/blue spread on the
    /// reference set, about half the visible seam.
    private static func gainCompensate(_ p: [Plane], order: [Int],
                                       positions: [(x: Int, y: Int)],
                                       closingDistance: Int?) -> [[Double]] {
        let n = p.count, w = p[0].w, h = p[0].h
        var gains = [[Double]](repeating: [1,1,1], count: n)
        for c in 0..<3 {
            var rows: [[Double]] = [], rhs: [Double] = []
            for k in 0..<(order.count - 1 + (closingDistance == nil ? 0 : 1)) {
                let next = (k + 1) % order.count
                let L = order[k], R = order[next]
                let dx = next == 0 ? closingDistance! : positions[next].x - positions[k].x
                let dy = next == 0 ? positions[0].y - positions[k].y : positions[next].y - positions[k].y
                var sl = 0.0, sr = 0.0; var cnt = 0
                let margin = min(20, h / 4)
                let top = max(margin, margin + dy), bottom = min(h - margin, h - margin + dy)
                guard bottom > top else { continue }
                for y in top..<bottom {
                    for x in dx..<w {
                        sl += Double(p[L].at(x, y, c))
                        sr += Double(p[R].at(x - dx, y - dy, c))
                        cnt += 1
                    }
                }
                guard cnt > 0, sl > 1e-6, sr > 1e-6 else { continue }
                var row = [Double](repeating: 0, count: n)
                row[L] = 1; row[R] = -1
                rows.append(row); rhs.append(-log((sl/Double(cnt)) / (sr/Double(cnt))))
            }
            var row = [Double](repeating: 1, count: n)
            rows.append(row); rhs.append(0)
            row = []
            if let sol = leastSquares(rows, rhs, unknowns: n) {
                for i in 0..<n { gains[i][c] = exp(sol[i]) }
            }
        }
        return gains
    }

    /// Normal-equations solve. The systems here are tiny (one unknown per
    /// frame), so the conditioning cost of A^T A is irrelevant.
    private static func leastSquares(_ A: [[Double]], _ b: [Double], unknowns: Int) -> [Double]? {
        var ata = [[Double]](repeating: [Double](repeating: 0, count: unknowns), count: unknowns)
        var atb = [Double](repeating: 0, count: unknowns)
        for (r, row) in A.enumerated() {
            for i in 0..<unknowns {
                guard row[i] != 0 else { continue }
                atb[i] += row[i] * b[r]
                for j in 0..<unknowns where row[j] != 0 { ata[i][j] += row[i]*row[j] }
            }
        }
        // Gaussian elimination with partial pivoting.
        for i in 0..<unknowns {
            var piv = i
            for r in i..<unknowns where abs(ata[r][i]) > abs(ata[piv][i]) { piv = r }
            guard abs(ata[piv][i]) > 1e-12 else { return nil }
            if piv != i { ata.swapAt(i, piv); atb.swapAt(i, piv) }
            let d = ata[i][i]
            for j in i..<unknowns { ata[i][j] /= d }
            atb[i] /= d
            for r in 0..<unknowns where r != i {
                let f = ata[r][i]
                guard f != 0 else { continue }
                for j in i..<unknowns { ata[r][j] -= f*ata[i][j] }
                atb[r] -= f*atb[i]
            }
        }
        return atb
    }

    // MARK: - Assembly

    private static func assemble(_ p: [Plane], order: [Int], positions: [(x: Int, y: Int)],
                                 gains: [[Double]], options: Options,
                                 circumference: Int?) -> (plane: Plane, cropped: Int)? {
        let w = p[0].w, h = p[0].h
        var X = [Int](repeating: 0, count: p.count)
        var Y = [Int](repeating: 0, count: p.count)
        for (k, i) in order.enumerated() { X[i] = positions[k].x; Y[i] = positions[k].y }
        let minX = X.min() ?? 0
        for i in 0..<p.count { X[i] -= minX }
        let minY = Y.min() ?? 0
        for i in 0..<p.count { Y[i] -= minY }
        guard (Y.max() ?? 0) < h else { return nil }
        let CW = (X.max() ?? 0) + w
        let CH = (Y.max() ?? 0) + h

        var acc = Plane(w: CW, h: CH)
        for (k, i) in order.enumerated() {
            guard !Task.isCancelled else { return nil }
            let x0 = X[i], y0 = Y[i]
            var cur = Plane(w: CW, h: CH)
            // Outside this frame, seed with what is already there so the
            // pyramid sees continuous data instead of a cliff into black.
            cur.px = acc.px
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 {
                        cur.set(x0 + x, y0 + y, c, Float(Double(p[i].at(x, y, c)) * gains[i][c]))
                    }
                }
            }
            if k == 0 { acc = cur; continue }

            // Seam finding: cut where the two frames disagree LEAST, then
            // take one source either side. Feathering averages views that
            // genuinely disagree — the pan head rotates about the tripod
            // screw, not the lens's nodal point — and that ghosts every
            // near object.
            let prev = order[k-1]
            let bandLo = x0, bandHi = min(CW, X[prev] + w)
            var cut = bandLo, bestCost = Double.greatestFiniteMagnitude
            if bandHi > bandLo {
                for xc in bandLo..<bandHi {
                    var cost = 0.0; var cnt = 0
                    let ys = max(y0, Y[prev]), ye = min(y0 + h, Y[prev] + h)
                    guard ye > ys else { continue }
                    for y in stride(from: ys, to: ye, by: 2) {
                        for c in 0..<3 {
                            let a = Double(p[i].at(xc - x0, y - y0, c)) * gains[i][c]
                            let b = Double(p[prev].at(xc - X[prev], y - Y[prev], c)) * gains[prev][c]
                            cost += abs(a - b); cnt += 1
                        }
                    }
                    if cnt > 0 {
                        let m = cost / Double(cnt)
                        if m < bestCost { bestCost = m; cut = xc }
                    }
                }
            }
            var mask = [Float](repeating: 0, count: CW*CH)
            for y in y0..<min(CH, y0+h) {
                for x in cut..<min(CW, x0+w) { mask[y*CW + x] = 1 }
            }
            acc = multibandBlend(acc, cur, mask: mask, w: CW, h: CH, levels: options.blendLevels)
        }

        // Crop to the fully covered band — the slope leaves a staircase.
        let top = Y.max() ?? 0
        let bot = (0..<p.count).map { Y[$0] + h }.min() ?? CH
        var outP = Plane(w: CW, h: max(1, bot - top))
        for y in 0..<outP.h {
            for x in 0..<CW {
                for c in 0..<3 { outP.set(x, y, c, acc.at(x, y + top, c)) }
            }
        }
        if let circumference, circumference < CW {
            outP = closeLoop(outP, circumference: circumference, levels: options.blendLevels)
        }
        return (outP, top + (CH - bot))
    }

    /// Blend the duplicate tail into the start, then keep exactly one turn.
    /// At x=0 we use the tail (continuous with the last output column);
    /// at the far edge of the overlap we use the original start.
    private static func closeLoop(_ strip: Plane, circumference: Int, levels: Int) -> Plane {
        let overlap = strip.w - circumference
        var head = Plane(w: overlap, h: strip.h), tail = head
        var mask = [Float](repeating: 0, count: overlap * strip.h)
        for y in 0..<strip.h {
            for x in 0..<overlap {
                let t = Float(x) / Float(max(1, overlap - 1))
                mask[y * overlap + x] = t * t * (3 - 2 * t)
                for c in 0..<3 {
                    head.set(x, y, c, strip.at(x, y, c))
                    tail.set(x, y, c, strip.at(circumference + x, y, c))
                }
            }
        }
        let blended = multibandBlend(tail, head, mask: mask, w: overlap, h: strip.h, levels: levels)
        var result = Plane(w: circumference, h: strip.h)
        for y in 0..<strip.h {
            for x in 0..<circumference {
                for c in 0..<3 {
                    result.set(x, y, c, x < overlap ? blended.at(x, y, c) : strip.at(x, y, c))
                }
            }
        }
        return result
    }

    // MARK: - Multi-band blend
    //
    // Low frequencies blended over a wide band, high frequencies over a
    // narrow one. A hard cut still shows because it butts a vignetted
    // frame EDGE against a bright frame CENTRE; feathering everything
    // instead re-introduces the parallax ghosting the seam finder just
    // removed. Apple's tool did the same thing — its blender is
    // MRBlend.c, despite the help text calling it a cross dissolve.

    private static func multibandBlend(_ A: Plane, _ B: Plane, mask: [Float],
                                       w: Int, h: Int, levels: Int) -> Plane {
        var la = laplacian(A, levels: levels)
        let lb = laplacian(B, levels: levels)
        var gm = [[Float]](); gm.reserveCapacity(levels+1)
        var m = mask; var mw = w, mh = h
        gm.append(m)
        for _ in 0..<levels {
            (m, mw, mh) = down1(m, w: mw, h: mh)
            gm.append(m)
        }
        for lv in 0...levels {
            let n = la[lv].w * la[lv].h
            for i in 0..<n {
                let k = gm[lv][i]
                for c in 0..<3 {
                    la[lv].px[i*3+c] = la[lv].px[i*3+c]*(1-k) + lb[lv].px[i*3+c]*k
                }
            }
        }
        return collapse(la)
    }

    private static func laplacian(_ p: Plane, levels: Int) -> [Plane] {
        var gauss = [p]
        for _ in 0..<levels { gauss.append(downPlane(gauss[gauss.count-1])) }
        var out: [Plane] = []
        for i in 0..<levels {
            let up = upPlane(gauss[i+1], w: gauss[i].w, h: gauss[i].h)
            var d = gauss[i]
            for j in 0..<d.px.count { d.px[j] -= up.px[j] }
            out.append(d)
        }
        out.append(gauss[levels])
        return out
    }

    private static func collapse(_ pyr: [Plane]) -> Plane {
        var cur = pyr[pyr.count-1]
        for i in stride(from: pyr.count-2, through: 0, by: -1) {
            let up = upPlane(cur, w: pyr[i].w, h: pyr[i].h)
            var s = pyr[i]
            for j in 0..<s.px.count { s.px[j] += up.px[j] }
            cur = s
        }
        return cur
    }

    private static let kern: [Float] = [1.0/16, 4.0/16, 6.0/16, 4.0/16, 1.0/16]

    static func blur1(_ src: [Float], w: Int, h: Int, comps: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<comps {
                    var s: Float = 0
                    for k in -2...2 {
                        let xx = min(max(0, x+k), w-1)
                        s += kern[k+2] * src[(y*w + xx)*comps + c]
                    }
                    tmp[(y*w + x)*comps + c] = s
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<comps {
                    var s: Float = 0
                    for k in -2...2 {
                        let yy = min(max(0, y+k), h-1)
                        s += kern[k+2] * tmp[(yy*w + x)*comps + c]
                    }
                    out[(y*w + x)*comps + c] = s
                }
            }
        }
        return out
    }

    private static func down1(_ src: [Float], w: Int, h: Int) -> ([Float], Int, Int) {
        let b = blur1(src, w: w, h: h, comps: 1)
        let nw = max(1, w/2), nh = max(1, h/2)
        var out = [Float](repeating: 0, count: nw*nh)
        for y in 0..<nh { for x in 0..<nw { out[y*nw + x] = b[(y*2)*w + x*2] } }
        return (out, nw, nh)
    }

    private static func downPlane(_ p: Plane) -> Plane {
        let b = blur1(p.px, w: p.w, h: p.h, comps: 3)
        var out = Plane(w: max(1, p.w/2), h: max(1, p.h/2))
        for y in 0..<out.h {
            for x in 0..<out.w {
                for c in 0..<3 { out.set(x, y, c, b[((y*2)*p.w + x*2)*3 + c]) }
            }
        }
        return out
    }

    private static func upPlane(_ p: Plane, w: Int, h: Int) -> Plane {
        var up = Plane(w: w, h: h)
        for y in 0..<h {
            for x in 0..<w {
                let sx = min(x/2, p.w-1), sy = min(y/2, p.h-1)
                for c in 0..<3 { up.set(x, y, c, p.at(sx, sy, c)) }
            }
        }
        up.px = blur1(up.px, w: w, h: h, comps: 3)
        return up
    }

    // MARK: - CoreGraphics bridge

    private static func plane(from cg: CGImage) throws -> Plane {
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw StitchError.renderFailed }
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w*4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw StitchError.renderFailed }
        var p = Plane(w: w, h: h)
        for i in 0..<(w*h) {
            for c in 0..<3 { p.px[i*3+c] = Float(rgba[i*4+c]) / 255 }
        }
        return p
    }

    private static func rotate90CW(_ src: Plane) -> Plane {
        var out = Plane(w: src.h, h: src.w)
        for y in 0..<src.h {
            for x in 0..<src.w {
                for c in 0..<3 { out.set(src.h - 1 - y, x, c, src.at(x, y, c)) }
            }
        }
        return out
    }

    private static func rotate90CCW(_ src: Plane) -> Plane {
        var out = Plane(w: src.h, h: src.w)
        for y in 0..<src.h {
            for x in 0..<src.w {
                for c in 0..<3 { out.set(y, src.w - 1 - x, c, src.at(x, y, c)) }
            }
        }
        return out
    }

    /// Mean brightness of a vertical third, for `skyIsOnTheRight`.
    private static func columnBandLuma(_ p: Plane, from x0: Int, to x1: Int) -> Double {
        var sum = 0.0, n = 0
        for x in stride(from: x0, to: x1, by: 2) {
            for y in stride(from: 0, to: p.h, by: 2) {
                let r = Double(p.at(x, y, 0))
                let g = Double(p.at(x, y, 1))
                let b = Double(p.at(x, y, 2))
                sum += 0.299 * r
                sum += 0.587 * g
                sum += 0.114 * b
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// Which way to turn a sideways frame, decided from the picture.
    ///
    /// Clockwise puts the frame's LEFT edge at the top; anticlockwise puts
    /// its RIGHT edge there. Overlap cannot choose between them — that is
    /// the 180° tie described below — but the scene can: outdoors the sky
    /// is the bright end, and the sky belongs up.
    ///
    /// Returns nil when the two ends are too close to call, and the
    /// clockwise convention stands.
    private static func skyIsOnTheRight(_ p: Plane) -> Bool? {
        let third = max(1, p.w / 3)
        let left  = columnBandLuma(p, from: 0, to: third)
        let right = columnBandLuma(p, from: p.w - third, to: p.w)
        // In 0...1 units; ~8/255. Below this the frame has no clear bright
        // end and guessing would be worse than the convention.
        guard abs(right - left) > 0.03 else { return nil }
        return right > left
    }

    /// Which way up the frames are, MEASURED rather than assumed.
    ///
    /// QuickPan frames arrive on their side because the camera is held
    /// vertically, and Apple's templates all pass `-rotate -90` for that
    /// reason. A pan shot with the camera held level arrives upright. Both
    /// land on disk as 640x480, so the aspect ratio cannot tell them
    /// apart — and the `w > h` test this replaces turned EVERY pan on its
    /// side, which was right for the QuickPan set it was written against
    /// and wrong for an ordinary one.
    ///
    /// A pan only correlates along the axis it was swept, and `matchPair`
    /// searches horizontally, so the correct orientation is the one that
    /// finds an overlap at all. The first pair is enough to tell, and both
    /// pair directions are tried because whether the sweep runs left to
    /// right is not decided until the next step.
    ///
    /// ONLY these two candidates, and clockwise is a fixed convention
    /// rather than a measurement. Turning the other way is equally good
    /// evidence — anticlockwise differs from clockwise by 180°, and
    /// rotating every frame 180° preserves neighbour overlap exactly, so
    /// the correlations tie and the winner is decided by floating-point
    /// noise. Offering it as a third candidate cost nothing to write and
    /// silently flipped the reference panorama upside down, reversing the
    /// reported sweep direction with it. The 90° question here IS
    /// decidable, because a 90° error destroys the overlap; the 180° one
    /// is not decidable from overlap at all, and a camera held vertically
    /// the other way needs an orientation tag to resolve, not a guess.
    private static func upright(_ planes: [Plane], options: Options) -> [Plane] {
        guard planes.count >= 2 else { return planes }

        // A fit whose step sits on the rim of the search window is not a
        // measurement — `match` already refuses one, for the same reason
        // `stepIsPegged` exists. It has to count here too, because this is
        // where the WRONG orientation wins by producing exactly that.
        //
        // Two frames of a pan, held the wrong way up, are nearly the same
        // picture barely shifted: the matcher pegs at the minimum step and
        // reports a healthy correlation for having found almost no motion
        // at all. Scored on correlation alone that beats the correct
        // orientation, the frames are never turned, and a real pan is
        // rejected further down for the very peg that won the vote.
        //
        // Seen on a two-frame QuickTake 150 pan: unrotated fit pegged at
        // step 64 of 640 with correlation 0.56, so the frames stayed on
        // their side and the pan — 27% overlap along the other axis — was
        // never looked for.
        func score(_ a: Plane, _ b: Plane) -> Double {
            func usable(_ fit: PairFit) -> Double {
                stepIsPegged(fit.dx, frameWidth: a.w, options: options)
                    ? -2                      // the "no fit" sentinel
                    : fit.correlation
            }
            return max(usable(matchPair(a, b, options: options)),
                       usable(matchPair(b, a, options: options)))
        }

        let asIs = score(planes[0], planes[1])
        let turned = score(rotate90CW(planes[0]), rotate90CW(planes[1]))
        guard turned > asIs else { return planes }

        // The frames ARE sideways. Which way to turn them is the 180°
        // question above — undecidable from overlap, because rotating
        // every frame 180° preserves neighbour overlap exactly. It is not
        // undecidable from the PICTURE, though: outdoors the sky is the
        // bright end of a sideways frame, and the sky goes up. Clockwise
        // lifts the left edge, anticlockwise the right.
        //
        // Only reached when a rotation is actually happening, so a level
        // pan is untouched and the demo scenes are unaffected. When the
        // two ends are too close to call, the clockwise convention stands.
        if skyIsOnTheRight(planes[0]) == true {
            return planes.map(rotate90CCW)
        }
        return planes.map(rotate90CW)
    }

    private static func cgImage(from p: Plane) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: p.w*p.h*4)
        for i in 0..<(p.w*p.h) {
            for c in 0..<3 {
                rgba[i*4+c] = UInt8(max(0, min(255, p.px[i*3+c] * 255)))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: p.w, height: p.h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: p.w*4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
