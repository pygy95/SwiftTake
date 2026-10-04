import Foundation

/// Opt-in geometry for a tripod head used at every declared detent — the
/// original 16-stop QuickPan disc, the wider 12/14/18/20-stop KiWi+ rings, or
/// any other consecutive-detent rig in between. Textured joins calibrate the
/// lens and direction; only unsupported joins use the rig estimate.
/// Image-only matching never enters this path.
nonisolated extension PanoramaStitcher {
    private struct QuickPanSeed {
        let order: [Int]
        let ratio: Double
        let evidence: [FeatureEvidence]
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func matchQuickPan(_ original: [Plane], options: Options) throws -> Session {
        let count = original.count
        let stops = options.quickPanStops
        // An unsupported stop count is rejected before any pixel work, not
        // silently clamped into a plausible-looking wrong geometry.
        guard PanoramaStitcher.quickPanStopsRange.contains(stops) else { throw StitchError.quickPanMismatch }
        // Enough independent joins to estimate a common geometry; at most one
        // rotation, without a duplicate starting frame. More consecutive
        // shots than positions on the declared ring means at least one
        // detent was repeated, so the count can never exceed `stops`.
        guard (6...stops).contains(count) else { throw StitchError.quickPanMismatch }
        let forward = Array(original.indices)
        let orders: [[Int]]
        if let fixed = options.fixedOrder {
            guard fixed.count == count, Set(fixed) == Set(forward) else {
                throw StitchError.quickPanMismatch
            }
            orders = [fixed]
        } else { orders = [forward, Array(forward.reversed())] }
        let required = max(4, count / 2)
        var seed: QuickPanSeed?
        for ratio in [0.8, 1.25, 2.0] {
            let frames = try original.map { try featureFrame(cylindricalProjection($0, focalRatio: ratio)) }
            for order in orders {
                var evidence: [FeatureEvidence] = []
                for i in 0..<count-1 {
                    try Task.checkCancellation()
                    if let pair = try featurePair(frames[order[i]], frames[order[i+1]], options: options) {
                        evidence.append(pair)
                    }
                }
                guard evidence.count >= required else { continue }
                let dx = median(evidence.map { Double($0.fit.dx) })
                let dy = median(evidence.map { Double($0.fit.dy) })
                // Conflicting strong matches indicate uneven/skipped detents;
                // do not discard them merely to make a regular sequence fit.
                guard evidence.allSatisfy({ abs(Double($0.fit.dx)-dx) <= max(5, dx*0.04)
                    && abs(Double($0.fit.dy)-dy) <= 3 }) else { continue }
                if let previous = seed,
                   previous.evidence.map(\.residual).reduce(0,+) / Double(previous.evidence.count)
                    <= evidence.map(\.residual).reduce(0,+) / Double(evidence.count) { continue }
                seed = QuickPanSeed(order: order, ratio: ratio, evidence: evidence)
            }
        }
        guard let seed else { throw StitchError.quickPanMismatch }
        let roll = median(seed.evidence.map { atan2(Double($0.fit.dy), Double($0.fit.dx)) })
        guard abs(roll) <= 3 * .pi/180 else { throw StitchError.quickPanMismatch }
        let appliedRoll = abs(roll) >= 0.15 * .pi/180 ? roll : 0
        let upright = appliedRoll == 0 ? original : try original.map { try correctingRoll($0, angle: appliedRoll) }
        let width = upright[0].w
        let degreesPerStop = 360.0 / Double(stops)
        let theta = degreesPerStop * Double.pi / 180
        var ratio = seed.ratio
        var planes: [Plane] = []
        var frames: [FeatureFrame] = []
        var measured: [Int: FeatureEvidence] = [:]
        var step = 0, drift = 0
        // Calibrate a shared cylindrical field of view from measured spacing
        // and the user's declared angle. No hard-coded standard/WideTake lens.
        for iteration in 0..<3 {
            try Task.checkCancellation()
            planes = try upright.map { try cylindricalProjection($0, focalRatio: ratio) }
            frames = try planes.map { try featureFrame($0) }
            measured.removeAll()
            for i in 0..<count-1 {
                if let pair = try featurePair(frames[seed.order[i]], frames[seed.order[i+1]], options: options) {
                    measured[i] = pair
                }
            }
            guard measured.count >= required else { throw StitchError.quickPanMismatch }
            step = Int(median(measured.values.map { Double($0.fit.dx) }).rounded())
            drift = Int(median(measured.values.map { Double($0.fit.dy) }).rounded())
            guard !stepIsPegged(step, frameWidth: width, options: options), abs(drift) <= 3,
                  measured.values.allSatisfy({ abs($0.fit.dx-step) <= max(5, Int(Double(step)*0.04))
                    && abs($0.fit.dy-drift) <= 3 }) else { throw StitchError.quickPanMismatch }
            if iteration < 2 {
                let halfFOV = theta * Double(width-1) / (2 * Double(step))
                ratio = Double(width-1) / (2 * Double(width) * tan(halfFOV))
                guard ratio.isFinite, (0.5...3).contains(ratio) else { throw StitchError.quickPanMismatch }
            }
        }
        // Evidence must span the capture, not just one textured cluster.
        guard let first = measured.keys.min(), let last = measured.keys.max(),
              first <= (count-1)/3, last >= (count-1)*2/3 else { throw StitchError.quickPanMismatch }
        var fits: [PairFit] = [], estimated: [Int] = []
        for i in 0..<count-1 {
            try Task.checkCancellation()
            if let pair = measured[i] {
                fits.append(pair.fit)
                continue
            }
            let a = seed.order[i], b = seed.order[i+1]
            // Where both overlaps have texture, require a consistent direct
            // correlation too. Assistance must not hide unrelated/misordered
            // photos. Sparse wall overlaps cannot provide this evidence.
            if min(frames[a].overlapCornerCount(step: step, rightEdge: true),
                   frames[b].overlapCornerCount(step: step, rightEdge: false)) >= 8 {
                let fit = matchPair(planes[a], planes[b], options: options)
                guard fit.correlation >= options.minimumCorrelation,
                      abs(fit.dx-step) <= max(5, Int(Double(step)*0.04)),
                      abs(fit.dy-drift) <= 3 else { throw StitchError.quickPanMismatch }
            }
            // Zero denotes an estimate, never invented image confidence.
            fits.append(PairFit(dx: step, dy: drift, vStretch: 1, correlation: 0))
            estimated.append(i)
        }
        let closing = try featurePair(frames[seed.order.last!], frames[seed.order[0]], options: options)?.fit
        // A full turn requires the frame count to match the DECLARED
        // full-revolution count for this spacing, never inferred from count
        // alone — the closing join must still carry independent evidence.
        let full: Bool
        if count == stops, let closing {
            full = abs(closing.dx-step) <= max(5, Int(Double(step)*0.04))
                && abs(closing.dy-drift) <= 3
                && abs(fits.map(\.dy).reduce(0,+) + closing.dy) <= max(4,count)
        } else { full = false }
        let hfov = degreesPerStop * Double(width) / Double(step)
        return Session(planes: planes, options: options, order: seed.order, step: step,
                       fittedSlope: drift, fits: fits, overlap: Double(width-step)/Double(width),
                       impliedHFOV: hfov, isFullRotation: full,
                       sweepDegrees: full ? 360 : min(359, Double(count-1)*degreesPerStop+hfov),
                       closingFit: full ? closing : nil, cylindricalFocalRatio: ratio,
                       usesFeatureAlignment: true, rollCorrectionDegrees: appliedRoll*180 / .pi,
                       estimatedJoins: estimated, usesQuickPanAssistance: true,
                       quickPanStops: stops)
    }
}
