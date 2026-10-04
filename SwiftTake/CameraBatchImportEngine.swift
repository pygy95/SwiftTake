import AppKit
import Foundation

/// Runs a camera import against explicit session and presentation adapters.
/// The manager retains serial ownership, settings and observable UI state.
@MainActor
enum CameraBatchImportEngine {
    struct SavedPhoto {
        let index: UInt8
        let position: Int
        let importedCount: Int
        let image: NSImage
        let header: [UInt8]
        let imageSize: Int
        let files: [URL]
        let exportedURL: URL
        let settings: Settings
    }

    /// Every setting that shapes how one photo is named, decoded and
    /// written, captured ONCE per photo before its duplicate check and
    /// threaded unchanged through naming, keepBoth/Fuji renaming, decode,
    /// export and the preview stamp. A live settings change mid-photo (the
    /// window spans several awaits: fetch, recover, decode) must not split
    /// the collision decision from what actually gets written — it takes
    /// effect starting with the next photo instead.
    struct Settings {
        let isFuji: Bool
        let keepOriginal: Bool
        let fileExtension: String
        let formatUTIIdentifier: String
        let isLossyFormat: Bool
        let archiveDirectory: URL
        let colorModeSuffix: String
        let colorModeLabel: String
        let dateStampEnabled: Bool
        let enhancedColor: Bool
        let hdrEnabled: Bool
        let hdrHeadroom: Double
    }

    /// Immutable tally captured the instant a mid-batch link fault is
    /// detected — before `interrupted` tears anything down. The manager
    /// publishes its fault feedback from this snapshot, never from state
    /// that teardown may already have cleared.
    struct InterruptionReport {
        let importedPhotoCount: Int
        let savedFiles: [URL]
    }

    struct Hooks {
        var isCurrent: @MainActor () -> Bool
        var queue: @MainActor () -> [UInt8]
        var settingsSnapshot: @MainActor () -> Settings
        var readHeader: @MainActor (UInt8) async -> [UInt8]?
        var recover: @MainActor () async -> Bool
        var ensureCameraName: @MainActor (UInt8) async -> Void
        var preliminaryName: @MainActor (UInt8, [UInt8], Settings) -> String
        var fujiName: @MainActor (UInt8, [UInt8]) -> String
        var chooseDuplicate: @MainActor (String) async -> BatchImportPolicy.DuplicateChoice
        var importedURLs: @MainActor (UInt8) -> [URL]
        var fetchImage: @MainActor (UInt8, Int, [UInt8], ((Double) -> Void)?) async -> [UInt8]?
        var makeArchive: @MainActor (UInt8, [UInt8], [UInt8]) -> Data
        var decode: @MainActor (UInt8, Data, [UInt8], Settings) async -> NSImage?
        /// `allowReplace`: true only when this photo's duplicate decision was
        /// Replace, chosen against the exact name being written — the export
        /// may overwrite that one file. Every other case (no collision,
        /// Keep Both's fresh name) is false: the export must not silently
        /// replace anything it didn't get explicit consent for.
        var export: @MainActor (NSImage, String, URL, [UInt8], Settings, Bool) async throws -> URL?
        var update: @MainActor (UInt8, Double, PhotoTransfer.Status, [URL]?) -> Void
        var didSkip: @MainActor (UInt8, [URL], URL) -> Void
        var didSave: @MainActor (SavedPhoto) -> Void
        /// Called once, from inside `run`, the moment a mid-batch link fault
        /// is confirmed unrecoverable. The hook owns teardown and feedback;
        /// `run` always returns nil afterward (teardown invalidates this job).
        var interrupted: @MainActor (InterruptionReport) async -> Void
        var logTransfer: @MainActor (UInt8, Int, Int) -> Void
    }

    struct Outcome {
        let summary: BatchImportPolicy.Summary
    }

    /// Returns nil for an obsolete or cancelled job, or one that just handed
    /// itself to `interrupted` — its UI must not be finalized here.
    static func run(destination: URL, importAll: Bool, hooks: Hooks) async -> Outcome? {
        guard hooks.isCurrent() else { return nil }
        // Duplicate checks and skipped-file reads need the same access as writes.
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }

        var imported = 0, failed = 0
        var files: [URL] = []
        var sticky: BatchImportPolicy.StickyPolicy? = importAll ? .skip : nil
        var position = 0
        var stopped = false

        photoLoop: while position < hooks.queue().count {
            guard hooks.isCurrent() else { return nil }
            let queue = hooks.queue()
            let index = queue[position]
            hooks.update(index, 0, .downloading, nil)

            var header = await hooks.readHeader(index)
            guard hooks.isCurrent() else { return nil }
            if (header?.count ?? 0) < 25 {
                let recovered = await hooks.recover()
                guard hooks.isCurrent() else { return nil }
                guard recovered else {
                    hooks.update(index, 0, .failedHeader, nil)
                    failed += 1
                    // Report reflects the batch exactly as it stood before
                    // teardown — `interrupted` tears down synchronously, so
                    // the `isCurrent` guard below always returns nil after.
                    await hooks.interrupted(InterruptionReport(importedPhotoCount: imported, savedFiles: files))
                    break
                }
                header = await hooks.readHeader(index)
                guard hooks.isCurrent() else { return nil }
            }
            guard let header, header.count >= 25 else {
                hooks.update(index, 0, .failedHeader, nil)
                failed += 1; position += 1
                continue
            }

            await hooks.ensureCameraName(index)
            guard hooks.isCurrent() else { return nil }
            // One snapshot for this photo, taken right before the duplicate
            // check — everything below (naming, the collision decision,
            // decode, export, the preview stamp) reads only this value, never
            // the live settings again, however many awaits separate them.
            let settings = hooks.settingsSnapshot()
            let originalName = hooks.preliminaryName(index, header, settings)
            var name = originalName
            var allowReplace = false
            func destinationURL(_ stem: String) -> URL {
                destination.appendingPathComponent(stem).appendingPathExtension(settings.fileExtension)
            }
            // Resolve a same-name collision against `candidateName`: prompt
            // (or apply the sticky answer) if a file is already there, then
            // report what the caller should do next. Shared by the QT100/150
            // check below (candidate = the preliminary name, which for that
            // family IS the final name) and the Fuji block further down
            // (candidate = the EXIF-derived final stem, known only after the
            // bytes are fetched) — one policy, one sticky state, decided
            // against whichever name will actually be written.
            enum CollisionDecision {
                case proceed(name: String, allowReplace: Bool)
                case skip(saved: [URL], expected: URL)
                case stop
            }
            func decideCollision(candidateName: String) async -> CollisionDecision? {
                let expected = destinationURL(candidateName)
                guard FileManager.default.fileExists(atPath: expected.path) else {
                    return .proceed(name: candidateName, allowReplace: false)
                }
                let policy: BatchImportPolicy.StickyPolicy
                if let sticky { policy = sticky }
                else {
                    let choice = await hooks.chooseDuplicate(expected.lastPathComponent)
                    guard hooks.isCurrent() else { return nil }
                    let resolution = BatchImportPolicy.resolveCollision(freshChoice: choice)
                    policy = resolution.policy
                    if let updated = resolution.updatedSticky { sticky = updated }
                }
                switch policy {
                case .stop:
                    return .stop
                case .skip:
                    var saved = [expected]
                    for url in hooks.importedURLs(index)
                    where url.pathExtension.lowercased() == "qtk" && !saved.contains(url) {
                        saved.append(url)
                    }
                    return .skip(saved: saved, expected: expected)
                case .replace:
                    return .proceed(name: candidateName, allowReplace: true)
                case .keepBoth:
                    let renamed = BatchImportPolicy.keepBothName(originalBaseName: candidateName) {
                        FileManager.default.fileExists(atPath: destinationURL($0).path)
                    }
                    return .proceed(name: renamed, allowReplace: false)
                }
            }
            // QT100/150: the preliminary name IS the final name, so the
            // collision decision happens now, before the (possibly slow)
            // download. Fuji/QT200's real name comes from the downloaded
            // JPEG's EXIF — deciding here would ask about, or silently
            // rename around, a name that was never going to be written.
            if !settings.isFuji {
                switch await decideCollision(candidateName: name) {
                case nil: return nil
                case .stop: stopped = true; break photoLoop
                case .skip(let saved, let expected):
                    hooks.update(index, 1, .skipped, saved)
                    guard hooks.isCurrent() else { return nil }
                    hooks.didSkip(index, saved, expected)
                    position += 1
                    continue photoLoop
                case .proceed(let resolvedName, let replace):
                    name = resolvedName
                    allowReplace = replace
                }
            }

            let sizeBytes = [header[5], header[6], header[7]]
            let size = Int(sizeBytes[0]) << 16 | Int(sizeBytes[1]) << 8 | Int(sizeBytes[2])
            let progress: (Double) -> Void = {
                guard hooks.isCurrent() else { return }
                hooks.update(index, $0 * 0.7, .downloading, nil)
            }
            var bytes = size > 0 ? await hooks.fetchImage(index, size, sizeBytes, progress) : nil
            guard hooks.isCurrent() else { return nil }
            if bytes == nil, size > 0 {
                let recovered = await hooks.recover()
                guard hooks.isCurrent() else { return nil }
                if recovered {
                    hooks.update(index, 0, .downloading, nil)
                    bytes = await hooks.fetchImage(index, size, sizeBytes, progress)
                    guard hooks.isCurrent() else { return nil }
                } else {
                    hooks.update(index, 0, .failedDownload, nil)
                    failed += 1
                    // Report reflects the batch exactly as it stood before
                    // teardown — `interrupted` tears down synchronously, so
                    // the `isCurrent` guard below always returns nil after.
                    await hooks.interrupted(InterruptionReport(importedPhotoCount: imported, savedFiles: files))
                    break
                }
            }
            hooks.logTransfer(index, size, bytes?.count ?? 0)
            guard size > 0, let bytes else {
                hooks.update(index, 0, .failedDownload, nil)
                failed += 1; position += 1
                continue
            }

            if settings.isFuji {
                // The real name, known only now — resolve the SAME duplicate
                // policy (prompt/sticky/skip/replace/keepBoth/stop) against
                // it, exactly as QT100/150 did above against its own final
                // name. A Fuji skip records the existing file the same way
                // the QTK skip path does, via the shared `decideCollision`.
                let stem = hooks.fujiName(index, bytes)
                switch await decideCollision(candidateName: stem) {
                case nil: return nil
                case .stop: stopped = true; break photoLoop
                case .skip(let saved, let expected):
                    hooks.update(index, 1, .skipped, saved)
                    guard hooks.isCurrent() else { return nil }
                    hooks.didSkip(index, saved, expected)
                    position += 1
                    continue photoLoop
                case .proceed(let resolvedName, let replace):
                    name = resolvedName
                    allowReplace = replace
                }
            }
            let archive = hooks.makeArchive(index, header, bytes)
            let archiveName = BatchImportPolicy.archiveBaseName(originalBaseName: originalName) {
                NamingMetadataPolicy.stripModeTag(from: $0)
            }
            let image = await hooks.decode(index, archive, bytes, settings)
            guard hooks.isCurrent() else { return nil }
            var saved: [URL] = []
            if settings.keepOriginal, !archive.isEmpty {
                do {
                    let url = try QTKArchiveStore.saveSafely(archive, candidateStem: archiveName, in: settings.archiveDirectory)
                    saved.append(url); files.append(url)
                } catch {
                    print("Keep-original QTK save failed for \(archiveName): \(error)")
                }
            }

            do {
                let exported = if let image { try await hooks.export(image, name, destination, header, settings, allowReplace) } else { nil as URL? }
                guard hooks.isCurrent() else { return nil }
                if let image, let exported {
                    saved.append(exported); files.append(exported)
                    imported += 1
                    hooks.didSave(SavedPhoto(index: index, position: position, importedCount: imported,
                                             image: image, header: header, imageSize: size,
                                             files: saved, exportedURL: exported, settings: settings))
                } else {
                    hooks.update(index, 0, .decodingFailed, nil)
                    failed += 1
                }
            } catch {
                guard hooks.isCurrent() else { return nil }
                hooks.update(index, 0, .saveError(detail: error.localizedDescription), nil)
                failed += 1
            }
            position += 1
        }

        guard hooks.isCurrent() else { return nil }
        return Outcome(summary: BatchImportPolicy.Summary(importedPhotoCount: imported, failedPhotoCount: failed,
                                                           savedFiles: files, stoppedByUser: stopped))
    }
}
