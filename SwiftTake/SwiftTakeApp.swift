// MARK: - SwiftTakeApp
//
// SwiftUI App entry point for SwiftTake — a 100 % Swift, native macOS app
// for talking to Apple QuickTake 100 / 150 cameras over the original
// 1990s serial protocol, decoding their proprietary `.QTK` raw image
// format, and rendering them with a hand-tuned colour pipeline derived
// from the Apple/Kodak QuickTake software for Windows.
//
// Scenes:
//   - WindowGroup → ContentView    : main gallery + sidebar
//   - Settings    → SettingsView   : multi-tab Settings window
//   - Window "Help"                : contextual help
//   - Window "Camera Controls"     : optional pop-out camera-control panel
//                                    when the user expands it from the
//                                    sidebar's Controls section
//   - Window "About SwiftTake"    : custom About window (replaces the
//                                    cramped fixed-size standard panel)
//
// The single `QuickTakeSerialManager` instance owns all camera state and
// is injected into every scene via `.environmentObject`. The `appTheme`
// AppStorage drives light / dark / system theme system-wide.
//
import SwiftUI
import CoreText

@main
struct SwiftTakeApp: App {
    /// One serial manager for the whole app lifetime — owns the
    /// camera connection, photo gallery, and every async I/O task.
    @StateObject private var serialManager = QuickTakeSerialManager()

    init() {
        // No window tabbing: a camera-gallery app never merges its windows
        // into tabs, and AppKit's automatic "Show Tab Bar" / "Show All Tabs"
        // View-menu items only exist while this is enabled — one switch
        // removes the feature and its menu items everywhere.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Register the bundled Charcoal (Mac OS 9) face so the Classic theme's
        // `Font.classic(...)` renders authentic period text.
        if let url = Bundle.main.url(forResource: "CHARCOAL", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // Nu Casual — the Newton-era casual face used by the Newton easter egg.
        if let url = Bundle.main.url(forResource: "NuCasual", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// User's preferred light / dark / system / classic theme. Persists across
    /// launches via `@AppStorage`.
    @AppStorage(PrefKey.appTheme) private var appTheme = AppTheme.system
    /// Classic is gated behind the easter egg; if it's selected but no longer
    /// unlocked (e.g. after Reset to Defaults), fall back to System.
    @AppStorage(PrefKey.rainbowUnlocked) private var classicUnlocked = false

    private var effectiveTheme: AppTheme {
        (appTheme == .classic && !classicUnlocked) ? .system : appTheme
    }


    var body: some Scene {
        WindowGroup {
            // Keep window sizing outside the identity reset. Otherwise the
            // first Classic rebuild can replace the live window size with
            // the new content's smaller ideal size while its toolbar attaches.
            GeometryReader { _ in
                ContentView()
                    .environmentObject(serialManager)
                    .appTheme(effectiveTheme)
                    .modifier(ReducedMotionSupport())
                    // Rebuild the whole view tree (and therefore the window toolbar)
                    // when crossing the Classic boundary. A window has ONE shared
                    // NSToolbar; morphing it between the native (Regular) and Platinum
                    // (Classic) layouts left items drifted/misaligned. Giving each
                    // theme a fresh identity means each gets a clean toolbar built
                    // from scratch — Regular stays 100% native, Classic full Platinum,
                    // and neither ever has to morph into the other.
                    .id(effectiveTheme.isClassic)
                    // Classic wears its own pixel-art Dock icon.
                    // Both hooks sit OUTSIDE the .id boundary above, and out here
                    // the identity reset does NOT re-fire onAppear (onAppear
                    // alone misses theme flips — the icon would never swap after
                    // launch). So: onAppear covers launch, onChange covers every
                    // flip; WindowThemeBridge fires the same idempotent swap from
                    // the auxiliary windows. These hooks feed the DOCK only —
                    // in-app icon views draw AppTheme.appIcon(classic:), derived
                    // from the theme, so they can't race this hook.
                    .onAppear { AppTheme.applyDockIcon(classic: effectiveTheme.isClassic) }
                    .onChange(of: effectiveTheme.isClassic) { _, classic in
                        AppTheme.applyDockIcon(classic: classic)
                    }
            }
            .frame(minWidth: 760, minHeight: 480)
        }
        // Floor for windows with no saved frame (fresh install, cleared
        // container, or a frame autosave that didn't stick): without an
        // explicit default, SwiftUI falls back to the content's ideal size,
        // which the Classic layout reports far too small. Saved frames
        // still win — this only decides the first impression.
        .defaultSize(width: 1100, height: 640)
        // Adds the menu-bar command set (File / Edit / Camera menus).
        .commands {
            AppCommands(serialManager: serialManager)
        }

        // Auxiliary scenes below use `.windowAppTheme()` — NOT the
        // `.appTheme(effectiveTheme)` used on the main window: values injected
        // here from the App don't reliably reach these scenes' view trees
        // (the Help window once rendered Liquid Glass in a Classic session),
        // so the bridge re-derives the theme from storage inside the view.

        // Native macOS Settings window (Cmd+,). Shares the same
        // `serialManager` instance — settings changes hit live state.
        Settings {
            SettingsView()
                .environmentObject(serialManager)
                .windowAppTheme()
                .modifier(ReducedMotionSupport())
        }

        // Help window — opened from the sidebar question-mark. Sized to its
        // content (the view sets a min frame) since it no longer scrolls.
        Window("Help", id: "helpWindow") {
            HelpWindowView()
                .windowAppTheme()
                .modifier(ReducedMotionSupport())
        }
        .windowResizability(.contentSize)

        // Pop-out Camera Controls window. The sidebar Controls section
        // can detach into this separate window for users who want the
        // controls visible while working on photos.
        Window("Camera Controls", id: "cameraControls") {
            CameraControlView()
                .environmentObject(serialManager)
                .windowAppTheme()
                .modifier(ReducedMotionSupport())
        }
        .windowResizability(.contentSize)

        // Panorama composer, standalone. No longer the primary surface —
        // Edit ▸ Stitch Panorama opens the same composer as a sheet on the
        // main window, next to the photos it was made from. This stays as
        // a fallback entry point off the Window menu, showing the same
        // composition through the same view, because a window scene costs
        // nothing to keep and some people live there.
        Window("Panorama", id: "panoramaWindow") {
            PanoramaWindowView()
                .environmentObject(serialManager)
                .windowAppTheme()
                .modifier(ReducedMotionSupport())
        }

        // Custom About window — replaces the cramped fixed-size standard
        // About panel so the feature list and prose render in full
        // without truncation.
        Window("About SwiftTake", id: "aboutWindow") {
            AboutView()
                .windowAppTheme()
                .modifier(ReducedMotionSupport())
        }
        .windowResizability(.contentSize)
    }
}

/// Suppress animated layout and transitions throughout each window. Views
/// with timers or physics provide their own static Reduce Motion variants.
private struct ReducedMotionSupport: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private extension View {
    /// Applies the user's chosen colour scheme with a short cross-fade. The
    /// Classic theme also swaps in the Platinum accent and flips the
    /// `isClassicTheme` environment flag so views can restyle themselves.
    func appTheme(_ theme: AppTheme) -> some View {
        self
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
            .environment(\.isClassicTheme, theme.isClassic)
            .classicButtonStyling(theme.isClassic)
            .animation(.easeInOut(duration: 0.25), value: theme)
    }
}
