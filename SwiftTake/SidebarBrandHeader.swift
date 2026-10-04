//
//  SidebarBrandHeader.swift
//  SwiftTake
//
//  The top of the sidebar: the aperture mark, the wordmark that types itself,
//  and the plaque behind them — plus both easter eggs they carry.
//
//  Extracted as a view struct with declared inputs. The mark runs a wink
//  animation and the wordmark a typewriter, and as part of ContentView's body
//  both were rebuilt on any published change on the manager. What the header
//  actually reads is the connection, the two unlock flags, and the glow.
//
//  The mark's own home frame is written back through a binding, because the
//  orb's flight home targets it — see the freeze note in the tracker.
//

import SwiftUI

/// Brand header — a fixed aperture mark (tinted to the theme's primary so it
/// reads in light and dark) beside the wordmark, which types itself in à la
/// Keynote when it changes (SwiftTake ⇄ the connected camera's name).
struct SidebarBrandHeader<DragGesture: Gesture>: View {
    let isConnected: Bool
    /// The connected camera's short name; the wordmark shows it in place of
    /// "SwiftTake".
    let cameraShortName: String
    let glowColor: Color
    let glowLevel: Double
    let rainbowUnlocked: Bool
    let phantomSecretUnlocked: Bool
    let allStatusColorsCollected: Bool
    let allPhantomsAbsorbed: Bool
    /// Both eggs done (and not Classic) — the mark becomes grabbable.
    let fullyUnlocked: Bool
    let orbOut: Bool
    /// The mark's live global frame: the orb's return target.
    @Binding var markRect: CGRect
    let onUnlockRainbow: () -> Void
    let onUnlockPhantom: () -> Void
    let dragGesture: DragGesture

    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var classicTaps = 0
    @State private var lastClassicTap = Date.distantPast

    var body: some View {
        HStack(spacing: 12) {
            if isClassicTheme {
                classicPlaque
            } else {
            ApertureMark(
                glowColor: glowColor,
                glowLevel: glowLevel,
                rainbow: rainbowUnlocked,
                gold: phantomSecretUnlocked,
                canUnlockRainbow: allStatusColorsCollected,
                onUnlockRainbow: onUnlockRainbow,
                canUnlockPhantom: allPhantomsAbsorbed,
                onUnlockPhantom: onUnlockPhantom,
                fullyUnlocked: fullyUnlocked
            )
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { markRect = g.frame(in: .global) }
                            // Freeze home while the orb is out — the mark
                            // offsets toward the cursor during a grab, and we
                            // must NOT let that moved frame overwrite home
                            // (it would corrupt the orb's return target).
                            .onChange(of: g.frame(in: .global)) { _, f in
                                if !orbOut { markRect = f }
                            }
                    }
                )
                // The mark swaps out INSTANTLY on grab: the orb
                // layer takes over at this exact spot as a clone
                // of the mark (same size, same rainbow glyph) and
                // visibly TRANSFORMS into the glass ball as it
                // travels. Having the mark follow the cursor while
                // force-fading over ~45 pt, with the orb fading in
                // separately, would be a crossfade of two objects
                // and read as the mark "fading off in the direction
                // you pull", not a morph.
                .opacity(orbOut ? 0 : 1)
                // Fully unlocked → the mark becomes grabbable. A
                // simultaneousGesture so the Button's tap (pulse)
                // and the drag (orb) coexist; limited to subviews
                // pre-unlock so tap/wink still works.
                .simultaneousGesture(dragGesture,
                                     including: fullyUnlocked ? .all : .subviews)

            // Egg growth: the mark steps +3pt on a 28pt base per
            // completed easter egg; the wordmark grows in lockstep.
            let eggBoost = 1 + Double((rainbowUnlocked ? 1 : 0)
                                      + (phantomSecretUnlocked ? 1 : 0)) * (3.0 / 28.0)
            WordmarkBrand(
                text: isConnected ? cameraShortName : "SwiftTake",
                platinum: phantomSecretUnlocked,
                font: .title2,
                platinumStyle: ContentView.platinumWordmark
            )
            .layoutPriority(1)
            .scaleEffect(eggBoost, anchor: .leading)
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: rainbowUnlocked)
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: phantomSecretUnlocked)

            Spacer(minLength: 0)
            }
        }
        // Backdrop behind the brand mark: Platinum plaque in
        // Classic, Liquid Glass capsule otherwise. Both easter
        // eggs complete → it slowly gilds to gold.
        .modifier(BrandHeaderBackdrop(
            classic: isClassicTheme,
            plain: isClassicTheme,
            gilded: rainbowUnlocked && phantomSecretUnlocked,
            orbOut: orbOut
        ))
    }

    /// The original Platinum artwork remains still, including while connected
    /// or after unlocking rewards. Keep its aperture's interaction and global
    /// bounds so collecting a planet never flies toward the old modern mark.
    private var classicPlaque: some View {
        Image("ClassicWordmarkPlaque")
            .resizable().scaledToFit().frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .overlay {
                GeometryReader { proxy in
                    let aperture = classicApertureBounds(in: CGRect(origin: .zero, size: proxy.size))
                    Button(action: registerClassicTap) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: aperture.width, height: aperture.height)
                    .position(x: aperture.midX, y: aperture.midY)
                    .accessibilityLabel("SwiftTake aperture")
                }
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                classicApertureBounds(in: proxy.frame(in: .global))
            } action: { markRect = $0 }
            .transaction { $0.animation = nil }
    }

    private func classicApertureBounds(in frame: CGRect) -> CGRect {
        // Aperture bounds in the bundled 820 × 210 plaque artwork.
        CGRect(x: frame.minX + frame.width * 36 / 820,
               y: frame.minY + frame.height * 30 / 210,
               width: frame.width * 140 / 820,
               height: frame.height * 140 / 210)
    }

    private func registerClassicTap() {
        let now = Date()
        classicTaps = now.timeIntervalSince(lastClassicTap) < 1.2 ? classicTaps + 1 : 1
        lastClassicTap = now
        guard classicTaps == 7 else { return }
        classicTaps = 0
        if allStatusColorsCollected && !rainbowUnlocked { onUnlockRainbow() }
        else if allPhantomsAbsorbed && !phantomSecretUnlocked { onUnlockPhantom() }
    }
}

/// The sidebar brand aperture — a theme-tinted `camera.aperture` mark with a
/// hidden treat: seven quick clicks fire a "shutter" — the iris spins a full
/// turn while the lens pinches and a flash pops. Slow clicks just reset the
/// counter, so it stays an easter egg, not an accident.
private struct ApertureMark: View {
    /// Colour-absorb easter egg: when the status orb is dropped on the mark it
    /// glows this colour (`glowLevel` 0→1→0). Defaults make it inert.
    var glowColor: Color = .clear
    var glowLevel: Double = 0
    /// Once every status colour has been absorbed, a 7-click wink turns the mark
    /// permanently rainbow (the 90s Apple stripes) and unlocks a setting.
    /// 90s Apple rainbow stripes — unlocked by the status-orb easter egg.
    var rainbow: Bool = false
    /// Shiny gold — unlocked by absorbing all three phantom photos. With `rainbow`
    /// it layers a gold sheen over the stripes for the "fully leveled up" look.
    var gold: Bool = false
    var canUnlockRainbow: Bool = false
    var onUnlockRainbow: () -> Void = {}
    /// Phantom track: all three .qtk absorbed (arms a 7-click wink to unlock).
    var canUnlockPhantom: Bool = false
    var onUnlockPhantom: () -> Void = {}
    /// Both tracks done. The 7-click wink is retired; the mark becomes a pure
    /// drag handle (clicks do nothing — drag it to summon the orb).
    var fullyUnlocked: Bool = false

    @State private var taps = 0
    @State private var rotation = 0.0
    @State private var scale = 1.0
    @State private var flash = 0.0
    @State private var resetTask: Task<Void, Never>?

    /// The 90s Apple logo stripes, top→bottom.
    private static let rainbowFill = LinearGradient(
        colors: [
            Color(red: 0.38, green: 0.73, blue: 0.28),
            Color(red: 0.96, green: 0.76, blue: 0.17),
            Color(red: 0.94, green: 0.52, blue: 0.16),
            Color(red: 0.88, green: 0.21, blue: 0.26),
            Color(red: 0.58, green: 0.24, blue: 0.59),
            Color(red: 0.00, green: 0.58, blue: 0.84)
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// The base fill for the mark: the 90s rainbow (status-orb egg) or the plain
    /// theme tint. Gold (phantom egg) is applied to the wordmark instead.
    private var baseStyle: AnyShapeStyle {
        rainbow ? AnyShapeStyle(Self.rainbowFill) : AnyShapeStyle(.primary)
    }

    /// Number of easter eggs completed (0/1/2) → cosmetic "level" 1/2/3.
    private var eggCount: Int { (rainbow ? 1 : 0) + (gold ? 1 : 0) }
    /// The mark grows a touch with each level (28 → 31 → 34).
    private var markSize: CGFloat { 28 + CGFloat(eggCount) * 3 }

    private func aperture() -> some View {
        Image(systemName: "camera.aperture").resizable().scaledToFit()
    }

    var body: some View {
        // A Button (not a bare onTapGesture) so clicks register reliably even
        // when the window isn't key — macOS would otherwise eat the first click.
        Button(action: registerTap) {
            ZStack {
                // Base mark — theme tint, or the 90s rainbow (status egg). The
                // gold (phantom egg) reward lives on the wordmark, not here; the
                // aperture only grows per level.
                aperture().foregroundStyle(baseStyle)

                // Absorbed-colour wash, crossfading over the base then fading back.
                aperture()
                    .foregroundStyle(glowColor)
                    .opacity(glowLevel)
            }
            // Grows with each level (1 → 2 → 3); animates as eggs complete.
            .frame(width: markSize, height: markSize)
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: eggCount)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .overlay {
                // A brief white bloom — the camera flash (wink easter egg).
                Circle()
                    .fill(.white)
                    .blur(radius: 5)
                    .opacity(flash)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            // Coloured glow radiating from the mark while it holds the colour.
            // Kept modest so it doesn't bloom up past the window into the menu bar.
            .shadow(color: glowColor.opacity(glowLevel * 0.8), radius: 6 * glowLevel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private func registerTap() {
        // Fully unlocked: the mark is purely a drag handle — clicks do nothing
        // (drag it to summon the orb).
        if fullyUnlocked { return }
        resetTask?.cancel()
        taps += 1
        if taps >= 7 {
            taps = 0
            wink()
        } else {
            // Forget the streak if the next click doesn't come soon. `try?`
            // swallows the cancellation error, so we must bail explicitly when
            // cancelled — otherwise each new click's cancel() would still run
            // `taps = 0` and the counter could never reach seven.
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                taps = 0
            }
        }
    }

    private func wink() {
        // Is this wink the one that unlocks a track? Rainbow (status) takes
        // priority, then phantom (gold). The activating wink is deliberately
        // slower and a touch larger than a normal click, to mark the moment.
        let unlockingRainbow = canUnlockRainbow && !rainbow
        let unlockingPhantom = !unlockingRainbow && canUnlockPhantom && !gold
        let unlocking = unlockingRainbow || unlockingPhantom

        // Shutter snap: an iris pinch + flash, then settle, with a spin of the
        // aperture blades over the top. When unlocking, everything is slower and
        // a little bigger — a deeper pinch, a brighter flash, and a settle that
        // pops slightly past full size before easing back.
        let pinchDur = unlocking ? 0.14 : 0.09
        withAnimation(.easeIn(duration: pinchDur)) {
            scale = unlocking ? 0.70 : 0.78
            flash = unlocking ? 0.85 : 0.7
        }
        withAnimation(.spring(response: unlocking ? 1.1 : 0.55,
                              dampingFraction: unlocking ? 0.7 : 0.6)) {
            rotation += unlocking ? 720 : 360
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pinchDur * 1_000_000_000))
            if unlocking {
                // Low damping → a gentle overshoot past 1.0 (the "slightly
                // larger" pop), over a slower settle.
                withAnimation(.spring(response: 0.6, dampingFraction: 0.45)) { scale = 1.0 }
                withAnimation(.easeOut(duration: 0.5)) { flash = 0.0 }
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.5)) { scale = 1.0 }
                withAnimation(.easeOut(duration: 0.28)) { flash = 0.0 }
            }
        }
        if unlockingRainbow {
            // Reveal the rainbow part-way through the spin so it "becomes" it.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.easeInOut(duration: 0.5)) { onUnlockRainbow() }
            }
        } else if unlockingPhantom {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.easeInOut(duration: 0.5)) { onUnlockPhantom() }
            }
        }
    }

}

/// The brand wordmark: types itself in (via `TypewriterText`) and, once the
/// phantom easter egg unlocks, does a one-time shine sweep and slow fade into a
/// subtle metallic platinum. After the reveal the platinum sticks (and types in
/// platinum if the word later changes).
private struct WordmarkBrand: View {
    let text: String
    let platinum: Bool
    let font: Font
    let platinumStyle: AnyShapeStyle

    @State private var reveal: Double = 0       // 0 = themed colour, 1 = platinum
    @State private var shineX: CGFloat = -0.4   // shine band sweep phase
    @State private var shining = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Base wordmark (handles typing). Once revealed it IS platinum, so a
            // later word change still types in platinum.
            TypewriterText(text)
                .modifier(WordmarkText(font: font))
                .foregroundStyle(reveal >= 1 ? platinumStyle : AnyShapeStyle(.primary))

            // During the reveal, a static platinum copy crossfades over the base.
            if reveal < 1 {
                Text(text)
                    .modifier(WordmarkText(font: font))
                    .foregroundStyle(platinumStyle)
                    .opacity(reveal)
            }
        }
        .overlay {
            if shining {
                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.4)
                        .offset(x: shineX * (w * 1.6) - w * 0.3)
                        .blendMode(.plusLighter)
                }
                .mask { Text(text).modifier(WordmarkText(font: font)) }
                .allowsHitTesting(false)
            }
        }
        .onAppear { reveal = platinum ? 1 : 0 }   // reflect persisted state, no anim
        .onChange(of: platinum) { _, now in
            if now { celebrate() } else { reveal = 0; shining = false }
        }
    }

    private func celebrate() {
        withAnimation(.easeInOut(duration: 2.0)) { reveal = 1 }    // slow fade (~0.5s slower)
        shineX = -0.4
        shining = true
        withAnimation(.easeInOut(duration: 1.7)) { shineX = 1.3 }  // shine sweep (matched)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            shining = false
        }
    }
}

/// Shared wordmark text styling. The scale floor is generous (0.55) so even
/// the longest camera name in the widest face (Charcoal "QuickTake 200",
/// egg-boosted) always fits the plaque instead of clipping.
private struct WordmarkText: ViewModifier {
    let font: Font
    func body(content: Content) -> some View {
        content
            .font(font)
            .fontWeight(.bold)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }
}

private struct BrandHeaderBackdrop: ViewModifier {
    let classic: Bool
    /// Bare passthrough — for content that IS its own plaque (the Classic
    /// wordmark plate artwork), where any backdrop would double-frame it.
    var plain: Bool = false
    var gilded: Bool = false
    /// True while the aperture orb is out being dragged. The gilded plaque's
    /// ambient glow is the orb's glow: it drains off the plaque the moment the
    /// orb is grabbed (the orb's halo blooms in at the same instant, as if it
    /// took the glow with it) and swells back slowly once the orb comes home.
    var orbOut: Bool = false

    /// Solid opaque dark chip behind the gilded state. Translucent tints let the
    /// bright window/plaque bleed through (muddy, low-contrast); a solid fill is
    /// reliably dark in every theme/mode so the metallic text + gold rim pop.
    private static let gildedDark = LinearGradient(
        colors: [Color(white: 0.17), Color(white: 0.07)],
        startPoint: .top, endPoint: .bottom)

    // Gold palette for the gilded reward state.
    /// Polished-gold ring: dark → bright → mid → bright → dark, so the rim shows
    /// two travelling highlights instead of one flat light-to-dark diagonal.
    private static let goldRing = [
        Color(red: 0.52, green: 0.36, blue: 0.07),
        Color(red: 1.00, green: 0.95, blue: 0.74),
        Color(red: 0.70, green: 0.50, blue: 0.14),
        Color(red: 1.00, green: 0.90, blue: 0.60),
        Color(red: 0.52, green: 0.36, blue: 0.07)
    ]
    private static let platinumEdge = LinearGradient(
        colors: [AppTheme.platinumLight, AppTheme.platinumShadow],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    @ViewBuilder
    func body(content: Content) -> some View {
        if plain {
            content
        } else {
            decorated(content)
        }
    }

    private func decorated(_ content: Content) -> some View {
        let padded = content.padding(.horizontal, 10).padding(.vertical, 8)
        let shape = RoundedRectangle(cornerRadius: classic ? 8 : 14, style: .continuous)

        // The content (aperture + wordmark) is a SINGLE stable view — never
        // rebuilt when `gilded` flips — so the gild reveal can't cross-dissolve
        // over it. Only the surfaces BEHIND (and the rim AROUND) it animate, so
        // the mark and text stay crisp and untouched throughout.
        return padded
            .background {
                ZStack {
                    // Ambient gold aura behind the gilded chip — the same soft
                    // glow a Copland-developed thumbnail wears (gold shape,
                    // tight blur, peeking out from behind). Blur is safe here:
                    // the plaque never moves, so the frame-late raster that
                    // plagued the orb's tail can't show. Drains FAST on grab
                    // (the orb's halo blooms in the same beat) and re-glows
                    // SLOWLY after the orb has sprung home.
                    shape.fill(Color(red: 0.98, green: 0.80, blue: 0.32))
                        .blur(radius: 6)
                        .padding(-1)
                        .opacity(gilded && !orbOut ? 0.5 : 0)
                        .animation(orbOut ? .easeOut(duration: 0.35)
                                          : .easeInOut(duration: 2.8).delay(0.3),
                                   value: orbOut)

                    // Non-gilded surface: Platinum plaque (Classic) or Liquid
                    // Glass capsule (otherwise). Fades OUT as the gild comes in.
                    Group {
                        if classic {
                            shape.fill(AppTheme.platinumFace)
                                .overlay(shape.inset(by: 0.6).stroke(Self.platinumEdge, lineWidth: 1.4))
                                .overlay(shape.stroke(AppTheme.platinumFrame.opacity(0.65), lineWidth: 1))
                        } else {
                            Color.clear.glassEffect(.regular, in: shape)
                        }
                    }
                    .opacity(gilded ? 0 : 1)

                    // Gilded solid dark chip so the platinum text reads. Fades IN
                    // behind the content.
                    shape.fill(Self.gildedDark)
                        .opacity(gilded ? 1 : 0)
                }
            }
            .overlay {
                if gilded {
                    // A slowly rotating angular gold rim — edge-only (strokeBorder),
                    // so it sits AROUND the content and never over the aperture or
                    // wordmark. Driven by TimelineView off the clock so it never
                    // stops; fades in with the gild via `.transition`.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let angle = (t.truncatingRemainder(dividingBy: 7) / 7) * 360
                        shape.strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: Self.goldRing),
                                center: .center,
                                angle: .degrees(angle)
                            ),
                            lineWidth: 1.8
                        )
                        .opacity(0.95)
                    }
                    .transition(.opacity)
                }
            }
            // Slow, deliberate reveal of the black chip + gold rim when the
            // final egg completes — a ceremonial gild rather than a quick swap.
            .animation(.easeInOut(duration: 3.0), value: gilded)
    }
}
