//
//  SidebarSections.swift
//  SwiftTake
//
//  The sidebar's four bubbles — Connection, Camera, Controls, Maintenance —
//  and the row primitives they share.
//
//  Each section is a view struct with declared inputs, for the reason the
//  gallery cells were split out: while they lived in ContentView's body every
//  section was rebuilt on any published change on the manager. Connection
//  cares about the link and the port; Maintenance cares about the busy flags.
//  Neither has anything to say about an import's progress, and now neither is
//  asked.
//
//  Which sections are ON SCREEN stays at the call site in ContentView, along
//  with their transitions and the single disclosure spring on the parent —
//  the height gating and the one-clock animation are load-bearing and easier
//  to reason about where the heights are measured.
//

import SwiftUI

// MARK: - Sections

/// Connection — an always-open "bubble" (no manual collapse). Lower-priority
/// bubbles below hide themselves when the window gets too short.
struct SidebarConnectionSection: View {
    let isConnected: Bool
    let portPath: String?
    /// Drives the Connect button's unsupported-model state.
    let modelSerialAvailable: Bool
    let modelDisplayName: String
    let isBusy: Bool
    let namespace: Namespace.ID
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarSectionHeader(title: "Connection", icon: "cable.connector")
                .padding(.vertical, 6)

            VStack(spacing: 8) {
                if isConnected {
                    SidebarInfoRow(label: "Status", value: "Connected", icon: "checkmark.circle.fill", iconColor: .green)
                    if let portPath {
                        SidebarInfoRow(label: "Port", value: URL(fileURLWithPath: portPath).lastPathComponent, icon: "cable.connector")
                    }
                } else {
                    SidebarInfoRow(label: "Status", value: "Not Connected", icon: "xmark.circle.fill", iconColor: .orange)
                    connectButton
                }
            }
            .modifier(SidebarRevealCardModifier(id: "Connection", namespace: namespace))
        }
    }

    private var connectButton: some View {
        // Reads the manager's selectedModelSerialAvailable — the same
        // availability gate as the other Connect affordances and
        // connectToDetectedCamera()'s entry guard, so the button and the
        // guard can never disagree.
        let isUnsupportedModel = !modelSerialAvailable
        return Button {
            onConnect()
        } label: {
            // Word only — no aperture glyph. The bare Text centres itself
            // within the button in every theme.
            Text("Connect")
        }
        .modifier(PrimaryButtonModifier(square: true))
        .disabled(isBusy || isConnected || isUnsupportedModel)
        .classicHelp(isUnsupportedModel
              ? "Serial support for the \(modelDisplayName) isn't available yet."
              : "Connect to the detected QuickTake camera")
    }
}

/// Camera info — always open when connected, but hidden automatically when
/// the sidebar is too short for it (the height gate lives at the call site).
struct SidebarCameraSection: View {
    let metadata: CameraMetadata
    let modelName: String
    /// Only cameras that accept a name-set command get the editable row.
    let supportsCameraControlUI: Bool
    let batteryWarning: String?
    let storageWarning: String?
    let namespace: Namespace.ID
    let onSetCameraName: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarSectionHeader(title: "Camera", icon: "camera.fill")
                .padding(.vertical, 6)

            VStack(spacing: 8) {
                // Editable name only for cameras that accept a
                // name-set command (Kodak family). The QT200/
                // Fuji family has no working rename over serial.
                if supportsCameraControlUI {
                    EditableSidebarRow(label: "Name", text: Binding(
                        get: { metadata.cameraName },
                        set: { _ in } // Ignored, we handle commit manually
                    )) { newName in
                        onSetCameraName(newName)
                    }
                }
                SidebarInfoRow(label: "Model", value: modelName)
                // Battery row only when the camera reports it
                // (the Fuji family has no battery opcode).
                if let battery = metadata.batteryLevel {
                    SidebarInfoRow(label: "Battery", value: "\(battery)%")
                }
                SidebarInfoRow(
                    label: "Photos",
                    value: metadata.picturesRemaining.map { "\(metadata.picturesTaken) / \(metadata.picturesTaken + $0)" }
                        ?? (metadata.picturesTaken == 1 ? "1 photo" : "\(metadata.picturesTaken) photos")
                )
                if batteryWarning != nil || storageWarning != nil {
                    warningBadges
                        .padding(.top, 4)
                }
            }
            .modifier(SidebarRevealCardModifier(id: "Camera", namespace: namespace))
        }
    }

    private var warningBadges: some View {
        HStack(spacing: 8) {
            if let batteryWarning {
                SidebarWarningBadge(text: batteryWarning,
                                    systemImage: "battery.25",
                                    tint: .orange,
                                    fill: Color.orange.opacity(0.12))
            }

            if let storageWarning {
                SidebarWarningBadge(text: storageWarning,
                                    systemImage: "internaldrive",
                                    tint: .yellow,
                                    fill: Color.yellow.opacity(0.14))
            }
        }
    }
}

/// Live camera controls — only for capable cameras (QT100/150), inline unless
/// popped out, and hidden when the sidebar is too short (it's the tallest
/// bubble). The prerequisites and the height gate live at the call site.
struct SidebarControlsSection: View {
    @Binding var expanded: Bool
    let namespace: Namespace.ID
    let onPopOut: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                // Disclosure caret + header — one click target.
                // Inline controls start collapsed in each new window.
                Button(action: {
                    // The parent section animates the disclosure and layout.
                    expanded.toggle()
                }) {
                    HStack(spacing: 6) {
                        // OS 9 solid disclosure triangle in Classic;
                        // the SF chevron elsewhere.
                        if isClassicTheme {
                            ClassicDisclosureTriangle(expanded: expanded)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        SidebarSectionHeader(title: "Controls", icon: "camera.viewfinder")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .classicHelp(expanded ? "Hide camera controls" : "Show camera controls")
                .accessibilityLabel(expanded ? "Collapse camera controls" : "Expand camera controls")
                Spacer()
                Button(action: onPopOut) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .classicHelp("Open in a separate window")
                .accessibilityLabel("Open controls in a separate window")
            }
            .padding(.vertical, 6)

            if expanded {
                CameraControlView(isInline: true)
                    .modifier(SidebarRevealCardModifier(id: "Controls", namespace: namespace, padding: 8))
                    // Same enter/exit the sidebar sections use:
                    // fade while sliding out from under the
                    // header. Without an explicit transition
                    // the controls popped in while the height
                    // sprang — read as abrupt.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Maintenance actions — always shown when connected.
struct SidebarMaintenanceSection: View {
    let isBusy: Bool
    let isRefreshing: Bool
    let areThumbnailsLoading: Bool
    /// Erase is hidden when the camera doesn't accept a delete over serial.
    let supportsSerialErase: Bool
    let onRefresh: () -> Void
    let onErase: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionHeader(title: "Maintenance", icon: "wrench.and.screwdriver.fill")

            HStack(spacing: 6) {
                // Refresh shows a live spinner while running
                // (instead of greying out) and is re-entrancy
                // guarded by the manager.
                MaintenanceIconButton(
                    systemImage: "arrow.clockwise",
                    tint: .accentColor,
                    help: "Refresh camera info",
                    busy: isRefreshing
                ) { onRefresh() }
                    .disabled(isBusy && !isRefreshing)

                // Erase is hidden when the camera doesn't accept
                // a delete over serial (QT200/Fuji NAKs it).
                if supportsSerialErase {
                    MaintenanceIconButton(
                        systemImage: "trash",
                        tint: .red,
                        help: "Erase all photos on the camera"
                    ) { onErase() }
                        .disabled(isBusy)
                }

                MaintenanceIconButton(
                    systemImage: "cable.connector.slash",
                    tint: .orange,
                    help: "Disconnect camera"
                ) { onDisconnect() }
                    // Deliberately ENABLED during a
                    // thumbnail load: it's the escape
                    // hatch when a camera dies mid-stream
                    // (the fetch loop breaks the moment
                    // isConnected flips).
                    .disabled(isBusy && !areThumbnailsLoading)
            }
        }
    }
}

// MARK: - Row primitives

struct SidebarSectionHeader: View {
    let title: String
    let icon: String

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title.uppercased())
                .font(isClassicTheme ? Font.classic(10, weight: .bold) : .caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
        }
    }
}

struct SidebarInfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil
    var iconColor: Color = .primary

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)
            Spacer()
            HStack(spacing: 4) {
                Text(value)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let icon {
                    Image(systemName: icon)
                        .foregroundColor(iconColor)
                        .frame(width: 16)
                }
            }
        }
        .font(isClassicTheme ? Font.classic(12) : .subheadline)
    }
}

private struct SidebarWarningBadge: View {
    let text: String
    let systemImage: String
    let tint: Color
    let fill: Color

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(isClassicTheme ? Font.classic(11) : .caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .foregroundColor(tint)
    }
}

private struct EditableSidebarRow: View {
    let label: String
    @Binding var text: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var editingText = ""
    @FocusState private var isFocused: Bool
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)
            Spacer()
            if isEditing {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
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
                    .fontWeight(.medium)
                    .onTapGesture {
                        isEditing = true
                    }
            }
        }
        .font(isClassicTheme ? Font.classic(12) : .subheadline)
    }
}

/// Compact icon-only maintenance button. Sits in a 3-wide row in the
/// sidebar's Maintenance section to replace the previous full-width
/// Label rows. Tap target stays generous (40×40 with hit-test on the
/// rounded background).
private struct MaintenanceIconButton: View {
    let systemImage: String
    let tint: Color
    let help: String
    /// When true, the tile shows a live spinner instead of greying out — so an
    /// in-progress action still reads as the Liquid Glass control, not disabled.
    var busy: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button {
            guard !busy else { return }
            // One short, graceful pulse for tactile click feedback. A low-damping
            // spring gives a single overshoot-and-settle — no repeating bounce.
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { pulse = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { pulse = false }
            }
            action()
        } label: {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            // Liquid Glass tile (Platinum bevel in Classic), subtly tinted to
            // keep each button's colour identity on hover.
            .modifier(MaintenanceTileBackground(tint: tint, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Brief click pulse only (hover never scales — that read as tacky).
            .scaleEffect(pulse ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
        .buttonStyle(.plain)
        .classicHelp(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
    }
}

private struct MaintenanceTileBackground: ViewModifier {
    let tint: Color
    let hovering: Bool
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            content.classicBevel(cornerRadius: 6)
        } else {
            content.glassEffect(
                .regular.tint(tint.opacity(hovering ? 0.30 : 0.18)).interactive(),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }
}

private struct SidebarRevealCardModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    var padding: CGFloat = 12
    @Environment(\.isClassicTheme) private var classic

    func body(content: Content) -> some View {
        if classic {
            content
                .padding(padding)
                .classicBevel(cornerRadius: 4)
                .transition(.opacity)
        } else if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(in: .rect(cornerRadius: 12))
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.materialize)
                .transition(.blurReplace)
        } else {
            content
                .padding(padding)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }
}
