import AppKit
import SwiftUI

/// Reaches up the AppKit hierarchy to grab the host `NSWindow` and tune its
/// title bar so the Liquid Glass toolbar strip looks right in both presentation
/// modes — which need *opposite* `titlebarAppearsTransparent` settings:
///
///   • Windowed — the title bar must draw its own frosted material, otherwise
///     `.toolbarBackground(.visible)` has no surface to render on and the glass
///     strip simply doesn't appear.
///   • Fullscreen — there's no title bar; the auto-hiding toolbar overlay wants
///     a transparent title bar so content (and the connecting blur) reaches the
///     very top.
///
/// So we toggle the flag on every fullscreen transition. `.fullSizeContentView`
/// (content extends under the bar) and a hidden separator stay constant.
///
/// In Classic the native chrome is stripped instead: transparent title bar,
/// hidden title, hidden traffic lights — and the hand-drawn `ClassicTitleBar`
/// is mounted over the band, with its title and boxes derived from the window
/// (title text, zoom box only if resizable, collapse box only if
/// miniaturizable). AppKit re-shows the standard buttons whenever the toolbar
/// attaches or the window becomes key, so Classic re-asserts from
/// `updateNSView` and window notifications rather than configuring once.
///
/// Two call sites: ContentView (`fullSize: true`, the default — also manages
/// full-size content and the pinned sidebar) and WindowThemeBridge
/// (`fullSize: false` — pure chrome for every auxiliary window). The main
/// window is rebuilt per theme (WindowGroup `.id`); auxiliary windows are NOT,
/// so the coordinator tracks the live `classic` value across flips.
struct WindowConfigurator: NSViewRepresentable {
    var classic: Bool = false
    /// Main-window layout management: insert `.fullSizeContentView` and hide
    /// the titlebar separator. Auxiliary windows skip it so their regular-
    /// theme look stays untouched.
    var fullSize: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = _WindowAwareView()
        let fullSize = self.fullSize
        let coordinator = context.coordinator
        coordinator.classic = classic
        coordinator.fullSize = fullSize
        // viewDidMoveToWindow, not a one-shot dispatch: when the view tree is
        // rebuilt live (theme flip via .id), the window attaches a beat later
        // than at launch, so a single async hop misses it and the Classic
        // chrome never mounts.
        view.onWindow = { window in
            if fullSize {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarSeparatorStyle = .none
            }
            coordinator.start(observing: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI re-runs this on state changes — a cheap, frequent hook to
        // re-assert the Classic chrome after AppKit restores its buttons, and
        // the moment auxiliary windows (which live across theme flips) learn
        // about a new theme.
        let coordinator = context.coordinator
        coordinator.classic = classic
        coordinator.fullSize = fullSize
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            Coordinator.apply(to: window, classic: coordinator.classic, fullSize: coordinator.fullSize)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Live flags — notifications read these rather than captured copies
        /// so windows that survive a theme flip re-apply the RIGHT theme.
        var classic = false
        var fullSize = true
        private var tokens: [NSObjectProtocol] = []
        private var started = false

        func start(observing window: NSWindow) {
            guard !started else { return }
            started = true
            let nc = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification,
                         NSWindow.didResizeNotification] {
                let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    Self.apply(to: window, classic: self.classic, fullSize: self.fullSize)
                }
                tokens.append(token)
            }
            Self.apply(to: window, classic: classic, fullSize: fullSize)
            // The split-view controller (and the toolbar) can attach a beat
            // after the window exists — apply again shortly after so launch is
            // always covered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
                if let self, let window { Self.apply(to: window, classic: self.classic, fullSize: self.fullSize) }
            }
        }

        /// Regular: transparent title bar only in fullscreen; frosted
        /// (opaque-material) in windowed so the toolbar's glass strip shows.
        /// Classic: SwiftUI hides the entire titlebar layer when the toolbar
        /// is hidden (NSTitlebarContainerView.isHidden) — which is exactly
        /// what Classic wants: a chrome-free window whose content draws the
        /// OS 9 title bar itself. The standard buttons are hidden here as
        /// belt-and-braces (they float even over hidden titlebars in some
        /// states), and unhidden on the way back to a regular theme.
        static func apply(to window: NSWindow, classic: Bool, fullSize: Bool) {
            if classic {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                // No fullscreen in Classic: the drawn chrome offers no exit
                // affordance from fullscreen, so the mode is a trap. Banning
                // it here also disables the View menu item. If the window is
                // already fullscreen (theme switched while in it), leave.
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            } else {
                window.titlebarAppearsTransparent = window.styleMask.contains(.fullScreen)
                // Windows survive theme flips (only content rebuilds), so
                // returning from Classic must dismantle its chrome.
                window.titleVisibility = .visible
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                // Restore fullscreen capability — main window only; auxiliary
                // windows never offer it.
                window.collectionBehavior.remove(.fullScreenNone)
                if fullSize {
                    window.collectionBehavior.insert(.fullScreenPrimary)
                }
            }
            setScrollPockets(hidden: classic, in: window)
            mountTitleBar(classic: classic, fullSize: fullSize, in: window)
            pinSidebarWidth(in: window)
        }

        /// Classic mounts the OS 9 title bar as an AppKit view pinned to the
        /// TOP of the window's frame view with Auto Layout — above the
        /// (hidden) titlebar layer and outside SwiftUI's safe-area clipping,
        /// which silently swallows inset content drawn in the old titlebar
        /// band. The bar's height is the REAL band height (main window: the
        /// 25pt slot its content reserves — see classicHeader; auxiliary
        /// windows: whatever the native title bar occupied, so the content
        /// below never shifts). Title and boxes come from the window itself.
        /// Z-order is re-asserted on every window event.
        private static func mountTitleBar(classic: Bool, fullSize: Bool, in window: NSWindow) {
            guard let frameView = window.contentView?.superview else { return }
            let existing = frameView.subviews.first(where: { $0 is ClassicTitleBarHostView })
            guard classic else {
                existing?.removeFromSuperview()
                return
            }
            // The main window's bar carries the APP name — its content header
            // (the Platinum control row) carries "Camera Storage". Auxiliary
            // windows show their own titles.
            let bar = ClassicTitleBar(
                title: fullSize ? "SwiftTake" : window.title,
                showZoom: window.styleMask.contains(.resizable),
                showCollapse: window.styleMask.contains(.miniaturizable),
                isActive: window.isKeyWindow)

            // The band height is whatever the (chrome-stripped) window still
            // reserves above its content — read live from the content view's
            // safe area, floored at the 25pt design height.
            let bandHeight = max(ClassicTitleBar.height, window.contentView?.safeAreaInsets.top ?? 0)

            let host: ClassicTitleBarHostView
            if let existing = existing as? ClassicTitleBarHostView {
                host = existing
                host.hosting?.rootView = bar   // live title / key-state refresh
                host.heightConstraint?.constant = bandHeight
            } else {
                let container = ClassicTitleBarHostView()
                container.translatesAutoresizingMaskIntoConstraints = false
                // First-mouse: window controls must respond even when the
                // window isn't key, like the traffic lights they replace.
                let hosting = _FirstMouseHostingView(rootView: bar)
                hosting.translatesAutoresizingMaskIntoConstraints = false
                // Critical: NSHostingView applies the WINDOW's safe-area
                // insets to its content by default, which would shove the bar
                // ~28pt down below the phantom (hidden) titlebar band.
                hosting.safeAreaRegions = []
                container.hosting = hosting
                container.addSubview(hosting)
                NSLayoutConstraint.activate([
                    hosting.topAnchor.constraint(equalTo: container.topAnchor),
                    hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                host = container
            }
            // Keep it on top of any later-added chrome. Re-adding drops the
            // container's constraints to frameView, so they are (re)activated
            // after every (re)attach.
            if host.superview !== frameView || frameView.subviews.last !== host {
                host.removeFromSuperview()
                frameView.addSubview(host, positioned: .above, relativeTo: nil)
                let height = host.heightAnchor.constraint(equalToConstant: bandHeight)
                host.heightConstraint = height
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: frameView.topAnchor),
                    host.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                    height,
                ])
            }
        }

        /// Liquid Glass paints a "scroll pocket" backdrop over the top ~52pt
        /// of each scroll column (the scroll-edge effect). In Classic that
        /// wash sits exactly over the drawn OS 9 title bar and flattens it to
        /// grey — and the SwiftUI `scrollEdgeEffectStyle(nil)` modifier does
        /// not reach the split view's internal scroll containers. So, as with
        /// `pinSidebarWidth`, reach in and switch the pocket views off by
        /// class name. Fails soft: if AppKit ever renames them, the wash
        /// comes back but nothing breaks.
        private static func setScrollPockets(hidden: Bool, in window: NSWindow) {
            guard let root = window.contentView?.superview else { return }
            var stack: [NSView] = [root]
            while let view = stack.popLast() {
                if String(describing: type(of: view)).contains("NSScrollPocket") {
                    view.isHidden = hidden
                    continue
                }
                stack.append(contentsOf: view.subviews)
            }
        }

        /// The sidebar is deliberately not user-resizable. SwiftUI's
        /// `navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)`
        /// STILL leaves the divider draggable on macOS 26, so pin the AppKit
        /// split item's thickness directly — the divider then simply won't
        /// move. Collapsing (hide/show sidebar) is untouched: that's the
        /// item's `isCollapsed`, independent of thickness.
        private static func pinSidebarWidth(in window: NSWindow) {
            var stack: [NSViewController] = window.contentViewController.map { [$0] } ?? []
            while let vc = stack.popLast() {
                if let split = vc as? NSSplitViewController {
                    // NEVER pin a collapsed sidebar: forcing thickness on a
                    // collapsed item pops it back open, and this runs on every
                    // SwiftUI update — so any mouse-move (hover state) undid
                    // the user's Toggle Sidebar a beat after they clicked it.
                    if let sidebar = split.splitViewItems.first, !sidebar.isCollapsed {
                        sidebar.minimumThickness = 260
                        sidebar.maximumThickness = 260
                    }
                    return
                }
                stack.append(contentsOf: vc.children)
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Marker container for the frame-mounted OS 9 title bar so
/// `mountTitleBar(classic:in:)` can find, re-order, refresh, and remove it.
final class ClassicTitleBarHostView: NSView {
    var hosting: NSHostingView<ClassicTitleBar>?
    var heightConstraint: NSLayoutConstraint?
}

/// The title-bar hosting view accepts the first click on an inactive window —
/// window controls must act immediately, like the traffic lights they replace.
private final class _FirstMouseHostingView: NSHostingView<ClassicTitleBar> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Calls `onWindow` the moment the view lands in (or moves to) a window —
/// the reliable attachment signal for window-level configuration.
private final class _WindowAwareView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}
