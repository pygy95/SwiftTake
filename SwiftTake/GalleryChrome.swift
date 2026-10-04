//
//  GalleryChrome.swift
//  SwiftTake
//
//  The controls that act on the gallery: the native toolbar, its Classic
//  Platinum stand-in, and the three popovers both of them open.
//
//  Extracted as view structs (and a ToolbarContent struct) with declared
//  inputs, for the reason the gallery and sidebar were: as part of
//  ContentView's body the whole of this chrome was rebuilt on any published
//  change on the manager. What it actually reads is small — whether there are
//  photos, whether any are selected, the busy flags, the zoom.
//
//  The two chrome rows NEVER coexist: the window is rebuilt on a theme switch
//  (see the WindowGroup `.id`), so each theme gets a clean one. They do share
//  presentation state, which is why the popovers are passed in from the one
//  place that owns those flags rather than built twice.
//

import SwiftUI

// MARK: - Native toolbar

/// The Regular-theme toolbar. Classic declares NO items at all — see the
/// comment at the call site; that is a macOS 26 safe-area constraint, not a
/// style choice.
struct GalleryToolbar<InfoPopover: View, SelectionPopover: View, ImportPopover: View>: ToolbarContent {
    let isClassic: Bool
    let hasPhotos: Bool
    let hasSelection: Bool
    let isConnected: Bool
    let isBusy: Bool
    let areThumbnailsLoading: Bool
    /// True while an import is actually running, which keeps Import enabled so
    /// more photos can be queued onto the same run.
    let hasActiveTransfers: Bool
    let thumbnailWidth: Double
    let focusedPhotoIndex: UInt8?
    let importPrimaryTitle: String

    @Binding var squareGrid: Bool
    @Binding var showingPhotoInfo: Bool
    @Binding var showingSelectionMenu: Bool
    @Binding var showingImportOptions: Bool

    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    @ViewBuilder let infoPopover: (UInt8) -> InfoPopover
    @ViewBuilder let selectionPopover: () -> SelectionPopover
    @ViewBuilder let importPopover: () -> ImportPopover

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // Zoom −/+ — native grouped glass in Regular, Platinum in
        // Classic. The window is rebuilt on a theme switch (see the
        // WindowGroup `.id`), so each theme gets a clean toolbar and we
        // can branch freely without worrying about cross-theme drift.
        if hasPhotos {
            ToolbarItemGroup {
                Button {
                    onZoomOut()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(thumbnailWidth <= ContentView.galleryZoomMin)
                .classicHelp("Smaller thumbnails")
                .accessibilityLabel("Smaller thumbnails")
                .modifier(ToolbarClassicButton(classic: isClassic))

                Button {
                    onZoomIn()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(thumbnailWidth >= ContentView.galleryZoomMax)
                .classicHelp("Larger thumbnails")
                .accessibilityLabel("Larger thumbnails")
                .modifier(ToolbarClassicButton(classic: isClassic))
            }
            .sharedBackgroundVisibility(isClassic ? .hidden : .automatic)

            // Grid layout + photo info — a separate group.
            ToolbarItemGroup {
                Button {
                    // No withAnimation here: the grid and cells animate
                    // via their own .animation(value: gallerySquareGrid)
                    // modifiers, and wrapping it would flash the toolbar.
                    squareGrid.toggle()
                } label: {
                    Image(systemName: squareGrid ? "rectangle.arrowtriangle.2.outward" : "square.grid.2x2")
                }
                .classicHelp(squareGrid ? "Show photos at their full aspect ratio" : "Crop thumbnails to squares")
                .accessibilityLabel("Thumbnail shape")
                .accessibilityValue(squareGrid ? "Square" : "Full aspect ratio")
                .modifier(ToolbarClassicButton(classic: isClassic))

                Button {
                    showingPhotoInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .disabled(focusedPhotoIndex == nil)
                .classicHelp("Photo info")
                .accessibilityLabel("Photo information")
                .modifier(ToolbarClassicButton(classic: isClassic))
                .popover(isPresented: $showingPhotoInfo, arrowEdge: .bottom) {
                    if let idx = focusedPhotoIndex {
                        infoPopover(idx)
                            // Squarer Platinum bubble in Classic only.
                            .presentationCornerRadius(isClassic ? 4 : nil)
                    }
                }
            }
            .sharedBackgroundVisibility(isClassic ? .hidden : .automatic)
        }

        // Selection + import (trailing). There's no select mode:
        // clicking a photo selects it, Finder/Photos-style.
        ToolbarItemGroup(placement: .primaryAction) {
            if hasSelection {
                Button {
                    onDeselectAll()
                } label: {
                    Label("Deselect", systemImage: "xmark.circle")
                }
                .classicHelp("Clear the selection")
                .modifier(ToolbarClassicButton(classic: isClassic))
            }

            // The selection-options and Import cluster HIDES until a
            // camera is connected — same rule as the zoom/view
            // controls. Disabled-but-visible read as broken when
            // there is nothing they could ever act on.
            if isConnected {

            // Overflow menu for selection variants, keeping the
            // Import dropdown focused on importing.
            // Classic uses a Platinum popover (the system Menu popup is
            // Liquid Glass and can't be themed); Regular keeps the
            // native glass Menu. Safe to branch — the window rebuilds
            // on theme switch.
            if isClassic {
                Button {
                    showingSelectionMenu.toggle()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .classicHelp("Selection options")
                .accessibilityLabel("Selection options")
                .disabled(!isConnected || !hasPhotos)
                .popover(isPresented: $showingSelectionMenu, arrowEdge: .bottom) {
                    selectionPopover()
                        // Squarer Platinum bubble in Classic only.
                        .presentationCornerRadius(isClassic ? 4 : nil)
                }
            } else {
                Menu {
                    Button("Select All") { onSelectAll() }
                    Button("Deselect All") {
                        onDeselectAll()
                    }
                    .disabled(!hasSelection)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .classicHelp("Selection options")
                .accessibilityLabel("Selection options")
                .disabled(!isConnected || !hasPhotos)
            }

            // The primary Import control — a Liquid Glass dropdown
            // (like the info popover) listing the import choices as
            // buttons. Enabled whenever there are photos to import.
            Button {
                showingImportOptions.toggle()
            } label: {
                Label {
                    Text(importPrimaryTitle)
                } icon: {
                    // Draw the glyph a touch larger than the label text
                    // so it reads at the same weight as the icon-only
                    // toolbar buttons, but pin its LAYOUT height to the
                    // text so it doesn't inflate the button/bubble.
                    // Classic sizes it DOWN to the Charcoal label's own
                    // 13 pt — the 16 pt glyph reads oversized against the
                    // denser period face.
                    Image(systemName: "square.and.arrow.down")
                        .font(isClassic ? .system(size: 13, weight: .semibold)
                                        : .system(size: 16, weight: .medium))
                        .frame(height: 14)
                }
            }
            .modifier(ToolbarPrimaryButton(classic: isClassic))
            // Disabled while the link is busy with anything that
            // ISN'T an import (thumbnail loading, refresh, erase) —
            // clicking would only silently defer, which reads as
            // broken. During a running import it stays ENABLED so
            // more photos can be queued onto the same run.
            .disabled(!isConnected
                      || !hasPhotos
                      || areThumbnailsLoading
                      || (isBusy && !hasActiveTransfers))
            .classicHelp("Import photos")
            .popover(isPresented: $showingImportOptions, arrowEdge: .bottom) {
                importPopover()
                    // Squarer Platinum bubble in Classic only.
                    .presentationCornerRadius(isClassic ? 4 : nil)
            }

            }   // if isConnected
        }
        .sharedBackgroundVisibility(isClassic ? .hidden : .automatic)
    }
}

// MARK: - Classic control row

/// Platinum stand-ins for the toolbar controls, 1:1 with the native
/// toolbar's buttons (same actions, same enabled rules, same popovers —
/// the two never coexist, so they share presentation state). Balloons
/// open downward here: the row hugs the window's top edge.
struct ClassicControlRow<InfoPopover: View, SelectionPopover: View, ImportPopover: View>: View {
    let hasPhotos: Bool
    let hasSelection: Bool
    let isConnected: Bool
    let isBusy: Bool
    let areThumbnailsLoading: Bool
    let hasActiveTransfers: Bool
    let thumbnailWidth: Double
    let focusedPhotoIndex: UInt8?

    @Binding var squareGrid: Bool
    @Binding var showingPhotoInfo: Bool
    @Binding var showingSelectionMenu: Bool
    @Binding var showingImportOptions: Bool

    let onToggleSidebar: () -> Void
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onDeselectAll: () -> Void

    @ViewBuilder let infoPopover: (UInt8) -> InfoPopover
    @ViewBuilder let selectionPopover: () -> SelectionPopover
    @ViewBuilder let importPopover: () -> ImportPopover

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(compact: false)
            controlRow(compact: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.platinumFace)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.platinumShadow.opacity(0.75)).frame(height: 1)
        }
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                onToggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(ClassicToolbarButtonStyle())
            .classicHelp("Toggle Sidebar", placement: .belowLeading)
            .accessibilityLabel("Toggle Sidebar")

            // The window's title bar carries the app name; this header
            // carries the document-style title, OS 9 fashion.
            if !compact {
                Text("Camera Storage")
                    .font(.classic(12, weight: .bold))
                    .foregroundStyle(AppTheme.platinumText)
                    .fixedSize()
                    .padding(.leading, 2)
            }

            Spacer(minLength: 12)

            // Gallery-view controls, right-aligned with the action cluster —
            // NOT crowding the title. Fixed glyph widths keep the buttons
            // uniform (a bare "minus" hugs narrower than a "plus").
            if hasPhotos {
                Button {
                    onZoomOut()
                } label: {
                    Image(systemName: "minus").frame(width: 16)
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .disabled(thumbnailWidth <= ContentView.galleryZoomMin)
                .classicHelp("Smaller thumbnails", placement: .below)
                .accessibilityLabel("Smaller thumbnails")

                Button {
                    onZoomIn()
                } label: {
                    Image(systemName: "plus").frame(width: 16)
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .disabled(thumbnailWidth >= ContentView.galleryZoomMax)
                .classicHelp("Larger thumbnails", placement: .below)
                .accessibilityLabel("Larger thumbnails")

                Button {
                    squareGrid.toggle()
                } label: {
                    Image(systemName: squareGrid ? "rectangle.arrowtriangle.2.outward" : "square.grid.2x2")
                        .frame(width: 16)
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .classicHelp(squareGrid ? "Show photos at their full aspect ratio" : "Crop thumbnails to squares",
                             placement: .below)
                .accessibilityLabel("Thumbnail shape")
                .accessibilityValue(squareGrid ? "Square" : "Full aspect ratio")

                Button {
                    showingPhotoInfo.toggle()
                } label: {
                    Image(systemName: "info.circle").frame(width: 16)
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .disabled(focusedPhotoIndex == nil)
                .classicHelp("Photo info", placement: .below)
                .accessibilityLabel("Photo information")
                .popover(isPresented: $showingPhotoInfo, arrowEdge: .bottom) {
                    if let idx = focusedPhotoIndex {
                        infoPopover(idx)
                            .presentationCornerRadius(4)
                    }
                }

                // Breathing room between the view controls and the
                // selection/import cluster.
                Color.clear.frame(width: 8, height: 1)
            }

            if hasSelection {
                Button {
                    onDeselectAll()
                } label: {
                    actionLabel("Deselect", systemImage: "xmark.circle", compact: compact)
                }
                .buttonStyle(ClassicToolbarButtonStyle())
                .classicHelp("Clear the selection", placement: .belowTrailing)
                .accessibilityLabel("Deselect all photos")
            }

            // Hidden until connected — same rule as the view controls above
            // (and the Regular toolbar): nothing to select or import without
            // a camera, and disabled-but-visible reads as broken.
            if isConnected {

            Button {
                showingSelectionMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 16)
            }
            .buttonStyle(ClassicToolbarButtonStyle())
            .classicHelp("Selection options", placement: .belowTrailing)
            .accessibilityLabel("Selection options")
            .disabled(!hasPhotos)
            .popover(isPresented: $showingSelectionMenu, arrowEdge: .bottom) {
                selectionPopover()
                    .presentationCornerRadius(4)
            }

            Button {
                showingImportOptions.toggle()
            } label: {
                actionLabel("Import", systemImage: "square.and.arrow.down", compact: compact)
            }
            .modifier(ToolbarPrimaryButton(classic: true))
            .disabled(!hasPhotos
                      || areThumbnailsLoading
                      || (isBusy && !hasActiveTransfers))
            .classicHelp("Import photos", placement: .belowTrailing)
            .accessibilityLabel("Import photos")
            .popover(isPresented: $showingImportOptions, arrowEdge: .bottom) {
                importPopover()
                    .presentationCornerRadius(4)
            }

            }   // if isConnected
        }
    }

    /// Keep labels at their intrinsic width so ViewThatFits chooses the compact
    /// row instead of squeezing a word into a tall, multi-line button.
    private func actionLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 14)
            if !compact {
                Text(title)
            }
        }
        .fixedSize()
    }
}

// MARK: - Popovers

/// Platinum-themed Select All / Deselect All popover (Classic stand-in for the
/// system Menu popup, which is Liquid Glass and can't be themed).
struct SelectionOptionsPopover: View {
    let hasSelection: Bool
    @Binding var showingImportOptions: Bool
    @Binding var showingSelectionMenu: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(.tint)
                Text("Selection")
                    .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
            }
            Divider()

            ImportOptionButton(title: "Select All",
                               systemImage: "checkmark.circle",
                               showingImportOptions: $showingImportOptions) {
                showingSelectionMenu = false
                onSelectAll()
            }

            ImportOptionButton(title: "Deselect All",
                               systemImage: "xmark.circle",
                               showingImportOptions: $showingImportOptions) {
                showingSelectionMenu = false
                onDeselectAll()
            }
            .disabled(!hasSelection)
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
        .background { if isClassicTheme { AppTheme.platinumFace } }
        .environment(\.isClassicTheme, isClassicTheme)
    }
}

/// Import choices as a Liquid Glass dropdown (mirrors the info popover):
/// the selection, all-new, and re-import-everything actions as buttons.
///
/// The counts are worked out HERE rather than handed in: this view is built
/// inside a `.popover` content closure, so the filter only runs when the
/// popover is actually opened.
struct ImportOptionsPopover: View {
    let photoIndices: [UInt8]
    let selectedCount: Int
    let importedPhotoURLs: [UInt8: [URL]]
    @Binding var showingImportOptions: Bool
    let onImportSelected: () -> Void
    let onImportNew: () -> Void
    let onImportEverythingAgain: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        let total = photoIndices.count
        let importedCount = photoIndices.filter {
            importedPhotoURLs[$0]?.isEmpty == false
        }.count
        let newCount = total - importedCount
        let hasImported = importedCount > 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.tint)
                Text("Import")
                    .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
            }
            Divider()

            if selectedCount > 0 {
                ImportOptionButton(
                    title: "Import \(selectedCount) Selected",
                    systemImage: "checkmark.circle",
                    showingImportOptions: $showingImportOptions
                ) {
                    onImportSelected()
                }
            }

            ImportOptionButton(
                title: hasImported ? "Import \(newCount) New" : "Import All (\(total))",
                systemImage: "square.and.arrow.down",
                prominent: true,
                showingImportOptions: $showingImportOptions
            ) {
                onImportNew()
            }
            .disabled(hasImported && newCount == 0)

            if hasImported {
                ImportOptionButton(
                    title: "Import Everything Again",
                    systemImage: "arrow.clockwise",
                    showingImportOptions: $showingImportOptions
                ) {
                    onImportEverythingAgain()
                }
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        // Popovers are hosted in a child window that drops the injected theme
        // environment, so re-inject it (the inner button modifiers read it) and
        // paint a Platinum body in Classic.
        .background { if isClassicTheme { AppTheme.platinumFace } }
        .environment(\.isClassicTheme, isClassicTheme)
    }
}

private struct ImportOptionButton: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    /// Every button in both popovers closes the import popover before acting.
    @Binding var showingImportOptions: Bool
    let action: () -> Void

    var body: some View {
        let button = Button {
            showingImportOptions = false
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)

        return Group {
            if prominent {
                button.modifier(PrimaryButtonModifier())
            } else {
                button.modifier(SidebarButtonModifier())
            }
        }
    }
}

/// Photos-style info popover for the focused photo, shown from the toolbar
/// "i" button. Capture date, dimensions, quality, file size and filename —
/// pulled from the QTK header and the rendered image on disk so it works for
/// any focused photo, even after a fresh launch.
///
/// The disk reads stay INSIDE this body on purpose: the view is built in a
/// `.popover` content closure, so nothing here touches the filesystem until
/// the popover is opened.
struct PhotoInfoPopover: View {
    let photoName: String
    let savedURLs: [URL]
    let captureDate: Date?
    let isHQ: Bool?

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        let renderedURL = savedURLs.first(where: { $0.pathExtension.lowercased() != "qtk" })
        let qtkURL = savedURLs.first(where: { $0.pathExtension.lowercased() == "qtk" })
        let displayURL = renderedURL ?? qtkURL

        let dimensions: String? = {
            guard let renderedURL,
                  let img = NSImage(contentsOf: renderedURL) else { return nil }
            let size = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
            guard size.width > 0, size.height > 0 else { return nil }
            return "\(Int(size.width)) × \(Int(size.height))"
        }()
        let quality: String? = isHQ.map { $0 ? "HQ" : "SQ" }
        let fileSize: String? = {
            guard let displayURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: displayURL.path),
                  let bytes = attrs[.size] as? NSNumber else { return nil }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes.int64Value)
        }()

        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)
                Text(photoName)
                    .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Divider()
            if let captureDate {
                row(label: "Captured", value: dateFormatter.string(from: captureDate))
            }
            if let dimensions {
                row(label: "Dimensions", value: dimensions)
            }
            if let quality {
                row(label: "Quality", value: quality)
            }
            if let fileSize {
                row(label: "On Disk", value: fileSize)
            }
            if let displayURL {
                row(label: "File", value: displayURL.lastPathComponent)
            }
            if captureDate == nil && dimensions == nil && fileSize == nil {
                Text("Import this photo to see its details.")
                    .font(isClassicTheme ? Font.classic(12) : .callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        // Platinum body in Classic (popover host window drops the injected theme).
        .background { if isClassicTheme { AppTheme.platinumFace } }
        .environment(\.isClassicTheme, isClassicTheme)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(isClassicTheme ? Font.classic(12) : .callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(isClassicTheme ? Font.classic(12) : .callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Toolbar button styling

private struct ToolbarClassicButton: ViewModifier {
    let classic: Bool
    func body(content: Content) -> some View {
        if classic {
            content.buttonStyle(ClassicToolbarButtonStyle())
        } else {
            content
        }
    }
}

/// Prominent toolbar button — a Platinum default button (black ring) in Classic,
/// the glass prominent style otherwise.
private struct ToolbarPrimaryButton: ViewModifier {
    let classic: Bool
    func body(content: Content) -> some View {
        if classic {
            content.buttonStyle(ClassicToolbarButtonStyle(prominent: true, classicFont: true))
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
