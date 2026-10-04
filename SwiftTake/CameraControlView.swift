// MARK: - CameraControlView
//
// The camera-control panel: take picture, flash mode, quality (HQ/SQ),
// self-timer countdown, capture progress. Renders inline in the sidebar
// by default, but can detach into its own NSWindow (driven by
// `serialManager.isCameraControlPoppedOut`).
//
// `isInline` selects the layout: compact spacing for the sidebar, more
// generous padding for the popped-out window.
//
// All actions defer to `QuickTakeSerialManager` (`takePicture`,
// `setFlashMode`, `setQualityMode`); this view is purely presentation.

import SwiftUI

struct CameraControlView: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.isClassicTheme) private var isClassicTheme
    var isInline: Bool = false

    // Layout sizing for the dedicated window
    private let windowWidth: CGFloat = 260
    private let windowHeight: CGFloat = 250
    private let lcdHeight: CGFloat = 160
    private let cornerButtonSize: CGFloat = 44
    @State private var isVisible = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 8) {
            // LCD Panel with glass control buttons overlaid at corners
            ZStack {
                // LCD Background
                if isClassicTheme {
                    // Sunken Platinum well in place of the LCD glass readout.
                    Color.clear
                        .classicBevel(sunken: true, cornerRadius: 6)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.65, green: 0.70, blue: 0.60))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.4), lineWidth: 3)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        .innerShadow(color: .black.opacity(0.2), radius: 5)
                }

                // LCD Content + overlaid glass control buttons
                if let metadata = serialManager.metadata {
                    // Counter display (centered)
                    if let countdown = serialManager.countdownTimer {
                        Text("\(countdown)")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundColor(.black.opacity(0.85))
                            .contentTransition(.numericText())
                    } else {
                        VStack(spacing: 2) {
                            HStack(alignment: .lastTextBaseline, spacing: 8) {
                                VStack(alignment: .trailing, spacing: -4) {
                                    Text("TAKEN")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.black.opacity(0.6))
                                    Text("\(metadata.picturesTaken)")
                                        .font(.system(size: 28, weight: .semibold))
                                        .foregroundColor(.black.opacity(0.85))
                                        .contentTransition(.numericText())
                                }

                                // This LCD panel is Kodak-only (QT100/150),
                                // which always report this; fall back to 0
                                // only to satisfy the optional type.
                                Text("\(metadata.picturesRemaining ?? 0)")
                                    .font(.system(size: 56, weight: .regular))
                                    .foregroundColor(.black.opacity(0.85))
                                    .contentTransition(.numericText())
                            }

                            HStack(spacing: 4) {
                                let battery = metadata.batteryLevel ?? 0
                                Image(systemName: battery > 50 ? "battery.100" : (battery > 20 ? "battery.50" : "battery.25"))
                                Text("\(battery)%")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black.opacity(0.8))
                        }
                    }

                    // Glass control buttons at four corners
                    VStack {
                        HStack {
                            lcdCornerButton(
                                icon: flashIcon(for: metadata.flashMode),
                                label: "Flash",
                                value: metadata.flashMode,
                                action: cycleFlash
                            )
                            Spacer()
                            // Only show the quality toggle for models that can
                            // switch (QT150: HQ/SQ; QT200: Fine/Normal once
                            // wired up). The QT100 is locked to HQ and would
                            // reject the command.
                            if serialManager.selectedModel.supportsQualityToggle {
                                lcdCornerButton(
                                    icon: metadata.isHighQuality ? "checkerboard.rectangle" : "squareshape",
                                    label: "Photo quality",
                                    value: metadata.isHighQuality ? "High quality" : "Standard quality",
                                    action: toggleQuality
                                )
                            }
                        }
                        Spacer()
                        HStack {
                            lcdCornerButton(
                                icon: "xmark.bin.fill",
                                label: "Delete all photos",
                                action: { showingDeleteConfirmation = true },
                                disabled: serialManager.isBusy || (serialManager.metadata?.picturesTaken ?? 0) == 0
                            )
                            Spacer()
                            timerButton
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("--")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.3))
                }
            }
            .frame(height: lcdHeight)

            // Shutter Button (directly under LCD with small gap)
            Button(action: {
                serialManager.takePicture()
            }) {
                HStack {
                    Image(systemName: "camera.shutter.button.fill")
                        .font(.title3)
                    Text("Take Picture")
                        .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .modifier(ShutterButtonModifier(isReady: serialManager.isConnected && !serialManager.isBusy))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .disabled(!serialManager.isConnected || serialManager.isBusy || (serialManager.metadata?.picturesRemaining == 0))

            // Capture progress bar (90s Apple rainbow colors)
            if let progress = serialManager.captureProgress {
                captureProgressBar(progress: progress)
                    .transition(.opacity)
            }
        }
        .padding(isInline ? 0 : 16)
        .frame(width: isInline ? nil : windowWidth, height: isInline ? nil : windowHeight)
        .frame(maxWidth: isInline ? .infinity : nil)
        // The self-timer countdown is shown by the 64-pt LCD digit and the
        // timer button's count badge (`timerButton`). Do not add a full-panel
        // spinner overlay when `countdownTimer != nil`: it covers both of
        // those, leaving a generic spinner instead of a visible countdown.
        .background {
            if isInline {
                Color.clear
            } else if isClassicTheme {
                ClassicPinstripe()
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }

        .scaleEffect(isVisible ? 1.0 : 0.8)
        .opacity(isVisible ? 1.0 : 0)
        .animation(.easeInOut(duration: 0.3), value: serialManager.captureProgress != nil)
        .alert("Delete All Photos?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All Photos", role: .destructive) {
                serialManager.deleteImages()
            }
        } message: {
            Text("This permanently deletes every photo on the camera. You can't undo this.")
        }
        .onAppear {
            if !isInline {
                serialManager.isCameraControlPoppedOut = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                isVisible = true
            }
        }
        .onDisappear {
            if !isInline {
                serialManager.isCameraControlPoppedOut = false
            }
        }
    }

    @ViewBuilder
    private func lcdCornerButton(icon: String, label: String, value: String = "", action: @escaping () -> Void, disabled: Bool = false) -> some View {
        if isClassicTheme {
            Button(action: action) {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.classic(15, weight: .bold))
                    .foregroundStyle(AppTheme.platinumText.opacity(disabled ? 0.35 : 1))
                    .frame(width: cornerButtonSize, height: cornerButtonSize)
                    .classicBevel(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .disabled(disabled || !serialManager.isConnected)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        } else {
            Button(action: action) {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.black.opacity(disabled ? 0.3 : 0.8))
                    .frame(width: cornerButtonSize, height: cornerButtonSize)
                    .background {
                        Circle().fill(Color.white.opacity(0.35))
                        Circle().fill(.regularMaterial)
                    }
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92, pressedOpacity: 0.85, shadowRadius: 2))
            .disabled(disabled || !serialManager.isConnected)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }

    // Not `@ViewBuilder`: both branches already `return AnyView(...)`, which disables it anyway.
    private var timerButton: some View {
        let disabled = serialManager.isBusy || (serialManager.metadata?.picturesRemaining == 0)
        let isCountingDown = serialManager.countdownTimer != nil

        if isClassicTheme {
            return AnyView(
                Button(action: { serialManager.takePictureWithTimer() }) {
                    Group {
                        if let count = serialManager.countdownTimer, count <= 9 {
                            Image(systemName: "\(count).circle.fill")
                                .symbolRenderingMode(.monochrome)
                                .font(.classic(15, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        } else if let count = serialManager.countdownTimer, count == 10 {
                            Text("10")
                                .font(.classic(13, weight: .bold))
                                .contentTransition(.numericText())
                        } else {
                            Image(systemName: "timer")
                                .symbolRenderingMode(.monochrome)
                                .font(.classic(15, weight: .bold))
                        }
                    }
                    .foregroundStyle(AppTheme.platinumText.opacity(disabled ? 0.35 : 1))
                    .frame(width: cornerButtonSize, height: cornerButtonSize)
                    .classicBevel(cornerRadius: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.classicAccent, lineWidth: isCountingDown ? 2 : 0)
                    )
                    .animation(.easeInOut(duration: 0.3), value: serialManager.countdownTimer)
                }
                .buttonStyle(.plain)
                .disabled(disabled || !serialManager.isConnected || isCountingDown)
                .accessibilityLabel("Self-timer")
                .accessibilityValue(isCountingDown ? "Counting down" : "Take photo after a delay")
            )
        }

        return AnyView(Button(action: { serialManager.takePictureWithTimer() }) {
            Group {
                if let count = serialManager.countdownTimer, count <= 9 {
                    Image(systemName: "\(count).circle.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 18, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                } else if let count = serialManager.countdownTimer, count == 10 {
                    Text("10")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: "timer")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .foregroundStyle(Color.black.opacity(disabled ? 0.3 : (isCountingDown ? 1.0 : 0.8)))
            .frame(width: cornerButtonSize, height: cornerButtonSize)
            .background {
                Circle().fill(Color.white.opacity(0.35))
                Circle().fill(.regularMaterial)
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(isCountingDown ? Color.orange.opacity(0.6) : Color.white.opacity(0.4), lineWidth: isCountingDown ? 2 : 1))
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.3), value: serialManager.countdownTimer)
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92, pressedOpacity: 0.85, shadowRadius: 2))
        .disabled(disabled || !serialManager.isConnected || isCountingDown)
        .accessibilityLabel("Self-timer")
        .accessibilityValue(isCountingDown ? "Counting down" : "Take photo after a delay"))
    }

    private func flashIcon(for mode: String) -> String {
        switch mode {
        case "Auto": return "bolt.badge.a.fill"
        case "Forced": return "bolt.fill"
        case "Disabled": return "bolt.slash.fill"
        default: return "bolt.trianglebadge.exclamationmark.fill"
        }
    }

    private func cycleFlash() {
        guard let metadata = serialManager.metadata else { return }

        let nextMode: UInt8
        switch metadata.flashMode {
        case "Auto":
            nextMode = 2 // Auto -> Forced
        case "Forced":
            nextMode = 1 // Forced -> Disabled
        case "Disabled":
            nextMode = 0 // Disabled -> Auto
        default:
            nextMode = 0
        }

        serialManager.setFlashMode(mode: nextMode)
    }

    private func toggleQuality() {
        guard let metadata = serialManager.metadata else { return }
        serialManager.setQualityMode(highQuality: !metadata.isHighQuality)
    }

    private func captureProgressBar(progress: Double) -> some View {
        let apple90sGradient = LinearGradient(
            stops: [
                .init(color: Color(red: 0.38, green: 0.73, blue: 0.28), location: 0.0),
                .init(color: Color(red: 0.96, green: 0.76, blue: 0.17), location: 0.2),
                .init(color: Color(red: 0.94, green: 0.52, blue: 0.16), location: 0.4),
                .init(color: Color(red: 0.88, green: 0.21, blue: 0.26), location: 0.6),
                .init(color: Color(red: 0.58, green: 0.24, blue: 0.59), location: 0.8),
                .init(color: Color(red: 0.00, green: 0.58, blue: 0.84), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 3)
                    .fill(apple90sGradient)
                    .frame(width: geo.size.width * progress, height: 4)
                    .animation(.spring(), value: progress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 4)
    }
}

private struct ShutterButtonModifier: ViewModifier {
    let isReady: Bool
    @Environment(\.isClassicTheme) private var isClassicTheme

    func body(content: Content) -> some View {
        if isClassicTheme {
            // Square OS 9 bevel button (matching the Settings sidebar), with
            // the default-button ring while the camera is ready.
            content
                .buttonStyle(ClassicSquareButtonStyle(prominent: isReady))
        } else if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(isReady ? .accentColor : .secondary)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isReady ? Color.accentColor : Color.secondary.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
                .shadow(color: isReady ? Color.accentColor.opacity(0.5) : .clear, radius: 10)
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.965, pressedOpacity: 0.96, shadowRadius: 12))
        }
    }
}

// Inner Shadow Extension for LCD screen
extension View {
    func innerShadow(color: Color, radius: CGFloat = 0.1) -> some View {
        modifier(InnerShadow(color: color, radius: radius))
    }
}

private struct InnerShadow: ViewModifier {
    var color: Color = .black
    var radius: CGFloat = 0.1

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color, lineWidth: radius)
                .blur(radius: radius)
                .mask(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(gradient: Gradient(colors: [Color.black, Color.clear]), startPoint: .top, endPoint: .bottom))
                )
        )
    }
}
