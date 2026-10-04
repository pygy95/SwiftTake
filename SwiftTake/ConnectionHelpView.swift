// MARK: - ConnectionHelpView
//
// Help sheet that walks the user through connecting a QuickTake camera
// to a modern Mac: cable type (avoid CH340-based adapters), pin
// compatibility, baud rate, and what to do if the camera doesn't respond.
//
// Shown as a `.sheet` from the sidebar when the user taps the "?" next to
// the connection state. Static content; no manager state.

import SwiftUI

struct ConnectionHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connection Help", systemImage: "questionmark.circle")
                    .font(isClassicTheme ? Font.classic(18, weight: .bold) : .title2.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 12) {
                helpRow(
                    icon: "power",
                    title: "Plug in first, then power on",
                    detail: "Connect the cable before turning the QuickTake on. The camera announces its exact model as it wakes, and SwiftTake listens for that announcement — a sleeping camera is woken automatically when you hit Connect."
                )
                helpRow(
                    icon: "cable.connector",
                    title: "Use a supported adapter",
                    detail: "Adapters that appear on macOS as usbserial, wchusbserial, usbmodem, or similar USB serial names are detected automatically. Prolific adapters also need the PL2303 Serial driver app.",
                    linkURL: "https://apps.apple.com/au/app/pl2303-serial/id1624835354?mt=12",
                    linkText: "Get PL2303 Serial"
                )
                helpRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Retry cleanly",
                    detail: "If connecting or importing fails, unplug and reconnect the adapter, power-cycle the camera if needed, then try Connect again."
                )
                helpRow(
                    icon: "timer",
                    title: "Wait for transfers",
                    detail: "Large downloads are read in full before SwiftTake gives up, so an import may pause briefly before reporting a timeout."
                )
                helpRow(
                    icon: "battery.25",
                    title: "Check power and cabling",
                    detail: "If a timeout still happens, check the camera's battery level, the serial wiring, and the adapter connection."
                )
                helpRow(
                    icon: "questionmark.diamond",
                    title: "Which QuickTake do you have?",
                    detail: "The QuickTake 100 and 150 (Kodak-built) use a mini-DIN-8 serial cable. The QuickTake 200 (a rebadged Fujifilm DS-7) uses a 2.5 mm stereo miniplug and a different serial protocol. All three are supported — see SwiftTake Help for a QuickTake 200 walkthrough."
                )
            }
            .padding(18)
            .modifier(HelpGlassCardModifier())

            HStack {
                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .modifier(PrimaryButtonModifier())
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func helpRow(icon: String, title: String, detail: String, linkURL: String? = nil, linkText: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(.primary)
                .background(.tertiary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)

                Text(detail)
                    .font(isClassicTheme ? Font.classic(12) : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let urlStr = linkURL, let text = linkText, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        if isClassicTheme {
                            // Platinum push button — no modern blue pill in
                            // Classic (matches this same link's treatment in
                            // HelpWindowView's adapter section).
                            Label(text, systemImage: "arrow.down.app.fill")
                                .font(.classic(11, weight: .semibold))
                                .foregroundStyle(AppTheme.platinumText)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 12)
                                .classicBevel(cornerRadius: 5)
                        } else {
                            Label(text, systemImage: "arrow.down.app.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96, pressedOpacity: 0.9, shadowRadius: 2))
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct HelpGlassCardModifier: ViewModifier {
    @Environment(\.isClassicTheme) private var isClassicTheme

    func body(content: Content) -> some View {
        if isClassicTheme {
            content.classicBevel(cornerRadius: 6)
        } else if #available(macOS 26.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
