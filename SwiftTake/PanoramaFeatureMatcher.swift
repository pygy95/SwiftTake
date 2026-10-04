// A bounded recovery path for cylindrical sweeps whose exposure changes or
// moving subjects defeat whole-overlap correlation. Independent textured patches
// must agree on a displacement; no capture count or declared sweep supplies it.
import Foundation

nonisolated extension PanoramaStitcher {
    struct FeatureRecovery {
        let planes: [Plane]
        let order: [Int]
        let fits: [PairFit]
        let closing: PairFit?
        let focalRatio: Double
        let roll: Double
        let residual: Double
    }

    struct FeatureEvidence {
        let fit: PairFit
        let residual: Double
        let support: Int
    }

    fileprivate struct Corner {
        let x: Int, y: Int
        let descriptor: [Float]
    }

    struct FeatureFrame {
        fileprivate let w: Int, h: Int
        fileprivate let scaleX: Double, scaleY: Double
        fileprivate let luma: [Float]
        fileprivate let corners: [Corner]

        func overlapCornerCount(step: Int, rightEdge: Bool) -> Int {
            let dx = Int(Double(step) / scaleX)
            return corners.filter { rightEdge ? $0.x >= dx : $0.x < w-dx }.count
        }
    }

    private struct Correspondence {
        let y: Int, dx: Int, dy: Int, right: Int
        let correlation: Float
    }

    /// Analyze at camera resolution or smaller. Render planes retain their full
    /// resolution; only measured offsets are scaled back from the analysis grid.
    static func featureFrame(_ plane: Plane) throws -> FeatureFrame {
        try Task.checkCancellation()
        let scale = min(1, 640.0 / Double(max(plane.w, plane.h)))
        let w = max(1, Int((Double(plane.w) * scale).rounded()))
        let h = max(1, Int((Double(plane.h) * scale).rounded()))
        let sx = Double(plane.w) / Double(w), sy = Double(plane.h) / Double(h)
        let original = plane.luma()
        var luma = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                let fx = min(Double(plane.w - 1), (Double(x) + 0.5) * sx - 0.5)
                let fy = min(Double(plane.h - 1), (Double(y) + 0.5) * sy - 0.5)
                let x0 = Int(fx), y0 = Int(fy)
                let x1 = min(x0 + 1, plane.w - 1), y1 = min(y0 + 1, plane.h - 1)
                let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
                let top = original[y0 * plane.w + x0] * (1-dx) + original[y0 * plane.w + x1] * dx
                let bottom = original[y1 * plane.w + x0] * (1-dx) + original[y1 * plane.w + x1] * dx
                luma[y*w+x] = top * (1-dy) + bottom * dy
            }
        }
        luma = blur1(luma, w: w, h: h, comps: 1)
        return FeatureFrame(w: w, h: h, scaleX: sx, scaleY: sy, luma: luma,
                            corners: try featureCorners(luma, w: w, h: h))
    }

    private static func patch(_ a: [Float], w: Int, x: Int, y: Int) -> [Float] {
        var values = [Float](); values.reserveCapacity(169)
        for yy in stride(from: y-12, through: y+12, by: 2) {
            for xx in stride(from: x-12, through: x+12, by: 2) { values.append(a[yy*w+xx]) }
        }
        let mean = values.reduce(0,+) / Float(values.count)
        var energy: Float = 0
        for i in values.indices { values[i] -= mean; energy += values[i]*values[i] }
        if energy > 1e-9 {
            let inverse = 1 / sqrt(energy)
            for i in values.indices { values[i] *= inverse }
        }
        return values
    }

    private static func featureCorners(_ a: [Float], w: Int, h: Int) throws -> [Corner] {
        guard w > 28, h > 28 else { return [] }
        var gx = [Float](repeating: 0, count: w*h), gy = gx
        for y in 1..<h-1 { for x in 1..<w-1 {
            gx[y*w+x] = (a[y*w+x+1]-a[y*w+x-1])*0.5
            gy[y*w+x] = (a[(y+1)*w+x]-a[(y-1)*w+x])*0.5
        } }
        var candidates: [(x: Int, y: Int, strength: Float)] = []
        for y in stride(from: 14, to: h-14, by: 2) {
            try Task.checkCancellation()
            for x in stride(from: 14, to: w-14, by: 2) {
                var xx: Float = 0, yy: Float = 0, xy: Float = 0
                for dy in -2...2 { for dx in -2...2 {
                    let i = (y+dy)*w+x+dx
                    xx += gx[i]*gx[i]; yy += gy[i]*gy[i]; xy += gx[i]*gy[i]
                } }
                let score = (xx+yy-sqrt((xx-yy)*(xx-yy)+4*xy*xy))*0.5
                if score > 0.0001 { candidates.append((x,y,score)) }
            }
        }
        candidates.sort { $0.strength > $1.strength }
        let threshold = (candidates.first?.strength ?? 0) * 0.005
        var output: [Corner] = []
        for candidate in candidates where candidate.strength >= threshold {
            if output.contains(where: { abs($0.x-candidate.x)<12 && abs($0.y-candidate.y)<12 }) { continue }
            output.append(Corner(x: candidate.x, y: candidate.y,
                                 descriptor: patch(a, w: w, x: candidate.x, y: candidate.y)))
            if output.count == 300 { break }
        }
        return output
    }

    private static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in a.indices { sum += a[i]*b[i] }
        return sum
    }

    static func featurePair(_ left: FeatureFrame, _ right: FeatureFrame,
                            options: Options) throws -> FeatureEvidence? {
        guard left.w == right.w, left.h == right.h else { return nil }
        let w = left.w, h = left.h
        let lo = max(8, Int(Double(w)*options.minStepFraction))
        let hi = min(w-8, Int(Double(w)*options.maxStepFraction))
        let drift = Int(Double(options.maxVerticalDrift) / left.scaleY)
        guard lo < hi, drift > 0 else { return nil }
        var matches: [Correspondence] = []
        for l in left.corners {
            try Task.checkCancellation()
            var best: Float = -2, second: Float = -2
            var bestIndex: Int?
            for (j,r) in right.corners.enumerated()
                where (lo...hi).contains(l.x-r.x) && abs(l.y-r.y) <= drift {
                let score = similarity(l.descriptor, r.descriptor)
                if score > best { second = best; best = score; bestIndex = j }
                else if score > second { second = score }
            }
            // Reject descriptors which match repeated scenery equally well.
            guard let j = bestIndex, best > 0.78, best-second > 0.04 else { continue }
            let r = right.corners[j]
            var rx = r.x, ry = r.y
            for yy in max(13,r.y-3)...min(h-14,r.y+3) {
                for xx in max(13,r.x-3)...min(w-14,r.x+3) {
                    let score = similarity(l.descriptor, patch(right.luma, w: w, x: xx, y: yy))
                    if score > best { best = score; rx = xx; ry = yy }
                }
            }
            guard (lo...hi).contains(l.x-rx), abs(l.y-ry) <= drift else { continue }
            let candidate = Correspondence(y: l.y, dx: l.x-rx, dy: l.y-ry, right: j, correlation: best)
            if let existing = matches.firstIndex(where: { $0.right == j }) {
                if best > matches[existing].correlation { matches[existing] = candidate }
            } else { matches.append(candidate) }
        }
        var consensus: [Correspondence] = []
        for seed in matches {
            let group = matches.filter { abs($0.dx-seed.dx)<=5 && abs($0.dy-seed.dy)<=5 }
            if group.count > consensus.count { consensus = group }
        }
        guard consensus.count >= 8, consensus.count * 4 >= matches.count else { return nil }
        let dx = consensus.map(\.dx).sorted()[consensus.count/2]
        let dy = consensus.map(\.dy).sorted()[consensus.count/2]
        let alternatives = matches.filter { abs($0.dx-dx)>10 || abs($0.dy-dy)>10 }
        let runnerUp = alternatives.map { seed in
            alternatives.filter { abs($0.dx-seed.dx)<=5 && abs($0.dy-seed.dy)<=5 }.count
        }.max() ?? 0
        let span = (consensus.map(\.y).max() ?? 0) - (consensus.map(\.y).min() ?? 0)
        guard consensus.count >= 2 * runnerUp, span >= h/8,
              dx > lo+1, dx < hi-1, abs(dy) < drift else { return nil }
        let correlation = Double(consensus.map(\.correlation).reduce(0,+)) / Double(consensus.count)
        guard correlation.isFinite, correlation >= max(0.85, options.minimumCorrelation) else { return nil }
        let residual = consensus.reduce(0.0) { $0 + hypot(Double($1.dx-dx), Double($1.dy-dy)) }
            / Double(consensus.count)
        // Correlation here describes the agreeing local patches, not the whole
        // overlap. Support, uniqueness, spatial extent and geometry also gate it.
        return FeatureEvidence(fit: PairFit(dx: Int((Double(dx)*left.scaleX).rounded()),
                                           dy: Int((Double(dy)*left.scaleY).rounded()),
                                           vStretch: 1, correlation: correlation),
                               residual: residual, support: consensus.count)
    }

    static func recoverFeatures(_ original: [Plane], options: Options) throws -> FeatureRecovery? {
        let forward = Array(original.indices)
        let orders: [[Int]]
        if let fixed = options.fixedOrder, fixed.count == original.count, Set(fixed) == Set(forward) {
            orders = [fixed]
        } else { orders = [forward, forward.reversed()] }

        // Estimate a small common roll from independent pair translations. A
        // single good pair cannot justify resampling the whole capture sequence.
        let initial = try original.map { try featureFrame(cylindricalProjection($0, focalRatio: 1.25)) }
        var roll = 0.0, support = 0
        for order in orders {
            var angles: [Double] = []
            for i in 0..<order.count-1 {
                if let evidence = try featurePair(initial[order[i]], initial[order[i+1]], options: options) {
                    angles.append(atan2(Double(evidence.fit.dy), Double(evidence.fit.dx)))
                }
            }
            if angles.count > support, angles.count >= max(3, (order.count-1)*2/3) {
                let median = angles.sorted()[angles.count/2]
                // A varying vertical path is not evidence of a shared camera roll.
                let agreeing = angles.filter { abs($0-median) < .pi/180 }.count
                if agreeing * 4 >= angles.count * 3, abs(median) <= 3 * .pi/180 {
                    roll = median; support = angles.count
                }
            }
        }
        let rotations = abs(roll) >= 0.15 * .pi/180 ? [0, roll] : [0]
        var best: FeatureRecovery?
        for angle in rotations {
            let upright = angle == 0 ? original : try original.map { try correctingRoll($0, angle: angle) }
            for ratio in [0.8, 1.0, 1.25, 2.0] {
                try Task.checkCancellation()
                let planes = try upright.map { try cylindricalProjection($0, focalRatio: ratio) }
                let frames = try planes.map { try featureFrame($0) }
                for order in orders {
                    var evidence: [FeatureEvidence] = []
                    for i in 0..<order.count-1 {
                        guard let pair = try featurePair(frames[order[i]], frames[order[i+1]], options: options) else { break }
                        evidence.append(pair)
                    }
                    guard evidence.count == order.count-1 else { continue }
                    let closing = try featurePair(frames[order.last!], frames[order[0]], options: options)
                    let residual = evidence.map(\.residual).reduce(0,+) / Double(evidence.count)
                    // Pick the projection with the most consistent local geometry;
                    // a high patch score alone cannot distinguish focal lengths.
                    if let previous = best, previous.residual <= residual { continue }
                    best = FeatureRecovery(planes: planes, order: order, fits: evidence.map(\.fit),
                                           closing: closing?.fit, focalRatio: ratio,
                                           roll: angle, residual: residual)
                }
            }
        }
        return best
    }

    /// Inverse rotation, cropped to an inscribed rectangle. Every output pixel
    /// comes from the photo; padded corners must never count as scene evidence.
    static func correctingRoll(_ p: Plane, angle: Double) throws -> Plane {
        let c = cos(angle), s = sin(angle)
        let width = Int((Double(p.w)-Double(p.h)*abs(s))/c)-2
        let height = Int((Double(p.h)-Double(p.w)*abs(s))/c)-2
        guard width > 28, height > 28 else { throw StitchError.noConfidentMatch }
        var output = Plane(w: width, h: height)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let xx = Double(x)-Double(width-1)/2, yy = Double(y)-Double(height-1)/2
                let sx = c*xx-s*yy+Double(p.w-1)/2, sy = s*xx+c*yy+Double(p.h-1)/2
                let x0 = max(0,min(p.w-2,Int(sx))), y0 = max(0,min(p.h-2,Int(sy)))
                let fx = Float(sx-Double(x0)), fy = Float(sy-Double(y0))
                for channel in 0..<3 {
                    let top = p.at(x0,y0,channel)*(1-fx)+p.at(x0+1,y0,channel)*fx
                    let bottom = p.at(x0,y0+1,channel)*(1-fx)+p.at(x0+1,y0+1,channel)*fx
                    output.set(x,y,channel,top*(1-fy)+bottom*fy)
                }
            }
        }
        return output
    }
}
