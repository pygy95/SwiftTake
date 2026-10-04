import SwiftUI

/// One in-flight sparkle particle. The angle drives a deterministic
/// fan-out direction so each tap looks like a spray, not a clump.
private struct Sparkle: Identifiable {
    let id = UUID()
    let angle: Double          // radians, direction of travel
    let distance: CGFloat      // how far it drifts before fading
    let size: CGFloat          // glyph point size
    let lifetime: Double       // seconds to live
}

/// HQ quality badge with a small bounce + gold-dust easter egg on tap.
///
/// On click:
///   1. The "HQ" text does a quick scale bounce (1.0 → 1.35 → 1.0).
///   2. Six gold-tinted sparkle glyphs spray outward from the badge,
///      fading and rotating as they travel a short distance, then vanish.
///
/// SQ uses a plain Text view in `ContentView` and has no easter egg —
/// the gold-dust effect is HQ's reward for being High Quality.
struct HQBadgeView: View {
    @State private var bounce: CGFloat = 1.0
    @State private var sparkles: [Sparkle] = []
    // Base size matches the SQ badge; scales with Dynamic Type while staying
    // pixel-identical at the default text size.
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 9

    var body: some View {
        Text("HQ")
            .font(.system(size: badgeSize, weight: .bold, design: .rounded))
            .foregroundColor(.orange)
            .scaleEffect(bounce)
            // Sparkles drawn on top, anchored to the badge centre.
            .overlay(
                ZStack {
                    ForEach(sparkles) { sparkle in
                        SparkleView(sparkle: sparkle)
                    }
                }
                .allowsHitTesting(false),
                alignment: .center
            )
            .contentShape(Rectangle())
            .onTapGesture {
                triggerEasterEgg()
            }
            .transition(.asymmetric(
                insertion: .scale.combined(with: .opacity).animation(.spring().delay(0.05)),
                removal: .opacity
            ))
            .accessibilityLabel("High Quality")
            .accessibilityHint("Double-tap for a sparkle effect")
            .accessibilityAddTraits(.isButton)
    }

    private func triggerEasterEgg() {
        // 1. Bounce the badge text.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
            bounce = 1.35
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
                bounce = 1.0
            }
        }

        // 2. Spawn 6 sparkles fanned around the badge with a touch of jitter
        // so two consecutive taps don't look identical.
        let count = 6
        let spawn: [Sparkle] = (0..<count).map { i in
            let baseAngle = (Double(i) / Double(count)) * 2 * .pi
            let jitter = Double.random(in: -0.35...0.35)
            return Sparkle(
                angle: baseAngle + jitter,
                distance: CGFloat.random(in: 14...22),
                size: CGFloat.random(in: 7...11),
                lifetime: Double.random(in: 0.55...0.85)
            )
        }
        sparkles.append(contentsOf: spawn)

        // 3. Garbage-collect once the longest-lived sparkle has finished.
        let maxLife = spawn.map(\.lifetime).max() ?? 0.85
        let toRemove = Set(spawn.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((maxLife + 0.05) * 1_000_000_000))
            sparkles.removeAll { toRemove.contains($0.id) }
        }
    }
}

/// Single sparkle particle. Animates from spawn (centred on the badge,
/// fully opaque) to its `distance` offset along `angle`, fading and
/// rotating as it travels. `onAppear` kicks the animation off — SwiftUI
/// then handles the rest declaratively until the parent removes it.
private struct SparkleView: View {
    let sparkle: Sparkle

    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 1.0
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: sparkle.size, weight: .bold))
            .foregroundStyle(
                // Warm gold gradient — lighter at the top so the dust
                // reads as glowing light, not painted icon.
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.92, blue: 0.55),
                             Color(red: 1.0, green: 0.78, blue: 0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: Color.orange.opacity(0.55), radius: 2, x: 0, y: 0)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .onAppear {
                let dx = cos(sparkle.angle) * sparkle.distance
                let dy = sin(sparkle.angle) * sparkle.distance
                withAnimation(.easeOut(duration: sparkle.lifetime)) {
                    offset = CGSize(width: dx, height: dy)
                    opacity = 0
                    rotation = Double.random(in: -180...180)
                }
            }
    }
}
