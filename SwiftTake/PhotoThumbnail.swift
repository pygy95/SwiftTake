//
//  PhotoThumbnail.swift
//  SwiftTake
//
//  One gallery tile: the image (or its loading animation), the selection
//  and focus borders, the Copland gold glow, and the springs that carry
//  all of it between states.
//
//  A view STRUCT rather than a method on ContentView, and that is the
//  point. SwiftUI re-evaluates at struct granularity: as a method the
//  tile was part of ContentView's ~5,500-line body, so every published
//  change on the manager — each progress tick of every import — rebuilt
//  every tile in the grid. Given its own struct with declared inputs, a
//  tile re-renders only when ITS values change.
//
//  Inputs are passed explicitly for the same reason. Reading the manager
//  from the environment here would re-widen the dependency to "any
//  change on the manager" and give the split back.
//

import SwiftUI

struct PhotoThumbnail: View {
    let index: UInt8
    let isSelected: Bool
    let isFocused: Bool

    /// The colour preview, once decoded — nil until then.
    let enhancedImage: NSImage?
    /// The camera's B&W thumbnail; the loading animation stands in when nil.
    let thumbnail: NSImage?
    /// Drives the offline dim: on-camera photos with nothing on disk.
    let hasImportedFiles: Bool
    let isConnected: Bool
    /// True while a Copland develop is squeezing this photo small.
    let isDevelopingShrink: Bool
    let isCoplandDeveloped: Bool
    let squareModeHidesGlow: Bool
    let squareGrid: Bool

    @Environment(\.isClassicTheme) private var isClassicTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Note: deliberately NOT @ViewBuilder — the inner-scale and
    // outer-frame layers compose in two steps via `let body = …; return
    // body…`, and ViewBuilder is incompatible with explicit `return`.
    var body: some View {
        // The OUTER frame is always full column-width × 4:3 — this gives
        // the tile a fixed final geometry. The INNER content is scaled
        // around its centre via `.scaleEffect`, so the B&W loading
        // thumbnail sits small in the middle of an empty cell, and the
        // colour preview grows out to the edges from that same centre
        // point when it lands. SwiftUI's scaleEffect anchors at .center
        // by default, so the animation is symmetric on all four sides.
        let hasEnhanced = enhancedImage != nil
        let bwScale: CGFloat = 0.66    // B&W thumbnail visual size (small + centered)
        // Copland develop forces this photo small first (even if imported) so it
        // shrinks, then expands as it develops — matching the un-imported flow.
        let scale: CGFloat = (hasEnhanced && !isDevelopingShrink) ? 1.0 : bwScale

        // A fixed-aspect, full-width Color.clear is the LAYOUT anchor: it alone
        // defines the cell size (square 1:1 or native 4:3). The image is an
        // OVERLAY that fills + crops to those bounds, so `scaledToFill` can never
        // drive the cell's size — which was the bug that made square-mode cells
        // overflow and overlap their neighbours.
        let body = Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(squareGrid ? 1.0 : (4.0 / 3.0), contentMode: .fit)
            .overlay {
                let image = enhancedImage ?? thumbnail
                ZStack {
                    if let image {
                        // The real thumbnail fizzles in over the loader. Classic
                        // uses a plain dissolve (no blur), matching the CRT feel.
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(isClassicTheme ? AnyTransition.opacity : AnyTransition(.blurReplace))
                    } else if isClassicTheme {
                        // Classic: a black-and-white CRT static that the photo
                        // fizzles in over — no Apple-Intelligence colour.
                        ClassicCRTLoader(seed: Double(index))
                            .transition(.opacity)
                    } else {
                        // Apple-Intelligence-style swirling colour while loading.
                        // Disconnected mid-load → the vortex spins down and
                        // drains to B&W; reconnect winds it back up.
                        ThumbnailLoadingSwirl(seed: Double(index),
                                              frozen: !isConnected)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: isClassicTheme ? 0.32 : 0.5), value: image == nil)
            }
            // Square (contact-sheet) mode: sharp corners, no shadow, so cells
            // read as one flush grid like Photos. Aspect mode keeps the rounded,
            // shadowed card look.
            .clipShape(RoundedRectangle(cornerRadius: squareGrid ? 0 : 12, style: .continuous))
            .shadow(radius: squareGrid ? 0 : (isSelected ? 4 : 2), y: squareGrid ? 0 : 2)
            // Copland: a developed photo's THUMBNAIL only ever gains a small
            // soft gold glow (the Mac OS 9 frame lives on the exported image,
            // not here). It fades in gently as the developed photo loads.
            //
            // Attached HERE — after the clip (so the rings aren't cut off)
            // and after the shadow (so they don't cast one), but INSIDE the
            // `.animation(value: squareGrid)` below — on purpose: a
            // background outside that animation is laid out at the FINAL
            // cell size immediately, so on a mode switch the gold frame
            // appeared full-size while the photo was still springing toward
            // it. In here it interpolates with the photo, frame for frame.
            .background { coplandGlow }
            .animation(.easeInOut(duration: 0.9), value: isCoplandDeveloped)
            .overlay(
                RoundedRectangle(cornerRadius: squareGrid ? 0 : 12)
                    // Period selection-blue border in Classic; accent otherwise.
                    .stroke(isSelected
                        ? (isClassicTheme ? AppTheme.platinumHighlight : Color.accentColor)
                        : (isFocused
                            ? (isClassicTheme ? AppTheme.platinumHighlight.opacity(0.55) : Color.secondary.opacity(0.5))
                            : Color.clear),
                        lineWidth: isSelected ? 3 : 2)
            )
            // Centre-anchored scale: 0.66 → 1.0 when colour preview arrives.
            .scaleEffect(scale, anchor: .center)

        return body
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: squareGrid)
            // Offline / un-imported dim — applied to the OUTER frame so
            // it shrinks the whole cell, not just the inner content.
            .scaleEffect((!isConnected && !hasImportedFiles) ? 0.8 : 1.0, anchor: .center)
            .opacity((!isConnected && !hasImportedFiles) ? 0.3 : 1.0)
            // Selection/focus stroke — a spring normally, a quick fade under
            // Reduce Motion (still shows up, just doesn't bounce).
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(), value: isSelected)
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(), value: isFocused)
            .transition(.asymmetric(
                insertion: .modifier(
                    active: ThumbnailGrowModifier(scale: 0.15, opacity: 0),
                    identity: ThumbnailGrowModifier(scale: 1.0, opacity: 1.0)
                ),
                removal: .opacity
            ))
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: thumbnail != nil)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: hasEnhanced)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isDevelopingShrink)
            .animation(.spring(), value: hasImportedFiles)
    }

    @ViewBuilder
    private var coplandGlow: some View {
        if isCoplandDeveloped {
            let gold = Color(red: 0.98, green: 0.80, blue: 0.32)
            // SHORT glow: the cell's cornerRadius clips its background, so the glow
            // must fade out within the ~8pt padding margin or it cuts off with a
            // hard edge. A tight blur hugging the photo edge stays unclipped.
            // NO BLUR, on hard-won principle: the old blurred gold card
            // re-rasterised a beat late while the grid reflowed (its size +
            // position change every spring frame), so the gold visibly
            // trailed the fast-moving thumbnail on the mode switch.
            // Feathered stroke rings of the same shape — the develop bubble's
            // approved recipe — draw in the same pass as the cell and cannot
            // trail it. Half of each stroke hides behind the opaque photo; the
            // outer half is the soft peeking glow.
            //
            // GEOMETRY carries NO animation of its own, deliberately: as a
            // .background this view is handed the cell's ALREADY-interpolated
            // frame every layout pass, so with no clock here it tracks the
            // photo exactly. Giving it its own spring made it chase the
            // interpolating frame — a spring following a spring — which read
            // as the gold frame "catching up" after the thumbnail.
            // OPACITY answers to `squareModeHidesGlow`, whose changes arrive
            // in their own withAnimation transactions (near-instant hide /
            // slow swell) that contain no geometry to steer.
            // Eight fine rings, 1.5 pt apart with small opacity steps — four
            // coarse rings quantised visibly (visible banding). At this
            // pitch adjacent steps are ~0.02–0.05 alpha and the falloff
            // reads as one continuous feather.
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                shape.stroke(gold.opacity(0.42), lineWidth: 1.5)
                shape.stroke(gold.opacity(0.30), lineWidth: 3)
                shape.stroke(gold.opacity(0.21), lineWidth: 4.5)
                shape.stroke(gold.opacity(0.145), lineWidth: 6)
                shape.stroke(gold.opacity(0.10), lineWidth: 7.5)
                shape.stroke(gold.opacity(0.065), lineWidth: 9)
                shape.stroke(gold.opacity(0.04), lineWidth: 10.5)
                shape.stroke(gold.opacity(0.022), lineWidth: 12)
            }
            .opacity(squareModeHidesGlow ? 0 : 1)
        }
    }
}
