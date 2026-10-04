// MARK: - ContentView
//
// The main window: NavigationSplitView with a sidebar (Connection /
// Camera / Controls / Maintenance) on the left and the photo gallery
// on the right.
//
// The sidebar is responsive: each section honours a `userWants*`
// preference, and a `recalculateSections()` pass gates which sections
// render in priority order (connection → camera → controls). Entering
// fullscreen expands all three. See the doc comment on
// `recalculateSections` for details.
//
// The four sidebar sections live in `SidebarSections.swift` and the
// gallery in `GalleryGrid.swift` / `PhotoCell.swift` / `PhotoThumbnail.
// swift` — view structs with declared inputs, so a published change on
// the manager reaches only the ones that read what changed.
//
// Other moving parts:
//   - `WindowConfigurator` (called via `.background`) flips the host
//     `NSWindow` into full-size-content-view mode so overlays cover
//     the title bar (matters for the Connecting blur in fullscreen).
//   - HQ/SQ badges on each gallery thumbnail; HQ has a small
//     gold-dust easter egg (see `HQBadgeView`).

import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct ContentView: View {
    @EnvironmentObject private var serialManager: QuickTakeSerialManager
    @State private var showingCameraControls = false
    @State private var showingEraseConfirmation = false
    @State private var showingOverwriteConfirmation = false
    @State private var focusedPhotoIndex: UInt8? = nil
    /// True when `focusedPhotoIndex` last moved via the keyboard (arrow keys)
    /// rather than a click — drives the keyboard focus ring in `PhotoCell`,
    /// which a mouse click should never light up.
    @State private var focusedViaKeyboard = false
    /// True while a file drag hovers the window — drives the
    /// drop-highlight overlay. See the `.dropDestination` below.
    @State private var isQTKDropTargeted = false
    @State private var pendingQTKDrop: QTKDropBatch?
    @State private var dropForPanorama: QTKDropBatch?
    @State private var dropForConversion: QTKDropBatch?
    /// Anchor for ⇧-click range selection (the last plain/⌘-clicked photo).
    /// Selection is ambient now (Finder/Photos-style) — there's no "select mode".
    @State private var selectionAnchor: UInt8? = nil
    @FocusState private var galleryHasKeyboardFocus: Bool
    /// Set by keyboard / QuickLook navigation so the next focus change scrolls
    /// the photo into view. Clicks leave it false — a click shouldn't reflow the
    /// grid under the pointer.
    @State private var autoScrollToFocus = false
    /// SQ quality-badge size — matches the HQ badge and scales with Dynamic
    /// Type while staying pixel-identical at the default text size.
    @ScaledMetric(relativeTo: .caption2) private var qualityBadgeSize: CGFloat = 9

    // Easter egg: drag the status bubble out of the sidebar and fling it around
    // the window; it springs home on release. While dragging it floats in a
    // window-level overlay so the sidebar's clipping can't contain it.
    @State private var isDraggingStatus = false
    /// Shape morph: 0 = the resting capsule, 1 = the round orb. Animated so the
    /// single bubble physically balls up and reforms — never a swap/flicker.
    @State private var statusMorph: Double = 0
    /// The capsule's resting rect in global (screen) coordinates (size + centre)
    /// so the bubble overlay sits exactly where the sidebar footer reserves it.
    @State private var statusHomeRect: CGRect = .zero
    /// Tracks whether the sidebar is showing, so the status bubble (a window-level
    /// overlay, deliberately outside the sidebar's clip) can hide when the sidebar
    /// is collapsed instead of floating over the detail pane.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Final-reward easter egg: once BOTH aperture eggs are unlocked, the mark
    /// itself can be grabbed and flung like the status orb — it balls up into a
    /// larger glass bubble with the 90s Apple rainbow swirling inside and a soft
    /// golden glow. `apertureOrbGlobal` tracks the cursor; `apertureOrbActive`
    /// is true from grab until it has sprung home; `apertureOrbScale` morphs it.
    @State private var apertureOrbGlobal: CGPoint = .zero
    /// Recent orb positions (newest last) — drives a curved comet tail.
    @State private var apertureTrail: [CGPoint] = []
    /// Fades the comet tail out on release (slow dissipate) before it's cleared.
    @State private var apertureTrailFade: Double = 1
    /// 0 while dragging → 1 on release; collapses the comet tail toward home so it
    /// follows the orb back instead of vanishing in place.
    @State private var apertureReturn: Double = 0
    /// Drives the orb's flight home by STEPPING the model position (a
    /// withAnimation return snaps the model instantly and only tweens the
    /// presentation — the comet tail would have nothing real to sample).
    /// Cancelled on a re-grab or a mid-flight lockout.
    @State private var apertureReturnTask: Task<Void, Never>?
    @State private var isDraggingAperture = false
    @State private var apertureOrbActive = false
    @State private var apertureOrbScale: CGFloat = 1.0
    /// Jelly squash/stretch for the orb (mirrors the status orb, with more give).
    @State private var apertureStretch: CGFloat = 0
    @State private var apertureStretchAngle: Angle = .zero
    /// 0 = still the aperture mark (what you grabbed), 1 = fully the orb. Morphs
    /// up on grab and back down on release so it reforms into the mark.
    @State private var apertureMorph: CGFloat = 0
    /// The bubble's current centre in global coordinates — tracks the cursor tip
    /// while dragging, springs back to the home centre on release.
    @State private var statusOrbGlobal: CGPoint = .zero
    /// Jelly deformation: how much the orb is squashed/stretched (0 = round)
    /// and the direction of travel it stretches along. Driven by drag velocity,
    /// springs back to 0 with a wobble when it slows or is released.
    @State private var statusStretch: CGFloat = 0
    @State private var statusStretchAngle: Angle = .zero
    /// Overall bubble scale — 1 normally; drops to 0 as the orb is "absorbed"
    /// into the aperture, then grows 0→1 as the status bar reforms at the bottom.
    @State private var statusAbsorbScale: CGFloat = 1

    // MARK: Copland easter egg
    // Drag the unlocked aperture orb onto a gallery thumbnail and release: the
    // orb flows into a square over the photo, "develops" it (a normal import /
    // re-import runs underneath, with gold sparkles on the progress bar), then
    // leaves the photo framed in a Mac OS 9 Platinum window. Once per photo per
    // session; afterwards the aperture grows back into its sidebar home.
    /// Live global frame of each thumbnail's image area — for orb hit-testing.
    // NOT a @State dictionary — see ThumbFrameStore for why (mid-develop
    // scroll lag: every frame write re-evaluated this whole body).
    @State private var thumbnailFrames = ThumbFrameStore()
    /// Gallery scroll state for the Classic OS 9 scrollbar: a bindable position
    /// (so the custom thumb can drive scrolling) and the live geometry the bar
    /// reads. Only consumed in the Classic theme.
    @State private var galleryScrollPosition = ScrollPosition(edge: .top)
    @State private var galleryScrollMetrics = ClassicScrollMetrics()
    /// Mirrors `gallerySquareGrid` for the Copland glow's VISIBILITY only.
    /// The mirror exists so the glow's fade carries its own explicit
    /// `withAnimation` (fast hide / slow swell — see the onChange at the
    /// window root) in a separate transaction from the mode switch itself:
    /// animations keyed directly to `gallerySquareGrid` also captured the
    /// glow's geometry change and dragged gold across the resizing cell.
    @State private var squareModeHidesGlow = false
    /// The photo currently being developed (drives the overlay + bar sparkles).
    @State private var coplandIndex: UInt8? = nil
    @State private var coplandTask: Task<Void, Never>?
    @State private var coplandTaskID: UUID?
    /// While set, this photo renders SMALL (like an un-imported one) so an
    /// already-imported photo shrinks first, then develops + expands — matching
    /// the un-imported flow. Cleared on completion so it grows back to full.
    @State private var coplandShrinkIndex: UInt8? = nil
    /// True while the develop sequence runs (gates the orb layer off).
    @State private var coplandActive = false
    /// 0 = orb circle at the release point, 1 = square filling the thumbnail.
    @State private var coplandMorph: CGFloat = 0
    /// Fades the develop bubble out once the import completes.
    @State private var coplandBubbleOpacity: Double = 1
    /// Where the orb was released (global) — the morph starts here.
    @State private var coplandReleasePoint: CGPoint = .zero

    // Hidden colour-collection easter egg: drop the orb onto the aperture mark
    // and it absorbs, glowing the logo that colour for a beat. Once per colour.
    @State private var apertureRect: CGRect = .zero
    @State private var apertureGlowColor: Color = .green
    @State private var apertureGlowLevel: Double = 0
    @AppStorage(PrefKey.collectedStatusColors) private var collectedStatusColorsRaw = ""
    /// Set once all three status colours have been absorbed and the user winks
    /// the aperture (7 clicks). Persists; gates the unlocked rainbow setting.
    @AppStorage(PrefKey.rainbowUnlocked) private var rainbowUnlocked = false
    @FocusState private var focusedField: UInt8?
    @Namespace private var sidebarGlassNamespace
    @State private var editingName: String = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.isClassicTheme) private var isClassicTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastOffset: CGFloat = -100
    @State private var isCameraControlsExpanded = false
    @State private var isConnectionExpanded = true
    @State private var isCameraExpanded = true
    @AppStorage(PrefKey.hasSeenWelcome) private var hasSeenWelcome = false
    @State private var showingWelcome = false
    @State private var showingConnectionHelp = false
    // Section visibility preferences ("show this section if there's room?").
    // Connection and Camera default open on launch; Camera Controls defaults
    // closed, then behaves dynamically with the other two. After launch all
    // three are honoured by `recalculateSections()` in priority order
    // (connection → camera → controls). Manual collapse sets the relevant
    // preference to `false`; entering fullscreen forces all three to `true`.
    @State private var userWantsConnectionExpanded = true
    @State private var userWantsCameraExpanded = true
    @State private var userWantsCameraControlsExpanded = false
    @State private var isFullScreen = false
    @State private var sidebarHeight: CGFloat = 0
    /// Last measured gallery width, fed by a transparent GeometryReader behind
    /// the LazyVGrid. Combined with the user's zoom (`galleryThumbnailWidth`) it
    /// derives the live column count.
    @State private var galleryWidth: CGFloat = 0
    /// User-adjustable thumbnail size (⌘+/⌘−, View menu, or trackpad pinch),
    /// persisted across launches. Drives the target cell width for the gallery.
    @AppStorage(PrefKey.galleryZoom) private var galleryThumbnailWidth: Double = ContentView.galleryZoomDefault
    /// Thumbnail width captured at the start of a pinch, so the magnification
    /// scales from a stable base instead of compounding each frame.
    @State private var pinchBaseWidth: Double? = nil
    /// True while a trackpad pinch is in progress — disables the size-tween so
    /// thumbnails track the fingers directly (the ⌘+/− steps still glide).
    @State private var isPinchingGallery = false
    /// Square-cropped grid (Photos' square mode) vs native 4:3 aspect grid.
    /// Persisted; toggled from the toolbar.
    @AppStorage(PrefKey.gallerySquareGrid) private var gallerySquareGrid = false
    /// Start collapsed in each new window; keep the user's choice while open.
    @State private var cameraControlsExpanded = false
    /// Whether the focused photo's info popover (the toolbar "i") is showing.
    @State private var showingPhotoInfo = false
    @State private var showingImportOptions = false
    /// The saved panorama the floating viewer is showing, if any.
    @State private var viewingPanorama: QuickTakeSerialManager.SavedPanorama?
    /// Set while the floating panel is opening or open, so the band gets
    /// out of the way first. See `openPanoramaViewer`.
    @State private var bandYieldsToViewer = false
    @State private var showingSelectionMenu = false

    /// Live column count, derived from the measured width and the current zoom.
    /// Computed (not stored) so it updates the instant either changes — the grid
    /// reads it, so changing zoom animates the reflow (Magic Move).
    private var galleryColumnCount: Int { Self.columnCount(forWidth: galleryWidth, target: galleryThumbnailWidth, spacing: effectiveSpacing) }

    /// The gallery caption for a photo. The derivation itself lives on
    /// `PhotoCell` so the grid, which builds captions per cell, and the
    /// keyboard rename and info popover here all read one implementation.
    private func getPhotoName(for index: UInt8) -> String {
        PhotoCell.name(for: index,
                       userName: serialManager.photoNames[index],
                       isCoplandDeveloped: isCoplandDeveloped(index))
    }

    // Gallery sizing. The cell TARGET is user-adjustable (zoom); spacing + the
    // zoom bounds are fixed. Larger thumbnails read better for a photo utility
    // and make the grow-into-the-full-image transition more impactful.
    static let gallerySpacing: CGFloat = 18
    static let galleryZoomMin: Double = 110
    static let galleryZoomMax: Double = 320
    static let galleryZoomStep: Double = 28
    static let galleryZoomDefault: Double = 168

    /// Inter-cell spacing: a comfortable gap in aspect mode, but ZERO in square
    /// mode so the thumbnails sit flush against each other like Photos' square
    /// (contact-sheet) view.
    private var effectiveSpacing: CGFloat { gallerySquareGrid ? 0 : Self.gallerySpacing }

    /// Explicit columns keep layout and keyboard navigation in sync. Window
    /// resizing updates them immediately; deliberate zoom steps animate in
    /// GalleryGrid. Each cell flexes around the target to fill the row evenly.
    private var gridColumns: [GridItem] {
        let target = CGFloat(galleryThumbnailWidth)
        return Array(
            repeating: GridItem(.flexible(minimum: target * 0.85, maximum: target * 1.35),
                                spacing: effectiveSpacing),
            count: max(1, galleryColumnCount)
        )
    }

    /// How many gallery columns fit `width` at the given cell `target` and
    /// `spacing`, so the layout and arrow-key navigation always agree.
    static func columnCount(forWidth width: CGFloat, target: Double, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (CGFloat(target) + spacing)))
    }

    /// Step the thumbnail zoom (toolbar −/+ buttons), clamped. The grid reflow
    /// is animated by the gallery's own `.animation(value: galleryThumbnailWidth)`
    /// — we deliberately DON'T wrap this in `withAnimation`, which would pull the
    /// whole toolbar (e.g. the info button's glass) into the transaction and make
    /// it flash on every ±.
    private func zoomGallery(by delta: Double) {
        galleryThumbnailWidth = min(max(galleryThumbnailWidth + delta,
                                        Self.galleryZoomMin), Self.galleryZoomMax)
    }

    var body: some View {
        ZStack {
            ZStack {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    GeometryReader { sidebarGeo in
                    // The section list scrolls (see `sidebarStatusFooter`),
                    // so one consistent set of spacing/padding metrics is used
                    // at every sidebar height. A height-dependent `compact`
                    // flag was tried but snapped visibly as the window crossed
                    // its threshold, re-spacing every section in one frame.
                    // Outer container: the scroll area fills the whole sidebar
                    // and the sticky status footer is OVERLAID on its bottom
                    // band. The footer never scrolls and is always painted in
                    // front, so the connection / import / error state stays
                    // visible regardless of how much content is in the sections
                    // above — but content now passes BENEATH it through the
                    // fade mask, rather than stopping dead at a reserved band.
                    VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        SidebarBrandHeader(
                            isConnected: serialManager.isConnected,
                            cameraShortName: serialManager.selectedModel.profile.shortName,
                            glowColor: apertureGlowColor,
                            glowLevel: apertureGlowLevel,
                            rainbowUnlocked: rainbowUnlocked,
                            phantomSecretUnlocked: serialManager.phantomSecretUnlocked,
                            allStatusColorsCollected: allStatusColorsCollected,
                            allPhantomsAbsorbed: serialManager.allPhantomsAbsorbed,
                            fullyUnlocked: apertureFullyUnlocked,
                            orbOut: apertureOrbActive,
                            markRect: $apertureRect,
                            onUnlockRainbow: { rainbowUnlocked = true },
                            onUnlockPhantom: { serialManager.unlockPhantomSecret() },
                            dragGesture: apertureDragGesture)
                        .padding(.vertical, 2)
                        .padding(.bottom, 8)

                        SidebarConnectionSection(
                            isConnected: serialManager.isConnected,
                            portPath: serialManager.detectedPortPath,
                            modelSerialAvailable: serialManager.selectedModelSerialAvailable,
                            modelDisplayName: serialManager.selectedModel.displayName,
                            isBusy: serialManager.isBusy,
                            namespace: sidebarGlassNamespace,
                            onConnect: { serialManager.connectToDetectedCamera() })

                        // Camera info — always open when connected, but hidden
                        // automatically when the sidebar is too short for it.
                        if serialManager.isConnected, let metadata = serialManager.metadata,
                           sidebarGeo.size.height >= 340 {
                            SidebarCameraSection(
                                metadata: metadata,
                                modelName: serialManager.selectedModel.rawValue,
                                supportsCameraControlUI: serialManager.selectedModel.supportsCameraControlUI,
                                batteryWarning: serialManager.batteryWarning,
                                storageWarning: serialManager.storageWarning,
                                namespace: sidebarGlassNamespace,
                                onSetCameraName: { newName in serialManager.setCameraName(newName) })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // Live camera controls — only for capable cameras
                        // (QT100/150), inline unless popped out. Keep the header
                        // accessible in short windows; expanded controls scroll.
                        if serialManager.isConnected,
                           serialManager.selectedModel.supportsCameraControlUI,
                           !serialManager.isCameraControlPoppedOut {
                            SidebarControlsSection(
                                expanded: $cameraControlsExpanded,
                                namespace: sidebarGlassNamespace,
                                onPopOut: {
                                    serialManager.isCameraControlPoppedOut = true
                                    openWindow(id: "cameraControls")
                                })
                                // The disclosure spring lives on the SECTIONS'
                                // PARENT below (one clock), so the Maintenance
                                // buttons ride the same curve as the caret and
                                // the controls' enter/exit.
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // Maintenance actions — always shown when connected.
                        if serialManager.isConnected {
                            SidebarMaintenanceSection(
                                isBusy: serialManager.isBusy,
                                isRefreshing: serialManager.isRefreshing,
                                areThumbnailsLoading: serialManager.areThumbnailsLoading,
                                supportsSerialErase: serialManager.selectedModel.supportsSerialErase,
                                onRefresh: { serialManager.refreshCameraMetadata() },
                                onErase: { showingEraseConfirmation = true },
                                onDisconnect: { serialManager.disconnectCamera() })
                        }

                    }
                    // One clock for the Controls disclosure: the spring sits
                    // on the sections' PARENT so the caret twist, the
                    // controls' enter/exit, AND the sections below
                    // (Maintenance) all ride the same curve. Scoped to the
                    // controls section alone, the siblings' layout shift
                    // happened OUTSIDE the animated subtree and snapped to
                    // its final spot. Value-diff, not withAnimation
                    // — the @AppStorage write re-renders outside any
                    // transaction (see the caret button's comment).
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: cameraControlsExpanded)
                    .padding(.horizontal, 14)
                    // Classic starts the sidebar on the same line as the
                    // detail pane. The Platinum control row heads the detail
                    // side only — "leaving the sidebar to rise cleanly to the
                    // title bar" — but rising cleanly to a DIFFERENT height
                    // than the row beside it reads as a notch above the
                    // camera badge rather than as clean space.
                    //
                    // 4, not 14: the row insets its own content by 5 inside
                    // the Platinum band and the brand badge carries 2 of its
                    // own, which puts the badge's top level with the row's.
                    // Modern keeps the roomier 14 — there is no banded header
                    // there for anything to line up with.
                    .padding(.top, isClassicTheme ? 4 : 14)
                    .padding(.bottom, 14)
                    // Extra bottom inset the height of the footer band: fully
                    // scrolled down, every control can clear the fade zone and
                    // be read/clicked; the fade-under-the-bubble only shows
                    // for content mid-scroll.
                    .padding(.bottom, Self.bottomBarHeight)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Follow window resizing directly. The disclosure above
                    // has its own animation, independent of the live height.
                    }
                    // Fade over the footer band so sidebar content SLIDES
                    // BENEATH the status bubble and dissolves, instead of
                    // stopping dead at a reserved empty band (which read as a
                    // too-large blank backdrop behind the bubble).
                    // Content stays fully crisp down to the footer line — the
                    // line level with the detail pane's progress bar, which
                    // must KEEP matching (the two intersecting is intentional) —
                    // then dissolves across the band, mostly gone by where the
                    // bubble sits so the bubble stays readable over its glass.
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle().fill(Color.black)
                            // The stops trace an ease-in curve: near-flat for
                            // the first ~20% so there is no visible seam where
                            // solid meets fade (an abrupt slope change reads
                            // as a hard line — Mach banding), then steepening
                            // so content is still mostly gone under the bubble.
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black.opacity(0.96), location: 0.10),
                                    .init(color: .black.opacity(0.84), location: 0.22),
                                    .init(color: .black.opacity(0.62), location: 0.36),
                                    .init(color: .black.opacity(0.38), location: 0.52),
                                    .init(color: .black.opacity(0.18), location: 0.68),
                                    .init(color: .black.opacity(0.06), location: 0.84),
                                    .init(color: .black.opacity(0.0), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: Self.bottomBarHeight)
                        }
                    )
                    // Sticky status footer — the Liquid Glass status bubble,
                    // OVERLAID on the scroll area's bottom band so overflowing
                    // section content can never push it off the bottom (and now
                    // passes beneath it through the fade above).
                    .overlay(alignment: .bottom) { sidebarStatusFooter() }
                    // end ScrollView
                    } // end outer VStack(spacing: 0)
                    .frame(width: sidebarGeo.size.width, height: sidebarGeo.size.height, alignment: .top)
                    .onAppear {
                        sidebarHeight = sidebarGeo.size.height
                        recalculateSections()
                    }
                    // No recalculateSections on height change: the section
                    // list is wrapped in a ScrollView, so overflow scrolls
                    // instead of forcing sections to collapse. Collapsing on
                    // height caused a visible snap at certain window heights.
                    .onChange(of: serialManager.isConnected) { _, isConnected in
                        if isConnected {
                            // On connect, restore all section preferences to
                            // visible. Whether each one appears still depends
                            // on `recalculateSections()`, which enforces the
                            // priority order (connection → camera → controls).
                            userWantsConnectionExpanded = true
                            userWantsCameraExpanded = true
                            userWantsCameraControlsExpanded = true
                        } else if serialManager.isCameraControlPoppedOut {
                            // Losing the camera strands the popped-out
                            // controls: every button on them talks to a
                            // camera that is no longer on the line. The
                            // inline section already vanishes with the
                            // connection; the window has to be told.
                            dismissWindow(id: "cameraControls")
                            serialManager.isCameraControlPoppedOut = false
                        }
                        recalculateSections()
                    }
                    // Switching to a model with no live-control UI (e.g. the
                    // QT200, whose Apple driver exposes no remote shutter /
                    // flash / quality / date) dismisses any popped-out Camera
                    // Controls window and lets `recalculateSections` collapse
                    // the sidebar Controls section. The pop-out window is the
                    // only surface that can outlive a model switch, so it
                    // needs an explicit dismiss.
                    .onChange(of: serialManager.selectedModel) { _, newModel in
                        if !newModel.supportsCameraControlUI,
                           serialManager.isCameraControlPoppedOut {
                            dismissWindow(id: "cameraControls")
                            serialManager.isCameraControlPoppedOut = false
                        }
                        recalculateSections()
                    }
                    // Fullscreen transitions via async notification streams —
                    // the house Task idiom (these were the file's last Combine
                    // publishers).
                    .task {
                        for await _ in NotificationCenter.default.notifications(named: NSWindow.didEnterFullScreenNotification) {
                        isFullScreen = true
                        // Fullscreen always shows everything that can be
                        // expanded, regardless of whether the camera is
                        // connected. The recalculate pass still gates the
                        // controls section's content on `isConnected`, but the
                        // preference is set so it reveals the moment a
                        // connection comes up.
                        userWantsConnectionExpanded = true
                        userWantsCameraExpanded = true
                        userWantsCameraControlsExpanded = true
                        // If the camera-controls were popped out into a
                        // separate window, re-dock them in the sidebar so
                        // fullscreen actually shows them in place.
                        if serialManager.isCameraControlPoppedOut {
                            dismissWindow(id: "cameraControls")
                            serialManager.isCameraControlPoppedOut = false
                        }
                        recalculateSections()
                        }
                    }
                    .task {
                        for await _ in NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification) {
                            isFullScreen = false
                        }
                    }
                    } // GeometryReader
                    // Fixed, non-resizable sidebar — a constant width gives the
                    // layout a stable design grid (the user can't drag it wider/
                    // narrower). min == ideal == max pins the split-view column.
                    .frame(width: 260)
                    // Classic: the sidebar is a FLAT Platinum panel — the
                    // pinstripes stay on the detail canvas only, so the two
                    // panes read as different spaces — separated by an OS 9
                    // groove (shadow + highlight hairlines) on its edge.
                    .background {
                        if isClassicTheme {
                            // Painted UNDER the top safe-area inset.
                            //
                            // The window hides its native title bar and draws
                            // an OS 9 one over the frame, but the content view
                            // still carries a safe-area inset where that bar
                            // sits. SwiftUI insets the sidebar below it, so the
                            // Platinum fill started lower than the pane beside
                            // it and the window's own near-white showed through
                            // as a bright strip above the camera badge —
                            // exactly the wrong colour in the one place the eye
                            // starts.
                            AppTheme.platinumFace.ignoresSafeArea(edges: .top)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if isClassicTheme {
                            HStack(spacing: 0) {
                                Rectangle().fill(AppTheme.platinumShadow.opacity(0.9)).frame(width: 1)
                                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1)
                            }
                            // Same top inset the sidebar's FILL had to
                            // ignore. Fixing only the fill left this groove
                            // starting a couple of points lower than the
                            // Platinum it divides, so the line stopped short
                            // of the title bar with a notch above it.
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                        }
                    }
                    // The single-value variant means FIXED — the user cannot
                    // drag the divider. The (min:ideal:max:) form declares a
                    // resizable RANGE, and with equal bounds macOS 26 still
                    // lets the divider drag. The AppKit pin in
                    // WindowConfigurator stays as belt-and-braces for the
                    // case where an NSSplitView does back this window.
                    .navigationSplitViewColumnWidth(260)
                    // Classic only: drop the system glass toggle (a Platinum
                    // lookalike is added in the detail toolbar below). Regular keeps
                    // the native toggle. Safe because the window rebuilds per theme
                    // (WindowGroup `.id`), so the two configs never coexist.
                    .toolbar(removing: isClassicTheme ? .sidebarToggle : nil)
                } detail: {
                    ScrollViewReader { scrollProxy in
                    // Classic: the Platinum control row heads the DETAIL pane
                    // only (an OS 9 document-window header), leaving the
                    // sidebar to rise cleanly to the title bar.
                    VStack(spacing: 0) {
                    // zIndex lifts the row above its scroll sibling so Balloon
                    // Help can hang below the buttons without being covered.
                    if isClassicTheme { classicControlRow.zIndex(1) }
                    ScrollView {
                        VStack(spacing: 15) {
                            if !serialManager.photoIndices.isEmpty {
                                gallerySection
                            } else if let previewImage = serialManager.previewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                                    .cornerRadius(12)
                                    .shadow(radius: 10, y: 4)
                                    .padding(.top, 40)
                            } else {
                                emptyStateSection
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Let the gallery reach the edges: edge-to-edge in square
                        // (contact-sheet) mode, a tight margin in aspect mode, and
                        // the roomier margin only for the single-preview / empty
                        // states where centred content reads better.
                        .padding(.horizontal, serialManager.photoIndices.isEmpty ? 24 : (gallerySquareGrid ? 0 : 12))
                        // No bottom margin on the empty/preview states — the
                        // margin would make an otherwise-fitting canvas
                        // scrollable by exactly its own height, which in
                        // Classic manifests as a near-full-track scrollbar
                        // thumb for no visible reason.
                        .padding(.bottom, serialManager.photoIndices.isEmpty ? 0 : 40)
                        // Reserve the OS 9 scrollbar's gutter in Classic so the
                        // rightmost content isn't hidden behind it.
                        .padding(.trailing, isClassicTheme ? ClassicScrollbar.width : 0)
                    }
                    // Classic: hide the native indicator and drive an authentic
                    // Platinum scrollbar overlaid on the trailing edge. Other
                    // themes keep the system scroller untouched.
                    .scrollIndicators(isClassicTheme ? .hidden : .automatic)
                    .scrollPosition($galleryScrollPosition)
                    .onScrollGeometryChange(for: ClassicScrollMetrics.self) { geo in
                        ClassicScrollMetrics(offset: geo.contentOffset.y,
                                             content: geo.contentSize.height,
                                             viewport: geo.containerSize.height)
                    } action: { _, m in
                        // Classic-only consumer: an unconditional write here
                        // would re-evaluate ContentView's body on EVERY
                        // scrolled frame in the regular themes, for a
                        // scrollbar they don't render.
                        if isClassicTheme { galleryScrollMetrics = m }
                    }
                    .overlay(alignment: .trailing) {
                        if isClassicTheme {
                            ClassicScrollbar(metrics: galleryScrollMetrics, scrollTo: { y in
                                galleryScrollPosition.scrollTo(y: y)
                            }, reserveGrowBox: true)
                        }
                    }
                    // The OS 9 grow box tucks into the corner the scrollbar
                    // reserves for it.
                    .overlay(alignment: .bottomTrailing) {
                        if isClassicTheme { ClassicGrowBox() }
                    }
                    .frame(minWidth: 400)
                    .background {
                        if isClassicTheme {
                            ClassicPinstripe()
                        } else {
                            Color(NSColor.windowBackgroundColor)
                        }
                    }
                    // The panorama panel belongs to the GALLERY, not the
                    // window. Over the whole split view it centred across
                    // the sidebar and its rounded corner sliced the live
                    // camera card mid-word — a hard cut through "QuickTake
                    // 100 (Dem" reads as a rendering fault, not a layer. It
                    // is also about the photos in this pane, so this is
                    // where it should sit.
                    .overlay { panoramaViewerLayer }
                    // Moof! — Cmd+P summons Clarus the Dogcow over the canvas.
                    .overlay {
                        if serialManager.showMoof {
                            MoofOverlay(classic: isClassicTheme) { serialManager.dismissMoof() }
                                .accessibilityHidden(true)   // decorative easter-egg overlay
                        }
                    }
                    .animation(reduceMotion ? .easeInOut(duration: 0.15)
                                            : .spring(response: 0.45, dampingFraction: 0.72),
                               value: serialManager.showMoof)
                    // (Phantom venus/mars/neptune.qtk drops are handled by the
                    // window-level dropDestination below, alongside imports —
                    // one drop surface, no routing ambiguity.)
                    // Window/toolbar title — always "Camera Storage", never the
                    // app name.
                    .navigationTitle("Camera Storage")
                    // Trackpad pinch-to-zoom the gallery, scaling from the width
                    // captured at gesture start so it tracks the fingers smoothly
                    // and clamps to the same bounds as ⌘+/⌘−.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let base = pinchBaseWidth ?? galleryThumbnailWidth
                                if pinchBaseWidth == nil {
                                    pinchBaseWidth = base
                                    isPinchingGallery = true
                                }
                                galleryThumbnailWidth = min(max(base * value.magnification,
                                                                Self.galleryZoomMin),
                                                            Self.galleryZoomMax)
                            }
                            .onEnded { _ in
                                pinchBaseWidth = nil
                                isPinchingGallery = false
                            }
                    )
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !serialManager.photoTransfers.isEmpty {
                            // A dedicated view, not a computed on ContentView:
                            // it tracks the live progress store, so per-tick
                            // redraws stay inside the bar.
                            BatchProgressBar(transfers: serialManager.photoTransfers,
                                             live: serialManager.liveProgress,
                                             coplandActive: coplandIndex != nil)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if let load = serialManager.thumbnailLoadProgress {
                            // Non-blocking activity signal while the camera's
                            // thumbnails stream in — the connect HUD lifts
                            // early so the UI stays playable, and this bar is
                            // the "something's happening" in its place.
                            ThumbnailLoadingBar(loaded: load.loaded, total: load.total)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(), value: serialManager.photoTransfers.isEmpty)
                    .animation(.spring(), value: serialManager.thumbnailLoadProgress == nil)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($galleryHasKeyboardFocus)
                    .onKeyPress(.space, phases: [.down, .up]) { press in
                        switch press.phase {
                        case .down:
                            guard let focusedPhotoIndex else { return .ignored }
                            Task {
                                await previewFocusedPhotoInQuickLook(focusedPhotoIndex)
                            }
                            return .handled
                        case .up:
                            QuickLookPreviewController.shared.dismiss()
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                    // Esc clears the photo selection (Finder/Photos
                    // convention) — but the panorama panel gets first
                    // refusal. It is the frontmost thing on screen and
                    // Escape is how you dismiss it; letting the gallery
                    // underneath answer instead left the panel sitting
                    // there while the selection silently vanished behind
                    // it. Innermost visible layer wins, as everywhere else
                    // in macOS.
                    .onExitCommand {
                        if viewingPanorama != nil {
                            closePanoramaViewer()
                            return
                        }
                        serialManager.selectedPhotoIndices.removeAll()
                        selectionAnchor = nil
                    }
                    // Handle each physical key once, using that event's modifiers.
                    // Assistive move commands remain available without a key event.
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                                phases: [.down, .repeat]) { press in
                        let direction: MoveCommandDirection
                        switch press.key {
                        case .upArrow: direction = .up
                        case .downArrow: direction = .down
                        case .leftArrow: direction = .left
                        case .rightArrow: direction = .right
                        default: return .ignored
                        }
                        moveGalleryFocus(direction, extendSelection: press.modifiers.contains(.shift))
                        return .handled
                    }
                    .onMoveCommand { direction in
                        moveGalleryFocus(direction, extendSelection: false)
                    }
                    .onChange(of: focusedField) { oldValue, newValue in
                        if let oldIndex = oldValue {
                            serialManager.renamePhoto(at: oldIndex, to: editingName)
                        }
                        if let newIndex = newValue {
                            editingName = getPhotoName(for: newIndex)
                        }
                    }
                    // Keep the focused/QuickLook-current photo on screen — scroll
                    // it into view as focus moves (arrow keys or QuickLook ↑/↓/←/→).
                    .onChange(of: focusedPhotoIndex) { _, newIndex in
                        // Only scroll when focus moved via the keyboard or
                        // QuickLook paging — never on a click, which would yank
                        // the grid out from under the pointer.
                        guard autoScrollToFocus else { return }
                        autoScrollToFocus = false
                        guard let newIndex else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollProxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                    } // VStack (classic row + scroll)
                    } // ScrollViewReader
                } // detail
                .toolbar {
                    // Classic declares NO toolbar items at all: even a hidden
                    // toolbar with items reserves its full 52pt unified height
                    // as top safe area, opening a dead band between the drawn
                    // OS 9 title bar and the content. With zero items the
                    // reservation drops to plain title-bar height, which the
                    // drawn bar covers. Everything the toolbar hosted lives in
                    // classicControlRow instead.
                    if !isClassicTheme {
                        galleryToolbar
                    }
                }
                // Liquid Glass title-bar pane in both windowed and fullscreen.
                // `.visible` renders the frosted toolbar material; the window
                // (see WindowConfigurator) no longer forces a fully-transparent
                // titlebar, so this material now shows in windowed mode too —
                // matching the strip fullscreen gives for free.
                .modifier(ClassicToolbarBackground(classic: isClassicTheme))
                // Classic replaces the native chrome wholesale: the toolbar row
                // is hidden, the title bar is transparent and empty (buttons and
                // title hidden by WindowConfigurator), and the hand-drawn OS 9
                // title bar + Platinum control row take their place at the top.
                // The other themes keep the native toolbar untouched.
                .toolbar(isClassicTheme ? .hidden : .automatic, for: .windowToolbar)
                // No safe-area games in Classic: the hidden toolbar leaves a
                // ~28pt top band, the frame-mounted OS 9 title bar draws over
                // it, and both columns naturally lay out beneath it. An extra
                // inset slot here would double-count the columns' inherent
                // top inset and open a dead gap between the title bar and the
                // content headers.
                // Liquid Glass paints a scroll-edge "pocket" backdrop over the
                // top of each scroll column — in Classic it would wash the
                // drawn chrome (and anything under it) to flat grey. Kill it;
                // the regular themes keep the automatic effect.
                .scrollEdgeEffectStyle(isClassicTheme ? nil : .automatic, for: .top)
                .task {
                    serialManager.detectSerialPort()
                }
                .onChange(of: serialManager.shouldRequestImport) { _, shouldRequestImport in
                    guard shouldRequestImport else { return }
                    // Menu- and drop-triggered imports are selection-aware: the
                    // selected photos if any, otherwise all.
                    beginImport()
                    serialManager.batchImportRequestHandled()
                }
                .onChange(of: serialManager.shouldConfirmErase) { _, shouldConfirm in
                    guard shouldConfirm else { return }
                    // Menu-bar erase shows the same confirmation dialog the
                    // sidebar trash button uses.
                    showingEraseConfirmation = true
                    serialManager.eraseConfirmationHandled()
                }
                // Classic routes this through the themed ClassicConfirmDialog
                // (see modalDialogLayer); the system alert only fires elsewhere.
                .alert("Erase all photos?", isPresented: isClassicTheme ? .constant(false) : $showingEraseConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Erase all photos", role: .destructive) {
                        serialManager.deleteImages()
                    }
                } message: {
                    Text("Every photo on the camera will be permanently deleted. This can't be undone.")
                }
                // Same split as the erase confirmation above: the system
                // alert everywhere modern, the drawn OS 9 dialog only in
                // Classic.
                //
                // This was a hand-built panel in both themes — an SF Symbol
                // tinted orange, a dimmed backdrop, a spring scale-in. Each
                // of those is a thing macOS alerts do not do, and together
                // they read as "an app imitating an alert" rather than an
                // alert. The real one comes with the app icon, the system's
                // own typography and metrics, the standard slide, and it
                // stays right when the OS changes its mind about any of
                // that.
                .alert("Import folder unavailable",
                       isPresented: Binding(
                        get: { !isClassicTheme && serialManager.destinationFallbackMessage != nil },
                        set: { if !$0 { serialManager.destinationFallbackMessage = nil } })) {
                    Button("OK") { serialManager.destinationFallbackMessage = nil }
                } message: {
                    Text(serialManager.destinationFallbackMessage ?? "")
                }
            } // inner ZStack
            .overlay(alignment: .top) {
                // In Classic the toasts drop below the drawn OS 9 chrome
                // instead of covering the title bar.
                toastContainer
                    .padding(.top, isClassicTheme ? ClassicTitleBar.height + 38 : 0)
            }
            .animation(.spring(), value: serialManager.showPowerTip)
            .animation(.spring(), value: serialManager.showConnectionAlert)
            .animation(.spring(), value: serialManager.showModelMismatch)
            .animation(.spring(), value: serialManager.errorMessage)
            .dropDestination(for: URL.self) { items, location in
                // The native vintage-camera raw format is accepted (finished
                // formats like JPEG are deliberately NOT importable — there is
                // nothing to decode; the user already has the picture):
                //   - `.qtk` → Apple QuickTake 100/150 (Kodak RADC inside an
                //              8-byte Apple header)
                //
                // File bodies are read synchronously here so the drop
                // destination's security scope is still alive when the
                // Task picks up the dispatch.
                // Expand any dropped folders (e.g. a memory card's directory)
                // into their contained files so a whole card can be dragged in.
                func expand(_ urls: [URL]) -> [URL] {
                    var out: [URL] = []
                    for url in urls {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                                out.append(contentsOf: e.compactMap { $0 as? URL })
                            }
                        } else {
                            out.append(url)
                        }
                    }
                    return out
                }
                guard pendingQTKDrop == nil, dropForPanorama == nil, dropForConversion == nil,
                      !serialManager.showingPanoramaComposer,
                      serialManager.pendingPanoramaFiles == nil else { return false }
                let scoped = items.filter { $0.startAccessingSecurityScopedResource() }
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                let allURLs = expand(items)

                // Phantom planets (venus/mars/neptune.qtk) are the easter egg,
                // not an import. Handled here so the canvas has exactly ONE
                // drop surface — a separate `.onDrop` would claim every file
                // drop over the canvas and silently swallow real imports.
                for url in allURLs where url.pathExtension.lowercased() == "qtk" {
                    if serialManager.loadPhantomQTK(named: url.deletingPathExtension().lastPathComponent) {
                        return true
                    }
                }

                let qtkURLs = Array(Set(allURLs.filter { $0.pathExtension.lowercased() == "qtk" }))

                guard !qtkURLs.isEmpty else { return false }

                var urlDataMap: [URL: Data] = [:]
                for url in qtkURLs {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) { urlDataMap[url] = data }
                }
                guard urlDataMap.count == qtkURLs.count else {
                    serialManager.errorMessage = "Some QTK files could not be read. No files were converted. Check that they are available and drop them again."
                    return true
                }
                if urlDataMap.count > 1 {
                    pendingQTKDrop = QTKDropBatch(files: urlDataMap)
                } else {
                    Task { await serialManager.convertDroppedQTKFiles(urlDataMap) }
                }

                return true
            } isTargeted: { targeted in
                isQTKDropTargeted = targeted
            }
            // Subtle accent stroke while a file drag hovers — the drop zone
            // had no feedback at all before landing. Overlay, not a
            // background change, so nothing about the default look moves.
            .overlay {
                if isQTKDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isQTKDropTargeted)
        } // outer ZStack
        // OS 9 busy cursor: the wristwatch replaces the pointer app-wide while
        // the Classic theme is active and the app is working. Gated to Classic
        // here, so the other themes keep the system cursor untouched.
        .classicBusyCursor(active: isClassicTheme
            && (serialManager.isBusy || serialManager.isConnecting
                || serialManager.isRefreshing || serialManager.areThumbnailsLoading))
        // Reach into the AppKit window once to enable full-size content view
        // so the connecting overlay (.ignoresSafeArea) covers the title-bar
        // region. This matters most in fullscreen, where the auto-hiding title
        // bar would otherwise float above the blur.
        .background(WindowConfigurator(classic: isClassicTheme))
        .sheet(isPresented: $showingWelcome) {
            WelcomeView(isPresented: $showingWelcome) {
                hasSeenWelcome = true
            }
        }
        .sheet(isPresented: $showingConnectionHelp) {
            ConnectionHelpView()
        }
        // Custom modal dialogs (duplicate prompt + folder-unavailable notice) are
        // presented as dimmed in-window OVERLAYS rather than sheets, so their
        // glass panel samples the gallery behind them (true Liquid Glass) — a
        // separate sheet window can't do that and reads as opaque.
        .overlay { modalDialogLayer }
        // Camera-disambiguation prompt, shown when auto-detection can't pin
        // the exact model. Driven by the manager's `pendingCameraSelection`;
        // dismissing it (or Cancel) abandons the probe via
        // `cancelCameraSelection`.
        .sheet(isPresented: Binding(
            get: { serialManager.pendingCameraSelection != nil },
            set: { if !$0 { serialManager.cancelCameraSelection() } }
        )) {
            CameraSelectionView(
                candidates: serialManager.pendingCameraSelection ?? [],
                onConfirm: { serialManager.confirmDetectedModel($0) },
                onCancel: { serialManager.cancelCameraSelection() }
            )
        }
        // Panorama composer. A sheet rather than the standalone window
        // because the panorama is made out of the photos selected behind
        // it, and a separate window severs that connection the moment it
        // opens. The window still exists as a fallback entry point and
        // shows the same composer off the same composition.
        .sheet(isPresented: Binding(
            get: { serialManager.showingPanoramaComposer },
            set: { if !$0 { serialManager.dismissPanoramaComposer() } }
        )) {
            // Re-injected, because a sheet is hosted outside this view's
            // environment and custom values do not reliably cross that
            // boundary — the same reason the gallery's popovers re-inject
            // it. Without this the composer stayed in the modern style
            // while the window behind it went Platinum, so mid-workflow
            // Classic looked like two apps stitched together. The order
            // sheet below never had the bug because it is passed the flag
            // as an ordinary parameter.
            // `windowAppTheme()`, not a hand-injected environment key.
            //
            // Injecting `\.isClassicTheme` alone got the flag across but
            // nothing else: the app applies `tint`, `preferredColorScheme`
            // and `classicButtonStyling` as SEPARATE modifiers beside it,
            // and a sheet inherits none of them — so the composer knew it
            // was in Classic and still drew modern buttons and fonts.
            // WindowThemeBridge exists for exactly this, reading the theme
            // from storage itself and re-applying the whole treatment. It
            // is what the auxiliary windows already use.
            PanoramaComposerSheet()
                .windowAppTheme()
        }
        .sheet(item: $pendingQTKDrop, onDismiss: {
            // Present the ordering sheet only after the choice sheet closes.
            if let batch = dropForPanorama {
                dropForPanorama = nil
                if serialManager.canPrepareDroppedPanorama {
                    serialManager.prepareDroppedPanorama(batch.files)
                } else {
                    serialManager.errorMessage = "SwiftTake became busy. Finish the current operation, then drop the files again. Your originals have not changed."
                }
            } else if let batch = dropForConversion {
                dropForConversion = nil
                Task { await serialManager.convertDroppedQTKFiles(batch.files) }
            }
        }) { batch in
            QTKDropChoiceSheet(
                count: batch.files.count,
                canMakePanorama: serialManager.canPrepareDroppedPanorama,
                onConvert: {
                    dropForConversion = batch
                    pendingQTKDrop = nil
                },
                onPanorama: {
                    guard serialManager.canPrepareDroppedPanorama else { return }
                    dropForPanorama = batch
                    pendingQTKDrop = nil
                },
                onCancel: { pendingQTKDrop = nil })
                .windowAppTheme()
        }
        // The ordering step, between file selection and the composer.
        // Only the Finder path presents it: a gallery selection is already
        // a sequence, since camera slot order IS capture order.
        .sheet(isPresented: Binding(
            get: { serialManager.pendingPanoramaFiles != nil },
            set: { if !$0 { serialManager.cancelPanoramaOrdering() } }
        )) {
            if let files = serialManager.pendingPanoramaFiles {
                PanoramaOrderSheet(
                    urls: files,
                    isClassicTheme: isClassicTheme,
                    capturedData: serialManager.pendingPanoramaData,
                    onConfirm: { ordered in
                        // Automatic hands back the untouched array, so the
                        // manager can tell "as given" from "arranged" by
                        // identity rather than needing a second flag.
                        serialManager.startPanorama(
                            files: files,
                            fixedOrder: ordered == files ? nil : ordered)
                    },
                    onCancel: { serialManager.cancelPanoramaOrdering() })
                    // Same reason as the composer above. This sheet gets the
                    // flag as a parameter so its type reads correctly, but
                    // its BUTTONS would still be modern in Classic without
                    // the rest of the treatment.
                    .windowAppTheme()
            }
        }
        // Camera diagnostic capture (any family). Appears immediately on run
        // in a capturing state, then fills with the copyable report.
        .sheet(isPresented: Binding(
            get: { serialManager.isCapturingDiagnostics || serialManager.diagnosticsReport != nil },
            set: { if !$0 {
                serialManager.diagnosticsReport = nil
                serialManager.isCapturingDiagnostics = false
            } }
        )) {
            DiagnosticsReportView(
                report: serialManager.diagnosticsReport,
                isCapturing: serialManager.isCapturingDiagnostics,
                cameraName: serialManager.diagnosticsCameraName,
                onClose: { serialManager.diagnosticsReport = nil }
            )
        }
        .onAppear {
            if !hasSeenWelcome {
                showingWelcome = true
            }
        }
        .overlay {
            if serialManager.isConnecting {
                ZStack {
                    // Flat dim covering the whole window (including the title-bar
                    // region in fullscreen). Blocks interaction by sitting on top
                    // of the content stack. Not .ultraThinMaterial, which doesn't
                    // reach the fullscreen title bar reliably.
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())   // catch all clicks
                        .allowsHitTesting(true)

                    // Compact HUD-style popup: a Platinum dialog with the OS 9
                    // barber-pole in Classic, a Liquid Glass pane elsewhere.
                    VStack(spacing: 14) {
                        if isClassicTheme {
                            ClassicBarberPole()
                                .frame(width: 170, height: 12)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                        }
                        Text("Connecting…")
                            .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .themedPanel(cornerRadius: isClassicTheme ? 4 : 16, classic: isClassicTheme)
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .overlay {
            if showingOverwriteConfirmation {
                overwriteConfirmationModal
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showingOverwriteConfirmation)
        // The split divider drags on macOS 26 no matter which
        // navigationSplitViewColumnWidth API is used — exact AND ranged forms
        // both leave it grabbable (verified by driving real hover-armed
        // drags; 260 held only as a MINIMUM). This invisible strip sits over
        // the divider's grab zone and swallows the drag before the split
        // view can see it: the sidebar is 260 pt by design, never resizable.
        // Nothing interactive lives in this 14 pt band — the sidebar and
        // gallery both pad well past it.
        .overlay(alignment: .leading) {
            if columnVisibility != .detailOnly {
                Color.clear
                    .frame(width: 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0))
                    .offset(x: 253)
                    .accessibilityHidden(true)
            }
        }
        // Easter egg: the one true status bubble lives here, above everything
        // and free of the sidebar's clipping. It morphs from capsule to orb and
        // back on the same view, so it never disappears/reappears.
        // A disconnect clears the saved panoramas; the panel must not be
        // left floating over an empty gallery showing one of them.
        .onChange(of: serialManager.savedPanoramas) { _, panos in
            if let showing = viewingPanorama, !panos.contains(showing) {
                closePanoramaViewer()
            }
        }
        .overlay { statusBubbleLayer }
        .overlay { apertureOrbLayer }
        .overlay { coplandLayer }
        .onChange(of: serialManager.photoSessionGeneration) { _, _ in cancelCopland() }
        .onDisappear { cancelCopland() }
        // Copland-glow visibility mirror (see `squareModeHidesGlow`): hiding
        // is quick, reappearing is the plaque aura's slow swell — and because
        // these run in their own transactions, neither direction can ever
        // steer the glow's geometry, which springs with the cell.
        .onAppear { squareModeHidesGlow = gallerySquareGrid }
        .onChange(of: gallerySquareGrid) { _, square in
            if square {
                // Effectively instant: the cells' resize spring barely moves
                // in its first 60 ms, so the gold is gone before anything
                // reshapes — at 0.15 s it was still visible for the first
                // beat of the resize and read as a jump behind the square.
                withAnimation(.easeOut(duration: 0.06)) { squareModeHidesGlow = true }
            } else {
                withAnimation(.easeInOut(duration: 2.8).delay(0.3)) { squareModeHidesGlow = false }
            }
        }
        // If the orb gets locked out while it's out (theme switched to Classic,
        // rainbow re-locked, phantom relock), tear it down cleanly so it can't be
        // left stranded on screen with a runaway sampling task. Skipped while a
        // Copland develop owns the orb — that sequence resets itself.
        .onChange(of: apertureFullyUnlocked) { _, unlocked in
            if !unlocked && apertureOrbActive && coplandIndex == nil {
                resetApertureOrb()
            }
        }
        // Phantom photo at the window root (above the sidebar) so the absorb can
        // genuinely fly INTO the aperture. It derives the canvas region from its
        // OWN geometry + the fixed sidebar width (capturing the detail rect from
        // inside the split view was unreliable), and uses the global aperture rect.
        .overlay {
            if let egg = serialManager.phantomEgg {
                PhantomPhotoView(
                    egg: egg,
                    alreadyAbsorbed: serialManager.isPhantomAbsorbed(egg),
                    sidebarShown: columnVisibility != .detailOnly,
                    sidebarWidth: 260,
                    aperture: { CGPoint(x: apertureRect.midX, y: apertureRect.midY) },
                    openSidebar: {
                        withAnimation(.easeInOut(duration: 0.3)) { columnVisibility = .all }
                    },
                    onAbsorb: { flashApertureForPhantom(egg) },
                    onComplete: { serialManager.dismissPhantom() }
                )
                .transition(.opacity)
                .accessibilityHidden(true)   // decorative easter-egg overlay
            }
        }
        .animation(.easeInOut(duration: 0.25), value: serialManager.phantomEgg)
    }

    /// Centered Liquid Glass confirmation, in place of a system modal — a dimmed
    /// backdrop with a glass card that matches the connecting HUD's house style.
    /// The "already imported" prompt. The view lives in
    /// `WindowOverlays.swift`; this gathers its inputs.
    private var overwriteConfirmationModal: some View {
        let dismiss = { showingOverwriteConfirmation = false }

        return OverwriteConfirmationDialog(
            onSkipImported: {
                dismiss()
                importToDefaultLocation(importAll: true, skipImported: true)
            },
            onImportAgain: {
                dismiss()
                importToDefaultLocation(importAll: true)
            },
            onCancel: dismiss)
    }

    /// The toast banner. The view lives in `WindowOverlays.swift`; this
    /// gathers its inputs.
    private var toastContainer: some View {
        ToastStack(
            errorMessage: serialManager.errorMessage,
            isConnecting: serialManager.isConnecting,
            showConnectionAlert: serialManager.showConnectionAlert,
            showModelMismatch: serialManager.showModelMismatch,
            detectedModelName: serialManager.detectedModelName,
            showPowerTip: serialManager.showPowerTip,
            onDismissError: { serialManager.errorMessage = nil },
            onDismissToast: { serialManager.presentToast(nil) })
    }

    /// Stable id for the current status colour, used both for the indicator and
    /// for the colour-collection easter egg.
    // Shared with the Settings status card — single source of truth on the
    // manager so the sidebar bubble and Settings always agree.
    private var statusColorID: String { serialManager.statusColorID }
    private var statusIndicatorColor: Color { serialManager.statusIndicatorColor }

    private var collectedStatusColors: Set<String> {
        Set(collectedStatusColorsRaw.split(separator: ",").map(String.init))
    }

    private func collectStatusColor(_ id: String) {
        var set = collectedStatusColors
        set.insert(id)
        collectedStatusColorsRaw = set.sorted().joined(separator: ",")
    }

    private var allStatusColorsCollected: Bool {
        collectedStatusColors.isSuperset(of: ["red", "orange", "green"])
    }

    /// Subtle metallic platinum for the wordmark, revealed when the phantom-photo
    /// egg completes (the `WordmarkBrand` view fades it in with a shine).
    static let platinumWordmark = AnyShapeStyle(
        LinearGradient(
            colors: [
                Color(red: 0.85, green: 0.87, blue: 0.91),   // light silver
                Color(red: 0.52, green: 0.55, blue: 0.60)    // deeper platinum
            ],
            startPoint: .top, endPoint: .bottom))


    /// Shared height for the two bottom status bars (sidebar footer + detail
    /// progress bar) so they sit at the same baseline and read as one bar.
    static let bottomBarHeight: CGFloat = 56

    /// Status labels read cleaner without a trailing full stop, but keep ellipses
    /// (e.g. "Importing…") and multi-dot forms intact.
    private var statusDisplayText: String {
        let m = serialManager.statusMessage
        if m.hasSuffix(".") && !m.hasSuffix("..") { return String(m.dropLast()) }
        return m
    }

    // MARK: Classic window chrome (OS 9 title bar + control row)

    /// The native toolbar. The view lives in `GalleryChrome.swift`; this
    /// gathers its inputs.
    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        GalleryToolbar(
            isClassic: isClassicTheme,
            hasPhotos: !serialManager.photoIndices.isEmpty,
            hasSelection: !serialManager.selectedPhotoIndices.isEmpty,
            isConnected: serialManager.isConnected,
            isBusy: serialManager.isBusy,
            areThumbnailsLoading: serialManager.areThumbnailsLoading,
            hasActiveTransfers: !serialManager.photoTransfers.isEmpty,
            thumbnailWidth: galleryThumbnailWidth,
            focusedPhotoIndex: focusedPhotoIndex,
            importPrimaryTitle: importPrimaryTitle,
            squareGrid: $gallerySquareGrid,
            showingPhotoInfo: $showingPhotoInfo,
            showingSelectionMenu: $showingSelectionMenu,
            showingImportOptions: $showingImportOptions,
            onZoomOut: { zoomGallery(by: -Self.galleryZoomStep) },
            onZoomIn: { zoomGallery(by: Self.galleryZoomStep) },
            onSelectAll: { serialManager.selectAllPhotos() },
            onDeselectAll: {
                serialManager.selectedPhotoIndices.removeAll()
                selectionAnchor = nil
            },
            infoPopover: { idx in photoInfoPopover(for: idx) },
            selectionPopover: { selectionOptionsPopover },
            importPopover: { importOptionsPopover })
    }

    /// The Classic Platinum control row. The view lives in
    /// `GalleryChrome.swift`; this gathers its inputs.
    private var classicControlRow: some View {
        ClassicControlRow(
            hasPhotos: !serialManager.photoIndices.isEmpty,
            hasSelection: !serialManager.selectedPhotoIndices.isEmpty,
            isConnected: serialManager.isConnected,
            isBusy: serialManager.isBusy,
            areThumbnailsLoading: serialManager.areThumbnailsLoading,
            hasActiveTransfers: !serialManager.photoTransfers.isEmpty,
            thumbnailWidth: galleryThumbnailWidth,
            focusedPhotoIndex: focusedPhotoIndex,
            squareGrid: $gallerySquareGrid,
            showingPhotoInfo: $showingPhotoInfo,
            showingSelectionMenu: $showingSelectionMenu,
            showingImportOptions: $showingImportOptions,
            onToggleSidebar: {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            },
            onZoomOut: { zoomGallery(by: -Self.galleryZoomStep) },
            onZoomIn: { zoomGallery(by: Self.galleryZoomStep) },
            onDeselectAll: {
                serialManager.selectedPhotoIndices.removeAll()
                selectionAnchor = nil
            },
            infoPopover: { idx in photoInfoPopover(for: idx) },
            selectionPopover: { selectionOptionsPopover },
            importPopover: { importOptionsPopover })
    }

    /// In-window modal dialogs (duplicate prompt / folder-unavailable notice),
    /// presented as glass overlays so they sample the gallery behind them.
    @ViewBuilder
    /// The in-window modal dialogs. The view lives in
    /// `WindowOverlays.swift`; this gathers its inputs.
    private var modalDialogLayer: some View {
        ModalDialogLayer(
            duplicatePrompt: serialManager.duplicatePrompt,
            destinationFallbackMessage: serialManager.destinationFallbackMessage,
            showingEraseConfirmation: showingEraseConfirmation,
            isClassicTheme: isClassicTheme,
            onDismissFallback: { serialManager.destinationFallbackMessage = nil },
            onConfirmErase: { showingEraseConfirmation = false; serialManager.deleteImages() },
            onCancelErase: { showingEraseConfirmation = false })
    }

    private var statusCapsule: some View {
        StatusCapsule(
            text: statusDisplayText,
            accessibilityMessage: serialManager.statusMessage,
            indicatorColor: statusIndicatorColor)
    }

    /// The sidebar footer is just an invisible placeholder: it reserves the
    /// bubble's layout slot and catches the drag. The VISIBLE bubble is always
    /// the single `statusBubbleLayer` in the window overlay, so the thing never
    /// disappears/reappears — it physically morphs and moves.
    private func sidebarStatusFooter() -> some View {
        statusCapsule
            .opacity(0)                       // placeholder only — never drawn
            .contentShape(Capsule())          // …but still grabbable
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { updateStatusHome(geo) }
                        .onChange(of: geo.frame(in: .global)) { _, _ in updateStatusHome(geo) }
                }
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 10)
            // Fixed height shared with the detail pane's progress bar
            // (`Self.bottomBarHeight`) so the two bottom bars sit at the same
            // baseline across the sidebar/detail divider and read as one bar.
            .frame(height: Self.bottomBarHeight)
            // The drag-to-orb easter egg is a Liquid Glass conceit — disable it in
            // Classic so the status well stays a fixed Platinum element.
            .gesture(statusDragGesture, including: isClassicTheme ? .subviews : .all)
    }

    private func updateStatusHome(_ geo: GeometryProxy) {
        let rect = geo.frame(in: .global)
        // At rest, animate the resize so the bubble grows/shrinks smoothly between
        // status-message lengths (paired with the text's soft cross-fade). Skip the
        // very first measurement (was `.zero`) so it doesn't balloon in on launch,
        // and stay instant during a fling/morph so nothing lags the cursor.
        if statusHomeRect != .zero && !isDraggingStatus && statusMorph < 0.02 {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                statusHomeRect = rect
                statusOrbGlobal = CGPoint(x: rect.midX, y: rect.midY)
            }
        } else {
            statusHomeRect = rect
            // Only re-home the orb when resting; mid-drag this would teleport it.
            if !isDraggingStatus {
                statusOrbGlobal = CGPoint(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Easter egg: fling the status bubble around the window; it springs home.
    /// The bubble centre tracks the cursor tip; drag velocity squashes/stretches
    /// the glass like jelly, which wobbles back to round when it slows or lands.
    private var statusDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if !isDraggingStatus {
                    isDraggingStatus = true
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) {
                        statusMorph = 1            // ball up
                    }
                }
                // Bubble sits exactly under the cursor, wherever you grabbed it.
                withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.82)) {
                    statusOrbGlobal = value.location
                }
                // Squash/stretch toward the travel direction, scaled by speed.
                let v = value.velocity
                let speed = hypot(v.width, v.height)
                // Snap the stretch axis (no animation) so it never spins the long
                // way around the ±180° seam.
                if speed > 40 { statusStretchAngle = Angle(radians: atan2(v.height, v.width)) }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.42)) {
                    statusStretch = min(0.42, speed / 3200)
                }
            }
            .onEnded { _ in
                // Dropped on the aperture (and this colour is new)? Absorb it.
                let apCenter = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
                let onAperture = apertureRect != .zero
                    && hypot(statusOrbGlobal.x - apCenter.x, statusOrbGlobal.y - apCenter.y) < 72
                if onAperture && !collectedStatusColors.contains(statusColorID) {
                    absorbIntoAperture(apertureCenter: apCenter)
                    return
                }

                let home = CGPoint(x: statusHomeRect.midX, y: statusHomeRect.midY)
                // Spring home, let the jelly wobble out, and reform to the capsule
                // — all continuous on the same bubble, no swap.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
                    statusOrbGlobal = home
                }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.34)) {
                    statusStretch = 0
                }
                withAnimation(.spring(response: 0.44, dampingFraction: 0.74)) {
                    statusMorph = 0
                }
                // `isDraggingStatus` only re-enables home tracking; it drives no
                // visuals, so flipping it never flickers the bubble.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    isDraggingStatus = false
                }
            }
    }

    /// The orb dissipates into the aperture mark, which glows the captured colour
    /// for ~2 s before fading back to white. The status bar then grows back at
    /// the bottom (rather than the orb flying home). Records the colour once.
    private func absorbIntoAperture(apertureCenter: CGPoint) {
        collectStatusColor(statusColorID)
        apertureGlowColor = statusIndicatorColor

        // Phase 1 — shrink into the logo.
        withAnimation(.easeIn(duration: 0.4)) {
            statusOrbGlobal = apertureCenter
            statusStretch = 0
            statusAbsorbScale = 0
        }

        // Phase 2 — the logo glows the colour, then fades back to white.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.easeOut(duration: 0.35)) { apertureGlowLevel = 1 }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.9)) { apertureGlowLevel = 0 }
        }

        // Phase 3 — reform the status bar at the bottom (grow from nothing).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 460_000_000)
            isDraggingStatus = false
            statusMorph = 0
            statusStretchAngle = .zero
            statusOrbGlobal = CGPoint(x: statusHomeRect.midX, y: statusHomeRect.midY)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                statusAbsorbScale = 1
            }
        }
    }

    /// Per-planet glow colour the aperture flashes when a phantom photo is absorbed.
    private func phantomGlowColor(_ egg: QuickTakeSerialManager.PhantomEgg) -> Color {
        switch egg {
        case .venus:   return Color(red: 0.95, green: 0.75, blue: 0.30)
        case .mars:    return Color(red: 0.85, green: 0.33, blue: 0.22)
        case .neptune: return Color(red: 0.30, green: 0.55, blue: 0.90)
        }
    }

    // MARK: Grabbable aperture orb (final reward)

    /// Both aperture eggs done → the mark becomes a grabbable rainbow orb. The
    /// orb is a Liquid Glass conceit, so it's Regular-only (never in Classic).
    private var apertureFullyUnlocked: Bool {
        rainbowUnlocked && serialManager.phantomSecretUnlocked && !isClassicTheme
    }

    /// Force the aperture orb fully back to its resting state. Used when the orb is
    /// locked out mid-flight (theme/unlock change) and the normal `.onEnded` spring-
    /// home can't be relied on (a cancelled gesture may never deliver it). Clears the
    /// drag flag (stopping the sampling task), hides the orb and resets every
    /// animation driver so the next grab starts clean.
    private func resetApertureOrb() {
        isDraggingAperture = false
        apertureReturnTask?.cancel()
        apertureReturnTask = nil
        apertureOrbActive = false
        apertureMorph = 0
        apertureStretch = 0
        apertureReturn = 0
        apertureTrail = []
        apertureTrailFade = 1
        apertureOrbGlobal = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
    }

    /// Grab the aperture and fling it like the status orb; it balls up into a
    /// larger glass bubble and springs home on release.
    private var apertureDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // No grabs while thumbnails are streaming in: the
                // gallery is mid-churn — cells appearing, serial link busy —
                // no place for a develop drop. A drag already in flight when
                // a load starts is left to finish; the drop below is gated
                // too, so it can only spring home.
                guard apertureFullyUnlocked, !serialManager.areThumbnailsLoading else { return }
                if !isDraggingAperture {
                    isDraggingAperture = true
                    // A re-grab mid-flight takes over from the return spring.
                    apertureReturnTask?.cancel()
                    apertureReturnTask = nil
                    // Start AS the aperture mark at its home, then morph into the
                    // orb while you drag it away.
                    let home = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
                    apertureOrbGlobal = home
                    apertureTrail = []
                    apertureTrailFade = 1
                    apertureReturn = 0
                    // Fresh frame table for this drag: tracking is mounted only
                    // while the orb is out, and stale rects from cells that have
                    // scrolled away must not catch the drop.
                    thumbnailFrames.frames.removeAll()
                    apertureOrbActive = true
                    // Slow enough that the glyph→glass transformation is
                    // actually SEEN under the cursor — the orb grows out of
                    // the mark rather than crossfading past it.
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        apertureMorph = 1
                    }
                    // Sample the orb position on a TIMER (not just on movement) so
                    // the tail keeps advancing even when you hold still — the same
                    // point gets appended and the tail collapses/dissipates instead
                    // of freezing in place.
                    Task { @MainActor in
                        // Also stop if the orb gets locked out mid-drag (theme→Classic,
                        // rainbow re-lock): that changes the gesture mask and can
                        // cancel the gesture so `.onEnded` never fires — without this
                        // guard the loop would spin forever. `resetApertureOrb()`
                        // (onChange below) clears the rest of the state.
                        while isDraggingAperture && apertureFullyUnlocked {
                            apertureTrail.append(apertureOrbGlobal)
                            if apertureTrail.count > 22 { apertureTrail.removeFirst() }
                            try? await Task.sleep(nanoseconds: 14_000_000)
                        }
                    }
                }
                // Only follow the cursor once the orb has taken over (during the
                // pulse the mark stays put in the header). A softer follow spring
                // than the status orb gives this big orb more lag / inertia.
                if apertureOrbActive {
                    // Set position DIRECTLY (no animation) so every layer — the
                    // system glass body, the SwiftUI colours, rim and glow — sits
                    // at the exact cursor each frame. Animating it let the glass
                    // lag the content during fast flings. Inertia/wobble comes from
                    // the jelly stretch + the bouncy spring-home on release.
                    apertureOrbGlobal = value.location
                    // (The comet tail is sampled on a timer — see the grab block —
                    // so it keeps moving / collapses even when held still.)
                    // Velocity-driven squash/stretch toward the travel direction.
                    let v = value.velocity
                    let speed = hypot(v.width, v.height)
                    if speed > 40 { apertureStretchAngle = Angle(radians: atan2(v.height, v.width)) }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                        apertureStretch = min(0.22, speed / 4200)
                    }
                }
            }
            .onEnded { _ in
                guard isDraggingAperture else { return }
                isDraggingAperture = false

                // Copland: dropped on an un-developed thumbnail WHILE CONNECTED? Flow
                // the orb into it and develop. When the camera is disconnected the
                // orb is just a fun toy — it never absorbs/develops; it springs home.
                if serialManager.canDevelopCopland,
                   coplandIndex == nil, let hit = coplandHitTest(apertureOrbGlobal) {
                    beginCopland(at: hit)
                    return
                }

                let home = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
                // Fly home on a HAND-STEPPED spring, not withAnimation: the
                // animated version snaps the MODEL to `home` instantly (only
                // the presentation tweens), so the comet tail would have
                // nothing real to sample — it would be faked by collapsing its
                // stale points (apertureReturn). Stepping the model through real
                // positions keeps the tail streaming behind the orb all the
                // way home, through the exact direct-set path the
                // drag uses, so no layer can lag. Constants map from
                // response 0.42 / damping 0.92 → k = (2π/0.42)² ≈ 224,
                // c = 2·ζ·√k ≈ 27.5.
                apertureReturnTask?.cancel()
                apertureReturnTask = Task { @MainActor in
                    var pos = apertureOrbGlobal
                    var vel = CGVector(dx: 0, dy: 0)
                    let k: CGFloat = 224, c: CGFloat = 27.5
                    let dt: CGFloat = 1.0 / 72.0
                    while !Task.isCancelled {
                        vel.dx += (-k * (pos.x - home.x) - c * vel.dx) * dt
                        vel.dy += (-k * (pos.y - home.y) - c * vel.dy) * dt
                        pos.x += vel.dx * dt
                        pos.y += vel.dy * dt
                        apertureOrbGlobal = pos
                        apertureTrail.append(pos)
                        if apertureTrail.count > 22 { apertureTrail.removeFirst() }
                        if abs(pos.x - home.x) < 0.5, abs(pos.y - home.y) < 0.5,
                           abs(vel.dx) < 6, abs(vel.dy) < 6 {
                            apertureOrbGlobal = home
                            break
                        }
                        try? await Task.sleep(nanoseconds: 14_000_000)
                    }
                }
                // The tail dissipates over the flight; no artificial collapse
                // (apertureReturn stays 0 — real points stream instead).
                withAnimation(.easeOut(duration: 0.6)) {
                    apertureTrailFade = 0
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    apertureStretch = 0
                }
                // Shrink + fade back into the aperture mark as it returns.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    apertureMorph = 0
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard !isDraggingAperture else { return }
                    apertureReturnTask?.cancel()   // settle fallback — normally already finished
                    apertureReturnTask = nil
                    apertureOrbActive = false
                    apertureTrail = []
                }
            }
    }

    // MARK: - Copland develop sequence

    /// Whether a photo carries a Copland develop. The test lives on `PhotoCell`
    /// alongside the cells that show the result.
    private func isCoplandDeveloped(_ index: UInt8) -> Bool {
        PhotoCell.isCoplandDeveloped(serialManager.importedPhotoURLs[index])
    }

    /// The index of an un-developed thumbnail whose image area contains the given
    /// global point (the orb's release position), or nil.
    private func coplandHitTest(_ p: CGPoint) -> UInt8? {
        for index in serialManager.photoIndices where !isCoplandDeveloped(index) {
            if let f = thumbnailFrames.frames[index], f.contains(p) { return index }
        }
        return nil
    }

    /// Flow the orb into the thumbnail and run the develop sequence: morph the
    /// glass bubble from the orb into a square over the photo, kick off a normal
    /// import / re-import (with gold sparkles on the progress bar), fade out on
    /// completion, leave the photo framed in Mac OS 9 chrome, then grow the
    /// aperture back into its sidebar home.
    private func beginCopland(at index: UInt8) {
        guard serialManager.canDevelopCopland, serialManager.photoIndices.contains(index),
              coplandTask == nil else { return }
        let generation = serialManager.photoSessionGeneration
        let taskID = UUID()
        coplandTaskID = taskID
        coplandReleasePoint = apertureOrbGlobal
        coplandIndex = index
        coplandActive = true
        coplandMorph = 0
        coplandBubbleOpacity = 1
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { apertureStretch = 0 }
        // Let the comet tail dissipate INTO the develop handoff instead of
        // popping off with the orb (the orb layer stays mounted through a
        // develop just to finish this fade).
        withAnimation(.easeOut(duration: 0.3)) { apertureTrailFade = 0 }
        // Shrink the target to the un-imported size first (already-imported photos
        // visibly contract), so both flows develop + expand identically.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { coplandShrinkIndex = index }
        // Absorb: the bubble flows from the orb into the thumbnail's square.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { coplandMorph = 1 }

        coplandTask = Task { @MainActor in
            defer {
                // A cancelled task must never dismantle a newer effect.
                if coplandTaskID == taskID { resetCopland() }
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && coplandTaskID == taskID
                    && serialManager.photoSessionGeneration == generation
                    && serialManager.isConnected && serialManager.photoIndices.contains(index)
            }
            // Let the bubble settle over the photo before the develop kicks off.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard isCurrent(), serialManager.canDevelopCopland else { return }

            let alreadyImported = !(serialManager.importedPhotoURLs[index]?.isEmpty ?? true)
            let needsImport = serialManager.selectedModel.usesQTKFormat || !alreadyImported
            if serialManager.selectedModel.usesQTKFormat {
                // QTK colour pipeline re-decodes (imported or not) and drives
                // the normal photoTransfers progress bar.
                serialManager.reimportPhoto(at: index)
            } else if !alreadyImported {
                // Other models: a normal single-photo import for un-imported ones.
                importPhoto(index)
            }
            // Hold the develop bubble until THIS photo's transfer settles —
            // tracked by its chip, not a fixed ceiling. A fixed 25 s cap sized
            // for the QT150 is too short: a QT200 photo is ~87 KB over serial
            // and takes ~28 s, so the bake would fire ~2 s BEFORE the file
            // landed and abort with "no imported URL".
            // The long ceiling below is purely a hang backstop.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard isCurrent() else { return }
            var waited: UInt64 = 0
            while serialManager.isBusy, waited < 240_000_000_000 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard isCurrent() else { return }
                waited += 120_000_000
            }
            guard !serialManager.isBusy else { return }
            if needsImport {
                guard let transfer = serialManager.cameraTransfer(for: index) else { return }
                switch transfer.status {
                case .imported, .reimported, .alreadyCurrent: break
                default: return
                }
            }
            // A beat so the finished photo reads before the bubble lifts.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard isCurrent() else { return }

            // Bake the Mac OS 9 framed file (with "copland" in its name) from the
            // imported image. Its presence is what marks the photo developed → the
            // thumbnail then slowly gains its soft gold glow.
            bakeCoplandFile(for: index)
            // Release the shrink → the photo (and bubble) expand to full size.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { coplandShrinkIndex = nil }
            withAnimation(.easeOut(duration: 0.5)) { coplandBubbleOpacity = 0 }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard isCurrent() else { return }

            // Tear down the overlay and grow the aperture back into its home. Park
            // the orb at home first so the mark grows back in place (no fly-in).
            coplandActive = false
            coplandIndex = nil
            coplandMorph = 0
            apertureOrbGlobal = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
            apertureTrail = []
            apertureTrailFade = 0
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                apertureMorph = 0
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private func cancelCopland() {
        guard coplandTask != nil else { return }
        coplandTask?.cancel()
        resetCopland()
    }

    private func resetCopland() {
        coplandTask = nil
        coplandTaskID = nil
        coplandActive = false
        coplandIndex = nil
        coplandShrinkIndex = nil
        coplandMorph = 0
        coplandBubbleOpacity = 1
        apertureOrbActive = false
        apertureMorph = 0
        apertureStretch = 0
        apertureTrail = []
        apertureTrailFade = 0
        apertureOrbGlobal = CGPoint(x: apertureRect.midX, y: apertureRect.midY)
    }

    /// Composites the imported photo into the real Mac OS 9 window chrome
    /// (`CoplandFrame` asset) and writes it to the import-destination folder with
    /// `_copland` in the name (even a simulated photo produces a genuine file;
    /// silent overwrite). That saved file is the "developed" marker — the
    /// THUMBNAIL stays the plain photo (just gains the soft glow).
    ///
    /// The frame has a transparent content hole; to fit the FULL photo at any
    /// QuickTake resolution (HQ 640×480 / SQ 320×240) the middle slice is stretched
    /// vertically (lengthening the side borders + scrollbar — no distortion) so the
    /// hole matches the photo's aspect exactly, and the photo is drawn behind it.
    @MainActor
    private func bakeCoplandFile(for index: UInt8) {
        let photo: NSImage
        let stem: String
        if DemoCamera.shared.isConnected {
            // Demo imports have no on-disk export. Read the source again so
            // a cached preview from an older, incorrect decode cannot leak
            // into the framed file. Only the requested Copland file is saved.
            guard let demoPhoto = DemoCamera.shared.decodedPreview(at: index) else { return }
            photo = demoPhoto
            stem = "Demo_\(serialManager.selectedModel.profile.shortName)_\(index + 1)"
        } else {
            let urls = serialManager.importedPhotoURLs[index] ?? []
            guard let base = urls.first(where: {
                $0.pathExtension.lowercased() != "qtk" && !CoplandArtifactPolicy.isDisplayArtifact($0)
            }), let importedPhoto = NSImage(contentsOf: base) else { return }
            photo = importedPhoto
            stem = base.deletingPathExtension().lastPathComponent
        }
        guard let frame = NSImage(named: "CoplandWindow") else {
            return
        }

        let camera = serialManager.isConnected ? serialManager.selectedModel.profile.shortName : "SwiftTake"
        let dateText: String = {
            guard let d = serialManager.captureDate(forIndex: index) else { return "" }
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: d)
        }()
        let info = dateText.isEmpty ? camera : "\(camera)  —  \(dateText)"

        guard let data = composeCoplandPNG(photo: photo, frame: frame, info: info) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.8)) {
            _ = serialManager.saveCoplandImage(data, baseName: stem, for: index)
        }
    }

    /// A Charcoal (period) font, matching the app's classic helper.
    private func charcoalNSFont(_ size: CGFloat) -> NSFont {
        for name in ["Charcoal", "ChiKareGo2", "ChicagoFLF", "Charcoal CY", "Chicago", "Geneva"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.boldSystemFont(ofSize: size)
    }

    /// The bounding box of the frame's transparent content hole, in TOP-LEFT
    /// pixel/point coords — so the photo fills exactly the transparent region.
    private func transparentHole(of frame: NSImage) -> CGRect? {
        var r = CGRect(x: 0, y: 0, width: frame.size.width, height: frame.size.height)
        guard let cg = frame.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = 0, maxY = 0, found = false
        for yTop in 0..<h {
            let yb = h - 1 - yTop
            for x in 0..<w where buf[(yb * w + x) * 4 + 3] < 40 {
                found = true
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if yTop < minY { minY = yTop }; if yTop > maxY { maxY = yTop }
            }
        }
        guard found else { return nil }
        // Scale from pixels back to the NSImage's point size (handles any DPI).
        let sx = frame.size.width / CGFloat(w), sy = frame.size.height / CGFloat(h)
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    /// Composites the photo into the `CoplandWindow` chrome's transparent hole and
    /// draws the dynamic info string in Charcoal, returning PNG data.
    @MainActor
    private func composeCoplandPNG(photo: NSImage, frame: NSImage, info: String) -> Data? {
        let FW = frame.size.width, FH = frame.size.height

        // DETECT the frame's transparent content hole at runtime (top-left coords),
        // so the photo fills exactly the transparent region whatever the frame is —
        // self-correcting, no hardcoded measurements.
        guard let hole = transparentHole(of: frame) else { return nil }
        let holeLeft = hole.minX, holeTop = hole.minY
        let holeW = hole.width, holeH = hole.height

        // Sanity floor: a real window hole is most of the frame (~93%). If the
        // asset were ever corrupted/swapped so detection returns a degenerate tiny
        // hole, `k = photoPixels / holeW` would explode and the NSImage allocation
        // below could demand gigabytes (beachball/crash). Bail gracefully instead —
        // the bake fails safe (orb returns home, nothing develops) like any other
        // missing-asset case.
        guard holeW >= FW * 0.3, holeH >= FH * 0.3 else { return nil }

        // Size off the photo's true PIXELS so the framed export is full-res/crisp.
        // Uniform scale k from the hole width — the whole frame scales with NO
        // distortion.
        let pw = CGFloat(photo.representations.first?.pixelsWide ?? Int(photo.size.width))
        let ph = CGFloat(photo.representations.first?.pixelsHigh ?? Int(photo.size.height))
        guard pw > 0, ph > 0 else { return nil }
        let k = pw / holeW
        let targetW = FW * k, targetH = FH * k

        // top-left row → bottom-left y in the scaled output.
        func blY(_ topY: CGFloat) -> CGFloat { targetH - topY * k }

        let out = NSImage(size: NSSize(width: targetW, height: targetH))
        out.lockFocus()
        guard let g = NSGraphicsContext.current else { out.unlockFocus(); return nil }

        // 1) The frame's transparent opening sits high (asymmetric chrome), so
        //    push the photo DOWN by `dropPx` to sit lower than centre. The photo
        //    overhangs the bottom (the frame's scrollbar chrome covers it); a light
        //    backdrop fills the hole first so the thin gap it leaves at the very top
        //    reads as neutral, not transparent.
        let dropPx: CGFloat = 21          // frame-px to lower the photo (tunable)
        g.imageInterpolation = .high
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: holeLeft * k, y: blY(holeTop + holeH), width: holeW * k, height: holeH * k).fill()
        photo.draw(in: NSRect(x: holeLeft * k, y: blY(holeTop + holeH) - dropPx * k,
                              width: holeW * k, height: holeH * k))

        // 2) Frame chrome on top, uniform scale — its transparent hole reveals the
        //    photo; title bar, lock/✗ icons and scrollbars sit on top.
        g.imageInterpolation = .none
        frame.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))

        // 3) Camera + capture date in the toolbar zone (below the title bar),
        //    Charcoal, NO backdrop — centred under the SwiftTake title group, which
        //    is centred at the frame centre (measured: content span centre ≈ 202).
        g.imageInterpolation = .high
        let attrs: [NSAttributedString.Key: Any] = [
            .font: charcoalNSFont(9 * k),
            .foregroundColor: NSColor.black
        ]
        let ns = info as NSString
        let tsz = ns.size(withAttributes: attrs)
        let tyMid = blY(31)                                   // toolbar row ≈ native 31
        let centerBiasPx: CGFloat = 11                        // locked centre for the name (frame-px)
        let centerX = targetW / 2 + centerBiasPx * k
        let tx = centerX - tsz.width / 2                      // name centred on the locked centre
        ns.draw(at: NSPoint(x: tx, y: tyMid - tsz.height / 2), withAttributes: attrs)

        out.unlockFocus()

        guard let tiff = out.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let data = bmp.representation(using: .png, properties: [:]) else { return nil }
        return data
    }

    /// Densifies the recorded trail into a continuous run of points (interpolating
    /// sub-points across long gaps) so the comet tail stays smooth at any drag
    /// speed / refresh rate. Returns local-space points already lerped toward home
    /// by `apertureReturn`, paired with their taper factor f (0 tip → 1 orb).
    /// Window-level layer that renders the grabbed aperture orb (above the
    /// sidebar so it isn't clipped), positioned at the cursor. The view lives
    /// in `ApertureOrbLayer.swift`; this gathers its inputs.
    @ViewBuilder
    private var apertureOrbLayer: some View {
        // Stays mounted through a Copland develop so the comet tail can fade
        // out gracefully; only the orb BALL swaps out (the develop bubble
        // replaces it at the release point).
        if apertureOrbActive {
            ApertureOrbLayer(
                orbGlobal: apertureOrbGlobal,
                homeRect: apertureRect,
                morph: apertureMorph,
                stretch: apertureStretch,
                stretchAngle: apertureStretchAngle,
                trailFade: apertureTrailFade,
                trail: apertureTrail,
                returnProgress: apertureReturn,
                coplandActive: coplandActive)
        }
    }

    /// The Copland develop overlay. The view lives in
    /// `CoplandDevelopLayer.swift`; this gathers its inputs.
    @ViewBuilder
    private var coplandLayer: some View {
        if coplandActive, let index = coplandIndex {
            CoplandDevelopLayer(
                index: index,
                frameStore: thumbnailFrames,
                releasePoint: coplandReleasePoint,
                morph: coplandMorph,
                bubbleOpacity: coplandBubbleOpacity,
                isShrinking: coplandShrinkIndex == index,
                enhancedImage: serialManager.enhancedPreviewImages[index],
                thumbnail: serialManager.availableThumbnails[index],
                isConnected: serialManager.isConnected,
                hasImportedFiles: serialManager.importedPhotoURLs[index] != nil,
                squareGrid: gallerySquareGrid)
        }
    }

    /// Records the phantom photo as collected and flashes the aperture as the
    /// photo flies into it. The overlay's own animation drives timing/dismissal.
    private func flashApertureForPhantom(_ egg: QuickTakeSerialManager.PhantomEgg) {
        serialManager.markPhantomAbsorbed(egg)
        apertureGlowColor = phantomGlowColor(egg)
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.45)) { apertureGlowLevel = 1 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.9)) { apertureGlowLevel = 0 }
        }
    }

    /// The saved-panorama viewer, over the gallery it belongs to.
    @ViewBuilder
    private var panoramaViewerLayer: some View {
        if let panorama = viewingPanorama {
            PanoramaViewer(panorama: panorama,
                           isClassicTheme: isClassicTheme,
                           onClose: { closePanoramaViewer() })
                .transition(.opacity)
        }
    }

    /// The morphing status bubble. The view lives in
    /// `StatusBubbleLayer.swift`; this gathers its inputs.
    @ViewBuilder
    private var statusBubbleLayer: some View {
        // Only while the sidebar is visible — otherwise the bubble would float
        // over the detail pane with no sidebar to belong to.
        if statusHomeRect != .zero && columnVisibility != .detailOnly {
            StatusBubbleLayer(
                homeRect: statusHomeRect,
                morph: statusMorph,
                orbGlobal: statusOrbGlobal,
                stretch: statusStretch,
                stretchAngle: statusStretchAngle,
                absorbScale: statusAbsorbScale,
                text: statusDisplayText,
                indicatorColor: statusIndicatorColor)
        }
    }

}

private extension ContentView {

    /// Recompute which sidebar sections are shown.
    ///
    /// Sections mirror their `userWants*` preference directly, gated by the
    /// prerequisite state (camera connected, controls not popped out, model
    /// supports controls). They collapse only on an explicit user click or
    /// when a prerequisite drops away. Overflow is the wrapping ScrollView's
    /// job. (An earlier height-based greedy fill auto-collapsed sections when
    /// the window got short, which snapped visibly; the ScrollView replaced it.)
    func recalculateSections() {
        let isConnected = serialManager.isConnected && serialManager.metadata != nil

        let showConn = userWantsConnectionExpanded
        let showCam  = isConnected && userWantsCameraExpanded
        let showCtrl = isConnected
                    && userWantsCameraControlsExpanded
                    && !serialManager.isCameraControlPoppedOut
                    && serialManager.selectedModel.supportsCameraControlUI

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isConnectionExpanded = showConn
            isCameraExpanded = showCam
            isCameraControlsExpanded = showCtrl
        }
    }

    /// The canvas's no-photos state. The view lives in
    /// `WindowOverlays.swift`; this gathers its inputs.
    private var emptyStateSection: some View {
        GalleryEmptyState(
            isConnected: serialManager.isConnected,
            cameraShortName: serialManager.selectedModel.profile.shortName,
            isBusy: serialManager.isBusy,
            onRefresh: { serialManager.refreshCameraMetadata() },
            onShowConnectionHelp: { showingConnectionHelp = true })
    }

    /// The gallery. `GalleryGrid` is a struct so the cells are built inside it
    /// rather than in this body; the inputs below are exactly the state the
    /// gallery depends on, and nothing else reaches the ForEach.
    ///
    /// The taps hand back through closures rather than taking bindings for
    /// focus, selection and the anchor: those are written nowhere else in the
    /// gallery, so the mutations stay here with the state they touch.
    private var gallerySection: some View {
        GalleryGrid(
            columns: gridColumns,
            spacing: effectiveSpacing,
            thumbnailWidth: galleryThumbnailWidth,
            isPinching: isPinchingGallery,
            isFullScreen: isFullScreen,
            squareGrid: gallerySquareGrid,
            galleryWidth: $galleryWidth,
            photoIndices: serialManager.photoIndices,
            selectedPhotoIndices: serialManager.selectedPhotoIndices,
            panoramaSlots: Set(serialManager.panoramaBySlot.keys),
            canMakePanorama: serialManager.canStitchSelection,
            onMakePanorama: { serialManager.stitchSelectedPanorama() },
            onOpenPanorama: { index in openPanoramaViewer(for: index) },
            onImportPhoto: { index in importPhoto(index) },
            activePanorama: bandYieldsToViewer ? nil : activePanorama,
            onOpenSavedPanorama: { pano in present(pano) },
            enhancedPreviewImages: serialManager.enhancedPreviewImages,
            availableThumbnails: serialManager.availableThumbnails,
            importedPhotoURLs: serialManager.importedPhotoURLs,
            photoQualities: serialManager.photoQualities,
            photoNames: serialManager.photoNames,
            isConnected: serialManager.isConnected,
            focusedPhotoIndex: focusedPhotoIndex,
            showKeyboardFocusRing: focusedViaKeyboard && galleryHasKeyboardFocus,
            qualityBadgeSize: qualityBadgeSize,
            squareModeHidesGlow: squareModeHidesGlow,
            apertureOrbActive: apertureOrbActive,
            coplandIndex: coplandIndex,
            coplandShrinkIndex: coplandShrinkIndex,
            frameStore: thumbnailFrames,
            editingName: $editingName,
            focusedField: $focusedField,
            onTap: { index in
                focusedPhotoIndex = index
                focusedViaKeyboard = false
                galleryHasKeyboardFocus = true
                handlePhotoTap(index)
            },
            onDoubleTap: { index in
                focusedPhotoIndex = index
                focusedViaKeyboard = false
                galleryHasKeyboardFocus = true
                serialManager.selectedPhotoIndices = [index]
                selectionAnchor = index
                Task { await previewFocusedPhotoInQuickLook(index) }
            },
            onRename: { index, newName in
                serialManager.renamePhoto(at: index, to: newName)
            },
            onRevealInFinder: { urls in
                revealInFinder(urls)
            })
    }

    // The three popovers the toolbar and the Classic control row share. The
    // views live in `GalleryChrome.swift`; these gather their inputs. All
    // three are built inside `.popover` content closures, so the work inside
    // them (the imported-count filter, the info popover's disk reads) only
    // runs when a popover is actually opened.

    private var selectionOptionsPopover: some View {
        SelectionOptionsPopover(
            hasSelection: !serialManager.selectedPhotoIndices.isEmpty,
            showingImportOptions: $showingImportOptions,
            showingSelectionMenu: $showingSelectionMenu,
            onSelectAll: { serialManager.selectAllPhotos() },
            onDeselectAll: {
                serialManager.selectedPhotoIndices.removeAll()
                selectionAnchor = nil
            })
    }

    private var importOptionsPopover: some View {
        ImportOptionsPopover(
            photoIndices: serialManager.photoIndices,
            selectedCount: serialManager.selectedPhotoIndices.count,
            importedPhotoURLs: serialManager.importedPhotoURLs,
            showingImportOptions: $showingImportOptions,
            onImportSelected: { importToDefaultLocation(importAll: false) },
            onImportNew: { importToDefaultLocation(importAll: true, skipImported: true) },
            onImportEverythingAgain: { importToDefaultLocation(importAll: true) })
    }

    private func photoInfoPopover(for index: UInt8) -> some View {
        PhotoInfoPopover(
            photoName: getPhotoName(for: index),
            savedURLs: serialManager.importedPhotoURLs[index] ?? [],
            captureDate: serialManager.captureDate(forIndex: index),
            isHQ: serialManager.photoQualities[index])
    }


    /// The 90s Apple stripes as a horizontal bar fill. Defined on `AppTheme`
    /// now that the panorama stitch bar wears it too — this stays as the
    /// name the two bars in this file already use.
    static let apple90sGradient = AppTheme.apple90sStripes


    /// The detail pane's import/develop progress bar. A dedicated view so its
    /// per-tick redraws stay OUT of the main body: the live fractions come
    /// from `TransferProgressStore`, which the manager writes silently ~8×/s
    /// during a transfer, and only THIS view registers a dependency on it.
    /// The @Published `photoTransfers` array changes only on edges (queue
    /// built, status flips, completion) — that's when the parent re-passes
    /// `transfers`, keeping progress ticks from redrawing the gallery.
    private struct BatchProgressBar: View {
        let transfers: [PhotoTransfer]
        let live: TransferProgressStore
        let coplandActive: Bool
        @Environment(\.isClassicTheme) private var isClassicTheme

        var body: some View {
        let total = Double(transfers.count)
        let completed = Double(transfers.filter { $0.progress >= 1 }.count)
        let queued = transfers.filter { $0.status == .waiting }.count
        let progressSum = transfers.reduce(0.0) { partial, transfer in
            // Store first (the live tick), the array value as the floor —
            // its terminal writes cover a photo that finished before this
            // bar appeared, and the max() guards a stale store entry.
            partial + min(max(live.values[transfer.id] ?? 0, transfer.progress), 1)
        }
        let overallProgress = total > 0 ? progressSum / total : 0.0
        let isDone = total > 0 && completed == total

        let apple90sGradient = ContentView.apple90sGradient
        // OS 9 determinate progress: a period-blue gel (light top → dark bottom).
        let classicBarFill = LinearGradient(
            colors: [Color(red: 0.42, green: 0.56, blue: 0.86), Color(red: 0.20, green: 0.33, blue: 0.64)],
            startPoint: .top, endPoint: .bottom)

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(isDone ? .green : .accentColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isDone ? "Import Complete" : (queued > 0 ? "Importing Photos... \(queued) Queued" : "Importing Photos..."))
                        .font(isClassicTheme ? Font.classic(11, weight: .bold) : .caption)
                        .fontWeight(.bold)
                        .contentTransition(.numericText())

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Classic: a sunken white Platinum well with a period-blue
                            // gel; other themes keep the 90s rainbow bar.
                            RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                                .fill(isClassicTheme ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary.opacity(0.2)))
                                .overlay {
                                    if isClassicTheme {
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(AppTheme.platinumShadow.opacity(0.7), lineWidth: 1)
                                    }
                                }
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                                .fill(isClassicTheme ? AnyShapeStyle(classicBarFill) : AnyShapeStyle(apple90sGradient))
                                .frame(width: geo.size.width * overallProgress, height: 6)
                                // Longer-than-default ease so the small
                                // jumps between phases (download →
                                // decode → write → complete) tween
                                // gently rather than snap. Combined
                                // with the manager's phantom-progress
                                // ticker during decode, this keeps the
                                // bar visibly flowing for the entire
                                // ~8s of an import.
                                .animation(.easeOut(duration: 0.45), value: overallProgress)

                            // Copland develop only: gold sparkles ride the tip.
                            if coplandActive {
                                // Offset the frame up-left so the bar tip lands at the
                                // sparkles' emit point (local 0.75, 0.80) — they spray
                                // up-left FROM the tip.
                                CoplandSparkles(progress: overallProgress)
                                    .frame(width: 64, height: 60)
                                    .position(x: max(2, geo.size.width * overallProgress) - 16, y: 3 - 18)
                                    .animation(.easeOut(duration: 0.45), value: overallProgress)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(height: 6)
                }

                Text("\(Int(completed)) of \(Int(total))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20)
            // Fixed height shared with the sidebar status footer so the two
            // bottom bars line up across the sidebar/detail divider.
            .frame(height: ContentView.bottomBarHeight)
            .background {
                if isClassicTheme { AppTheme.platinumFace } else { Rectangle().fill(.ultraThinMaterial) }
            }
        }
        .frame(maxWidth: .infinity)
        }
    }


    private func importToDefaultLocation(importAll: Bool, skipImported: Bool = false) {
        let destination = serialManager.effectiveImportDestinationURL
        serialManager.batchDownloadImages(to: destination, importAll: importAll, skipImported: skipImported)
    }

    /// Title for the primary Import control — reflects the current selection,
    /// and is explicit about counts so it always reads clearly.
    private var importPrimaryTitle: String {
        let selected = serialManager.selectedPhotoIndices.count
        if selected > 0 {
            return "Import \(selected) Selected"
        }
        return "Import All (\(serialManager.photoIndices.count))"
    }

    /// The primary Import action: import the selection if there is one, else all.
    private func beginImport() {
        if serialManager.selectedPhotoIndices.isEmpty {
            beginImportAll()
        } else {
            importToDefaultLocation(importAll: false)
        }
    }

    /// Import every photo — with the overwrite confirmation when some are
    /// already on disk.
    private func beginImportAll() {
        let hasImported = serialManager.importedPhotoURLs.values.contains { !$0.isEmpty }
        if hasImported {
            showingOverwriteConfirmation = true
        } else {
            importToDefaultLocation(importAll: true)
        }
    }

    /// Arrow-key navigation through the gallery. Treats `photoIndices`
    /// as a 1-D list and jumps by `galleryColumnCount` rows on
    /// up / down. When nothing is focused yet, the first arrow press
    /// just focuses the first photo so the user can take over from
    /// there. In selection mode the highlight follows focus so the
    /// keyboard can fully drive single-photo selection.
    private func moveGalleryFocus(_ direction: MoveCommandDirection, extendSelection: Bool) {
        let indices = serialManager.photoIndices
        guard !indices.isEmpty else { return }

        // No focus yet — first arrow press lands on the first photo.
        guard let current = focusedPhotoIndex,
              let position = indices.firstIndex(of: current) else {
            let landing = indices.first!
            autoScrollToFocus = true
            focusedPhotoIndex = landing
            focusedViaKeyboard = true
            galleryHasKeyboardFocus = true
            return
        }

        let count = indices.count
        let columns = max(1, galleryColumnCount)
        let newPosition: Int
        switch direction {
        case .left:  newPosition = max(0, position - 1)
        case .right: newPosition = min(count - 1, position + 1)
        case .up:    newPosition = max(0, position - columns)
        case .down:  newPosition = min(count - 1, position + columns)
        @unknown default: return
        }

        guard newPosition != position else { return }
        let nextIndex = indices[newPosition]
        // Arrow keys move the focus ring only — selection is driven by clicks
        // (plain / ⌘ / ⇧). ⇧+arrow extends the selection from the anchor.
        if extendSelection {
            selectRange(to: nextIndex)
        }
        autoScrollToFocus = true
        focusedPhotoIndex = nextIndex
        focusedViaKeyboard = true
        galleryHasKeyboardFocus = true
    }

    /// Finder/Photos-style click selection. Plain = select just this one;
    /// ⌘ = toggle; ⇧ = contiguous range from the anchor.
    private func handlePhotoTap(_ index: UInt8) {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if mods.contains(.command) {
            serialManager.toggleSelection(for: index)
            selectionAnchor = index
        } else if mods.contains(.shift) {
            selectRange(to: index)
        } else {
            serialManager.selectedPhotoIndices = [index]
            selectionAnchor = index
        }
    }

    /// Select the contiguous run of `photoIndices` between the anchor (or
    /// `target` if no anchor yet) and `target`, replacing the current selection.
    private func selectRange(to target: UInt8) {
        let indices = serialManager.photoIndices
        let anchor = selectionAnchor ?? target
        guard let a = indices.firstIndex(of: anchor),
              let b = indices.firstIndex(of: target) else {
            serialManager.selectedPhotoIndices = [target]
            return
        }
        serialManager.selectedPhotoIndices = Set(indices[min(a, b)...max(a, b)])
    }

    /// Reveal ONE representative file in Finder (the Copland-framed export if it
    /// exists, else the rendered image, else the first) so it's always a single
    /// Finder window — even when a photo's files span folders (e.g. the simulated
    /// base in a temp dir + the Copland file in the photos folder).
    private func revealInFinder(_ urls: [URL]) {
        let target = urls.first(where: CoplandArtifactPolicy.isDisplayArtifact)
            ?? urls.first(where: { $0.pathExtension.lowercased() != "qtk" })
            ?? urls.first
        if let target {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    private func importPhoto(_ index: UInt8) {
        guard !serialManager.areThumbnailsLoading else { return }
        serialManager.selectedPhotoIndices = [index]
        importToDefaultLocation(importAll: false)
    }

    /// Opening a photo and importing it are the same transfer over the slow
    /// serial link, so a double-click does both: an already-imported photo
    /// opens straight from disk, and a new one is imported (download → save →
    /// cache, with the import progress bar) and then shown in QuickLook.
    private func previewFocusedPhotoInQuickLook(_ index: UInt8) async {
        // A frame that went into a saved panorama opens the PANORAMA — in
        // the floating panel, over the gallery, rather than importing a
        // photo nobody asked for. The cell is badged so this is not a
        // surprise, and the context menu still offers the frame's own
        // import.
        if serialManager.panoramaBySlot[index] != nil {
            openPanoramaViewer(for: index)
            return
        }
        // Already on disk (this session or a previous one)? Show it without
        // touching the camera — no re-download, no duplicate file.
        if serialManager.loadImportedPreviewIfAvailable(at: index) {
            presentAllAvailablePreviews(startingAt: index)
            return
        }

        // New photo: opening it imports it. Kick off the single-photo import,
        // then present once the saved preview is cached.
        guard !serialManager.isBusy, !serialManager.areThumbnailsLoading else { return }
        importPhoto(index)

        // Wait for the import to finish writing + caching the preview. The
        // import bar shows progress meanwhile; QuickLook opens when ready.
        for _ in 0..<300 {
            if temporaryQuickLookURL(for: index) != nil {
                presentAllAvailablePreviews(startingAt: index)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The panorama the current selection belongs to, if any.
    ///
    /// The band shows ONE at a time and follows the selection, and this is
    /// the whole rule: the selected photos must agree on which panorama
    /// they came from. Click a linked photo and the set is trivially one,
    /// so its panorama appears; click a frame from another and it changes;
    /// deselect and there is nothing to answer, so the band goes. Right
    /// after a save every source frame is still selected and every one of
    /// them points at the panorama just made, which is why it appears
    /// unprompted.
    ///
    /// A selection spanning two panoramas agrees on nothing and shows
    /// nothing. That is the honest answer rather than a limitation: Select
    /// All, or a Shift-drag across the boundary, is not a question about
    /// one photo, and picking a winner would state something the user
    /// never asked.
    ///
    /// This deliberately does NOT consult `focusedPhotoIndex`. Letting the
    /// last-clicked photo win looks equivalent — a single selection
    /// resolves the same either way — but focus is sticky: nothing clears
    /// it on Select All or on a Shift-extend, so a click from minutes ago
    /// would go on governing the band, and every selection that spans two
    /// panoramas would confidently show one of them.
    private var activePanorama: QuickTakeSerialManager.SavedPanorama? {
        let urls = Set(serialManager.selectedPhotoIndices
            .compactMap { serialManager.panoramaBySlot[$0] })
        guard urls.count == 1, let only = urls.first else { return nil }
        return serialManager.savedPanoramas.last { $0.image == only }
    }

    /// Show the panorama a given camera slot contributed to.
    private func openPanoramaViewer(for index: UInt8) {
        guard let url = serialManager.panoramaBySlot[index],
              let record = serialManager.savedPanoramas.last(where: { $0.image == url })
        else { return }
        present(record)
    }

    /// The band and the panel are the SAME picture, so they hand over
    /// rather than stack. Showing both at once said it twice, and the
    /// panel landing on top of its own smaller copy read as a duplicate
    /// rather than a zoom.
    ///
    /// Sequenced, not simultaneous: the band fades first and the panel
    /// arrives in the space it left. Crossing them over just looks like
    /// two things fighting for the same spot.
    private func present(_ record: QuickTakeSerialManager.SavedPanorama) {
        guard viewingPanorama == nil else { viewingPanorama = record; return }
        withAnimation(.easeOut(duration: 0.18)) { bandYieldsToViewer = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            viewingPanorama = record
        }
    }

    /// Every way out of the panel comes through here — Done, Escape, a
    /// click outside, and the panorama being cleared underneath it — so
    /// the band can never be left hidden with nothing in front of it.
    private func closePanoramaViewer() {
        withAnimation(.easeOut(duration: 0.16)) { viewingPanorama = nil }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.easeIn(duration: 0.24)) { bandYieldsToViewer = false }
        }
    }

    private func presentAllAvailablePreviews(startingAt targetIndex: UInt8) {
        var items: [(url: URL, index: UInt8)] = []
        var selectedItemIndex = 0

        for photoIndex in serialManager.photoIndices {
            if let url = temporaryQuickLookURL(for: photoIndex) {
                if photoIndex == targetIndex {
                    selectedItemIndex = items.count
                }
                items.append((url: url, index: photoIndex))
            }
        }

        if !items.isEmpty {
            QuickLookPreviewController.shared.onIndexChanged = { newPhotoIndex in
                Task { @MainActor in
                    // Paging through QuickLook highlights the current photo in the
                    // gallery (focus ring + accent selection) and scrolls it into
                    // view (via the .onChange on focusedPhotoIndex).
                    self.autoScrollToFocus = true
                    self.focusedPhotoIndex = newPhotoIndex
                    self.serialManager.selectedPhotoIndices = [newPhotoIndex]
                    self.selectionAnchor = newPhotoIndex
                }
            }
            // Pass the column count as a LIVE closure so ↑/↓ row jumps respect
            // the current zoom/window size, which can change while open.
            QuickLookPreviewController.shared.present(
                items: items,
                selectedIndex: selectedItemIndex,
                columnCount: { self.galleryColumnCount }
            )
        }
    }

    private func temporaryQuickLookURL(for index: UInt8) -> URL? {
        guard let image = serialManager.enhancedPreviewImages[index],
              let tiffData = image.tiffRepresentation else {
            return nil
        }

        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTake-preview-\(index)")
            .appendingPathExtension("tiff")

        do {
            try tiffData.write(to: previewURL, options: .atomic)
            return previewURL
        } catch {
            return nil
        }
    }


}

/// Classic-theme loading tile: a black-and-white CRT "snow" — animated static
/// + scanlines — that the real photo fizzles in over. No colour, period-correct.
struct ClassicCRTLoader: View {
    var seed: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Dark phosphor base.
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))

                // Deterministic per-frame snow (own LCG — Math.random isn't used).
                var s = UInt64(bitPattern: Int64((t * 30).rounded())) &+ UInt64(seed * 1009 + 1)
                func rnd() -> Double {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    return Double(s >> 33) / Double(UInt64(1) << 31)
                }
                let dots = Int((size.width * size.height) / 26)
                for _ in 0..<max(1, dots) {
                    let x = rnd() * size.width
                    let y = rnd() * size.height
                    let b = 0.25 + rnd() * 0.75
                    ctx.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)),
                             with: .color(Color(white: b)))
                }

                // CRT scanlines.
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(.black.opacity(0.35)))
                    y += 3
                }
            }
        }
        .background(Color.black)
    }
}


/// Little gold STARS twinkling off the tip of the import progress bar — shown
/// only during a Copland develop. Each is a 4-point sparkle that emits from the
/// centre, flies up/outward, spins a little and fades.
private struct CoplandSparkles: View {
    /// Live overall progress (0…1) — its rate of change leans the spray.
    var progress: Double = 0
    @State private var lastProgress: Double = 0
    @State private var lean: Double = 0       // 0…1, how hard the spray tilts

    /// A 4-point sparkle (concave star) centred at `c`, outer radius `r`.
    private func sparkle(_ c: CGPoint, _ r: CGFloat, rotation: Double) -> Path {
        var p = Path()
        let inner = r * 0.34
        let pts = 4
        for k in 0..<(pts * 2) {
            let rad = (k % 2 == 0) ? r : inner
            let a = rotation - Double.pi / 2 + Double(k) * Double.pi / Double(pts)
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let gold = Color(red: 0.99, green: 0.86, blue: 0.46)
                let n = 6   // just a few — cute, not a fountain
                // Emit from the bar TIP (the frame is positioned so the tip lands
                // here) and drift up-left as they fade.
                let ox = size.width * 0.75
                let oy = size.height * 0.80
                for i in 0..<n {
                    // Deterministic per-particle randoms (no Math.random).
                    func rnd(_ k: Double) -> Double {
                        let v = sin(Double(i) * k) * 43758.5453
                        return v - floor(v)
                    }
                    let r1 = rnd(12.9898), r2 = rnd(78.233), r3 = rnd(37.719)
                    let speed = 0.6 + r1 * 0.45                          // slow, gentle lifecycle
                    let life = (t * speed + r2).truncatingRemainder(dividingBy: 1.0)
                    // Base up-left; the faster the bar moves, the more the spray
                    // leans toward horizontal-left (subtle until a big speed-up).
                    let ang = -3 * Double.pi / 4 - lean * 0.5 + (r3 - 0.5) * 0.9
                    let dist = life * (20 + r1 * 26)
                    let x = ox + CGFloat(cos(ang)) * CGFloat(dist)
                    let y = oy + CGFloat(sin(ang)) * CGFloat(dist)
                    let sz = CGFloat(1 - life) * (6.0 + CGFloat(r2) * 5.0)   // bigger stars
                    let spin = t * (0.8 + r1 * 1.2) + r2 * 6.28          // gentle twinkle-spin
                    ctx.opacity = (1 - life) * 0.95
                    ctx.fill(sparkle(CGPoint(x: x, y: y), sz, rotation: spin), with: .color(gold))
                }
            }
        }
        // Lean grows with how fast the progress tip advances between updates.
        .onChange(of: progress) { _, p in
            let delta = max(0, p - lastProgress)
            lastProgress = p
            withAnimation(.easeOut(duration: 0.6)) {
                lean = min(1, delta * 4.5)
            }
        }
    }
}

/// Apple-Intelligence-style "whirlpool of colour" shown while a thumbnail is
/// still downloading: solid rainbow vortices around slowly wandering eyes,
/// softly blurred and overscanned past the tile. The real image then fizzles
/// in over it (the cell crossfades to the photo with a blur dissolve).
struct ThumbnailLoadingSwirl: View {
    /// Per-tile phase offset so neighbouring tiles swirl out of sync rather
    /// than in lockstep (pass the photo index).
    var seed: Double = 0
    /// Connection-death staging: true → the vortex slowly spins DOWN
    /// to a stop and drains to black-and-white; false → it slowly winds back
    /// up. A time-warped clock, so freeze/resume are real deceleration and
    /// re-acceleration, not a hard stop.
    var frozen: Bool = false

    /// The tile's warped clock: advances at `rate`, which eases toward 0
    /// (frozen) or 1 (running) every tick.
    @State private var swirlTime: Double = 0
    @State private var rate: Double = 1
    @State private var lastTick: Date?

    // The six Apple "90s logo" stripe colours with a mixed midpoint between
    // each pair (and a seamless wrap back to green). The midpoints bake the
    // wedge-seam softness INTO the gradient — a live gaussian blur per tile
    // per frame would starve scrolling and the serial import of frame budget
    // across a full card of loading tiles.
    private static let palette: [Color] = {
        let stripes: [Color] = [
            Color(red: 0.38, green: 0.73, blue: 0.28), // Green
            Color(red: 0.96, green: 0.76, blue: 0.17), // Yellow
            Color(red: 0.94, green: 0.52, blue: 0.16), // Orange
            Color(red: 0.88, green: 0.21, blue: 0.26), // Red
            Color(red: 0.58, green: 0.24, blue: 0.59), // Purple
            Color(red: 0.00, green: 0.58, blue: 0.84), // Blue
            Color(red: 0.38, green: 0.73, blue: 0.28)  // back to green (seamless)
        ]
        var soft: [Color] = []
        for i in 0..<(stripes.count - 1) {
            soft.append(stripes[i])
            soft.append(stripes[i].mix(with: stripes[i + 1], by: 0.5))
        }
        soft.append(stripes[stripes.count - 1])
        return soft
    }()

    var body: some View {
        // Paused once fully spun down: a parked (dead-camera) gallery of
        // tiles burns zero frames. Unpausing on reconnect restarts the ticks
        // and the rate ramps back up.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: frozen && rate == 0)) { timeline in
            // ONE vortex per tile (seed-phased so neighbours stay out of
            // sync); the only compositing effect is the saturation drain,
            // which is a no-op while running (rate 1) — cheap enough that a
            // whole card of loading tiles doesn't fight the import.
            swirlLayer(t: swirlTime, phase: seed * 1.7 + 1.0)
                .scaleEffect(1.6)   // overscan hides the tile's hard edges
                .saturation(rate)   // drains to B&W in step with the spin-down
                .onChange(of: timeline.date) { _, now in
                    step(to: now)
                }
        }
    }

    /// Advance the warped clock: ease `rate` toward its target (~1.5 s to
    /// spin down or wind back up), then accumulate warped time.
    private func step(to now: Date) {
        let dt = min(now.timeIntervalSince(lastTick ?? now), 0.1)
        lastTick = now
        let target: Double = frozen ? 0 : 1
        rate += (target - rate) * min(1, dt * 2.2)
        if frozen, rate < 0.02 { rate = 0 }   // settle the tail; pauses the timeline
        swirlTime += dt * rate
    }

    /// One vortex: a solid six-colour rainbow sweep around a slowly wandering
    /// eye. `phase` decorrelates each layer / tile.
    private func swirlLayer(t: Double, phase p: Double) -> some View {
        let spin = Angle.degrees((t * 26 + p * 47).truncatingRemainder(dividingBy: 360))

        // Lissajous drift — different x / y frequencies, phase-shifted — so the
        // eye roams the tile instead of pivoting in the middle.
        let eye = UnitPoint(x: 0.5 + 0.30 * sin(t * 0.34 + p),
                            y: 0.5 + 0.30 * cos(t * 0.43 + p * 1.3))

        return AngularGradient(gradient: Gradient(colors: Self.palette),
                               center: eye, angle: spin)
    }
}

struct ThumbnailGrowModifier: ViewModifier {
    var scale: CGFloat
    var opacity: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                    .scaleEffect(scale < 1.0 ? 1.0 : 0)
                    .opacity(scale < 1.0 ? 1.0 : 0)
            )
    }
}


/// Non-blocking bottom bar while the connected camera's thumbnails stream in.
/// Same visual family as `BatchProgressBar`, but nothing is being written —
/// it's the "the app is busy, carry on" signal that replaced the full-window
/// Connecting blanket for this phase.
///
/// The fill GLIDES rather than steps: thumbnails arrive every ~0.5–3 s
/// depending on the camera (a QT200 preview is ~10 KB over serial ≈ 2.8 s),
/// and jumping once per arrival read as janky. Each new count animates over
/// the gap measured between the previous two arrivals — a continuous crawl on
/// a slow camera that still keeps up on a fast one.
private struct ThumbnailLoadingBar: View {
    let loaded: Int
    let total: Int

    @Environment(\.isClassicTheme) private var isClassicTheme
    /// Pacing state: when the previous chunk arrived, and how long the current
    /// tween should run (the last observed gap, clamped, one step behind).
    @State private var lastArrival = Date()
    @State private var pace: Double = 0.8

    private var progress: Double { total > 0 ? Double(loaded) / Double(total) : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .foregroundColor(.accentColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Loading Photos…")
                        .font(isClassicTheme ? Font.classic(11, weight: .bold) : .caption)
                        .fontWeight(.bold)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Classic: sunken white Platinum well + period-blue gel.
                            RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                                .fill(isClassicTheme ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary.opacity(0.2)))
                                .overlay {
                                    if isClassicTheme {
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(AppTheme.platinumShadow.opacity(0.7), lineWidth: 1)
                                    }
                                }
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: isClassicTheme ? 2 : 3)
                                .fill(isClassicTheme
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [Color(red: 0.42, green: 0.56, blue: 0.86), Color(red: 0.20, green: 0.33, blue: 0.64)],
                                        startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(ContentView.apple90sGradient))
                                .frame(width: geo.size.width * progress, height: 6)
                                .animation(.linear(duration: pace), value: progress)
                        }
                    }
                    .frame(height: 6)
                }

                Text("\(loaded) of \(total)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20)
            .frame(height: ContentView.bottomBarHeight)
            .background {
                if isClassicTheme { AppTheme.platinumFace } else { Rectangle().fill(.ultraThinMaterial) }
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: loaded) { _, _ in
            let now = Date()
            pace = min(3.5, max(0.3, now.timeIntervalSince(lastArrival)))
            lastArrival = now
        }
    }
}

struct ToastView: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    /// How long the banner stays on screen before dismissing itself.
    /// Longer than the old fixed 5 s so there's time to actually read
    /// it; errors get the longest dwell.
    var duration: TimeInterval = 8
    var onDismiss: () -> Void

    @Environment(\.isClassicTheme) private var isClassicTheme

    var body: some View {
        HStack(spacing: 16) {
            // Classic: a FLAT solid chip with a hard frame — the gradient +
            // coloured glow reads as Liquid Glass against the Platinum.
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    isClassicTheme ? AnyShapeStyle(color) : AnyShapeStyle(color.gradient),
                    in: RoundedRectangle(cornerRadius: isClassicTheme ? 3 : 8, style: .continuous))
                .overlay {
                    if isClassicTheme {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(AppTheme.platinumFrame.opacity(0.8), lineWidth: 1)
                    }
                }
                .shadow(color: isClassicTheme ? .clear : color.opacity(0.3), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isClassicTheme ? Font.classic(14, weight: .bold) : .headline)
                Text(subtitle)
                    .font(isClassicTheme ? Font.classic(12) : .subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.88, pressedOpacity: 0.8, shadowRadius: 1))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 400)
        .modifier(ToastBackgroundModifier())
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
        // A `.task` is tied to this view's lifetime: if the banner is
        // replaced by a different one, SwiftUI tears this view down and
        // cancels the sleep, so a stale timer can't dismiss whatever
        // banner came after it. (The old `asyncAfter` had exactly that
        // bug.)
        .task(id: title + subtitle) {
            // Keyed the same as the id above, so this fires exactly once per
            // distinct banner — never on a re-render of the same one.
            AccessibilityNotification.Announcement("\(title). \(subtitle)").post()
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

extension View {
    /// Liquid Glass panel normally, raised Platinum bevel in Classic.
    func themedPanel(cornerRadius: CGFloat, classic: Bool) -> some View {
        modifier(ThemedPanelModifier(cornerRadius: cornerRadius, classic: classic))
    }
}

private struct ThemedPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let classic: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if classic {
            content.classicBevel(cornerRadius: cornerRadius)
        } else if reduceTransparency {
            // Same shape as the glass path, an opaque window-coloured fill
            // in place of the see-through material.
            content.background(shape.fill(Color(NSColor.windowBackgroundColor)))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// In Classic the toolbar's glass is removed per-group via
// `.sharedBackgroundVisibility(.hidden)`; the Platinum look comes from this
// ButtonStyle. It's a real ButtonStyle (not external chrome) so the whole
// beveled area — not just the symbol — is the hit target.
struct ClassicToolbarButtonStyle: ButtonStyle {
    var prominent = false
    var classicFont = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(classicFont ? .classic(13, weight: .semibold) : .system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.platinumText)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .classicBevel(sunken: configuration.isPressed, cornerRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(prominent ? 0.85 : 0), lineWidth: 2)
            )
            .contentShape(Rectangle())
    }
}

/// Backdrop behind the sidebar brand header so the aperture + wordmark read
/// clearly: a raised Platinum plaque in Classic, a Liquid Glass capsule in the
/// regular themes. When both easter-egg tracks are complete it slowly gilds to
/// gold as a reward.
/// Live thumbnail frames (global coords) shared between the gallery cells
/// (writers), the orb's drop hit-test, and the Copland bubble (its reader).
///
/// An @Observable box instead of `@State` on ContentView on purpose: the
/// developing cell reports its frame on EVERY scrolled frame, and as @State
/// each write re-evaluated the entire ContentView body — the residual
/// "scrolling is laggy mid-develop" even after tracking was gated down to
/// one cell. With the box, a write invalidates only `CoplandFrameReader`
/// (the one view that reads frames inside a body), so the bubble still
/// tracks its cell pixel-for-pixel while the rest of the window stays idle.
/// The orb's drop hit-test reads happen in gesture handlers, outside any
/// body, and register no dependency at all.
@Observable
final class ThumbFrameStore {
    var frames: [UInt8: CGRect] = [:]
}

// Platinum button in Classic; in Regular the button is left native so the
// toolbar's own shared Liquid Glass renders it. (The window rebuilds on a theme
// switch, so the two configs never have to morph into each other.)
/// Toolbar backdrop: frosted glass in the regular themes. Classic kills the
/// backdrop outright — its toolbar row is hidden and the OS 9 title bar is
/// drawn in content, and any titlebar material would paint OVER that drawn
/// chrome (the titlebar container sits above the content view).
private struct ClassicToolbarBackground: ViewModifier {
    let classic: Bool
    func body(content: Content) -> some View {
        if classic {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.visible, for: .windowToolbar)
        }
    }
}

struct BubbleSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color
    let classic: Bool
    func body(content: Content) -> some View {
        if classic {
            content.classicBevel(cornerRadius: radius)
        } else {
            // `.clear` (not `.regular`) so the status backdrop is transparent
            // Liquid Glass — the frosted `.regular` variant read as a solid area.
            content.glassEffect(.clear.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

private struct ToastBackgroundModifier: ViewModifier {
    @Environment(\.isClassicTheme) private var classic
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if classic {
            content.classicBevel(cornerRadius: 6)
        } else if reduceTransparency {
            // Same corner radius as the glass/material path, an opaque
            // window-coloured fill instead of a see-through one.
            content
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(14)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThickMaterial)
                .cornerRadius(14)
        }
    }
}

struct SidebarButtonModifier: ViewModifier {
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            content.buttonStyle(ClassicButtonStyle())
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Wordmark that types itself in one character at a time, like Keynote's
/// "Typewriter" build-in. When `text` changes it backspaces the old value and
/// types the new one, with a caret that blinks while typing and retires once
/// the line is complete.
struct TypewriterText: View {
    let text: String

    @State private var displayed: String = ""
    @State private var isTyping: Bool = false
    @State private var caretVisible: Bool = false
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 1) {
            Text(displayed)
                .contentTransition(.identity)
            // Slim caret — only present mid-type, blinking for the Keynote feel.
            Rectangle()
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .opacity(isTyping && caretVisible ? 0.85 : 0)
                .padding(.vertical, 3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { run(to: text, animated: false) }
        .onChange(of: text) { _, newValue in run(to: newValue, animated: true) }
    }

    private func run(to target: String, animated: Bool) {
        animationTask?.cancel()

        // Reduce Motion: snap straight to the target text instead of the
        // backspace/retype build — the new caption still appears, it just
        // doesn't animate its way there.
        guard animated && !reduceMotion else {
            displayed = target
            isTyping = false
            return
        }

        animationTask = Task { @MainActor in
            isTyping = true
            startCaretBlink()

            // Backspace whatever's there, then type the new wordmark in.
            while !displayed.isEmpty {
                if Task.isCancelled { return }
                displayed.removeLast()
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            for character in target {
                if Task.isCancelled { return }
                displayed.append(character)
                try? await Task.sleep(nanoseconds: 55_000_000)
            }

            isTyping = false
        }
    }

    private func startCaretBlink() {
        Task { @MainActor in
            while isTyping {
                caretVisible.toggle()
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            caretVisible = false
        }
    }
}

// MARK: - Moof! (Cmd+P easter egg)

/// A comic speech-bubble outline: a rounded rect body with a small tail
/// pointing straight down toward whatever sits below it.
private struct SpeechBubble: Shape {
    var cornerRadius: CGFloat = 12
    var tailWidth: CGFloat = 20
    var tailHeight: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        // One continuous outline (body + tail) so there's no seam line where the
        // tail meets the bubble — the bottom edge simply detours out to the tip.
        let r = cornerRadius
        let bottom = rect.maxY - tailHeight     // bubble body's bottom edge
        let cx = rect.midX
        let halfTail = tailWidth / 2

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))                                   // top edge
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX, y: rect.minY))                             // top-right
        p.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))                                      // right edge
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bottom),
                       control: CGPoint(x: rect.maxX, y: bottom))                                // bottom-right
        p.addLine(to: CGPoint(x: cx + halfTail, y: bottom))                                      // toward tail
        p.addLine(to: CGPoint(x: cx, y: rect.maxY))                                              // down to tip
        p.addLine(to: CGPoint(x: cx - halfTail, y: bottom))                                      // back up
        p.addLine(to: CGPoint(x: rect.minX + r, y: bottom))                                      // bottom edge
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - r),
                       control: CGPoint(x: rect.minX, y: bottom))                                // bottom-left
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))                                   // left edge
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))                             // top-left
        p.closeSubpath()
        return p
    }
}

/// Clarus the Dogcow, centred on the canvas, saying "Moof!". New Clarus under
/// Liquid Glass, the original pixel Clarus in Classic. Tap or wait to dismiss.
private struct MoofOverlay: View {
    let classic: Bool
    let onDismiss: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 14) {
                // Nudge the bubble over Clarus's head (she faces left) so the
                // tail points at her, not at her back.
                speechBubble
                    .offset(x: -26)
                Image(classic ? "ClarusOld" : "ClarusNew")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(classic ? .none : .high)
                    .scaledToFit()
                    .frame(width: 130)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
            }
            .padding(28)
            .frame(width: 220)
            .themedPanel(cornerRadius: 22, classic: classic)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
            // Reduce Motion: no scale-in bounce — Clarus still shows up, by
            // a plain fade instead of springing to size.
            .scaleEffect(reduceMotion || appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .onTapGesture { onDismiss() }
        }
        .transition(.opacity)
        .task {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15)
                                        : .spring(response: 0.5, dampingFraction: 0.6)) {
                appeared = true
            }
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            onDismiss()
        }
    }

    private var speechBubble: some View {
        Text("Moof!")
            .font(classic ? .classic(20, weight: .bold) : .title2.weight(.bold))
            .foregroundStyle(classic ? AppTheme.platinumText : .primary)
            .padding(.top, 9)
            .padding(.bottom, 9 + 11)   // leave room for the tail inside the shape
            .padding(.horizontal, 20)
            .background { bubbleBackground }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if classic {
            SpeechBubble()
                .fill(AppTheme.platinumFace)
                .overlay(SpeechBubble().stroke(AppTheme.platinumFrame.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        } else if reduceTransparency {
            SpeechBubble().fill(Color(NSColor.windowBackgroundColor))
        } else {
            Color.clear.glassEffect(.regular, in: SpeechBubble())
        }
    }
}

// MARK: - Phantom .qtk photo (easter egg)

/// A phantom planet photo that takes over the whole window: it fizzles in behind
/// a dissolving rainbow-Apple field, fills the window (resizing with it), and on
/// click either flies into the aperture top-left (first time — "absorbed") or
/// drops away downward (if it's already been collected).
private struct PhantomPhotoView: View {
    let egg: QuickTakeSerialManager.PhantomEgg
    let alreadyAbsorbed: Bool
    let sidebarShown: Bool
    let sidebarWidth: CGFloat
    /// The aperture centre in global coords (reliable across the split view).
    let aperture: () -> CGPoint
    let openSidebar: () -> Void
    let onAbsorb: () -> Void
    let onComplete: () -> Void

    @State private var fizzleStart = Date()
    @State private var revealed = false
    @State private var dismissing = false
    @State private var absorbOffset: CGSize = .zero
    @State private var absorbScale: CGFloat = 1
    @State private var fallDown: CGFloat = 0
    @State private var contentOpacity: Double = 1

    // The phantom photos are 4:3 (640×480).
    private let aspect: CGFloat = 640.0 / 480.0
    // Leave the toolbar visible at the top.
    private let topInset: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            let originGlobal = geo.frame(in: .global).origin
            // The canvas region in this overlay's local space: right of the sidebar,
            // below the toolbar.
            let leftInset = sidebarShown ? sidebarWidth : 0
            let canvasX = leftInset
            let canvasW = max(0, geo.size.width - leftInset)
            let canvasH = max(0, geo.size.height - topInset)
            let availW = max(0, canvasW - 24)
            let availH = max(0, canvasH - 24)
            let w = min(availW, availH * aspect)
            let h = w / aspect
            let cx = canvasX + canvasW / 2
            let cy = topInset + canvasH / 2

            ZStack {
                Image(egg.asset)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)

                if !revealed {
                    RainbowFizzle(start: fizzleStart)
                        .frame(width: w, height: h)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .scaleEffect(absorbScale)
            .offset(absorbOffset)
            .offset(y: fallDown)
            .opacity(contentOpacity)
            .position(x: cx, y: cy)
            .contentShape(Rectangle())
            .onTapGesture { dismiss(photoCenter: CGPoint(x: cx, y: cy), originGlobal: originGlobal) }
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(nanoseconds: 950_000_000)
            revealed = true
        }
    }

    private func dismiss(photoCenter: CGPoint, originGlobal: CGPoint) {
        // Ignore taps during the fizzle build-in.
        guard !dismissing, revealed else { return }
        dismissing = true

        if alreadyAbsorbed {
            // Second viewing — fade downward out of the canvas.
            withAnimation(.easeIn(duration: 0.45)) {
                fallDown = 1000
                contentOpacity = 0
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                onComplete()
            }
        } else {
            // First time — open the sidebar (so the aperture is on-screen), let it
            // settle, then shrink and fly the photo straight INTO the aperture.
            if !sidebarShown { openSidebar() }
            Task { @MainActor in
                if !sidebarShown {
                    try? await Task.sleep(nanoseconds: 380_000_000)   // sidebar open + layout
                }
                // Aperture in this overlay's local space.
                let ap = aperture()
                let apLocal = CGPoint(x: ap.x - originGlobal.x, y: ap.y - originGlobal.y)
                onAbsorb()                                            // mark collected + glow
                withAnimation(.easeIn(duration: 0.6)) {
                    absorbOffset = CGSize(width: apLocal.x - photoCenter.x,
                                          height: apLocal.y - photoCenter.y)
                    absorbScale = 0.02
                    contentOpacity = 0
                }
                try? await Task.sleep(nanoseconds: 620_000_000)
                onComplete()
            }
        }
    }
}

/// A one-shot dissolve of 90s rainbow-Apple blocks that clears to reveal whatever
/// is beneath it — the "fizzle" build-in for phantom photos.
private struct RainbowFizzle: View {
    let start: Date

    private static let stripes: [Color] = [
        Color(red: 0.38, green: 0.70, blue: 0.27),   // green
        Color(red: 0.96, green: 0.78, blue: 0.16),   // yellow
        Color(red: 0.93, green: 0.53, blue: 0.18),   // orange
        Color(red: 0.79, green: 0.20, blue: 0.22),   // red
        Color(red: 0.50, green: 0.23, blue: 0.55),   // purple
        Color(red: 0.20, green: 0.45, blue: 0.73)    // blue
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let p = min(1, max(0, timeline.date.timeIntervalSince(start) / 1.2))
            Canvas { ctx, size in
                guard p < 1 else { return }
                let block: CGFloat = 7
                let cols = Int(ceil(size.width / block))
                let rows = Int(ceil(size.height / block))
                guard rows > 0 else { return }
                // Each cell fades out over a wide soft window as the sweep `p`
                // passes its random threshold — a gradual dissolve, not a hard flip.
                let window = 0.45
                for r in 0..<rows {
                    let stripe = Self.stripes[min(Self.stripes.count - 1,
                                                  r * Self.stripes.count / rows)]
                    for c in 0..<cols {
                        var s = UInt64((r &* 928_371 ^ c &* 1_234_577) & 0x7fff_ffff) &+ 99
                        s ^= s << 13; s ^= s >> 7; s ^= s << 17
                        let rnd = Double(s % 997) / 997.0
                        let alpha = max(0, min(1, (rnd - p) / window + 0.5))
                        if alpha > 0.02 {
                            ctx.fill(
                                Path(CGRect(x: CGFloat(c) * block, y: CGFloat(r) * block,
                                            width: block + 1, height: block + 1)),
                                with: .color(stripe.opacity(alpha)))
                        }
                    }
                }
            }
            // Heavy blur dissolves the cell grid into a soft cloud (not pixels).
            .blur(radius: 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // decorative phantom-photo build-in
    }
}
