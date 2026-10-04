//
//  PhotoCell.swift
//  SwiftTake
//
//  One gallery cell: the tile plus everything wrapped around it — the caption
//  and its rename field, the quality and imported badges, the selection wash,
//  the drag, the context menu, and the taps.
//
//  Extracted for the same reason as PhotoThumbnail: SwiftUI re-evaluates at
//  View-struct granularity, so while this lived in ContentView's body every
//  cell was rebuilt on any published change on the manager — each progress
//  tick of every import. As its own struct a cell re-renders only when ITS
//  inputs change, and the expensive part (PhotoThumbnail) is handed plain
//  values, so the tile can be skipped even on the passes where the wrapper
//  is not.
//
//  Inputs are explicit — values, bindings, and closures. Reading the manager
//  from the environment here would re-widen the dependency to "any change on
//  the manager" and give the split straight back.
//
//  The mutations stay with the state: the taps hand back through closures so
//  focus, selection and the selection anchor keep living on ContentView.
//

import SwiftUI

struct PhotoCell: View {
    let index: UInt8
    let isSelected: Bool
    let isFocused: Bool
    /// True only when this cell's focus arrived via the keyboard (arrow
    /// keys) rather than a click — draws the accent focus ring. A mouse
    /// click, or hovering with no focus at all, never sets this.
    let isKeyboardFocused: Bool
    let squareGrid: Bool

    // Tile inputs, passed straight through to PhotoThumbnail as plain values.
    /// The colour preview, once decoded — nil until then.
    let enhancedImage: NSImage?
    /// The camera's B&W thumbnail; the loading animation stands in when nil.
    let thumbnail: NSImage?
    let isConnected: Bool
    /// True while a Copland develop is squeezing this photo small.
    let isDevelopingShrink: Bool
    let isCoplandDeveloped: Bool
    let squareModeHidesGlow: Bool

    /// The caption: a user rename if there is one, else "Photo N"/"Copland N".
    let photoName: String
    /// Composed VoiceOver label — name, then quality and import state.
    let accessibilityLabel: String
    /// nil until the camera reports this photo's quality.
    let isHQ: Bool?
    /// Files on disk for this photo. nil means never imported — distinct from
    /// an empty array, and the two are told apart below.
    let savedURLs: [URL]?
    let qualityBadgeSize: CGFloat

    /// True only while the orb machinery can actually use this cell's frame —
    /// see the tracking `.background`.
    let tracksFrame: Bool
    /// Frame writes land in the box rather than in ContentView `@State`.
    let frameStore: ThumbFrameStore

    @Binding var editingName: String
    @FocusState.Binding var focusedField: UInt8?

    let onTap: (UInt8) -> Void
    let onDoubleTap: (UInt8) -> Void
    let onRename: (UInt8, String) -> Void
    let onRevealInFinder: ([URL]) -> Void
    /// This frame went into a saved panorama, so opening it opens that
    /// panorama instead of importing the frame. Badged, so that is visible
    /// before it happens rather than after.
    let isPartOfPanorama: Bool
    /// True when the current selection could become a panorama (two or more
    /// photos). The item only appears on a cell that is part of that
    /// selection, the way Finder acts on the selection you right-clicked
    /// into rather than silently retargeting.
    let canMakePanorama: Bool
    let onMakePanorama: () -> Void
    /// The cell's current width, so chrome can give ground when the grid
    /// is zoomed small rather than sitting at one fixed size.
    var thumbnailWidth: Double = 200
    /// Opens the panorama this frame went into. Nil when it went into none.
    var onOpenPanorama: (() -> Void)? = nil
    /// Imports this one photo — kept reachable because opening a linked
    /// frame now shows the panorama instead of importing it.
    var onImportPhoto: (() -> Void)? = nil

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        VStack(spacing: squareGrid ? 0 : 6) {
            tile

            // The filename + badge caption is hidden in square mode
            // so the thumbnails sit flush as a Photos-style contact
            // sheet (details still live in the toolbar "i" popover).
            if !squareGrid {
                caption
            }
        }
        .padding(squareGrid ? 0 : 8)
        // Classic uses the period selection-blue wash; other themes the accent tint.
        .background(isSelected
            ? (isClassicTheme ? AppTheme.platinumHighlight.opacity(0.20) : Color.accentColor.opacity(0.1))
            : (isFocused
                ? (isClassicTheme ? AppTheme.platinumHighlight.opacity(0.10) : Color.secondary.opacity(0.08))
                : Color.clear))
        .cornerRadius(squareGrid ? 0 : 8)
        // Keyboard focus ring — on top of the existing wash above, never in
        // place of it, so mouse/click focus keeps today's look exactly.
        .overlay {
            if isKeyboardFocused {
                RoundedRectangle(cornerRadius: squareGrid ? 0 : 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        // The cell's context menu reveals the imported files and
        // nothing else. Importing and re-importing live on the
        // deliberate surfaces — the toolbar's Import button, the
        // Camera menu, and the develop orb — where the mode being
        // applied is visible before the action runs; a hidden
        // right-click that silently re-runs the colour pipeline
        // was too easy to trigger by accident.
        //
        // An un-imported photo has nothing to reveal, so it gets
        // no menu at all rather than an empty popup.
        .contextMenu {
            // Keep panorama creation available alongside the selected photos.
            // A linked frame opens its panorama on double-click, so its own
            // import has to stay reachable somewhere. Both are named here
            // rather than one being implied.
            if isPartOfPanorama, let open = onOpenPanorama {
                Button("Open Panorama") { open() }
                if let importOne = onImportPhoto, savedURLs == nil {
                    Button("Import Photo") { importOne() }
                }
                Divider()
            }
            if isSelected && canMakePanorama {
                Button("Make Panorama…") { onMakePanorama() }
                Divider()
            }
            let urls = savedURLs ?? []
            if !urls.isEmpty {
                Button("Show in Finder") {
                    onRevealInFinder(urls)
                }
            }
        }
        // Double-click opens the photo in QuickLook (the native
        // "open" gesture) — works for imported and on-camera photos.
        // Importing is the toolbar/menu's job; revealing in Finder is
        // the folder badge + context menu.
        .onTapGesture(count: 2) {
            onDoubleTap(index)
        }
        .onTapGesture {
            onTap(index)
        }
        .disabled(!isConnected && savedURLs == nil)
        .onDrag {
            // Prefer the rendered image file over the raw .qtk
            // archive so drops into Photos / Mail / Finder /
            // any sane app land an openable image.
            let urls = savedURLs ?? []
            let preferred = urls.first(where: { $0.pathExtension.lowercased() != "qtk" }) ?? urls.first
            if let preferred {
                return NSItemProvider(object: preferred as NSURL)
            }
            return NSItemProvider()
        }
        .id(index)   // scroll target for ScrollViewReader (focus follow)
        // One VoiceOver element per photo, with a composed label
        // (name, quality, import state). The folder action stays
        // reachable through the cell's context menu.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var tile: some View {
        PhotoThumbnail(
            index: index,
            isSelected: isSelected,
            isFocused: isFocused,
            enhancedImage: enhancedImage,
            thumbnail: thumbnail,
            hasImportedFiles: savedURLs != nil,
            isConnected: isConnected,
            isDevelopingShrink: isDevelopingShrink,
            isCoplandDeveloped: isCoplandDeveloped,
            squareModeHidesGlow: squareModeHidesGlow,
            squareGrid: squareGrid)
            // A frame that went into a saved panorama says so, centred along
            // the bottom of the image. Centred rather than tucked in a
            // corner because it is a statement about the whole photo, not a
            // status pip like the HQ badge or the imported folder — and
            // because every frame in the run carries one, so a row of them
            // lines up.
            .overlay(alignment: .bottom) {
                if isPartOfPanorama {
                    // Sized down with the tile below ~150pt. At minimum
                    // zoom a fixed capsule spanned most of the thumbnail's
                    // width — far heavier than the small corner pills
                    // Photos.app uses at the same scale — so the badge
                    // gives ground rather than dominating the picture it
                    // is annotating.
                    let tight = thumbnailWidth < 150
                    Text("Panorama")
                        .font(isClassicTheme ? .classic(tight ? 8 : 9, weight: .bold)
                                             : .system(size: tight ? 8.5 : 10,
                                                       weight: .semibold))
                        .foregroundStyle(isClassicTheme ? AppTheme.platinumText : .white)
                        .padding(.horizontal, tight ? 5 : 8)
                        .padding(.vertical, tight ? 2 : 3)
                        .background {
                            if isClassicTheme {
                                // OS 9 had no glass. A raised Platinum chip
                                // is the period-correct way to say the same
                                // thing.
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(AppTheme.platinumFace)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(AppTheme.platinumShadow.opacity(0.8), lineWidth: 1))
                            } else {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().fill(.black.opacity(0.28))
                            }
                        }
                        .padding(.bottom, tight ? 5 : 7)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            // Record the image area's global frame so the Copland
            // orb can hit-test which thumbnail it was dropped on —
            // but ONLY while the orb machinery can actually use it
            // (orb out, or a develop in flight). Tracking
            // permanently meant every visible cell wrote this
            // @State dict on every scrolled frame: a whole-body
            // re-evaluation per scroll tick, felt as stutter and
            // worst while an import was also publishing progress.
            .background {
                // While the orb is OUT every cell tracks (drop
                // hit-testing needs them all); during a develop
                // only the DEVELOPING cell tracks — the bubble
                // needs just its target. Writes go to the
                // ThumbFrameStore box, so a scroll-time frame
                // update re-renders only the bubble's reader,
                // not the whole ContentView body.
                if tracksFrame {
                    GeometryReader { g in
                        Color.clear
                            .onAppear { frameStore.frames[index] = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in
                                frameStore.frames[index] = f
                            }
                    }
                }
            }
    }

    private var caption: some View {
        HStack(spacing: 4) {
            if focusedField == index {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(isClassicTheme ? Font.classic(11) : .caption)
                    .focused($focusedField, equals: index)
                    .onSubmit {
                        onRename(index, editingName)
                        focusedField = nil
                    }
            } else {
                // The wordmark egg's Keynote-style typewriter,
                // reused: "Photo N" backspaces away and
                // "Copland N" types in after a develop — and
                // back again when a re-import retires it.
                TypewriterText(photoName)
                    .font(isClassicTheme ? Font.classic(11) : .caption)
                    .foregroundColor((isSelected || isFocused) ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .highPriorityGesture(TapGesture(count: 2).onEnded {
                        editingName = photoName
                        focusedField = index
                    })
            }

            Spacer()

            if let isHQ {
                if isHQ {
                    // HQ gets the gold-dust easter egg. See HQBadgeView.
                    HQBadgeView()
                } else {
                    // SQ stays plain — keeps the easter egg special.
                    Text("SQ")
                        .font(.system(size: qualityBadgeSize, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .classicHelp("Standard Quality")
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity).animation(.spring().delay(0.05)),
                            removal: .opacity
                        ))
                }
            }

            if let savedURLs, !savedURLs.isEmpty {
                Button {
                    onRevealInFinder(savedURLs)
                } label: {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                        .font(.caption2)
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9, pressedOpacity: 0.85, shadowRadius: 2))
                .classicHelp("Show in Finder")
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity).animation(.spring().delay(0.1)), removal: .opacity))

                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity).animation(.spring().delay(0.2)), removal: .opacity))
            }
        }
        // Animate the whole badge row when the
        // imported-files state flips so HQ glides left
        // instead of snapping when the folder + tick
        // pop in. Spring is tuned to feel like Photos'
        // import-complete confirmation.
        .animation(
            .spring(response: 0.45, dampingFraction: 0.78),
            value: (savedURLs?.isEmpty == false)
        )
    }
}

// MARK: - Derived cell inputs

/// The pure derivations that turn a photo's manager state into what a cell
/// displays. They live here, next to the view that shows them, and are static
/// so both GalleryGrid (building cells) and ContentView (which needs the same
/// answers for the keyboard rename, the info popover and the orb's hit-test)
/// call one implementation instead of keeping two in step.
extension PhotoCell {
    /// Uses the generated PNG naming convention for the gallery's developed state.
    static func isCoplandDeveloped(_ savedURLs: [URL]?) -> Bool {
        (savedURLs ?? []).contains(where: CoplandArtifactPolicy.isDisplayArtifact)
    }

    /// The caption. User renames always win; the default flips to "Copland N"
    /// while the photo carries a copland develop, and back to "Photo N" once a
    /// re-import retires it. The gallery caption view is a TypewriterText, so
    /// the flip literally retypes itself.
    static func name(for index: UInt8, userName: String?, isCoplandDeveloped: Bool) -> String {
        userName ?? (isCoplandDeveloped ? "Copland \(index + 1)" : "Photo \(index + 1)")
    }

    /// Composed VoiceOver label for a gallery cell: name, then quality and
    /// import state when known.
    static func accessibilityLabel(name: String, isHQ: Bool?, savedURLs: [URL]?) -> String {
        var parts = [name]
        if let isHQ {
            parts.append(isHQ ? "High Quality" : "Standard Quality")
        }
        if let savedURLs, !savedURLs.isEmpty {
            parts.append("Imported")
        }
        return parts.joined(separator: ", ")
    }
}
