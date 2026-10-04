// PanoramaPipeline harness.
//
// Exercises the state-independent panorama work extracted from
// `QuickTakeSerialManager` into `SwiftTake/PanoramaPipeline.swift`, without
// launching the app or touching a camera:
//
//   * file read, decode and slot ordering (`decodeFinderFrames`)
//   * rejection of unreadable entries so the caller can spot a short set
//   * cancellation of the file decode
//   * match/blend under a forwarded cancel (`stitch`), including the
//     progress callbacks and a prompt unwind when pre-cancelled
//   * `sweepEstimate` and the staged `export`
//
// Fixtures are deterministic: solid-colour PNGs generated here, plus the
// committed `SwiftTake/DemoPanSource.jpg` crops the existing panorama
// harnesses already use. No personal photos, no network.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Fixtures

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func writeSolidPNG(_ rgb: (Double, Double, Double), to url: URL, side: Int = 48) {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

/// Dominant channel of a decoded frame, so red/green/blue fixtures can be
/// told apart after a round trip.
func dominantChannel(_ image: CGImage) -> Int {
    var px = [UInt8](repeating: 0, count: 4)
    // Context creation AND drawing both stay inside the pointer scope — a
    // CGContext must not outlive the array buffer it was handed.
    px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2,
                                   width: image.width, height: image.height))
    }
    let channels = [Int(px[0]), Int(px[1]), Int(px[2])]
    return channels.firstIndex(of: channels.max()!)!
}

/// Deterministic LCG so synthetic archives are identical on every run —
/// same generator as `Tools/DecoderHarness/main.swift`'s fuzz fixtures.
func lcgBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var s = seed
    return (0..<count).map { _ in
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: s >> 33)
    }
}

/// A minimal but structurally valid `.qtk` archive `QTKDecoder` will decode
/// to a real image — just enough header plus LCG-filled Bayer payload, no
/// personal photos.
func syntheticQTK(qt100: Bool, width: Int, height: Int, seed: UInt64) -> Data {
    var b = [UInt8](repeating: 0, count: 736)
    for (i, ch) in (qt100 ? "qktk" : "qktn").utf8.enumerated() { b[i] = ch }
    b[544] = UInt8(height >> 8); b[545] = UInt8(height & 0xFF)
    b[546] = UInt8(width >> 8);  b[547] = UInt8(width & 0xFF)
    b += lcgBytes(120_000, seed: seed)
    return Data(b)
}

func demoCrops(_ count: Int, step: Int = 240, width: Int = 640) -> [CGImage] {
    let src = CGImageSourceCreateWithURL(
        repoRoot.appendingPathComponent("SwiftTake/DemoPanSource.jpg") as CFURL, nil)!
    let scene = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    return (0..<count).map {
        scene.cropping(to: CGRect(x: $0 * step, y: 0, width: width, height: 480))!
    }
}

/// Thread-safe collector for the `stitch` progress callbacks, which arrive
/// off the calling task.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var aligning: [(Int, Int)] = []
    private(set) var blendCount = 0
    func recordAligning(_ done: Int, _ total: Int) { lock.lock(); aligning.append((done, total)); lock.unlock() }
    func recordBlending() { lock.lock(); blendCount += 1; lock.unlock() }
}

/// MainActor-isolated tick collector for the `decodeFinderFrames` progress
/// callback, so the `@Sendable` closure captures an immutable reference
/// rather than a mutable local.
@MainActor final class TickCollector {
    private(set) var ticks: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { ticks.append((done, total)) }
}

/// Holds the `stitch` task so `onBlending` can cancel it from inside the
/// callback — the task handle does not exist yet when the closure is
/// written, only by the time the detached work actually calls back.
final class StitchTaskBox: @unchecked Sendable {
    var task: Task<PanoramaPipeline.StitchOutput, Error>?
}

// MARK: - Runner

@main
struct PanoramaPipelineChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ passed: Bool, _ description: String) {
            checks += 1
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(description)")
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("PanoramaPipelineHarness-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // Colour fixtures. RED, GREEN, BLUE dominant respectively.
        let red = scratch.appendingPathComponent("red.png")
        let green = scratch.appendingPathComponent("green.png")
        let blue = scratch.appendingPathComponent("blue.png")
        writeSolidPNG((0.9, 0.05, 0.05), to: red)
        writeSolidPNG((0.05, 0.9, 0.05), to: green)
        writeSolidPNG((0.05, 0.05, 0.9), to: blue)

        // --- File read + slot ordering -------------------------------------

        let forward = await PanoramaPipeline.decodeFinderFrames(urls: [red, green, blue]) { _, _ in }
        check(forward.frames.count == 3, "every readable file is decoded")
        check(forward.frames.count == 3 && forward.frames.map(dominantChannel) == [0, 1, 2],
              "frames keep the given order, not the task group's completion order")
        check(forward.qtkSlots.isEmpty, "plain PNGs are never classified as QTK")

        let reversed = await PanoramaPipeline.decodeFinderFrames(urls: [blue, green, red]) { _, _ in }
        check(reversed.frames.map(dominantChannel) == [2, 1, 0], "reordered input yields reordered frames")

        let missingRed = scratch.appendingPathComponent("removed/red.png")
        let missingBlue = scratch.appendingPathComponent("removed/blue.png")
        let captured = [missingRed: try Data(contentsOf: red), missingBlue: try Data(contentsOf: blue)]
        let capturedFrames = await PanoramaPipeline.decodeFinderFrames(
            urls: [missingBlue, missingRed], capturedData: captured) { _, _ in }
        check(capturedFrames.frames.map(dominantChannel) == [2, 0],
              "dropped snapshots decode in requested order without access to original files")
        let missingSnapshot = await PanoramaPipeline.decodeFinderFrames(
            urls: [red], capturedData: [:]) { _, _ in }
        check(missingSnapshot.frames.isEmpty, "missing snapshot never falls back to a different on-disk file")
        let corruptSnapshot = await PanoramaPipeline.decodeFinderFrames(
            urls: [red], capturedData: [red: Data([0, 1, 2])]) { _, _ in }
        check(corruptSnapshot.frames.isEmpty, "corrupt snapshot never falls back to a valid on-disk file")
        let cancelledSnapshotTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PanoramaPipeline.decodeFinderFrames(urls: [missingRed], capturedData: captured) { _, _ in }
        }
        check(await cancelledSnapshotTask.value.frames.isEmpty, "cancelled drop snapshot contributes no frames")

        let oversized = scratch.appendingPathComponent("oversized.png")
        writeSolidPNG((0.9, 0.1, 0.1), to: oversized, side: PanoramaStitcher.maxFrameDimension + 1)
        let rejectedSize = await PanoramaPipeline.decodeFinderFrames(urls: [oversized]) { _, _ in }
        check(rejectedSize.frames.isEmpty, "oversized Finder image is rejected before rasterization")
        let rejectedCount = await PanoramaPipeline.decodeFinderFrames(
            urls: Array(repeating: red, count: PanoramaStitcher.maxFrameCount + 1)) { _, _ in }
        check(rejectedCount.frames.isEmpty, "oversized Finder batch is rejected before decoding")

        let ticks = TickCollector()
        _ = await PanoramaPipeline.decodeFinderFrames(urls: [red, green, blue]) { done, total in
            await ticks.add(done, total)
        }
        check(ticks.ticks.count == 3 && ticks.ticks.allSatisfy { $0.1 == 3 }
              && ticks.ticks.map(\.0).sorted() == [1, 2, 3],
              "progress reports each file against the full count")

        // --- Error handling ---------------------------------------------------

        let missing = scratch.appendingPathComponent("gone.png")
        let junkQTK = scratch.appendingPathComponent("junk.qtk")
        let notAnImage = scratch.appendingPathComponent("fake.png")
        // Deterministic non-QTK, non-image bytes (0,1,2,… — not the "qkt"
        // signature, not a JPEG SOI), so the decode reliably rejects it.
        try Data((0..<512).map { UInt8($0 & 0xFF) }).write(to: junkQTK)
        try Data("this is not an image".utf8).write(to: notAnImage)

        let salvaged = await PanoramaPipeline.decodeFinderFrames(
            urls: [red, missing, junkQTK, notAnImage, blue]) { _, _ in }
        check(salvaged.frames.count == 2, "unreadable, corrupt and non-image entries are dropped")
        check(salvaged.frames.count == 2 && salvaged.frames.map(dominantChannel) == [0, 2],
              "the entries that survive keep their order, so a short set is detectable")

        // --- Cancellation of the file decode --------------------------------

        let decodeTask = Task {
            await PanoramaPipeline.decodeFinderFrames(urls: [red, green, blue]) { _, _ in }
        }
        decodeTask.cancel()
        let cancelledDecode = await decodeTask.value
        check(cancelledDecode.frames.isEmpty, "a cancelled file decode contributes no frames")

        // --- QTK vs. already-finished classification, and the resulting
        // Look treatment (the imported-file colour-double-processing fix) --

        let qtkA = scratch.appendingPathComponent("a.qtk")
        let qtkB = scratch.appendingPathComponent("b.qtk")
        try syntheticQTK(qt100: false, width: 640, height: 480, seed: 1).write(to: qtkA)
        try syntheticQTK(qt100: false, width: 640, height: 480, seed: 2).write(to: qtkB)

        let allQTK = await PanoramaPipeline.decodeFinderFrames(urls: [qtkA, qtkB]) { _, _ in }
        check(allQTK.frames.count == 2 && allQTK.qtkSlots == [0, 1],
              "an all-archive set classifies every slot as QTK")

        let allFinished = await PanoramaPipeline.decodeFinderFrames(urls: [red, green]) { _, _ in }
        check(allFinished.qtkSlots.isEmpty, "an all-finished set classifies no slot as QTK")

        let mixed = await PanoramaPipeline.decodeFinderFrames(urls: [qtkA, red, qtkB]) { _, _ in }
        check(mixed.frames.count == 3 && mixed.qtkSlots == [0, 2],
              "a mixed set classifies only the archive slots as QTK, by position in the returned frames")

        let enhancedLook = FinishedLookSettings(enhanced: true, hdr: false, headroom: 1.5)
        let neutralLook = FinishedLookSettings(enhanced: false, hdr: false, headroom: 1.5)

        func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
            a.width == b.width && a.height == b.height
                && (a.dataProvider?.data as Data?) == (b.dataProvider?.data as Data?)
        }

        let untouchedMixed = try await PanoramaPipeline.applyingLook(enhancedLook, toQTKSlots: mixed.qtkSlots, in: mixed.frames)
        check(pixelsEqual(untouchedMixed[1], mixed.frames[1]),
              "applyingLook never touches a slot outside qtkSlots")
        check(!pixelsEqual(untouchedMixed[0], mixed.frames[0]) && !pixelsEqual(untouchedMixed[2], mixed.frames[2]),
              "applyingLook changes every QTK slot when the look is non-neutral")
        let referenceA = FinishedImageLook.render(mixed.frames[0], enhanced: true, hdr: false, headroom: 1.5)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        check(referenceA.map { pixelsEqual($0, untouchedMixed[0]) } == true,
              "the baked QTK slot matches FinishedImageLook.render directly")

        let neutralMixed = try await PanoramaPipeline.applyingLook(neutralLook, toQTKSlots: mixed.qtkSlots, in: mixed.frames)
        check(zip(neutralMixed, mixed.frames).allSatisfy(pixelsEqual),
              "a neutral look is a true no-op, even over QTK slots")

        let noQTKSlots = try await PanoramaPipeline.applyingLook(enhancedLook, toQTKSlots: [], in: mixed.frames)
        check(zip(noQTKSlots, mixed.frames).allSatisfy(pixelsEqual),
              "an empty qtkSlots set leaves every frame untouched regardless of the look")

        // A pre-cancelled mixed-look bake must surface CancellationError
        // rather than grinding through every QTK slot on the UI actor.
        let lookCancelTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PanoramaPipeline.applyingLook(enhancedLook, toQTKSlots: mixed.qtkSlots, in: mixed.frames)
        }
        var lookCancelled = false
        do { _ = try await lookCancelTask.value } catch is CancellationError { lookCancelled = true } catch {}
        check(lookCancelled, "a cancelled mixed-look bake surfaces CancellationError rather than a result")

        // --- Match / blend, happy path + progress --------------------------

        let frames = demoCrops(4)
        let pairs = PanoramaStitcher.pairMatchCount(frames: frames.count)
        let sink = ProgressSink()
        let output = try await PanoramaPipeline.stitch(
            frames: frames, fixedOrder: nil,
            onAligning: { done, total in sink.recordAligning(done, total) },
            onBlending: { sink.recordBlending() })
        check(output.strip != nil, "a confident set stitches to a strip")
        check(sink.aligning.map(\.0) == Array(1...pairs) && sink.aligning.allSatisfy { $0.1 == pairs },
              "aligning progress is monotonic and ends at the pair count")
        check(sink.blendCount == 1, "the blend callback fires exactly once")

        let sweep = PanoramaPipeline.sweepEstimate(for: output.session)
        check(sweep > 0 && sweep <= 359, "open-arc sweep estimate stays below a full circle")

        // --- Staged export --------------------------------------------------

        let exportDir = scratch.appendingPathComponent("out")
        let written = try await PanoramaPipeline.export(
            strip: output.strip!, session: output.session, destination: exportDir)
        check(written.count == 3 && written.allSatisfy { fm.fileExists(atPath: $0.path) },
              "export stages all three formats to disk")

        // Force the second publication to collide after the PNG was moved.
        // Exercise the real rollback, then retry without changing the source.
        let collisionDir = scratch.appendingPathComponent("publication-collision")
        let sentinel = Data("existing file must survive".utf8)
        var publicationFailed = false
        do {
            _ = try await PanoramaPipeline.export(
                strip: output.strip!, session: output.session, destination: collisionDir,
                onStaged: {
                    let staging = try! FileManager.default.contentsOfDirectory(
                        at: collisionDir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".panorama-") }!
                    let html = try! FileManager.default.contentsOfDirectory(
                        at: staging, includingPropertiesForKeys: nil).first { $0.pathExtension == "html" }!
                    try! sentinel.write(to: collisionDir.appendingPathComponent(html.lastPathComponent))
                })
        } catch { publicationFailed = true }
        check(publicationFailed, "publication collision reports a save failure")
        let survivors = try fm.contentsOfDirectory(at: collisionDir, includingPropertiesForKeys: nil)
        check(survivors.count == 1 && survivors[0].pathExtension == "html",
              "failed second publication rolls back PNG and removes staging")
        check(try survivors.count == 1 && Data(contentsOf: survivors[0]) == sentinel,
              "publication failure preserves the pre-existing collision file")
        let retry = try await PanoramaPipeline.export(
            strip: output.strip!, session: output.session, destination: collisionDir)
        check(retry.count == 3 && retry.allSatisfy { fm.fileExists(atPath: $0.path) },
              "retry after publication failure saves all formats")
        check(try fm.contentsOfDirectory(atPath: collisionDir.path).count == 4,
              "retry retains the existing file and leaves no staging directory")

        for beforeStart in [true, false] {
            let dir = scratch.appendingPathComponent(beforeStart ? "cancel-before-export" : "cancel-after-staging")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let sentinel = dir.appendingPathComponent("existing.txt")
            let bytes = Data("keep existing files".utf8)
            try bytes.write(to: sentinel)
            let task = Task {
                if beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
                return try await PanoramaPipeline.export(
                    strip: output.strip!, session: output.session, destination: dir,
                    onStaged: { if !beforeStart { withUnsafeCurrentTask { $0?.cancel() } } })
            }
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            check(cancelled, "export cancellation is reported (before start: \(beforeStart))")
            check(try fm.contentsOfDirectory(atPath: dir.path) == ["existing.txt"],
                  "cancelled export publishes nothing and removes staged formats")
            check(try Data(contentsOf: sentinel) == bytes, "cancelled export preserves existing files")
        }

        // --- Cancellation of the match ------------------------------------

        let started = ContinuousClock.now
        let stitchTask = Task {
            try await PanoramaPipeline.stitch(frames: demoCrops(4), fixedOrder: nil,
                                              onAligning: { _, _ in }, onBlending: {})
        }
        stitchTask.cancel()
        var cancelled = false
        do { _ = try await stitchTask.value } catch is CancellationError { cancelled = true } catch {}
        let elapsed = ContinuousClock.now - started
        check(cancelled, "a pre-cancelled stitch surfaces CancellationError rather than a result")
        check(elapsed < .seconds(5), "a cancelled stitch unwinds without grinding through every pair")

        // --- Cancellation DURING the blend ----------------------------------
        //
        // The blend is one pass, not interruptible mid-loop the way match
        // is — but `render` still checks `Task.isCancelled` partway through
        // and returns nil rather than a picture. That nil must surface as
        // `CancellationError`, the same as every other cancel point, and
        // never as a "successful" empty strip — see PanoramaPipeline.stitch.
        let blendBox = StitchTaskBox()
        blendBox.task = Task {
            try await PanoramaPipeline.stitch(
                frames: demoCrops(4), fixedOrder: nil,
                onAligning: { _, _ in },
                onBlending: { blendBox.task?.cancel() })
        }
        var cancelledDuringBlend = false
        var blendGaveNilStripAsSuccess = false
        do {
            let out = try await blendBox.task!.value
            blendGaveNilStripAsSuccess = out.strip == nil
        } catch is CancellationError {
            cancelledDuringBlend = true
        } catch {}
        check(cancelledDuringBlend, "cancelling from inside onBlending surfaces CancellationError")
        check(!blendGaveNilStripAsSuccess,
              "a cancel during the blend never comes back as a nil strip 'success'")

        // Cancel after both ordinary orderings fail, just as projection fallback
        // would start. It must not continue into the extra searches or blending.
        let projectionBox = StitchTaskBox()
        let projectionFrames = demoCrops(4)
        projectionBox.task = Task {
            try await PanoramaPipeline.stitch(
                frames: [projectionFrames[0], projectionFrames[2], projectionFrames[1], projectionFrames[3]],
                fixedOrder: nil,
                onAligning: { done, total in
                    if done == total - 1 { projectionBox.task?.cancel() }
                }, onBlending: {})
        }
        var cancelledBeforeProjection = false
        do { _ = try await projectionBox.task!.value }
        catch is CancellationError { cancelledBeforeProjection = true }
        catch {}
        check(cancelledBeforeProjection, "cancelling before projection fallback surfaces CancellationError")

        // --- DestinationScope: the adapter behind the panorama/source
        // security-scoped disk reads (QuickTakeSerialManager's
        // loadOrFetchQTK/loadOrFetchFinishedFrame, PanoramaBandTile.load).
        // Real sandbox behaviour cannot run in a harness, so this checks the
        // adapter contract against a recording fake: every read runs while
        // scope is held, and begin/end stay balanced — including the
        // "begin() returned false" case, where `URL`'s own contract forbids
        // calling `end()` at all.
        final class RecordingDestinationScope: DestinationScope, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var beginCount = 0, endCount = 0
            private(set) var readRanWhileActive = false
            private var active = false
            private let grant: Bool
            init(grant: Bool) { self.grant = grant }
            func begin() -> Bool {
                lock.lock(); defer { lock.unlock() }
                beginCount += 1; active = grant; return grant
            }
            func end() {
                lock.lock(); defer { lock.unlock() }
                endCount += 1; active = false
            }
            func markRead() {
                lock.lock(); defer { lock.unlock() }
                if active { readRanWhileActive = true }
            }
        }
        do {
            let s1 = RecordingDestinationScope(grant: true)
            let r1 = withDestinationScope(s1) { () -> Int? in s1.markRead(); return 42 }
            check(r1 == 42, "withDestinationScope returns the read's value")
            check(s1.readRanWhileActive, "the read ran while scope was held")
            check(s1.beginCount == 1 && s1.endCount == 1, "begin/end balanced on a successful read")

            let s2 = RecordingDestinationScope(grant: true)
            let r2 = withDestinationScope(s2) { () -> Int? in s2.markRead(); return nil }
            check(r2 == nil, "a read that finds nothing still returns nil")
            check(s2.beginCount == 1 && s2.endCount == 1, "begin/end balanced when the read finds nothing")

            // begin() == false (an unscoped/non-bookmarked URL, or access
            // actually denied) must skip end() — calling it anyway would
            // over-release the real URL's access count.
            let s3 = RecordingDestinationScope(grant: false)
            _ = withDestinationScope(s3) { () -> Int? in s3.markRead(); return 1 }
            check(s3.beginCount == 1, "begin() is still called when scope grants nothing")
            check(s3.endCount == 0, "end() is skipped when begin() returned false")
            check(!s3.readRanWhileActive, "the read is not considered scoped when begin() returned false")

            let s4 = RecordingDestinationScope(grant: true)
            for _ in 0..<5 { _ = withDestinationScope(s4) { 1 } }
            check(s4.beginCount == 5 && s4.endCount == 5, "repeated reads keep begin/end paired 1:1")
        }

        print("\(checks - failures)/\(checks) panorama pipeline checks passed")
        if failures != 0 { exit(1) }
    }
}
