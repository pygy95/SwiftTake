//
//  CoplandDevelopLayer.swift
//  SwiftTake
//
//  The Copland develop overlay — the glass bubble that flows from the orb's
//  release point onto a thumbnail, sweeps a gold sheen over the photo while
//  the import runs underneath, and fades out when it completes.
//
//  Extracted as a view struct with declared inputs, so the develop animation
//  and the frame-reading box it depends on live together. The frame read
//  itself stays behind CoplandFrameReader for the reason its doc comment
//  gives: a scroll-time frame write must re-evaluate that tiny view and
//  nothing else.
//

import SwiftUI

/// Copland develop overlay: the orb (a clear Liquid Glass bubble) flows from
/// its release point into a square over the target thumbnail, sweeps a gold
/// "develop" sheen across the photo while the import runs underneath, and
/// fades out on completion — all above the gallery so it isn't clipped.
struct CoplandDevelopLayer: View {
    let index: UInt8
    let frameStore: ThumbFrameStore
    /// Where the orb was released (global) — the morph starts here.
    let releasePoint: CGPoint
    /// 0 = orb circle at the release point, 1 = square filling the thumbnail.
    let morph: CGFloat
    let bubbleOpacity: Double
    /// True while this photo is being forced small ahead of the develop.
    let isShrinking: Bool
    let enhancedImage: NSImage?
    let thumbnail: NSImage?
    let isConnected: Bool
    let hasImportedFiles: Bool
    let squareGrid: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The frame read lives in CoplandFrameReader so scroll-time frame
        // writes re-evaluate only that tiny view, never this whole body.
        CoplandFrameReader(store: frameStore, index: index) { gf in
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let gold = Color(red: 0.98, green: 0.80, blue: 0.32)
                let m = morph
                let startC = CGPoint(x: releasePoint.x - origin.x,
                                     y: releasePoint.y - origin.y)
                let endC = CGPoint(x: gf.midX - origin.x, y: gf.midY - origin.y)
                let cx = startC.x + (endC.x - startC.x) * m
                let cy = startC.y + (endC.y - startC.y) * m
                // Match the thumbnail's VISUAL size, not its layout box: un-imported
                // previews render small (B&W at 0.66, offline at 0.8), imported ones
                // fill the cell. So the bubble is small on small thumbs and large on
                // imported ones — and grows in step as the photo develops.
                let hasEnhanced = enhancedImage != nil && !isShrinking
                let offlineDim = !isConnected && !hasImportedFiles
                let vs: CGFloat = (hasEnhanced ? 1.0 : 0.66) * (offlineDim ? 0.8 : 1.0)
                let tw = gf.width * vs
                let th = gf.height * vs
                let w = 90 + (tw - 90) * m
                let h = 90 + (th - 90) * m
                // Match the thumbnail's VISUAL corner radius (the cell's 12pt — 0 in
                // square mode — scaled by the same vs as its size) so the glass aligns
                // with the thumbnail underneath with no overlap/underlap. Lerps from
                // the orb's circle (45) into that as it settles.
                let thumbRadius = (squareGrid ? 0 : 12) * vs
                let corner = 45 + (thumbRadius - 45) * m
                let shape = RoundedRectangle(cornerRadius: max(0, corner), style: .continuous)

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
                let photo = enhancedImage ?? thumbnail
                let edge = max(5, min(w, h) * 0.10)        // inner edge-fade band
                ZStack {
                    // Clear Liquid Glass body — the bubble itself.
                    Color.clear
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .clipShape(shape)

                    // Glowing 90s Apple-logo colours, rotating — behind the photo, so
                    // they show through the photo's faded inner edges as a glowing
                    // frame while it processes.
                    if m >= 0.999 && bubbleOpacity > 0.5 {
                        // Reduce Motion: the swirl still shows — frozen at one
                        // angle instead of continuously spinning.
                        TimelineView(reduceMotion ? .animation(paused: true)
                                                   : .animation(minimumInterval: 1.0 / 30.0)) { tl in
                            let angle = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate * 42
                            AngularGradient(gradient: Gradient(colors: swirl),
                                            center: .center, angle: .degrees(angle))
                                .blur(radius: 6)
                                .opacity(0.8)
                                .blendMode(.plusLighter)
                        }
                        .clipShape(shape)
                    }

                    // The photo — fills the bubble at the SAME corner radius as the
                    // thumbnail (aligns, no overlap/underlap), with its inner edges
                    // faded to transparent while processing so the glass + colours
                    // blend in around the rim.
                    if let photo {
                        Image(nsImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w, height: h)
                            .clipShape(shape)
                            .mask(
                                shape
                                    .inset(by: edge)
                                    .fill(Color.black)
                                    .blur(radius: edge * 0.9)
                            )
                            // Reveal ONLY once the bubble is fully in position around
                            // the thumbnail — never while it's still flowing in — then
                            // fade in. (No stretch/oversize during the morph.)
                            .opacity(m >= 0.999 ? 1 : 0)
                            .animation(.easeIn(duration: 0.3), value: m >= 0.999)
                    }
                }
                .frame(width: w, height: h)
                // Grow smoothly when the photo finishes developing (B&W→colour
                // flips the visual scale up to full size).
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: hasEnhanced)
                // Gold glow hugging the bubble — concentric strokes of the SAME
                // morphing shape, no blur and no .shadow: a shadow rasterises a
                // beat behind the moving/resizing glass, so the glow visibly
                // desyncs from the bubble mid-morph. Strokes are drawn
                // in the same pass as the shape and can't lag it. The falloff
                // between rings must be GRADUAL: a 3-ring version with
                // a bright thin ring next to a much fainter band reads as a
                // "double gold border" instead of one feathered glow.
                .overlay {
                    ZStack {
                        shape.stroke(gold.opacity(0.26), lineWidth: 3)
                        shape.stroke(gold.opacity(0.15), lineWidth: 6.5)
                        shape.stroke(gold.opacity(0.10), lineWidth: 11)
                        shape.stroke(gold.opacity(0.065), lineWidth: 16.5)
                        shape.stroke(gold.opacity(0.04), lineWidth: 23)
                    }
                    .allowsHitTesting(false)
                }
                .position(x: cx, y: cy)
                .opacity(bubbleOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // decorative develop animation
    }
}

/// Reads ONE thumbnail's live frame from the store and hands it to `content`.
/// Exists so the frame dependency is registered against THIS tiny view rather
/// than against the develop layer or ContentView — see `ThumbFrameStore`.
private struct CoplandFrameReader<Content: View>: View {
    let store: ThumbFrameStore
    let index: UInt8
    @ViewBuilder let content: (CGRect) -> Content

    var body: some View {
        if let gf = store.frames[index] {
            content(gf)
        }
    }
}
