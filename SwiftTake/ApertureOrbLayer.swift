//
//  ApertureOrbLayer.swift
//  SwiftTake
//
//  The grabbed aperture orb: the ball itself and the comet tail it drags
//  behind it, rendered at window level so neither is clipped by the sidebar.
//
//  Extracted as view structs with declared inputs. The drag state they read
//  still lives in ContentView `@State`, so today a drag frame re-evaluates
//  ContentView's body either way — but the layers are now the only things
//  that read it, which is what makes moving that state into an @Observable
//  box (the roadmap's secondary item) a small diff in one file rather than a
//  change to the window's whole body.
//
//  Nothing here is a "nice to have": every no-blur / no-shadow note below
//  records a specific visible lag that was chased down and fixed.
//

import SwiftUI

/// Window-level layer that renders the grabbed aperture orb (above the
/// sidebar so it isn't clipped), positioned at the cursor.
struct ApertureOrbLayer: View {
    /// The orb's centre in global coordinates — tracks the cursor.
    let orbGlobal: CGPoint
    /// The sidebar mark's frame: where the orb flies home to.
    let homeRect: CGRect
    /// 0 = still the aperture mark, 1 = fully the orb.
    let morph: CGFloat
    /// Jelly squash/stretch and the axis it acts along.
    let stretch: CGFloat
    let stretchAngle: Angle
    let trailFade: Double
    /// The recorded flight path, newest last.
    let trail: [CGPoint]
    /// 0 while dragging, 1 once the tail has been pulled all the way home.
    let returnProgress: Double
    /// A develop swaps the BALL out (the bubble replaces it at the release
    /// point) but leaves the tail mounted so it can fade out gracefully.
    let coplandActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: no jelly squash/stretch and no comet tail — the
        // orb still follows the drag (that's direct manipulation, not an
        // ambient animation) but stops wobbling and trailing after itself.
        let stretch = reduceMotion ? 0 : self.stretch

        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let gold = Color(red: 0.98, green: 0.80, blue: 0.32)
            let orbSize: CGFloat = 90
            // Starts at the sidebar mark's size (34 pt of the 90 pt ball)
            // so the orb begins life as a clone of the mark it replaces.
            let orbScale = 0.38 + 0.62 * morph
            let orbP = CGPoint(x: orbGlobal.x - origin.x,
                               y: orbGlobal.y - origin.y)
            let homeP = CGPoint(x: homeRect.midX - origin.x,
                                y: homeRect.midY - origin.y)
            // Curved comet tail: soft gold blobs along the recorded path,
            // DENSIFIED (sub-points interpolated across gaps) so it stays a
            // continuous smooth streak even on a fast fling / 240Hz display.
            // Tapers wide near the orb to a small point at the tip; each blob
            // carries its own gradient softness (NO group blur — see below),
            // masked out of the orb's circle, and lerped toward home on
            // release (follows back).
            // Reduce Motion: no comet tail — the orb still appears and still
            // follows the drag, it just doesn't leave a trail behind it.
            let dense = reduceMotion ? [] : densifiedTrailPoints(origin: origin, home: homeP)
            ZStack {
                ForEach(Array(dense.enumerated()), id: \.offset) { _, item in
                    Circle()
                        // Softness is baked INTO each blob as a gradient instead
                        // of blurring the group: a `.blur` whose content changes
                        // every frame re-rasterises a beat late, so the whole
                        // glowing streak (and the hole cut out of it) visibly
                        // trailed the ball on a fast fling. Gradient blobs are
                        // static content moved by transforms — they render in
                        // the SAME frame as the ball and cannot lag it.
                        .fill(RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: gold, location: 0.0),
                                .init(color: gold.opacity(0.9), location: 0.30),
                                .init(color: gold.opacity(0.0), location: 1.0)
                            ]),
                            center: .center, startRadius: 0,
                            endRadius: orbSize * 0.33))
                        .frame(width: orbSize * 0.66, height: orbSize * 0.66)
                        // 1.5× scale — the gradient's outward fade supplies the
                        // spread a 22 pt blur would otherwise add.
                        .scaleEffect((0.12 + 0.9 * item.f) * orbScale * 1.5)   // tiny tip → wide near orb
                        // HEADLESS: opacity peaks mid-trail and falls to 0 at the
                        // orb (f→1); the glow that hugs the orb is the halo inside
                        // `ApertureOrb`, so the tail never overlaps the ball. The
                        // extra min(...) term kills the head HARD over the last
                        // quarter — the widest blobs sit right behind the ball and
                        // read as a solid gold lump at fling speed without it.
                        .opacity(item.f * (1 - item.f) * 1.7
                                 * min(1, (1 - item.f) * 4.5)
                                 * morph * trailFade)
                        .position(item.point)
                }
            }
            .compositingGroup()
            .mask(
                // Cut the gold out of the orb's OWN circular footprint with a hard
                // edge: inside the orb the glass reads through to the real backdrop
                // (never the gold), while everything OUTSIDE — halo + comet tail —
                // stays exactly as-is. The crisp inner boundary is hidden under the
                // orb's rim, so the outside bloom is untouched.
                Rectangle()
                    .overlay(
                        Circle()
                            .frame(width: orbSize * orbScale, height: orbSize * orbScale)
                            // The ball jelly-stretches along its travel axis at
                            // speed — the cut-out must stretch the SAME way, or
                            // tail gold peeks through the clear glass at the
                            // ball's stretched edges (the "solid gold under the
                            // orb" on a fast fling). Same transform + same
                            // animated state as the ball, so they stay congruent
                            // through every spring frame.
                            .scaleEffect(x: 1 + stretch,
                                         y: 1 - stretch * 0.55)
                            .rotationEffect(stretchAngle)
                            .position(orbP)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
            )

            if !coplandActive {
                ApertureOrb(morph: morph, stretch: stretch, stretchAngle: stretchAngle)
                    .position(orbP)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // decorative dragged-orb animation
    }

    /// The recorded flight path, in local coordinates, with sub-points filled
    /// in across long gaps and each point's position along the tail (0 = tip,
    /// 1 = at the orb). On release every point is lerped toward home, so the
    /// tail follows the ball back rather than hanging in mid-air.
    private func densifiedTrailPoints(origin: CGPoint, home: CGPoint) -> [(point: CGPoint, f: CGFloat)] {
        let pts = trail
        let count = pts.count
        guard count > 0 else { return [] }
        func local(_ gp: CGPoint) -> CGPoint {
            let lp = CGPoint(x: gp.x - origin.x, y: gp.y - origin.y)
            return CGPoint(x: lp.x + (home.x - lp.x) * returnProgress,
                           y: lp.y + (home.y - lp.y) * returnProgress)
        }
        var out: [(CGPoint, CGFloat)] = []
        for i in 0..<count {
            let f0 = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 1
            let p0 = local(pts[i])
            out.append((p0, f0))
            if i + 1 < count {
                let f1 = CGFloat(i + 1) / CGFloat(count - 1)
                let p1 = local(pts[i + 1])
                let dist = hypot(p1.x - p0.x, p1.y - p0.y)
                let steps = min(14, Int(dist / 10))   // fill long gaps at high speed
                if steps > 1 {
                    for s in 1..<steps {
                        let t = CGFloat(s) / CGFloat(steps)
                        out.append((CGPoint(x: p0.x + (p1.x - p0.x) * t,
                                            y: p0.y + (p1.y - p0.y) * t),
                                    f0 + (f1 - f0) * t))
                    }
                }
            }
        }
        return out
    }
}

/// The reward orb: a clear Liquid Glass ball with a gold halo hugging its
/// rim and the 90s Apple stripes swirling inside its edge. Morphs out of
/// the aperture mark and jelly-squashes while dragged; the trailing comet
/// tail lives separately in `ApertureOrbLayer`.
struct ApertureOrb: View {
    let morph: CGFloat
    let stretch: CGFloat
    let stretchAngle: Angle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size: CGFloat = 90
        let radius = size / 2
        let m = stretch
        // 90s Apple stripes (loop-closed so the spin has no seam).
        let swirl = [
            Color(red: 0.38, green: 0.73, blue: 0.28),
            Color(red: 0.96, green: 0.76, blue: 0.17),
            Color(red: 0.94, green: 0.52, blue: 0.16),
            Color(red: 0.88, green: 0.21, blue: 0.26),
            Color(red: 0.58, green: 0.24, blue: 0.59),
            Color(red: 0.00, green: 0.58, blue: 0.84),
            Color(red: 0.38, green: 0.73, blue: 0.28)
        ]
        // Colour strongest at the rim but now bleeding inward toward the middle
        // (not just a thin edge), so the 90s stripes read more clearly.
        let edgeMask = RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .black.opacity(0.0), location: 0.0),
                .init(color: .black.opacity(0.20), location: 0.40),
                .init(color: .black.opacity(0.62), location: 0.78),
                .init(color: .black.opacity(1.0), location: 0.95),
                .init(color: .black.opacity(1.0), location: 1.0)
            ]),
            center: .center, startRadius: 0, endRadius: radius)

        // Reduce Motion: the swirl still shows, frozen instead of spinning.
        return TimelineView(reduceMotion ? .animation(paused: true)
                                          : .animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 26   // slow spin

            // Gold halo + glass + spinning colour ring, ALL jellied together so the
            // glow matches the orb's form at every point. The OUTER fade trailing
            // behind it (the comet tail, with inertia) lives in `ApertureOrbLayer`.
            let gold = Color(red: 0.98, green: 0.80, blue: 0.32)
            ZStack {
                ZStack {
                    // ORB CHROME (halo + glass + colour ring) blooms IN with
                    // the morph while the aperture glyph below dissolves —
                    // ONE element visibly transforming, not two crossfading.
                    Group {
                    // Gold glow that HUGS the orb — a RadialGradient with a CLEAR
                    // centre (gold only from the rim outward), so no gold shows
                    // through the glass. Critically it uses gradient stops, NOT a
                    // `.blur` (a blurred layer rasterises a frame late and lags the
                    // orb at speed → the "lagging outline"). Living inside the orb's
                    // jellied stack, it tracks + squashes with the orb EXACTLY, at
                    // every point. The trailing comet tail (with inertia/lag, which
                    // is fine there) lives separately in `ApertureOrbLayer`.
                    // Soft gold glow: gold SOLID out to the rim, then fading only
                    // OUTWARD — a real glow (bright at the edge, feathering out), NOT
                    // a clear→bright→clear annulus (which always reads as a ring no
                    // matter the opacity). The orb's interior is then masked away so
                    // no gold shows through the clear glass. Glow + mask both live in
                    // this jellied stack with NO `.blur`, so they share the orb's
                    // exact transform → it hugs the shape dynamically with zero lag.
                    Circle()
                        .fill(RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: gold.opacity(0.34), location: 0.0),
                                .init(color: gold.opacity(0.34), location: 0.585),  // solid out to the rim
                                .init(color: gold.opacity(0.0), location: 0.86)      // soft outward fade
                            ]),
                            center: .center, startRadius: 0, endRadius: size * 0.85))
                        .frame(width: size * 1.7, height: size * 1.7)
                        .mask(
                            // Keep everything EXCEPT the orb's own circle — cuts the
                            // interior cleanly so the glow starts bright AT the rim.
                            Rectangle()
                                .overlay(
                                    Circle()
                                        .frame(width: size, height: size)
                                        .blendMode(.destinationOut)
                                )
                                .compositingGroup()
                        )

                    // Clearer glass variant so the centre is more see-through
                    // (the rim colour + gold ring + stroke still define the orb).
                    Color.clear
                        .frame(width: size, height: size)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

                    // Swirling 90s colours on the outer ring (clear centre), slowly
                    // spinning, glowing onto the glass.
                    AngularGradient(gradient: Gradient(colors: swirl),
                                    center: .center, angle: .degrees(angle))
                        .frame(width: size, height: size)
                        .mask(edgeMask)
                        .clipShape(Circle())
                        .blur(radius: 2)
                        .opacity(0.74)
                        .blendMode(.plusLighter)
                    }
                    .opacity(min(1, morph * 1.5))

                    // The rainbow aperture glyph the orb GROWS OUT OF — a
                    // clone of the sidebar mark at grab (the mark hides the
                    // same instant this appears in its place). The iris opens
                    // outward and dissolves as the glass takes over, and
                    // re-condenses into the mark on the way home.
                    Image(systemName: "camera.aperture")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.95, height: size * 0.95)
                        .foregroundStyle(LinearGradient(
                            colors: Array(swirl.prefix(6)),
                            startPoint: .top, endPoint: .bottom))
                        .opacity(max(0, 1 - morph * 1.6))
                }
                .rotationEffect(-stretchAngle)
                .scaleEffect(x: 1 + m, y: 1 - m * 0.55, anchor: .center)
                .rotationEffect(stretchAngle)
            }
            // 0.38 = the sidebar mark's 34 pt over the orb's 90 — the morph
            // starts at mark size and grows, rather than fading in.
            .scaleEffect(0.38 + 0.62 * morph)
        }
    }
}
