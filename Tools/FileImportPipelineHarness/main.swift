import AppKit
import Foundation

// FileImportPipeline harness.
//
// Exercises the state-independent drag-and-drop engine split out of
// `QuickTakeSerialManager` into `SwiftTake/FileImportPipeline.swift`,
// without launching the app, touching a camera, or reading any personal
// file. All fixtures are synthetic and live in a unique temporary
// directory that is removed afterward.
//
// Covers:
//   * decode-vs-save failure distinction (`Summary.decodeFailures` /
//     `.saveFailures`), including the export step returning nil (no write
//     attempted) being counted as decode-adjacent, consistent with the
//     `.decodingFailed` status used for it
//   * naming/export atomicity: the format used to resolve a "keep both"
//     name and the format actually written can never disagree, even
//     across a run where the live setting changes between items
//   * cancellation mid-run: the loop stops promptly and `run` returns
//     rather than draining every remaining item
//   * stable filename ordering through `sortedByFilename` and through the
//     processing loop itself
//   * corrupt input handling (decode returning nil)
//   * a large (>256-item) drop: every item's progress/result reports back
//     against the exact right id, confirming the existing UUID-keyed
//     identity (not the decorative `PhotoTransfer.index`) has no ceiling —
//     this is a regression check, not a fix; the baseline was already
//     correct here.
//
// Not covered here (needs the full manager / app target, out of this
// harness's reach): the `dropConversionActive` / `dropConversionWaiters`
// FIFO queue-release semantics and the destination-fallback preflight —
// neither was touched by this extraction, so they are unchanged from
// baseline by inspection.
//
// Concurrency note: `exportDecoded` and `onUpdate` are `@MainActor` in
// `FileImportPipeline.run`, and this harness's `main()` is `@MainActor`
// too, so closures for those two params capture and mutate plain local
// `var`s safely — both sides are the same actor, so there is nothing for
// the compiler to warn about. `decode` genuinely runs off-main (inside
// `Task.detached`), so the one test that needs to observe it
// (`OrderRecorder`) uses a lock-backed `@unchecked Sendable` collector,
// the same pattern `PanoramaPipelineHarness` uses for its off-main
// progress callback.

/// Thread-safe collector for `decode` calls, which genuinely run off the
/// main actor (inside `Task.detached`).
final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var order: [String] = []
    func record(_ name: String) { lock.lock(); order.append(name); lock.unlock() }
}

@MainActor
@main
struct FileImportPipelineChecks {

    static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1
            print("PASS: " + name)
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("swifttake-file-import-pipeline-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeDestination(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// A trivial, always-valid placeholder image. The pipeline never
        /// inspects pixels — `exportDecoded` is a caller-supplied closure in
        /// every check here, exactly as the manager supplies
        /// `resolveAndExportDroppedFile` in production — so an empty
        /// `NSImage` is sufficient.
        let placeholderImage = NSImage(size: NSSize(width: 1, height: 1))

        /// One recorded `onUpdate` call, for asserting per-item outcomes.
        struct UpdateRecord { let id: UUID; let progress: Double; let status: PhotoTransfer.Status }

        /// Standard "keep both" naming + write, matching
        /// `resolveAndExportDroppedFile` exactly, parameterized by a fixed
        /// extension. `@MainActor` to match `exportDecoded`'s parameter type.
        @MainActor
        func standardExport(to destination: URL, extension ext: String) -> (@MainActor @Sendable (String, NSImage, Date?, [UInt8]?) async throws -> URL?) {
            { decodedBaseName, _, _, _ in
                var baseName = decodedBaseName
                var n = 2
                while fm.fileExists(atPath: destination.appendingPathComponent(baseName).appendingPathExtension(ext).path) {
                    baseName = "\(decodedBaseName) \(n)"
                    n += 1
                }
                let dest = destination.appendingPathComponent(baseName).appendingPathExtension(ext)
                try Data().write(to: dest)
                return dest
            }
        }

        // MARK: - Ordering

        do {
            let destination = try makeDestination("ordering")
            let names = ["c.qtk", "a.qtk", "e.qtk", "b.qtk", "d.qtk"]
            let map = Dictionary(uniqueKeysWithValues: names.map { name in
                (scratch.appendingPathComponent(name), name.data(using: .utf8)!)
            })
            let sorted = FileImportPipeline.sortedByFilename(map)
            check(sorted.map { $0.url.lastPathComponent } == ["a.qtk", "b.qtk", "c.qtk", "d.qtk", "e.qtk"],
                  "sortedByFilename orders alphabetically regardless of dictionary order")

            let recorder = OrderRecorder()
            let items = sorted.map { FileImportPipeline.Item(id: UUID(), url: $0.url, data: $0.data) }
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, data in
                    recorder.record(url.lastPathComponent)
                    return FileImportPipeline.DropConversion(
                        image: placeholderImage, captureDate: nil,
                        baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: standardExport(to: destination, extension: "tiff"),
                onUpdate: { _, _, _, _ in }
            )
            check(recorder.order == ["a.qtk", "b.qtk", "c.qtk", "d.qtk", "e.qtk"],
                  "run() decodes items in the exact order given (shot order, not completion order)")
            check(summary.succeeded == 5 && summary.failed == 0,
                  "ordering check: all five items imported cleanly")
        }

        // MARK: - Decode failure (corrupt input)

        do {
            let destination = try makeDestination("decode-failure")
            let items = [FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("corrupt.qtk"),
                                                  data: Data([0xDE, 0xAD, 0xBE, 0xEF]))]
            var records: [UpdateRecord] = []
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { _, _ in nil },   // simulates a QTKDecoder that couldn't parse the bytes
                exportDecoded: standardExport(to: destination, extension: "tiff"),
                onUpdate: { id, progress, status, _ in records.append(UpdateRecord(id: id, progress: progress, status: status)) }
            )
            check(summary.decodeFailures == 1 && summary.saveFailures == 0 && summary.succeeded == 0,
                  "a decode() nil is counted as a decode failure, not a save failure")
            check(records.last?.status == .decodingFailed, "corrupt input ends on .decodingFailed")
        }

        // MARK: - Save failure (export throws — disk full / permissions / unwritable folder)

        do {
            let destination = try makeDestination("save-failure")
            struct FakeSaveError: LocalizedError { var errorDescription: String? { "The disk is full." } }
            let items = [FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("good.qtk"), data: Data())]
            var records: [UpdateRecord] = []
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                       baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: { _, _, _, _ in throw FakeSaveError() },
                onUpdate: { id, progress, status, _ in records.append(UpdateRecord(id: id, progress: progress, status: status)) }
            )
            check(summary.saveFailures == 1 && summary.decodeFailures == 0 && summary.succeeded == 0,
                  "an export throw is counted as a save failure, not a decode failure")
            if case .saveError(let detail) = records.last?.status {
                check(detail == "The disk is full.", "the save error's detail reaches the terminal status")
            } else {
                check(false, "terminal status for a save-error item must be .saveError")
            }
            _ = destination
        }

        // MARK: - Export returning nil (no write attempted — decode-adjacent, not save-adjacent)

        do {
            let destination = try makeDestination("export-nil")
            let items = [FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("good.qtk"), data: Data())]
            var records: [UpdateRecord] = []
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                       baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                // Mirrors exportImage's first guard: no CGImage, no write
                // attempted, returns nil rather than throwing.
                exportDecoded: { _, _, _, _ in nil },
                onUpdate: { id, progress, status, _ in records.append(UpdateRecord(id: id, progress: progress, status: status)) }
            )
            check(summary.decodeFailures == 1 && summary.saveFailures == 0,
                  "export returning nil (no write attempted) is counted as decode-adjacent, not a save failure")
            check(records.last?.status == .decodingFailed,
                  "export returning nil keeps the .decodingFailed status, consistent with its failure kind")
            _ = destination
        }

        // MARK: - Mixed batch: decode failure, save failure, and success together

        do {
            let destination = try makeDestination("mixed")
            struct FakeSaveError: Error {}
            let items = [
                FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("ok.qtk"), data: Data([1])),
                FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("corrupt.qtk"), data: Data([2])),
                FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("unwritable.qtk"), data: Data([3])),
            ]
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    url.lastPathComponent == "corrupt.qtk" ? nil :
                        FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                           baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: { baseName, image, captureDate, header in
                    if baseName == "unwritable" { throw FakeSaveError() }
                    return try await standardExport(to: destination, extension: "tiff")(baseName, image, captureDate, header)
                },
                onUpdate: { _, _, _, _ in }
            )
            check(summary.succeeded == 1 && summary.decodeFailures == 1 && summary.saveFailures == 1,
                  "a mixed batch attributes each item's failure to the correct kind independently")
        }

        // MARK: - Keep-both naming collision (unchanged behavior, verified through the extraction)

        do {
            let destination = try makeDestination("keep-both")
            // Pre-seed "shot.tiff" so the first item must resolve to "shot 2".
            try Data().write(to: destination.appendingPathComponent("shot.tiff"))
            let items = [FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("shot.qtk"), data: Data())]
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                       baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: standardExport(to: destination, extension: "tiff"),
                onUpdate: { _, _, _, _ in }
            )
            check(summary.importedFiles.first?.lastPathComponent == "shot 2.tiff",
                  "a name collision resolves silently to 'name 2' rather than overwriting or failing")
        }

        // MARK: - Naming/export atomicity across a settings change mid-run
        //
        // Simulates the user flipping the export format in Settings between
        // items (never claiming to do so *within* one item's processing,
        // which the single merged `exportDecoded` call makes impossible by
        // construction — see FileImportPipeline.run's doc comment). Proves
        // each item's OWN naming decision and OWN write always share the
        // one format value that closure read for that item, regardless of
        // what the "live setting" was before or is after.

        do {
            let destination = try makeDestination("settings-mid-run")
            var liveExtension = "tiff"
            let items = ["shot0", "shot1", "shot2"].map {
                FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("\($0).qtk"), data: Data())
            }
            var extensionUsedFor: [String: String] = [:]
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                       baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: { decodedBaseName, _, _, _ in
                    // ONE read, used for both the collision check and the
                    // write — the exact invariant the fix guarantees.
                    let ext = liveExtension
                    var baseName = decodedBaseName
                    var n = 2
                    while fm.fileExists(atPath: destination.appendingPathComponent(baseName).appendingPathExtension(ext).path) {
                        baseName = "\(decodedBaseName) \(n)"
                        n += 1
                    }
                    let dest = destination.appendingPathComponent(baseName).appendingPathExtension(ext)
                    try Data().write(to: dest)
                    extensionUsedFor[decodedBaseName] = ext
                    return dest
                },
                onUpdate: { _, _, status, _ in
                    // Flip the "live setting" once an item finishes — between
                    // items, never inside one.
                    if status == .imported { liveExtension = (liveExtension == "tiff") ? "png" : "tiff" }
                }
            )
            check(summary.succeeded == 3, "settings-mid-run: all three items still import despite the format flipping between them")
            check(extensionUsedFor["shot0"] == "tiff" && extensionUsedFor["shot1"] == "png" && extensionUsedFor["shot2"] == "tiff",
                  "each item's single export call used one consistent format for its own naming AND its own write, even as the live format changed between items")
            for saved in summary.importedFiles {
                check(fm.fileExists(atPath: saved.path), "the file actually on disk matches the name decided in the same call: \(saved.lastPathComponent)")
            }
        }

        // MARK: - Cancellation mid-run

        do {
            let destination = try makeDestination("cancel")
            let items = (0..<8).map { i in
                FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("f\(i).qtk"), data: Data())
            }
            let runTask = Task {
                await FileImportPipeline.run(
                    items: items,
                    decode: { url, _ in
                        // Simulate real decode cost so cancellation has a
                        // window to land mid-batch rather than the whole
                        // run finishing before the cancel arrives.
                        Thread.sleep(forTimeInterval: 0.05)
                        return FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                                  baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                    },
                    exportDecoded: standardExport(to: destination, extension: "tiff"),
                    onUpdate: { _, _, _, _ in }
                )
            }
            try await Task.sleep(nanoseconds: 140_000_000)   // ~2-3 items in, out of 8
            runTask.cancel()
            let summary = await runTask.value
            let processed = summary.succeeded + summary.decodeFailures + summary.saveFailures
            check(processed < items.count,
                  "cancelling mid-run stops the loop early (\(processed) of \(items.count) processed) rather than draining every item")
        }

        // MARK: - Large drop (>256 items): identity regression check
        //
        // Per-item identity for a drop is the caller-assigned `id` (a real
        // `PhotoTransfer.id` UUID in production), not the decorative
        // `PhotoTransfer.index` byte the manager also sets. That UUID
        // keying has no 256-item ceiling; this confirms the extraction
        // preserved that — it is a regression check, not a fix, since the
        // baseline was already correct here.

        do {
            let destination = try makeDestination("large-drop")
            let count = 300
            let items = (0..<count).map { i in
                FileImportPipeline.Item(id: UUID(),
                                         url: scratch.appendingPathComponent(String(format: "img%04d.qtk", i)),
                                         data: Data())
            }
            var finalStatusByID: [UUID: PhotoTransfer.Status] = [:]
            var savedByID: [UUID: URL] = [:]
            let summary = await FileImportPipeline.run(
                items: items,
                decode: { url, _ in
                    FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                       baseName: url.deletingPathExtension().lastPathComponent, header: nil)
                },
                exportDecoded: standardExport(to: destination, extension: "tiff"),
                onUpdate: { id, _, status, saved in
                    finalStatusByID[id] = status
                    if let saved = saved?.first { savedByID[id] = saved }
                }
            )
            check(summary.succeeded == count, "a \(count)-item drop (above the old UInt8 ceiling) imports every item")
            check(Set(items.map(\.id)).count == count, "every item's id is distinct — no identity collisions at any size")
            let allMatch = items.allSatisfy { item in
                finalStatusByID[item.id] == .imported &&
                    savedByID[item.id]?.deletingPathExtension().lastPathComponent == item.url.deletingPathExtension().lastPathComponent
            }
            check(allMatch, "every one of the \(count) items reports its result back against its own id, not a neighbor's")
        }

        // Cancellation delivered by a progress callback must prevent the next stage.
        for stopAt in [0.05, 0.95] {
            let recorder = OrderRecorder()
            var exports = 0
            let item = FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("cancel.qtk"), data: Data())
            let task = Task {
                await FileImportPipeline.run(
                    items: [item],
                    decode: { url, _ in
                        recorder.record(url.lastPathComponent)
                        return FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                                  baseName: "cancel", header: nil)
                    },
                    exportDecoded: { _, _, _, _ in exports += 1; return nil },
                    onUpdate: { _, progress, _, _ in
                        if progress == stopAt { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                )
            }
            let result = await task.value
            check(result.cancelled && result.failed == 0, "cancellation at \(stopAt) is a stop, not a file failure")
            check(exports == 0, "cancellation at \(stopAt) prevents export")
            check(recorder.order.count == (stopAt == 0.05 ? 0 : 1), "cancellation at \(stopAt) prevents the next decode stage")
        }

        do {
            let item = FileImportPipeline.Item(id: UUID(), url: scratch.appendingPathComponent("cancel-export.qtk"), data: Data())
            let result = await FileImportPipeline.run(
                items: [item],
                decode: { _, _ in FileImportPipeline.DropConversion(image: placeholderImage, captureDate: nil,
                                                                     baseName: "cancel-export", header: nil) },
                exportDecoded: { _, _, _, _ in throw CancellationError() },
                onUpdate: { _, _, _, _ in }
            )
            check(result.cancelled && result.failed == 0 && result.succeeded == 0,
                  "export cancellation stops without reporting a save or decode error")
        }

        print("\n\(passed) checks passed.")
    }
}
