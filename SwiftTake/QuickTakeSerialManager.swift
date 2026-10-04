import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct CameraMetadata {
    /// Battery charge percent, or `nil` when the camera doesn't report it.
    /// The Fuji family (QT200 / DS-7 / Kenox) has no battery opcode, so it's
    /// genuinely unknown there — `nil` keeps us from showing a false "0%".
    var batteryLevel: Int?
    var picturesTaken: Int
    /// Remaining shots, or `nil` when the camera has no fixed-frame capacity
    /// to report. The Fuji family stores variable-count JPEGs on a card, so
    /// there's no meaningful "frames left" — `nil` avoids a false "Storage
    /// full" / "0 / 0".
    var picturesRemaining: Int?
    var flashMode: String
    var cameraName: String
    var quality: String
    var isHighQuality: Bool
}

/// Coordinates camera sessions, gallery state and import jobs for the UI.
/// Protocol sessions serialize exchanges; extracted components handle rendering,
/// persistence and panorama processing.
@MainActor
final class QuickTakeSerialManager: ObservableObject {
    // Batch-import orchestration policy (duplicate-collision resolution,
    // Keep-Both naming, the archive-vs-rendered naming split, and the finish
    // summary itself) lives in `BatchImportPolicy` — a standalone, camera-free
    // component. See `SwiftTake/BatchImportPolicy.swift`.

    @Published private(set) var isConnected = false
    /// Invalidates view-owned work when the connection or photo slots change.
    @Published private(set) var photoSessionGeneration: UInt64 = 0
    var canDevelopCopland: Bool {
        isConnected && !isBusy && !areThumbnailsLoading && !isProbingLiveness
    }
    @Published private(set) var isConnecting = false
    @Published private(set) var isBusy = false {
        didSet {
            // The instant the link frees up is the only reliable moment to start
            // a deferred import (one the user requested while busy). Many code
            // paths clear `isBusy` directly, so observing the property catches
            // them all.
            if oldValue && !isBusy { runPendingImportIfNeeded() }
        }
    }
    /// A camera-info refresh (metadata + thumbnails) is in progress. Drives the
    /// Refresh button's live spinner and guards against re-entrant refreshes.
    @Published private(set) var isRefreshing = false
    /// An import the user requested while the link was busy (loading thumbnails
    /// or refreshing). It runs automatically once the camera is free, so the
    /// Import button is never a dead end.
    private var pendingImport: (importAll: Bool, skipImported: Bool)?
    @Published private(set) var detectedPortPath: String?
    @Published private(set) var metadata: CameraMetadata?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewedPhotoIndex: UInt8?
    @Published private(set) var downloadProgress: Double = 0
    @Published private var cameraTransfers: [PhotoTransfer] = []
    @Published private var droppedTransfers: [PhotoTransfer] = []
    var photoTransfers: [PhotoTransfer] { cameraTransfers + droppedTransfers }
    private var dropConversionActive = false
    private var dropConversionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Per-tick progress lives here, NOT in the array above — a `let` box
    /// (never republished) whose writes bypass objectWillChange entirely.
    /// See TransferProgressStore.
    let liveProgress = TransferProgressStore()
    @Published private(set) var lastImportDestination: URL?
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    /// Full explanation shown in a dedicated warning ALERT (not the short status
    /// pill) when an import had to fall back from the chosen destination to the
    /// default — e.g. a disconnected drive. Non-nil = the alert is shown; the UI
    /// clears it on dismiss. Kept separate from `errorMessage` so a successful
    /// import's `finishBatchImport` can't wipe it before the user sees it.
    @Published var destinationFallbackMessage: String?

    // MARK: Banner toasts
    //
    // The app shows at most one banner at a time, the way macOS itself
    // coalesces notifications. These three flags drive the connection-
    // related banners; `errorMessage` drives a fourth (red) one. The
    // UI renders whichever single banner has the highest priority, and
    // `presentToast(_:)` below ensures only one of these flags is ever
    // set so they can't pile up (e.g. a double banner on disconnect).

    /// Gentle reminder, shown after the user disconnects, to power the
    /// camera off so it doesn't drain its batteries.
    @Published var showPowerTip = false

    /// Shown when the connection drops on its own (cable pulled, camera
    /// powered off, adapter unplugged).
    @Published var showConnectionAlert = false

    /// Surfaced when the connected camera reports a different model
    /// than the one selected in Settings → Hardware. Lets the user keep
    /// their choice (e.g. for testing) while giving a clear nudge.
    @Published var showModelMismatch = false
    @Published var detectedModelName: String? = nil

    /// Drives the themed "Which camera is this?" prompt. Non-nil holds the
    /// candidate models to offer; set during auto-detection when the model
    /// can't be pinned automatically. See `beginCameraSelection`.
    @Published var pendingCameraSelection: [QuickTakeModel]? = nil
    /// The family whose session is held open behind an ambiguous prompt
    /// (nil when the prompt is a manual chooser with no live session).
    private var pendingProbeFamily: QuickTakeProtocolFamily? = nil
    private var pendingProbePath: String? = nil

    /// Non-nil holds the latest diagnostic capture, shown in a copy-pasteable
    /// sheet. See `runCameraDiagnostics`.
    @Published var diagnosticsReport: String? = nil
    /// True while a capture is in flight — drives the immediate "Capturing…"
    /// popup so the sheet appears the moment the user runs diagnostics, then
    /// fills in with the report.
    @Published var isCapturingDiagnostics = false
    /// Camera name to title the diagnostics sheet (per-family, not hardcoded).
    @Published var diagnosticsCameraName: String? = nil
    @Published var countdownTimer: Int? = nil
    @Published var isCameraControlPoppedOut = false
    @Published private(set) var captureProgress: Double? = nil
    private var statusRevertTask: Task<Void, Never>?

    @Published var selectedModel: QuickTakeModel {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: PrefKey.selectedModel)
        }
    }
    @Published var exportFormat: QuickTakeExportFormat {
        didSet {
            UserDefaults.standard.set(exportFormat.rawValue, forKey: PrefKey.exportFormat)
        }
    }

    @Published private(set) var photoIndices: [UInt8] = []
    @Published var availableThumbnails: [UInt8: NSImage] = [:]
    @Published private(set) var enhancedPreviewImages: [UInt8: NSImage] = [:]
    @Published var selectedPhotoIndices: Set<UInt8> = []
    @Published private(set) var importedPhotoURLs: [UInt8: [URL]] = [:]
    /// USER renames only. The gallery caption is the uniform "Photo N" on
    /// every camera unless the user renames a photo here.
    @Published var photoNames: [UInt8: String] = [:]
    /// Camera-reported filenames (the QT200's DSC stems) — kept INTERNAL.
    /// They key the cross-session imported-photo maps and serve as a
    /// last-resort naming fallback, but are never displayed: DSC names
    /// repeat across cameras and read as noise.
    private var fujiCameraNames: [UInt8: String] = [:]
    @Published private(set) var photoQualities: [UInt8: Bool] = [:]
    @Published private(set) var areThumbnailsLoading = false
    /// Live "N of M" while the connected camera's thumbnails stream in —
    /// drives the non-blocking bottom loading bar (the UI stays free during
    /// the fetch; this is the "something's happening" signal). nil when idle.
    @Published private(set) var thumbnailLoadProgress: (loaded: Int, total: Int)?

    /// Identity ("model|name") of the camera behind the gallery currently on
    /// screen. The index-keyed gallery is kept after disconnect for offline
    /// viewing, so on the next connect we compare identities: a DIFFERENT camera
    /// clears the stale gallery (otherwise its photos would clash with the new
    /// camera's indices), while the SAME camera keeps it (preserving manual
    /// renames) and just refreshes in place. Nil until the first connect.
    private var lastConnectedCameraIdentity: String?

    /// Set for the FIRST thumbnail fetch after a DIFFERENT camera connects, so the
    /// cross-session "already imported" recognition (disk matches by DSC name /
    /// EXIF-date filename) is suppressed. Two different cameras share those names
    /// (e.g. two QT200s both number photos DSC00001…), so trusting the match would
    /// wrongly skip / mis-preview the new camera's photos. The SAME camera keeps
    /// recognition. NOTE: two cameras with the SAME name are indistinguishable over
    /// serial, so this can't tell them apart — give them different names to fix that.
    private var suppressImportedRecognition = false

    /// Cache of downloaded Fuji/QT200 JPEG bytes, keyed by gallery index. The
    /// QT200 has no cheap thumbnail opcode, so the first download of a photo
    /// (preview or import) is reused both to render a real gallery thumbnail
    /// and to avoid a second ~87KB transfer at import time.
    private var fujiJPEGCache: [UInt8: [UInt8]] = [:]

    @Published var shouldRequestImport = false
    @AppStorage(PrefKey.keepOriginalQTK) var keepOriginalQTK = false

    /// When true, layers a post-process on top of the Kodak colour science:
    /// shadows lift, clarity, sharpen, saturation — and, on HEIC, keeps the
    /// highlights it pushes above white so they land in HDR headroom.
    ///
    /// (This used to claim MHC demosaic and chromatic smoothing. Both went
    /// with the Swift-dcraw retirement: MHC was deleted outright, and the
    /// chroma median runs for BOTH looks, not just this one.)
    /// When false, the decoder reproduces the vintage Apple/Kodak software's
    /// output as faithfully as possible.
    /// Default is `true`; the enhanced look is generally preferable, so turn
    /// it off only when targeting the authentic era look.
    @AppStorage(PrefKey.newTakeEnabled) var newTakeEnabled = true

    /// When true, the decoder renders to Float16 RGBA in extended-linear-sRGB
    /// so highlights map into the EDR headroom on Liquid Retina / XDR displays.
    /// Color science is unchanged — this is purely a presentation upgrade.
    /// Not a setting of its own. HDR is part of what NewTake MEANS: the
    /// look that lifts shadows and adds local contrast is also the one that
    /// pushes highlights above white, so it is the look with something to
    /// put in the headroom. Vintage is faithfulness to a 1995 SDR render;
    /// extending that into EDR is anachronistic, and measures as the
    /// weakest case anyway — roughly half the above-white content Enhanced
    /// produces.
    ///
    /// The decoder still supports all four look/range combinations and the
    /// harness still guards them. That independence is correctness. This
    /// property is the product decision layered on top, in ONE place: the
    /// rule used to be spelled out at four call sites, and four copies of a
    /// condition drifting apart is exactly the bug this branch fixed.
    var hdrOutputActive: Bool {
        newTakeEnabled && exportFormat == .heic
    }

    /// The Look, snapshotted as a value so it can cross into the detached
    /// decode tasks the import loop uses.
    var finishedLook: FinishedLookSettings {
        FinishedLookSettings(enhanced: newTakeEnabled,
                             hdr: hdrOutputActive,
                             headroom: hdrHeadroom)
    }

    /// Apply the Look to an already-finished image — the QT200 family,
    /// whose JPEGs arrive from the camera fully rendered.
    ///
    /// Adapter kept on the manager because the import and panorama paths
    /// call it as `QuickTakeSerialManager.applyFinishedLook`. The
    /// implementation lives with the rest of the finished-JPEG rendering in
    /// `CameraImageRenderer`.
    nonisolated static func applyFinishedLook(
        _ image: NSImage?, _ look: FinishedLookSettings
    ) -> NSImage? {
        CameraImageRenderer.applyFinishedLook(image, look)
    }

    /// HDR headroom multiplier. 1.0 = SDR-equivalent peak (white at 1.0).
    /// 1.5 = ~1.7 stops of headroom for highlights (typical Liquid Retina).
    /// 2.0 = aggressive — pushes specular highlights well into HDR range.
    /// Honored only when `hdrOutputActive` is true.
    @AppStorage(PrefKey.hdrHeadroom) var hdrHeadroom: Double = 1.5

    /// Optional 1990s-style date stamp burned into the bottom-right
    /// corner of the rendered image just before export — a deliberate
    /// nostalgia toggle, off by default. Pulls the timestamp from the
    /// QTK header (or falls back to the file's modification date when
    /// the camera didn't record one).
    @AppStorage(PrefKey.captureDateStamp) var captureDateStampEnabled: Bool = false

    /// Whether the SELECTED model can be connected over serial right now.
    /// Every shipping model's protocol is implemented, so this is currently
    /// always true — kept as its own property (rather than every call site
    /// reading `serialProtocolImplemented` directly) so the Connect
    /// affordances and `connectToDetectedCamera()`'s entry guard read THE
    /// SAME gate and can never disagree if a future model ships unverified.
    var selectedModelSerialAvailable: Bool {
        selectedModel.serialProtocolImplemented
    }

    // No per-camera EEPROM color matrix exists on the wire: every
    // QuickTake 100/150 uses the same Kodak factory matrix, so
    // `kodakDefaultRGBCam` is correct for every unit.

    @Published private(set) var preferredImportDestinationURL: URL?
    /// User override for where original `.qtk` archives are written when
    /// "Keep Original Files" is on. Defaults to a `QTK` sub-folder
    /// alongside the photo import folder so the originals stay grouped
    /// with their decoded versions but don't clutter the same listing.
    @Published private(set) var preferredQTKDestinationURL: URL?
    @Published private(set) var preferredPanoramaDestinationURL: URL?
    @Published var selectedBaudRate: SerialBaudRate {
        didSet {
            UserDefaults.standard.set(selectedBaudRate.rawValue, forKey: PrefKey.serialBaudRate)
        }
    }
    @Published var selectedPostImportAction: PostImportAction {
        didSet {
            UserDefaults.standard.set(selectedPostImportAction.rawValue, forKey: PrefKey.postImportAction)
        }
    }

    // Two parallel sessions over the generic SerialPort — one per protocol
    // family — chosen by `selectedModel.protocolFamily` at every call site.
    // The `.kodak` session is the QT100/150 workhorse; the `.fuji` session
    // serves QT200 / Fujifilm DS-7 / Samsung Kenox SSC-350N.
    private let cameraWork = CameraWork()
    private var sessionTeardown: Task<Void, Never>?
    private var cameraImportActive = false

    func cameraTransfer(for index: UInt8) -> PhotoTransfer? {
        cameraTransfers.first { $0.index == index }
    }
    private let session = QuickTakeCameraSession()
    private let fujiSession = FujiCameraSession()

    /// Import / QTK destination bookmark persistence, legacy-key migration,
    /// and the pre-write "still usable?" check. See `DestinationBookmarkStore`.
    private let destinationStore = DestinationBookmarkStore()
    /// Cross-session record of already-imported QT200 photos (DSC name → path
    /// and size). See `FujiImportLedger`.
    private let fujiLedger = FujiImportLedger()

    // Preference keys live in PrefKey (PreferenceKeys.swift) — one list,
    // so resetToDefaults() can never miss one again.
    private var systemProgress: Progress?
    /// Background liveness poll (async loop, not a Combine timer — house style
    /// prefers async/await over Combine). `.cancel()` / `= nil` still apply.
    private var connectionTimer: Task<Void, Never>?

    /// True only while the liveness monitor's ENQ probe is in flight. The monitor
    /// skips probing when `isBusy`, but an import could still START in the
    /// sub-second window after the probe's first `await` (actor reentrancy would
    /// then interleave its frames with the probe's ENQ). The import path checks
    /// this flag and defers; the monitor sets it synchronously — with no `await`
    /// between the `isBusy` check and the set — so it's atomic vs. an import's
    /// own synchronous prologue. Not `@Published`; it drives no UI.
    private var isProbingLiveness = false

    /// Don't ask the camera if it's alive before this moment.
    ///
    /// Taking a picture or erasing the card leaves a QuickTake writing to
    /// flash with nothing left over to answer an ENQ. The liveness poll
    /// would then find silence and call it a dead link — which is what a
    /// QuickTake 150 dropping "on taking a photo" actually is. The camera
    /// was never gone; it was busy, and we asked at the worst moment.
    ///
    /// A window rather than a flag, because the work continues after the
    /// command returns: the shutter ACK comes back long before the picture
    /// is on the card.
    private var quietUntil: Date?

    /// Give the camera room after something slow, and stop the poll
    /// treating that room as silence.
    private func invalidateCameraWork() {
        photoSessionGeneration &+= 1
        cameraWork.invalidate()
        cameraImportActive = false
        connectionTimer?.cancel()
        statusRevertTask?.cancel()
        pendingImport = nil
        isRefreshing = false
        isConnecting = false
        isCapturingDiagnostics = false
        areThumbnailsLoading = false
        thumbnailLoadProgress = nil
        captureProgress = nil
        countdownTimer = nil
        isProbingLiveness = false
        panoramaTask?.cancel()
        panoramaGeneration += 1
        panoramaRetryInput = nil
        canRetryQuickPan = false
        panoramaQuickPanStops = 16
        if let prompt = duplicatePrompt { prompt.resolve(.stop) }
        for i in cameraTransfers.indices where cameraTransfers[i].progress < 1 {
            cameraTransfers[i].status = .cancelled
        }
        let cancelledIDs = Set(cameraTransfers.map(\.id))
        if !cancelledIDs.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self else { return }
                for id in cancelledIDs { self.liveProgress.values.removeValue(forKey: id) }
                self.cameraTransfers.removeAll { cancelledIDs.contains($0.id) }
            }
        }
        systemProgress?.unpublish()
        systemProgress = nil
        clearDockBadge()
    }

    private func holdOffLivenessProbe(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if let existing = quietUntil, existing > until { return }
        quietUntil = until
    }

    init() {
        DestinationBookmarkStore.migrateLegacyKeys()
        if let modelStr = UserDefaults.standard.string(forKey: PrefKey.selectedModel),
           let quickTakeModel = QuickTakeModel(rawValue: modelStr) {
            self.selectedModel = quickTakeModel
        } else {
            self.selectedModel = .qt150
        }

        if let formatRawValue = UserDefaults.standard.string(forKey: PrefKey.exportFormat),
           let exportFormat = QuickTakeExportFormat(rawValue: formatRawValue) {
            self.exportFormat = exportFormat
        } else {
            self.exportFormat = .tiff
        }

        if let baudRateRawValue = UserDefaults.standard.string(forKey: PrefKey.serialBaudRate),
           let baudRate = SerialBaudRate(rawValue: baudRateRawValue) {
            self.selectedBaudRate = baudRate
        } else {
            self.selectedBaudRate = .bps57600
        }

        if let postImportActionRawValue = UserDefaults.standard.string(forKey: PrefKey.postImportAction),
           let postImportAction = PostImportAction(rawValue: postImportActionRawValue) {
            self.selectedPostImportAction = postImportAction
        } else {
            self.selectedPostImportAction = .doNothing
        }

        self.preferredImportDestinationURL = destinationStore.resolvedDestination(.importDestination)
        self.preferredQTKDestinationURL    = destinationStore.resolvedDestination(.qtk)
        self.preferredPanoramaDestinationURL = destinationStore.resolvedDestination(.panorama)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

    }

    deinit {
        let captureSession = session
        let captureFujiSession = fujiSession
        Task {
            await captureSession.disconnect()
            await captureFujiSession.disconnect()
        }
    }

    var totalPictureCapacity: Int {
        (metadata?.picturesTaken ?? 0) + (metadata?.picturesRemaining ?? 0)
    }

    /// True when the camera reports a fixed frame capacity (QT100/150) rather
    /// than card-backed variable storage (Fuji family). Drives whether the UI
    /// shows "taken / capacity" or a plain count.
    var hasFixedFrameCapacity: Bool {
        metadata?.picturesRemaining != nil
    }

    var effectiveImportDestinationURL: URL {
        destinationStore.effectiveImportDestination(preferred: preferredImportDestinationURL)
    }

    var effectiveImportDestinationDisplayName: String {
        DestinationBookmarkStore.displayName(for: effectiveImportDestinationURL)
    }

    /// True when a **custom** import destination is set but isn't currently
    /// reachable (e.g. a disconnected USB drive). Settings surfaces this so the
    /// path shown doesn't silently lie — imports fall back to the default until
    /// it's back (see `usableImportDestination`). Cheap enough for Settings; not
    /// `@Published`, so it re-checks whenever the view re-renders.
    var importDestinationIsUnreachable: Bool {
        destinationStore.isUnreachable(preferred: preferredImportDestinationURL)
    }

    /// Where original `.qtk` files are written. Falls back to a `QTK`
    /// sub-folder of the photo destination so originals are grouped
    /// with their decoded counterparts but don't clutter the same
    /// listing. The folder is created on demand when a save runs.
    var effectiveQTKDestinationURL: URL {
        destinationStore.effectiveQTKDestination(preferredQTK: preferredQTKDestinationURL,
                                                 effectiveImport: effectiveImportDestinationURL)
    }

    var effectiveQTKDestinationDisplayName: String {
        DestinationBookmarkStore.displayName(for: effectiveQTKDestinationURL)
    }

    /// True when the QTK destination is the auto-derived "QTK" sub-folder
    /// of the photo destination (rather than a user-picked override).
    /// Used by Settings to show "Use Default" only when meaningful.
    var qtkDestinationIsDefault: Bool {
        preferredQTKDestinationURL == nil
    }

    var effectivePanoramaDestinationURL: URL {
        destinationStore.effectivePanoramaDestination(preferred: preferredPanoramaDestinationURL,
                                                      effectiveImport: effectiveImportDestinationURL)
    }

    var panoramaDestinationIsDefault: Bool {
        !destinationStore.hasSavedDestination(.panorama)
    }

    var panoramaDestinationIsUnreachable: Bool {
        (!panoramaDestinationIsDefault && preferredPanoramaDestinationURL == nil)
            || destinationStore.isUnreachable(preferred: preferredPanoramaDestinationURL)
    }

    var effectivePanoramaDestinationDisplayName: String {
        if !panoramaDestinationIsDefault && preferredPanoramaDestinationURL == nil { return "Unavailable" }
        return DestinationBookmarkStore.displayName(for: effectivePanoramaDestinationURL)
    }

    var batteryWarning: String? {
        // `nil` battery means the camera doesn't report it (Fuji family) —
        // unknown, not empty. Don't raise a false "Critical Battery".
        guard let batteryLevel = metadata?.batteryLevel else { return nil }
        if batteryLevel <= 10 { return "Critical Battery" }
        if batteryLevel <= 25 { return "Low Battery" }
        return nil
    }

    var storageWarning: String? {
        // `nil` remaining means variable card storage with no reported
        // "frames left" (Fuji family) — don't claim the card is full.
        guard let picturesRemaining = metadata?.picturesRemaining else { return nil }
        if picturesRemaining == 0 { return "Storage full" }
        if picturesRemaining <= 5 { return "Only \(picturesRemaining) left" }
        return nil
    }

    @discardableResult
    func setPreferredImportDestination(_ url: URL) -> Bool {
        // The store handles the bookmark and the "picked folder won't take a
        // bookmark — use a SwiftTake sub-folder" fallback; the manager only
        // mirrors the resulting URL and phrases the notice.
        switch destinationStore.setImportDestination(url) {
        case .saved(let saved):
            preferredImportDestinationURL = saved
            return true
        case .savedInSubfolder(let sub, let parent):
            preferredImportDestinationURL = sub
            statusMessage = "Saving to \(parent.lastPathComponent)"
            scheduleStatusRevert()
            return true
        case .failed:
            errorMessage = "Couldn’t use that folder. It may be read-only or a format macOS can’t bookmark — try a different location."
            return false
        }
    }

    func clearPreferredImportDestination() {
        destinationStore.clear(.importDestination)
        preferredImportDestinationURL = nil
    }

    @discardableResult
    func setPreferredQTKDestination(_ url: URL) -> Bool {
        if destinationStore.makeBookmark(for: url, slot: .qtk) {
            preferredQTKDestinationURL = url
            return true
        }
        errorMessage = "Couldn't save that folder. Try choosing it again."
        return false
    }

    func clearPreferredQTKDestination() {
        destinationStore.clear(.qtk)
        preferredQTKDestinationURL = nil
    }

    @discardableResult
    func setPreferredPanoramaDestination(_ url: URL) -> Bool {
        if destinationStore.makeBookmark(for: url, slot: .panorama) {
            preferredPanoramaDestinationURL = url
            return true
        }
        errorMessage = "Couldn't save that folder. Try choosing it again."
        return false
    }

    func clearPreferredPanoramaDestination() {
        destinationStore.clear(.panorama)
        preferredPanoramaDestinationURL = nil
    }

    /// Make sure we have a writable destination before an import begins. A saved
    /// folder can disappear between launches — the user moved or trashed it, or it
    /// lived on an external drive that's now unplugged. The bookmark still resolves
    /// to a (now dead) path, so without this every photo would fail with a generic
    /// save error. The store tries to (re)create the folder inside its security
    /// scope; if that's not possible it reports a fall back to the default
    /// `Pictures/SwiftTake` and the manager tells the user once.
    private func usableImportDestination(_ requested: URL) -> URL {
        switch destinationStore.usableImportDestination(requested) {
        case .ok(let url):
            return url
        case .fellBack(let fallback, let notify):
            guard notify else { return fallback }
            // Chosen folder is unavailable — fall back to the default. Show the
            // full explanation in a dedicated ALERT (the status pill is too small
            // to read a long sentence), and keep the pill short.
            statusMessage = "Saved to “\(fallback.lastPathComponent)”"
            destinationFallbackMessage = "It may have been moved, or it’s on a drive that isn’t connected. Your photos were saved to “\(fallback.lastPathComponent)” instead.\n\nReconnect the drive, or choose a new folder in Settings."
            return fallback
        }
    }

    // MARK: - Moof! easter egg

    /// SwiftTake can't print — Cmd+P instead summons Clarus the Dogcow over the
    /// canvas. This drives that overlay.
    @Published var showMoof = false
    /// Retained so playback isn't cut short when the call returns.
    private var moofSound: NSSound?

    /// Cmd+P: there's no printer here, so bark a "Moof!" and show Clarus.
    func triggerMoof() {
        if let url = Bundle.main.url(forResource: "moof", withExtension: "m4a") {
            moofSound = NSSound(contentsOf: url, byReference: true)
            moofSound?.play()
        }
        showMoof = true
    }

    func dismissMoof() {
        showMoof = false
    }

    // MARK: - Phantom .qtk easter egg

    /// One of the three magic "planet" photos.
    enum PhantomEgg: String, CaseIterable {
        case venus, mars, neptune
        var asset: String {
            switch self {
            case .venus:   return "EasterEggQT100"
            case .mars:    return "EasterEggQT150"
            case .neptune: return "EasterEggQT200"
            }
        }
        var model: QuickTakeModel {
            switch self {
            case .venus:   return .qt100
            case .mars:    return .qt150
            case .neptune: return .qt200
            }
        }
    }

    /// The phantom photo currently taking over the canvas (nil = none). Drives
    /// the full-window overlay in ContentView.
    @Published var phantomEgg: PhantomEgg?

    /// Which planets have been absorbed into the aperture (persisted). Each can
    /// only be absorbed once; collecting all three unlocks a further secret.
    @AppStorage(PrefKey.absorbedPhantoms) private var absorbedPhantomsRaw = ""
    /// Set once all three phantom photos have been absorbed.
    @AppStorage(PrefKey.phantomSecretUnlocked) private(set) var phantomSecretUnlocked = false

    var absorbedPhantoms: Set<String> {
        Set(absorbedPhantomsRaw.split(separator: ",").map(String.init))
    }

    func isPhantomAbsorbed(_ egg: PhantomEgg) -> Bool {
        absorbedPhantoms.contains(egg.rawValue)
    }

    /// True once all three phantoms are absorbed — this only ARMS the secret; the
    /// actual unlock needs a 7-click wink on the aperture (mirrors the status-orb
    /// track: collect 3 → wink to unlock).
    var allPhantomsAbsorbed: Bool {
        absorbedPhantoms.isSuperset(of: PhantomEgg.allCases.map(\.rawValue))
    }

    /// Records a phantom as absorbed. Does NOT unlock the secret — see `unlockPhantomSecret`.
    func markPhantomAbsorbed(_ egg: PhantomEgg) {
        var set = absorbedPhantoms
        set.insert(egg.rawValue)
        absorbedPhantomsRaw = set.sorted().joined(separator: ",")
        objectWillChange.send()
    }

    /// Flips the phantom secret on — called by the aperture's 7-click wink once
    /// all three phantoms are absorbed.
    func unlockPhantomSecret() {
        guard allPhantomsAbsorbed else { return }
        objectWillChange.send()
        phantomSecretUnlocked = true
    }

    func dismissPhantom() { phantomEgg = nil }

    /// Copland easter egg: register the baked Mac OS 9 framed file as one of this
    /// photo's saved files. Its `copland` name is the "developed" marker.
    func registerCoplandFile(_ url: URL, for index: UInt8) {
        // A develop leaves ONLY the copland file: the import that
        // fed it was a means to an end, so its export — and any older
        // copland — comes off the disk here. The `.qtk` archive survives:
        // it's the re-decodable original, and the way the photo can be
        // re-imported normally later. Caller (saveCoplandImage) still holds
        // the destination's security scope for the deletions.
        var kept = (importedPhotoURLs[index] ?? []).filter { existing in
            if existing == url { return false }   // re-appended below
            if existing.pathExtension.lowercased() == "qtk" { return true }
            try? FileManager.default.removeItem(at: existing)
            return false
        }
        kept.append(url)
        importedPhotoURLs[index] = kept
    }

    /// Copland easter egg: write the rendered Mac OS 9 framed PNG into the real
    /// import-destination folder (with sandbox access), so even a simulated photo
    /// produces a genuine file on disk to open/test. Overwrites silently — no
    /// prompt — then registers it as the photo's `_copland` file. Returns the URL.
    @discardableResult
    func saveCoplandImage(_ data: Data, baseName: String, for index: UInt8) -> URL? {
        let destination = effectiveImportDestinationURL
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }
        // The copland file carries the CLEAN stem — mode tags stripped — so
        // it reads "<Model>_<date>_<NNN>_copland.png" no matter which
        // pipeline rendered the underlying photo.
        let url = destination.appendingPathComponent("\(stripModeTag(from: baseName))_copland.png")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)   // silent overwrite
        } catch {
            return nil
        }
        registerCoplandFile(url, for: index)
        return url
    }

    /// Dropping a `.qtk` file named venus / mars / neptune "decodes" to a
    /// preloaded image for the matching QuickTake. Returns true if a magic name
    /// matched (the photo then takes over the canvas with a fizzle build-in).
    @discardableResult
    func loadPhantomQTK(named stem: String) -> Bool {
        guard let egg = PhantomEgg(rawValue: stem.lowercased()),
              NSImage(named: egg.asset) != nil else {
            return false
        }
        // Presentation only: the planet's camera must never replace the live
        // session's model (or its persisted preference), even while connecting.
        phantomEgg = egg
        return true
    }

    // (The Newton easter egg lives entirely in the Help window — click "Apple
    // Newton" in the QuickTake 100/150 wiring note. No manager state needed.)

    /// Stable id for the connection-status colour, shared by the sidebar status
    /// bubble and the Settings status card so they always agree.
    var statusColorID: String {
        if errorMessage != nil { return "red" }
        if isBusy || isConnecting { return "orange" }
        if !isConnected { return "orange" }
        if isConnected && metadata == nil { return "orange" }
        return "green"
    }

    /// The connection-status colour: green (ready), orange (disconnected /
    /// connecting / busy / warming up), red (error).
    var statusIndicatorColor: Color {
        switch statusColorID {
        case "red": return .red
        case "orange": return .orange
        default: return .green
        }
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: PrefKey.selectedModel)
        UserDefaults.standard.removeObject(forKey: PrefKey.exportFormat)
        UserDefaults.standard.removeObject(forKey: PrefKey.importDestinationBookmark)
        UserDefaults.standard.removeObject(forKey: PrefKey.qtkDestinationBookmark)
        UserDefaults.standard.removeObject(forKey: PrefKey.panoramaDestinationBookmark)
        UserDefaults.standard.removeObject(forKey: PrefKey.serialBaudRate)
        UserDefaults.standard.removeObject(forKey: PrefKey.postImportAction)
        UserDefaults.standard.removeObject(forKey: PrefKey.keepOriginalQTK)
        UserDefaults.standard.removeObject(forKey: PrefKey.hasSeenWelcome)
        UserDefaults.standard.removeObject(forKey: PrefKey.appTheme)
        // Image settings (Settings → Image).
        UserDefaults.standard.removeObject(forKey: PrefKey.newTakeEnabled)
        UserDefaults.standard.removeObject(forKey: PrefKey.hdrHeadroom)
        UserDefaults.standard.removeObject(forKey: PrefKey.captureDateStamp)
        // Retired key (the DC-serial gate is now model selection itself) —
        // still cleaned here so an install that once set it doesn't carry a
        // stale key forever.
        UserDefaults.standard.removeObject(forKey: PrefKey.kodakDCExperimental)
        UserDefaults.standard.removeObject(forKey: PrefKey.lastIdentifiedKodakModel)
        // Gallery view preferences (owned by ContentView's @AppStorage — clearing
        // the keys snaps those views back to their defaults via UserDefaults KVO).
        UserDefaults.standard.removeObject(forKey: PrefKey.gallerySquareGrid)
        UserDefaults.standard.removeObject(forKey: PrefKey.galleryZoom)
        // Cached data.
        UserDefaults.standard.removeObject(forKey: PrefKey.fujiImportedPaths)
        UserDefaults.standard.removeObject(forKey: PrefKey.fujiImportedSizes)
        // Hidden easter-egg progress — a full reset clears ALL of it (colour
        // collection + rainbow unlock + phantom unlock), per the dialog's
        // "clear all cached data" promise. Wiping only some left an inconsistent
        // half-state (rainbow gone but phantom still unlocked).
        UserDefaults.standard.removeObject(forKey: PrefKey.collectedStatusColors)
        UserDefaults.standard.removeObject(forKey: PrefKey.rainbowUnlocked)
        UserDefaults.standard.removeObject(forKey: PrefKey.absorbedPhantoms)
        UserDefaults.standard.removeObject(forKey: PrefKey.phantomSecretUnlocked)
        UserDefaults.standard.removeObject(forKey: PrefKey.developerToolsEnabled)

        selectedModel = .qt150
        exportFormat = .tiff
        selectedBaudRate = .bps57600
        selectedPostImportAction = .doNothing
        keepOriginalQTK = false
        newTakeEnabled = true
        hdrHeadroom = 1.5
        captureDateStampEnabled = false
        preferredImportDestinationURL = nil
        preferredQTKDestinationURL = nil
        preferredPanoramaDestinationURL = nil
        // Mirror the egg-state defaults on the in-memory @AppStorage properties so
        // the live UI (gilded aperture, Classic-theme availability) updates at once.
        absorbedPhantomsRaw = ""
        phantomSecretUnlocked = false
    }

    func detectSerialPort(userInitiated: Bool = false) {
        // A scan says nothing about a camera that is already connected, and
        // it must not talk over one. In demo mode there is no adapter to
        // find, so a scan reported "Connect Camera to Begin" next to a
        // green dot while a camera sat connected in the sidebar — and the
        // scan re-runs on things as innocent as changing the theme, which
        // is how the desync showed up. A real camera on a real port had the
        // same hole; it was just harder to notice.
        if isConnected { return }
        setBusy(true, status: "Scanning for Serial Devices…")
        Task {
            let path = SerialPortFinder.bestCandidate()
            self.detectedPortPath = path
            self.isBusy = false

            if path != nil {
                self.statusMessage = "Adapter Found"
                self.errorMessage = nil
            } else {
                self.statusMessage = userInitiated ? "Camera Not Found" : "Connect Camera to Begin"
                self.errorMessage = userInitiated ? "Check your connection and ensure the camera is powered on." : nil
            }
        }
    }

    // MARK: - Auto-detection
    //
    // Pressing Connect no longer trusts the Settings model blindly. It
    // probes each protocol family's handshake (Kodak 8N1 wake vs Fuji 8E1
    // ENQ), and whichever the camera answers tells us the family. We then
    // read the camera's self-reported name to pin the exact model. When the
    // name doesn't disambiguate within a family (e.g. a Fuji that just says
    // "DS-7" when it could be a QT200 / DS-7 / Kenox), we ask the user with
    // a themed prompt instead of guessing.

    /// Families auto-detect may probe.
    private static let probeFamilies: [QuickTakeProtocolFamily] = [.kodak, .fuji]

    /// Implemented models, grouped for the "Which camera?" prompt.
    static func implementedModels(in family: QuickTakeProtocolFamily) -> [QuickTakeModel] {
        QuickTakeModel.allCases.filter { $0.protocolFamily == family && $0.serialProtocolImplemented }
    }
    static var allImplementedModels: [QuickTakeModel] {
        QuickTakeModel.allCases.filter { $0.serialProtocolImplemented }
    }
    /// One representative model per implemented protocol family, for the
    /// "couldn't detect anything" manual chooser — so the user picks a FAMILY
    /// (Apple QuickTake 100/150 vs QuickTake 200), not a flat list of every
    /// model and rebadged sibling. The exact model is then pinned by
    /// `resolveModel` once a connection is made.
    static var familyRepresentatives: [QuickTakeModel] {
        var reps: [QuickTakeModel] = []
        for family in probeFamilies {   // implemented, probeable families only
            if let rep = implementedModels(in: family).first { reps.append(rep) }
        }
        return reps
    }

    func connectToDetectedCamera() {
        // Each connect attempt gets its own trace: a failure's evidence
        // must not be buried under the session that preceded it.
        QTLog.begin("CONNECT ATTEMPT · Settings model: \(selectedModel.displayName)")
        // QT100/150/200 always pass this guard.
        guard selectedModelSerialAvailable else {
            QTLog.note("CONNECT", "selected model has no serial implementation")
            QTLog.flush()
            self.isBusy = false
            self.isConnecting = false
            self.isConnected = false
            self.statusMessage = "\(selectedModel.displayName) Is in Beta"
            self.errorMessage = "Serial support for the \(selectedModel.displayName) isn't available yet. Pick a different model in Settings ▸ Hardware."
            return
        }

        invalidateCameraWork()
        setBusy(true, status: "Detecting Camera…")
        self.isConnecting = true
        // Cancel any previously-running monitor before tearing down the
        // session. Without this, a leftover timer from an earlier
        // connection keeps polling the about-to-close port every 10s
        // and races with the new connect — visible as spurious
        // "Camera Disconnected" toasts when the user reconnects after
        // a failed handshake.
        self.connectionTimer?.cancel()
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            await sessionTeardown?.value
            guard !Task.isCancelled else { return }
            let path = SerialPortFinder.bestCandidate() ?? self.detectedPortPath
            guard let path else {
                QTLog.note("CONNECT", "no serial adapter found")
                QTLog.flush()
                self.isBusy = false
                self.isConnecting = false
                self.isConnected = false
                self.statusMessage = "No Adapter Found"
                self.errorMessage = "Connect a supported USB-to-serial adapter, then try again."
                return
            }

            // Tear both sessions down before reopening — either could hold
            // a stale port from a previous connection.
            await session.disconnect()
            guard cameraWork.isCurrent(workGeneration) else { return }
            await fujiSession.disconnect()
            guard cameraWork.isCurrent(workGeneration) else { return }

            // Probe for the camera, passive-first (see
            // orderedProbeFamilies). The first family that handshakes
            // leaves its session open.
            var detectedFamily: QuickTakeProtocolFamily? = nil
            for family in orderedProbeFamilies() {
                if await probeHandshake(family: family, path: path) {
                    detectedFamily = family
                    break
                }
            }
            guard cameraWork.isCurrent(workGeneration) else { return }
            // Second chance for an ALREADY-AWAKE QT100/150: a camera
            // woken by an earlier probe or a failed connect never
            // re-emits its one wake burst, so the burst-gated Kodak
            // probe above is blind to it — even though it answers the
            // handshake fine. Reopen fresh (the Fuji probe may have
            // left line state behind) and handshake with the ping
            // reply as the existence gate.
            if detectedFamily == nil {
                let opened = await session.open(path: path)
                guard cameraWork.isCurrent(workGeneration) else { return }
                if opened {
                    let speed: QuickTakeCameraSession.LineSpeed =
                        selectedBaudRate == .bps57600 ? .fast : .standard
                    let shook = await session.handshake(speed: speed, assumeAwake: true)
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    if shook {
                        detectedFamily = .kodak
                    } else {
                        await session.disconnect()
                        guard cameraWork.isCurrent(workGeneration) else { return }
                    }
                }
            }

            guard cameraWork.isCurrent(workGeneration) else { return }
            guard let family = detectedFamily else {
                QTLog.note("CONNECT", "no camera responded to detection")
                QTLog.flush()
                // Nothing answered on any family. Don't pop a modal chooser —
                // detection is automatic when the camera responds, so a failure
                // here means a connection problem. Report it and let the user
                // fix the cable/power or pick their model in Settings.
                self.detectedPortPath = path
                self.isBusy = false
                self.isConnecting = false
                self.isConnected = false
                self.statusMessage = "Camera Not Responding"
                self.errorMessage = "Couldn't detect a camera. Check it's plugged in and powered on, then try again. If it was connected recently, power the camera off and on first — or choose your model in Settings ▸ Hardware."
                return
            }

            self.detectedPortPath = path
            QTLog.note("CONNECT", "family probed OK", detail: "\(family) on \(path); Settings model = \(self.selectedModel.displayName)")

            // Family is known; try to pin the exact model from the camera's
            // self-reported name.
            let resolvedModel = await resolveModel(in: family)
            guard cameraWork.isCurrent(workGeneration) else { return }
            if let model = resolvedModel {
                guard cameraWork.isCurrent(workGeneration) else { return }
                QTLog.note("MODEL", "resolved from hardware", detail:
                    "\(model.displayName)\(model == self.selectedModel ? "" : " (overrides Settings: \(self.selectedModel.displayName))")")
                if model != self.selectedModel { self.selectedModel = model }
            } else if self.selectedModel.protocolFamily != family {
                // resolveModel couldn't pin the exact sibling, and we've
                // arrived from a DIFFERENT family — so the current model isn't
                // a valid sibling to keep.
                if family == .kodak {
                    // Reaching here means resolveModel had NOTHING: no wake
                    // burst (camera already awake) and no hardware-proven
                    // identity remembered from an earlier connect
                    // (PrefKey.lastIdentifiedKodakModel). The device NAME is
                    // deliberately NOT consulted — it's user-editable, so a
                    // QT100 named "QuickTake 150" would lie. The models CAN
                    // be told apart — the wake burst carries the identity
                    // (byte 3: 0xC8 = QT150) — this is only the
                    // everything-was-silent default: QT150, by far the more
                    // common body. A power-cycled reconnect self-corrects via
                    // the burst.
                    QTLog.note("MODEL", "NO hardware evidence — defaulting", detail:
                        "no aligned wake burst, no remembered identity → QT150")
                    self.selectedModel = .qt150
                } else if let fallback = Self.implementedModels(in: family).first {
                    // Other families' siblings share the image format too, so a
                    // representative default is harmless.
                    self.selectedModel = fallback
                }
            }
            await self.finalizeConnection(family: family, path: path)
            guard cameraWork.isCurrent(workGeneration) else { return }
        }
    }

    /// The probe order is FIXED: Kodak first, Fuji second — never the
    /// selected model's family first. The Kodak probe is purely passive
    /// until a wake burst arrives (DTR drop + listen; not one byte is
    /// sent to a silent line), so it can never confuse a QT200. The Fuji
    /// probe is the opposite: opening its session toggles DTR — which
    /// wakes a QT100/150 and burns its ONE wake burst mid-probe — and
    /// its stale-baud rescue actively thrashes the line. Running Fuji
    /// first is exactly how a QT150 ended up "Not Responding" whenever
    /// the app had last resolved to a QT200 (bench, 2026-07-09).
    private func orderedProbeFamilies() -> [QuickTakeProtocolFamily] {
        Self.probeFamilies   // [.kodak, .fuji] — passive before active
    }

    /// Open + handshake one family. Returns true (session left open) on a
    /// live camera; closes the session and returns false otherwise. The
    /// Kodak probe uses the user's chosen line speed so the resulting
    /// session can be reused directly for transfers.
    private func probeHandshake(family: QuickTakeProtocolFamily, path: String) async -> Bool {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return false }

        switch family {
        case .kodak:
            let opened = await session.open(path: path)
            guard cameraWork.isCurrent(workGeneration) else { return false }
            guard opened else { return false }
            let speed: QuickTakeCameraSession.LineSpeed = selectedBaudRate == .bps57600 ? .fast : .standard
            let shook = await session.handshake(speed: speed)
            guard cameraWork.isCurrent(workGeneration) else { return false }
            if shook { return true }
            await session.disconnect()
            guard cameraWork.isCurrent(workGeneration) else { return false }
            return false
        case .fuji:
            // Always wake at 9600 (the camera's power-on rate); the fast-baud
            // ramp happens after connect in finalizeConnection via the proper
            // SPEED→EOT→switch→ping sequence.
            let opened = await fujiSession.open(path: path)
            guard cameraWork.isCurrent(workGeneration) else { return false }
            guard opened else { return false }
            let shook = await fujiSession.handshake()
            guard cameraWork.isCurrent(workGeneration) else { return false }
            if shook { return true }
            // "Needs a camera restart" rescue: a camera stranded at a fast
            // baud by an unclean session end won't hear the 9600 wake — try
            // finding it at the ramped rates and resetting it ourselves.
            let recovered = await fujiSession.recoverFromStaleBaud()
            guard cameraWork.isCurrent(workGeneration) else { return false }
            if recovered { return true }
            await fujiSession.disconnect()
            guard cameraWork.isCurrent(workGeneration) else { return false }
            return false
        }
    }

    /// Read the camera's self-reported name on the already-open session and
    /// map it to a specific model. Returns nil when the name doesn't
    /// disambiguate the family's siblings.
    private func resolveModel(in family: QuickTakeProtocolFamily) async -> QuickTakeModel? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        switch family {
        case .kodak:
            // ONLY hardware-level evidence identifies the model. The
            // device-info NAME is user-editable (this app ships Set Name) —
            // a QT100 renamed "QuickTake 150" lies convincingly — so the
            // name plays NO part in identification, ever. The chain is:
            // aligned wake burst → identity a previous burst proved →
            // nothing (caller defaults to QT150, the common body).
            if let identity = session.wakeIdentity {
                // The model identity lives in the wake burst and nowhere
                // else on the wire: 0x01 is a QuickTake 100 (whose burst is
                // A5 5A 01 01 01 00 02) and 0xC8 a 150. The session only
                // exposes byte 3 from an ALIGNED burst — A5 5A header — so
                // a split read can't smuggle garbage in here.
                let model = identity.model
                // Persist only what the camera actually SAID. An
                // unrecognised byte still drives the QT100 path, because
                // that is the right landing for any body in this family
                // that isn't a 150 — but it is a guess, and writing a guess
                // here would let it masquerade as hardware-proven on every
                // later connect that misses the burst. Guesses don't get
                // remembered.
                if identity.isKnown {
                    UserDefaults.standard.set(model.rawValue,
                                              forKey: PrefKey.lastIdentifiedKodakModel)
                }
                return model
            }
            // No burst this connect — the last hardware-proven identity is
            // the only other admissible evidence.
            if let raw = UserDefaults.standard.string(forKey: PrefKey.lastIdentifiedKodakModel),
               let remembered = QuickTakeModel(rawValue: raw),
               remembered.protocolFamily == .kodak {
                return remembered
            }
            return nil
        case .fuji:
            // Lead with VERSION (0x09): the QT200 always answers it
            // ("02.00,QT-200"), whereas MODEL (0x29) NAKs on the QT200 — and
            // three NAKs make the camera auto-reset itself, forcing autodetect
            // into the manual "which camera?" prompt. A real DS-7/Kenox
            // answers VERSION too, so fall back to the NAK-prone MODEL command
            // only when VERSION fails to disambiguate.
            if let model = Self.matchFujiModel(await fujiSession.readFirmwareVersion()) {
                return model
            }
            return Self.matchFujiModel(await fujiSession.readModelString())
        }
    }

    /// Map a Fuji-family self-reported string (VERSION or MODEL reply) to a
    /// specific model. Returns nil when the string is absent or doesn't name a
    /// sibling we recognize.
    private static func matchFujiModel(_ reported: String?) -> QuickTakeModel? {
        guard let name = reported?.lowercased(), !name.isEmpty else { return nil }
        if name.contains("200") || name.contains("quicktake") { return .qt200 }
        if name.contains("ds-7") || name.contains("ds7") { return .fujiDS7 }
        if name.contains("kenox") || name.contains("ssc") { return .samsungSSC350N }
        return nil
    }

    /// Finish a connection on a session that's already open + handshaken for
    /// `family`. `selectedModel` must already be a model in that family.
    private func finalizeConnection(family: QuickTakeProtocolFamily, path: String) async {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return }

        // Fuji baud ramp follows the exact pre-transfer sequence:
        // SPEED cmd with leading 0x01 class byte → EOT reset → switch host →
        // re-ping. Both the 0x01 class byte and the EOT are required; without
        // them the camera ACKs but never switches. A camera that declines
        // stays at 9600 (safe), and the import timeout is clamped against any
        // mismatch.
        if family == .fuji, selectedBaudRate != .bps9600 {
            let rate = await fujiSession.negotiateFastestBaud()
            guard cameraWork.isCurrent(workGeneration) else { return }
            if rate > 9600 { NSLog("[Fuji] negotiated %d baud", rate) }
        }

        // The camera can be slow to settle right after the handshake, so the FIRST
        // metadata read sometimes times out — which would "half-connect" (the
        // liveness monitor then drops it, forcing a manual reconnect).
        // Recover in two stages:
        //   1) retry with a growing breather (catches a camera that's just slow);
        //   2) if it STILL fails, RE-HANDSHAKE once — exactly what a manual
        //      reconnect does, and what reliably wakes a stubborn first connect —
        //      then retry again (re-ramping Fuji baud, since a re-handshake drops
        //      the camera back to 9600).
        var metadataResult = await fetchMetadata()
        guard cameraWork.isCurrent(workGeneration) else { return }
        if metadataResult == nil {
            for delayMs in [400, 700, 1000] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
                metadataResult = await fetchMetadata()
                guard cameraWork.isCurrent(workGeneration) else { return }
                if metadataResult != nil { break }
            }
        }
        if metadataResult == nil {
            if await probeHandshake(family: family, path: path) {
                if family == .fuji, selectedBaudRate != .bps9600 {
                    _ = await fujiSession.negotiateFastestBaud()
                    guard cameraWork.isCurrent(workGeneration) else { return }
                }
                for delayMs in [400, 700] {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    metadataResult = await fetchMetadata()
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    if metadataResult != nil { break }
                }
            }
        }

        guard cameraWork.isCurrent(workGeneration) else { return }
        // Auto-detect sets the model itself, so the post-connect
        // "different model?" toast is moot — clear it if it was lingering.
        self.detectedModelName = nil
        if self.showModelMismatch { self.presentToast(nil) }

        self.detectedPortPath = path
        guard cameraWork.isCurrent(workGeneration) else { return }
        self.metadata = metadataResult

        // Offline viewing may retain the previous gallery, but a reconnect
        // cannot prove its slots still contain the same photos. The same camera
        // can have been erased and refilled while disconnected. Rebuild from
        // current headers and disk recognition on every connection.
        guard cameraWork.isCurrent(workGeneration) else { return }
        let cameraIdentity = "\(selectedModel.rawValue)|\(metadataResult?.cameraName ?? "")"
        clearGalleryState()
        if selectedModel.protocolFamily == .kodak,
           let last = lastConnectedCameraIdentity, last != cameraIdentity {
            // A different camera: don't trust cross-session imported-matches for
            // its first fetch (shared DSC/EXIF names would wrongly skip its photos).
            suppressImportedRecognition = true
        }
        lastConnectedCameraIdentity = cameraIdentity

        self.isConnected = true
        self.downloadProgress = 0
        self.errorMessage = metadataResult == nil ? "Connected, but camera info couldn't be read." : nil
        self.statusMessage = metadataResult == nil
            ? "Failed to Fetch Camera Metadata"
            : "Connected to \(metadataResult?.cameraName ?? "QuickTake")"


        startConnectionMonitor()

        // Connected — drop the full-window "Connecting…" blanket NOW, before
        // the thumbnail fetch, so the gallery streams in visibly and the app
        // stays playable while thumbnails load (the status orb stays
        // flingable during it). `isBusy` stays true until the fetch
        // finishes, so the serial-touching controls stay guarded throughout.
        self.isConnecting = false

        if metadataResult != nil {
            await fetchAllThumbnails()
            guard cameraWork.isCurrent(workGeneration) else { return }
        }

        self.isBusy = false
    }

    // MARK: - "Which camera?" prompt

    private func beginCameraSelection(candidates: [QuickTakeModel], family: QuickTakeProtocolFamily?, path: String?) {
        // The chooser sheet IS the prompt — don't leave a "camera not
        // responding" error banner sitting behind it. Clear any error + banner
        // so the user just sees the clean "Which camera is this?" sheet.
        self.errorMessage = nil
        self.presentToast(nil)
        self.pendingProbeFamily = family
        self.pendingProbePath = path
        self.pendingCameraSelection = candidates
    }

    /// The user picked a model in the themed prompt. If we already have an
    /// open session for that model's family (the ambiguous case), reuse it;
    /// otherwise run a fresh connect for the chosen model.
    func confirmDetectedModel(_ model: QuickTakeModel) {
        let openFamily = pendingProbeFamily
        let openPath = pendingProbePath
        pendingCameraSelection = nil
        pendingProbeFamily = nil
        pendingProbePath = nil

        if model != selectedModel { selectedModel = model }
        setBusy(true, status: "Connecting to \(model.displayName)…")
        self.isConnecting = true
        self.connectionTimer?.cancel()

        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            if let openFamily, openFamily == model.protocolFamily, let openPath {
                // Reuse the still-open probe session.
                await self.finalizeConnection(family: openFamily, path: openPath)
                guard cameraWork.isCurrent(workGeneration) else { return }
            } else {
                // No reusable session (manual chooser after no-response, or a
                // cross-family pick): tear down and connect fresh.
                if let openFamily { await self.disconnect(family: openFamily) }
                await self.connectFresh(model: model)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
        }
    }

    /// User dismissed the themed prompt without choosing — abandon the probe.
    func cancelCameraSelection() {
        invalidateCameraWork()
        let openFamily = pendingProbeFamily
        pendingCameraSelection = nil
        pendingProbeFamily = nil
        pendingProbePath = nil
        self.isBusy = false
        self.isConnecting = false
        self.isConnected = false
        self.statusMessage = defaultIdleStatus
        let previousTeardown = sessionTeardown
        sessionTeardown = Task {
            await previousTeardown?.value
            if let openFamily {
                await self.disconnect(family: openFamily)
            } else {
                await session.disconnect()
                await fujiSession.disconnect()
            }
        }
    }

    /// Open + handshake + finalize for a known model (no detection). Used
    /// when the user forces a model via the prompt and we have no reusable
    /// open session.
    private func connectFresh(model: QuickTakeModel) async {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return }
        QTLog.begin("CONNECT ATTEMPT (manual) · model: \(model.displayName)")

        await sessionTeardown?.value
        guard cameraWork.isCurrent(workGeneration) else { return }
        let path = SerialPortFinder.bestCandidate() ?? self.detectedPortPath
        guard let path else {
            QTLog.note("CONNECT", "no serial adapter found")
            QTLog.flush()
            self.isBusy = false
            self.isConnecting = false
            self.isConnected = false
            self.statusMessage = "No Adapter Found"
            self.errorMessage = "Connect a supported USB-to-serial adapter, then try again."
            return
        }

        await session.disconnect()
        guard cameraWork.isCurrent(workGeneration) else { return }
        await fujiSession.disconnect()
        guard cameraWork.isCurrent(workGeneration) else { return }

        let family = model.protocolFamily
        let connected = await probeHandshake(family: family, path: path)
        guard cameraWork.isCurrent(workGeneration) else { return }
        guard connected else {
            QTLog.note("CONNECT", "selected camera did not respond", detail: model.displayName)
            QTLog.flush()
            self.detectedPortPath = path
            self.isBusy = false
            self.isConnecting = false
            self.isConnected = false
            self.statusMessage = "Camera Not Responding"
            self.errorMessage = "Make sure the camera is on, then try again."
            return
        }
        self.detectedPortPath = path
        await finalizeConnection(family: family, path: path)
        guard cameraWork.isCurrent(workGeneration) else { return }
    }

    /// Close one family's session.
    private func disconnect(family: QuickTakeProtocolFamily) async {
        switch family {
        case .kodak: await session.disconnect()
        case .fuji:  await fujiSession.disconnect()
        }
    }

    // MARK: - Diagnostics

    /// Capture a diagnostic report for the connected camera and stash it in
    /// `diagnosticsReport` for the copy-pasteable sheet. Works for every
    /// family: the Kodak QT100/150 and Fuji QT200 sessions probe their
    /// live link.
    func runCameraDiagnostics() {
        let family = selectedModel.protocolFamily

        guard isConnected else {
            statusMessage = "Connect a Camera First"
            return
        }
        guard !isBusy, !areThumbnailsLoading, !isProbingLiveness else { return }

        // Show the popup immediately with a "capturing…" state, then fill it.
        isCapturingDiagnostics = true
        diagnosticsCameraName = isConnected
            ? (metadata?.cameraName ?? selectedModel.displayName)
            : selectedModel.displayName
        setBusy(true, status: "Capturing Camera Diagnostics…")
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            let session: CameraDiagnosticsCapable
            switch family {
            case .kodak: session = self.session
            case .fuji:  session = self.fujiSession
            }
            let report = await session.captureDiagnostics()
            guard cameraWork.isCurrent(workGeneration) else { return }
            self.diagnosticsReport = report
            self.isCapturingDiagnostics = false
            self.isBusy = false
            self.statusMessage = "Diagnostics Captured"
            scheduleStatusRevert()
        }
    }

    /// Write the running trace to `~/Pictures/SwiftTake Traces/` and
    /// reveal it. The folder needs no file picker under the sandbox, so
    /// this works mid-fault without a dialog in the way.
    func exportSessionTrace() {
        Task {
            if let url = await QTDiagnosticLog.shared.export() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self.statusMessage = "Session Trace Saved"
            } else {
                self.statusMessage = "Couldn't Save Session Trace"
            }
            scheduleStatusRevert()
        }
    }

    /// Re-wake the connected family's session after a mid-transfer failure.
    /// An aborted transfer's EOT recovery leaves the camera un-handshaken
    /// (and a Fuji back at 9600) — without this, every remaining photo in a
    /// batch insta-fails in a FAILED HEADER cascade. Same
    /// open+handshake(+Fuji re-ramp) the connect path's own metadata
    /// recovery uses.
    private func rewakeSessionAfterFailure() async -> Bool {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return false }

        guard isConnected, let path = detectedPortPath else { return false }
        guard await probeHandshake(family: selectedModel.protocolFamily, path: path) else {
            return false
        }
        if selectedModel.protocolFamily == .fuji, selectedBaudRate != .bps9600 {
            _ = await fujiSession.negotiateFastestBaud()
            guard cameraWork.isCurrent(workGeneration) else { return false }
        }
        return true
    }

    private func startConnectionMonitor() {
        connectionTimer?.cancel()
        // Poll every 10s on an async loop. The manager is @MainActor, so this
        // Task inherits the main actor — state reads and the disconnect handler
        // run on main, and the actual ENQ I/O suspends on the SerialPort actor.
        let monitorGeneration = cameraWork.generation
        connectionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                if Task.isCancelled || !self.isConnected { return }
                if self.isBusy { continue }           // never probe mid-transfer
                // Still finishing a capture or an erase. Silence here is
                // the camera working, not the camera gone.
                if let quiet = self.quietUntil, quiet > Date() { continue }
                // Claim the session for the probe (atomic vs. an import's sync
                // prologue — no await since the isBusy check) so an import can't
                // start mid-probe and interleave frames with the ENQ.
                self.isProbingLiveness = true
                var alive = await self.checkIfAlive()
                guard self.cameraWork.isCurrent(monitorGeneration) else { return }
                // Silence is not proof. A QuickTake naps, and a camera that
                // ignored four ENQs may simply need waking — which is the
                // same recovery an aborted transfer already uses. Only a
                // camera that will not re-handshake is actually gone.
                //
                // This runs ONLY when the probe has already failed, so it
                // costs nothing on a healthy link and replaces a teardown
                // rather than adding work before one.
                if !alive {
                    QTLog.note("MONITOR", "probe missed — trying a re-wake before calling it dead")
                    alive = await self.rewakeSessionAfterFailure()
                    guard self.cameraWork.isCurrent(monitorGeneration) else { return }
                    QTLog.note("MONITOR", alive ? "re-wake worked; link was napping"
                                                : "re-wake failed; link really is gone")
                }
                self.isProbingLiveness = false
                if !alive {
                    self.handleUnexpectedDisconnect()
                    return
                }
                // Release: run any import that deferred itself during the probe.
                self.runPendingImportIfNeeded()
            }
        }
    }

    /// Liveness check that tolerates a single missed reply. The camera can nap
    /// between commands, so one unanswered ENQ is not proof the link is gone —
    /// retry a few times (like `handshake`) before declaring a disconnect, so a
    /// healthy connection isn't dropped on a transient miss.
    private func checkIfAlive() async -> Bool {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return false }

        // The demo camera is always there — it has no port to go quiet on.
        if DemoCamera.shared.isConnected { return true }
        // Four tries on a lengthening leash: about six seconds of patience
        // in total, against the two it used to allow. `capturePhoto` gives
        // the shutter ten seconds precisely because these cameras take
        // their time, and the poll that decides whether the camera still
        // EXISTS had less patience than the command that knows it's slow.
        let attempts: [(timeout: TimeInterval, gapNS: UInt64)] = [
            (0.5, 300_000_000), (1.0, 600_000_000),
            (1.0, 1_000_000_000), (1.5, 0),
        ]
        for (index, step) in attempts.enumerated() {
            let alive: Bool
            switch selectedModel.protocolFamily {
            case .kodak: alive = await session.isResponding(timeout: step.timeout)
            case .fuji:  alive = await fujiSession.isResponding(timeout: step.timeout)
            }
            if alive { return true }
            if index < attempts.count - 1 {
                try? await Task.sleep(nanoseconds: step.gapNS)
                guard cameraWork.isCurrent(workGeneration) else { return false }
            }
        }
        return false
    }

    private func handleUnexpectedDisconnect() {
        // If we're already disconnected (e.g. the user just tapped
        // Disconnect, or a previous poll already handled the drop),
        // there's nothing to report — bail so we don't stack a second
        // banner on top of the one already shown.
        guard isConnected else { return }
        invalidateCameraWork()

        QTLog.note("CONNECT", "unexpected disconnect")
        // Save now; the user may never attempt another connection.
        QTLog.flush()

        connectionTimer?.cancel()
        connectionTimer = nil
        withAnimation(.spring()) {
            self.isConnected = false
            self.isBusy = false
            self.metadata = nil
            self.statusMessage = "Disconnected"
            self.presentToast(.connectionLost)
        }
        let previousTeardown = sessionTeardown
        sessionTeardown = Task {
            await previousTeardown?.value
            await session.disconnect()
            await fujiSession.disconnect()

            let content = UNMutableNotificationContent()
            content.title = "Camera Disconnected"
            content.body = "The connection to your QuickTake was lost. Check the cable and power, then reconnect."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// `fullReload: true` is the menu's "Reload Gallery" — the same rebuild
    /// as plugging in a camera: every cell drops to its swirl and refetches,
    /// fresh photo count included. The default keeps loaded thumbnails and
    /// fetches only what's missing (the sidebar Refresh behaviour).
    func refreshCameraMetadata(fullReload: Bool = false) {
        guard isConnected else {
            statusMessage = "Connect a Camera First"
            return
        }
        // Reentrancy guard: a refresh does a metadata read AND a full thumbnail
        // fetch over the single, slow serial link. Overlapping refreshes
        // interleave at `await` points and corrupt the serial session, so
        // ignore new requests until the current one fully finishes.
        guard !isRefreshing, !isBusy, !areThumbnailsLoading, !isProbingLiveness else { return }
        isRefreshing = true

        // A full reload re-reads the card from scratch, and the card may
        // have been shot on or erased in the camera since the last read —
        // so the slot numbering cannot be assumed to still mean what it
        // meant. A plain Refresh only re-reads the camera INFO and leaves
        // the photo list alone, so it keeps them.
        if fullReload { invalidateSlotKeyedState() }
        setBusy(true, status: fullReload ? "Reloading Gallery…" : "Refreshing Camera Info…")
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            // The first read after an idle stretch can time out while the
            // camera wakes — the connect path has the same forgiveness
            // (retries + breathers in finalizeConnection). One breather +
            // retry here before declaring failure.
            var metadataResult = await fetchMetadata()
            guard cameraWork.isCurrent(workGeneration) else { return }
            if metadataResult == nil {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
                metadataResult = await fetchMetadata()
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
            // Keep the LAST GOOD metadata on a failed refresh: nulling it
            // collapses the camera sections (and their counts) over a
            // one-off read miss.
            if metadataResult != nil { self.metadata = metadataResult }
            self.errorMessage = metadataResult == nil ? "Couldn't refresh camera info." : nil
            // Same wording as the initial-connect failure branch so the
            // user sees one phrase whenever the camera is reachable but
            // won't surrender its info, regardless of the trigger.
            self.statusMessage = metadataResult == nil
                ? "Connected, but Camera Info Couldn't Be Read"
                : "Refreshed Camera Info from \(metadataResult?.cameraName ?? "QuickTake")"

            if metadataResult != nil {
                // Default: same live camera (the link never dropped) — keep
                // loaded thumbnails, fetch only what's missing/new. Reload
                // Gallery passes true for the full rebuild.
                await fetchAllThumbnails(fullReload: fullReload)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }

            // Only release the link AFTER the thumbnail fetch completes, so the
            // Refresh control stays guarded for the entire operation.
            self.isBusy = false
            self.isRefreshing = false
            scheduleStatusRevert()
            runPendingImportIfNeeded()
        }
    }

    func setCameraName(_ name: String) {
        guard let ascii = name.data(using: .ascii), !ascii.isEmpty else {
            errorMessage = "Use plain ASCII characters for the camera name."
            return
        }
        var bytes = Array(ascii.prefix(32))
        let expected = String(bytes: bytes, encoding: .ascii)!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            errorMessage = "Use a nonempty camera name with printable ASCII characters."
            return
        }
        bytes.append(contentsOf: repeatElement(0x20, count: 32 - bytes.count))
        updateCameraSetting("Updating Camera Name…", success: "Camera Name Updated", action: { [self] in
            if DemoCamera.shared.isConnected { DemoCamera.shared.setName(expected); return true }
            switch selectedModel.protocolFamily {
            case .kodak: return await session.setName(bytes)
            case .fuji: return await fujiSession.setName(bytes)
            }
        }, verify: { [self] metadata in
            if selectedModel.protocolFamily == .fuji, !DemoCamera.shared.isConnected {
                return await fujiSession.readCameraName() == expected
            }
            return metadata.cameraName == expected
        })
    }

    func syncDateAndTime() {
        guard !isBusy, !areThumbnailsLoading, !isProbingLiveness, isConnected else { return }

        let date = Date()
        let calendar = Calendar.current
        let c = calendar.dateComponents([.month, .day, .year, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000, month = c.month ?? 1, day = c.day ?? 1
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0

        setBusy(true, status: "Setting Camera Clock…")
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            switch selectedModel.protocolFamily {
            case .kodak:
                let bytes: [UInt8] = [UInt8(month), UInt8(day), UInt8(year % 100),
                                      UInt8(hour), UInt8(minute), UInt8(second)]
                let accepted = await session.setClock(bytes)
                guard cameraWork.isCurrent(workGeneration) else { return }
                self.statusMessage = accepted ? "Camera Clock Set" : "Camera Rejected the Clock Command"

            case .fuji:
                // Fuji/QT200 wants 14 ASCII digits "YYYYMMDDHHMMSS". The whole
                // EXIF-date filename scheme depends on this clock being right, so
                // read it straight back and confirm it actually stuck (the QT200
                // may not implement the clock over serial — DATE_GET can NAK).
                let ok = await fujiSession.setClock(year: year, month: month, day: day,
                                                    hour: hour, minute: minute, second: second)
                guard cameraWork.isCurrent(workGeneration) else { return }
                if !ok {
                    self.statusMessage = "Camera Rejected the Clock Command"
                } else if let r = await fujiSession.readClock() {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    let matches = r.year == year && r.month == month && r.day == day &&
                                  r.hour == hour && r.minute == minute && abs(r.second - second) <= 2
                    self.statusMessage = matches
                        ? "Camera Clock Set to \(String(format: "%04d-%02d-%02d %02d:%02d", r.year, r.month, r.day, r.hour, r.minute))"
                        : "Clock Set, but Read Back \(String(format: "%04d-%02d-%02d %02d:%02d", r.year, r.month, r.day, r.hour, r.minute))"
                } else {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    self.statusMessage = "Clock Command Accepted — Couldn’t Verify the Time"
                }
            }

            self.isBusy = false
            scheduleStatusRevert()
        }
    }

    func takePictureWithTimer() {
        guard isConnected, !isBusy, countdownTimer == nil else { return }

        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            for i in (0...10).reversed() {
                self.countdownTimer = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
            self.countdownTimer = nil
            takePicture()
        }
    }

    func disconnectCamera() {
        if DemoCamera.shared.isConnected {
            demoDisconnect()
            return
        }
        invalidateCameraWork()
        QTLog.note("CONNECT", "disconnect requested")
        // Every session ends with its trace on disk, so a fault that
        // ended in a disconnect is still explainable afterwards.
        QTLog.flush()
        // Tear the connection down *synchronously* before the async
        // port close. The 10-second connection monitor polls on a
        // timer; if we waited until after `closePort()` to flip
        // `isConnected` and cancel the timer, the monitor could fire
        // during that await, see a still-"connected" but dead port,
        // and raise its own "camera disconnected" toast on top of the
        // one we show here — the user would get two banners at once.
        // Flipping state up front makes the monitor's guard short-
        // circuit and stops the timer immediately.
        connectionTimer?.cancel()
        connectionTimer = nil
        withAnimation(.spring()) {
            self.isConnected = false
            self.isBusy = false
            self.metadata = nil
            self.previewImage = nil
            self.previewedPhotoIndex = nil
            self.downloadProgress = 0
            self.statusMessage = "Disconnected"
            self.errorMessage = nil
            self.presentToast(.poweredDownReminder)
        }
        // Keep original JPEGs with the offline gallery so a panorama can still
        // use unprocessed sources after disconnect. The next connection or
        // gallery reset clears them before any camera slots can be reused.
        let previousTeardown = sessionTeardown
        sessionTeardown = Task {
            await previousTeardown?.value
            await session.disconnect()
            await fujiSession.disconnect()
        }
    }

    /// The connection-related banner the app can show. Only one is ever
    /// on screen at a time — see `presentToast(_:)`.
    enum CameraBanner {
        /// Post-disconnect "remember to power off the camera" reminder.
        case poweredDownReminder
        /// The connection dropped unexpectedly.
        case connectionLost
        /// The camera reports a different model than the one selected.
        case modelMismatch
    }

    /// Show exactly one connection banner, clearing the others. Routing
    /// every banner through here is what prevents the two-at-once stack
    /// (the disconnect double-toast). Pass `nil` to clear all of them.
    func presentToast(_ banner: CameraBanner?) {
        showPowerTip       = banner == .poweredDownReminder
        showConnectionAlert = banner == .connectionLost
        showModelMismatch  = banner == .modelMismatch
    }

    func clearMessages() {
        errorMessage = nil
        presentToast(nil)
        if !isBusy {
            statusMessage = defaultIdleStatus
        }
    }

    /// The status-pill phrase the app should re-converge on whenever a
    /// transient action (import / refresh / rename) finishes. Keeps the
    /// idle-revert (after `scheduleStatusRevert`) and `clearMessages`
    /// in lockstep so the user always sees the same baseline phrase
    /// for the same baseline state — no "Camera Ready" one moment and
    /// "Connected." the next.
    fileprivate var defaultIdleStatus: String {
        guard isConnected else { return "Ready" }
        if let name = metadata?.cameraName, !name.isEmpty {
            return "Connected to \(name)"
        }
        return "Connected"
    }

    func requestBatchImport() {
        shouldRequestImport = true
    }

    func batchImportRequestHandled() {
        shouldRequestImport = false
    }

    /// Menu-bar erase routes through the SAME confirmation dialog the sidebar
    /// trash button shows (same request/handled pattern as batch import) —
    /// no destructive path may run unconfirmed.
    @Published private(set) var shouldConfirmErase = false

    func requestEraseConfirmation() {
        shouldConfirmErase = true
    }

    func eraseConfirmationHandled() {
        shouldConfirmErase = false
    }

    func toggleSelection(for index: UInt8) {
        if selectedPhotoIndices.contains(index) {
            selectedPhotoIndices.remove(index)
        } else {
            selectedPhotoIndices.insert(index)
        }
    }

    func selectAllPhotos() {
        selectedPhotoIndices = Set(photoIndices)
    }

    func deleteImages() {
        guard !isBusy, !areThumbnailsLoading, !isProbingLiveness, isConnected else {
            statusMessage = "Connect a Camera First"
            return
        }

        setBusy(true, status: "Deleting All Images…")
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            // Erasing a full card is the longest the camera is ever
            // unreachable in one go.
            holdOffLivenessProbe(for: 20)
            let outcome: QuickTakeCameraSession.EraseOutcome
            if DemoCamera.shared.isConnected {
                DemoCamera.shared.eraseAll()
                outcome = .acknowledged
            } else {
                switch selectedModel.protocolFamily {
                case .kodak: outcome = await session.eraseAll()
                case .fuji: outcome = await fujiSession.eraseAll() ? .acknowledged : .unconfirmed
                }
            }

            guard cameraWork.isCurrent(workGeneration) else { return }
            if outcome == .rejected {
                self.errorMessage = "The camera declined the erase command."
                self.statusMessage = "Camera Declined the Erase"
                self.isBusy = false
                scheduleStatusRevert()
                return
            }

            // The card may now be empty or partially erased (Fuji). Cached
            // originals must never be reused under renumbered photo slots,
            // even when the following metadata refresh cannot complete.
            self.invalidateSlotKeyedState()
            self.fujiJPEGCache.removeAll()
            self.previewImage = nil
            self.previewedPhotoIndex = nil
            if outcome == .acknowledged {
                self.photoIndices.removeAll()
                self.availableThumbnails.removeAll()
                self.selectedPhotoIndices.removeAll()
            }

            // A missing ACK is not a refusal: the camera may have erased its
            // photos. Re-establish framing before reading metadata so a late
            // completion byte cannot be mistaken for a device-info status.
            self.isRefreshing = true
            self.statusMessage = "Refreshing Camera After Erase…"
            if outcome == .unconfirmed {
                let recovered = await rewakeSessionAfterFailure()
                guard cameraWork.isCurrent(workGeneration) else { return }
                guard recovered else {
                    self.errorMessage = "The erase may have completed, but the camera couldn't be reached. Reconnect to check its photos."
                    self.statusMessage = "Erase Unconfirmed — Reconnect Camera"
                    self.isRefreshing = false
                    self.isBusy = false
                    scheduleStatusRevert()
                    return
                }
            }

            // An erase ACK can precede the updated photo count. Keep polling
            // until the camera reports an empty card, not merely a valid reply.
            // Retain the latest valid reply if a subsequent read times out.
            var metadataResult: CameraMetadata? = nil
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
                let refreshed = await fetchMetadata()
                guard cameraWork.isCurrent(workGeneration) else { return }
                if let refreshed { metadataResult = refreshed }
                if refreshed?.picturesTaken == 0 { break }
            }

            if let metadataResult {
                self.metadata = metadataResult
                // Reconcile both the gallery and controls with the camera.
                // A nonempty result can mean photos remain or a new shot was
                // taken; never repeat the destructive command to resolve it.
                await fetchAllThumbnails(fullReload: true)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
            let confirmedEmpty = metadataResult?.picturesTaken == 0
            self.errorMessage = confirmedEmpty ? nil : "Couldn't confirm that the camera is empty. Refresh to check its current photos."
            self.statusMessage = confirmedEmpty ? "All Images Deleted" : "Erase Sent — Camera Contents Unconfirmed"
            self.isRefreshing = false
            self.isBusy = false
            scheduleStatusRevert()
        }
    }

    func setFlashMode(mode: UInt8) {
        let expected = ["Auto", "Disabled", "Forced"]
        guard Int(mode) < expected.count else { return }
        updateCameraSetting("Updating Flash Mode…", success: "Flash Mode Updated", action: { [self] in
            if DemoCamera.shared.isConnected { DemoCamera.shared.setFlash(mode: mode); return true }
            switch selectedModel.protocolFamily {
            case .kodak: return await session.setFlash(mode: mode)
            case .fuji: return await fujiSession.setFlash(mode: mode)
            }
        }, verify: { $0.flashMode == expected[Int(mode)] })
    }

    func setQualityMode(highQuality: Bool) {
        updateCameraSetting("Updating Quality Mode…", success: "Quality Updated", action: { [self] in
            if DemoCamera.shared.isConnected { DemoCamera.shared.setQuality(high: highQuality); return true }
            switch selectedModel.protocolFamily {
            case .kodak: return await session.setQuality(high: highQuality)
            case .fuji: return await fujiSession.setQuality(high: highQuality)
            }
        }, verify: { $0.quality == (highQuality ? "High" : "Standard") })
    }

    private func updateCameraSetting(_ message: String, success: String,
                                     action: @escaping @MainActor () async -> Bool,
                                     verify: @escaping @MainActor (CameraMetadata) async -> Bool) {
        guard isConnected, !isBusy, !areThumbnailsLoading, !isProbingLiveness else { return }
        setBusy(true, status: message)
        cameraWork.start { [self] in
            let token = cameraWork.generation
            let accepted = await action()
            guard cameraWork.isCurrent(token) else { return }
            guard accepted else {
                isBusy = false
                statusMessage = "Camera Setting Was Not Accepted"
                scheduleStatusRevert()
                return
            }
            let result = await fetchMetadata()
            guard cameraWork.isCurrent(token) else { return }
            if let result { metadata = result }
            let verified: Bool
            if let result { verified = await verify(result) } else { verified = false }
            guard cameraWork.isCurrent(token) else { return }
            isBusy = false
            statusMessage = verified ? success : "Refresh to Verify Camera Setting"
            scheduleStatusRevert()
        }
    }

    func takePicture() {
        guard !isBusy, !areThumbnailsLoading, !isProbingLiveness, isConnected else { return }
        setBusy(true, status: "Taking Picture…")
        let previousCount = metadata?.picturesTaken
        captureProgress = 0.0
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            captureProgress = 0.15
            if DemoCamera.shared.isConnected {
                // A beat of shutter, so the capture progress ring is seen.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
                DemoCamera.shared.takePicture()
            } else {
                let accepted: Bool
                switch selectedModel.protocolFamily {
                case .kodak: accepted = await session.capturePhoto()
                case .fuji:  accepted = await fujiSession.capturePhoto()
                }
                guard cameraWork.isCurrent(workGeneration) else { return }
                guard accepted else {
                    captureProgress = nil
                    isBusy = false
                    statusMessage = "Camera Did Not Accept the Shot"
                    scheduleStatusRevert()
                    return
                }
                // The shutter ACK means "I heard you", not "it's on the
                // card". Hold the poll off while the write finishes.
                holdOffLivenessProbe(for: 12)
            }
            captureProgress = 0.5

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard cameraWork.isCurrent(workGeneration) else { return }

            // Three reads on a lengthening wait. Two wasn't enough: a
            // high-quality frame on a nearly-full card can still be
            // writing four seconds after the shutter, and giving up then
            // put "Refresh to Confirm the Shot" on screen for a photo that
            // had in fact been taken.
            var metadataResult = await fetchMetadata()
            guard cameraWork.isCurrent(workGeneration) else { return }
            for wait in [UInt64(2_000_000_000), UInt64(3_000_000_000)]
            where metadataResult == nil || metadataResult!.picturesTaken <= (previousCount ?? -1) {
                try? await Task.sleep(nanoseconds: wait)
                guard cameraWork.isCurrent(workGeneration) else { return }
                metadataResult = await fetchMetadata()
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
            captureProgress = 0.7
            if let metadataResult { self.metadata = metadataResult }
            if let meta = metadataResult, meta.picturesTaken > (previousCount ?? 0) {
                captureProgress = 0.8
                let newIndex = UInt8(meta.picturesTaken - 1)
                if !photoIndices.contains(newIndex) {
                    photoIndices.append(newIndex)
                }
                // Prefer the per-photo header's quality byte (24); fall
                // back to the global meta flag if the header isn't
                // available. The global flag can lag the actual photo's
                // quality if the user toggles HQ/SQ between capture and
                // metadata read.
                guard cameraWork.isCurrent(workGeneration) else { return }
                if let header = await fetchImageHeader(forImageIndex: newIndex),
                   header.count >= 25 {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    let q = header[24]
                    if q == 0x10 {
                        photoQualities[newIndex] = true
                    } else if q == 0x20 {
                        photoQualities[newIndex] = false
                    } else {
                        photoQualities[newIndex] = meta.isHighQuality
                    }
                } else {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    photoQualities[newIndex] = meta.isHighQuality
                }
                guard cameraWork.isCurrent(workGeneration) else { return }
                if let thumbBytes = await fetchThumbnailBytes(forImageIndex: newIndex) {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    switch selectedModel.protocolFamily {
                    case .kodak:
                        availableThumbnails[newIndex] = QuickTakeThumbnailRenderer.renderImage(from: thumbBytes, model: selectedModel)
                    case .fuji:
                        availableThumbnails[newIndex] = QuickTake200ThumbnailRenderer.render(thumbBytes)
                    }
                }
            }
            guard cameraWork.isCurrent(workGeneration) else { return }
            captureProgress = 1.0
            self.isBusy = false
            self.statusMessage = metadataResult.map { $0.picturesTaken > (previousCount ?? $0.picturesTaken) } == true
                ? "Picture Taken" : "Refresh to Confirm the Shot"
            scheduleStatusRevert()

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard cameraWork.isCurrent(workGeneration) else { return }
            captureProgress = nil
        }
    }

    /// Tasteful gallery placeholder for photos whose thumbnail hasn't been
    /// fetched yet — a soft SF Symbol "photo" rather than the generic
    /// file-type icon (which reads as an ugly question mark / not native).
    static let galleryPlaceholderImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .tertiaryLabelColor))
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo not yet downloaded")?
            .withSymbolConfiguration(config) {
            return symbol
        }
        return NSImage(size: NSSize(width: 64, height: 64))
    }()

    // The QT200 already-imported ledger (DSC name → imported path + size) lives
    // in `FujiImportLedger`; `fujiLedger` above is the handle. The recognition
    // reads are inline at the call sites in `fetchAllThumbnails`.

    /// Wipe all per-photo (index-keyed) gallery state on connection so previous
    /// thumbnails, names and imported files cannot mask reused camera slots.
    /// `fetchAllThumbnails` rebuilds everything for the connected camera
    /// (thumbnails from the camera, imported previews re-derived from disk), so
    /// clearing here is safe.
    /// `keepingSlots` is the difference between swapping cameras and putting
    /// the camera away.
    ///
    /// When another camera is arriving, the slots survive so the new count
    /// lands as one diff — see below. When nothing is arriving, keeping them
    /// leaves a grid of grey placeholder cells sitting under a sidebar that
    /// reads Not Connected, which is what two testers reported as ghost
    /// tiles. Nothing is coming to replace them, so they go.
    private func clearGalleryState(keepingSlots: Bool = true) {
        // photoIndices deliberately SURVIVES the clear: the cells drop to
        // placeholder swirls at once (every content map below empties, so no
        // stale photo can mask the new camera's slots — the twin-swap
        // invariant), and fetchAllThumbnails then writes the new count as
        // ONE diff — extra cells fade away through the grid's count spring
        // instead of the whole gallery blinking out and refilling.
        // A failed connect still cleans up: the fetch's no-metadata guard
        // calls photoIndices.removeAll().
        availableThumbnails = [:]
        invalidateSlotKeyedState()
        selectedPhotoIndices = []
        previewImage = nil
        if !keepingSlots { photoIndices.removeAll() }
        previewedPhotoIndex = nil
        fujiJPEGCache.removeAll()
    }

    /// `fullReload: false` is the REFRESH path: the link stayed alive, so the
    /// connected camera cannot have been swapped — keep every thumbnail we
    /// already have and fetch only the cells still showing nothing or the
    /// placeholder (e.g. photos taken since). Connect always full-reloads
    /// (identical-twin QT200s can't be told apart, so trust nothing).
    private func fetchAllThumbnails(fullReload: Bool = true) async {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return }

        guard let taken = metadata?.picturesTaken, taken > 0 else {
            photoIndices.removeAll()
            availableThumbnails.removeAll()
            selectedPhotoIndices.removeAll()
            return
        }

        self.areThumbnailsLoading = true
        // Housekeeping: drop stale entries from the Fuji DSC→path map (deleted
        // imports) so it can't grow unbounded. Once per connect, Fuji only.
        if selectedModel.protocolFamily == .fuji { fujiLedger.prune() }
        let indices = (0..<taken).map(UInt8.init)
        thumbnailLoadProgress = (0, indices.count)
        photoIndices = indices
        if fullReload { availableThumbnails.removeAll() }
        fujiJPEGCache.removeAll()
        selectedPhotoIndices.removeAll()

        let placeholder = Self.galleryPlaceholderImage
        // Where an already-imported photo might live: the chosen folder AND the
        // default fallback. An import falls back to the default when the chosen
        // folder is unavailable (P1/U4 — e.g. a disconnected USB), so a photo can
        // be in either — check both, or already-imported shots stop pre-populating.
        let importDirs: [URL] = {
            var dirs = [effectiveImportDestinationURL]
            let fallback = DestinationBookmarkStore.defaultImportDestination()
            if !dirs.contains(where: { $0.standardizedFileURL == fallback.standardizedFileURL }) {
                dirs.append(fallback)
            }
            return dirs
        }()

        for index in indices {
            // Stop promptly if the camera was unplugged (or we were told to
            // disconnect) mid-load — otherwise every remaining serial read times
            // out against a dead port, hanging for minutes on a full card. Same
            // guard as the import loop (QA2); `disconnectCamera` flips
            // `isConnected` synchronously, and the liveness monitor flips it on an
            // unexpected drop. `areThumbnailsLoading` is still cleared after the
            // loop, so the UI never gets stuck "Loading".
            if !isConnected { break }

            // Refresh: this cell already shows a real thumbnail from the same
            // live session — skip the ~3 s camera round-trip and move on.
            if !fullReload,
               let existing = availableThumbnails[index],
               existing !== Self.galleryPlaceholderImage {
                thumbnailLoadProgress = (Int(index) + 1, indices.count)
                continue
            }
            let header = await fetchImageHeader(forImageIndex: index)
            guard cameraWork.isCurrent(workGeneration) else { return }
            if let header, header.count >= 12 {
                // HQ/SQ detection from the per-photo camera header.
                //
                // Byte 24 is the authoritative quality flag — same value
                // the camera *accepts* in `updateQualityMode`:
                //   0x10 = HQ (high quality)
                //   0x20 = SQ (standard quality)
                // `QTKFormatter.buildQTKData` already relies on this byte
                // (`fileHeader[7] = (imageHeader[24] == 16) ? 0x08 : 0x04`).
                //
                // The width heuristic `imageWidth >= 640` is unreliable: the
                // QT150 sensor reports 640 in bytes 8-9 even for SQ captures
                // (HQ vs SQ differs in compression, not header-reported
                // dimensions), which misclassifies SQ as HQ. Use it only as a
                // fallback when byte 24 is missing (header < 25 bytes) or holds
                // an unexpected value.
                //
                // Kodak QT100/150 only. The Fuji/QT200 synthesizes an all-zero
                // header (just the size at [5..7]), so this byte would label
                // every QT200 photo SQ; Fuji quality is decided from the
                // JPEG/EXIF at download time (see fetchFullImage). Leave it
                // unset (no badge) until then.
                if selectedModel.protocolFamily == .kodak {
                    let qualityByte: UInt8? = header.count >= 25 ? header[24] : nil
                    if let q = qualityByte, q == 0x10 {
                        photoQualities[index] = true   // HQ
                    } else if let q = qualityByte, q == 0x20 {
                        photoQualities[index] = false  // SQ
                    } else {
                        let imageWidth = Int(header[8]) << 8 | Int(header[9])
                        photoQualities[index] = imageWidth >= 640
                    }
                }

                // QT200/Fuji: record the camera's own filename (DSC0000N) —
                // INTERNAL only. It keys the cross-session imported-photo maps
                // and is the last-resort naming fallback; the gallery caption
                // stays the uniform "Photo N" unless the user renames.
                if selectedModel.protocolFamily == .fuji, fujiCameraNames[index] == nil,
                   let camName = await DemoCamera.shared.orLive(
                       demo: { DemoCamera.shared.photoName(at: index) },
                       live: { await self.fujiSession.readPhotoName(index: Int(index)) }) {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    fujiCameraNames[index] = (camName as NSString).deletingPathExtension
                }

                // QT200/Fuji: set the HQ/SQ badge from the camera-reported size
                // (cheap — one GetImageSize, no full download), so the badge
                // shows on the thumbnail before import. Don't clobber a quality
                // already determined from a full JPEG.
                if selectedModel.protocolFamily == .fuji, photoQualities[index] == nil,
                   let bytes = await DemoCamera.shared.orLive(
                       demo: { DemoCamera.shared.photoSize(at: index) },
                       live: { await self.fujiSession.readPhotoSize(index: Int(index)) }) {
                    guard cameraWork.isCurrent(workGeneration) else { return }
                    let isFine = self.fujiQuality(fromSizeBytes: bytes)
                    self.photoQualities[index] = isFine
                }

                // QT200/Fuji: recognize a photo we already imported (saved under
                // its EXIF-date name) via the persisted DSC-name map, so we load
                // the disk image and SKIP the camera thumbnail fetch below.
                // Current photo's camera-reported byte size (header[5..7]); used to
                // verify a DSC-name match is really THIS photo, not another QT200's
                // identically-named shot.
                guard cameraWork.isCurrent(workGeneration) else { return }
                let currentSize = Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
                if !suppressImportedRecognition,
                   selectedModel.protocolFamily == .fuji, enhancedPreviewImages[index] == nil,
                   let dsc = fujiCameraNames[index],
                   fujiLedger.importedSize(forDSC: dsc) == currentSize,   // same photo (size matches), not a DSC-name collision
                   let path = fujiLedger.importedPath(forDSC: dsc),
                   FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    self.importedPhotoURLs[index] = [url]
                    if let localImage = NSImage(contentsOf: url) {
                        self.enhancedPreviewImages[index] = localImage
                    }
                }

                guard cameraWork.isCurrent(workGeneration) else { return }
                let dateStr = self.parseImageDate(from: header)
                let untaggedBase = self.importStem(forIndex: index, dateStr: dateStr)
                let baseName = untaggedBase + currentModeSuffix()

                // Look for the imported file across the candidate dirs — the
                // current-mode name first, then the suffix-less name.
                let candidates = [baseName, untaggedBase]
                var expectedFileURL: URL?
                outer: for dir in importDirs {
                    for stem in candidates {
                        let candidate = dir.appendingPathComponent(stem).appendingPathExtension(self.exportFormat.fileExtension)
                        if FileManager.default.fileExists(atPath: candidate.path) { expectedFileURL = candidate; break outer }
                    }
                }

                // For Fuji, this filename match can also collide across two QT200s
                // if their photos happen to share an EXIF timestamp — so if we have
                // a stored size for this DSC name, require it to match the camera's
                // current photo. No stored size (older import) → trust the filename.
                let fujiSizeOK = selectedModel.protocolFamily != .fuji
                    || (fujiCameraNames[index].flatMap { fujiLedger.importedSize(forDSC: $0) }.map { $0 == currentSize } ?? true)
                if !suppressImportedRecognition, fujiSizeOK, let expectedFileURL {
                    self.importedPhotoURLs[index] = [expectedFileURL]
                    if let localImage = NSImage(contentsOf: expectedFileURL) {
                        self.enhancedPreviewImages[index] = localImage
                        // HQ/SQ width fallback — Kodak QT100/150 ONLY (HQ =
                        // 640×480, SQ = 320×240). The QT200 is always
                        // 640×480, so this heuristic would falsely stamp
                        // every QT200 photo HQ; that camera shows no badge
                        // unless quality is truly determined (see
                        // fujiPhotoQuality), so don't apply it here.
                        if self.selectedModel.protocolFamily == .kodak,
                           self.photoQualities[index] == nil {
                            self.photoQualities[index] = localImage.size.width >= 640
                        }
                    }
                }
            }

            // Already-imported photos already have their decoded image loaded
            // from disk — reuse it as the gallery thumbnail and SKIP the camera
            // thumbnail fetch (that's what slowed down reconnecting to a card
            // full of already-imported shots).
            if let imported = enhancedPreviewImages[index] {
                availableThumbnails[index] = imported
            } else if let thumbBytes = await fetchThumbnailBytes(forImageIndex: index) {
                guard cameraWork.isCurrent(workGeneration) else { return }
                // Each family's thumbnail block has its own shape: Fuji is the
                // PIC_GET_THUMB JPEG/raw block, the QT100/150 the QTK 4-bit
                // grayscale.
                let rendered: NSImage?
                switch selectedModel.protocolFamily {
                case .fuji:  rendered = QuickTake200ThumbnailRenderer.render(thumbBytes)
                case .kodak: rendered = QuickTakeThumbnailRenderer.renderImage(from: thumbBytes, model: selectedModel)
                }
                availableThumbnails[index] = rendered ?? placeholder
            } else {
                // A QuickTake photo yielded no thumbnail — with or without a
                // header. (The bench showed a pull usually kills the THUMB
                // read while that photo's header already succeeded; keying
                // the suspicion on header==nil alone left the grey tile AND
                // burned a whole extra photo of timeouts before the abort.)
                // Decide BEFORE touching the cell, so an interrupted cell
                // keeps its swirl and freezes to B&W with its neighbours.
                guard cameraWork.isCurrent(workGeneration) else { return }
                if !isConnected {
                    // The user hit Disconnect mid-fetch — the in-flight read
                    // died with the port. Deliberate action: stop quietly,
                    // no "camera stopped responding" scare banner.
                    break
                }
                // Fast liveness ping (the monitor's own 3-try probe), not
                // the full re-handshake: dead is declared in a couple of
                // seconds instead of after a whole baud-ladder rescue.
                let alive = await checkIfAlive()
                guard cameraWork.isCurrent(workGeneration) else { return }
                if alive {
                    // One-off failure on a live link — this photo alone
                    // takes the placeholder.
                    availableThumbnails[index] = placeholder
                } else {
                    disconnectCamera()
                    self.errorMessage = "The camera stopped responding while loading thumbnails. Check the cable and batteries, then connect again."
                    self.statusMessage = "Camera Stopped Responding"
                    break
                }
            }
            guard cameraWork.isCurrent(workGeneration) else { return }
            thumbnailLoadProgress = (Int(index) + 1, indices.count)
        }
        guard cameraWork.isCurrent(workGeneration) else { return }
        thumbnailLoadProgress = nil
        self.areThumbnailsLoading = false
        // One-shot: only the first fetch after a camera change skips cross-session
        // recognition. Later refreshes (same camera) recognize this camera's own
        // imports normally.
        suppressImportedRecognition = false
        runPendingImportIfNeeded()
    }

    /// Start a deferred import (one requested while the link was busy) now that
    /// the camera is free again.
    private func runPendingImportIfNeeded() {
        guard let pending = pendingImport,
              isConnected, !isBusy, !areThumbnailsLoading, cameraTransfers.isEmpty else { return }
        pendingImport = nil
        batchDownloadImages(to: effectiveImportDestinationURL,
                            importAll: pending.importAll,
                            skipImported: pending.skipImported)
    }

    /// Decode raw camera image bytes into a displayable image, per the model's
    /// storage format. QuickTake 100/150 use the proprietary QTK Bayer pipeline
    /// (`QTKFormatter` + `QTKDecoder`); the QuickTake 200 / Fuji family stores
    /// standard JPEG, which MUST go through `QuickTake200JPEGDecoder` — the QTK
    /// path returns empty data for them and would otherwise yield a black
    /// frame. Returns nil if decoding fails.
    ///
    /// Adapter: snapshots the Look and the demo-camera state on the actor and
    /// hands the decode to `CameraImageRenderer`, which holds the branch logic.
    private func renderCameraImage(model: QuickTakeModel, header: [UInt8], imageData: [UInt8]) -> NSImage? {
        CameraImageRenderer.render(
            model: model, header: header, imageData: imageData,
            options: CameraImageRenderer.Options(
                look: finishedLook,
                // Only the QTK models can carry a JPEG demo stand-in, so —
                // matching the baseline's short-circuit — DemoCamera is not
                // consulted for the Fuji family.
                demoServesFinishedImages: model.usesQTKFormat
                    && DemoCamera.shared.isConnected
                    && DemoCamera.shared.servesFinishedImages
            )
        )
    }

    func downloadPreviewImage(at index: UInt8, model: QuickTakeModel? = nil) {
        // Default to the user-selected model so the QT100/QT150 thumbnail
        // decoders aren't silently mismatched. Caller can still override.
        let model = model ?? self.selectedModel
        guard isConnected else {
            statusMessage = "Connect a Camera First"
            return
        }

        guard !isBusy, !areThumbnailsLoading, !isProbingLiveness else { return }
        setBusy(true, status: "Downloading Image \(index)…")
        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            guard let header = await fetchImageHeader(forImageIndex: index), header.count >= 25 else {
                guard cameraWork.isCurrent(workGeneration) else { return }
                self.isBusy = false
                self.errorMessage = "The camera sent an unreadable response. Try again."
                self.statusMessage = "Couldn't Download Photo \(index)"
                return
            }

            let sizeBytes = [header[5], header[6], header[7]]
            let imageSize = Int(sizeBytes[0]) << 16 | Int(sizeBytes[1]) << 8 | Int(sizeBytes[2])

            guard imageSize > 0,
                  let imageData = await fetchFullImage(
                    forImageIndex: index,
                    imageSize: imageSize,
                    sizeBytes: sizeBytes,
                    progress: { progress in
                        // Silent store, not the (unread) @Published
                        // downloadProgress — a per-chunk publish here was the
                        // QT200/QT150 half of the develop scroll stutter.
                        self.updateLiveProgress(index: index, progress: progress)
                    }
                  ) else {
                guard cameraWork.isCurrent(workGeneration) else { return }
                self.isBusy = false
                self.errorMessage = "The camera didn't send any photo data. Try again."
                self.statusMessage = "Couldn't Download Photo \(index)"
                return
            }

            guard cameraWork.isCurrent(workGeneration) else { return }
            let decodedImage = renderCameraImage(model: model, header: header, imageData: imageData)

            // Mirror the disk-write stamping so the in-app preview
            // matches what gets saved when toggle is on. No-op when off.
            let captureDate = self.parseImageDateAsDate(from: header)
            self.previewImage = decodedImage.map { self.stampedIfEnabled($0, captureDate: captureDate) }
            self.previewedPhotoIndex = index
            self.isBusy = false
            self.errorMessage = decodedImage == nil ? "Preview could not be generated." : nil
            self.statusMessage = decodedImage == nil
                ? "Downloaded Photo \(index), but Decoding Failed"
                : "Downloaded and Decoded Photo \(index)"
        }
    }

    /// Make a previously-imported photo viewable without touching the camera.
    /// Opening a photo imports it (open == import), so any photo that's already
    /// on disk can be shown straight from that file — no re-download, no
    /// duplicate. Loads the on-disk export into the in-memory preview cache and
    /// returns true when a preview is available.
    func loadImportedPreviewIfAvailable(at index: UInt8) -> Bool {
        if enhancedPreviewImages[index] != nil { return true }

        // Prefer the viewable export (HEIC/JPEG/TIFF) over a `.qtk` original,
        // which AppKit can't render directly.
        guard let url = importedPhotoURLs[index]?.first(where: {
            $0.pathExtension.lowercased() != "qtk"
            && FileManager.default.fileExists(atPath: $0.path)
        }), let image = NSImage(contentsOf: url) else {
            return false
        }

        enhancedPreviewImages[index] = image
        previewedPhotoIndex = index
        previewImage = image
        return true
    }

    func batchDownloadImages(to requestedDestination: URL, importAll: Bool = false, skipImported: Bool = false) {
        guard isConnected else {
            statusMessage = "Connect a Camera First"
            return
        }

        var indicesToImport = (importAll ? photoIndices : selectedPhotoIndices.sorted())
        if skipImported {
            indicesToImport = indicesToImport.filter { (importedPhotoURLs[$0]?.isEmpty ?? true) }
        }
        guard !indicesToImport.isEmpty else {
            statusMessage = skipImported
                ? "All Photos Have Already Been Imported"
                : (importAll ? "No Photos Are Available to Import" : "No Photos Selected to Import")
            // Auto-revert so the pill doesn't sit on a stale message; the
            // camera is still connected, so the default phrase belongs back.
            scheduleStatusRevert()
            return
        }

        // Demo mode simulates the import rather than running it. A demo must
        // not leave files in someone's photo folder — and writing them also
        // poisoned the gallery: the cross-session recogniser matched the
        // demo's own output by name, so every photo came back already
        // imported and the thumbnails never appeared to stream.
        if DemoCamera.shared.isConnected {
            guard !isBusy, !areThumbnailsLoading else { return }
            isBusy = true
            cameraWork.start { [self] in await demoImport(indicesToImport) }
            return
        }

        if isBusy || areThumbnailsLoading || isProbingLiveness {
            if cameraImportActive {
                // An import is already running — add these onto its queue.
                queueAdditionalImports(indicesToImport)
            } else {
                // Busy with a non-import task (thumbnail load / refresh), or a
                // liveness probe is mid-flight — defer the import to start the
                // moment the link is free (the monitor re-runs pending imports
                // when its probe ends), instead of refusing or racing the probe's
                // ENQ onto the wire. The Import button always "works".
                pendingImport = (importAll, skipImported)
                statusMessage = "Waiting for the Camera…"
                scheduleStatusRevert()
            }
            return
        }

        // Preflight the destination: if the saved folder vanished or its drive is
        // unplugged, fall back to the default (with a notice) so the import still
        // lands somewhere rather than failing every photo.
        let destinationURL = usableImportDestination(requestedDestination)

        cameraImportActive = true
        setBusy(true, status: "Importing \(indicesToImport.count) Photos…")

        self.downloadProgress = 0
        self.clearCameraProgress()
        self.cameraTransfers = indicesToImport.map {
            PhotoTransfer(index: $0, progress: 0, status: .waiting, savedFiles: [])
        }
        self.lastImportDestination = destinationURL

        self.systemProgress = Progress(totalUnitCount: Int64(indicesToImport.count))
        self.systemProgress?.kind = .file
        self.systemProgress?.setUserInfoObject(Progress.FileOperationKind.downloading, forKey: .fileOperationKindKey)
        self.systemProgress?.isCancellable = false
        self.systemProgress?.publish()

        // Dock badge — Mail/Photos-style progress indicator. Updated as
        // photos finish; cleared in `finishBatchImport` when the run
        // completes (success or failure).
        setDockBadge(completed: 0, total: indicesToImport.count)

        cameraWork.start { [self] in
            let workGeneration = cameraWork.generation
            guard cameraWork.isCurrent(workGeneration) else { return }

            // If the destination fell back to the default (chosen folder gone),
            // let the user read + dismiss that warning BEFORE the download loop —
            // otherwise a duplicate prompt can pop over it and hide what happened.
            while self.destinationFallbackMessage != nil {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }

            guard let outcome = await CameraBatchImportEngine.run(
                destination: destinationURL, importAll: importAll,
                hooks: cameraBatchHooks(workGeneration: workGeneration)
            ) else { return }
            let summary = outcome.summary
            let importedPhotoCount = summary.importedPhotoCount
            let failedPhotoCount = summary.failedPhotoCount

            guard cameraWork.isCurrent(workGeneration) else { return }
            self.cameraImportActive = false
            self.finishBatchImport(summary: summary)
            self.isBusy = false
            self.systemProgress?.unpublish()
            self.systemProgress = nil
            self.clearDockBadge()
            let finishedTransferIDs = Set(self.cameraTransfers.map(\.id))

            // Only post a banner when something actually imported, and word it
            // honestly (failures shouldn't read as "Successfully imported", and
            // a user-stopped run shouldn't read as "Complete"). Wording and
            // branching live in `BatchImportPolicy.completionNotification` — see
            // that file. A mid-import link fault takes its own path —
            // `cameraBatchHooks`'s `interrupted` hook — and never reaches here.
            if let notification = BatchImportPolicy.completionNotification(
                importedPhotoCount: importedPhotoCount, failedPhotoCount: failedPhotoCount,
                stoppedByUser: summary.stoppedByUser
            ) {
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
                for id in finishedTransferIDs { self.liveProgress.values.removeValue(forKey: id) }
                self.cameraTransfers.removeAll { finishedTransferIDs.contains($0.id) }
            }
        }
    }

    /// One immutable per-photo settings snapshot for the camera-import
    /// engine and the re-import batch: every live setting that shapes
    /// naming, the duplicate decision, decode and export, read exactly
    /// once here so callers can thread a single value through the awaits
    /// in between instead of re-reading `self` and risking a mid-photo
    /// change splitting the collision decision from what gets written.
    private func cameraImportSettingsSnapshot() -> CameraBatchImportEngine.Settings {
        CameraBatchImportEngine.Settings(
            isFuji: selectedModel.protocolFamily == .fuji,
            keepOriginal: keepOriginalQTK && selectedModel.usesQTKFormat,
            fileExtension: exportFormat.fileExtension,
            formatUTIIdentifier: exportFormat.uti.identifier,
            isLossyFormat: exportFormat == .jpeg || exportFormat == .heic,
            archiveDirectory: effectiveQTKDestinationURL,
            colorModeSuffix: currentModeSuffix(),
            colorModeLabel: currentColorModeLabel(),
            dateStampEnabled: captureDateStampEnabled,
            enhancedColor: newTakeEnabled,
            hdrEnabled: hdrOutputActive,
            hdrHeadroom: hdrHeadroom
        )
    }

    /// Adapts the batch engine to this session's serial methods and UI state.
    private func cameraBatchHooks(workGeneration: UInt64) -> CameraBatchImportEngine.Hooks {
        CameraBatchImportEngine.Hooks(
            isCurrent: { self.cameraWork.isCurrent(workGeneration) },
            queue: { self.cameraTransfers.map(\.index) },
            settingsSnapshot: { self.cameraImportSettingsSnapshot() },
            readHeader: { await self.fetchImageHeader(forImageIndex: $0) },
            recover: { await self.rewakeSessionAfterFailure() },
            ensureCameraName: { index in
                if self.selectedModel.protocolFamily == .fuji, self.fujiCameraNames[index] == nil,
                   let name = await DemoCamera.shared.orLive(
                       demo: { DemoCamera.shared.photoName(at: index) },
                       live: { await self.fujiSession.readPhotoName(index: Int(index)) }) {
                    guard self.cameraWork.isCurrent(workGeneration) else { return }
                    self.fujiCameraNames[index] = (name as NSString).deletingPathExtension
                }
            },
            preliminaryName: { index, header, settings in
                self.importStem(forIndex: index, dateStr: self.parseImageDate(from: header)) + settings.colorModeSuffix
            },
            fujiName: { index, bytes in
                Self.fujiDateStem(jpeg: bytes, cameraName: self.photoNames[index] ?? self.fujiCameraNames[index])
            },
            chooseDuplicate: { await self.promptForDuplicate(fileName: $0) },
            importedURLs: { self.importedPhotoURLs[$0] ?? [] },
            fetchImage: { index, size, sizeBytes, progress in
                await self.fetchFullImage(forImageIndex: index, imageSize: size, sizeBytes: sizeBytes, progress: progress)
            },
            makeArchive: { index, header, bytes in
                QTLog.note("HEADER", "photo \(index) header", bytes: Array(header.prefix(28)))
                let archive = QTKFormatter.buildQTKData(model: self.selectedModel, imageHeader: header, imageData: bytes)
                QTLog.note("ARCHIVE", "QTK built", detail:
                    "model=\(self.selectedModel.displayName) magic=\(archive.count >= 4 ? String(bytes: archive.prefix(4), encoding: .ascii) ?? "?" : "?") "
                    + "bytes=\(archive.count) (header 736 + payload \(max(0, archive.count - 736)))")
                return archive
            },
            decode: { index, archive, bytes, settings in
                if self.selectedModel.usesQTKFormat {
                    return await self.decodeWithProgress(qtkData: archive, forIndex: index,
                                                         from: 0.7, to: 0.95, estimatedSeconds: 1.5,
                                                         settings: settings)
                }
                self.updateTransfer(index: index, progress: 0.9, status: .decoding, savedFiles: nil)
                let look = FinishedLookSettings(enhanced: settings.enhancedColor, hdr: settings.hdrEnabled,
                                                headroom: settings.hdrHeadroom)
                return await Task.detached(priority: .userInitiated) {
                    SendableImageBox(image: Self.applyFinishedLook(
                        (try? QuickTake200JPEGDecoder.decode(Data(bytes)))?.image, look))
                }.value.image
            },
            export: { image, name, directory, header, settings, allowReplace in
                try await self.exportImage(image, named: name, to: directory, header: header, settings: settings,
                                           collisionMode: allowReplace ? .replace : .exclusive,
                                           isCurrent: { self.cameraWork.isCurrent(workGeneration) })
            },
            update: { self.updateTransfer(index: $0, progress: $1, status: $2, savedFiles: $3) },
            didSkip: { index, files, renderedURL in
                self.importedPhotoURLs[index] = files
                if let image = NSImage(contentsOf: renderedURL) { self.enhancedPreviewImages[index] = image }
            },
            didSave: { photo in self.recordCameraImport(photo) },
            interrupted: { report in
                // Teardown first and synchronously — see `disconnectCamera`'s
                // own comment on why deferring it behind an await reopens
                // the double-banner race. Everything below publishes from
                // `report`, captured before teardown touched anything.
                self.disconnectCamera()
                let teardownGeneration = self.cameraWork.generation
                // Transient overlay — safe to publish unconditionally even
                // if a newer connection races in right behind it.
                self.presentToast(.connectionLost)
                // The status pill and error text are sticky, so only write
                // them if nothing newer has claimed the connection since
                // teardown — never stomp a fresh connect's status.
                if self.cameraWork.generation == teardownGeneration {
                    self.errorMessage = "The camera stopped responding mid-import. Check the cable and batteries, then connect again — photos already imported are safe on disk."
                    self.statusMessage = "Import Interrupted"
                }
                guard report.importedPhotoCount > 0 else { return }
                let content = UNMutableNotificationContent()
                content.title = "Import Stopped"
                content.body = "Imported \(report.importedPhotoCount) photos before the camera disconnected."
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            },
            logTransfer: { index, announced, received in
                QTLog.note("TRANSFER", "photo \(index) complete", detail:
                    "announced=\(announced) received=\(received)"
                    + (received == announced ? " (exact)" : " ** MISMATCH **"))
            }
        )
    }

    private func recordCameraImport(_ photo: CameraBatchImportEngine.SavedPhoto) {
        if selectedModel.protocolFamily == .fuji {
            fujiLedger.record(dscName: fujiCameraNames[photo.index], url: photo.exportedURL, size: photo.imageSize)
        }
        let captureDate = parseImageDateAsDate(from: photo.header)
        enhancedPreviewImages[photo.index] = stampedIfEnabled(photo.image, captureDate: captureDate,
                                                               stampEnabled: photo.settings.dateStampEnabled)
        if photo.position == 0 {
            previewImage = stampedIfEnabled(photo.image, captureDate: parseImageDateAsDate(from: photo.header),
                                            stampEnabled: photo.settings.dateStampEnabled)
        }
        systemProgress?.completedUnitCount = Int64(photo.importedCount)
        importedPhotoURLs[photo.index] = photo.files
        updateTransfer(index: photo.index, progress: 1, status: .imported, savedFiles: photo.files)
        downloadProgress = Double(photo.position + 1) / Double(max(cameraTransfers.count, 1))
        setDockBadge(completed: photo.position + 1, total: cameraTransfers.count)
    }

    private func queueAdditionalImports(_ indices: [UInt8]) {
        let existing = Set(cameraTransfers.map(\.index))
        let queuedIndices = indices.filter { !existing.contains($0) }

        guard !queuedIndices.isEmpty else {
            statusMessage = "Already Queued for Import"
            scheduleStatusRevert()
            return
        }

        cameraTransfers.append(contentsOf: queuedIndices.map {
            PhotoTransfer(index: $0, progress: 0, status: .waiting, savedFiles: [])
        })
        systemProgress?.totalUnitCount = Int64(cameraTransfers.count)

        let completed = cameraTransfers.filter { $0.progress >= 1 }.count
        setDockBadge(completed: completed, total: cameraTransfers.count)
        statusMessage = queuedIndices.count == 1
            ? "Queued Photo \(Int(queuedIndices[0]) + 1) for Import"
            : "Queued \(queuedIndices.count) More Photos for Import"
    }

    // MARK: - Drag-and-drop import

    /// Shared engine for the drag-and-drop importers. A drop behaves like a
    /// serial import: files decode off the main actor and export to the SAME
    /// destination chosen in Settings (with the unavailable-folder fallback
    /// and its explanatory alert), and name clashes resolve with a silent
    /// "name 2" suffix (the serial Fuji convention). Two deliberate
    /// differences from serial: "Keep Original Files" does NOT
    /// apply — the dropped files ARE the originals, already in the user's
    /// hands — and the run always ends with a Finder reveal of what landed,
    /// regardless of the post-import setting.
    ///
    /// This method stays a thin adapter: it owns the `@Published` chip
    /// state, the destination preflight/security-scope balance and the
    /// queue-release semantics, then hands the actual decode/export loop to
    /// `FileImportPipeline`, which touches no manager state.
    private func convertDroppedFiles(
        _ urlDataMap: [URL: Data],
        decode: @escaping @Sendable (URL, Data) -> FileImportPipeline.DropConversion?
    ) async {
        guard !urlDataMap.isEmpty else { return }
        if dropConversionActive {
            await withCheckedContinuation { dropConversionWaiters.append($0) }
        } else { dropConversionActive = true }
        defer {
            if dropConversionWaiters.isEmpty { dropConversionActive = false }
            else { dropConversionWaiters.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return }

        // Same destination preflight as a serial import; give the user time
        // to read the fallback alert before files start landing.
        let destination = usableImportDestination(effectiveImportDestinationURL)
        while destinationFallbackMessage != nil {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
        }

        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Sort by filename so multi-file drops process in shot order (DSC
        // names and dated stems sort naturally) instead of dictionary order.
        let sorted = FileImportPipeline.sortedByFilename(urlDataMap)

        // All chips up front at 0, like a serial batch import, so the bottom
        // bar starts empty and visibly fills — a drop reads as a quick load
        // rather than an instantly-full "Import Complete". Each chip's own
        // generated `id` becomes the pipeline item's identity, so progress
        // and terminal results report back to the exact right chip.
        var items: [FileImportPipeline.Item] = []
        for (index, entry) in sorted.enumerated() {
            let chip = PhotoTransfer(index: UInt8(index & 0xFF),   // masked so 256+ drops can't trap
                                     progress: 0, status: .waiting, savedFiles: [])
            droppedTransfers.append(chip)
            items.append(FileImportPipeline.Item(id: chip.id, url: entry.url, data: entry.data))
        }

        let summary = await FileImportPipeline.run(
            items: items,
            decode: decode,
            exportDecoded: { baseName, image, captureDate, header in
                try await self.resolveAndExportDroppedFile(baseName: baseName, image: image,
                                                            captureDate: captureDate, header: header, to: destination)
            },
            onUpdate: { id, progress, status, savedFiles in
                self.updateDroppedTransfer(id: id, progress: progress, status: status, savedFiles: savedFiles)
            }
        )

        if !isBusy { lastImportDestination = destination }
        finishDropConversion(succeeded: summary.succeeded, decodeFailures: summary.decodeFailures,
                              saveFailures: summary.saveFailures, importedFiles: summary.importedFiles, cancelled: summary.cancelled)

        // Match the serial batch: hold the finished bar (green check +
        // "Import Complete") for a beat, then clear these chips.
        let finishedIDs = Set(items.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.droppedTransfers.removeAll { finishedIDs.contains($0.id) }
            for id in finishedIDs { self.liveProgress.values.removeValue(forKey: id) }
        }
    }

    /// Dropped `.qtk` archives (QuickTake 100/150) — decoded through the
    /// currently selected colour pipeline, exactly like a re-import.
    func convertDroppedQTKFiles(_ urlDataMap: [URL: Data]) async {
        // Snapshot the pipeline settings on the main actor; the decode
        // closure runs detached.
        let enhanced = newTakeEnabled
        let hdr = hdrOutputActive, headroom = hdrHeadroom
        await convertDroppedFiles(urlDataMap) { url, qtkData in
            guard let image = QTKDecoder().decode(data: qtkData, enhanced: enhanced,
                                                  hdrEnabled: hdr, hdrHeadroom: headroom) else { return nil }
            return FileImportPipeline.DropConversion(
                image: image,
                captureDate: nil,   // exportImage reads the date from the QTK header
                baseName: url.deletingPathExtension().lastPathComponent,
                header: Self.imageHeaderFromQTK(qtkData)
            )
        }
    }

    // (No JPEG drop importer, deliberately: the QT200's card files are
    // finished JPEGs — there is nothing to decode, so drops accept only the
    // proprietary raw formats.)

    /// Resolve the name and prepare the export on MainActor before suspending.
    private func resolveAndExportDroppedFile(
        baseName decodedBaseName: String, image: NSImage, captureDate: Date?, header: [UInt8]?, to destination: URL
    ) async throws -> URL? {
        try Task.checkCancellation()
        let fileExtension = exportFormat.fileExtension
        var baseName = decodedBaseName
        var n = 2
        while FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(baseName).appendingPathExtension(fileExtension).path
        ) {
            baseName = "\(decodedBaseName) \(n)"
            n += 1
        }
        // `baseName` was just resolved to a non-colliding name above —
        // exclusive catches a same-name file that appears between that
        // check and this publish. `isCurrent` reads the drop conversion's
        // own task cancellation (there's no camera generation involved).
        return try await exportImage(image, named: baseName, to: destination, captureDate: captureDate, header: header,
                                     collisionMode: .exclusive, isCurrent: { !Task.isCancelled })
    }

    /// Shared finish for the drag-and-drop importers: honest status, then a
    /// Finder reveal of the files that landed — ALWAYS, regardless of the
    /// post-import setting (a drop is a deliberate "convert these now", so
    /// show the result). Never touches the destination folder
    /// itself (it's the user's folder).
    ///
    /// `decodeFailures` and `saveFailures` are tracked separately by
    /// `FileImportPipeline` so this message never blames the input for a
    /// write problem, or vice versa.
    private func finishDropConversion(succeeded: Int, decodeFailures: Int, saveFailures: Int, importedFiles: [URL], cancelled: Bool) {
        if isBusy || isConnecting || areThumbnailsLoading {
            if !importedFiles.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(importedFiles) }
            return
        }
        if cancelled {
            statusMessage = succeeded == 0 ? "Import Stopped" : "Import Stopped — Imported \(succeeded) Files"
            errorMessage = nil
            if !importedFiles.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(importedFiles) }
            scheduleStatusRevert()
            return
        }
        let failed = decodeFailures + saveFailures
        if succeeded > 0 {
            if failed > 0 {
                statusMessage = "Imported \(succeeded) File\(succeeded == 1 ? "" : "s") — \(failed) Failed"
                errorMessage = dropFailureExplanation(decodeFailures: decodeFailures, saveFailures: saveFailures)
            } else {
                statusMessage = "Imported \(succeeded) File\(succeeded == 1 ? "" : "s")"
                errorMessage = nil
            }
            NSWorkspace.shared.activateFileViewerSelecting(importedFiles)
        } else {
            if saveFailures > 0 && decodeFailures == 0 {
                statusMessage = "Couldn’t Save the Dropped File\(failed == 1 ? "" : "s")"
            } else if decodeFailures > 0 && saveFailures == 0 {
                statusMessage = "Couldn’t Read the Dropped File\(failed == 1 ? "" : "s")"
            } else {
                statusMessage = "Couldn’t Import the Dropped Files"
            }
            errorMessage = dropFailureExplanation(decodeFailures: decodeFailures, saveFailures: saveFailures)
        }
        scheduleStatusRevert()
    }

    /// Honest aggregate explanation for a drop's failures: a decode failure
    /// means the bytes never parsed (corrupt or unsupported input); a save
    /// failure means the file decoded fine but the export write failed or
    /// was refused (destination full, read-only, or gone). The two are
    /// never described as the same problem — see `FileImportPipeline`.
    private func dropFailureExplanation(decodeFailures: Int, saveFailures: Int) -> String {
        switch (decodeFailures > 0, saveFailures > 0) {
        case (true, false):
            return "\(decodeFailures) dropped file\(decodeFailures == 1 ? "" : "s") couldn’t be decoded — " +
                "they may be corrupt or an unsupported format."
        case (false, true):
            return "\(saveFailures) dropped file\(saveFailures == 1 ? "" : "s") decoded but couldn’t be saved — " +
                "check that the destination folder has room and you can write to it."
        case (true, true):
            return "\(decodeFailures) dropped file\(decodeFailures == 1 ? "" : "s") couldn’t be decoded, and " +
                "\(saveFailures) more decoded but couldn’t be saved."
        case (false, false):
            return "Some dropped files had errors."
        }
    }

    // MARK: - Metadata & Thumbnails

    private func fetchMetadata() async -> CameraMetadata? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }

        if DemoCamera.shared.isConnected { return DemoCamera.shared.metadata() }

        // Fuji-family cameras don't expose a single 128-byte status
        // block; build CameraMetadata from individual queries instead.
        if selectedModel.protocolFamily == .fuji {
            // These MUST run sequentially: they share one serial port, and
            // the Fuji request/response choreography (send frame → read ACK →
            // read reply) can't tolerate a second command interleaving with
            // the first. Do not parallelize with `async let`.
            // Clamp to the gallery's UInt8 index space: PIC_COUNT is a 16-bit
            // wire field, and a corrupt reply claiming more than 255 photos
            // would trap the `UInt8` conversions downstream (fetchAllThumbnails,
            // takePicture). Real cards hold far fewer, so the clamp is inert
            // in practice and purely a corrupt-reply guard.
            // A FAILED count read must fail the whole metadata fetch — not
            // masquerade as "0 photos". A dozing QT200's first read after an
            // idle stretch returned nil here; the old `?? 0` built "valid"
            // metadata with zero photos and fetchAllThumbnails dutifully
            // emptied the gallery (bench: Reload Gallery's first click made
            // every thumbnail disappear). A genuinely empty card reports 0,
            // not nil, so nothing legitimate is lost.
            guard let rawPhotoCount = await fujiSession.readPhotoCount() else { return nil }
            let picturesTaken = min(rawPhotoCount, 255)
            let modelResult = await fujiSession.readModelString()
            guard cameraWork.isCurrent(workGeneration) else { return nil }
            let cameraName: String = (modelResult?.isEmpty == false)
                ? (modelResult ?? selectedModel.displayName)
                : selectedModel.displayName
            let flashMode: String
            switch (await fujiSession.readFlashMode()) ?? 0xFF {
            case 0:  flashMode = "Auto"
            case 1:  flashMode = "Disabled"
            case 2:  flashMode = "Forced"
            default: flashMode = "Unknown"
            }
            return CameraMetadata(
                batteryLevel: nil,              // not exposed by the Fuji command set
                picturesTaken: picturesTaken,
                picturesRemaining: nil,         // card-backed, no fixed-frame "remaining"
                flashMode: flashMode,
                cameraName: cameraName,
                quality: "Fine",                // SETFEATURE 'impm' wire bytes TBD
                isHighQuality: true
            )
        }

        guard let payload = await session.readDeviceInfo(), payload.count == 128 else { return nil }
        // Kodak bodies have fixed internal storage: an empty camera must still
        // have room for photos. Reject a shifted/transient 0-taken, 0-remaining
        // reply rather than emptying the gallery and displaying "Storage full".
        guard payload[4] > 0 || payload[6] > 0 else {
            QTLog.note("METADATA", "invalid zero-capacity device info", bytes: payload)
            return nil
        }

        let flashMode: String
        switch payload[22] {
        case 0: flashMode = "Auto"
        case 1: flashMode = "Disabled"
        case 2: flashMode = "Forced"
        default: flashMode = "Unknown"
        }

        let nameBytes = Array(payload[47..<79])
        let name = String(bytes: nameBytes, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? "QuickTake"

        let quality: String
        let isHighQuality: Bool
        switch payload[27] {
        case 16:
            quality = "High"
            isHighQuality = true
        case 32:
            quality = "Standard"
            isHighQuality = false
        default:
            quality = "Unknown"
            isHighQuality = false
        }

        return CameraMetadata(
            batteryLevel: Int(payload[2]),
            picturesTaken: Int(payload[4]),
            picturesRemaining: Int(payload[6]),
            flashMode: flashMode,
            cameraName: name.isEmpty ? "QuickTake" : name,
            quality: quality,
            isHighQuality: isHighQuality
        )
    }

    // MARK: - Image Downloads

    private func fetchThumbnailBytes(forImageIndex index: UInt8) async -> [UInt8]? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }

        if DemoCamera.shared.isConnected { return await DemoCamera.shared.thumbnailBytes(at: index) }
        switch selectedModel.protocolFamily {
        case .kodak:
            return await session.readThumbnail(index: index)
        case .fuji:
            // Camera-side thumbnail: PIC_GET_THUMB (0x00), a fixed ~10.5KB
            // (60×175) block, 1-based index. At the negotiated 115200 this is
            // ~1s each. Rendered by `QuickTake200ThumbnailRenderer`
            // (ImageIO-first since the block is tagged JPEG, with a raw
            // 60×175 grayscale fallback).
            return await fujiSession.readPhotoThumbnail(index: Int(index))
        }
    }

    private func fetchImageHeader(forImageIndex index: UInt8) async -> [UInt8]? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }

        if DemoCamera.shared.isConnected { return DemoCamera.shared.imageHeader(at: index) }
        switch selectedModel.protocolFamily {
        case .kodak:
            return await session.readPhotoHeader(index: index)
        case .fuji:
            // Fuji has no fixed-format per-photo header — synthesize a
            // 64-byte block with the file size at [5][6][7] (big-endian
            // 24-bit, the layout every Kodak caller already parses) so
            // the downstream fetchFullImage path works without per-family
            // edits in the callers.
            guard let size = await fujiSession.readPhotoSize(index: Int(index)) else { return nil }
            var header = [UInt8](repeating: 0, count: 64)
            header[5] = UInt8((size >> 16) & 0xFF)
            header[6] = UInt8((size >>  8) & 0xFF)
            header[7] = UInt8( size        & 0xFF)
            return header
        }
    }

    private func fetchFullImage(
        forImageIndex index: UInt8,
        imageSize: Int,
        sizeBytes: [UInt8],
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }

        guard sizeBytes.count == 3 else { return nil }

        // The session actors call `progress` from their OWN executor, but every
        // caller's closure mutates @MainActor @Published state (downloadProgress /
        // cameraTransfers). Hop each callback onto the main actor — ordered (the
        // main queue is FIFO, so the bar stays monotonic) — instead of racing on
        // that state off-main.
        let progress = progress.map { cb in { [weak self] (value: Double) in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cameraWork.isCurrent(workGeneration) else { return }
                cb(value)
            }
        } }

        // Demo mode serves the same bytes a camera would, paced so the
        // progress bar behaves like a real transfer rather than snapping to
        // 100%. Everything past this point — decode, colour pipeline, export,
        // naming, dedup — is the real import.
        if DemoCamera.shared.isConnected {
            return await DemoCamera.shared.fullImage(at: index, progress: progress)
        }

        switch selectedModel.protocolFamily {
        case .kodak:
            return await session.readPhoto(index: index, byteCount: imageSize, sizeField: sizeBytes, progress: progress)
        case .fuji:
            // Reuse a previously-downloaded copy (e.g. fetched for the gallery
            // thumbnail) instead of pulling the ~87KB JPEG off the camera twice.
            if let cached = fujiJPEGCache[index] { return cached }
            let jpeg = await fujiSession.readPhotoJPEG(index: Int(index), expectedSize: imageSize, progress: progress)
            guard cameraWork.isCurrent(workGeneration) else { return nil }
            if let jpeg {
                fujiJPEGCache[index] = jpeg
                // Upgrade the gallery from placeholder to a real low-res
                // thumbnail now that we have the actual image bytes.
                if let thumb = QuickTake200JPEGDecoder.thumbnail(from: Data(jpeg)) {
                    availableThumbnails[index] = thumb
                }
                // Now that the real JPEG is in hand, settle HQ/SQ from it.
                if let quality = fujiPhotoQuality(jpeg: jpeg) {
                    photoQualities[index] = quality
                }
            } else {
                // The session already drained + EOT'd a half-read transfer;
                // re-handshake so the link is clean for the next photo (and so
                // the 10s liveness monitor doesn't see garbage and disconnect).
                _ = await fujiSession.handshake()
                guard cameraWork.isCurrent(workGeneration) else { return nil }
            }
            return jpeg
        }
    }

    /// Filename stem for a QT200 import: "QuickTake200_<date>_<time>" from the
    /// EXIF capture time — e.g. "QuickTake200_1996-01-01_001134". The time
    /// varies per shot even when the camera clock is unset, so files still sort
    /// in capture order. Falls back to `cameraName` (the DSC name) if the JPEG
    /// has no EXIF date.
    private nonisolated static func fujiDateStem(jpeg: [UInt8], cameraName: String?) -> String {
        NamingMetadataPolicy.fujiDateStem(
            captureDate: QuickTake200JPEGDecoder.captureDate(from: Data(jpeg)),
            cameraName: cameraName
        )
    }

    /// Best-effort Fine(HQ) / Normal(SQ) for a QT200 JPEG. Returns true for
    /// Fine, false for Normal, nil when the image can't be measured. Adapter
    /// over `FujiQualityClassifier`, which owns the threshold and the
    /// bits-per-pixel formula shared with `fujiQuality(fromSizeBytes:)`.
    private func fujiPhotoQuality(jpeg: [UInt8]) -> Bool? {
        FujiQualityClassifier.isFine(jpeg: jpeg)
    }

    /// Fine(HQ)/Normal(SQ) from the camera-reported compressed byte size alone —
    /// no full download. Lets the gallery show the badge on a thumbnail (during
    /// enumeration) before import.
    private func fujiQuality(fromSizeBytes bytes: Int) -> Bool {
        FujiQualityClassifier.isFine(fromSizeBytes: bytes)
    }

    private func parseImageDate(from header: [UInt8]) -> String? {
        NamingMetadataPolicy.parseImageDate(from: header)
    }

    /// Mail/Photos-style "12/24" progress indicator on the Dock icon.
    /// `badgeLabel` keeps the app's icon visible and just paints a red
    /// bubble on top, rather than replacing the icon.
    private func setDockBadge(completed: Int, total: Int) {
        NSApp.dockTile.badgeLabel = "\(completed)/\(total)"
    }

    private func clearDockBadge() {
        NSApp.dockTile.badgeLabel = nil
    }

    private func setBusy(_ busy: Bool, status: String) {
        self.isBusy = busy
        self.statusMessage = status
        if busy {
            self.errorMessage = nil
            statusRevertTask?.cancel()
        }
    }

    /// Leave a busy state without emptying the status pill.
    ///
    /// `setBusy(false, status: "")` writes an EMPTY statusMessage, and the
    /// pill renders that as a bare orb with no label — so every exit from
    /// the panorama flow (finish, cancel, save, failure) left a blank orb
    /// sitting in the corner until something else happened to speak. Every
    /// other long job ends by letting its last message stand and scheduling
    /// the revert back to the idle phrase; the panorama paths never did.
    ///
    /// Passing a message shows it and then reverts. Passing nothing keeps
    /// whatever was last said — "Stitched 5 photos into a panorama." — and
    /// reverts from there, which is the right behaviour on cancel too.
    private func endBusy(status: String = "") {
        isBusy = false
        if !status.isEmpty {
            statusMessage = status
        } else if statusMessage.isEmpty {
            statusMessage = defaultIdleStatus
        }
        scheduleStatusRevert()
    }

    private func scheduleStatusRevert() {
        statusRevertTask?.cancel()
        statusRevertTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !isBusy, isConnected else { return }
            // Re-converge on the same baseline phrase `clearMessages`
            // would produce — typically "Connected to {cameraName}." —
            // so the pill returns to the same default no matter which
            // action was running.
            statusMessage = defaultIdleStatus
            errorMessage = nil
        }
    }

    /// Short tag identifying the current colour-correction mode, used in
    /// filename suffixes so different pipelines don't overwrite each other.
    /// Empty for the vintage PerfectColor default; a suffix appears only when
    /// Enhanced is actually on:
    ///   ""         → PerfectColor vintage (the normal look)
    ///   "newtake"  → NewTake on, HDR included when the format carries
    ///                it. HDR only
    ///                exists on .heic exports, so it can never collide with
    ///                a NewTake .tiff/.png, which is why HDR has no tag of
    ///                its own (bench: "the _enhanced suffix isn't added").
    func currentColorModeTag() -> String {
        newTakeEnabled ? "newtake" : ""
    }

    /// The filename suffix for the active mode ("_newtake"), or "" for the
    /// PerfectColor default.
    func currentModeSuffix() -> String {
        let tag = currentColorModeTag()
        return tag.isEmpty ? "" : "_\(tag)"
    }

    /// Human-readable label for the active mode — surfaced in menus, status
    /// messages, and confirmation dialogs. Unlike the file TAG, the label
    /// still names HDR when it's genuinely applying.
    func currentColorModeLabel() -> String {
        if hdrOutputActive {
            return "NewTake HDR"
        }
        return newTakeEnabled ? "NewTake" : "Vintage"
    }

    /// Removes previous colour-mode suffixes before re-import.
    private func stripModeTag(from stem: String) -> String {
        NamingMetadataPolicy.stripModeTag(from: stem)
    }

    /// Re-import a single already-imported photo through whatever colour
    /// pipeline is currently selected in Settings. Decodes from the
    /// locally saved `.qtk` if it exists; otherwise re-fetches from
    /// the camera. Drives the same `cameraTransfers` progress bar as
    /// the initial-import flow, so the visual treatment is identical
    /// whether the user double-clicks a thumbnail to import or
    /// right-clicks "Import Again" — same colourful progress UI in
    /// the gallery, not just a status-pill update.
    func reimportPhoto(at index: UInt8) {
        // QTK colour-pipeline only (QT100/150). No-op for the QT200's JPEGs.
        guard selectedModel.usesQTKFormat, !isBusy, !areThumbnailsLoading, !isProbingLiveness else { return }
        isBusy = true
        // Demo stand-ins are finished JPEGs, not raw Bayer payloads. Keep
        // them out of QTK reconstruction and refresh their preview instead.
        if DemoCamera.shared.isConnected {
            cameraWork.start { [self] in await demoImport([index]) }
            return
        }
        cameraWork.start { [self] in await performReimportBatch(indices: [index], requireConfirmation: false) }
    }

    /// The engine behind `reimportPhoto(at:)`, which today means the Copland
    /// develop. Populates `cameraTransfers` so the gallery's progress bar
    /// shows up exactly the way it does during a fresh import. For each index
    /// it tries `.qtk` on disk first and falls back to the camera; the two
    /// flows produce identical bytes (a QTK blob), so everything downstream —
    /// decode, filename, write, EXIF embed — is the same path.
    ///
    /// Still takes a list and a confirmation flag though only ever called
    /// with one index and `false`: it was shared with a bulk re-decode
    /// command that has since been removed, and the batch shape is what makes
    /// the progress bar work.
    private func performReimportBatch(indices: [UInt8], requireConfirmation: Bool) async {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return }

        let label = currentColorModeLabel()
        let suffix = currentModeSuffix()
        let destination = effectiveImportDestinationURL

        if requireConfirmation {
            let count = indices.count
            let alert = NSAlert()
            alert.messageText = "Re-import \(count) Photo\(count == 1 ? "" : "s") as \(label)?"
            alert.informativeText = """
                Each photo will be decoded again with the current pipeline and written as `…\(suffix).\(exportFormat.fileExtension)` to your photo folder:

                \(destination.path(percentEncoded: false))

                Photos with a saved `.qtk` archive re-decode offline; the rest re-fetch from the camera if it's connected. Photos already saved with this colour mode and export format will be skipped.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Re-import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Populate the transfer list up front so the colourful gallery
        // progress bar appears immediately — same UI as a fresh import.
        setBusy(true, status: "\(label) — 0 of \(indices.count)…")
        clearCameraProgress()
        cameraTransfers = indices.map {
            PhotoTransfer(index: $0, progress: 0, status: .waiting, savedFiles: [])
        }
        setDockBadge(completed: 0, total: indices.count)

        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { destination.stopAccessingSecurityScopedResource() }
        }

        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var processed = 0
        var failed = 0

        for index in indices {
            guard cameraWork.isCurrent(workGeneration) else { return }
            // One settings snapshot for THIS photo, taken before its own
            // fetch/decode/export awaits — same contract as the camera
            // batch engine, so a settings change mid-photo can't separate
            // the skip-if-already-current filename below from what decode
            // and export actually use for it. Takes effect next photo.
            let settings = cameraImportSettingsSnapshot()
            // Compute the destination filename up front so we can
            // skip-if-already-current BEFORE paying for the QTK fetch
            // (which may round-trip to the camera over serial) and the
            // 1–2-second decode. A re-import only adds value if either
            // the colour mode (folded into `tag` → `taggedBase`) or the
            // export format (`fileExtension`) has changed since the
            // file was last written; otherwise the result would be a
            // byte-for-byte duplicate of what's already on disk.
            let baseStem = baseFilenameStem(forIndex: index)
            let taggedBase = baseStem + settings.colorModeSuffix
            let expectedURL = destination
                .appendingPathComponent(taggedBase)
                .appendingPathExtension(settings.fileExtension)

            if FileManager.default.fileExists(atPath: expectedURL.path) {
                // Already saved with the current colour-mode tag AND
                // current export-format extension. Mark the transfer
                // complete, surface the URL to the gallery, and move
                // on without re-decoding.
                var urls = importedPhotoURLs[index] ?? []
                if !urls.contains(expectedURL) { urls.append(expectedURL) }
                importedPhotoURLs[index] = urls
                processed += 1
                updateTransfer(
                    index: index,
                    progress: 1.0,
                    status: .alreadyCurrent,
                    savedFiles: [expectedURL]
                )
                setDockBadge(completed: processed, total: indices.count)
                statusMessage = "\(label) — \(processed) of \(indices.count)…"
                continue
            }

            updateTransfer(index: index, progress: 0.05, status: .reading, savedFiles: nil)

            // Resolve QTK bytes — disk first, then camera. Capped at
            // 0.65 so there's room for decode (0.65→0.92) and write
            // (0.92→1.0) phases to keep the bar visibly advancing.
            let qtkData = await loadOrFetchQTK(forIndex: index, progress: { p in
                self.updateTransfer(index: index, progress: 0.05 + p * 0.6, status: .downloading, savedFiles: nil)
            })
            // Re-check immediately on resume, before branching on the
            // result: a stale generation (the job was superseded while
            // this await was suspended) must not touch the transfer list
            // or the failure count on EITHER the success or failure path.
            guard cameraWork.isCurrent(workGeneration) else { return }
            guard let qtkData else {
                updateTransfer(index: index, progress: 0, status: .noSource, savedFiles: nil)
                failed += 1
                continue
            }

            // Decode off the main actor with phantom-progress so the
            // bar keeps moving during the 1–2s decode window.
            let decoded = await decodeWithProgress(
                qtkData: qtkData,
                forIndex: index,
                from: 0.65,
                to: 0.92,
                estimatedSeconds: 1.5,
                settings: settings
            )
            guard cameraWork.isCurrent(workGeneration) else { return }
            guard let decoded else {
                updateTransfer(index: index, progress: 0, status: .decodingFailed, savedFiles: nil)
                failed += 1
                continue
            }

            updateTransfer(index: index, progress: 0.95, status: .writing, savedFiles: nil)

            do {
                let newURL = try await exportImage(
                    decoded,
                    named: taggedBase,
                    to: destination,
                    header: Self.imageHeaderFromQTK(qtkData),
                    settings: settings,
                    // `expectedURL` was just verified non-existent above (the
                    // "already current" branch handles the exists case) —
                    // exclusive catches a same-name file that appears
                    // between that check and this publish.
                    collisionMode: .exclusive,
                    isCurrent: { self.cameraWork.isCurrent(workGeneration) }
                )
                guard cameraWork.isCurrent(workGeneration) else { return }
                // `ReimportPostExportDecision.apply` is the one real place
                // that decides what an export attempt changes: on success,
                // retire any Copland artifact (exact-match only — never by
                // substring, so an ordinary file that merely contains
                // "copland" in its name is never touched) and record the
                // new URL; on failure (`newURL == nil`), it returns `nil`
                // and nothing changes. Same function in production and in
                // the harness's tests — not a hand-copied mirror of it.
                let decision = ReimportPostExportDecision.apply(
                    exportedURL: newURL,
                    existingURLs: importedPhotoURLs[index] ?? [],
                    cleanStem: baseStem,
                    destination: destination,
                    removeFile: { try? FileManager.default.removeItem(at: $0) }
                )
                if let updatedURLs = decision, let newURL {
                    processed += 1
                    importedPhotoURLs[index] = updatedURLs
                    if let nsImg = NSImage(contentsOf: newURL) {
                        enhancedPreviewImages[index] = nsImg
                    }
                    updateTransfer(index: index, progress: 1.0, status: .reimported, savedFiles: [newURL])
                    setDockBadge(completed: processed, total: indices.count)
                    statusMessage = "\(label) — \(processed) of \(indices.count)…"
                } else {
                    // Same condition `FileImportPipeline` labels
                    // `.decodingFailed` for the dropped-file path: `newURL`
                    // is nil only when `exportImage`'s `image.cgImage(...)`
                    // conversion fails, not a write failure (a real write
                    // failure throws and lands in the `catch` below).
                    updateTransfer(index: index, progress: 0, status: .decodingFailed, savedFiles: nil)
                    failed += 1
                }
            } catch {
                guard cameraWork.isCurrent(workGeneration) else { return }
                updateTransfer(index: index, progress: 0, status: .saveError(detail: nil), savedFiles: nil)
                failed += 1
            }
        }

        guard cameraWork.isCurrent(workGeneration) else { return }
        // Final pill copy: distinguish single-photo from batch — the
        // single-photo case stays terse while a batch summarises "N photos".
        if failed == 0 && processed == 1 {
            statusMessage = "Re-imported"
        } else if failed == 0 {
            statusMessage = "Re-imported \(processed) Photos as \(label)"
        } else if processed == 0 {
            statusMessage = "Re-import Failed"
            errorMessage = isConnected
                ? "None of the selected photos could be re-imported. Make sure they're still on the camera or that you have `.qtk` archives on disk."
                : "Connect the camera or turn on “Keep Original Files” to re-decode existing photos offline."
        } else {
            statusMessage = "Re-imported \(processed) of \(indices.count) (\(failed) Failed)"
        }
        isBusy = false
        clearDockBadge()
        scheduleStatusRevert()

        // Open Finder for the batch flow only — single-photo re-import
        // doesn't pop Finder, matching the existing initial-import
        // contract (single is "do the thing", batch is "do many and
        // surface the result").
        if requireConfirmation, processed > 0 {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }

        // Match the batch-import behaviour: hold the bar visible for
        // ~2.5s post-completion so the user sees the green check, then
        // clear the transfer list so the gallery returns to normal.
        let finishedIDs = Set(cameraTransfers.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard cameraWork.isCurrent(workGeneration) else { return }
            for id in finishedIDs { self.liveProgress.values.removeValue(forKey: id) }
            self.cameraTransfers.removeAll { finishedIDs.contains($0.id) }
        }
    }

    /// Resolves the raw `.qtk` bytes for a given gallery index, trying
    /// disk first and falling back to the camera. Used by the
    /// re-import engine. The progress callback fires while the camera
    /// transfer is in flight (disk reads finish too fast to bother
    /// reporting).
    // MARK: - Panorama

    /// True when the current selection could plausibly be a pan sequence.
    /// Deliberately permissive — the stitcher decides for real, and it can
    /// tell (it measures the overlap and refuses below a confidence
    /// threshold) far better than a precondition can guess.
    /// The live panorama, if one has been stitched this session.
    @Published var panorama: PanoramaComposition?

    /// Drives the composer sheet on the main window. The standalone
    /// "Panorama" window reads `panorama` directly and is unaffected, so
    /// both entry points keep working off the same composition.
    @Published var showingPanoramaComposer = false

    /// What a running stitch is doing, or nil when nothing is running.
    @Published var panoramaPhase: PanoramaPhase?

    /// The running stitch, held so it can be cancelled. Matching is the
    /// longest job in the app by a wide margin — seconds per pair, and
    /// the pair count grows with the set — and it is the only one the
    /// user cannot walk away from, because the composer is modal.
    private var panoramaTask: Task<Void, Never>?

    /// Bumped on every request. A cancelled stitch does not stop dead: it
    /// unwinds through whatever `await` it was parked on, and without a
    /// generation its clean-up would clear state that the stitch which
    /// REPLACED it has already published.
    private var panoramaGeneration = 0
    /// `look` is the strip-level Look resolved for the ORIGINAL attempt —
    /// neutral when every frame was already finished, snapshotted when it
    /// wasn't — so an assisted retry reprocesses the same decoded originals
    /// without re-deriving or re-reading live settings.
    private var panoramaRetryInput: (frames: [CGImage], order: [Int]?, look: FinishedLookSettings)?
    @Published private(set) var canRetryQuickPan = false
    /// The spacing offered on the retry control. Survives a failed assisted
    /// retry (so correcting a wrong guess doesn't also forget it), and is
    /// reset to 16 at every genuine new-job boundary below — never read or
    /// written outside this one job's lifetime, so nothing leaks between
    /// unrelated panoramas.
    @Published var panoramaQuickPanStops = 16

    /// Explicit retry on decoded originals; no second camera transfer.
    /// `stops` is the declared stops-per-revolution for the tripod head in
    /// use (16 preserves the original QuickPan detent); it is validated
    /// here rather than trusted from the caller.
    func retryPanoramaWithQuickPan(stops: Int = 16) {
        guard !isBusy, canRetryQuickPan, let input = panoramaRetryInput,
              PanoramaStitcher.quickPanStopsRange.contains(stops) else { return }
        panoramaQuickPanStops = stops
        panoramaTask?.cancel()
        panoramaGeneration += 1
        panoramaRetryInput = nil
        canRetryQuickPan = false
        let generation = panoramaGeneration
        panoramaFailure = nil
        panoramaPhase = .refining
        showingPanoramaComposer = true
        panoramaTask = Task {
            defer {
                if generation == panoramaGeneration {
                    endBusy()
                    panoramaPhase = nil
                    panoramaTask = nil
                }
            }
            await finishPanoramaStitch(frames: input.frames, generation: generation,
                                       fixedOrder: input.order, quickPanAssisted: true,
                                       quickPanStops: stops, look: input.look)
        }
    }

    /// Any camera, two photos or more.
    ///
    /// This used to require the QTK families. That was never a real
    /// constraint — the stitcher takes CGImages and does not care where
    /// they came from — only an accident of the fetch path going through
    /// the Bayer pipeline. The QuickPan and WideTake are QT150-era
    /// accessories, but nothing stops a QT200 being swept by hand, and
    /// `loadOrFetchFinishedFrame` now supplies its frames.
    var canStitchSelection: Bool {
        selectedPhotoIndices.count >= 2
    }

    /// Build a panorama from files chosen in Finder.
    ///
    /// A standard open panel, not a gallery of our own. macOS already has
    /// a good photo chooser — any folder, search, preview, column view —
    /// and people already know how to drive it. A custom grid would be a
    /// worse version of something already on the machine, and it could
    /// only ever show photos this app had imported.
    ///
    /// Accepts raw `.qtk` archives AND ordinary images, because the frames
    /// of a pan are worth joining whatever form they are in — including
    /// exports from an earlier session, which is how these have been
    /// stitched by hand up to now.
    var canPrepareDroppedPanorama: Bool {
        !isBusy && !isConnecting && !isRefreshing && !areThumbnailsLoading
            && !dropConversionActive && !showingPanoramaComposer && pendingPanoramaFiles == nil
    }

    func prepareDroppedPanorama(_ files: [URL: Data]) {
        guard canPrepareDroppedPanorama, (2...PanoramaStitcher.maxFrameCount).contains(files.count) else { return }
        pendingPanoramaData = files
        pendingPanoramaFiles = files.keys.sorted {
            let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
    }

    func choosePanoramaPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Choose Photos for a Panorama"
        panel.prompt = "Choose"
        panel.message = "Pick overlapping photos in capture order. You can rearrange them before stitching."
        var types: [UTType] = [.image]
        if let qtk = UTType(filenameExtension: "qtk") { types.append(qtk) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count >= 2 else {
            presentPanoramaFailure("A panorama needs at least two photos.")
            return
        }
        guard urls.count <= PanoramaStitcher.maxFrameCount else {
            presentPanoramaFailure("Choose at most \(PanoramaStitcher.maxFrameCount) photos for one panorama.")
            return
        }
        // Sorted by name: filenames usually encode capture time, so this
        // is right far more often than not, and it gives the order sheet a
        // sensible arrangement to open with rather than Finder's
        // selection order, which is whatever the user clicked.
        pendingPanoramaData = nil
        pendingPanoramaFiles = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Files are waiting on the order sheet. Nil the rest of the time.
    /// File selection (chooser or drop) sets this — a gallery selection is
    /// already a sequence and goes straight to the stitcher.
    @Published var pendingPanoramaFiles: [URL]?
    /// Drop bytes remain available through the choice and order sheets.
    private(set) var pendingPanoramaData: [URL: Data]?

    /// The order sheet is done. `order` is nil when the user left
    /// automatic ticked, which is the default and the usual answer.
    func startPanorama(files: [URL], fixedOrder order: [URL]?) {
        guard max(files.count, order?.count ?? 0) <= PanoramaStitcher.maxFrameCount else {
            presentPanoramaFailure("Choose at most \(PanoramaStitcher.maxFrameCount) photos for one panorama.")
            return
        }
        let capturedData = pendingPanoramaData
        pendingPanoramaData = nil
        pendingPanoramaFiles = nil
        panoramaFailure = nil
        panoramaSourceSlots = []
        panoramaTask?.cancel()
        panoramaGeneration += 1
        panoramaRetryInput = nil
        canRetryQuickPan = false
        panoramaQuickPanStops = 16
        panorama = nil
        panoramaPhase = .decoding(done: 0, total: files.count)
        showingPanoramaComposer = true
        let urls = order ?? files
        // A manual arrangement is expressed as the order the FILES are in,
        // so the stitcher's `fixedOrder` is simply "as given" — the array
        // has already been permuted.
        let insist = order != nil
        let generation = panoramaGeneration
        panoramaTask = Task { await performPanoramaStitch(fileURLs: urls, insistOrder: insist, generation: generation, capturedData: capturedData) }
    }

    func cancelPanoramaOrdering() {
        pendingPanoramaFiles = nil
        pendingPanoramaData = nil
    }

    private func performPanoramaStitch(fileURLs: [URL], insistOrder: Bool = false, generation: Int,
                                      capturedData: [URL: Data]? = nil) async {
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        // Snapshotted before the decode, which can take seconds — a Settings
        // change mid-job must not change which Look this job resolves to.
        let capturedLook = finishedLook
        setBusy(true, status: "Reading \(fileURLs.count) Photos…")
        defer {
            if generation == panoramaGeneration {
                endBusy()
                panoramaPhase = nil
                panoramaTask = nil
            }
        }
        let total = fileURLs.count

        // File read, decode and slot ordering run in the pipeline; the
        // generation-gated phase update stays here.
        let (decoded, qtkSlots) = await PanoramaPipeline.decodeFinderFrames(urls: fileURLs, capturedData: capturedData) { done, count in
            await MainActor.run {
                guard generation == self.panoramaGeneration else { return }
                self.panoramaPhase = .decoding(done: done, total: count)
            }
        }
        guard !Task.isCancelled, generation == panoramaGeneration else { return }

        guard decoded.count == total, decoded.count >= 2 else {
            endBusy()
            panoramaPhase = nil
            presentPanoramaFailure(
                "Only \(decoded.count) of those \(total) files could be opened as photos. Use images no larger than \(PanoramaStitcher.maxFrameDimension) pixels per side.")
            return
        }

        // A chosen set may mix raw archives with already-finished images
        // (earlier exports, or camera JPEGs copied in directly). Decide
        // where the current Look may run without reprocessing a source that
        // was already rendered — see `PanoramaPipeline.applyingLook`.
        let frames: [CGImage]
        let stripLook: FinishedLookSettings
        if qtkSlots.isEmpty {
            // Nothing raw: these sources are already final.
            frames = decoded
            stripLook = .neutral
        } else if qtkSlots.count == decoded.count {
            // Unchanged behaviour: one Look pass after blending.
            frames = decoded
            stripLook = capturedLook
        } else {
            // Off the main actor and cancellable: this runs a full-resolution
            // render per raw frame, which must not freeze the UI or outlast
            // a cancel the way the earlier synchronous version did.
            do {
                frames = try await PanoramaPipeline.applyingLook(capturedLook, toQTKSlots: qtkSlots, in: decoded)
            } catch {
                // Only `CancellationError` can reach here — the user changed
                // their mind partway through baking the raw frames' look.
                return
            }
            stripLook = .neutral
        }
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        await finishPanoramaStitch(frames: frames, generation: generation,
                                   fixedOrder: insistOrder ? Array(0..<frames.count) : nil,
                                   look: stripLook)
    }

    func stitchSelectedPanorama() {
        let indices = selectedPhotoIndices.sorted()
        guard indices.count >= 2 else { return }
        guard indices.count <= PanoramaStitcher.maxFrameCount else {
            presentPanoramaFailure("Choose at most \(PanoramaStitcher.maxFrameCount) photos for one panorama.")
            return
        }
        // A second request replaces the first rather than racing it for
        // the same published state.
        panoramaTask?.cancel()
        panoramaGeneration += 1
        panoramaRetryInput = nil
        canRetryQuickPan = false
        panoramaQuickPanStops = 16
        // Clear first. Showing the previous panorama while a new one is
        // being built invites the user to judge the wrong picture.
        panorama = nil
        panoramaFailure = nil
        // Remembered so saving can bring the source photos into the gallery
        // too — see `panoramaBySlot`.
        panoramaSourceSlots = indices
        panoramaPhase = .decoding(done: 0, total: indices.count)
        showingPanoramaComposer = true
        let generation = panoramaGeneration
        panoramaTask = Task { await performPanoramaStitch(indices: indices, generation: generation) }
    }

    /// Closes the composer, and abandons a stitch if one is running —
    /// Cancel and Done are the same act. Nothing else consumes the
    /// result, so carrying on would be minutes of CPU spent on a picture
    /// nobody is going to see.
    ///
    /// Safe at any point in the job: the panorama exports
    /// are written only once a finished composition exists, and that is
    /// only built from a match that ran to completion. A cancelled stitch
    /// leaves the photo folder and the gallery exactly as it found them.
    /// `keepingMessage` distinguishes the two ways out. Saving has just
    /// written "Saved to SwiftTake Panorama." and that should be readable;
    /// cancelling has nothing to announce and must not inherit whatever
    /// the abandoned job last said.
    func dismissPanoramaComposer(keepingMessage: Bool = false) {
        panoramaGeneration += 1
        panoramaRetryInput = nil
        canRetryQuickPan = false
        panoramaQuickPanStops = 16
        showingPanoramaComposer = false
        panoramaPhase = nil
        panoramaFailure = nil
        // Cancelling a running stitch is optional; settling the status is
        // not. This used to `guard let` and return early, so closing after
        // a COMPLETED stitch — the ordinary Save — skipped the status
        // handling entirely and left "Saved to…" on screen for good.
        if let running = panoramaTask {
            panoramaTask = nil
            running.cancel()
        }
        // Stop looking busy immediately rather than when the task
        // actually unwinds, which is at the next pair boundary and up to
        // a couple of seconds away. Nothing the user asked for is
        // happening any more, and the serial link was never involved.
        //
        // Back to idle AT ONCE, not "keep the last message and revert in
        // five seconds". Cancelling left the pill reading "Stitched 5
        // photos into a panorama." — an announcement of something that
        // did not happen — or a frozen "Reading 5 of 5…". Keeping the last
        // words is right when a job FINISHES and wrong when it is
        // abandoned; the previous fix for the blank pill did not draw that
        // distinction and turned a blank message into a false one.
        endBusy(status: keepingMessage ? "" : defaultIdleStatus)
    }

    private func performPanoramaStitch(indices: [UInt8], generation: Int) async {
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        // Snapshotted before the serial fetch/develop, which can take tens
        // of seconds — a Settings change mid-job must not change which Look
        // this job resolves to. Every camera-gallery source (QTK archive or
        // QT200 original JPEG) decodes neutrally below, so the captured
        // value always applies once, after blending — unlike the Finder
        // path, there is no pre-rendered export to double-process here.
        let capturedLook = finishedLook
        setBusy(true, status: "Stitching \(indices.count) Photos…")
        defer {
            // Only tidy up if this is still the current stitch. A request
            // that replaced us has already published its own state.
            if generation == panoramaGeneration {
                endBusy()
                panoramaPhase = nil
                panoramaTask = nil
            }
        }

        // Decode WITHOUT the Look. The panorama still ends up wearing it —
        // PanoramaComposition applies it to the finished strip — but doing
        // it per frame fought the gain compensation and banded the seams.
        // See PanoramaComposition.look.
        // Fetch serially — `loadOrFetchQTK` may reach down the serial line
        // to the camera, which is one wire and cannot be parallelised.
        // Two shapes of source. The QT100/150 hand back a Bayer archive
        // that still has to be developed, which is the expensive part and
        // is worth doing in parallel below. Every other family hands back
        // a finished picture, so there is nothing left to parallelise and
        // the frame is ready as soon as it has been read.
        // Routed on what the bytes ARE, not on which camera is selected. A
        // demo QuickTake 150 serves drawn stand-ins with no mosaic behind
        // them, and developing those produces frames the stitcher cannot
        // match — which is exactly how the demo QT150 panorama used to fail,
        // with "could not find a confident overlap".
        let needsDevelop = selectedModel.usesQTKFormat
            && !(DemoCamera.shared.isConnected && DemoCamera.shared.servesFinishedImages)
        var archives: [(slot: Int, data: Data)] = []
        var finished: [(slot: Int, image: CGImage)] = []
        for (n, index) in indices.enumerated() {
            guard !Task.isCancelled, generation == panoramaGeneration else { return }
            panoramaPhase = .decoding(done: n, total: indices.count)
            setBusy(true, status: "Reading \(n + 1) of \(indices.count)…")
            if needsDevelop {
                if let qtk = await loadOrFetchQTK(forIndex: index) {
                    archives.append((n, qtk))
                }
            } else if let image = await loadOrFetchFinishedFrame(forIndex: index) {
                finished.append((n, image))
            }
        }
        guard !Task.isCancelled, generation == panoramaGeneration else { return }

        // Develop the Bayer archives in PARALLEL — since the coarse-to-fine
        // search made matching cheap, the per-frame decode (about 1.3 s, so
        // 21 s for a full rotation) is the whole cost, and the frames do not
        // depend on each other. The pipeline keys results by slot and sorts,
        // because frame ORDER must not be left to a task group's completion
        // order. The finished-frame families have nothing left to decode.
        let total = indices.count
        setBusy(true, status: "Decoding \(total) Photos…")
        var decoded = await PanoramaPipeline.decodeArchives(archives) { done, _ in
            await MainActor.run {
                guard generation == self.panoramaGeneration else { return }
                self.panoramaPhase = .decoding(done: done, total: total)
            }
        }
        decoded.append(contentsOf: finished)

        let frames: [CGImage] = decoded.sorted { $0.slot < $1.slot }.map(\.image)
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        guard frames.count == total, frames.count >= 2 else {
            presentPanoramaFailure("Could not read every selected photo. Retry before stitching so no frames are skipped.")
            return
        }

        await finishPanoramaStitch(frames: frames, generation: generation, look: capturedLook)
    }

    /// Match and compose — no writing. Shared by both entry points, a
    /// gallery selection and the Finder chooser, because only where the
    /// pixels come from differs. Two copies of this would be two places
    /// for the cancellation guard to drift apart. Saving is `savePanorama`,
    /// called from the composer's Save button.
    private func finishPanoramaStitch(frames: [CGImage],
                                      generation: Int,
                                      fixedOrder: [Int]? = nil,
                                      quickPanAssisted: Bool = false,
                                      quickPanStops: Int = 16,
                                      look: FinishedLookSettings) async {
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        panoramaRetryInput = (frames, fixedOrder, look)
        canRetryQuickPan = false
        // Progress arrives from the detached matcher, so it has to hop
        // back. The generation guard matters here: a stitch unwinding
        // after a cancel must not repaint the one that replaced it.
        let report: @Sendable (PanoramaPhase) -> Void = { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self, generation == self.panoramaGeneration else { return }
                self.panoramaPhase = phase
            }
        }

        setBusy(true, status: "Aligning and Blending…")
        panoramaPhase = .aligning(done: 0,
                                  total: PanoramaStitcher.pairMatchCount(frames: frames.count))
        let session: PanoramaStitcher.Session
        let strip: CGImage?
        do {
            // The pipeline runs the match and blend detached and forwards
            // this task's cancellation into that work; the generation-gated
            // phase reporting stays here.
            let box = try await PanoramaPipeline.stitch(
                frames: frames,
                fixedOrder: fixedOrder,
                quickPanAssisted: quickPanAssisted,
                quickPanStops: quickPanStops,
                onRefining: { report(.refining) },
                onAligning: { done, total in report(.aligning(done: done, total: total)) },
                onBlending: { report(.blending) })
            session = box.session; strip = box.strip
        } catch is CancellationError {
            // The user changed their mind. Not a failure, and nothing to
            // tell them that they do not already know.
            return
        } catch {
            // A cancel racing the throw, or a request that has already
            // been superseded, must not reopen the composer with a
            // failure message for a job nobody is waiting on.
            guard !Task.isCancelled, generation == panoramaGeneration else { return }
            // Offered after an image-only failure AND after an assisted
            // attempt with the wrong spacing — the photographer can correct
            // the declared stops and retry on the same decoded originals.
            canRetryQuickPan = (6...PanoramaStitcher.maxFrameCount).contains(frames.count)
                && (error as? PanoramaStitcher.StitchError).map {
                    switch $0 {
                    case .noConfidentMatch, .quickPanMismatch: return true
                    default: return false
                    }
                } == true
            presentPanoramaFailure((error as? PanoramaStitcher.StitchError)?.description
                                   ?? error.localizedDescription)
            return
        }
        // Same gate before the nil-strip failure and before anything is
        // published or written — a cancelled or stale result must stay
        // silent on every exit, not just the success path.
        guard !Task.isCancelled, generation == panoramaGeneration else { return }
        guard let strip else {
            presentPanoramaFailure("The panorama could not be rendered.")
            return
        }
        panorama = PanoramaComposition(session: session, sources: frames,
                                       initial: strip, look: look)
        panoramaRetryInput = nil

        let seams = session.fits.enumerated().map { i, fit in
            session.estimatedJoins.contains(i) ? "estimated" : String(format: "%.2f", fit.correlation)
        }.joined(separator: ", ")
        QTLog.note("Panorama", "\(frames.count) frames, order \(session.order), step \(session.step), "
                   + "slope \(session.fittedSlope), overlap \(Int(session.overlap * 100))%, "
                   + "fullRotation=\(session.isFullRotation), features=\(session.usesFeatureAlignment), "
                   + "roll=\(session.rollCorrectionDegrees), correlations [\(seams)]")
        statusMessage = "Stitched \(frames.count) Photos"
    }

    /// Why the last stitch could not finish, shown INSIDE the composer.
    /// Nil when there is nothing wrong.
    @Published var panoramaFailure: String?

    /// The camera slots a panorama was built from, if it came from the
    /// gallery. Empty for the Finder chooser, whose files are already on
    /// disk and were never on a camera.
    private var panoramaSourceSlots: [UInt8] = []

    /// Raw `.qtk` bytes fetched from the camera this session, by slot.
    ///
    /// Without this, a second panorama over the same photos pulls every
    /// frame down the serial line again — half a minute each on real
    /// hardware, so six frames is three minutes of re-reading bytes the
    /// app already had. Keep Original Files avoids that by writing the
    /// archive to disk, but it is off by default and most people making a
    /// panorama have no reason to have turned it on.
    ///
    /// Cheap to hold: a QuickTake archive is about 90 KB, so a full
    /// 32-photo card is under 3 MB. Dropped whenever the gallery is
    /// cleared, because slots mean nothing once a different camera is
    /// attached.
    private var fetchedQTKCache: [UInt8: Data] = [:]

    /// Give the source frames the full-size preview they have already
    /// earned, without importing anything.
    ///
    /// A gallery cell shows its picture at 66% until a full-resolution
    /// preview arrives — that shrunk state is how the app says "still only
    /// the camera's little thumbnail". Linked frames never import, so
    /// without this they would sit at 66% for the rest of the session:
    /// permanently mid-load, for photos that have just finished doing the
    /// most work in the app. It also left the "Panorama" badge aligned to
    /// the cell's full box while the picture inside it was smaller, so the
    /// badge floated in empty space below the photo.
    ///
    /// The frames cost nothing — the stitch decoded them at full size and
    /// the composition is still holding them. `sources` is in the order
    /// they were handed in, which is `panoramaSourceSlots` sorted, so the
    /// two zip. The stitcher's own `order` is not used here: that is the
    /// order it decided to ASSEMBLE them in, not where they came from.
    ///
    /// The Look is applied so these match what an import of the same photo
    /// would have produced. Without it a linked frame would be visibly
    /// flatter than its imported neighbour, which reads as a bug.
    private func publishPanoramaSourcesAsPreviews(_ composition: PanoramaComposition) {
        let look = composition.look
        let work = panoramaSourceSlots.enumerated().compactMap {
            (position, slot) -> SendableSlotFrame? in
            guard position < composition.sources.count else { return nil }
            return SendableSlotFrame(slot: slot, image: composition.sources[position])
        }
        guard !work.isEmpty else { return }

        // OFF the main thread, one frame at a time.
        //
        // This used to render every frame inline, and it hung the app. Six
        // 640x480 QuickTake 100 frames were quick enough that nothing
        // looked wrong; twelve 1600x1200 QuickTake 200 frames are twelve
        // full-resolution Core Image passes in a row, on the thread that
        // draws the window, at the exact moment the user has just pressed
        // Save. The app beachballed and had to be force quit.
        //
        // Published per frame rather than as one batch at the end, so the
        // cells fill in as they land — the same progressive behaviour the
        // gallery already has when thumbnails stream off the camera.
        Task.detached(priority: .userInitiated) { [weak self] in
            for item in work {
                let plain = NSImage(cgImage: item.image,
                                    size: NSSize(width: item.image.width,
                                                 height: item.image.height))
                let finished = QuickTakeSerialManager.applyFinishedLook(plain, look) ?? plain
                let box = SendableImageBox(image: finished)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // The link is the proof this slot still means what it
                    // meant when Save was pressed. A disconnect, an erase
                    // or a reload during the render drops it, and writing
                    // the preview anyway would put one photo's picture on
                    // another photo's cell.
                    guard self.panoramaBySlot[item.slot] != nil else { return }
                    self.enhancedPreviewImages[item.slot] = box.image
                }
            }
        }
    }

    /// Drop everything keyed by CAMERA SLOT.
    ///
    /// A slot number is only meaningful against one particular set of
    /// photos. Erase the card, or reload the gallery after the camera has
    /// been used, and slot 1 is a different picture — at which point the
    /// panorama links would badge photos that were never in a panorama and
    /// open the wrong one, and the byte caches would hand a stitch the
    /// previous occupant of that slot. Both are silent wrong answers, which
    /// is the worst kind, so anything that can renumber the card comes
    /// through here.
    ///
    /// The panorama FILES are untouched — they are in the user's photo
    /// folder and are not the camera's business.
    private func invalidateSlotKeyedState() {
        photoSessionGeneration &+= 1
        // Disk files survive, but their slot associations do not. Otherwise
        // loadOrFetchQTK's disk-first lookup can feed an old original into a
        // panorama after the camera has reused that number for a new photo.
        importedPhotoURLs = [:]
        photoNames = [:]
        fujiCameraNames = [:]
        photoQualities = [:]
        panoramaBySlot = [:]
        savedPanoramas = []
        fetchedQTKCache = [:]
        fetchedFrameCache = [:]
        // The full-size previews go too. Ones derived from an import can be
        // re-derived from the file on disk, and `fetchAllThumbnails` does
        // exactly that — but a panorama source has no file behind it, so
        // its preview lives only here and is keyed by a slot number that
        // has just stopped meaning anything. Left in place it would draw
        // one photo's picture on another photo's cell.
        enhancedPreviewImages = [:]
    }

    /// The same idea for the families that hand back a finished picture
    /// (QT200, and the Fuji-derived bodies): the bytes off the wire, not
    /// the rendered image.
    ///
    /// Deliberately the RAW transfer rather than the decoded `CGImage`. A
    /// QuickTake 200 frame decodes to 1600x1200 — about 7.7 MB in memory —
    /// so caching pictures would cost a quarter of a gigabyte for one card,
    /// where the JPEG it came from is tens of kilobytes. Re-rendering is
    /// milliseconds; re-reading over the serial line is half a minute.
    private var fetchedFrameCache: [UInt8: (header: [UInt8], data: [UInt8])] = [:]

    /// Which panorama each camera slot contributed to, once one is saved.
    ///
    /// A panorama is what the user actually made; the frames are
    /// ingredients. So rather than importing six photos nobody asked for,
    /// the cells they came from point AT the result — double-clicking one
    /// opens the panorama, and a badge says why. The frames can still be
    /// imported normally by anyone who wants them individually.
    @Published private(set) var panoramaBySlot: [UInt8: URL] = [:]

    /// One saved panorama, as the gallery needs to show it.
    struct SavedPanorama: Identifiable, Equatable {
        let id = UUID()
        /// The flat PNG; interactive HTML and immersive images sit beside it.
        let image: URL
        let frameCount: Int
        /// Overlap as a fraction, for the caption.
        let overlap: Double
        /// Identical coverage to the saved interactive and immersive exports.
        let sweepDegrees: Double
        /// Every file the save actually wrote, by extension and uppercased
        /// — PNG, HTML, HEIC (or JPEG). Taken from what landed on disk.
        let formats: [String]
        /// Shared camera quality, or nil for mixed/unknown or Finder sources.
        let sourceIsHQ: Bool?
        /// The bookmark-gated folder `image` was saved under — the same
        /// `parent` the save itself claimed scope on — so a later reload
        /// (`PanoramaBandTile`) can re-acquire it. Optional for records
        /// without a scoped destination.
        let scopeRoot: URL?
        var alignmentNote: String? = nil

        var caption: String {
            let base = "\(frameCount) photos · \(Int((overlap * 100).rounded()))% overlap"
            // Generic rather than naming QuickPan specifically — this tag
            // also covers the other declared tripod spacings.
            return alignmentNote == nil ? base : base + " · Tripod-assisted"
        }

        var formatsCaption: String {
            formats.map { $0 == "HTML" ? "Interactive" : ($0 == "MOV" ? "Legacy QTVR" : $0) }
                .joined(separator: " · ")
        }

        var interactiveURL: URL? {
            formats.contains("HTML") ? image.deletingPathExtension().appendingPathExtension("html") : nil
        }
    }

    /// Panoramas made this session, newest last. These are NOT on the
    /// camera — they were made here — so the gallery shows them in a band of
    /// their own rather than mixed in with the camera's own photos.
    @Published private(set) var savedPanoramas: [SavedPanorama] = []

    /// Panoramas written this session, newest last.
    ///
    /// Kept apart from `importedPhotoURLs`, which means "the files imported
    /// FROM this camera slot". A panorama is made from many slots and is
    /// not an import of any one of them, and filing it under the first
    /// source photo broke two things at once: the next stitch loaded the
    /// finished 2352x480 panorama as though it were that slot's 640x480
    /// frame — every frame after the first then disagreed about size, so
    /// the second stitch of a session always failed — and Import All
    /// treated that slot as already imported and skipped it.
    @Published private(set) var savedPanoramaURLs: [URL] = []

    /// Write the panorama the user is looking at, and say where it went.
    ///
    /// Called from Save, NOT when the stitch finishes. Writing on
    /// completion put two files in the photo folder before anyone had seen
    /// the picture, so Cancel could not mean cancel — and a Level nudge
    /// after the fact left the file on disk disagreeing with the one on
    /// screen. The user decides what is worth keeping.
    @discardableResult
    func savePanorama() async -> URL? {
        guard let composition = panorama, composition.canSave, let strip = composition.strip else { return nil }
        composition.isSaving = true
        composition.saveError = nil
        defer { composition.isSaving = false }
        let session = composition.session
        let sourceSlots = panoramaSourceSlots
        let sourceQualities = sourceSlots.compactMap { photoQualities[$0] }
        let sourceIsHQ: Bool? = sourceSlots.count == composition.frameCount
            && sourceQualities.count == sourceSlots.count
            && Set(sourceQualities).count == 1 ? sourceQualities.first : nil
        let generation = panoramaGeneration

        // A custom folder is used directly; the default inherits access from
        // the photo destination. Keep this scope with the saved record too.
        if preferredPanoramaDestinationURL == nil, !panoramaDestinationIsDefault {
            preferredPanoramaDestinationURL = destinationStore.resolvedDestination(.panorama)
            if preferredPanoramaDestinationURL == nil {
                composition.saveError = "The panorama folder isn't available. Reconnect its drive or choose a folder in Settings."
                return nil
            }
        }
        let parent = preferredPanoramaDestinationURL ?? effectiveImportDestinationURL
        let hasAccess = parent.startAccessingSecurityScopedResource()
        defer { if hasAccess { parent.stopAccessingSecurityScopedResource() } }
        let destination = effectivePanoramaDestinationURL
        let written: [URL]
        do {
            written = try await PanoramaPipeline.export(
                strip: strip, session: session, destination: destination)
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, generation == panoramaGeneration, panorama === composition else { return nil }
            composition.saveError = "The panorama could not be saved: " + error.localizedDescription
            QTLog.note("Panorama", composition.saveError!)
            return nil
        }

        savedPanoramaURLs.append(contentsOf: written)
        // Link the sources to the flat image — the .png, not the movie or the
        // immersive file, since that is what a viewer can show.
        if let flat = written.first(where: { $0.pathExtension.lowercased() == "png" }) {
            if generation == panoramaGeneration, panorama === composition {
                for slot in sourceSlots { panoramaBySlot[slot] = flat }
                publishPanoramaSourcesAsPreviews(composition)
            }
            let formats = written
                .map { $0.pathExtension.uppercased() }
                .reduce(into: [String]()) { acc, ext in
                    if !acc.contains(ext) { acc.append(ext) }
                }
            savedPanoramas.append(SavedPanorama(image: flat,
                                                frameCount: composition.frameCount,
                                                overlap: session.overlap,
                                                sweepDegrees: session.sweepDegrees ?? PanoramaPipeline.sweepEstimate(for: session),
                                                formats: formats,
                                                sourceIsHQ: sourceIsHQ,
                                                scopeRoot: parent,
                                                alignmentNote: session.alignmentNote))
        }
        if !Task.isCancelled, generation == panoramaGeneration, panorama === composition {
            statusMessage = written.isEmpty
                ? "The panorama could not be saved."
                : "Saved to \(destination.lastPathComponent)."
        }
        return written.first
    }


    /// Report a stitch that could not finish, in the sheet the user is
    /// already looking at.
    ///
    /// This used to tear the sheet down, wait 350ms for the dismissal
    /// animation, and then raise an app-modal NSAlert — so a failure read as
    /// a window appearing, vanishing, and being replaced by a different
    /// window complaining. The old comment here said as much: the failure
    /// belongs inline, next to the frames that would not join.
    ///
    /// It stays put now. The sheet is already open, already about this
    /// panorama, and already has a way out.
    /// A stitch that could not finish, shown in the sheet it happened in.
    ///
    /// Settling the busy state belongs HERE, not at the call sites. The
    /// camera-slot path happened to have a `defer` that ended it; the
    /// Finder path had none, so failing a stitch of chosen files left the
    /// sidebar reading "Aligning and Blending…" with the busy dot lit —
    /// for the rest of the session — while the sheet in front of it said
    /// the photos wouldn't join up. A failure means the work has stopped,
    /// on every path, so the rule lives with the failure.
    ///
    /// Back to idle rather than to a failure phrase: the sheet is already
    /// saying what went wrong, at length, and the pill repeating it would
    /// be the same news twice.
    private func presentPanoramaFailure(_ message: String) {
        panoramaPhase = nil
        panoramaFailure = message
        showingPanoramaComposer = true
        endBusy(status: defaultIdleStatus)
    }

    /// A finished frame, for the families that have no QTK archive.
    ///
    /// The QT200 and the Kodak DC cameras store display-referred images —
    /// there is no Bayer mosaic to hold and re-develop, so the bytes decode
    /// straight to a picture. Use original JPEG bytes from the session or
    /// camera: saved exports may already have NewTake, HDR or a date stamp
    /// baked in. The panorama applies its Look once, after blending.
    ///
    /// This is what lets the QT200 make panoramas. The stitcher never cared
    /// about the format — it takes CGImages — but the only route into it
    /// went through the Bayer pipeline, so the feature was gated to a
    /// camera family for a reason that was never about the camera.
    private func loadOrFetchFinishedFrame(forIndex index: UInt8,
                                          progress: ((Double) -> Void)? = nil) async -> CGImage? {
        let workGeneration = cameraWork.generation

        let outcome = await ReimportSourceResolver.resolve(
            diskLookup: { nil as CGImage? },
            sessionCacheLookup: {
                // Already pulled down this session — render it again
                // rather than asking the camera for bytes the app is
                // still holding.
                guard let bytes = self.fetchedFrameCache[index]?.data ?? self.fujiJPEGCache[index] else { return nil }
                return (try? QuickTake200JPEGDecoder.decode(Data(bytes)))?.image
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
            },
            isCurrent: { self.cameraWork.isCurrent(workGeneration) },
            cameraFetch: {
                await self.fetchFinishedFrameFromCamera(
                    forIndex: index, workGeneration: workGeneration, progress: progress)
            }
        )

        switch outcome {
        case .resolved(let image, _): return image
        case .unavailable, .stale: return nil
        }
    }

    /// Camera-only step of `loadOrFetchFinishedFrame`: fetches the header
    /// then the full image over the wire and renders it. Every `await`
    /// here is followed by a generation re-check on BOTH branches — a
    /// stale result (the job superseded while suspended) must not populate
    /// `fetchedFrameCache` or be handed back to the caller.
    private func fetchFinishedFrameFromCamera(
        forIndex index: UInt8,
        workGeneration: UInt64,
        progress: ((Double) -> Void)?
    ) async -> CGImage? {
        guard isConnected, photoIndices.contains(index) else { return nil }

        let header = await fetchImageHeader(forImageIndex: index)
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        guard let header, header.count >= 25 else { return nil }

        let sizeBytes = [header[5], header[6], header[7]]
        let imageSize = Int(sizeBytes[0]) << 16 | Int(sizeBytes[1]) << 8 | Int(sizeBytes[2])
        guard imageSize > 0 else { return nil }

        let imageData = await fetchFullImage(
            forImageIndex: index, imageSize: imageSize,
            sizeBytes: sizeBytes, progress: progress)
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        guard let imageData else { return nil }

        fetchedFrameCache[index] = (header, imageData)
        return (try? QuickTake200JPEGDecoder.decode(Data(imageData)))?.image
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func loadOrFetchQTK(forIndex index: UInt8, progress: ((Double) -> Void)? = nil) async -> Data? {
        let workGeneration = cameraWork.generation

        let outcome = await ReimportSourceResolver.resolve(
            diskLookup: {
                // Saved `.qtk` on disk, under the (possibly separate)
                // bookmark-gated QTK destination — see fetchQTKFromCameraAndArchive,
                // which saves there under the same scope.
                withDestinationScope(URLDestinationScope(url: self.effectiveQTKDestinationURL)) {
                    // Identical bytes to what came off the camera, and
                    // works offline.
                    guard let qtkURL = self.importedPhotoURLs[index]?.first(where: {
                              $0.pathExtension.lowercased() == "qtk" }),
                          let data = try? Data(contentsOf: qtkURL) else { return nil }
                    return data
                }
            },
            sessionCacheLookup: {
                // Already pulled down this session. The bytes are
                // identical to disk's; the only difference is that nobody
                // asked for them to be kept on disk.
                self.fetchedQTKCache[index]
            },
            isCurrent: { self.cameraWork.isCurrent(workGeneration) },
            cameraFetch: {
                await self.fetchQTKFromCameraAndArchive(
                    forIndex: index, workGeneration: workGeneration, progress: progress)
            }
        )

        switch outcome {
        case .resolved(let data, _): return data
        case .unavailable, .stale: return nil
        }
    }

    /// Camera-only step of `loadOrFetchQTK`: fetches the header then the
    /// full image over the wire, builds the QTK blob, and — when "Keep
    /// Original Files" is on — persists the archive. Every `await` here is
    /// followed by a generation re-check on BOTH branches: a stale result
    /// must not reach the archive, the session cache, or the caller.
    private func fetchQTKFromCameraAndArchive(
        forIndex index: UInt8,
        workGeneration: UInt64,
        progress: ((Double) -> Void)?
    ) async -> Data? {
        // Requires a live connection and the photo still being on the camera.
        guard isConnected, photoIndices.contains(index) else { return nil }

        let header = await fetchImageHeader(forImageIndex: index)
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        guard let header, header.count >= 25 else { return nil }

        let sizeBytes = [header[5], header[6], header[7]]
        let imageSize = Int(sizeBytes[0]) << 16 | Int(sizeBytes[1]) << 8 | Int(sizeBytes[2])
        guard imageSize > 0 else { return nil }

        let imageData = await fetchFullImage(
            forImageIndex: index,
            imageSize: imageSize,
            sizeBytes: sizeBytes,
            progress: progress
        )
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        guard let imageData else { return nil }

        let qtkData = QTKFormatter.buildQTKData(
            model: selectedModel,
            imageHeader: header,
            imageData: imageData
        )
        if keepOriginalQTK {
            do {
                // Byte-safe: reuses an identical existing archive, or picks a
                // fresh name rather than overwriting a different photo's.
                let qtkURL = try QTKArchiveStore.saveSafely(
                    qtkData, candidateStem: baseFilenameStem(forIndex: index), in: effectiveQTKDestinationURL)
                var urls = importedPhotoURLs[index] ?? []
                if !urls.contains(qtkURL) { urls.append(qtkURL) }
                importedPhotoURLs[index] = urls
            } catch {
                QTLog.note("ARCHIVE", "Keep-original QTK save failed", detail: error.localizedDescription)
            }
        }
        // Held either way. On disk it is the user's copy; here it is only
        // so the wire is not asked for the same photo twice.
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        fetchedQTKCache[index] = qtkData
        return qtkData
    }

    /// The suffix-less base filename stem for an imported photo. A user
    /// rename wins outright; otherwise the app-wide scheme applies:
    /// `<Model>_<YYYYMMDD_HHMMSS>_<NNN>` (e.g. "QuickTake150_19970315_142233_005"),
    /// or `<Model>_<NNN>` when the camera recorded no date. Underscores
    /// throughout, model-specific prefix. The
    /// colour-mode suffix is appended by callers via `currentModeSuffix()`.
    /// (The QT200's serial path overrides this stem with its EXIF-date name
    /// after download.)
    private func importStem(forIndex index: UInt8, dateStr: String?) -> String {
        NamingMetadataPolicy.importStem(
            customName: photoNames[index],
            prefix: selectedModel.fileNamePrefix,
            index: Int(index),
            dateStr: dateStr
        )
    }

    /// Builds a clean filename stem for a re-imported photo. Prefers the
    /// existing on-disk filename (so QuickTake-19970315-…-005 stays stable
    /// across modes), falls back to the user-set photo name, then to a generic
    /// indexed stem. Any prior mode tag is stripped so re-imports don't
    /// compound suffixes.
    private func baseFilenameStem(forIndex index: UInt8) -> String {
        NamingMetadataPolicy.baseFilenameStem(
            savedFileStem: importedPhotoURLs[index]?.first?.deletingPathExtension().lastPathComponent,
            customName: photoNames[index],
            prefix: selectedModel.fileNamePrefix,
            index: Int(index)
        )
    }

    /// Reads the capture date out of a saved `.qtk` archive for the
    /// given gallery index, or returns nil if no QTK was kept (or the
    /// header isn't decodable).
    func captureDate(forIndex index: UInt8) -> Date? {
        // Demo mode writes no files, so there is no .qtk to read a header
        // from — but the simulated camera knows when it "took" the photo,
        // which is the same fact by a shorter route.
        if DemoCamera.shared.isConnected,
           let simulated = DemoCamera.shared.captureDate(at: index) {
            return simulated
        }
        guard let qtkURL = importedPhotoURLs[index]?.first(where: { $0.pathExtension.lowercased() == "qtk" }),
              let data = try? Data(contentsOf: qtkURL),
              let header = Self.imageHeaderFromQTK(data) else {
            return nil
        }
        return parseImageDateAsDate(from: header)
    }

    func renamePhoto(at index: UInt8, to newName: String) {
        photoNames[index] = newName

        if let urls = importedPhotoURLs[index], !urls.isEmpty {
            var newURLs: [URL] = []
            for url in urls {
                let directory = url.deletingLastPathComponent()
                let extensionStr = url.pathExtension
                let newURL = directory.appendingPathComponent("\(newName).\(extensionStr)")

                do {
                    try FileManager.default.moveItem(at: url, to: newURL)
                    newURLs.append(newURL)
                } catch {
                    print("Failed to rename file \(url.lastPathComponent) to \(newURL.lastPathComponent): \(error)")
                    newURLs.append(url)
                }
            }
            importedPhotoURLs[index] = newURLs
        }
    }

    /// What the user picked in the "file already exists" sheet.
    /// `applyToAll` means the same choice should be auto-applied to
    /// any further conflicts in the same import batch.
    typealias DuplicateAction = BatchImportPolicy.DuplicateChoice

    /// A pending "file already exists" decision, surfaced to the UI as the custom
    /// `DuplicateFileDialog` (themed + precisely aligned, unlike an `NSAlert`).
    /// Continuation-based so the import loop can `await` the user's choice.
    struct DuplicatePromptRequest: Identifiable {
        let id = UUID()
        let fileName: String
        let resolve: (DuplicateAction) -> Void
    }

    /// Non-nil while a duplicate prompt is on screen. The view presents
    /// `DuplicateFileDialog`; a button tap calls `resolve`, which clears this and
    /// resumes the suspended import.
    @Published var duplicatePrompt: DuplicatePromptRequest?

    /// Ask the user how to resolve a name clash. Presents the in-app dialog and
    /// suspends the import until they choose.
    @MainActor
    private func promptForDuplicate(fileName: String) async -> DuplicateAction {
        await withCheckedContinuation { (cont: CheckedContinuation<DuplicateAction, Never>) in
            self.duplicatePrompt = DuplicatePromptRequest(fileName: fileName) { [weak self] action in
                self?.duplicatePrompt = nil
                cont.resume(returning: action)
            }
        }
    }

    private func clearCameraProgress() {
        for transfer in cameraTransfers { liveProgress.values.removeValue(forKey: transfer.id) }
    }

    private func updateLiveProgress(index: UInt8, progress: Double) {
        guard let transfer = cameraTransfers.first(where: { $0.index == index }) else { return }
        liveProgress.values[transfer.id] = progress
    }

    private func updateDroppedTransfer(id: UUID, progress: Double, status: PhotoTransfer.Status, savedFiles: [URL]?) {
        guard let index = droppedTransfers.firstIndex(where: { $0.id == id }) else { return }
        liveProgress.values[id] = progress
        let doneEdge = (droppedTransfers[index].progress >= 1) != (progress >= 1)
        guard droppedTransfers[index].status != status || doneEdge || savedFiles != nil else { return }
        droppedTransfers[index].progress = progress
        droppedTransfers[index].status = status
        if let savedFiles { droppedTransfers[index].savedFiles = savedFiles }
    }

    private func updateTransfer(index: UInt8, progress: Double, status: PhotoTransfer.Status, savedFiles: [URL]?) {
        guard !Task.isCancelled else { return }
        guard let transferIndex = cameraTransfers.firstIndex(where: { $0.index == index }) else { return }
        // Every tick goes to the silent store (only BatchProgressBar reads
        // it). The @Published array is written ONLY on summary-visible
        // edges — a status flip, the done edge, files landing — so a
        // running transfer can't re-evaluate the whole ContentView body
        // 8×/s while the gallery is scrolling.
        liveProgress.values[cameraTransfers[transferIndex].id] = progress
        let doneEdge = (cameraTransfers[transferIndex].progress >= 1) != (progress >= 1)
        guard cameraTransfers[transferIndex].status != status || doneEdge || savedFiles != nil else { return }
        cameraTransfers[transferIndex].progress = progress
        cameraTransfers[transferIndex].status = status
        if let savedFiles {
            cameraTransfers[transferIndex].savedFiles = savedFiles
        }
    }

    /// Decodes a `.qtk` blob through `QTKDecoder` on a background
    /// queue and ticks the photo's transfer progress smoothly between
    /// `from` and `to` while the work runs. Without this, the
    /// progress bar stalls for the full decode duration (1–2s on an
    /// HQ photo) because `QTKDecoder().decode(...)` is synchronous
    /// and otherwise blocks the main actor — no SwiftUI updates can
    /// land on the bar until decode returns. Running decode in a
    /// `Task.detached` lets the main actor breathe; the phantom
    /// ticker fills the visual gap with continuous motion paced for
    /// the typical decode time.
    private func decodeWithProgress(
        qtkData: Data,
        forIndex index: UInt8,
        from: Double,
        to: Double,
        estimatedSeconds: Double,
        settings: CameraBatchImportEngine.Settings
    ) async -> NSImage? {
        let workGeneration = cameraWork.generation
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        let enhanced = settings.enhancedColor
        let hdrEnabled = settings.hdrEnabled
        let hdrHeadroom = settings.hdrHeadroom

        let decodeTask = Task.detached(priority: .userInitiated) { () -> SendableImageBox in
            let img = QTKDecoder().decode(
                data: qtkData,
                enhanced: enhanced,
                hdrEnabled: hdrEnabled,
                hdrHeadroom: hdrHeadroom
            )
            return SendableImageBox(image: img)
        }

        // Phantom progress ticker on the main actor. Each step is
        // tiny so the bar reads as continuous motion. Runs until
        // either it reaches `to` or it's cancelled when decode lands.
        let phantom = Task { @MainActor in
            let totalSteps = max(1, Int(estimatedSeconds * 14))
            let increment = (to - from) / Double(totalSteps)
            let stepNanos = UInt64((estimatedSeconds * 1_000_000_000) / Double(totalSteps))
            var p = from
            for _ in 0..<totalSteps {
                try? await Task.sleep(nanoseconds: stepNanos)
                guard cameraWork.isCurrent(workGeneration) else { return }
                p = min(to, p + increment)
                self.updateTransfer(index: index, progress: p, status: .decoding, savedFiles: nil)
            }
        }

        let result = await decodeTask.value
        phantom.cancel()
        guard cameraWork.isCurrent(workGeneration) else { return nil }
        return result.image
    }

    private func finishBatchImport(summary: BatchImportPolicy.Summary) {
        // Wording and branching live in `BatchImportPolicy.finishOutcome` —
        // pure counts/flags in, status text + error text + post-import
        // decision out. Preserved verbatim from a prior fix pass: the
        // all-skipped (0,0) case reads as "No New Photos Imported" (not an
        // error), a real all-failed run gets neutral wording, and a
        // user-initiated Stop is never reported as an error.
        let outcome = BatchImportPolicy.finishOutcome(
            importedPhotoCount: summary.importedPhotoCount,
            failedPhotoCount: summary.failedPhotoCount,
            stoppedByUser: summary.stoppedByUser
        )
        statusMessage = outcome.statusMessage
        errorMessage = outcome.errorMessage
        scheduleStatusRevert()
        guard outcome.shouldPerformPostImportAction else { return }
        performPostImportAction()
    }

    private func performPostImportAction() {
        switch selectedPostImportAction {
        case .doNothing:
            break
        case .showInFinder:
            if let destination = lastImportDestination {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    /// Render and write `image` to `destinationURL` in the current
    /// export format. Capture date is taken from `captureDate` if the
    /// caller has it pre-extracted (the Fuji/QT200 path: date comes
    /// from the JPEG/Exif preamble) or otherwise from the QTK image
    /// header bytes (the QT100/150 path: date is in the 8-byte raw
    /// header). Passing both — `captureDate` wins.
    /// Replacement requires the caller's duplicate decision; job currency is
    /// checked on the main actor after encoding and immediately before publication.
    private func exportImage(_ image: NSImage, named baseName: String, to destinationURL: URL, captureDate explicitCaptureDate: Date? = nil, header: [UInt8]? = nil, settings explicitSettings: CameraBatchImportEngine.Settings? = nil, collisionMode: AtomicFileWriter.CollisionMode = .exclusive, isCurrent: () -> Bool = { true }) async throws -> URL? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // Snapshot EVERYTHING the worker needs while still on the main actor
        // (settings can't change mid-export, and the worker never touches
        // `self`): capture date, stamp toggle, format, colour-space choice,
        // and the finished metadata dictionary. Callers threading a
        // per-photo snapshot from earlier in the pipeline (the camera batch
        // engine, re-import) pass it in explicitly so this export agrees
        // with the naming and collision decision already made for the same
        // photo; other callers get one taken fresh, right here.
        let settings = explicitSettings ?? cameraImportSettingsSnapshot()
        let captureDate: Date? = explicitCaptureDate ?? header.flatMap { parseImageDateAsDate(from: $0) }
        // Display P3 is only justified when the Enhanced PerfectColor pipeline
        // actually ran — i.e. for the QTK raw format (QT100/150). The
        // Fuji/QT200 family is finished, display-referred sRGB JPEGs with no
        // wide-gamut data, so it always exports as sRGB.
        let useP3 = selectedModel.usesQTKFormat && settings.enhancedColor
        var properties = exportMetadataProperties(captureDate: captureDate, modeLabel: settings.colorModeLabel)
        if settings.isLossyFormat {
            properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        }
        let job = PhotoExporter.ExportJob(
            cgImage: cgImage,
            properties: properties,
            stampEnabled: settings.dateStampEnabled,
            captureDate: captureDate,
            useP3: useP3,
            formatUTI: settings.formatUTIIdentifier,
            fileURL: destinationURL.appendingPathComponent(baseName).appendingPathExtension(settings.fileExtension),
            collisionMode: collisionMode
        )

        return try await PhotoExporter.exportOffMain(job, isCurrent: isCurrent)
    }

    /// In-memory equivalent of the disk-save stamping inside
    /// `exportImage`. Apply this at every site that hands an
    /// `NSImage` to the gallery / preview UI (`enhancedPreviewImages`,
    /// `previewImage`) so what the user sees in the app matches what
    /// gets written to disk — same toggle (`captureDateStampEnabled`),
    /// same fallback (`Date()` if the camera didn't supply a date).
    ///
    /// When the toggle is off, returns the input image unchanged
    /// (zero-cost no-op). When it's on but stamping fails for any
    /// reason (no CGImage, stampDate returned nil), the original
    /// image is returned — the gallery never gets a blank image just
    /// because the stamp couldn't render.
    private func stampedIfEnabled(_ image: NSImage, captureDate: Date?, stampEnabled: Bool? = nil) -> NSImage {
        guard stampEnabled ?? captureDateStampEnabled else { return image }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let dateToStamp = captureDate ?? Date()
        guard let stamped = PhotoExporter.stampDate(on: cgImage, at: dateToStamp) else {
            return image
        }
        return NSImage(cgImage: stamped, size: image.size)
    }

    /// Same shape as `parseImageDate(from:)` but returns a `Date` so
    /// callers can format it for EXIF (`yyyy:MM:dd HH:mm:ss`) or anything
    /// else they need.
    private func parseImageDateAsDate(from header: [UInt8]) -> Date? {
        // Easter egg: when the date header is missing or unreadable, vintage
        // files would otherwise fall back to the 1970 UNIX epoch. Instead we
        // quietly stamp the camera's own release date.
        NamingMetadataPolicy.parseImageDateAsDate(
            from: header,
            fallbackDate: selectedModel.releaseDate
        )
    }

    /// Reconstructs an image-header style buffer from a saved `.qtk`
    /// file so the QTK paths (re-import, drag-in, batch convert) can
    /// share the same EXIF helpers as the live-camera path. The QTK
    /// format (see `QTKFormatter`) packs camera header bytes 4..63 at
    /// file offset 14..73, so we mirror that mapping here.
    private nonisolated static func imageHeaderFromQTK(_ data: Data) -> [UInt8]? {
        NamingMetadataPolicy.imageHeaderFromQTK(data)
    }

    private func exportMetadataProperties(captureDate: Date? = nil, modeLabel: String) -> [String: Any] {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.2"
        return NamingMetadataPolicy.exportMetadataProperties(
            modelName: selectedModel.displayName,
            appVersion: appVersion,
            modeLabel: modeLabel,
            captureDate: captureDate
        )
    }

    // Default destination and security-scoped-bookmark resolution live in
    // `DestinationBookmarkStore` (`destinationStore`).
}

// MARK: - Demo-mode hook
//
// Demo mode supplies bytes at the four points where camera bytes enter this
// file (fetchMetadata, fetchThumbnailBytes, fetchImageHeader, fetchFullImage)
// and then stays out of the way. Everything else — the thumbnail loop and its
// loading bar, the import loop and its progress bar, the decoder, the colour
// pipeline, exportImage, naming, dedup, the post-import action — is the real
// code path, unmodified.
//
// That is why this hook is so small. It does not simulate an import; it lets
// the real import run against a camera that happens to live in the app
// bundle. See DemoCamera.
extension QuickTakeSerialManager {
    /// Bring the demo camera up and build the gallery through the REAL
    /// thumbnail loop, so the streaming bar and the per-cell fizzle-in behave
    /// exactly as they do on hardware.
    func demoConnect(model: QuickTakeModel) async {
        invalidateCameraWork()
        let workGeneration = cameraWork.generation
        isBusy = true
        clearGalleryState()
        selectedModel = model
        DemoCamera.shared.connect(as: model)

        isConnecting = true
        statusMessage = "Connecting…"
        // A beat of "connecting" so the HUD and its barber pole are actually
        // seen; a demo that snaps straight to connected hides the work.
        try? await Task.sleep(nanoseconds: 900_000_000)

        guard cameraWork.isCurrent(workGeneration) else { return }
        metadata = DemoCamera.shared.metadata()
        detectedPortPath = "/dev/cu.demo-quicktake"
        isConnected = true
        isConnecting = false
        errorMessage = nil
        presentToast(nil)

        await fetchAllThumbnails()
        guard cameraWork.isCurrent(workGeneration) else { return }
        isBusy = false
        statusMessage = defaultIdleStatus
    }

    /// Simulate an import: the transfer pacing, the progress bar and the
    /// colour preview arriving, with nothing written to disk.
    ///
    /// Demo mode deliberately does NOT run the real export. A demo that
    /// leaves photos in someone's pictures folder is bad manners, and it also
    /// broke the gallery — the cross-session recogniser matched the demo's
    /// own output by filename, so on the next connect every photo came back
    /// already-imported and the thumbnails never appeared to stream.
    ///
    /// No file means no folder badge and no Finder reveal, which is honest:
    /// there is nothing to reveal.
    func demoImport(_ indices: [UInt8]) async {
        guard !indices.isEmpty else { return }
        let workGeneration = cameraWork.generation
        clearCameraProgress()
        cameraTransfers = indices.map {
            PhotoTransfer(index: $0, progress: 0, status: .waiting, savedFiles: [])
        }
        isBusy = true
        statusMessage = "Importing Photos…"

        for index in indices {
            if let i = cameraTransfers.firstIndex(where: { $0.index == index }) {
                cameraTransfers[i].status = .downloading
            }
            for step in 1...20 {
                updateLiveProgress(index: index, progress: Double(step) / 20.0)
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard cameraWork.isCurrent(workGeneration) else { return }
            }
            // The colour preview the decoder would have produced. Real bytes,
            // real decode — just no export.
            if let preview = DemoCamera.shared.decodedPreview(at: index) {
                enhancedPreviewImages[index] = preview
            }
            if let i = cameraTransfers.firstIndex(where: { $0.index == index }) {
                cameraTransfers[i].progress = 1
                cameraTransfers[i].status = .imported
            }
        }

        statusMessage = "Import Complete"
        isBusy = false
        let finishedIDs = Set(cameraTransfers.map(\.id))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard cameraWork.isCurrent(workGeneration) else { return }
        for id in finishedIDs { liveProgress.values.removeValue(forKey: id) }
        cameraTransfers.removeAll { finishedIDs.contains($0.id) }
        scheduleStatusRevert()
    }

    func demoDisconnect() {
        invalidateCameraWork()
        isBusy = false
        DemoCamera.shared.disconnect()
        clearGalleryState(keepingSlots: false)
        isConnected = false
        isConnecting = false
        metadata = nil
        detectedPortPath = nil
        clearCameraProgress()
        cameraTransfers = []
        statusMessage = "Ready"
    }
}
