//
//  WindowOverlays.swift
//  SwiftTake
//
//  What the window puts OVER the gallery, and what it shows instead of one:
//  the toast banner, the modal dialogs, the overwrite prompt, the status
//  placeholder capsule, and the empty state.
//
//  Extracted as view structs with declared inputs. These are the pieces that
//  are usually absent and briefly critical, so it matters that they only
//  re-render for their own reasons: the toast reads four manager flags and
//  the error string, the dialog layer reads three prompts, and the empty
//  state reads whether a camera is attached. None of them has any business
//  being rebuilt by an import's progress.
//

import SwiftUI

// MARK: - Toasts

/// At most one banner is ever shown, the way macOS coalesces its own
/// notifications. The single highest-priority active banner wins (error
/// first, then connection-lost, model mismatch, and finally the power
/// reminder) so banners can never stack on top of each other.
struct ToastStack: View {
    let errorMessage: String?
    let isConnecting: Bool
    let showConnectionAlert: Bool
    let showModelMismatch: Bool
    let detectedModelName: String?
    let showPowerTip: Bool
    let onDismissError: () -> Void
    let onDismissToast: () -> Void

    var body: some View {
        Group {
            if let error = errorMessage, !isConnecting {
                ToastView(
                    title: "Something went wrong",
                    subtitle: error,
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    duration: 10
                ) {
                    onDismissError()
                }
            } else if showConnectionAlert {
                ToastView(
                    title: "Camera disconnected",
                    subtitle: "The connection was lost. Check the cable and power, then reconnect.",
                    icon: "cable.connector.slash",
                    color: .orange,
                    duration: 9
                ) {
                    onDismissToast()
                }
            } else if showModelMismatch, let detected = detectedModelName {
                ToastView(
                    title: "Different model detected",
                    subtitle: "This looks like a \(detected). You can switch in Settings ▸ Hardware.",
                    icon: "questionmark.diamond.fill",
                    color: .yellow,
                    duration: 9
                ) {
                    onDismissToast()
                }
            } else if showPowerTip {
                ToastView(
                    // Titled for what it SAYS, not for what preceded it.
                    // This carried "Camera disconnected" — the exact title
                    // of the disconnect toast above — under a sleep icon
                    // and a line about unplugging, so two different toasts
                    // answered to one name and this one read as a
                    // contradiction of its own icon.
                    title: "Safe to unplug",
                    subtitle: "Turn the camera off to save its batteries.",
                    icon: "powersleep",
                    color: .blue,
                    duration: 8
                ) {
                    onDismissToast()
                }
            }
        }
        .padding(.top, 20)
    }
}

// MARK: - Modal dialogs

/// In-window modal dialogs (duplicate prompt / folder-unavailable notice /
/// the Classic erase confirmation), presented as glass overlays so they
/// sample the gallery behind them.
struct ModalDialogLayer: View {
    let duplicatePrompt: QuickTakeSerialManager.DuplicatePromptRequest?
    let destinationFallbackMessage: String?
    let showingEraseConfirmation: Bool
    let isClassicTheme: Bool
    let onDismissFallback: () -> Void
    let onConfirmErase: () -> Void
    let onCancelErase: () -> Void

    var body: some View {
        ZStack {
            if let req = duplicatePrompt {
                DimmedBackdrop()
                DuplicateFileDialog(fileName: req.fileName) { action in
                    req.resolve(action)
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if isClassicTheme, let msg = destinationFallbackMessage {
                // Classic only. Modern themes get the real system alert
                // (see ContentView) — without this guard both would appear,
                // the drawn one on top of the real one.
                DimmedBackdrop()
                NoticeDialog(
                    icon: "externaldrive.badge.exclamationmark",
                    tint: .orange,
                    title: "Import folder unavailable",
                    message: msg
                ) {
                    onDismissFallback()
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if isClassicTheme && showingEraseConfirmation {
                DimmedBackdrop()
                ClassicConfirmDialog(
                    icon: "trash", tint: .red,
                    title: "Erase all photos?",
                    message: "Every photo on the camera will be permanently deleted. This can't be undone.",
                    confirmLabel: "Erase all photos", destructive: true,
                    onConfirm: onConfirmErase,
                    onCancel: onCancelErase
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: duplicatePrompt?.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: destinationFallbackMessage)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showingEraseConfirmation)
    }
}

/// Dimmed, click-blocking backdrop behind a modal dialog.
struct DimmedBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(.black.opacity(0.28))
            .ignoresSafeArea()
            .contentShape(Rectangle())   // absorb clicks so it's truly modal
    }
}

/// The "some of these are already imported" prompt, raised before a
/// whole-camera import that would re-download photos already on disk.
struct OverwriteConfirmationDialog: View {
    let onSkipImported: () -> Void
    let onImportAgain: () -> Void
    let onCancel: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        ZStack {
            // Dim + click-catch over the whole window.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 18) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("Some photos are already imported")
                        .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                        .multilineTextAlignment(.center)
                    Text("Skip the ones you already have, or import everything again.")
                        .font(isClassicTheme ? Font.classic(12) : .subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button {
                        onSkipImported()
                    } label: {
                        Text("Skip Imported").frame(maxWidth: .infinity)
                    }
                    .modifier(PrimaryButtonModifier())
                    .controlSize(.large)

                    Button {
                        onImportAgain()
                    } label: {
                        Text("Import Again").frame(maxWidth: .infinity)
                    }
                    .modifier(SidebarButtonModifier())
                    .controlSize(.large)

                    Button(action: onCancel) {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .frame(width: 260)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .themedPanel(cornerRadius: 18, classic: isClassicTheme)
            .shadow(color: .black.opacity(0.2), radius: 22, x: 0, y: 10)
        }
    }
}

// MARK: - Status capsule

/// The resting status pill. Note it is ONLY ever drawn invisibly: the sidebar
/// footer renders it at opacity 0 as a layout placeholder, and the visible
/// bubble is `StatusBubbleLayer`.
struct StatusCapsule: View {
    let text: String
    /// The raw status message, for the VoiceOver label — the trimmed `text` is
    /// a display nicety.
    let accessibilityMessage: String
    let indicatorColor: Color

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(text)
                .font(isClassicTheme ? Font.classic(11) : .caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // No glass here: this capsule is ONLY ever drawn invisibly (the sidebar
        // footer renders it at opacity 0 as a layout placeholder). The visible
        // bubble — glass and all — is `StatusBubbleLayer` / `BubbleSurface`.
        // The coloured dot's meaning is carried by the status text, so read
        // them as a single element rather than an unlabelled circle + text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(accessibilityMessage)")
    }
}

// MARK: - Empty state

/// What the canvas shows with no photos to show: an actionable "nothing on
/// the camera" state when connected, and the friendly "plug me in" state
/// when not.
struct GalleryEmptyState: View {
    let isConnected: Bool
    let cameraShortName: String
    let isBusy: Bool
    let onRefresh: () -> Void
    let onShowConnectionHelp: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(spacing: 16) {
            if isConnected {
                // Connected, just nothing on the camera — make it actionable.
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Text("No Photos Yet")
                        .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                        .foregroundStyle(.secondary)
                    Text("Take a photo on the \(cameraShortName), then refresh to see it here.")
                        .font(isClassicTheme ? Font.classic(12) : .subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(isClassicTheme ? Font.classic(12, weight: .semibold) : .callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 4)
                .disabled(isBusy)
            } else {
                // No camera — the friendly "plug me in" state. Grouped into
                // clear tiers so it reads as a hierarchy rather than a stack of
                // equidistant items: illustration → primary message → helpers.
                VStack(spacing: 22) {
                    if isClassicTheme {
                        // Classic wears the pixel-art QuickTake in full colour
                        // (a template render would flatten it to a silhouette).
                        // The Regular illustration's 2048 canvas is mostly
                        // padding — its camera shows at ~145pt wide. This art
                        // is cropped tight, so it renders at 145 inside the
                        // same 180pt layout box for an optical match.
                        Image("ClassicConnectCamera")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 145)
                            .frame(width: 180, height: 180)
                            // The Regular art sits right-of-centre and slightly
                            // high inside its padded canvas; nudge to match.
                            .offset(x: 13, y: -3)
                    } else {
                        Image("ConnectCamera")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .foregroundStyle(.secondary)
                            .opacity(0.8)
                    }

                    // Primary message — title tight to its supporting line.
                    VStack(spacing: 6) {
                        Text("No Camera Connected")
                            .font(isClassicTheme ? Font.classic(15, weight: .semibold) : .title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Plug in your QuickTake, power it on, then Connect to import photos.")
                            .font(isClassicTheme ? Font.classic(12) : .subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }

                    // Secondary helpers — the drag hint and the help link belong
                    // together, set apart from the primary message above.
                    VStack(spacing: 12) {
                        Text("No camera handy? Drag .qtk files here to import them without one.")
                            .font(isClassicTheme ? Font.classic(11) : .caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                        Button {
                            onShowConnectionHelp()
                        } label: {
                            Label("Need help connecting?", systemImage: "questionmark.circle")
                                .font(isClassicTheme ? Font.classic(12, weight: .semibold) : .callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Centre the graphic vertically in the canvas (fill the scroll viewport).
        .containerRelativeFrame(.vertical, alignment: .center)
        // `.contain` (not `.combine`) so the "Need help connecting?" button stays a
        // separate, actionable VoiceOver element instead of being flattened into
        // one label with the surrounding text.
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Dialog views
//
// Moved here with the layer that presents them. GlassDialogPanel stays
// file-private: the three dialogs are its only users.

/// Custom, precisely-aligned "file already exists" dialog — replaces the
/// `NSAlert` (whose stacked buttons / accessory checkbox read as unpolished).
/// Icon + title/body are top-left aligned; the button row keeps Stop on the far
/// left and Keep Both / Replace (default) on the right, matching macOS ordering.
struct DuplicateFileDialog: View {
    let fileName: String
    let onChoice: (QuickTakeSerialManager.DuplicateAction) -> Void
    @Environment(\.isClassicTheme) private var isClassicTheme
    @State private var applyToAll = false

    /// Middle-truncate a long import name so the title stays one tidy line.
    private var shownName: String {
        guard fileName.count > 40 else { return fileName }
        return String(fileName.prefix(22)) + "…" + String(fileName.suffix(16))
    }

    var body: some View {
        // No icon — everything left-aligned to one edge (title, body, checkbox,
        // buttons) so the box lines up cleanly.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(shownName)” already exists")
                    .font(isClassicTheme ? Font.classic(15, weight: .bold) : .headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("An item with that name is already in this folder. Replace it, keep both (the new one is renamed), or stop importing.")
                    .font(isClassicTheme ? Font.classic(12) : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Apply to all remaining duplicates", isOn: $applyToAll)
                .modifier(ThemedCheckboxToggle())
                .font(isClassicTheme ? Font.classic(12) : .callout)

            HStack(spacing: 12) {
                Button("Stop", role: .cancel) { onChoice(.stop) }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 20)
                Button("Keep Both") { onChoice(.keepBoth(applyToAll: applyToAll)) }
                Button("Replace") { onChoice(.replace(applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420)
        .modifier(GlassDialogPanel(classic: isClassicTheme))
    }
}

/// Glass panel for the in-window modal dialogs — real Liquid Glass (samples the
/// dimmed gallery behind the overlay) in the normal themes, Platinum in Classic.
private struct GlassDialogPanel: ViewModifier {
    let classic: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if classic {
            content
                .background(shape.fill(AppTheme.platinumFace))
                .overlay(shape.stroke(AppTheme.platinumFrame, lineWidth: 1))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        } else if reduceTransparency {
            // Same shape/stroke/shadow as the glass path below, an opaque
            // window-coloured fill in place of the see-through material.
            content
                .background(shape.fill(Color(NSColor.windowBackgroundColor)))
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
        }
    }
}

/// A small, premium notice dialog (icon + title + message + a single OK), styled
/// to match `DuplicateFileDialog` so app-level warnings read consistently rather
/// than as a bare system alert.
struct NoticeDialog: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    let onDismiss: () -> Void
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        Group {
            if isClassicTheme { classicBody } else { alertBody }
        }
        .modifier(GlassDialogPanel(classic: isClassicTheme))
    }

    /// The macOS alert shape: narrow, centred, one full-width default
    /// button. This used to be a 420pt-wide card with the icon shoved left,
    /// ragged-left text beside it and the button floated off to the right —
    /// a layout Apple uses for a Finder info pane, not for a warning. An
    /// alert is a single short statement, and centring it at alert width is
    /// what makes it read as one.
    private var alertBody: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Button("OK") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 300)
    }

    /// Mac OS 9 put the pictograph on the left and the text beside it, so
    /// the Classic theme keeps that arrangement rather than inheriting the
    /// modern centred one. Same dialog, two periods.
    private var classicBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .symbolRenderingMode(.monochrome)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(Font.classic(15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(Font.classic(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("OK") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

/// A themed confirm/cancel dialog (matches NoticeDialog) so confirmations read
/// as part of the app. Used in Classic in place of the system `.alert`.
/// Internal (not private) so the Settings scene can reuse it.
struct ClassicConfirmDialog: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    let confirmLabel: String
    var destructive: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                // Flat monochrome pictograph in Classic — the layered
                // hierarchical rendering reads as Liquid Glass.
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .symbolRenderingMode(isClassicTheme ? .monochrome : .hierarchical)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(isClassicTheme ? Font.classic(15, weight: .bold) : .headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(isClassicTheme ? Font.classic(12) : .callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .modifier(SecondaryButtonModifier())
                Button(confirmLabel, role: destructive ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .modifier(PrimaryButtonModifier())
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 420)
        .modifier(GlassDialogPanel(classic: isClassicTheme))
    }
}
