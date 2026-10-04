import AppKit
import Foundation

@MainActor
final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var current = true, fuji = false, keepOriginal = true
    var queue: [UInt8] = [0]
    var headerReads = 0, recoveries = 0, fetches = 0, prompts = 0, interruptions = 0
    var namesRead: [UInt8] = [], exports: [String] = []
    var exportAllowReplace: [Bool] = []
    var saves: [CameraBatchImportEngine.SavedPhoto] = []
    var interruptedReports: [CameraBatchImportEngine.InterruptionReport] = []
    var skipped: [[URL]] = []
    var updates: [(UInt8, Double, PhotoTransfer.Status)] = []
    var header: [UInt8] { var h = [UInt8](repeating: 0, count: 25); h[7] = 3; return h }
    var archiveDirectory: URL { directory.appendingPathComponent("Originals") }

    // Settings fields, mutable so a test can flip them mid-photo (inside a
    // hook that fires after the engine has already taken its per-photo
    // snapshot) and prove the change is inert until the NEXT photo.
    var fileExtension = "png"
    var formatUTIIdentifier = "public.png"
    var isLossyFormat = false
    var colorModeSuffix = ""
    var colorModeLabel = "Vintage"
    var dateStampEnabled = false
    var enhancedColor = false
    var hdrEnabled = false
    var hdrHeadroom = 1.0
    // Every settings snapshot the engine actually took, and every one an
    // export/decode hook actually received — lets a test assert the two
    // stayed the SAME value across an intervening settings change.
    var snapshotsTaken: [CameraBatchImportEngine.Settings] = []
    var exportSettings: [CameraBatchImportEngine.Settings] = []
    var decodeSettings: [CameraBatchImportEngine.Settings] = []

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([9]).write(to: url)
        return url
    }
    func currentSettings() -> CameraBatchImportEngine.Settings {
        .init(isFuji: fuji, keepOriginal: keepOriginal, fileExtension: fileExtension,
              formatUTIIdentifier: formatUTIIdentifier, isLossyFormat: isLossyFormat,
              archiveDirectory: archiveDirectory, colorModeSuffix: colorModeSuffix,
              colorModeLabel: colorModeLabel, dateStampEnabled: dateStampEnabled,
              enhancedColor: enhancedColor, hdrEnabled: hdrEnabled, hdrHeadroom: hdrHeadroom)
    }
    func hooks() -> CameraBatchImportEngine.Hooks {
        .init(isCurrent: { self.current && !Task.isCancelled },
              queue: { self.queue },
              settingsSnapshot: {
                  let settings = self.currentSettings()
                  self.snapshotsTaken.append(settings)
                  return settings
              },
              readHeader: { _ in self.headerReads += 1; return self.header },
              recover: { self.recoveries += 1; return true },
              ensureCameraName: { self.namesRead.append($0) },
              preliminaryName: { index, _, settings in "Photo \(index)" + settings.colorModeSuffix },
              fujiName: { _, _ in "Camera date" },
              chooseDuplicate: { _ in self.prompts += 1; return .skip(applyToAll: false) },
              importedURLs: { _ in [] },
              fetchImage: { _, _, _, progress in self.fetches += 1; progress?(0.5); return [1, 2, 3] },
              makeArchive: { _, _, bytes in Data(bytes) },
              decode: { _, _, _, settings in
                  self.decodeSettings.append(settings)
                  return NSImage(size: NSSize(width: 2, height: 2))
              },
              export: { _, name, directory, _, settings, allowReplace in
                  self.exports.append(name)
                  self.exportSettings.append(settings)
                  self.exportAllowReplace.append(allowReplace)
                  let url = directory.appendingPathComponent(name).appendingPathExtension(settings.fileExtension)
                  try Data([4, 5]).write(to: url)
                  return url
              },
              update: { index, progress, status, _ in self.updates.append((index, progress, status)) },
              didSkip: { _, files, _ in self.skipped.append(files) },
              didSave: { self.saves.append($0) },
              interrupted: { report in
                  self.interruptions += 1
                  self.interruptedReports.append(report)
                  // Production's `interrupted` hook tears down synchronously
                  // (disconnectCamera bumps the generation) before ever
                  // returning — mirror that here rather than the old
                  // connected=false/current=true fake, which tested a
                  // shape `run` never sees for real.
                  self.current = false
              },
              logTransfer: { _, _, _ in })
    }
    func run(_ hooks: CameraBatchImportEngine.Hooks? = nil, all: Bool = false) async -> CameraBatchImportEngine.Outcome? {
        await CameraBatchImportEngine.run(destination: directory, importAll: all, hooks: hooks ?? self.hooks())
    }
}

@main
struct Harness {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        checks += 1
    }
    @MainActor static func main() async throws {
        do {
            let f = try Fixture(); defer { f.clean() }
            let outcome = await f.run()
            check(outcome?.summary.importedPhotoCount == 1, "successful camera import")
            check(outcome?.summary.savedFiles.count == 2, "archive and render recorded")
            check(f.saves.first?.imageSize == 3, "header size passed to save adapter")
            check(f.updates.contains { $0.1 == 0.35 }, "download progress scaled")
            let original = try Data(contentsOf: f.saves[0].files[0])
            check(original == Data([1, 2, 3]), "original bytes preserved")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.readHeader = { _ in f.headerReads += 1; return f.headerReads == 1 ? nil : f.header }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 1, "header recovery succeeds")
            check(f.headerReads == 2 && f.recoveries == 1, "one header retry")
        }
        do {
            // Isolated bad header: recovery SUCCEEDS both times (the link is
            // alive), but the re-read header is still short — the batch
            // must keep going to the next photo rather than tearing down.
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            var h = f.hooks()
            h.readHeader = { _ in f.headerReads += 1; return [1] }
            let outcome = await f.run(h)
            check(outcome?.summary.failedPhotoCount == 2, "unreadable headers counted")
            check(f.headerReads == 4 && f.recoveries == 2 && f.fetches == 0, "bounded retries per header")
            check(f.interruptions == 0, "isolated bad header never hands off to interrupted()")
        }
        do {
            // Header failure BEFORE any save: the link is dead (recover
            // returns false) on the very first photo — must hand off through
            // the same interruption contract as a fetch-stage link fault,
            // not grind through the rest of the queue as failedHeader.
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            var h = f.hooks()
            h.readHeader = { _ in f.headerReads += 1; return [1] }
            h.recover = { f.recoveries += 1; return false }
            let outcome = await f.run(h)
            check(outcome == nil, "an interrupted batch hands off to interrupted() and yields no outcome")
            check(f.interruptions == 1, "interrupted hook fires exactly once")
            check(f.interruptedReports.count == 1, "interrupted hook fires exactly once")
            check(f.interruptedReports.first?.importedPhotoCount == 0, "captured report has nothing imported yet")
            check(f.interruptedReports.first?.savedFiles.isEmpty == true, "captured report has no files yet")
            check(f.headerReads == 1 && f.fetches == 0, "no further photos attempted after a dead-link header fault")
        }
        do {
            // Header failure AFTER a saved photo: photo 0 saves normally,
            // photo 1's header comes back short and the link is dead. The
            // captured report must reflect photo 0's tally, and photo 2
            // must never be attempted.
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1, 2]
            var h = f.hooks()
            h.readHeader = { index in f.headerReads += 1; return index == 0 ? f.header : [1] }
            h.recover = { f.recoveries += 1; return false }
            let outcome = await f.run(h)
            check(outcome == nil, "interruption after a successful photo still yields no outcome")
            check(f.interruptions == 1, "interrupted hook fires once, not per remaining photo")
            check(f.saves.count == 1, "only the photo before the fault was saved")
            check(f.interruptedReports.first?.importedPhotoCount == 1, "captured report keeps the photo imported before the fault")
            check(f.interruptedReports.first?.savedFiles.count == 2, "captured report keeps that photo's saved files")
            check(f.headerReads == 2 && f.fetches == 1, "photo 2 never attempted after the fault")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.readHeader = { _ in f.headerReads += 1; return nil }
            h.recover = { f.current = false; return true }
            let outcome = await f.run(h)
            check(outcome == nil && f.headerReads == 1, "obsolete recovery cannot start another read")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let rendered = try f.file("Photo 0.png"), archive = try f.file("original.qtk")
            var h = f.hooks(); h.importedURLs = { _ in [archive, rendered] }
            let outcome = await f.run(h, all: true)
            check(outcome?.summary.importedPhotoCount == 0, "import all skips existing render")
            check(f.prompts == 0 && f.fetches == 0, "skip avoids prompt and download")
            check(f.skipped == [[rendered, archive]], "skip retains original reference")
        }
        for choice in [BatchImportPolicy.DuplicateChoice.skip(applyToAll: true), .replace(applyToAll: true), .keepBoth(applyToAll: true), .stop] {
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            _ = try f.file("Photo 0.png"); _ = try f.file("Photo 1.png")
            var h = f.hooks(); h.chooseDuplicate = { _ in f.prompts += 1; return choice }
            let outcome = await f.run(h)
            check(f.prompts == 1, "duplicate choice sticks or stops")
            switch choice {
            case .skip: check(f.fetches == 0 && f.skipped.count == 2, "sticky skip")
            case .replace: check(f.exports == ["Photo 0", "Photo 1"], "sticky replace")
            case .keepBoth: check(f.exports == ["Photo 0 2", "Photo 1 2"], "sticky keep both")
            case .stop: check(outcome?.summary.stoppedByUser == true && f.fetches == 0, "stop ends batch")
            }
        }
        // Fuji duplicate policy (A1): the collision decision must be made
        // against the FINAL, EXIF-derived name — known only after the bytes
        // are fetched — and must honour Skip/Replace/Keep Both/Stop exactly
        // like QT100/150 does, sticky apply-to-all included, instead of the
        // historical bug (decide against a preliminary guess, then ALWAYS
        // silently keepBoth-rename the real name regardless of the choice).
        // `fujiName` returns the same stem for every index here, so a second
        // Fuji photo re-collides with whatever the first one just wrote —
        // exercising sticky policy across Fuji photos in one batch.
        for choice in [BatchImportPolicy.DuplicateChoice.skip(applyToAll: true), .replace(applyToAll: true), .keepBoth(applyToAll: true), .stop] {
            let f = try Fixture(); defer { f.clean() }
            f.fuji = true; f.keepOriginal = false
            f.queue = [0, 1]
            _ = try f.file("Camera date.png")
            var h = f.hooks(); h.chooseDuplicate = { _ in f.prompts += 1; return choice }
            let outcome = await f.run(h)
            check(f.prompts == 1, "Fuji final-name duplicate choice sticks or stops")
            switch choice {
            case .skip:
                check(f.fetches == 2 && f.exports.isEmpty && f.skipped.count == 2,
                      "Fuji sticky skip: both photos still fetch (the final name needs the bytes) but neither decodes/exports")
            case .replace:
                check(f.exports == ["Camera date", "Camera date"], "Fuji sticky replace: each photo overwrites the same final name")
            case .keepBoth:
                check(f.exports == ["Camera date 2", "Camera date 3"], "Fuji sticky keep both: each photo gets its own unique final name")
            case .stop:
                check(outcome?.summary.stoppedByUser == true && f.fetches == 1, "Fuji stop: the second photo's bytes are never fetched")
            }
        }
        do {
            // A single, non-sticky Fuji collision: the prompt must name the
            // FINAL file (proving the fix asks about the right name), and
            // Replace must overwrite exactly that file.
            let f = try Fixture(); defer { f.clean() }
            f.fuji = true; f.keepOriginal = false
            _ = try f.file("Camera date.png")
            var h = f.hooks()
            h.chooseDuplicate = { name in
                f.prompts += 1
                check(name == "Camera date.png", "Fuji prompt names the FINAL file, not a preliminary guess")
                return .replace(applyToAll: false)
            }
            let outcome = await f.run(h)
            check(f.prompts == 1, "Fuji final-name collision prompts exactly once")
            check(f.exports == ["Camera date"], "Fuji Replace overwrites the exact final name the prompt named")
            check(outcome?.summary.importedPhotoCount == 1, "Fuji Replace still counts as a successful import")
        }
        do {
            // Mirror image of the historical bug: a PRELIMINARY-name
            // collision that the final EXIF name doesn't share must never
            // prompt at all — Fuji's preliminary name is never checked.
            let f = try Fixture(); defer { f.clean() }
            f.fuji = true; f.keepOriginal = false
            _ = try f.file("Photo 0.png")   // the preliminary name — irrelevant for Fuji
            let outcome = await f.run()
            check(f.prompts == 0, "a preliminary-only collision never prompts for Fuji")
            check(f.exports == ["Camera date"], "Fuji exports at its final name, untouched by the preliminary collision")
            check(outcome?.summary.importedPhotoCount == 1, "Fuji import succeeds despite the irrelevant preliminary collision")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.didSave = { photo in f.saves.append(photo); if photo.index == 0 { f.queue.append(1) } }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 2, "photos appended during import are processed")
            check(f.saves.map(\.position) == [0, 1], "dynamic queue positions preserved")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.fetchImage = { _, _, _, _ in f.fetches += 1; return f.fetches == 1 ? nil : [1, 2, 3] }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 1, "download retry succeeds")
            check(f.fetches == 2 && f.recoveries == 1, "one download retry")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            var h = f.hooks()
            h.fetchImage = { _, _, _, _ in f.fetches += 1; return nil }
            h.recover = { false }
            let outcome = await f.run(h)
            check(f.interruptions == 1 && f.fetches == 1 && f.headerReads == 1, "failed recovery stops camera work")
            check(outcome == nil, "an interrupted batch hands off to interrupted() and yields no outcome")
            check(f.interruptedReports.count == 1, "interrupted hook fires exactly once")
            check(f.interruptedReports.first?.importedPhotoCount == 0, "captured report has nothing imported yet")
            check(f.interruptedReports.first?.savedFiles.isEmpty == true, "captured report has no files yet")
        }
        do {
            // A link fault after one photo already imported: the captured
            // report must reflect that photo, not zero — it's taken from
            // the engine's own tally, not re-derived after teardown.
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            var h = f.hooks()
            var fetchCount = 0
            h.fetchImage = { _, _, _, progress in
                fetchCount += 1
                progress?(1)
                return fetchCount == 1 ? [1, 2, 3] : nil
            }
            h.recover = { false }
            let outcome = await f.run(h)
            check(outcome == nil, "interruption after a successful photo still yields no outcome")
            check(f.interruptions == 1, "interrupted hook fires once, not per remaining photo")
            check(f.saves.count == 1, "only the photo before the fault was saved")
            check(f.interruptedReports.first?.importedPhotoCount == 1, "captured report keeps the photo imported before the fault")
            check(f.interruptedReports.first?.savedFiles.count == 2, "captured report keeps that photo's saved files")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.fetchImage = { _, _, _, _ in f.fetches += 1; return nil }
            let outcome = await f.run(h)
            check(f.fetches == 2 && f.recoveries == 1, "failed download retry bounded")
            check(outcome?.summary.failedPhotoCount == 1 && f.exports.isEmpty, "no export after failed download")
        }
        for result in 0...2 {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.export = { _, _, directory, _, _, _ in
                f.current = false
                if result == 2 { throw CocoaError(.fileWriteUnknown) }
                return result == 0 ? directory.appendingPathComponent("finished.png") : nil
            }
            let outcome = await f.run(h)
            check(outcome == nil && f.saves.isEmpty, "obsolete export cannot finalize any result")
            check(!f.updates.contains { update in
                if update.2 == .decodingFailed { return true }
                if case .saveError = update.2 { return true }
                return false
            }, "obsolete export cannot publish failure")
        }
        do {
            // "Reconnect mid-export" (A2): the fake's generation bumps
            // AFTER the export hook's own "encode" work finishes but BEFORE
            // publish — mirroring production's real guard in `exportImage`
            // (encode detached, re-check `isCurrent`, then
            // `AtomicFileWriter.publish`). The staged bytes must never reach
            // the final path, the temp must be cleaned up, and the engine
            // must not record the photo as saved.
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            h.export = { _, name, directory, _, settings, _ in
                let finalURL = directory.appendingPathComponent(name).appendingPathExtension(settings.fileExtension)
                let tempURL = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
                try Data([4, 5]).write(to: tempURL)
                f.current = false   // the reconnect, landing right after "encode"
                guard f.current else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                return finalURL
            }
            let outcome = await f.run(h)
            check(outcome == nil, "a reconnect mid-export yields no outcome")
            check(f.saves.isEmpty, "a reconnect mid-export is never recorded as saved")
            let finalURL = f.directory.appendingPathComponent("Photo 0.png")
            check(!FileManager.default.fileExists(atPath: finalURL.path), "a reconnect mid-export publishes no file")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: f.directory.path))?
                .filter { $0.hasPrefix(".staging-") } ?? []
            check(leftovers.isEmpty, "a reconnect mid-export removes its own staged temp file")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            _ = try f.file("Originals")
            let outcome = await f.run()
            check(outcome?.summary.importedPhotoCount == 1, "optional archive failure allows rendered export")
            check(f.saves[0].files.count == 1, "failed archive omitted from saved files")
        }
        for stage in 0...2 {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            if stage == 0 { h.decode = { _, _, _, _ in nil } }
            if stage == 1 { h.export = { _, _, _, _, _, _ in nil } }
            if stage == 2 { h.export = { _, _, _, _, _, _ in throw CocoaError(.fileWriteUnknown) } }
            let outcome = await f.run(h)
            check(outcome?.summary.failedPhotoCount == 1 && f.saves.isEmpty, "decode/export failure counted")
            check(outcome?.summary.savedFiles.count == 1, "original survives render failure")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks(); h.readHeader = { _ in [UInt8](repeating: 0, count: 25) }
            let outcome = await f.run(h)
            check(outcome?.summary.failedPhotoCount == 1 && f.fetches == 0 && f.recoveries == 0, "zero size cannot trigger download")
        }
        for stage in 0...3 {
            let f = try Fixture(); defer { f.clean() }
            var h = f.hooks()
            switch stage {
            case 0: h.ensureCameraName = { _ in f.current = false }
            case 1:
                _ = try f.file("Photo 0.png")
                h.chooseDuplicate = { _ in f.current = false; return .replace(applyToAll: false) }
            case 2:
                h.fetchImage = { _, _, _, progress in
                    f.current = false; progress?(1); return [1, 2, 3]
                }
            default: h.decode = { _, _, _, _ in f.current = false; return NSImage() }
            }
            let outcome = await f.run(h)
            check(outcome == nil && f.exports.isEmpty && f.saves.isEmpty, "invalidation at async boundary stops subsequent stages")
            check(!FileManager.default.fileExists(atPath: f.archiveDirectory.path), "obsolete job cannot save an archive")
            if stage == 2 { check(!f.updates.contains { $0.1 == 0.7 }, "obsolete download progress ignored") }
        }

        // MARK: - Settings-snapshot regressions (QT150 path)
        //
        // A settings change made while a photo's fetch/decode is suspended
        // must never split the duplicate decision this photo already made
        // from what actually gets decoded and written for it — the whole
        // point of taking ONE `Settings` snapshot before the collision
        // check and threading it, unchanged, through every hook after.
        do {
            let f = try Fixture(); defer { f.clean() }
            _ = try f.file("Photo 0.png")   // forces the duplicate prompt
            var h = f.hooks()
            var promptedName: String?
            h.chooseDuplicate = { name in
                promptedName = name
                f.prompts += 1
                // Simulate the user changing format/colour-mode/HDR/stamp
                // settings WHILE the collision prompt is up (a slow serial
                // fetch is about to follow it) — must not touch this photo.
                f.fileExtension = "tiff"
                f.formatUTIIdentifier = "public.tiff"
                f.isLossyFormat = true
                f.colorModeSuffix = "_newtake"
                f.colorModeLabel = "NewTake HDR"
                f.dateStampEnabled = true
                f.enhancedColor = true
                f.hdrEnabled = true
                f.hdrHeadroom = 2.0
                return .replace(applyToAll: false)
            }
            h.fetchImage = { _, _, _, progress in
                // The settings change is already live in the fixture by the
                // time this fires; a fresh live read here (the historical
                // bug) would leak the post-prompt format into this photo.
                f.fetches += 1; progress?(1); return [1, 2, 3]
            }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 1, "QT150 snapshot: import still succeeds across a live settings change")
            check(promptedName == "Photo 0.png", "QT150 snapshot: duplicate prompt saw the pre-change name and extension")
            check(f.exports == ["Photo 0"], "QT150 snapshot: export uses the pre-change name, no suffix leaked in")
            check(f.exportSettings.map(\.fileExtension) == ["png"], "QT150 snapshot: export used the snapshot extension, not the mid-photo change")
            check(f.decodeSettings.map(\.enhancedColor) == [false], "QT150 snapshot: decode used the snapshot colour mode, not the mid-photo change")
            check(f.decodeSettings.map(\.hdrEnabled) == [false], "QT150 snapshot: decode used the snapshot HDR flag, not the mid-photo change")
            check(f.saves.first?.settings.dateStampEnabled == false, "QT150 snapshot: recorded photo (preview stamp) carries the pre-change stamp toggle")
            let written = f.directory.appendingPathComponent("Photo 0").appendingPathExtension("png")
            check(FileManager.default.fileExists(atPath: written.path), "QT150 snapshot: file actually landed at the extension the prompt was answered for")
            check(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("Photo 0").appendingPathExtension("tiff").path),
                  "QT150 snapshot: no stray file at the post-change extension")
        }
        do {
            // Same defect, later window: the settings change happens during
            // the image fetch (after the collision decision, before decode
            // and export) rather than during the duplicate prompt itself —
            // and must apply starting with the NEXT photo in the same
            // batch, not the one already in flight.
            let f = try Fixture(); defer { f.clean() }
            f.queue = [0, 1]
            var h = f.hooks()
            h.fetchImage = { _, _, _, progress in
                f.fetches += 1
                if f.fetches == 1 {
                    f.fileExtension = "heic"; f.enhancedColor = true; f.hdrEnabled = true
                }
                progress?(1)
                return [1, 2, 3]
            }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 2, "QT150 snapshot: fetch-time settings change still imports both photos")
            check(f.exportSettings.map(\.fileExtension) == ["png", "heic"], "QT150 snapshot: photo 0 keeps the pre-change extension, photo 1 picks up the change")
            check(f.decodeSettings.map(\.enhancedColor) == [false, true], "QT150 snapshot: photo 0 keeps the pre-change colour mode, photo 1 picks up the change")
        }

        // MARK: - Settings-snapshot regressions (Fuji / QT200 path)
        do {
            let f = try Fixture(); defer { f.clean() }
            f.fuji = true
            var h = f.hooks()
            h.fetchImage = { _, _, _, progress in
                f.fetches += 1
                // A settings change mid-fetch must not change which naming
                // branch this photo takes, nor its extension/colour mode.
                f.fuji = false
                f.fileExtension = "jpeg"; f.isLossyFormat = true
                f.enhancedColor = true
                progress?(1)
                return [1, 2, 3]
            }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 1, "Fuji snapshot: import still succeeds across a live settings change")
            check(f.namesRead == [0], "Fuji snapshot: camera name still read for this photo")
            check(f.exports == ["Camera date"], "Fuji snapshot: Fuji naming still applied — the mid-fetch isFuji flip didn't retroactively switch branches")
            check(f.exportSettings.map(\.fileExtension) == ["png"], "Fuji snapshot: export used the snapshot extension, not the mid-fetch change")
            check(f.decodeSettings.map(\.enhancedColor) == [false], "Fuji snapshot: decode used the snapshot colour mode, not the mid-fetch change")
            let written = f.directory.appendingPathComponent("Camera date").appendingPathExtension("png")
            check(FileManager.default.fileExists(atPath: written.path), "Fuji snapshot: file landed at the pre-change extension")
        }
        do {
            // Fuji keepBoth now goes through the same prompt as everything
            // else (A1) — it must still stay pinned to the pre-fetch
            // snapshot: the collision check it runs (and the file it writes)
            // uses the snapshot's extension, not whatever the live setting
            // became while the Fuji stem's own fetch was in flight.
            let f = try Fixture(); defer { f.clean() }
            f.fuji = true
            _ = try f.file("Camera date.png")
            var h = f.hooks()
            h.fetchImage = { _, _, _, progress in
                f.fetches += 1
                f.fileExtension = "bmp"; f.colorModeLabel = "NewTake"; f.dateStampEnabled = true
                progress?(1)
                return [1, 2, 3]
            }
            h.chooseDuplicate = { _ in f.prompts += 1; return .keepBoth(applyToAll: false) }
            let outcome = await f.run(h)
            check(outcome?.summary.importedPhotoCount == 1, "Fuji snapshot: keepBoth import still succeeds")
            check(f.prompts == 1, "Fuji snapshot: keepBoth is asked like any other collision, exactly once")
            check(f.exports == ["Camera date 2"], "Fuji snapshot: keepBoth detected the collision using the snapshot extension, not the mid-fetch change")
            check(f.exportSettings.map(\.fileExtension) == ["png"], "Fuji snapshot: export extension pinned to the snapshot despite the mid-fetch change")
            check(f.saves.first?.settings.dateStampEnabled == false, "Fuji snapshot: preview stamp uses the snapshot toggle, not the mid-fetch change")
            let written = f.directory.appendingPathComponent("Camera date 2").appendingPathExtension("png")
            check(FileManager.default.fileExists(atPath: written.path), "Fuji snapshot: file landed at the snapshot extension, not the mid-fetch one")
        }

        print("Camera batch import: \(checks) checks passed")
    }
}
