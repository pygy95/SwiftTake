// MARK: - AnimatedButtonStyles
//
// Reusable SwiftUI `ButtonStyle` for tactile feedback on press:
//
//   - `PressableScaleButtonStyle` — scales the button slightly and
//     dims the shadow on press; springs back when released. Used on
//     prominent action buttons (Connect, Take Picture, etc.).
//
// Animations stay short and snappy (~0.2 s springs) so the UI feels
// responsive rather than bouncy.

import SwiftUI

struct PressableScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var pressedOpacity: Double = 0.92
    var shadowRadius: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Reduce Motion: no scale (that's the "lift"), a plain dim answers
            // for press feedback instead.
            .scaleEffect(!reduceMotion && configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.10 : 0.16),
                radius: configuration.isPressed ? shadowRadius * 0.55 : shadowRadius,
                x: 0,
                y: configuration.isPressed ? 2 : 5
            )
            .animation(reduceMotion ? .easeInOut(duration: 0.1)
                                    : .spring(response: 0.22, dampingFraction: 0.78),
                       value: configuration.isPressed)
    }
}
