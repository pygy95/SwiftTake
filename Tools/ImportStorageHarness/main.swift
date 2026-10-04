import Foundation

// Fixed-output checks for the storage components split out of
// `QuickTakeSerialManager`:
//
//   • `DestinationBookmarkStore` — legacy-key migration, security-scoped
//     bookmark save / resolve / stale-refresh / clear, and the pre-write
//     "is this folder still usable" fall-back.
//   • `FujiImportLedger` — the QT200 already-imported DSC-name → path/size
//     map and its prune-by-fileExists housekeeping.
//
// No camera, no manager, no `UserDefaults.standard`, no personal Pictures
// folder. Every check runs against an isolated `UserDefaults(suiteName:)`
// suite and temporary directories. An injected fallback provider keeps
// destination checks inside the scratch tree without changing the environment.
//
// The bookmark checks build the store with EMPTY bookmark options:
// `.withSecurityScope` needs the app sandbox entitlement, which a plain
// command-line tool doesn't have. The save/resolve/stale/clear semantics
// under test are identical for plain and security-scoped bookmarks; the app
// always uses the security-scoped defaults. What this harness does NOT
// prove: security-scoped resolution/renewal, `startAccessingSecurityScopedResource`
// grants, or how any of this behaves inside the actual App Sandbox — that
// can only be established by running the built app on real hardware.

@main struct ImportStorageChecks {

    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1
            print("PASS: " + name)
        }

        let fm = FileManager.default

        // Every file operation stays inside this unique test directory.
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("swifttake-import-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let suiteName = "com.swifttake.harness.importstorage.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        func makeDir(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func makeFile(_ name: String, bytes: Int) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data(repeating: 0x2A, count: bytes).write(to: url)
            return url
        }

        // ════════════════════════════════════════════════════════════════
        // 1. Legacy-key migration
        // ════════════════════════════════════════════════════════════════
        let newKey = PrefKey.newTakeEnabled
        let legacyKey = PrefKey.legacyPerfectColorEnhanced
        func clearMigrationKeys() {
            suite.removeObject(forKey: newKey)
            suite.removeObject(forKey: legacyKey)
        }

        // Legacy true, new absent → carried across; legacy key removed.
        clearMigrationKeys()
        suite.set(true, forKey: legacyKey)
        DestinationBookmarkStore.migrateLegacyKeys(defaults: suite)
        check(suite.object(forKey: newKey) as? Bool == true,
              "migrateLegacyKeys carries a legacy true onto the new key")
        check(suite.object(forKey: legacyKey) == nil,
              "migrateLegacyKeys removes the legacy key after carrying it")

        // Legacy false, new absent → the false is carried (not defaulted).
        clearMigrationKeys()
        suite.set(false, forKey: legacyKey)
        DestinationBookmarkStore.migrateLegacyKeys(defaults: suite)
        check(suite.object(forKey: newKey) as? Bool == false,
              "migrateLegacyKeys carries a legacy false (distinct from unset)")

        // New already set → legacy is ignored, new is untouched, legacy cleared.
        clearMigrationKeys()
        suite.set(false, forKey: newKey)
        suite.set(true, forKey: legacyKey)
        DestinationBookmarkStore.migrateLegacyKeys(defaults: suite)
        check(suite.object(forKey: newKey) as? Bool == false,
              "migrateLegacyKeys does not overwrite an existing new key")
        check(suite.object(forKey: legacyKey) == nil,
              "migrateLegacyKeys still clears the legacy key when new is set")

        // Neither present → no-op, no crash, new stays unset.
        clearMigrationKeys()
        DestinationBookmarkStore.migrateLegacyKeys(defaults: suite)
        check(suite.object(forKey: newKey) == nil,
              "migrateLegacyKeys leaves the new key unset when nothing to carry")
        clearMigrationKeys()

        // ════════════════════════════════════════════════════════════════
        // 2. Bookmark save / resolve / clear  (plain bookmarks)
        // ════════════════════════════════════════════════════════════════
        // Inject the fallback so every destination stays inside the test directory.
        let injectedDefault = scratch.appendingPathComponent("fallback-default/SwiftTake", isDirectory: true)
        let store = DestinationBookmarkStore(defaults: suite,
                                             bookmarkCreationOptions: [],
                                             bookmarkResolutionOptions: [],
                                             defaultDestination: { injectedDefault })
        let importKey = PrefKey.importDestinationBookmark

        check(store.resolvedDestination(.importDestination) == nil,
              "resolvedDestination is nil with nothing stored")

        let dirA = try makeDir("dirA")
        check(store.makeBookmark(for: dirA, slot: .importDestination),
              "makeBookmark succeeds for a real directory")
        check(suite.data(forKey: importKey) != nil,
              "makeBookmark writes bookmark data under the import key")
        check(store.resolvedDestination(.importDestination)?.standardizedFileURL.path
              == dirA.standardizedFileURL.path,
              "resolvedDestination returns the bookmarked directory")

        // Slots are independent keys.
        let dirB = try makeDir("dirB")
        check(store.makeBookmark(for: dirB, slot: .qtk),
              "makeBookmark succeeds for the qtk slot")
        check(store.resolvedDestination(.qtk)?.standardizedFileURL.path
              == dirB.standardizedFileURL.path,
              "the qtk slot resolves independently of the import slot")

        let panoramaDirectory = try makeDir("panoramas")
        check(!store.hasSavedDestination(.panorama), "panorama defaults to no saved bookmark")
        check(store.makeBookmark(for: panoramaDirectory, slot: .panorama),
              "makeBookmark succeeds for the panorama slot")
        let reopenedStore = DestinationBookmarkStore(defaults: suite,
                                                     bookmarkCreationOptions: [],
                                                     bookmarkResolutionOptions: [])
        check(reopenedStore.resolvedDestination(.panorama)?.standardizedFileURL.path
              == panoramaDirectory.standardizedFileURL.path,
              "a new store restores the persisted panorama folder")
        check(store.resolvedDestination(.importDestination)?.standardizedFileURL.path == dirA.path
              && store.resolvedDestination(.qtk)?.standardizedFileURL.path == dirB.path,
              "saving a panorama folder preserves photo and QTK choices")
        try fm.removeItem(at: panoramaDirectory)
        check(store.resolvedDestination(.panorama) == nil && store.hasSavedDestination(.panorama),
              "an unavailable panorama folder retains its custom bookmark")
        try fm.createDirectory(at: panoramaDirectory, withIntermediateDirectories: true)
        check(store.resolvedDestination(.panorama)?.standardizedFileURL.path == panoramaDirectory.path,
              "the panorama bookmark resolves again after its folder returns")
        store.clear(.panorama)
        check(!store.hasSavedDestination(.panorama)
              && store.resolvedDestination(.importDestination) != nil
              && store.resolvedDestination(.qtk) != nil,
              "resetting panoramas leaves photo and QTK bookmarks intact")

        store.clear(.importDestination)
        check(suite.data(forKey: importKey) == nil,
              "clear removes the import bookmark data")
        check(store.resolvedDestination(.importDestination) == nil,
              "resolvedDestination is nil again after clear")
        check(store.resolvedDestination(.qtk) != nil,
              "clearing the import slot leaves the qtk slot intact")
        store.clear(.qtk)

        // Hard failure: corrupt bookmark data is unreadable as bookmark
        // bytes at all (.fileReadCorruptFile) — unrecoverable, key cleared.
        suite.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: importKey)
        check(store.resolvedDestination(.importDestination) == nil,
              "resolvedDestination returns nil for un-resolvable bookmark data")
        check(suite.data(forKey: importKey) == nil,
              "resolvedDestination clears the key on hard failure")

        // Transient failure: the bookmarked directory is gone (ejected
        // volume, momentarily missing) — that's .fileNoSuchFile, not
        // .fileReadCorruptFile, so the bookmark data must survive for a
        // later resolve rather than being permanently discarded.
        let vanishing = try makeDir("vanishing")
        _ = store.makeBookmark(for: vanishing, slot: .importDestination)
        let dataBeforeVanish = suite.data(forKey: importKey)
        try fm.removeItem(at: vanishing)
        check(store.resolvedDestination(.importDestination) == nil,
              "resolvedDestination returns nil while the bookmarked directory is missing")
        check(suite.data(forKey: importKey) == dataBeforeVanish,
              "resolvedDestination keeps the bookmark data across a transient missing-directory failure")
        try fm.createDirectory(at: vanishing, withIntermediateDirectories: true)
        check(store.resolvedDestination(.importDestination)?.standardizedFileURL.path
              == vanishing.standardizedFileURL.path,
              "resolvedDestination succeeds again once the directory reappears at the same path")
        store.clear(.importDestination)

        // ════════════════════════════════════════════════════════════════
        // 3. Bookmark stale-refresh
        // ════════════════════════════════════════════════════════════════
        // Bookmark a directory, then rename it. Resolving the bookmark now
        // follows the file to its new path and reports the bookmark stale;
        // the store must return the new location and rewrite the stored
        // bookmark rather than clearing it.
        let staleSrc = try makeDir("stale-before")
        _ = store.makeBookmark(for: staleSrc, slot: .importDestination)
        let dataBeforeMove = suite.data(forKey: importKey)
        let staleDst = scratch.appendingPathComponent("stale-after", isDirectory: true)
        try fm.moveItem(at: staleSrc, to: staleDst)

        let resolvedAfterMove = store.resolvedDestination(.importDestination)
        check(resolvedAfterMove?.standardizedFileURL.path == staleDst.standardizedFileURL.path,
              "resolvedDestination follows a moved directory (stale bookmark)")
        check(suite.data(forKey: importKey) != nil,
              "a stale bookmark is refreshed in place, not cleared")
        check(suite.data(forKey: importKey) != dataBeforeMove,
              "the refreshed bookmark data differs from the pre-move data")
        check(store.resolvedDestination(.importDestination)?.standardizedFileURL.path
              == staleDst.standardizedFileURL.path,
              "the refreshed bookmark still resolves on a second read")
        store.clear(.importDestination)

        // ════════════════════════════════════════════════════════════════
        // 4. usableImportDestination fall-back
        // ════════════════════════════════════════════════════════════════
        // .ok — a folder that can be created and written.
        let usableTarget = scratch.appendingPathComponent("import-target", isDirectory: true)
        switch store.usableImportDestination(usableTarget) {
        case .ok(let url):
            check(url.standardizedFileURL.path == usableTarget.standardizedFileURL.path,
                  "usableImportDestination returns .ok for a creatable folder")
            var isDir: ObjCBool = false
            check(fm.fileExists(atPath: usableTarget.path, isDirectory: &isDir) && isDir.boolValue,
                  "usableImportDestination created the folder it approved")
        case .fellBack:
            check(false, "usableImportDestination unexpectedly fell back for a creatable folder")
        }

        // .fellBack(notify: true) — an un-creatable path that isn't the default.
        let blockedParent = try makeFile("blocked-parent", bytes: 1)
        let unwritable = blockedParent.appendingPathComponent("child", isDirectory: true)
        switch store.usableImportDestination(unwritable) {
        case .ok:
            check(false, "usableImportDestination unexpectedly approved an unwritable path")
        case .fellBack(let fallback, let notify):
            check(notify, "usableImportDestination signals notify when the requested folder isn't the default")
            check(fallback.standardizedFileURL.path == injectedDefault.standardizedFileURL.path,
                  "the fall-back destination is the injected default folder")
        }

        // .fellBack(notify: false) — the requested folder already IS the
        // default and it's unusable (a plain file sits where the folder
        // should be), so there's nothing new to tell the user.
        try fm.createDirectory(at: injectedDefault.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: injectedDefault)
        try Data([0x00]).write(to: injectedDefault)
        switch store.usableImportDestination(injectedDefault) {
        case .ok:
            check(false, "usableImportDestination approved a path blocked by a file")
        case .fellBack(let fallback, let notify):
            check(!notify,
                  "usableImportDestination suppresses notify when the requested folder already is the default")
            check(fallback.standardizedFileURL.path == injectedDefault.standardizedFileURL.path,
                  "the silent fall-back still points at the default location")
        }
        try? fm.removeItem(at: injectedDefault)

        // Laziness: with a custom QTK folder set, effectiveQTKDestination must
        // NOT evaluate the (autoclosure) import-destination — matching the
        // baseline `preferredQTK ?? effectiveImport…`.
        final class EvalFlag: @unchecked Sendable { var hit = false }
        let flag = EvalFlag()
        func markedImport() -> URL { flag.hit = true; return injectedDefault }
        let customQTK = try makeDir("custom-qtk")
        let qtkResult = store.effectiveQTKDestination(preferredQTK: customQTK,
                                                      effectiveImport: markedImport())
        check(qtkResult.standardizedFileURL.path == customQTK.standardizedFileURL.path,
              "effectiveQTKDestination returns the custom QTK folder unchanged")
        check(!flag.hit,
              "effectiveQTKDestination does not evaluate the import default when a custom QTK folder is set")
        let qtkFallback = store.effectiveQTKDestination(preferredQTK: nil,
                                                       effectiveImport: markedImport())
        check(flag.hit && qtkFallback.lastPathComponent == "QTK"
              && qtkFallback.deletingLastPathComponent().standardizedFileURL.path
                 == injectedDefault.standardizedFileURL.path,
              "effectiveQTKDestination falls back to <import>/QTK only when preferredQTK is nil")

        flag.hit = false
        let customPanorama = store.effectivePanoramaDestination(preferred: panoramaDirectory,
                                                                effectiveImport: markedImport())
        check(customPanorama == panoramaDirectory && !flag.hit,
              "custom panoramas use the chosen folder directly without evaluating the photo default")
        let defaultPanorama = store.effectivePanoramaDestination(preferred: nil,
                                                                 effectiveImport: markedImport())
        check(flag.hit && defaultPanorama == injectedDefault.appendingPathComponent("SwiftTake Panorama", isDirectory: true),
              "default panoramas follow the effective photo destination")
        check(store.effectivePanoramaDestination(preferred: nil, effectiveImport: dirA)
              == dirA.appendingPathComponent("SwiftTake Panorama", isDirectory: true),
              "changing the photo folder also changes the default panorama folder")

        // ════════════════════════════════════════════════════════════════
        // 5. FujiImportLedger record / prune / correlation
        // ════════════════════════════════════════════════════════════════
        suite.removeObject(forKey: PrefKey.fujiImportedPaths)
        suite.removeObject(forKey: PrefKey.fujiImportedSizes)
        let ledger = FujiImportLedger(defaults: suite)

        check(ledger.importedPath(forDSC: "DSC00001") == nil
              && ledger.importedSize(forDSC: "DSC00001") == nil,
              "an empty ledger has no path or size for any DSC name")
        ledger.prune()   // must not crash on an empty ledger
        check(suite.dictionary(forKey: PrefKey.fujiImportedPaths) == nil,
              "prune on an empty ledger writes nothing")

        let fileA = try makeFile("DSC00001.jpg", bytes: 111)
        let fileB = try makeFile("DSC00002.jpg", bytes: 222)
        ledger.record(dscName: "DSC00001", url: fileA, size: 111)
        check(ledger.importedPath(forDSC: "DSC00001") == fileA.path,
              "record stores the imported path under the DSC name")
        check(ledger.importedSize(forDSC: "DSC00001") == 111,
              "record stores the camera byte size under the DSC name")

        // nil / empty DSC names are ignored.
        ledger.record(dscName: nil, url: fileB, size: 999)
        ledger.record(dscName: "", url: fileB, size: 999)
        check((suite.dictionary(forKey: PrefKey.fujiImportedPaths) as? [String: String])?.count == 1,
              "record ignores a nil or empty DSC name")

        ledger.record(dscName: "DSC00002", url: fileB, size: 222)
        check(ledger.importedPath(forDSC: "DSC00002") == fileB.path
              && ledger.importedSize(forDSC: "DSC00002") == 222,
              "a second record keeps its own path/size pair")

        // prune with every file present rewrites nothing.
        let pathsBeforePrune = suite.dictionary(forKey: PrefKey.fujiImportedPaths) as? [String: String]
        let sizesBeforePrune = suite.dictionary(forKey: PrefKey.fujiImportedSizes) as? [String: Int]
        ledger.prune()
        check(suite.dictionary(forKey: PrefKey.fujiImportedPaths) as? [String: String] == pathsBeforePrune
              && suite.dictionary(forKey: PrefKey.fujiImportedSizes) as? [String: Int] == sizesBeforePrune,
              "prune leaves both maps untouched when every imported file still exists")

        // Delete one imported file; prune drops that entry from BOTH maps
        // and leaves the surviving pair fully intact.
        try fm.removeItem(at: fileB)
        ledger.prune()
        check(ledger.importedPath(forDSC: "DSC00002") == nil,
              "prune drops the path entry whose file was deleted")
        check(ledger.importedSize(forDSC: "DSC00002") == nil,
              "prune drops the size entry in lockstep with the path entry")
        check(ledger.importedPath(forDSC: "DSC00001") == fileA.path
              && ledger.importedSize(forDSC: "DSC00001") == 111,
              "prune preserves the path/size pair whose file still exists")

        // Original archives (`saveSafely`): successful writes return a usable
        // path and never overwrite bytes that don't match; genuine directory-
        // creation failures still throw before a caller can register a URL.
        // All failures are local and deterministic, including when the
        // harness runs with elevated access.
        let archiveDirectory = scratch.appendingPathComponent("originals/nested", isDirectory: true)
        let original = Data([0x71, 0x6b, 0x74, 0x6e, 0, 1, 2, 3])
        let archive = try QTKArchiveStore.saveSafely(original, candidateStem: "Photo 001", in: archiveDirectory)
        check(archive.lastPathComponent == "Photo 001.qtk", "archive returns the requested filename")
        check(try Data(contentsOf: archive) == original, "archive creates nested folders and preserves all bytes")

        // Identical bytes saved again under the same candidate reuse the
        // existing file rather than writing a second copy.
        let reused = try QTKArchiveStore.saveSafely(original, candidateStem: "Photo 001", in: archiveDirectory)
        check(reused == archive, "saving identical bytes again reuses the same archive URL")

        // Different bytes under the same candidate are never overwritten —
        // they land at a distinct, disambiguated name instead.
        let replacement = Data([9, 8, 7])
        let distinct = try QTKArchiveStore.saveSafely(replacement, candidateStem: "Photo 001", in: archiveDirectory)
        check(distinct.lastPathComponent == "Photo 001 2.qtk",
              "different bytes under the same candidate are preserved under a new name, never overwritten")
        check(try Data(contentsOf: archive) == original, "the original archive's bytes are untouched by the later distinct save")
        check(try Data(contentsOf: distinct) == replacement, "the new archive holds its own exact bytes")
        check(Set(try fm.contentsOfDirectory(atPath: archiveDirectory.path)) == ["Photo 001.qtk", "Photo 001 2.qtk"],
              "successful writes leave no leftover staging files")

        let blockedFolder = try makeFile("blocked-originals", bytes: 7)
        var failedPath: URL?
        do {
            failedPath = try QTKArchiveStore.saveSafely(original, candidateStem: "Photo", in: blockedFolder)
        } catch { }
        check(failedPath == nil, "a file blocking the archive directory yields no saved URL")
        check(try Data(contentsOf: blockedFolder) == Data(repeating: 0x2A, count: 7),
              "directory creation failure preserves the blocking file")

        // A directory occupying the candidate name can't be read as archive
        // bytes — treated as a non-match (never assumed safe to replace), so
        // the save is diverted to the next candidate instead of touching it.
        let occupied = archiveDirectory.appendingPathComponent("Occupied.qtk", isDirectory: true)
        try fm.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("keep.txt")
        try original.write(to: sentinel)
        let diverted = try QTKArchiveStore.saveSafely(replacement, candidateStem: "Occupied", in: archiveDirectory)
        check(diverted.lastPathComponent == "Occupied 2.qtk",
              "a directory blocking the candidate name diverts the save to the next name")
        check(try Data(contentsOf: diverted) == replacement, "the diverted save holds its own exact bytes")
        check(try Data(contentsOf: sentinel) == original,
              "the blocking directory and its contents are untouched")

        print("\nAll \(passed) import-storage checks passed.")
    }
}
