// MARK: - CameraSelectionView
//
// The "Which camera is this?" prompt. Shown by `ContentView` when
// auto-detection (in `QuickTakeSerialManager.connectToDetectedCamera`)
// identifies the protocol family but can't pin the exact model (e.g. a
// Fuji-family camera that could be a QuickTake 200, a Fujifilm DS-7, or a
// Samsung Kenox), or when nothing answered and the user wants to choose
// manually.
//
// Visual conventions match `WelcomeView` / `AboutView`: the app icon up
// top, a short headline, then a vertical list of candidate rows (icon,
// title, one-line description) and a primary glass action button. The
// selected row is tinted with the accent colour.

import SwiftUI

struct CameraSelectionView: View {
    /// The models to offer. Passed in by the parent from
    /// `serialManager.pendingCameraSelection`.
    let candidates: [QuickTakeModel]
    var onConfirm: (QuickTakeModel) -> Void
    var onCancel: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var selection: QuickTakeModel?
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — actual app icon, mirroring WelcomeView.
            VStack(spacing: 14) {
                Image(nsImage: AppTheme.appIcon(classic: isClassicTheme))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)

                VStack(spacing: 6) {
                    Text("Which camera is this?")
                        .font(isClassicTheme ? .classic(19, weight: .bold) : .system(size: 22, weight: .semibold))

                    Text(subtitle)
                        .font(isClassicTheme ? Font.classic(12) : .callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 36)
            .padding(.horizontal, 36)
            .padding(.bottom, 22)

            Divider()
                .padding(.horizontal, 32)

            // Candidate rows.
            VStack(spacing: 10) {
                ForEach(candidates) { model in
                    candidateRow(model)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Spacer(minLength: 0)

            // Actions.
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .modifier(SecondaryButtonModifier())

                Button {
                    if let selection { onConfirm(selection) }
                } label: {
                    Text("Connect")
                        .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .modifier(PrimaryButtonModifier())
                .disabled(selection == nil)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 460)
        .frame(minHeight: 420)
        .background {
            if isClassicTheme { ClassicPinstripe() }
        }
        .onAppear {
            // Default to the first candidate so Connect is reachable in one
            // click for the common "yes, the obvious one" case.
            if selection == nil { selection = candidates.first }
            isAnimating = true
        }
    }

    private var subtitle: String {
        if candidates.count <= 1 {
            return "SwiftTake connected to a camera but couldn't confirm the model. Pick the one that's plugged in."
        }
        return "A few models share this connection. Pick the one that's plugged in so photos decode correctly."
    }

    @ViewBuilder
    private func candidateRow(_ model: QuickTakeModel) -> some View {
        let isSelected = selection == model
        Button {
            selection = model
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(rowAccent(isSelected: isSelected))
                    .frame(width: 26)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(isClassicTheme ? .classic(13, weight: .bold) : .headline)
                        .foregroundStyle(isClassicTheme ? AppTheme.platinumText : .primary)
                    Text(Self.blurb(for: model))
                        .font(isClassicTheme ? Font.classic(11) : .caption)
                        .foregroundStyle(isClassicTheme ? AppTheme.platinumText.opacity(0.7) : .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(rowAccent(isSelected: isSelected))
                    .padding(.top, 1)
            }
            .padding(12)
            .modifier(CandidateRowSurface(isClassic: isClassicTheme, isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: isClassicTheme ? 6 : 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func rowAccent(isSelected: Bool) -> Color {
        if isClassicTheme {
            return isSelected ? AppTheme.classicAccent : AppTheme.platinumText.opacity(0.35)
        }
        return isSelected ? Color.accentColor : Color.secondary.opacity(0.4)
    }

    /// A short, model-specific one-liner for the row, noting the family
    /// relationships (the QT200 is a rebadged DS-7, etc.).
    private static func blurb(for model: QuickTakeModel) -> String {
        switch model {
        case .qt100:          return "Apple's 1994 fixed-focus QuickTake (Kodak-built)."
        case .qt150:          return "Apple's 1995 QuickTake — adds standard/high quality."
        case .qt200:          return "Apple's 1997 QuickTake — a rebadged Fujifilm DS-7, JPEG on SmartMedia."
        case .fujiDS7:        return "Fujifilm's 1996 DS-7 — the QuickTake 200's twin."
        case .samsungSSC350N: return "Samsung Kenox SSC-350N — same Fujifilm DS-7 family."
        }
    }
}

/// Candidate row surface — a raised Platinum bevel in Classic, otherwise the
/// rounded translucent card used elsewhere in the house aesthetic.
private struct CandidateRowSurface: ViewModifier {
    var isClassic: Bool
    var isSelected: Bool
    func body(content: Content) -> some View {
        if isClassic {
            content
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? AppTheme.classicAccent.opacity(0.18) : Color.clear)
                )
                .classicBevel(cornerRadius: 6)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }
}
