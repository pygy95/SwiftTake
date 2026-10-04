// MARK: - AppCommands
//
// Menu-bar commands wired into `SwiftTakeApp` via the `.commands` scene
// modifier: a custom About item, the Camera menu (controls, connect,
// refresh, import, re-import, erase), gallery zoom, and a Help menu that
// replaces the stock one. Also defines `DeveloperCommands`, the diagnostics
// and test-presentation menu shown only when Developer Tools is enabled.
//
// All actions defer to the shared `QuickTakeSerialManager`, so the menu
// bar, sidebar, and shortcuts all do the same thing.

import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var serialManager: QuickTakeSerialManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    // Same key ContentView observes — writing it here re-sizes the gallery.
    @AppStorage(PrefKey.galleryZoom) private var galleryThumbnailWidth: Double = ContentView.galleryZoomDefault
    // Drives whether the Simulator menu exists at all. Off by default.
    @AppStorage(PrefKey.demoModeEnabled) private var demoModeEnabled = false
    // Drives whether the Developer menu exists at all. Off by default.
    @AppStorage(PrefKey.developerToolsEnabled) private var developerToolsEnabled = false

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SwiftTake") {
                openWindow(id: "aboutWindow")
            }
        }

        // SwiftTake has no printing — Cmd+P is hijacked for the Moof! easter
        // egg (Clarus the Dogcow). Replacing `.printItem` removes the stock
        // "Print…" item and claims its ⌘P shortcut app-wide.
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                serialManager.triggerMoof()
            }
            .keyboardShortcut("p", modifiers: [.command])
        }

        // Photo selection lives in the Edit menu (Finder/Photos convention).
        CommandGroup(after: .pasteboard) {
            Button("Select All Photos") {
                serialManager.selectAllPhotos()
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(!serialManager.isConnected || serialManager.photoIndices.isEmpty)

            Button("Deselect All") {
                serialManager.selectedPhotoIndices.removeAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(serialManager.selectedPhotoIndices.isEmpty)

            Divider()

            // Sits with the selection commands because that is what it
            // operates on. Enabled rather than hidden when unavailable, so
            // the feature stays discoverable — the stitcher itself decides
            // whether the frames actually overlap and says so if not.
            //
            // Opens the composer as a SHEET on the main window: the
            // panorama is made out of the selection behind it, and a
            // window of its own puts it somewhere with no visible
            // connection to the photos that produced it. The standalone
            // window scene is still there for anyone who opens it.
            // The Finder route. Sits with Stitch Panorama because they end
            // in the same place; this one gets its frames from disk rather
            // than the selection, and so has to ask about order on the way.
            Button("Choose Photos…") {
                serialManager.choosePanoramaPhotos()
            }

            Button("Stitch Panorama…") {
                serialManager.stitchSelectedPanorama()
            }
            .disabled(!serialManager.canStitchSelection)
        }

        // Ordered by lifecycle: connection first, then working with photos,
        // then device-level actions, then utilities. Items are DISABLED (not
        // hidden) when unavailable so every shortcut stays discoverable — the
        // one exception is Erase, hidden for cameras whose firmware rejects
        // the command (QT200/Fuji NAKs it), mirroring the sidebar.
        CommandMenu("Camera") {
            Button("Connect") {
                serialManager.connectToDetectedCamera()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!serialManager.selectedModelSerialAvailable
                      || serialManager.isConnected
                      || serialManager.isBusy)

            Button("Disconnect") {
                serialManager.disconnectCamera()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            // Enabled during a thumbnail load on purpose — the escape hatch
            // when a camera dies mid-stream, mirroring the sidebar button.
            .disabled(!serialManager.isConnected
                      || (serialManager.isBusy && !serialManager.areThumbnailsLoading))

            Divider()

            // Selection-aware, same rule as the toolbar button: disabled while
            // the link is busy with anything that ISN'T an import; enabled
            // during a running import so more photos can queue onto it.
            Button("Import Photos") {
                serialManager.requestBatchImport()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!serialManager.isConnected
                      || serialManager.photoIndices.isEmpty
                      || serialManager.areThumbnailsLoading
                      || (serialManager.isBusy && serialManager.photoTransfers.isEmpty))

            // No bulk re-decode command, deliberately. Re-running the colour
            // pipeline over archives on disk is a third way to get photos in,
            // alongside the camera and a .qtk drag-and-drop, and it was the
            // one nobody could name: it read like a camera import but never
            // touched the camera. Re-importing from the camera, or dropping
            // the .qtk files back on the window, both do the job and are
            // obvious about what they act on. The per-photo path stays —
            // the Copland develop runs on it.
            Button("Refresh Camera Info") {
                serialManager.refreshCameraMetadata()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!serialManager.isConnected || serialManager.isBusy)

            // Full plug-in-style rebuild: every cell drops to its
            // swirl and refetches, fresh count included — unlike Refresh
            // above, which keeps loaded thumbnails.
            Button("Reload Gallery") {
                serialManager.refreshCameraMetadata(fullReload: true)
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(!serialManager.isConnected || serialManager.isBusy)

            Divider()

            // The live camera-control panel is Kodak-only today (the QT200
            // driver exposes no LCD-style controls) AND needs a camera on
            // the line — every control on it is a serial command, so
            // opening it while disconnected offers nothing but dead
            // buttons.
            Button("Camera Controls…") {
                openWindow(id: "cameraControls")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!serialManager.isConnected
                      || !serialManager.selectedModel.supportsCameraControlUI)

            if serialManager.selectedModel.supportsSerialErase {
                // Routes through the SAME confirmation dialog as the sidebar
                // trash button — every entry point to a destructive action
                // must confirm.
                Button("Erase All Photos…") {
                    serialManager.requestEraseConfirmation()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!serialManager.isConnected || serialManager.isBusy)
            }
        }

        // Gallery thumbnail zoom. Standard image-app shortcuts: ⌘+ / ⌘− to
        // resize, ⌘0 to reset. Writes the shared AppStorage key ContentView
        // reads, so the grid reflows.
        CommandGroup(after: .toolbar) {
            Button("Zoom In") {
                galleryThumbnailWidth = min(ContentView.galleryZoomMax,
                                            galleryThumbnailWidth + ContentView.galleryZoomStep)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(galleryThumbnailWidth >= ContentView.galleryZoomMax)

            Button("Zoom Out") {
                galleryThumbnailWidth = max(ContentView.galleryZoomMin,
                                            galleryThumbnailWidth - ContentView.galleryZoomStep)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(galleryThumbnailWidth <= ContentView.galleryZoomMin)

            Button("Reset Zoom") {
                galleryThumbnailWidth = ContentView.galleryZoomDefault
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("SwiftTake Help") {
                openWindow(id: "helpWindow")
            }
            // The shortcuts catalogue lives in Settings ▸ Shortcuts; this
            // deep-links straight to that pane rather than opening a
            // separate window.
            Button("Keyboard Shortcuts") {
                SettingsDeepLink.requestShortcuts()
                openSettings()
            }
            .keyboardShortcut("/", modifiers: [.command])
        }

        // Demo mode's menu. This SHIPS — it appears only once the user turns
        // Simulator on in Settings ▸ General, and the menu is absent entirely
        // until then, so nobody meets it by accident.
        //
        // A runtime gate rather than a compile-time one, deliberately: the
        // point of demo mode is that a shipped copy can run it.
        if demoModeEnabled {
            SimulatorCommands(serialManager: serialManager)
        }

        // Developer menu. Appears only once Developer Tools is turned on in
        // Settings ▸ General — diagnostics, the session trace, and the
        // toast/dialog test presentations all live here rather than in the
        // Camera or Simulator menus a normal user would browse.
        if developerToolsEnabled {
            DeveloperCommands(serialManager: serialManager)
        }
    }
}

// MARK: - Developer Commands

/// Diagnostics, session trace, and test-presentation menus for internal use.
/// Hidden unless Developer Tools is enabled — see `AppCommands`.
struct DeveloperCommands: Commands {
    @ObservedObject var serialManager: QuickTakeSerialManager

    var body: some Commands {
        CommandMenu("Developer") {
            // Captures the camera's real serial responses into a copy-
            // pasteable report. Works for every family: connected QT100/150
            // and QT200 sessions probe the live link.
            Button("Capture Camera Diagnostics…") {
                serialManager.runCameraDiagnostics()
            }
            .disabled(serialManager.isBusy || !serialManager.isConnected)

            // The session trace records the CONNECT itself, so unlike the
            // diagnostics report above it stays useful when a camera never
            // finished connecting. Always enabled for that reason.
            Button("Save Session Trace…") {
                serialManager.exportSessionTrace()
            }

            Divider()

            // Test presentations. Disabled while the manager is busy so they
            // can't inject a toast or dialog on top of active work.
            Menu("Toast") {
                Button("Something Went Wrong") {
                    serialManager.errorMessage = "The camera stopped responding mid-frame."
                }
                Button("Camera Disconnected") { serialManager.presentToast(.connectionLost) }
                Button("Power Reminder") { serialManager.presentToast(.poweredDownReminder) }
                Button("Clear") {
                    serialManager.errorMessage = nil
                    serialManager.presentToast(nil)
                }
            }
            .disabled(serialManager.isBusy)

            Menu("Dialog") {
                Button("Import Folder Unavailable") {
                    serialManager.destinationFallbackMessage =
                        "“QuickTake Imports” is on a volume that isn’t mounted. Photos will go to your Pictures folder instead."
                }
            }
            .disabled(serialManager.isBusy)
        }
    }
}
