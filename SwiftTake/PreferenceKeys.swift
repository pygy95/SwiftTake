// MARK: - PrefKey
//
// Every UserDefaults / @AppStorage key the app uses, in ONE place.
//
// Why: raw string keys scattered across files force `resetToDefaults()` to
// keep its own hand-typed copy of the list — which is exactly how a key
// gets silently missed by Reset. With the keys
// centralized, a new preference is added HERE, referenced everywhere by
// name, and the compiler catches a typo instead of the user catching a
// half-reset app.
//
// The string values are load-bearing: they're what's already on users'
// disks. Never change a value; only ever add.

import Foundation

nonisolated enum PrefKey {
    // Appearance & onboarding
    static let appTheme            = "appTheme"
    static let hasSeenWelcome      = "hasSeenWelcome"

    // Hardware & connection
    static let selectedModel      = "SelectedQuickTakeModel"
    static let serialBaudRate     = "QuickTakeSerialBaudRate"

    // Import & export
    static let exportFormat              = "QuickTakeExportFormat"
    static let postImportAction          = "QuickTakePostImportAction"
    static let importDestinationBookmark = "PreferredImportDestinationBookmark"
    static let qtkDestinationBookmark    = "PreferredQTKDestinationBookmark"
    static let panoramaDestinationBookmark = "PreferredPanoramaDestinationBookmark"
    static let keepOriginalQTK           = "KeepOriginalQTK"

    // Colour pipeline
    static let newTakeEnabled       = "NewTakeEnabled"

    /// Retired. Was the storage for what is now `newTakeEnabled`, back when
    /// the two looks were called PerfectColor and Enhanced. Kept ONLY so
    /// `migrateLegacyKeys()` can carry an existing setting across once —
    /// nothing reads it as a live preference. PerfectColor is Apple's
    /// trademark and this decoder is a reconstruction rather than that
    /// software, so the name is gone from the app entirely, string literals
    /// included.
    static let legacyPerfectColorEnhanced = "PerfectColorEnhanced"
    static let hdrHeadroom          = "HDRHeadroom"
    static let captureDateStamp     = "CaptureDateStamp"

    // Gallery view
    static let gallerySquareGrid = "gallerySquareGrid"
    static let galleryZoom       = "galleryThumbnailWidth"

    // Sidebar

    // Retired. Gated the experimental Kodak DC40/50/120 serial toggle, from
    // before that whole camera family was removed (no test hardware existed
    // to verify it against). Kept ONLY so `resetToDefaults()` can clear a
    // stale value left on an old install's disk; nothing reads it live.
    static let kodakDCExperimental = "experimentalKodakDCSerial"

    // Cross-session imported-photo recognition (QT200 dedup maps)
    static let fujiImportedPaths = "fujiImportedPaths"
    static let fujiImportedSizes = "fujiImportedSizes"

    // Last QT100/150 identity PROVEN by a wake burst (resolveModel) — the
    // tiebreak when a reconnect misses the burst and the name says nothing.
    static let lastIdentifiedKodakModel = "lastIdentifiedKodakModel"

    // Demo mode: run the app against a simulated QuickTake with no hardware
    // attached. Off by default; turning it on reveals the Simulator menu.
    static let demoModeEnabled = "demoModeEnabled"

    // Developer tools: diagnostics, session trace, and test-presentation
    // menus for internal use. Off by default; turning it on reveals the
    // Developer menu.
    static let developerToolsEnabled = "developerToolsEnabled"

    // Easter-egg progress
    static let collectedStatusColors = "collectedStatusColors"
    static let rainbowUnlocked       = "apertureRainbowUnlocked"
    static let absorbedPhantoms      = "absorbedPhantoms"
    static let phantomSecretUnlocked = "phantomSecretUnlocked"
}
