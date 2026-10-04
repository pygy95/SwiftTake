//
//  StatusBubbleLayer.swift
//  SwiftTake
//
//  The status bubble: one glass shape that morphs between the sidebar's
//  resting capsule and the draggable orb.
//
//  Extracted as a view struct with declared inputs so the morph reads from a
//  named set of values rather than from ContentView's whole state. The drag
//  state itself still lives in ContentView `@State` (moving it into a box is
//  the roadmap's secondary item) — this split is what makes that a one-file
//  change when the numbers ask for it.
//

import SwiftUI

/// The single, always-present bubble: a glass shape that morphs from the
/// resting capsule (`morph == 0`) to the round orb (`== 1`), follows
/// the cursor, and jellies with velocity. Lives in the window overlay so it
/// escapes the sidebar's clipping; the sidebar footer is a clear placeholder.
struct StatusBubbleLayer: View {
    /// The resting capsule's frame — the morph starts from its size.
    let homeRect: CGRect
    /// 0 = resting capsule, 1 = round orb.
    let morph: Double
    /// The bubble's centre in global coordinates.
    let orbGlobal: CGPoint
    /// Jelly deformation and the axis it acts along.
    let stretch: CGFloat
    let stretchAngle: Angle
    /// 1 normally; drops to 0 as the orb is absorbed into the aperture, then
    /// grows back as the status bar reforms.
    let absorbScale: CGFloat
    let text: String
    let indicatorColor: Color

    @Environment(\.isClassicTheme) private var isClassicTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: no jelly squash/stretch — the bubble still morphs
        // and follows the drag, it just doesn't wobble while doing it.
        let stretch = reduceMotion ? 0 : self.stretch

        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let m = morph
            let cap = homeRect.size
            let orbD: CGFloat = 50
            // Types spelled out: these mix the Double morph with CGFloat
            // geometry, and left to inference the chain defeats the
            // type-checker's budget outright.
            let w: CGFloat = cap.width + (orbD - cap.width) * m
            let h: CGFloat = cap.height + (orbD - cap.height) * m
            // Classic: blocky OS 9 corners, not the modern capsule.
            let radius: CGFloat = isClassicTheme ? 4 : h / 2

            // The status light is ONE element that Magic-Moves from the
            // capsule's left edge to the orb's centre as it balls up,
            // growing from the 8pt dot to the glowing core.
            let coreSize: CGFloat = max(8, h * 0.26)
            let dotSize: CGFloat = 8 + (coreSize - 8) * m
            let dotX: CGFloat = 16 + (w / 2 - 16) * m

            ZStack(alignment: .topLeading) {
                Color.clear

                // Status text — fades out as it balls up (left-inset to sit
                // just past the resting dot). A soft cross-fade swaps one
                // message for the next; the capsule resizes to fit the text
                // (dynamic), so short messages never sprawl.
                Text(text)
                    .font(isClassicTheme ? Font.classic(11) : .caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: text)
                    // Wrap to the SAME text width the placeholder capsule was
                    // measured at (leading dot inset 28 + trailing 12), so the
                    // text fills the dynamic bubble instead of running off it
                    // (a `.fixedSize()` would force one long line).
                    .frame(width: max(0, w - 40), alignment: .leading)
                    .padding(.leading, 28)
                    .frame(width: w, height: h, alignment: .leading)
                    .opacity(1 - min(1, m * 1.8))

                // Soft halo bleeding into the glass as it rounds up.
                Circle()
                    .fill(indicatorColor)
                    .frame(width: coreSize * 1.6, height: coreSize * 1.6)
                    .blur(radius: coreSize * 0.85)
                    .opacity(m)
                    .position(x: w / 2, y: h / 2)

                // The travelling status light itself — in Classic an OS 9
                // lamp (recessed Platinum ring, flat LED) instead of the
                // modern glowing dot; the orb egg is locked there anyway.
                if isClassicTheme {
                    ClassicStatusLamp(color: indicatorColor, size: dotSize)
                        .position(x: dotX, y: h / 2)
                } else {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: dotSize, height: dotSize)
                        .shadow(color: indicatorColor.opacity(0.9 * m), radius: dotSize * 0.5 * m)
                        .position(x: dotX, y: h / 2)
                }
            }
            .frame(width: w, height: h)
            .modifier(BubbleSurface(radius: radius,
                                    tint: indicatorColor.opacity(0.16 * m),
                                    classic: isClassicTheme))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(isClassicTheme ? 0 : 0.14 * m), lineWidth: 1)
            )
            // Keep the fading text contained as the shape shrinks to a ball.
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Jelly: stretch ALONG travel, squash across — rotate→scale→
            // counter-rotate so the stretch axis follows the fling without
            // ever rotating the bubble itself (no upside-down, no spin).
            .rotationEffect(-stretchAngle)
            .scaleEffect(x: 1 + stretch * m, y: 1 - stretch * 0.55 * m, anchor: .center)
            .rotationEffect(stretchAngle)
            // Lift shadow grows as it balls up.
            .shadow(color: .black.opacity(0.30 * m), radius: 18 * m, y: 12 * m)
            .shadow(color: indicatorColor.opacity(0.45 * m), radius: h * 0.28 * m)
            // Absorb shrink / reform grow.
            .scaleEffect(absorbScale, anchor: .center)
            .position(x: orbGlobal.x - origin.x, y: orbGlobal.y - origin.y)
            .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }
}
