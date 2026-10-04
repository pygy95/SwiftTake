// MARK: - AppTheme
//
// User-selectable colour scheme for the app: System (follow macOS), Light,
// Dark — and the hidden "Classic" Mac OS Platinum reskin, unlocked by the
// status-bubble colour-collection easter egg. Stored in `@AppStorage("appTheme")`
// and applied via `.appTheme(...)` in `SwiftTakeApp`.
//
// `colorScheme` returns `ColorScheme?` so SwiftUI can pass `nil` for the System
// case — "let the OS decide" matches macOS's Appearance setting.

import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case classic = "Classic"

    var id: String { self.rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light, .classic:
            return .light
        case .dark:
            return .dark
        }
    }

    /// The Platinum reskin (unlocked easter egg).
    var isClassic: Bool { self == .classic }

    /// Period accent (muted Platinum blue) for Classic; nil = system accent.
    var accent: Color? { isClassic ? AppTheme.classicAccent : nil }

    // Classic Mac OS Platinum palette.
    static let classicAccent = Color(red: 0.22, green: 0.34, blue: 0.60)
    static let platinum = Color(red: 0.866, green: 0.866, blue: 0.866)
    static let platinumFace = Color(red: 0.866, green: 0.866, blue: 0.866)
    static let platinumLight = Color.white
    static let platinumShadow = Color(red: 0.50, green: 0.50, blue: 0.50)
    static let platinumFrame = Color(red: 0.30, green: 0.30, blue: 0.30)
    static let platinumHighlight = Color(red: 0.20, green: 0.30, blue: 0.55) // selection

    /// The 90s Apple stripes as a horizontal bar fill — the import bar, the
    /// thumbnail-loading bar and the panorama stitch bar. Lives here rather
    /// than beside any one of them: every wait in the app wears the same
    /// bar, and three copies of six stops is three chances to drift.
    static let apple90sStripes = LinearGradient(
        stops: [
            .init(color: Color(red: 0.38, green: 0.73, blue: 0.28), location: 0.0), // Green
            .init(color: Color(red: 0.96, green: 0.76, blue: 0.17), location: 0.2), // Yellow
            .init(color: Color(red: 0.94, green: 0.52, blue: 0.16), location: 0.4), // Orange
            .init(color: Color(red: 0.88, green: 0.21, blue: 0.26), location: 0.6), // Red
            .init(color: Color(red: 0.58, green: 0.24, blue: 0.59), location: 0.8), // Purple
            .init(color: Color(red: 0.00, green: 0.58, blue: 0.84), location: 1.0)  // Blue
        ],
        startPoint: .leading, endPoint: .trailing)
}

// MARK: - Classic Platinum style kit

extension Font {
    /// The classic Mac system font. The bundled Charcoal face — registered at
    /// launch in `SwiftTakeApp.init` — makes it pixel-authentic; the bold
    /// system fallback only fires if font registration ever fails.
    static func classic(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        for name in ["Charcoal", "ChiKareGo2", "ChicagoFLF", "Charcoal CY", "Geneva", "Chicago"] {
            if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        }
        return .system(size: size, weight: weight == .regular ? .semibold : weight)
    }
}

/// A raised (or sunken) Platinum bevel — the building block of every classic
/// panel, well, and button. Light edge top-left, shadow bottom-right, thin dark
/// frame around the whole thing.
struct ClassicBevel: ViewModifier {
    var sunken: Bool = false
    var cornerRadius: CGFloat = 4

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // The whole bevel — fill AND strokes — lives in the background,
            // under the content. Identical for content that fits (nothing
            // sits on the border region), and overlays that extend past the
            // bevel (Balloon Help on controls inside bubbles) are neither
            // clipped by a clipShape nor crossed by the border strokes.
            .background(
                ZStack {
                    shape.fill(AppTheme.platinumFace)
                    shape.inset(by: 0.6).stroke(
                        LinearGradient(
                            colors: sunken
                                ? [AppTheme.platinumShadow, AppTheme.platinumLight]
                                : [AppTheme.platinumLight, AppTheme.platinumShadow],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.4)
                    shape.stroke(AppTheme.platinumFrame.opacity(0.6), lineWidth: 1)
                }
            )
    }
}

extension View {
    func classicBevel(sunken: Bool = false, cornerRadius: CGFloat = 4) -> some View {
        modifier(ClassicBevel(sunken: sunken, cornerRadius: cornerRadius))
    }
}

/// The Platinum push-button SURFACE — authentic OS 9 anatomy: a pill
/// (rounded-end) shape, a subtly domed face (light at the top settling darker
/// toward the bottom), a 3D bevel (light top-left / shadow bottom-right,
/// inverting when pressed), all inside a thin dark frame. `prominent` floats
/// the heavy black default-button ring just outside the frame, period-style.
/// Also serves the Help window's Classic tabs, where `pressed` doubles as
/// "selected" — the active tab is the button held down.
struct ClassicPushSurface: View {
    var pressed: Bool = false
    var prominent: Bool = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                colors: pressed
                    ? [Color(white: 0.60), Color(white: 0.73)]
                    : [Color(white: 0.96), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom))
            shape.inset(by: 1).stroke(
                LinearGradient(
                    colors: pressed
                        ? [AppTheme.platinumShadow, AppTheme.platinumLight]
                        : [AppTheme.platinumLight, AppTheme.platinumShadow],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.6)
            shape.stroke(AppTheme.platinumFrame.opacity(0.85), lineWidth: 1)
        }
        .overlay {
            if prominent {
                shape.inset(by: -3).stroke(Color.black.opacity(0.85), lineWidth: 2)
            }
        }
    }
}

/// Classic push button — an authentic Platinum pill (see ClassicPushSurface):
/// domed face that darkens and a bevel that inverts on press. `prominent`
/// adds the heavy black ring of a default button. A flat rounded-rect
/// bevel reads modern rather than period — the domed face sells the look.
struct ClassicButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.classic(13, weight: .semibold))
            .foregroundStyle(AppTheme.platinumText)
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .background(ClassicPushSurface(pressed: configuration.isPressed,
                                           prominent: prominent))
            .contentShape(Capsule())
    }
}

extension AppTheme {
    static let platinumText = Color.black
}

/// Draws Classic chrome around the native button's existing keyboard focus.
private struct ClassicFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    var cornerRadius: CGFloat = 6
    func body(content: Content) -> some View {
        // Observe native focus; an extra focusable wrapper would intercept activation.
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
    }
}

private extension View {
    func classicFocusRing(cornerRadius: CGFloat = 6) -> some View {
        modifier(ClassicFocusRing(cornerRadius: cornerRadius))
    }
}

/// An OS 9 Platinum popup button (Classic-only). Native `.menu` pickers draw
/// system NSMenu chrome that can't be reskinned, so Classic swaps them for
/// this: a push button showing the current value with the period double-arrow
/// glyph (held pressed while open), opening a Platinum popover list — the
/// same pattern as the main window's import dropdown. Rows highlight in the
/// period selection blue on hover; the current value carries a checkmark.
struct ClassicPopUpButton<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    @State private var open = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.classic(12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(AppTheme.platinumText)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(ClassicPushSurface(pressed: open))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .classicFocusRing(cornerRadius: 13)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    ClassicMenuRow(label: option.label,
                                   selected: option.value == selection) {
                        selection = option.value
                        open = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 160, alignment: .leading)
            // Platinum interior; the popover's outer chrome stays system —
            // exactly how the import dropdown does it.
            .background(AppTheme.platinumFace)
            // Squarer bubble: Platinum menus were sharp-cornered, so rein in
            // the system popover's big radius. A small radius (not 0) keeps
            // the anchor arrow's blend from looking broken; 6 still read
            // too soft. This view only exists in Classic, so no theme
            // conditional is needed.
            .presentationCornerRadius(4)
        }
    }
}

/// OS 9 checkbox — a sunken white well with a bold black check. Platinum had
/// no switches: every Toggle wears this in Classic. Renders the label (in
/// Charcoal) when the Toggle has one.
struct ClassicCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color.white)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(
                            LinearGradient(
                                colors: [AppTheme.platinumShadow, AppTheme.platinumLight],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(AppTheme.platinumFrame.opacity(0.8), lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 15, height: 15)
                configuration.label
                    .font(.classic(12))
                    .foregroundStyle(AppTheme.platinumText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .classicFocusRing(cornerRadius: 3)
    }
}

/// Modern switch normally; OS 9 checkbox in Classic (Platinum had no
/// switches). For Toggles that are a native checkbox in the modern theme,
/// use `ThemedCheckboxToggle` instead.
struct ThemedSwitchToggle: ViewModifier {
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            content.toggleStyle(ClassicCheckboxStyle())
        } else {
            content.toggleStyle(.switch)
        }
    }
}

/// Native macOS checkbox normally; the OS 9 checkbox in Classic.
struct ThemedCheckboxToggle: ViewModifier {
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            content.toggleStyle(ClassicCheckboxStyle())
        } else {
            content.toggleStyle(.checkbox)
        }
    }
}

/// One row of a Classic popup menu — period selection blue on hover (white
/// text, like real OS 9 menus), checkmark on the current value.
private struct ClassicMenuRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(selected ? 1 : 0)
                Text(label)
                    .font(.classic(12))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .foregroundStyle(hovered ? Color.white : AppTheme.platinumText)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            // Soft-cornered highlight: a hard edge-to-edge bar is what real
            // OS 9 menus drew, but inside this ROUNDED popover bubble it
            // reads as an abrasive slab. Same flat period blue —
            // Platinum menu selection had no gradient — just rounded like
            // the modern menu highlight so it sits with the bubble's chrome.
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovered ? AppTheme.platinumHighlight : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The one shared "prominent action" button treatment: Classic Platinum
/// default button (black ring) when the Classic theme is active, Liquid Glass
/// prominent on macOS 26+, bordered-prominent otherwise. Replaces four
/// identical per-file copies (ContentView / CameraSelection / Diagnostics /
/// ConnectionHelp). Toolbar buttons and Settings keep their own treatments.
struct PrimaryButtonModifier: ViewModifier {
    /// Classic-only: square OS 9 bevel corners instead of the pill. The other
    /// themes render identically either way.
    var square: Bool = false
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            if square {
                content.buttonStyle(ClassicSquareButtonStyle(prominent: true, contentPadding: true))
            } else {
                content.buttonStyle(ClassicButtonStyle(prominent: true))
            }
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Shared secondary (Cancel/Close) treatment: Classic Platinum push button,
/// otherwise the standard bordered style.
struct SecondaryButtonModifier: ViewModifier {
    @Environment(\.isClassicTheme) private var classic
    func body(content: Content) -> some View {
        if classic {
            content.buttonStyle(ClassicButtonStyle())
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Make Classic the DEFAULT button style app-wide (macOS 26's default is
    /// Liquid Glass, so any unstyled Button would otherwise stay glassy).
    /// Explicit styles (`.plain`, `.bordered`, the prominent modifiers) still
    /// override this, so only the otherwise-default buttons are caught.
    @ViewBuilder
    func classicButtonStyling(_ active: Bool) -> some View {
        if active {
            self
                .buttonStyle(ClassicButtonStyle())
                // Default font for unstyled Text and system controls (Toggle /
                // Picker / menu labels). Explicitly-styled text overrides this,
                // so those sites are converted individually too.
                .environment(\.font, .classic(13))
        } else {
            self
        }
    }
}


// MARK: - Auxiliary-window theme bridge

/// Theme applier for auxiliary scenes (Settings and every secondary `Window`).
///
/// Those scenes don't reliably receive the environment injected on their root
/// views from `SwiftTakeApp`: the Help window shipped showing Liquid Glass
/// cards in a Classic session before it learned to read storage directly, and
/// ContentView's popovers re-inject the flag manually for the same reason.
/// Rather than each window carrying its own copy of that workaround, this
/// modifier holds the `@AppStorage` keys ITSELF — a modifier's body
/// re-evaluates whenever the storage changes, regardless of how the scene
/// treats values injected from the App — and re-applies the full theme
/// treatment locally. Mirrors `effectiveTheme` in SwiftTakeApp, including
/// the classic-unlock gate.
struct WindowThemeBridge: ViewModifier {
    @AppStorage(PrefKey.appTheme) private var appTheme = AppTheme.system
    @AppStorage(PrefKey.rainbowUnlocked) private var classicUnlocked = false

    private var effectiveTheme: AppTheme {
        (appTheme == .classic && !classicUnlocked) ? .system : appTheme
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(effectiveTheme.colorScheme)
            .tint(effectiveTheme.accent)
            .environment(\.isClassicTheme, effectiveTheme.isClassic)
            .classicButtonStyling(effectiveTheme.isClassic)
            .animation(.easeInOut(duration: 0.25), value: effectiveTheme)
            // OS 9 window chrome for every auxiliary window in Classic —
            // same treatment as the main window (hidden native title bar,
            // drawn Platinum bar), minus the main window's layout management
            // (fullSize: false: no full-size content view, no sidebar pin).
            // These windows live across theme flips, so the configurator
            // swaps chrome in place rather than being rebuilt.
            .background(WindowConfigurator(classic: effectiveTheme.isClassic, fullSize: false))
            // Dock-icon insurance: fires from EVERY themed window, so the
            // swap happens even when the theme is changed from Settings with
            // the main window closed. Idempotent with the main window's hook.
            .onChange(of: effectiveTheme.isClassic) { _, classic in
                AppTheme.applyDockIcon(classic: classic)
            }
    }
}

extension AppTheme {
    /// The Classic theme's transparent pixel-art icon composited onto a white tile with a
    /// hairline frame, so the Classic icon reads as a proper app tile in the
    /// Dock and About instead of floating pixels. The tile sits on the modern
    /// macOS icon grid (824×824 squircle centered in the 1024 canvas, corner
    /// radius ≈185) — the exact footprint of the bundle AppIcon, so swapping
    /// themes doesn't change the icon's apparent size. Drawing-handler
    /// NSImage: the squircle re-renders vector-crisp at every backing scale.
    @MainActor private static let classicTileIcon: NSImage? = {
        guard let art = NSImage(named: "ClassicAppIcon") else { return nil }
        let canvas = NSSize(width: 1024, height: 1024)
        return NSImage(size: canvas, flipped: false) { _ in
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
            NSColor.white.setFill()
            squircle.fill()

            // Draw the art 1:1 on its own canvas: the asset's framing is
            // exact and DELIBERATE — the hand's cut edge lands on the tile's
            // right boundary (ink to x≈923 of the 100…924 tile; measured),
            // so it kisses the frame and reads as cropped by it. A bbox-fit
            // with margins floated that cut edge inside the tile and made
            // the hand look amputated. Clipping to the squircle is
            // pure insurance for a future art swap that DOES overflow.
            NSGraphicsContext.current?.saveGraphicsState()
            squircle.addClip()
            art.draw(in: NSRect(origin: .zero, size: canvas))
            NSGraphicsContext.current?.restoreGraphicsState()

            // Hairline near-black frame (Platinum window chrome, not pure
            // black), fully inside the tile edge and drawn LAST so the line
            // crosses OVER the hand at the kiss edge — it's the crop line,
            // and must never be interrupted. 8px at 1024 ≈ 1–2px at the
            // sizes the Dock actually renders.
            let frameWidth: CGFloat = 8
            let framed = tile.insetBy(dx: frameWidth / 2, dy: frameWidth / 2)
            let framePath = NSBezierPath(
                roundedRect: framed,
                xRadius: 185 - frameWidth / 2, yRadius: 185 - frameWidth / 2)
            framePath.lineWidth = frameWidth
            NSColor(white: 0.15, alpha: 1).setStroke()
            framePath.stroke()
            return true
        }
    }()

    /// Swap the Dock icon for the theme: the Classic pixel-art icon on its white
    /// tile in Classic, nil restores the bundle icon. Runtime-only,
    /// idempotent — called from the main window's hooks and every
    /// WindowThemeBridge.
    @MainActor static func applyDockIcon(classic: Bool) {
        NSApplication.shared.applicationIconImage = classic ? classicTileIcon : nil
    }

    /// The app icon for the ACTIVE THEME, computed deterministically —
    /// in-app icon views (About, Welcome, camera chooser, diagnostics) must
    /// use this instead of reading `NSApp.applicationIconImage`: that live
    /// value is updated by an onChange hook on ITS OWN schedule, so a window
    /// re-rendering on a theme flip could win the race and draw the stale
    /// icon with nothing to trigger a redraw (About could keep showing the
    /// modern icon after switching to Classic).
    @MainActor static func appIcon(classic: Bool) -> NSImage {
        if classic, let tile = classicTileIcon {
            return tile
        }
        return NSImage(named: "AppIcon")
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}

extension View {
    /// Apply to the root view of every auxiliary scene — see `WindowThemeBridge`.
    func windowAppTheme() -> some View { modifier(WindowThemeBridge()) }
}

// MARK: - Classic styling hook

/// Environment flag so views can opt into Classic Platinum styling
/// progressively, without threading the theme through every initialiser.
private struct ClassicThemeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isClassicTheme: Bool {
        get { self[ClassicThemeKey.self] }
        set { self[ClassicThemeKey.self] = newValue }
    }
}

/// The iconic Mac OS Platinum pinstripe — flat grey ruled with faint white
/// hairlines every few points.
struct ClassicPinstripe: View {
    var body: some View {
        AppTheme.platinum.overlay(
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.white.opacity(0.55))
                    )
                    y += 4
                }
            }
            .allowsHitTesting(false)
        )
    }
}

/// A solid OS 9 disclosure triangle — points right when collapsed, rotates to
/// point down when expanded. The Classic stand-in for the SF chevron caret.
struct ClassicDisclosureTriangle: View {
    var expanded: Bool
    var body: some View {
        _RightTriangle()
            .fill(AppTheme.platinumText)
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.2), value: expanded)
    }
}

private struct _RightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Squared Platinum push surface — same anatomy as `ClassicPushSurface` (domed
/// face, 3D bevel inverting when pressed, thin dark frame) but with square
/// OS 9 button corners instead of the pill. Worn by list-style button rows
/// (the Settings sidebar) and square action buttons.
struct ClassicSquareSurface: View {
    var pressed: Bool = false
    var prominent: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                colors: pressed
                    ? [Color(white: 0.60), Color(white: 0.73)]
                    : [Color(white: 0.96), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom))
            shape.inset(by: 1).stroke(
                LinearGradient(
                    colors: pressed
                        ? [AppTheme.platinumShadow, AppTheme.platinumLight]
                        : [AppTheme.platinumLight, AppTheme.platinumShadow],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.6)
            shape.stroke(AppTheme.platinumFrame.opacity(0.85), lineWidth: 1)
        }
        .overlay {
            if prominent {
                shape.inset(by: -3).stroke(Color.black.opacity(0.85), lineWidth: 2)
            }
        }
    }
}

/// Square-cornered sibling of `ClassicButtonStyle` for buttons that should
/// read as OS 9 bevel buttons rather than pills (e.g. the shutter and Connect
/// buttons). `contentPadding: false` for labels that bring their own padding.
struct ClassicSquareButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var contentPadding: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.classic(13, weight: .semibold))
            .foregroundStyle(AppTheme.platinumText)
            .padding(.vertical, contentPadding ? 5 : 0)
            .padding(.horizontal, contentPadding ? 16 : 0)
            .background(ClassicSquareSurface(pressed: configuration.isPressed,
                                             prominent: prominent))
            .contentShape(Rectangle())
    }
}

/// An OS 9 status lamp: a recessed Platinum ring holding a flat, top-lit
/// coloured LED with a small glint — the period stand-in for the modern
/// glassy status dot. Purely indicative; the colour carries the state.
struct ClassicStatusLamp: View {
    var color: Color
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            // Recessed well: sunken bevel ring around the lamp.
            Circle().fill(Color(white: 0.60))
            Circle().stroke(
                LinearGradient(colors: [AppTheme.platinumShadow, Color.white.opacity(0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: max(1, size * 0.10))
            // The LED itself — flat colour, lightened toward the top.
            Circle()
                .fill(color)
                .overlay(
                    Circle().fill(LinearGradient(
                        colors: [Color.white.opacity(0.5), .clear],
                        startPoint: .top, endPoint: .center))
                )
                .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.8))
                .padding(size * 0.16)
            // Glint, upper-left.
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: -size * 0.16, y: -size * 0.18)
        }
        .frame(width: size, height: size)
    }
}

/// The OS 9 indeterminate progress bar — animated diagonal "barber pole"
/// stripes in a sunken white well. Worn by the Classic Connecting HUD (and
/// any other wait-with-no-progress moment).
struct ClassicBarberPole: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let period: CGFloat = 14
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t * 22).truncatingRemainder(dividingBy: period)
                var x: CGFloat = -size.height - period
                while x < size.width + period {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x + phase, y: size.height))
                    stripe.addLine(to: CGPoint(x: x + phase + size.height, y: 0))
                    stripe.addLine(to: CGPoint(x: x + phase + size.height + period / 2, y: 0))
                    stripe.addLine(to: CGPoint(x: x + phase + period / 2, y: size.height))
                    stripe.closeSubpath()
                    ctx.fill(stripe, with: .linearGradient(
                        Gradient(colors: [Color(red: 0.42, green: 0.56, blue: 0.86),
                                          Color(red: 0.20, green: 0.33, blue: 0.64)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    x += period
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(AppTheme.platinumShadow.opacity(0.7), lineWidth: 1))
    }
}

// MARK: - Classic busy cursor (OS 9 wristwatch)

extension AppTheme {
    /// The OS 9 "busy" wristwatch cursor, drawn in code so no bitmap asset is
    /// needed. Shown app-wide while the Classic theme is active and the app is
    /// working (connecting / importing / refreshing / loading thumbnails) —
    /// the period stand-in for the modern spinner.
    @MainActor static let classicWatchCursor: NSCursor = {
        let s: CGFloat = 22
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let cx = s / 2, cy = s / 2
            let faceR: CGFloat = 6.5

            // Band nubs top + bottom (black).
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: cx - 2.5, y: cy + faceR - 1, width: 5, height: 4)).fill()
            NSBezierPath(rect: NSRect(x: cx - 2.5, y: cy - faceR - 3, width: 5, height: 4)).fill()

            // Face: white fill, thick black rim.
            let face = NSBezierPath(ovalIn: NSRect(x: cx - faceR, y: cy - faceR,
                                                   width: faceR * 2, height: faceR * 2))
            NSColor.white.setFill(); face.fill()
            NSColor.black.setStroke(); face.lineWidth = 1.6; face.stroke()

            // Hands: minute straight up, hour toward ~4 o'clock.
            let minute = NSBezierPath()
            minute.lineWidth = 1.4
            minute.move(to: NSPoint(x: cx, y: cy)); minute.line(to: NSPoint(x: cx, y: cy + faceR - 2))
            minute.stroke()
            let hour = NSBezierPath()
            hour.lineWidth = 1.4
            hour.move(to: NSPoint(x: cx, y: cy)); hour.line(to: NSPoint(x: cx + 3.2, y: cy - 2.4))
            hour.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: s / 2, y: s / 2))
    }()
}

/// Shows the OS 9 watch cursor while `active` (Classic + busy). Sets the watch
/// and re-asserts it from a local mouse-moved monitor — SwiftUI's hover
/// tracking keeps resetting the pointer, and cursor-rect games are fragile —
/// then restores the arrow the moment `active` drops (and again on teardown,
/// so the watch can never stick). The caller gates `active` to Classic.
struct ClassicBusyCursor: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.background(BusyCursorHolder(active: active).allowsHitTesting(false))
    }
}

private struct BusyCursorHolder: NSViewRepresentable {
    let active: Bool

    final class Coordinator {
        private var monitor: Any?
        private(set) var watching = false

        func activate() {
            guard !watching else { return }
            watching = true
            AppTheme.classicWatchCursor.set()
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged]
            ) { [weak self] event in
                guard self?.watching == true else { return event }
                // A live text edit (the rename caption, a Settings field) needs
                // its own I-beam — don't fight the field editor's cursor rects
                // while one is first responder.
                if event.window?.firstResponder is NSTextView { return event }
                AppTheme.classicWatchCursor.set()
                return event
            }
        }

        func deactivate() {
            guard watching else { return }
            watching = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NSCursor.arrow.set()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let active = self.active
        DispatchQueue.main.async {
            active ? coordinator.activate() : coordinator.deactivate()
        }
    }
}

extension View {
    /// Show the OS 9 watch cursor while `active`. Gate `active` to Classic.
    func classicBusyCursor(active: Bool) -> some View {
        modifier(ClassicBusyCursor(active: active))
    }
}

// MARK: - Classic OS 9 scrollbar

/// Scroll state the scrollbar needs, plumbed out of the `ScrollView` via
/// `onScrollGeometryChange`.
struct ClassicScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var canScroll: Bool { content > viewport + 1 }
    var maxScroll: CGFloat { max(0, content - viewport) }
}

/// An authentic Platinum scrollbar: pinstriped track, raised arrow buttons at
/// each end, and a ridged proportional thumb you can drag. Reflects AND drives
/// the scroll position. Classic-only — the caller overlays it on the scroll
/// view's trailing edge and hides the native indicator. Always visible; the
/// thumb disappears and the arrows grey out when the content fits (period-true).
struct ClassicScrollbar: View {
    let metrics: ClassicScrollMetrics
    let scrollTo: (CGFloat) -> Void
    /// Stop above a grow box in the window corner, period-style.
    var reserveGrowBox = false

    static let width: CGFloat = 15
    private let arrowH: CGFloat = 15
    private let lineStep: CGFloat = 64
    @State private var dragStart: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - (reserveGrowBox ? Self.width : 0)
            let trackTop = arrowH
            let trackLen = max(0, h - arrowH * 2)
            let thumbFrac = metrics.content > 0 ? min(1, metrics.viewport / metrics.content) : 1
            let thumbLen = metrics.canScroll ? max(24, trackLen * thumbFrac) : 0
            let dragRange = max(0, trackLen - thumbLen)
            let scrollFrac = metrics.maxScroll > 0 ? min(1, max(0, metrics.offset / metrics.maxScroll)) : 0
            let thumbY = trackTop + dragRange * scrollFrac

            ZStack(alignment: .top) {
                ClassicScrollTrack()
                    .frame(height: h)

                if metrics.canScroll {
                    ClassicScrollThumb()
                        .frame(height: thumbLen)
                        .offset(y: thumbY)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if dragStart == nil { dragStart = metrics.offset }
                                    guard dragRange > 0 else { return }
                                    let newOffset = (dragStart ?? 0) + (v.translation.height / dragRange) * metrics.maxScroll
                                    scrollTo(min(metrics.maxScroll, max(0, newOffset)))
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }

                ClassicScrollArrow(down: false, enabled: metrics.canScroll)
                    .frame(height: arrowH)
                    .onTapGesture { scrollTo(max(0, metrics.offset - lineStep)) }

                ClassicScrollArrow(down: true, enabled: metrics.canScroll)
                    .frame(height: arrowH)
                    .offset(y: h - arrowH)
                    .onTapGesture { scrollTo(min(metrics.maxScroll, metrics.offset + lineStep)) }
            }
        }
        .frame(width: Self.width)
    }
}

/// One-stop OS 9 scrollbar for any vertical `ScrollView`: hides the native
/// indicator, reads the scroll geometry, reserves the gutter via content
/// margins, and overlays a driving `ClassicScrollbar` — in Classic only; the
/// other themes are untouched. (The main gallery wires these pieces manually
/// because its content already manages its own margins.)
struct ClassicScrollbarModifier: ViewModifier {
    var reserveGrowBox = false
    @Environment(\.isClassicTheme) private var classic
    @State private var metrics = ClassicScrollMetrics()
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollIndicators(classic ? .hidden : .automatic)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ClassicScrollMetrics.self) { geo in
                ClassicScrollMetrics(offset: geo.contentOffset.y,
                                     content: geo.contentSize.height,
                                     viewport: geo.containerSize.height)
            } action: { _, m in
                // Only Classic consumes the metrics — writing this @State per
                // scroll frame in the other themes would re-evaluate the whole
                // scroll subtree for a thumb that doesn't exist there.
                if classic { metrics = m }
            }
            .contentMargins(.trailing, classic ? ClassicScrollbar.width : 0, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if classic {
                    ClassicScrollbar(metrics: metrics, scrollTo: { y in
                        position.scrollTo(y: y)
                    }, reserveGrowBox: reserveGrowBox)
                }
            }
    }
}

extension View {
    /// Apply directly to a vertical `ScrollView`. Classic-only.
    func classicScrollbar(reserveGrowBox: Bool = false) -> some View {
        modifier(ClassicScrollbarModifier(reserveGrowBox: reserveGrowBox))
    }
}

private struct ClassicScrollTrack: View {
    var body: some View {
        // Recessed well: clearly darker than the Platinum face, with a sunken
        // bevel (shadow top-left, light bottom-right) so the raised thumb and
        // arrow buttons pop against it.
        Rectangle()
            .fill(Color(red: 0.68, green: 0.68, blue: 0.68))
            .overlay(
                Rectangle().inset(by: 0.6).stroke(
                    LinearGradient(colors: [AppTheme.platinumShadow, Color.white.opacity(0.9)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.2)
            )
            .overlay(Rectangle().stroke(AppTheme.platinumFrame.opacity(0.65), lineWidth: 1))
    }
}

private struct ClassicScrollThumb: View {
    var body: some View {
        // The Platinum thumb — OS 9's blue-lavender gel with a dark frame and
        // a top-left highlight, unmistakable against the recessed track.
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                colors: [Color(red: 0.76, green: 0.80, blue: 0.93),
                         Color(red: 0.55, green: 0.62, blue: 0.84)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.inset(by: 1).stroke(
                LinearGradient(colors: [Color.white.opacity(0.95),
                                        Color(red: 0.35, green: 0.42, blue: 0.64)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2)
            shape.stroke(AppTheme.platinumFrame, lineWidth: 1)
            // Grip ridges — the OS 9 thumb texture: light line over dark line.
            VStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.85)).frame(width: 8, height: 1)
                        Rectangle().fill(Color(red: 0.33, green: 0.40, blue: 0.62)).frame(width: 8, height: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 1)
        .clipShape(shape.inset(by: -0.5))   // ridges must never spill a squeezed thumb
    }
}

private struct ClassicScrollArrow: View {
    var down: Bool
    var enabled: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.80)],
                                      startPoint: .top, endPoint: .bottom))
            shape.inset(by: 1).stroke(
                LinearGradient(colors: [AppTheme.platinumLight, AppTheme.platinumShadow],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.3)
            shape.stroke(AppTheme.platinumFrame.opacity(0.8), lineWidth: 1)
            _ScrollTriangle(down: down)
                .fill(enabled ? AppTheme.platinumText : AppTheme.platinumShadow.opacity(0.5))
                .frame(width: 7, height: 5)
        }
        .padding(.horizontal, 1)
    }
}

/// The OS 9 grow box — two overlapping square outlines on a Platinum tile in
/// the window's bottom-right corner. Decorative: resizing itself is the
/// window edge's native behaviour.
struct ClassicGrowBox: View {
    var body: some View {
        ZStack {
            Rectangle().fill(AppTheme.platinumFace)
            // Big square, bottom-right.
            Rectangle()
                .stroke(AppTheme.platinumFrame, lineWidth: 1)
                .frame(width: 7.5, height: 7.5)
                .offset(x: 1, y: 1)
            // Small square, top-left, face-filled so it reads "in front".
            Rectangle()
                .fill(AppTheme.platinumFace)
                .overlay(Rectangle().stroke(AppTheme.platinumFrame, lineWidth: 1))
                .frame(width: 5.5, height: 5.5)
                .offset(x: -1.5, y: -1.5)
        }
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.platinumFrame.opacity(0.65)).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(AppTheme.platinumFrame.opacity(0.65)).frame(width: 1) }
        .frame(width: ClassicScrollbar.width, height: ClassicScrollbar.width)
        .allowsHitTesting(false)
    }
}

private struct _ScrollTriangle: Shape {
    var down: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if down {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Classic Balloon Help

/// Where a Balloon Help balloon appears relative to its control. Controls near
/// the top of the window use the `below` variants so the balloon isn't clipped
/// by the window edge; controls hugging the left/right window edges use the
/// leading/trailing variants so the balloon grows inward instead of clipping.
nonisolated enum ClassicHelpPlacement {
    case above, below, belowLeading, belowTrailing

    var isBelow: Bool { self != .above }
    var alignment: Alignment {
        switch self {
        case .above: return .top
        case .below: return .bottom
        case .belowLeading: return .bottomLeading
        case .belowTrailing: return .bottomTrailing
        }
    }
}

/// OS 9 "Balloon Help" — a cream comic-balloon tooltip shown on hover in the
/// Classic theme, in place of the modern help tag. Always also sets the system
/// `.help(_:)` for accessibility and for the other themes.
struct ClassicHelp: ViewModifier {
    let text: String
    var placement: ClassicHelpPlacement = .above
    @Environment(\.isClassicTheme) private var classic
    @State private var hovering = false
    @State private var show = false
    /// Measured width of the control, so an edge-aligned balloon can aim its
    /// tail at the control's CENTRE rather than a fixed spot on the balloon.
    @State private var controlWidth: CGFloat = 0

    /// Tail x-position in balloon space: distance in from the aligned edge
    /// (leading or trailing); nil = centred.
    private var tailInset: CGFloat? {
        switch placement {
        case .belowLeading, .belowTrailing: return controlWidth / 2
        case .above, .below: return nil
        }
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { controlWidth = $0 }
            // Classic draws its own balloon; all themes retain the same VoiceOver hint.
            .help(classic ? "" : text)
            .accessibilityHint(Text(text))
            .onHover { over in
                hovering = over
                if over && classic {
                    Task { @MainActor in
                        // Long fuse: the balloon must never ambush a click.
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        if hovering { show = true }
                    }
                } else {
                    show = false
                }
            }
            // The balloon is ALWAYS in the overlay (visibility via opacity):
            // wrapping it in an `if` puts a conditional container between the
            // overlay and the alignment guide, the guide is ignored, and the
            // balloon lands on top of its control instead of beside it.
            .overlay(alignment: placement.alignment) {
                ClassicHelpBalloon(text: text,
                                   tailUp: placement.isBelow,
                                   tailInset: tailInset,
                                   tailFromTrailing: placement == .belowTrailing)
                    .fixedSize()
                    // Float the balloon clear of the control: bottom 4pt
                    // above its top, or top 4pt below its bottom.
                    .alignmentGuide(placement == .above ? .top : .bottom) { d in
                        placement == .above ? d[.bottom] + 4 : d[.top] - 4
                    }
                    .opacity(classic && show ? 1 : 0)
                    .allowsHitTesting(false)
                    .zIndex(1000)
            }
            .animation(.easeOut(duration: 0.12), value: show)
    }
}

extension View {
    /// Classic Balloon Help on hover; the system help tag otherwise.
    func classicHelp(_ text: String, placement: ClassicHelpPlacement = .above) -> some View {
        modifier(ClassicHelp(text: text, placement: placement))
    }
}

private struct ClassicHelpBalloon: View {
    let text: String
    var tailUp: Bool = false
    var tailInset: CGFloat? = nil
    var tailFromTrailing: Bool = false
    private let tail: CGFloat = 7
    var body: some View {
        Text(text)
            .font(.classic(11))
            .foregroundColor(.black)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .padding(tailUp ? .top : .bottom, tail)   // room for the tail
            .background(_BalloonShape(tail: tail, tailUp: tailUp,
                                      tailInset: tailInset, tailFromTrailing: tailFromTrailing)
                .fill(Color(red: 1.0, green: 1.0, blue: 0.92)))
            .overlay(_BalloonShape(tail: tail, tailUp: tailUp,
                                   tailInset: tailInset, tailFromTrailing: tailFromTrailing)
                .stroke(Color.black, lineWidth: 1))
            .frame(maxWidth: 240)
            .shadow(color: .black.opacity(0.25), radius: 3, y: tailUp ? -1 : 1)
    }
}

private struct _BalloonShape: Shape {
    var tail: CGFloat
    var tailUp: Bool = false
    /// Tail tip distance in from the aligned edge (the control's half-width,
    /// so the tail points at the control's centre); nil = balloon centre.
    var tailInset: CGFloat? = nil
    var tailFromTrailing: Bool = false

    /// ONE continuous outline — body and tail as a single subpath. (A rounded
    /// rect plus a separate tail triangle strokes the rect's edge straight
    /// across the tail's base, drawing a line between bubble and tail.)
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 6
        let body = CGRect(x: rect.minX, y: rect.minY + (tailUp ? tail : 0),
                          width: rect.width, height: rect.height - tail)
        var tipX = rect.midX
        if let tailInset {
            tipX = tailFromTrailing ? rect.maxX - tailInset : rect.minX + tailInset
        }
        // Keep the tail's base clear of the rounded corners.
        tipX = min(max(tipX, body.minX + r + tail), body.maxX - r - tail)

        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if tailUp {
            // Top edge, interrupted by the tail.
            p.addLine(to: CGPoint(x: tipX - tail, y: body.minY))
            p.addLine(to: CGPoint(x: tipX, y: rect.minY))
            p.addLine(to: CGPoint(x: tipX + tail, y: body.minY))
        }
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        if !tailUp {
            // Bottom edge (right→left), interrupted by the tail.
            p.addLine(to: CGPoint(x: tipX + tail, y: body.maxY))
            p.addLine(to: CGPoint(x: tipX, y: rect.maxY))
            p.addLine(to: CGPoint(x: tipX - tail, y: body.maxY))
        }
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Classic OS 9 title bar

/// An authentic OS 9 title-bar control box — a beveled Platinum square with a
/// hand-drawn glyph (none for close, an inner square for zoom, a centre line
/// for collapse), inverting to sunken while pressed. No hover state — OS 9
/// had none.
struct ClassicTitleBarBox: View {
    enum Kind { case close, zoom, collapse }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) { Color.clear }
            .buttonStyle(_BoxStyle(kind: kind))
            .accessibilityLabel(kind == .close ? "Close" : kind == .zoom ? "Zoom" : "Minimise")
    }

    private struct _BoxStyle: ButtonStyle {
        let kind: Kind
        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            return ZStack {
                Rectangle().fill(LinearGradient(
                    colors: pressed ? [Color(white: 0.52), Color(white: 0.68)]
                                    : [Color(white: 0.98), Color(white: 0.80)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Rectangle().inset(by: 1).stroke(
                    LinearGradient(
                        colors: pressed ? [AppTheme.platinumShadow, AppTheme.platinumLight]
                                        : [AppTheme.platinumLight, AppTheme.platinumShadow],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
                glyph
                Rectangle().stroke(AppTheme.platinumFrame, lineWidth: 1)
            }
            .frame(width: 13, height: 13)
            .contentShape(Rectangle())
        }

        @ViewBuilder private var glyph: some View {
            switch kind {
            case .close:
                EmptyView()
            case .zoom:
                Rectangle().stroke(AppTheme.platinumFrame, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .offset(x: -1, y: -1)
            case .collapse:
                Rectangle().fill(AppTheme.platinumFrame)
                    .frame(width: 7, height: 1.5)
            }
        }
    }
}

/// The Mac OS 9 title bar, mounted over the (stripped) native title-bar band
/// of any Classic window by `WindowConfigurator`: racing-stripe texture,
/// centred Charcoal title, close box on the left, zoom + collapse boxes on
/// the right — the latter two only when the window can actually zoom or
/// minimise, matching how OS 9 dialogs wore only a close box. Fills whatever
/// height its AppKit container gives it (25pt on the main window, the real
/// band height on auxiliary windows).
struct ClassicTitleBar: View {
    let title: String
    var showZoom = true
    var showCollapse = true
    static let height: CGFloat = 25

    /// OS 9 deactivated its title bars completely: stripes gone, boxes gone,
    /// title greyed. Driven by the mount (WindowConfigurator) from the real
    /// `isKeyWindow` state — `controlActiveState` does not propagate into a
    /// frame-mounted NSHostingView.
    var isActive = true

    var body: some View {
        ZStack {
            Rectangle().fill(AppTheme.platinumFace)
            if isActive {
                _TitleBarStripes()
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
            }
            // Only when there IS a title. The chip carries a platinumFace
            // background to punch a clean hole in the stripes for the text —
            // but with an empty title that hole is all there is, so an
            // untitled window (a sheet, say) got a blank 20pt gap sitting in
            // the middle of an otherwise continuous striped bar. OS 9 drew
            // untitled movable modals as unbroken stripes.
            if !title.isEmpty {
                Text(title)
                    .font(.classic(13, weight: .bold))
                    .foregroundStyle(isActive ? AppTheme.platinumText : Color(white: 0.45))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .background(AppTheme.platinumFace)
            }
            if isActive {
                HStack {
                    ClassicTitleBarBox(kind: .close) {
                        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        if showZoom {
                            ClassicTitleBarBox(kind: .zoom) {
                                (NSApp.keyWindow ?? NSApp.mainWindow)?.performZoom(nil)
                            }
                        }
                        if showCollapse {
                            ClassicTitleBarBox(kind: .collapse) {
                                (NSApp.keyWindow ?? NSApp.mainWindow)?.performMiniaturize(nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 7)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.platinumFrame).frame(height: 1)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isActive)
        // The native titlebar layer is hidden in Classic, so the drawn bar
        // provides the window behaviours itself: drag to move, double-click
        // to zoom. The boxes are Buttons and win their clicks.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if showZoom { (NSApp.keyWindow ?? NSApp.mainWindow)?.performZoom(nil) }
        })
        .gesture(WindowDragGesture())
    }
}

/// The OS 9 title-bar racing stripes: paired 1px lines, white over shadow.
private struct _TitleBarStripes: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0.5
            while y + 1 < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                         with: .color(.white.opacity(0.9)))
                ctx.fill(Path(CGRect(x: 0, y: y + 1, width: size.width, height: 1)),
                         with: .color(.black.opacity(0.22)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}
