import Foundation

// MARK: - DestinationBookmarkStore
//
// Persistence for photo, panorama and kept `.qtk` folders in Settings. Owns the
// security-scoped bookmark storage, the stale-bookmark refresh, the
// one-time legacy-key migration, and the "is this folder still usable"
// pre-flight the import paths run before writing.
//
// The source of truth is `UserDefaults` (injectable, so a harness can use
// an isolated suite). `QuickTakeSerialManager` keeps the `@Published`
// mirrors and owns every user-facing message — this type only reports what
// happened so the manager can phrase it.
//
// `nonisolated` (the module defaults to `@MainActor`): the work is
// filesystem and `UserDefaults` I/O with no app or UI state, matching
// `PhotoExporter` / `AtomicFileWriter`. The manager already calls the same
// code synchronously on the main actor, so behaviour is unchanged.

nonisolated struct DestinationBookmarkStore {

    /// Which destination a call refers to. The raw key strings are the ones
    /// already on users' disks — see `PrefKey`.
    enum Slot {
        case importDestination
        case qtk
        case panorama

        var defaultsKey: String {
            switch self {
            case .importDestination: return PrefKey.importDestinationBookmark
            case .qtk:               return PrefKey.qtkDestinationBookmark
            case .panorama:          return PrefKey.panoramaDestinationBookmark
            }
        }
    }

    /// Outcome of pointing the import destination at a user-picked folder.
    enum SetOutcome {
        /// Bookmarked the folder the user picked.
        case saved(URL)
        /// The picked folder itself refused a bookmark (a volume root, an
        /// exFAT/FAT card…); a `SwiftTake` sub-folder was created inside it
        /// and bookmarked instead. `parent` is what the user picked.
        case savedInSubfolder(URL, parent: URL)
        /// Nothing could be bookmarked.
        case failed
    }

    /// Result of pre-flighting the import destination immediately before a
    /// write. `.fellBack` carries the default folder to use instead, plus
    /// whether the caller should surface a notice (it should not when the
    /// requested folder already was the default).
    enum UsableDestination {
        case ok(URL)
        case fellBack(fallback: URL, notify: Bool)
    }

    let defaults: UserDefaults
    private let bookmarkCreationOptions: URL.BookmarkCreationOptions
    private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions
    private let defaultDestination: @Sendable () -> URL

    /// `bookmark*Options` are injectable purely so a non-sandboxed harness
    /// can pass `[]` — `.withSecurityScope` needs the app entitlement. The
    /// app always uses the security-scoped defaults, matching shipped
    /// behaviour. `defaultDestination` is likewise injectable so a harness
    /// can point the fall-back at a scratch folder instead of the real
    /// `~/Pictures/SwiftTake`; the app uses `defaultImportDestination()`.
    init(defaults: UserDefaults = .standard,
         bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope],
         bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope],
         defaultDestination: @escaping @Sendable () -> URL = { DestinationBookmarkStore.defaultImportDestination() }) {
        self.defaults = defaults
        self.bookmarkCreationOptions = bookmarkCreationOptions
        self.bookmarkResolutionOptions = bookmarkResolutionOptions
        self.defaultDestination = defaultDestination
    }

    // MARK: Legacy-key migration

    /// Carry a setting stored under the old PerfectColor-era key across to
    /// its replacement, once, before anything reads the preference.
    ///
    /// Without this, renaming the key would silently reset the user's Look
    /// back to the default — the setting would not be lost so much as
    /// quietly changed, which is worse.
    ///
    /// Static so `QuickTakeSerialManager.init` can call it as its very first
    /// step, before `self` is fully initialised.
    static func migrateLegacyKeys(defaults: UserDefaults = .standard) {
        let d = defaults
        if d.object(forKey: PrefKey.newTakeEnabled) == nil,
           let old = d.object(forKey: PrefKey.legacyPerfectColorEnhanced) as? Bool {
            d.set(old, forKey: PrefKey.newTakeEnabled)
        }
        d.removeObject(forKey: PrefKey.legacyPerfectColorEnhanced)
    }

    // MARK: Bookmark resolution (init-time reads)

    /// The URL a stored bookmark for `slot` resolves to, or nil. A stale
    /// bookmark is transparently refreshed in place. On failure, only bytes
    /// that are themselves unreadable as bookmark data (`.fileReadCorruptFile`
    /// — confirmed empirically: garbage, empty, and truncated bookmark data
    /// all raise this, distinctly from a missing target) are unrecoverable
    /// and clear the key; every other failure — most commonly a missing or
    /// unmounted target (`.fileNoSuchFile`) — is treated as transient, so the
    /// data is kept for a later resolve once the volume/folder is back.
    func resolvedDestination(_ slot: Slot) -> URL? {
        let key = slot.defaultsKey
        guard let bookmarkData = defaults.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale,
               let refreshed = try? url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(refreshed, forKey: key)
            }
            return url
        } catch CocoaError.fileReadCorruptFile {
            defaults.removeObject(forKey: key)
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Effective destination

    func hasSavedDestination(_ slot: Slot) -> Bool {
        defaults.data(forKey: slot.defaultsKey) != nil
    }

    /// `~/Pictures/SwiftTake`, falling back to the app's Documents container
    /// (durable in the sandbox) and then the temp dir if `.picturesDirectory`
    /// is somehow unavailable. The folder is created on demand.
    static func defaultImportDestination() -> URL {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let targetURL = baseDir.appendingPathComponent("SwiftTake")
        try? fm.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
        return targetURL
    }

    func effectiveImportDestination(preferred: URL?) -> URL {
        preferred ?? defaultDestination()
    }

    /// The kept-originals folder: a user override, else a `QTK` sub-folder of
    /// the effective photo destination so originals stay grouped with their
    /// decoded counterparts without cluttering the same listing.
    ///
    /// `effectiveImport` is `@autoclosure` so a set `preferredQTK` never
    /// forces the import-destination default to be computed (and its folder
    /// created) — matching the baseline `preferredQTK ?? effectiveImport…`.
    func effectiveQTKDestination(preferredQTK: URL?, effectiveImport: @autoclosure () -> URL) -> URL {
        preferredQTK ?? effectiveImport().appendingPathComponent("QTK", isDirectory: true)
    }

    func effectivePanoramaDestination(preferred: URL?, effectiveImport: @autoclosure () -> URL) -> URL {
        preferred ?? effectiveImport().appendingPathComponent("SwiftTake Panorama", isDirectory: true)
    }

    /// `~`-relative display form of a destination path, for Settings.
    static func displayName(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// True when a custom destination is set but isn't currently a reachable
    /// directory (e.g. a disconnected USB drive). A nil `preferred` is the
    /// default, which is never "unreachable".
    func isUnreachable(preferred: URL?) -> Bool {
        guard let url = preferred else { return false }
        let acc = url.startAccessingSecurityScopedResource()
        defer { if acc { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        return !ok
    }

    // MARK: Set / clear

    /// Store a security-scoped bookmark for `url` under `slot`. Returns false
    /// if the OS refuses (see the sub-folder fallback in `setImportDestination`).
    func makeBookmark(for url: URL, slot: Slot) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmarkData, forKey: slot.defaultsKey)
            return true
        } catch {
            return false
        }
    }

    /// Point the import destination at `url`. Some locations — most often a
    /// volume ROOT like a USB stick, or an exFAT/FAT card — won't accept a
    /// security-scoped bookmark directly even though a folder inside them
    /// will, so a `SwiftTake` sub-folder is transparently created and
    /// bookmarked there (the same convention `~/Pictures/SwiftTake` uses).
    func setImportDestination(_ url: URL) -> SetOutcome {
        if makeBookmark(for: url, slot: .importDestination) { return .saved(url) }

        let sub = url.appendingPathComponent("SwiftTake", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        if makeBookmark(for: sub, slot: .importDestination) {
            return .savedInSubfolder(sub, parent: url)
        }
        return .failed
    }

    func clear(_ slot: Slot) {
        defaults.removeObject(forKey: slot.defaultsKey)
    }

    // MARK: Import-time pre-flight

    /// Make sure there's a writable folder before an import begins. A saved
    /// folder can vanish between launches (moved, trashed, or on an external
    /// drive that's now unplugged); the bookmark still resolves to a dead
    /// path. Try to (re)create it inside its security scope, and otherwise
    /// report a fall back to the default so the import still lands somewhere.
    func usableImportDestination(_ requested: URL) -> UsableDestination {
        let hasAccess = requested.startAccessingSecurityScopedResource()
        defer { if hasAccess { requested.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        let created = (try? FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)) != nil
        let existsAsDir = FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDir) && isDir.boolValue
        if created, existsAsDir, FileManager.default.isWritableFile(atPath: requested.path) {
            return .ok(requested)
        }

        let fallback = defaultDestination()
        let notify = requested.standardizedFileURL != fallback.standardizedFileURL
        return .fellBack(fallback: fallback, notify: notify)
    }
}
