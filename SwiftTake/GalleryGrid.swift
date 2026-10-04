//
//  GalleryGrid.swift
//  SwiftTake
//
//  The camera-storage gallery: the selection count, the grid of cells, and
//  the reflow/zoom animations that carry the cells between layouts.
//
//  Extracted as a view struct so the cells are BUILT here rather than in
//  ContentView's body. That is the whole point: the grid declares the manager
//  state it actually depends on — the photo list, the selection, the four
//  image/URL/quality/name dictionaries — and nothing else. A change to
//  anything outside that set no longer reaches the ForEach, so a gallery of
//  cells is not reconstructed for, say, a progress tick.
//
//  Inputs are explicit. Reading the manager from the environment here would
//  re-widen the dependency to "any change on the manager" and give the split
//  straight back.
//

import SwiftUI

struct GalleryGrid: View {
    // MARK: Layout

    let columns: [GridItem]
    let spacing: CGFloat
    let thumbnailWidth: Double
    let isPinching: Bool
    let isFullScreen: Bool
    let squareGrid: Bool
    /// Live grid width, measured here and read back by the caller to derive
    /// `columnCount` (so the layout and arrow-key nav stay in sync).
    @Binding var galleryWidth: CGFloat

    // MARK: Gallery contents — the manager state this grid depends on

    let photoIndices: [UInt8]
    let selectedPhotoIndices: Set<UInt8>
    let panoramaSlots: Set<UInt8>
    let canMakePanorama: Bool
    let onMakePanorama: () -> Void
    let onOpenPanorama: (UInt8) -> Void
    let onImportPhoto: (UInt8) -> Void
    /// The panorama belonging to whatever is selected right now — ONE, or
    /// none. Shown in a band of its own because it is NOT on the camera:
    /// the grid above is called Camera Storage and has to stay true to
    /// its name.
    let activePanorama: QuickTakeSerialManager.SavedPanorama?
    let onOpenSavedPanorama: (QuickTakeSerialManager.SavedPanorama) -> Void
    let enhancedPreviewImages: [UInt8: NSImage]
    let availableThumbnails: [UInt8: NSImage]
    let importedPhotoURLs: [UInt8: [URL]]
    let photoQualities: [UInt8: Bool]
    /// User renames; the default caption is derived per cell.
    let photoNames: [UInt8: String]
    let isConnected: Bool

    // MARK: Cell chrome

    let focusedPhotoIndex: UInt8?
    /// True only when `focusedPhotoIndex` got there via the keyboard (arrow
    /// keys) and the gallery still holds keyboard focus — gates the focus
    /// ring so a mouse click never lights it up. See `ContentView`.
    let showKeyboardFocusRing: Bool
    let qualityBadgeSize: CGFloat
    let squareModeHidesGlow: Bool

    // MARK: Orb / Copland

    let apertureOrbActive: Bool
    let coplandIndex: UInt8?
    let coplandShrinkIndex: UInt8?
    let frameStore: ThumbFrameStore

    @Binding var editingName: String
    @FocusState.Binding var focusedField: UInt8?

    let onTap: (UInt8) -> Void
    let onDoubleTap: (UInt8) -> Void
    let onRename: (UInt8, String) -> Void
    let onRevealInFinder: ([URL]) -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // "Camera Storage" is now the window/toolbar title (see
            // navigationTitle). A subtle count appears here whenever photos are
            // selected (selection is ambient — no "select mode").
            // The selection count row is ALWAYS present (its height is reserved)
            // and only the label fades in/out — otherwise selecting the first
            // photo would insert this row and shove the whole grid downward.
            HStack {
                Spacer()
                Text("\(max(selectedPhotoIndices.count, 1)) Selected")
                    .font(isClassicTheme ? Font.classic(12, weight: .semibold) : .subheadline)
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .opacity(selectedPhotoIndices.isEmpty ? 0 : 1)
            }
            .padding(.top, 20)
            .animation(.easeInOut(duration: 0.2), value: selectedPhotoIndices.count)

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(photoIndices, id: \.self) { index in
                    cell(for: index)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: photoIndices.count)
            // Animate deliberate zoom steps, including their column reflow.
            // Window-width changes must track the resize immediately, so the
            // derived column count is not an animation trigger. A live pinch
            // likewise follows the fingers without a trailing spring.
            .animation(isPinching ? nil : .spring(response: 0.5, dampingFraction: 0.85),
                       value: thumbnailWidth)
            // Coordinate the column reflow with the macOS fullscreen transition
            // (~0.5s) so the thumbnails glide between fullscreen and windowed
            // instead of snapping at the end of the resize.
            .animation(.smooth(duration: 0.5), value: isFullScreen)
            // Watch the live grid width; `galleryColumnCount` derives from it +
            // the zoom, so the layout and arrow-key nav stay in sync.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { galleryWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            galleryWidth = newWidth
                        }
                }
            )

            if let activePanorama {
                panoramaBand(activePanorama)
                    // A plain fade. Nothing sits below the band, so there is
                    // no layout for a slide to explain — and it hands over
                    // with the floating panel, where a slide would read as
                    // the picture moving somewhere rather than being
                    // replaced by a bigger copy of itself.
                    .transition(.opacity)
            }

            // Photo info now lives in the toolbar "i" popover (Photos-style),
            // not an auto-on-focus bottom strip.
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focusedPhotoIndex)
        .animation(.easeInOut(duration: 0.22), value: activePanorama?.id)
    }

    // MARK: - Panorama band

    /// The selected photo's panorama, under a heading of its own.
    ///
    /// ONE at a time, and it follows the selection. A session can make
    /// several panoramas, and listing them all turned the band into a
    /// growing pile with nothing tying any entry to the photos above it.
    /// Showing the one that belongs to what is selected makes the band an
    /// answer to "what did these photos become" — which is the only
    /// question it exists to answer. Select nothing, and there is nothing
    /// to answer, so it goes.
    ///
    /// Full grid width rather than a cell, because a panorama IS wide — a
    /// 5:1 strip shrunk into a square tile is unreadable, and the width on
    /// screen is the most honest thing the band can say about it.
    private func panoramaBand(_ panorama: QuickTakeSerialManager.SavedPanorama) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The app already has one way of naming a section — icon,
            // uppercase, caption2 bold — used by CONNECTION, CAMERA,
            // CONTROLS and MAINTENANCE. A second recipe invented for this
            // one heading is how an app starts looking assembled rather
            // than designed, so this is the same component. The rule is
            // the one addition, because unlike the sidebar's stacked
            // sections this heading has to divide a wide open area.
            HStack(spacing: 8) {
                SidebarSectionHeader(title: "Panorama", icon: "pano")
                Rectangle()
                    .fill(isClassicTheme ? AppTheme.platinumShadow.opacity(0.5)
                                         : Color.secondary.opacity(0.18))
                    .frame(height: 1)
            }

            PanoramaBandTile(panorama: panorama,
                             isClassicTheme: isClassicTheme,
                             onOpen: { onOpenSavedPanorama(panorama) },
                             onRevealInFinder: { onRevealInFinder([panorama.image]) })
                // Keyed on the panorama so switching selection between two
                // of them cross-fades rather than swapping the picture
                // inside a tile that never moved — which read as a glitch.
                .id(panorama.id)
                .transition(.opacity)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.22), value: panorama.id)
    }

    /// Gathers one cell's inputs. The derived caption, label and Copland state
    /// come from the shared helpers so this and ContentView (which needs the
    /// same answers for the keyboard rename, the info popover and the orb's
    /// hit-test) can never drift apart.
    private func cell(for index: UInt8) -> some View {
        let savedURLs = importedPhotoURLs[index]
        let isHQ = photoQualities[index]
        let developed = PhotoCell.isCoplandDeveloped(savedURLs)
        let name = PhotoCell.name(for: index, userName: photoNames[index], isCoplandDeveloped: developed)

        return PhotoCell(
            index: index,
            isSelected: selectedPhotoIndices.contains(index),
            isFocused: focusedPhotoIndex == index,
            isKeyboardFocused: showKeyboardFocusRing && focusedPhotoIndex == index,
            squareGrid: squareGrid,
            enhancedImage: enhancedPreviewImages[index],
            thumbnail: availableThumbnails[index],
            isConnected: isConnected,
            isDevelopingShrink: coplandShrinkIndex == index,
            isCoplandDeveloped: developed,
            squareModeHidesGlow: squareModeHidesGlow,
            photoName: name,
            accessibilityLabel: PhotoCell.accessibilityLabel(name: name, isHQ: isHQ, savedURLs: savedURLs),
            isHQ: isHQ,
            savedURLs: savedURLs,
            qualityBadgeSize: qualityBadgeSize,
            // The frame-tracking gate, kept exactly as it was: permanent
            // tracking wrote the frame dict on every scrolled frame and
            // caused the stutter fixed in v1.37.
            tracksFrame: apertureOrbActive || coplandIndex == index,
            frameStore: frameStore,
            editingName: $editingName,
            focusedField: $focusedField,
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onRename: onRename,
            onRevealInFinder: onRevealInFinder,
            isPartOfPanorama: panoramaSlots.contains(index),
            canMakePanorama: canMakePanorama,
            onMakePanorama: onMakePanorama,
            thumbnailWidth: thumbnailWidth,
            onOpenPanorama: { onOpenPanorama(index) },
            onImportPhoto: { onImportPhoto(index) })
    }
}
