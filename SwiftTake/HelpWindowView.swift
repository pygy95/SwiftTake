// MARK: - HelpWindowView
//
// Main help window opened via the menu bar (Help → SwiftTake Help) or the help
// button in `WelcomeView`. Organised as tabs: an Overview (identify your model
// + adapter advice) and a focused tab per camera family, each with its wiring
// diagram and connection/workflow guidance. Every section shares one header and
// card style so the page reads as a single coherent document.
//
// Lives in its own `Window` scene so users can keep it open beside the main
// gallery while learning their way around.

import SwiftUI
import AppKit

struct HelpWindowView: View {
    // Read the theme straight from storage rather than the injected
    // environment: this auxiliary `Window` scene doesn't reliably receive the
    // app-wide `isClassicTheme`, so a Classic session was still showing the
    // Liquid Glass help cards. Mirrors `effectiveTheme` in SwiftTakeApp.
    @AppStorage(PrefKey.appTheme) private var appThemeSetting = AppTheme.system
    @AppStorage(PrefKey.rainbowUnlocked) private var classicUnlocked = false
    private var isClassicTheme: Bool { appThemeSetting == .classic && classicUnlocked }
    @State private var selectedTab: HelpTab = .overview
    // Hidden Classic-only treat: click Overview 3× (not necessarily in a row,
    // just while the window is open) and the cow takes over; click again to
    // restore — then it's 3 more clicks to bring it back.
    @State private var overviewClicks = 0
    @State private var showCow = false
    // Newton easter egg — fired by clicking "Apple Newton" in the QuickTake
    // 100/150 tab; the eMate takes over the help window, types, then retracts.
    @State private var showNewton = false

    private enum HelpTab: String, CaseIterable, Identifiable, Hashable {
        case overview, qt100, qt200
        var id: Self { self }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .qt100:    "QuickTake 100 / 150"
            case .qt200:    "QuickTake 200"
            }
        }
        var icon: String {
            switch self {
            case .overview: "questionmark.circle"
            case .qt100:    "camera"
            case .qt200:    "camera.aperture"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Classic draws its own Platinum tabs in content (they count the
            // Overview re-taps for the cow egg, which a native control
            // cannot). Regular themes get the NATIVE segmented picker in the
            // window toolbar below — the real Liquid Glass control with its
            // full morph, exactly as a principal toolbar item renders it.
            if isClassicTheme {
                // Fixed height so the selection change can't nudge the bar
                // (and the content below) up or down by a point or two.
                helpTabBar
                    .frame(height: 60)
                Divider()
            }
            // No ScrollView, deliberately: every tab has to fit. It also
            // can't be here — a ScrollView has no intrinsic height, so it
            // takes whatever it's offered and the window can never size
            // itself to the content.
            Group {
                switch selectedTab {
                case .overview: if showCow { CowEasterEggView() } else { overviewTab }
                case .qt100:    quickTake100150Tab
                case .qt200:    quickTake200Tab
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            if !isClassicTheme {
                ToolbarItem(placement: .principal) {
                    Picker("Help Section", selection: $selectedTab) {
                        ForEach(HelpTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        // Width is derived from the margin and the text column, so it always
        // equals the padded block exactly — any slack would land on the sides
        // and break the match with the top and bottom.
        //
        // Height is deliberately NOT pinned: with `.windowResizability(
        // .contentSize)` the window then takes each tab's natural height, so
        // the bottom margin is the same 32pt as the other three on every tab.
        // Pinning it made the shorter tabs bottom-heavy. The old reason for
        // pinning — that a height change nudged the tab bar — no longer
        // applies: the segmented picker lives in the toolbar, and Classic
        // draws its tabs at the top of the content, so both are anchored
        // above anything that moves.
        //
        // Note for anyone changing this: `.frame(minHeight:maxHeight:)`
        // clamps layout but does NOT set the ideal size that
        // `.windowResizability(.contentSize)` reads, so the window kept
        // sizing to the old content height and looked like stale window
        // state. `.frame(width:height:)` does set it.
        .frame(width: Self.windowWidth)
        .background { helpBackdrop }
        // Newton easter egg takes over the help window, then retracts.
        .overlay {
            if showNewton {
                NewtonEggView { showNewton = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)   // visual easter egg over the help content
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showNewton)
    }

    /// Backdrop the cards sit on: the Platinum pinstripe in Classic, a soft
    /// top-to-bottom gradient otherwise so the Liquid Glass cards have depth to
    /// refract instead of floating on a flat fill.
    @ViewBuilder
    private var helpBackdrop: some View {
        if isClassicTheme {
            ClassicPinstripe().ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [Color(NSColor.underPageBackgroundColor),
                         Color(NSColor.windowBackgroundColor)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var helpTabBar: some View {
        // Classic only — Regular themes use the native segmented picker in
        // the window toolbar (see body). Custom Platinum tabs remain here so
        // the Overview-click cow easter egg can count taps: a native Picker
        // can't see a re-tap on the already-selected segment. Selection is a
        // quick MECHANICAL push (mirrors the Settings sidebar).
        HStack(spacing: 8) { ForEach(HelpTab.allCases, content: classicTab) }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .animation(.easeOut(duration: 0.07), value: selectedTab)
    }

    /// A Platinum tab for Classic — a REAL push button (ClassicPushSurface);
    /// the selected tab is the one held pressed-in (sunken face) with a
    /// whisper of the period accent. Taps route through `handleTabTap` so the
    /// cow easter egg can count Overview clicks.
    private func classicTab(_ tab: HelpTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            handleTabTap(tab)
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .font(.classic(13, weight: .bold))
                .foregroundStyle(selected ? AnyShapeStyle(AppTheme.platinumText) : AnyShapeStyle(.secondary))
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background {
                    ClassicPushSurface(pressed: selected)
                        .overlay {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(AppTheme.classicAccent.opacity(0.12))
                            }
                        }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func handleTabTap(_ tab: HelpTab) {
        guard tab == .overview else { selectedTab = tab; return }
        if showCow {
            showCow = false
            overviewClicks = 0
        } else if isClassicTheme {
            overviewClicks += 1
            if overviewClicks >= 3 { showCow = true }
        }
        selectedTab = .overview
    }

    // MARK: - Tabs

    private var overviewTab: some View {
        tabContainer {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("SwiftTake Help", systemImage: "questionmark.circle.fill")
                        .font(isClassicTheme ? .classic(22, weight: .bold) : .largeTitle.weight(.bold))
                    Text("Connecting and importing from vintage Apple QuickTake cameras — the 100, 150, and 200.")
                        .font(isClassicTheme ? .classic(14) : .title3)
                        .foregroundStyle(.secondary)
                }

                identifySection
                adapterSection
            }
        }
    }

    private var quickTake100150Tab: some View {
        tabContainer {
            VStack(alignment: .leading, spacing: 24) {
                tabHeader("QuickTake 100 & 150", subtitle: "Kodak-built · mini-DIN-8 serial cable")

                wiringCard(
                    connecting: "Connect the camera's mini-DIN-8 cable to your USB-to-serial adapter, power the camera on, then choose Connect. To build your own cable, follow the pinout below — the perspective is looking at the plug ends, so the DB9 is viewed from its female pins and the DIN8 from its male pins.",
                    image: "QTWiring",
                    accessibility: "QuickTake 100 / 150 wiring guide: a Mac mini-DIN-8 serial cable to a DB9 female serial port, with the pin-to-pin table.",
                    // Hidden hotspot over the "Apple Newton" words in the note.
                    secretHotspot: { showNewton = true }
                )
            }
        }
    }

    private var quickTake200Tab: some View {
        tabContainer {
            VStack(alignment: .leading, spacing: 24) {
                tabHeader("QuickTake 200", subtitle: "Fujifilm DS-7 · 2.5 mm stereo miniplug cable")

                wiringCard(
                    connecting: "The 200 uses a 2.5 mm stereo (TRS) plug, not the mini-DIN-8. Wire each conductor to its signal as shown, or use the original cable, then add a USB-to-serial adapter. Power on and choose Connect — SwiftTake picks the fastest reliable speed.",
                    image: "QT200Wiring",
                    accessibility: "QuickTake 200 wiring: a DB9 female serial port to the 2.5 millimetre jack — Tip is RXD, Ring is TXD, Sleeve is ground."
                )
            }
        }
    }

    // MARK: - Identify your camera

    private var identifySection: some View {
        helpSection("Which QuickTake?") {
            HStack(alignment: .top, spacing: 16) {
                modelCard(
                    title: "QuickTake 100 / 150",
                    image: "QuickTake150Photo",
                    points: [
                        "Built by Kodak for Apple",
                        "Rounded “binocular” body",
                        "Mini-DIN-8 serial cable",
                        "Stores photos in built-in memory"
                    ]
                )
                modelCard(
                    title: "QuickTake 200",
                    image: "QuickTake200Photo",
                    points: [
                        "A rebadged Fujifilm DS-7",
                        "Flat, boxy body with an LCD",
                        "2.5 mm stereo miniplug cable",
                        "Stores photos on a SmartMedia card"
                    ]
                )
            }
        }
    }

    private func modelCard(title: String,
                           image: String,
                           points: [String]) -> some View {
        // The camera centres against the WHOLE text column — title and specs
        // together — not just the specs. Nested inside the spec row it sat
        // below the card's true middle, because the title above it wasn't
        // part of what it was centring against.
        //
        // Equal spacers either side float it in the gap the text leaves, so
        // it lands in the middle of the space you can actually see.
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    // A step up from .headline: these name the two things the
                    // section is about, so they sit between the body text and
                    // the .title2 section heading.
                    .font(isClassicTheme ? .classic(15, weight: .bold) : .title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Lifted off the baseline to the text's optical
                            // centre. A dot aligned to .firstTextBaseline sits
                            // ON the baseline, which reads as sitting low
                            // against the line it belongs to.
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.secondary)
                                .alignmentGuide(.firstTextBaseline) { d in
                                    d[VerticalAlignment.center] + 4
                                }
                            Text(point)
                                .font(isClassicTheme ? .classic(12) : .subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Both photos are exported to the same 88x54 tile, so neither
            // camera looks arbitrarily bigger than the other.
            //
            // They were photographed on white, so they're shown back on a
            // light tile rather than cut out onto the card: the flood-fill
            // edge and any residual matte stop mattering once the background
            // they came from is under them again, and against a dark card the
            // tile makes them read as product shots. The tile is baked square
            // — the corner treatment belongs to the theme, since Classic's
            // OS 9 chrome doesn't do rounded.
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 6,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: isClassicTheme ? 0 : 6,
                                     style: .continuous)
                        // Hairline, and it earns its keep in light mode: the
                        // tile is near the card colour there, so the border is
                        // the only thing defining the edge.
                        .strokeBorder(isClassicTheme
                                      ? AppTheme.platinumShadow.opacity(0.9)
                                      : Color.primary.opacity(0.14),
                                      lineWidth: isClassicTheme ? 1 : 0.5)
                )
                .accessibilityHidden(true)   // the title already names it

            Spacer(minLength: 0)
        }
        // NO Spacer in here. `tabContainer` proposes the whole window height,
        // so anything vertically flexible inside a card inflates it.
        .frame(maxWidth: .infinity)
        .modifier(HelpCard(classic: isClassicTheme))
    }

    // MARK: - Adapter

    private var adapterSection: some View {
        helpSection("Adapter", subtitle: "Every QuickTake reaches a modern Mac through a USB-to-serial adapter — the chipset matters.") {
            VStack(alignment: .leading, spacing: 0) {
                adapterRow(
                    icon: "checkmark.seal.fill",
                    color: .green,
                    title: "Prolific (PL2303) — recommended",
                    detail: "Works reliably. Needs the free PL2303 Serial driver app for macOS.",
                    linkURL: "https://apps.apple.com/au/app/pl2303-serial/id1624835354?mt=12",
                    linkText: "Get PL2303 Serial"
                )
                Divider().padding(.vertical, 14)
                adapterRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .yellow,
                    title: "FTDI (FT233RL) — usually fine",
                    detail: "Genuine FTDI adapters work well, but “generic” clones often don't."
                )
                Divider().padding(.vertical, 14)
                adapterRow(
                    icon: "xmark.octagon.fill",
                    color: .red,
                    title: "CH340 — avoid",
                    detail: "CH340-based cables are unreliable here. Steer clear."
                )
            }
            .modifier(HelpCard(classic: isClassicTheme))
        }
    }

    private func adapterRow(icon: String, color: Color, title: String, detail: String, linkURL: String? = nil, linkText: String? = nil) -> some View {
        // Icon and button centre on the WHOLE text block — title and detail
        // together — so the icon sits between the two lines rather than level
        // with the first one. This also survives the detail text wrapping:
        // the block gets taller, the icon stays in its middle.
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)
                Text(detail)
                    .font(isClassicTheme ? .classic(12) : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The download button sits at the trailing edge rather than under
            // the text: it's the row's one action, and hanging it off the
            // right keeps the three adapter rows reading as a single scannable
            // column of names rather than one row that's twice as tall.
            Spacer(minLength: 12)

            Group {
                if let linkURL, let linkText, let url = URL(string: linkURL) {
                    Link(destination: url) {
                        if isClassicTheme {
                            // Platinum push button — no modern blue pill in Classic.
                            Label(linkText, systemImage: "arrow.down.app.fill")
                                .font(.classic(11, weight: .semibold))
                                .foregroundStyle(AppTheme.platinumText)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 12)
                                .classicBevel(cornerRadius: 5)
                        } else {
                            Label(linkText, systemImage: "arrow.down.app.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96, pressedOpacity: 0.9, shadowRadius: 2))

                }
            }
            .layoutPriority(1)          // never let the detail text squeeze it
        }
    }

    // MARK: - Shared building blocks

    /// A tab's content, centred in a fixed-width reading column and pinned to
    /// the top. No scroll view — the window is sized to fit every tab.
    /// The margin on all four sides of every tab, and the text column it
    /// wraps. The window width is derived from them, so the whole window's
    /// negative space is these two numbers — change `Self.margin` and the
    /// sides, top and bottom all move together.
    ///
    /// 32 looked thin at the sides even though it matched the top: above the
    /// content sits the 52pt toolbar as well as the margin, so the eye reads
    /// ~84pt of air up there against 32 at the edges.
    static let margin: CGFloat = 48
    /// Slightly less at the top, on purpose. The toolbar sits above the
    /// content and contributes its own band of air, so an equal 48 there
    /// reads as more space than the sides and bottom have. This is the
    /// optical match, not the arithmetic one.
    static let topMargin: CGFloat = 32
    /// Sized so the toolbar's segmented picker lands dead centre.
    ///
    /// The picker does not centre itself: measured at two window widths its
    /// left edge sat 252pt from the window's left both times (offset from
    /// centre +109 at 720 wide, +69 at 800), so it's placed after a fixed
    /// leading reserve rather than balanced. It is 434pt across, so it is
    /// centred exactly when the window is 2*252 + 434 = 938 — which this
    /// column plus the two 48pt margins produces.
    ///
    /// Change `margin` and this needs recomputing, or the picker drifts off
    /// centre again by half the difference.
    static let textColumn: CGFloat = 842

    /// Longest a run of body text is allowed to get. Cards and diagrams use
    /// the full column, but a paragraph set across all 842pt is a hard read —
    /// Apple keeps prose near 60-75 characters. Applied to the tab subtitles
    /// and section blurbs, which are the only free-running text here.
    static let proseWidth: CGFloat = 620

    static var windowWidth: CGFloat { textColumn + margin * 2 }

    private func tabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.top, Self.topMargin)
            .padding([.leading, .trailing, .bottom], Self.margin)
            .frame(maxWidth: Self.windowWidth, alignment: .leading)
        // Deliberately NOT `.frame(maxHeight: .infinity, alignment: .top)`.
        // That made the container greedy vertically and pinned the content to
        // the top, so every point of slack in the window piled up at the
        // bottom and the bottom gap stopped matching the sides. It was there
        // for when the window height was pinned; the height follows the
        // content now, so the container hugs it and the only space below is
        // the margin.
    }

    /// Large header for a camera tab.
    private func tabHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(isClassicTheme ? .classic(22, weight: .bold) : .largeTitle.weight(.bold))
            Text(subtitle)
                .font(isClassicTheme ? .classic(14) : .title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.proseWidth, alignment: .leading)
        }
    }

    /// A "Connecting" card: guidance above a centred, full-width wiring diagram
    /// on a white figure card (so the line art reads in light and dark).
    private func wiringCard(connecting: String, image: String, accessibility: String,
                            secretHotspot: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wiring Diagram")
                .font(isClassicTheme ? .classic(14, weight: .bold) : .headline)
            Text(connecting)
                .font(isClassicTheme ? .classic(12) : .subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.proseWidth, alignment: .leading)

            Image(image)
                .resizable()
                .scaledToFit()
                // NOT capped. A height cap shrinks the whole diagram, and
                // these are technical drawings — the pin numbers and the
                // wiring table have to stay readable, which matters more than
                // the window being short. It cost nothing to remove: the
                // window's height follows its content now, so the tab just
                // gets taller.
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Invisible hotspot over the "Apple Newton" words in the
                // diagram's note.
                //
                // WARNING: this is positioned as FRACTIONS of the displayed
                // image, so it slides off its target whenever the artwork is
                // re-framed — silently, with nothing failing to build. It has
                // already had to be recomputed twice: once when QTWiring lost
                // its baked-in title, and again when its margins were
                // balanced. Against the current 1448x952 art the Newton note
                // sits at y 0.6987, height 0.0627. Re-derive from the ORIGINAL
                // 1448x1086 file (y 0.700, height 0.055) if it ever moves
                // again, and check by drawing the box onto the artwork.
                .overlay {
                    if let secretHotspot {
                        GeometryReader { geo in
                            Button(action: secretHotspot) {
                                Color.clear.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: geo.size.width * 0.24, height: geo.size.height * 0.0627)
                            .position(x: geo.size.width * 0.27, y: geo.size.height * 0.6987)
                        }
                    }
                }
                .accessibilityLabel(accessibility)
        }
        .modifier(HelpCard(classic: isClassicTheme))
    }

    /// A section: a title (with optional subtitle) above its content, sharing
    /// the spacing every section uses so the page reads consistently.
    private func helpSection<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(isClassicTheme ? .classic(17, weight: .bold) : .title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(isClassicTheme ? .classic(12) : .subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.proseWidth, alignment: .leading)
                }
            }
            content()
        }
    }

}

/// An animated GIF, played via AppKit's `NSImageView` (SwiftUI's `Image` only
/// shows the first frame).
private struct AnimatedGIFView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(data: data)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

/// The cow easter egg — fills the Help window with the looping GIF.
private struct CowEasterEggView: View {
    var body: some View {
        ZStack {
            Color.black
            if let asset = NSDataAsset(name: "CowWithHair") {
                AnimatedGIFView(data: asset.data)
                    .padding(10)
            } else {
                Text("🐮").font(.system(size: 96))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The one card treatment every Help section shares — material fill, rounded
/// corners, consistent padding.
private struct HelpCard: ViewModifier {
    let classic: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if classic {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .classicBevel(cornerRadius: 6)
        } else if reduceTransparency {
            // Same shape as the glass card, an opaque window-coloured fill.
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor)))
        } else {
            // Keep it simple: the plain native Liquid Glass card.
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
