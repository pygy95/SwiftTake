import Foundation

// MARK: - FujiImportLedger
//
// Cross-session record of which QT200 photos have already been imported,
// keyed by the camera's stable `DSC0000N` name.
//
// QT200 imports are saved under an EXIF-date filename
// ("QuickTake200_<date>_<time>") that can't be reconstructed from the cheap
// enumeration data, so on reconnect this map is how an already-imported
// photo is recognised without a wasteful re-fetch of its camera thumbnail.
// The camera-reported byte size is stored alongside the path: two different
// QT200s can't be renamed and reuse the same DSC names, but two distinct
// photos almost never share an exact byte size, so the size lets the
// reconnect check VERIFY a name match is really this photo.
//
// Backed entirely by `UserDefaults` (injectable for tests). `nonisolated`
// (the module defaults to `@MainActor`): plain `UserDefaults` + `FileManager`
// I/O with no app or UI state.

nonisolated struct FujiImportLedger {

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// DSC name → absolute path the photo was imported to.
    private var paths: [String: String] {
        get { (defaults.dictionary(forKey: PrefKey.fujiImportedPaths) as? [String: String]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: PrefKey.fujiImportedPaths) }
    }

    /// DSC name → camera-reported byte size of that photo.
    private var sizes: [String: Int] {
        get { (defaults.dictionary(forKey: PrefKey.fujiImportedSizes) as? [String: Int]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: PrefKey.fujiImportedSizes) }
    }

    /// The path `dsc` was imported to, if recorded.
    func importedPath(forDSC dsc: String) -> String? { paths[dsc] }

    /// The recorded camera byte size for `dsc`, if any.
    func importedSize(forDSC dsc: String) -> Int? { sizes[dsc] }

    /// Record that the QT200 photo named `dscName` (camera-reported `size`
    /// bytes) was imported to `url`. The path and size are written as a pair
    /// so the reconnect check can require both to match.
    func record(dscName: String?, url: URL, size: Int) {
        guard let dscName, !dscName.isEmpty else { return }
        var map = paths
        map[dscName] = url.path
        paths = map
        var sizeMap = sizes
        sizeMap[dscName] = size
        sizes = sizeMap
    }

    /// Drop map entries whose imported file no longer exists on disk, so the
    /// DSC-name→path map can't grow without bound as users delete old
    /// imports. Cheap enough to run once per connect. The read side already
    /// guards on `fileExists`, so this is housekeeping, never correctness.
    /// The sizes map is filtered to the same surviving keys so it can't grow
    /// unbounded either.
    func prune() {
        let map = paths
        guard !map.isEmpty else { return }
        let pruned = map.filter { FileManager.default.fileExists(atPath: $0.value) }
        if pruned.count != map.count {
            paths = pruned
            sizes = sizes.filter { pruned[$0.key] != nil }
        }
    }
}
