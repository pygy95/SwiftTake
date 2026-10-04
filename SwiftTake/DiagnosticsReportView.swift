// MARK: - DiagnosticsReportView
//
// The copy-pasteable diagnostics sheet. Presented the moment a capture
// starts (showing a "Capturing…" state) and then filled with the report
// produced by the connected camera's `captureDiagnostics()` (run via
// `QuickTakeSerialManager.runCameraDiagnostics()`). Works for every camera
// family. Styling matches the house aesthetic (WelcomeView / AboutView /
// CameraSelectionView): app-icon header, SF Symbols, system fonts, rounded
// surfaces, and Liquid Glass on macOS 26+.

import SwiftUI

struct DiagnosticsReportView: View {
    /// The finished report, or nil while the capture is still running.
    let report: String?
    /// True while the capture is in flight.
    let isCapturing: Bool
    /// Camera name for the title, e.g. "QuickTake 150".
    let cameraName: String?
    var onClose: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var didCopy = false

    private var title: String {
        if let cameraName, !cameraName.isEmpty { return "\(cameraName) Diagnostics" }
        return "Camera Diagnostics"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let report, !isCapturing {
                reportBody(report)
            } else {
                capturingBody
            }

            Divider()

            actions
        }
        .frame(width: 580, height: 560)
        .background {
            if isClassicTheme { ClassicPinstripe() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: AppTheme.appIcon(classic: isClassicTheme))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.22), radius: 7, x: 0, y: 4)

                Image(systemName: "stethoscope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 6, y: 6)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(isClassicTheme ? .classic(18, weight: .bold) : .system(size: 20, weight: .semibold))

                Text(isCapturing
                     ? "Talking to the camera and recording its responses…"
                     : "Copy this and send it back so camera support can be improved from real device bytes.")
                    .font(isClassicTheme ? Font.classic(12) : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 26)
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
    }

    // MARK: Capturing state

    private var capturingBody: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Capturing diagnostics…")
                .font(isClassicTheme ? Font.classic(12) : .callout)
                .foregroundStyle(.secondary)
            Text("This can take up to a minute while every command is exercised.")
                .font(isClassicTheme ? Font.classic(11) : .caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Report body

    private func reportBody(_ report: String) -> some View {
        let scroll = ScrollView {
            Text(report)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(isClassicTheme ? AppTheme.platinumText : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }

        return Group {
            if isClassicTheme {
                scroll
                    .background(AppTheme.platinumFace)
                    .classicBevel(sunken: true, cornerRadius: 4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                scroll
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                copyToClipboard()
            } label: {
                Label(didCopy ? "Copied" : "Copy to Clipboard",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .modifier(PrimaryButtonModifier())
            .disabled(report == nil || isCapturing)

            Button {
                onClose()
            } label: {
                Text(isCapturing ? "Hide" : "Close")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .modifier(SecondaryButtonModifier())
        }
        .padding(16)
    }

    private func copyToClipboard() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        withAnimation { didCopy = true }
    }
}
