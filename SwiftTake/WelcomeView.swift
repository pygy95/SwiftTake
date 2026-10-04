// MARK: - WelcomeView
//
// First-launch onboarding sheet. Shown once, gated by
// `@AppStorage(PrefKey.hasSeenWelcome)` in `ContentView`. A single-page
// introduction: app icon, name, tagline, a short list of what the app
// does, and one primary action button.
//
// Visual conventions match `AboutView` (same icon size, same feature-row
// treatment: symbol on the left in tint colour, title and dim
// description on the right) so the two windows read as siblings.
//
// `onDismiss` fires when the user clicks Continue; the parent uses it to
// set `hasSeenWelcome = true` so the sheet doesn't show again.

import SwiftUI

struct WelcomeView: View {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var isAnimating = false

    /// What the app does, in three rows. Same tone and length as the
    /// About window's feature list — short noun-style title + a
    /// single-sentence description in `.secondary`.
    private let features: [(icon: String, title: String, description: String)] = [
        (
            "cable.connector",
            "Connect",
            "Plug your QuickTake into your Mac through a serial adapter and pair it in one click."
        ),
        (
            "photo.stack",
            "Browse & Import",
            "Thumbnails of every photo on the camera. Import the ones you want straight to your Mac."
        ),
        (
            "camera.viewfinder",
            "Control",
            "Take photos remotely, adjust flash and quality, manage the camera — all from your desk."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header — actual app icon (not an SF Symbol). We pull the
            // icon from `NSApp.applicationIconImage` so it tracks the
            // bundle's real icon at every size, including any future
            // refresh of AppIcon.appiconset.
            VStack(spacing: 18) {
                Image(nsImage: AppTheme.appIcon(classic: isClassicTheme))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
                    .scaleEffect(isAnimating ? 1.0 : 0.86)
                    .opacity(isAnimating ? 1.0 : 0)
                    .animation(.spring(response: 0.7, dampingFraction: 0.78), value: isAnimating)

                VStack(spacing: 6) {
                    if isClassicTheme {
                        Text("Welcome to SwiftTake")
                            .font(.classic(26, weight: .bold))
                            .foregroundStyle(AppTheme.platinumText)
                    } else {
                        Text("Welcome to SwiftTake")
                            .font(.system(size: 26, weight: .semibold))
                    }

                    Text("A Mac companion for the Apple QuickTake camera.")
                        .font(isClassicTheme ? .classic(13) : .body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .opacity(isAnimating ? 1.0 : 0)
                .offset(y: isAnimating ? 0 : 8)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: isAnimating)
            }
            .padding(.top, 46)
            .padding(.bottom, 30)

            Divider()
                .padding(.horizontal, 40)

            // Feature list — sized to its longest row, then horizontally
            // centred so the block reads as a unit instead of hugging
            // the left edge with empty space on the right. Same pattern
            // as `AboutView`.
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(features.enumerated()), id: \.offset) { idx, feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.icon)
                                .font(.title3.weight(.regular))
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)
                                Text(feature.description)
                                    .font(isClassicTheme ? .classic(12) : .callout)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .opacity(isAnimating ? 1.0 : 0)
                        .offset(y: isAnimating ? 0 : 10)
                        .animation(
                            .easeOut(duration: 0.45).delay(0.25 + Double(idx) * 0.08),
                            value: isAnimating
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 24)

            Spacer(minLength: 0)

            // Continue button — primary action. `.glassProminent` adopts
            // the macOS 26 Liquid Glass treatment when available;
            // `.borderedProminent` is the fallback.
            Group {
                if isClassicTheme {
                    Button {
                        isPresented = false
                        onDismiss()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(ClassicButtonStyle(prominent: true))
                } else {
                    Button {
                        isPresented = false
                        onDismiss()
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .modifier(WelcomeButtonModifier())
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
            .opacity(isAnimating ? 1.0 : 0)
            .animation(.easeOut(duration: 0.45).delay(0.55), value: isAnimating)
        }
        // Window sized to fit the icon, header, three feature rows
        // and the button without scrolling on any common display.
        .frame(width: 540, height: 600)
        .background {
            if isClassicTheme {
                ClassicPinstripe().ignoresSafeArea()
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

private struct WelcomeButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
