// MARK: - SettingsView
//
// Multi-pane Settings window (Cmd+,):
//
//   - General     theme, hardware model, save locations, reset
//   - Camera      name, date/time, metadata refresh
//   - Image       look, export format, original files, date stamp
//   - Connection  serial baud rate, port detection
//
// All controls bind into the shared `QuickTakeSerialManager` via
// `@EnvironmentObject`.

import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case camera = "Camera"
    case image = "Image"
    case connection = "Connection"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .camera: return "camera.fill"
        case .image: return "photo.fill"
        case .connection: return "cable.connector"
        case .shortcuts: return "keyboard.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .camera: return .orange
        case .image: return .blue
        case .connection: return .green
        case .shortcuts: return .indigo
        }
    }
}

// MARK: - Deep links

/// Lets menu commands land the Settings window on a specific pane.
/// `SettingsPane` is private to this file, so callers go through the named
/// requests below. A request is stashed for the freshly-opened-window case
/// (consumed in `onAppear`) and posted as a notification for the
/// already-open case — whichever fires first clears it.
enum SettingsDeepLink {
    static let notification = Notification.Name("SwiftTake.SettingsDeepLink")
    fileprivate static var pendingPane: SettingsPane?

    /// Open-on-Shortcuts: the Help ▸ Keyboard Shortcuts command (⌘/).
    static func requestShortcuts() {
        pendingPane = .shortcuts
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @AppStorage(PrefKey.appTheme) private var appTheme = AppTheme.system
    @AppStorage(PrefKey.rainbowUnlocked) private var classicUnlocked = false
    @State private var selectedPane: SettingsPane = .general
    @State private var showingConnectionHelp = false
    @Environment(\.openWindow) private var openWindow
    // The Settings scene doesn't reliably receive the injected `isClassicTheme`
    // environment, so derive it from storage (same as HelpWindowView).
    private var isClassicTheme: Bool { appTheme == .classic && classicUnlocked }
    @Namespace private var sidebarNamespace

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 8) {
                Text("SwiftTake")
                    .font(isClassicTheme ? Font.classic(12, weight: .semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(SettingsPane.allCases) { pane in
                    Button(action: {
                        if isClassicTheme {
                            // Classic: a quick, mechanical "push" — no fluid slide.
                            withAnimation(.easeOut(duration: 0.07)) { selectedPane = pane }
                        } else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { selectedPane = pane }
                        }
                    }) {
                        HStack(spacing: 12) {
                            SettingsPaneIcon(systemName: pane.icon, color: pane.iconColor)
                            Text(pane.rawValue)
                                .font(isClassicTheme ? Font.classic(13) : .body)
                                .foregroundStyle(selectedPane == pane ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.7)))
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            ZStack {
                                if isClassicTheme {
                                    // Every pane row is a REAL Platinum push
                                    // button — squared OS 9 corners, not the
                                    // pill; the selected pane is the one held
                                    // pressed-in.
                                    ClassicSquareSurface(pressed: selectedPane == pane)
                                        .overlay {
                                            if selectedPane == pane {
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .fill(AppTheme.classicAccent.opacity(0.12))
                                            }
                                        }
                                } else if selectedPane == pane {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                                        )
                                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                                        .matchedGeometryEffect(id: "SidebarHighlight", in: sidebarNamespace)
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                }

                Spacer()

                Button {
                    openWindow(id: "helpWindow")
                } label: {
                    HStack(spacing: 12) {
                        SettingsPaneIcon(systemName: "questionmark.circle.fill", color: .purple)
                        Text("Help")
                            .font(isClassicTheme ? Font.classic(13) : .body)
                            .foregroundStyle(.primary.opacity(0.7))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    // Same bank of squared Platinum buttons as the pane rows.
                    .background {
                        if isClassicTheme { ClassicSquareSurface() }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
            .frame(width: 220)
            .background(isClassicTheme
                        ? AnyShapeStyle(AppTheme.platinumFace)
                        : AnyShapeStyle(Color(NSColor.windowBackgroundColor).opacity(0.5)))

            // Divider
            Divider()

            // Detail Area
            VStack(alignment: .leading, spacing: 0) {
                if isClassicTheme {
                    // OS 9 header PLATE: the pane title on a raised Platinum
                    // bar spanning the content — frames the pane (and the
                    // scrollbar below) the way a control panel would.
                    Text(selectedPane.rawValue)
                        .font(.classic(16, weight: .bold))
                        .foregroundStyle(AppTheme.platinumText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .classicBevel(cornerRadius: 3)
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                } else {
                    Text(selectedPane.rawValue)
                        .font(.largeTitle.weight(.bold))
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                        .padding(.bottom, 10)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        switch selectedPane {
                        case .general:
                            GeneralPane(appTheme: $appTheme)
                        case .camera:
                            CameraPane()
                        case .image:
                            ImagePane()
                        case .connection:
                            ConnectionPane(showingHelp: $showingConnectionHelp)
                        case .shortcuts:
                            ShortcutsList()
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                    .id(selectedPane)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: selectedPane)
                }
                .classicScrollbar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, idealWidth: 780, maxWidth: 900,
               minHeight: 520, idealHeight: 580, maxHeight: 720)
        // Classic backdrop for the detail area — every other window wears the
        // pinstripe in Classic; this one alone showed the modern window
        // background behind the Platinum cards. The sidebar's flat platinum
        // fill paints over its own half, so only the detail side shows this.
        .background {
            if isClassicTheme { ClassicPinstripe().ignoresSafeArea() }
        }
        .sheet(isPresented: $showingConnectionHelp) {
            ConnectionHelpView()
        }
        .onAppear(perform: consumeDeepLink)
        .onReceive(NotificationCenter.default.publisher(for: SettingsDeepLink.notification)) { _ in
            consumeDeepLink()
        }
    }

    /// Jump to an externally requested pane (e.g. ⌘/ → Shortcuts). No
    /// animation: the user is arriving, not browsing between panes.
    private func consumeDeepLink() {
        guard let pane = SettingsDeepLink.pendingPane else { return }
        SettingsDeepLink.pendingPane = nil
        selectedPane = pane
    }
}

// MARK: - Sidebar Icon

private struct SettingsPaneIcon: View {
    let systemName: String
    let color: Color
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        if isClassicTheme {
            // Plain dark glyph — the row itself is now a Platinum push button,
            // and a beveled chip ON a beveled button read as clutter. Frame
            // kept so text alignment matches the modern tile exactly.
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.platinumText)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - Premium Glass Components

private struct PremiumGlassCard<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content
    @Environment(\.isClassicTheme) private var classic

    var body: some View {
        // In BOTH themes the explanatory footer renders INSIDE the group's
        // box, under its rows — subtext floating outside the frame reads as
        // belonging to nothing.
        if classic {
            // OS 9 control-panel GROUP BOX: an etched groove frame (shadow
            // hairline with a white highlight offset below-right) on the flat
            // Platinum face, with the section title straddling the top border
            // — not a floating card.
            VStack(spacing: 0) {
                content
                if let footer = footer {
                    Text(footer)
                        .font(.classic(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .offset(x: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(AppTheme.platinumShadow.opacity(0.9), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.classic(12, weight: .bold))
                    .foregroundStyle(AppTheme.platinumText)
                    .padding(.horizontal, 5)
                    .background(AppTheme.platinumFace)   // interrupts the groove
                    .offset(y: -8)
                    .padding(.leading, 8)
            }
            .padding(.top, 8)   // headroom for the straddling title
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Section label, sized to match System Settings group headers.
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, 6)

                // Grouped card holds the controls AND the footer description.
                VStack(spacing: 0) {
                    content
                    if let footer = footer {
                        Text(footer)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                    }
                }
                .background(.regularMaterial)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let showDivider: Bool
    @ViewBuilder let content: Content
    @Environment(\.isClassicTheme) private var isClassicTheme

    init(title: String, subtitle: String? = nil, showDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(isClassicTheme ? Font.classic(13) : .body)
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                    Spacer(minLength: 20)
                    HStack {
                        Spacer()
                        content
                    }
                }
                // Optional explanatory caption under the row (Apple-style footnote),
                // e.g. why a chosen save location can't be used right now.
                if let subtitle {
                    Text(subtitle)
                        .font(isClassicTheme ? Font.classic(11) : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, isClassicTheme ? 12 : 16)
            .padding(.vertical, isClassicTheme ? 9 : 12)

            if showDivider {
                if isClassicTheme {
                    // Etched groove between rows, control-panel style.
                    VStack(spacing: 0) {
                        Rectangle().fill(AppTheme.platinumShadow.opacity(0.55)).frame(height: 1)
                        Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1)
                    }
                    .padding(.horizontal, 8)
                } else {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - General Pane

/// One folder control shared by every save location and appearance theme.
private struct SettingsFolderRow: View {
    @Environment(\.isClassicTheme) private var isClassicTheme
    let title: String
    let destination: URL
    let displayName: String
    let isCustom: Bool
    var warning: String? = nil
    var showDivider = true
    let onChoose: (URL) -> Void
    let onReset: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: warning, showDivider: showDivider) {
            HStack(spacing: 8) {
                Spacer()
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Folder unavailable")
                }
                Text(displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .font(isClassicTheme ? Font.classic(12) : .callout)
                    .help(displayName)
                if isCustom {
                    Button("Use Default", action: onReset)
                        .controlSize(.small)
                        .accessibilityLabel("Use default folder for \(title.lowercased())")
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.title = "Choose \(title) Folder"
                    panel.prompt = "Choose Folder"
                    panel.directoryURL = destination
                    if panel.runModal() == .OK, let url = panel.url { onChoose(url) }
                }
                .controlSize(.small)
                .accessibilityLabel("Choose folder for \(title.lowercased())")
            }
        }
    }
}

private struct GeneralPane: View {
    @Binding var appTheme: AppTheme
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var showingResetConfirmation = false
    /// Unlocked by the status-bubble colour-collection easter egg; reveals the
    /// hidden Classic Platinum theme.
    @AppStorage(PrefKey.rainbowUnlocked) private var classicUnlocked = false
    /// Reveals the Simulator menu and lets the app connect to a demo camera.
    @AppStorage(PrefKey.demoModeEnabled) private var demoModeEnabled = false
    /// Reveals the Developer menu (diagnostics, session trace, test presentations).
    @AppStorage(PrefKey.developerToolsEnabled) private var developerToolsEnabled = false

    /// Hide Classic until it's earned.
    private var availableThemes: [AppTheme] {
        AppTheme.allCases.filter { $0 != .classic || classicUnlocked }
    }

    var body: some View {
        PremiumGlassCard(
            title: "Appearance",
            footer: classicUnlocked
                ? "Choose how SwiftTake looks. Classic is a Mac OS Platinum throwback you unlocked."
                : "Choose how SwiftTake looks. System follows your macOS appearance."
        ) {
            SettingsRow(title: "Theme", showDivider: false) {
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: $appTheme,
                        options: availableThemes.map { ($0, $0.rawValue) })
                } else {
                    Picker("", selection: $appTheme) {
                        ForEach(availableThemes) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }

        PremiumGlassCard(title: "Hardware", footer: hardwareCardFooter) {
            SettingsRow(title: "Camera", showDivider: false) {
                // One row per camera profile: the Fuji family (QT200/DS-7/
                // DS-8/Kenox) and the Kodak DC family each collapse to a
                // single choice. The exact model is auto-detected on connect.
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: cameraProfileBinding,
                        options: CameraProfile.shipping.map { ($0, $0.displayName) })
                        .help(serialManager.selectedModel.profile.blurb)
                } else {
                    Picker("", selection: cameraProfileBinding) {
                        ForEach(CameraProfile.shipping) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help(serialManager.selectedModel.profile.blurb)
                }
            }
        }

        PremiumGlassCard(title: "Save Locations", footer: "These locations apply to future saves. Existing files stay where they are. QTK originals are saved when Keep Original Files is enabled in Image.") {
            SettingsFolderRow(title: "Photos",
                              destination: serialManager.effectiveImportDestinationURL,
                              displayName: serialManager.effectiveImportDestinationDisplayName,
                              isCustom: serialManager.preferredImportDestinationURL != nil,
                              warning: serialManager.importDestinationIsUnreachable
                                ? "This folder isn’t available. New imports use the default SwiftTake folder until it’s back." : nil,
                              onChoose: { _ = serialManager.setPreferredImportDestination($0) },
                              onReset: { serialManager.clearPreferredImportDestination() })
            SettingsFolderRow(title: "Panoramas",
                              destination: serialManager.effectivePanoramaDestinationURL,
                              displayName: serialManager.effectivePanoramaDestinationDisplayName,
                              isCustom: !serialManager.panoramaDestinationIsDefault,
                              warning: serialManager.panoramaDestinationIsUnreachable
                                ? "This folder isn’t available. Reconnect its drive or choose another folder before saving." : nil,
                              onChoose: { _ = serialManager.setPreferredPanoramaDestination($0) },
                              onReset: { serialManager.clearPreferredPanoramaDestination() })
            SettingsFolderRow(title: "QTK Originals",
                              destination: serialManager.effectiveQTKDestinationURL,
                              displayName: serialManager.effectiveQTKDestinationDisplayName,
                              isCustom: !serialManager.qtkDestinationIsDefault,
                              showDivider: false,
                              onChoose: { _ = serialManager.setPreferredQTKDestination($0) },
                              onReset: { serialManager.clearPreferredQTKDestination() })
        }

        PremiumGlassCard(title: "Import", footer: "Choose what happens after an import finishes.") {
            SettingsRow(title: "After Import", showDivider: false) {
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: $serialManager.selectedPostImportAction,
                        options: PostImportAction.allCases.map { ($0, $0.displayName) })
                } else {
                    Picker("", selection: $serialManager.selectedPostImportAction) {
                        ForEach(PostImportAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }

        // Demo mode. Deliberately sits directly under Hardware: the question
        // it answers ("what if I haven't got one of these cameras?") is the
        // one the Hardware picker raises.
        PremiumGlassCard(
            title: "Demo Mode",
            footer: "Try sample photos without a camera. Photo imports are simulated; saved panoramas are real files."
        ) {
            SettingsRow(title: "Simulate a Camera", showDivider: false) {
                Toggle("", isOn: $demoModeEnabled)
                    .labelsHidden()
                    .modifier(ThemedSwitchToggle())
            }
        }

        PremiumGlassCard(
            title: "Developer",
            footer: "Adds a Developer menu with diagnostics and test-presentation commands for internal use."
        ) {
            SettingsRow(title: "Show Developer Menu", showDivider: false) {
                Toggle("", isOn: $developerToolsEnabled)
                    .labelsHidden()
                    .modifier(ThemedSwitchToggle())
            }
        }

        PremiumGlassCard(title: "Reset", footer: "Restore all settings to their defaults and clear cached data. The welcome screen appears the next time you open SwiftTake.") {
            SettingsRow(title: "Reset App", showDivider: false) {
                Button("Reset to Defaults") {
                    showingResetConfirmation = true
                }
                .controlSize(.small)
            }
        }
        .alert("Reset SwiftTake?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                serialManager.resetToDefaults()
            }
        } message: {
            Text("All settings return to their defaults and cached data is cleared. The welcome screen appears the next time you open SwiftTake.")
        }
    }

    /// Short footer for the Hardware card. The longer per-model story lives
    /// in the picker's hover help, keeping the card body quiet.
    private var hardwareCardFooter: String {
        // Mirrors the AboutView tagline so the broader compatibility shows up
        // right where the model is picked. Ends with the reason it matters
        // rather than a blunt warning, in the System Settings style.
        // The Kodak DC and Chinon bodies used to be listed here. They are no
        // longer offered (see CameraProfile.shipping), so promising them
        // under a picker that cannot select them was the text describing an
        // app that no longer exists. The Fuji and Samsung siblings stay: they
        // ARE reachable, as the QuickTake 200 profile.
        "Pick the QuickTake (100, 150, or 200) connected to your Mac. The 200 profile also covers the Fujifilm DS-7 and Samsung Kenox SSC-350N, which share its protocol exactly. Choose the matching model so photos decode correctly."
    }

    /// Bridges the profile picker to the underlying `selectedModel`: reading
    /// maps the current model to its profile; writing adopts the profile's
    /// representative model (the exact sibling is auto-detected on connect).
    private var cameraProfileBinding: Binding<CameraProfile> {
        Binding(
            get: { serialManager.selectedModel.profile },
            set: { serialManager.selectedModel = $0.representativeModel }
        )
    }

}

// MARK: - Camera Pane

private struct CameraPane: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        // Device Management rows (name / date / metadata refresh) are
        // Kodak-only. The QT200 driver exposes no wire commands for
        // camera-name or date-time setting (`QTIC_SETFEATURE` is a no-op
        // for anything the user would change). Show the same card shape
        // with an empty-state explanation so the absent rows make sense.
        if serialManager.selectedModel.supportsCameraControlUI {
            kodakDeviceManagementCard
        } else if serialManager.selectedModel.protocolFamily == .fuji {
            fujiClockCard
        } else {
            unavailableCard
        }
    }

    /// Clock setting in the Fuji family is firmware-dependent. A true Fujifilm
    /// DS-7 / Samsung Kenox honours the native `DATE_SET` (0x86) command, so we
    /// offer the button. The QuickTake 200 NAKs it, and Apple's own driver never
    /// set the clock over serial either (`QTIC_SETFEATURE` is a host-side no-op;
    /// it reads each photo's date from the thumbnail EXIF). So for the QT200 we
    /// explain rather than show a button that can only fail.
    @ViewBuilder
    private var fujiClockCard: some View {
        if serialManager.selectedModel == .qt200 {
            PremiumGlassCard(
                title: "Device Management",
                footer: "The QuickTake 200's firmware doesn't accept a clock-set command over serial; Apple's own software couldn't set it either. If the date is wrong, set it on the camera. Imports are named by each photo's capture date and time, so a correct camera clock keeps those names meaningful."
            ) {
                SettingsRow(title: "Date and Time", showDivider: false) {
                    Text("Set on the camera body")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            PremiumGlassCard(
                title: "Device Management",
                footer: "Imported photos are named by their capture date and time, so set the camera's clock to match your Mac before shooting. The result is reported once it's set."
            ) {
                SettingsRow(title: "Date and Time", showDivider: false) {
                    Button("Set to Computer Date/Time") {
                        serialManager.syncDateAndTime()
                    }
                    .disabled(!serialManager.isConnected || serialManager.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var kodakDeviceManagementCard: some View {
        PremiumGlassCard(title: "Device Management", footer: "Manage metadata and maintenance tasks for the connected QuickTake camera.") {
            SettingsRow(title: "Camera Name") {
                if let metadata = serialManager.metadata {
                    EditableTextField(
                        text: metadata.cameraName,
                        onCommit: { newName in
                            serialManager.setCameraName(newName)
                        }
                    )
                } else {
                    Text("Connect camera to edit")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsRow(title: "Date and Time") {
                Button("Set to Computer Date/Time") {
                    serialManager.syncDateAndTime()
                }
                .disabled(!serialManager.isConnected || serialManager.isBusy)
            }

            SettingsRow(title: "Metadata", showDivider: false) {
                Button("Refresh Camera Info") {
                    serialManager.refreshCameraMetadata()
                }
                .disabled(!serialManager.isConnected || serialManager.isBusy)
            }
        }
    }

    @ViewBuilder
    private var unavailableCard: some View {
        PremiumGlassCard(
            title: "Device Management",
            footer: "Camera name, date and time, and metadata refresh aren't available for the \(serialManager.selectedModel.displayName). The original Apple driver doesn't expose them over serial."
        ) {
            SettingsRow(title: "", showDivider: false) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Not applicable for this model.")
                        .font(isClassicTheme ? Font.classic(12) : .callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Image Pane

private struct ImagePane: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        // Look and output range are INDEPENDENT axes, and the old layout
        // hid that by stacking them as two peer toggles in one card. They
        // read as additive refinements of each other; they are not. Look is
        // a rendering choice that touches every pixel.
        //
        // HDR is no longer a switch at all. It is part of what Enhanced
        // means: Enhanced is the look that pushes highlights above white,
        // so it is the look with something to put in the headroom, and
        // Vintage — faithfulness to a 1995 SDR render — has both the least
        // to gain (about half the above-white content) and the weakest
        // claim to it. See `hdrOutputActive`.
        //
        // Applies to every camera. The QT200 has no Bayer decode to hook
        // into, but the post-process is not Bayer-specific — see
        // FinishedImageLook, which supplies the sRGB curve in place of the
        // Kodak one and calls the very same enhancement.
        //
        // Only the Vintage copy differs, because "vintage" means something
        // different per family: reproducing Apple's 1995 software for the
        // QTK Bayer decode, versus leaving the camera's own 1997 JPEG alone.
        PremiumGlassCard(
                title: "Look",
                footer: {
                    if !serialManager.newTakeEnabled {
                        return serialManager.selectedModel.usesQTKFormat
                            ? "Vintage reproduces the look of Apple's 1995 software as faithfully as the decoder can."
                            : "Vintage keeps the camera's own JPEG exactly as it wrote it."
                    }
                    return serialManager.exportFormat == .heic
                        ? "NewTake lifts the shadows, adds local contrast and a little saturation — and keeps highlights above white, so HDR displays can show them."
                        : "NewTake lifts the shadows, adds local contrast and a little saturation. Export as HEIC to keep highlights above white for HDR displays too."
                }()
            ) {
                SettingsRow(title: "Rendering", showDivider: false) {
                    if isClassicTheme {
                        ClassicPopUpButton(
                            selection: $serialManager.newTakeEnabled,
                            options: [(false, "Vintage"), (true, "NewTake")])
                    } else {
                        Picker("", selection: $serialManager.newTakeEnabled) {
                            Text("Vintage").tag(false)
                            Text("NewTake").tag(true)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

        PremiumGlassCard(title: "Export Options", footer: serialManager.exportFormat.isLossless
                           ? "\(serialManager.exportFormat.displayName) is a lossless format. Image quality is fully preserved."
                           : "JPEG and HEIC use compression. Some fine detail may be lost.") {
            SettingsRow(title: "Export Format", showDivider: false) {
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: $serialManager.exportFormat,
                        options: QuickTakeExportFormat.allCases.map { ($0, $0.displayName) })
                } else {
                    Picker("", selection: $serialManager.exportFormat) {
                        ForEach(QuickTakeExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

        }

        if serialManager.selectedModel.producesProprietaryRaw {
            PremiumGlassCard(
                title: "Original Files",
                footer: "Keep the camera’s original .qtk files so your photos can be decoded again later. Choose their save location in General."
            ) {
                SettingsRow(title: "Keep Original Files", showDivider: false) {
                    Toggle("", isOn: $serialManager.keepOriginalQTK)
                        .labelsHidden()
                        .modifier(ThemedSwitchToggle())
                }
            }
        }

        // Optional 1990s-style date burn-in. Off by default and in its own
        // card so it reads as a stylistic choice rather than a core setting.
        PremiumGlassCard(
            title: "Date Stamp",
            footer: "Prints the capture date into the bottom-right corner of every exported photo, in the style of 1990s consumer cameras. The original `.qtk` archive is never modified."
        ) {
            SettingsRow(title: "Imprint on Photos", showDivider: false) {
                Toggle("", isOn: $serialManager.captureDateStampEnabled)
                    .labelsHidden()
                    .modifier(ThemedSwitchToggle())
            }
        }
    }
}

// MARK: - Connection Pane

private struct ConnectionPane: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @Environment(\.isClassicTheme) private var isClassicTheme
    @Binding var showingHelp: Bool

    var body: some View {
        PremiumGlassCard(title: "Status", footer: nil) {
            SettingsRow(title: "Serial Port") {
                Text(serialManager.detectedPortPath ?? "No device found")
                    .foregroundStyle(serialManager.detectedPortPath != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 250, alignment: .trailing)
            }

            SettingsRow(title: "Connection", showDivider: serialManager.errorMessage != nil) {
                HStack(spacing: 6) {
                    // Same status colour the sidebar bubble shows (green ready,
                    // orange in-between, red error).
                    Circle()
                        .fill(serialManager.statusIndicatorColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: serialManager.statusIndicatorColor.opacity(0.5), radius: 4)
                    Text(serialManager.isConnected ? "Connected" : "Not Connected")
                        .font(isClassicTheme ? Font.classic(13) : .body)
                }
            }

            if let errorMsg = serialManager.errorMessage {
                SettingsRow(title: "Error", showDivider: false) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMsg)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .font(isClassicTheme ? Font.classic(12) : .callout)
                    }
                }
            }
        }

        PremiumGlassCard(title: "Controls", footer: "Rescan searches for QuickTake-compatible serial adapters. Connect opens a session with the detected device.") {
            SettingsRow(title: "Baud Rate") {
                if isClassicTheme {
                    ClassicPopUpButton(
                        selection: $serialManager.selectedBaudRate,
                        options: SerialBaudRate.allCases.map {
                            ($0, "\($0.displayName) (\($0.detail))")
                        })
                } else {
                    Picker("", selection: $serialManager.selectedBaudRate) {
                        ForEach(SerialBaudRate.allCases) { baudRate in
                            Text("\(baudRate.displayName) (\(baudRate.detail))").tag(baudRate)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsRow(title: "Actions", showDivider: false) {
                HStack(spacing: 8) {
                    Button("Rescan") {
                        serialManager.detectSerialPort(userInitiated: true)
                    }
                    // Also off while connected. Scanning for an adapter to
                    // connect to is meaningless once you are connected to
                    // one, and `detectSerialPort` now returns early in that
                    // case — leaving the button live would make it a
                    // no-op that looks broken rather than unavailable.
                    .disabled(serialManager.isBusy || serialManager.isConnected)

                    Button("Connect") {
                        serialManager.connectToDetectedCamera()
                    }
                    // The one shared prominent treatment (Platinum default
                    // button in Classic, glassProminent on macOS 26) — this
                    // was the last private copy, and its non-Classic branch
                    // had drifted to borderedProminent.
                    .modifier(PrimaryButtonModifier())
                    .disabled(serialManager.isBusy || serialManager.isConnected)

                    Button("Disconnect") {
                        serialManager.disconnectCamera()
                    }
                    .disabled(!serialManager.isConnected)
                }
            }
        }

        PremiumGlassCard(title: "Support", footer: "View hardware wiring diagrams, supported adapter chipsets, and driver installation guides.") {
            SettingsRow(title: "Troubleshooting", showDivider: false) {
                Button("Connection Help…") {
                    showingHelp = true
                }
            }
        }
    }
}

// MARK: - Editable Text Field

private struct EditableTextField: View {
    let text: String
    let onCommit: (String) -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var isEditing = false
    @State private var editingText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            Group {
                if isClassicTheme {
                    // Period text field: a sunken white well (OS 9 had no
                    // rounded-border fields).
                    TextField("", text: $editingText)
                        .textFieldStyle(.plain)
                        .font(.classic(12))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(Color.white)
                        .classicBevel(sunken: true, cornerRadius: 3)
                } else {
                    TextField("", text: $editingText)
                        .textFieldStyle(.roundedBorder)
                }
            }
                .focused($isFocused)
                .multilineTextAlignment(.trailing)
                .frame(width: 200)
                .onSubmit {
                    isEditing = false
                    if editingText != text {
                        onCommit(editingText)
                    }
                }
                .onAppear {
                    editingText = text
                    isFocused = true
                }
        } else {
            Text(text)
                .foregroundStyle(.secondary)
                .onTapGesture {
                    isEditing = true
                }
        }
    }
}
