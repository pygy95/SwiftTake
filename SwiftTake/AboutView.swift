// MARK: - AboutView
//
// Custom "About SwiftTake" window. Replaces the macOS standard
// fixed-size About panel so the prose and feature list render in full
// without truncation. Opened via Menu Bar → SwiftTake → About SwiftTake
// (which fires `openWindow(id: "aboutWindow")` registered in
// SwiftTakeApp).
//
// Style follows Apple's About-window conventions:
//   - Centered app icon, name, version
//   - One short tagline beneath
//   - A simple feature list (one row per feature, no bullets)
//   - Quiet copyright footer

import SwiftUI

struct AboutView: View {
    @Environment(\.isClassicTheme) private var isClassicTheme

    private let features: [(symbol: String, label: String)] = [
        ("bolt.fill",          "Native Apple silicon performance"),
        ("paintbrush.fill",    "Designed for macOS"),
        ("camera.aperture",    "Live camera controls and remote shutter"),
        ("photo.stack",        "Live gallery with QuickLook preview"),
        ("rectangle.stack.fill",
                               "TIFF, PNG, BMP, JPEG, and HEIC export"),
        ("sparkles",           "Refined Vintage and NewTake looks"),
        ("link",               "Works with Fujifilm sibling cameras"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: AppTheme.appIcon(classic: isClassicTheme))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)

                // The app name stands alone; Finder's Get Info reads the
                // marketing version from the bundle's Info.plist.
                if isClassicTheme {
                    Text("SwiftTake")
                        .font(.classic(28, weight: .bold))
                        .foregroundStyle(AppTheme.platinumText)
                } else {
                    Text("SwiftTake")
                        .font(.title.weight(.semibold))
                }

                // Centered in BOTH themes: multilineTextAlignment centres
                // the wrapped lines within the text block, and the
                // max-width frame centres the block itself — without it
                // the wrap rendered ragged-left. Shared Text, so Classic
                // and Regular can't drift apart (only the font differs).
                Text("A Mac companion for the Apple QuickTake and its cousin cameras from Fujifilm.")
                    .font(isClassicTheme ? .classic(13) : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Never truncate — wrap to as many lines as needed
                    // (Charcoal runs wider than the system face).
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 36)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 36)

            // Feature list — sized to its longest row, then horizontally
            // centred in the window so the block reads as a unit instead
            // of hugging the left edge with empty space on the right.
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(features, id: \.label) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .frame(width: 20)
                            Text(item.label)
                                .font(isClassicTheme ? .classic(12) : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)

            VStack(spacing: 6) {
                Text("Built with care for vintage Apple hardware.")
                    .font(isClassicTheme ? .classic(11) : .footnote)
                    .foregroundStyle(.tertiary)
                Text("Not affiliated with or endorsed by Apple Inc. QuickTake is a trademark of Apple Inc.")
                    .font(isClassicTheme ? .classic(10) : .caption2)
                    .foregroundStyle(.tertiary)
                    // Wrap instead of truncating: measured single-line, this
                    // line runs past the window and clips mid-word.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 36)
            .padding(.bottom, 22)
        }
        // Fixed width; HEIGHT FOLLOWS CONTENT. A hard 600 pt height clipped
        // the tagline in Classic — Charcoal sets taller and wider than the
        // system face, and a fixed-height stack truncates instead of growing,
        // running the tagline off the window unreadably. The window
        // scene is .contentSize-resizable, so it simply fits either theme.
        .frame(width: 460)
        .background {
            if isClassicTheme {
                ClassicPinstripe().ignoresSafeArea()
            }
        }
    }
}
