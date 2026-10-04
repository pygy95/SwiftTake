// State-independent panorama work, split out of `QuickTakeSerialManager`:
// reading and decoding source frames, running the match/blend under a
// forwarded cancel, estimating an open-arc sweep, and staging the export.
//
// The manager keeps every `@Published` value, the task-generation counter,
// slot invalidation and the camera-frame fetch; its panorama methods
// snapshot that state and call in here. Nothing in this file touches the
// UI actor or manager state.

import AppKit
import CoreGraphics
import ImageIO

/// `nonisolated` for the same reason as `PanoramaStitcher` / `PhotoExporter`:
/// the heavy work runs on detached tasks and must not inherit `@MainActor`.
nonisolated enum PanoramaPipeline {

    /// Carries a finished match out of the detached stitch task under
    /// strict concurrency checking. The session and strip are built inside
    /// that task and only read afterwards.
    struct StitchOutput: @unchecked Sendable {
        let session: PanoramaStitcher.Session
        let strip: CGImage?
    }

    /// Lets a decoded `NSImage?` cross out of a decode task group. The
    /// image is created inside the task and read-only afterwards.
    ///
    /// `isQTK` distinguishes a raw Bayer archive (decoded neutrally here,
    /// still wanting the current Look applied once after blending) from a
    /// file ImageIO read as-is — a previous export or a camera JPEG already
    /// carries whatever rendering it was given, and must not receive a
    /// second pass. See `applyingLook(_:toQTKSlots:in:)`.
    private struct DecodedImage: @unchecked Sendable {
        let image: NSImage?
        /// Unused by `decodeArchives` (always `false` there) — every
        /// camera-gallery source already gets the same post-blend treatment
        /// regardless of family, so that call site never reads this field.
        let isQTK: Bool
    }

    // MARK: - File input

    /// Read and decode Finder-chosen files into frames, in the given order.
    ///
    /// A `.qtk` archive is raw Bayer and goes through the decoder; every
    /// other type is handed to ImageIO as it is, so a panorama can start
    /// from earlier exports as well as raw. Unreadable entries are dropped:
    /// the caller compares the returned count against the request and
    /// rejects an incomplete set rather than stitching the wrong frames.
    ///
    /// `progress` reports `(decoded, total)` as each file finishes and is
    /// awaited at that point, so the caller can gate it on a generation
    /// check. A cancelled task contributes no frame. `qtkSlots` indexes the
    /// returned `frames` array (post-sort, not the input URLs) and tells the
    /// caller which sources are raw archives versus already-finished images,
    /// so it can decide where the current Look may run.
    static func decodeFinderFrames(
        urls: [URL],
        capturedData: [URL: Data]? = nil,
        progress: @Sendable (Int, Int) async -> Void
    ) async -> (frames: [CGImage], qtkSlots: Set<Int>) {
        let total = urls.count
        guard total <= PanoramaStitcher.maxFrameCount else { return ([], []) }
        let decoded: [(slot: Int, image: CGImage, isQTK: Bool)] = await withTaskGroup(
            of: (Int, DecodedImage).self
        ) { group in
            var next = min(2, total)
            for slot in 0..<next {
                group.addTask(priority: .userInitiated) {
                    (slot, decodeFinderFile(urls[slot], capturedData: capturedData))
                }
            }
            var out: [(slot: Int, image: CGImage, isQTK: Bool)] = []
            var done = 0
            for await (slot, box) in group {
                if !Task.isCancelled, next < total {
                    let nextSlot = next
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        (nextSlot, decodeFinderFile(urls[nextSlot], capturedData: capturedData))
                    }
                }
                done += 1
                await progress(done, total)
                if let cg = box.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    out.append((slot, cg, box.isQTK))
                }
            }
            return out
        }
        // Frame ORDER is the one thing that must not be left to a task
        // group's completion order.
        let sorted = decoded.sorted { $0.slot < $1.slot }
        let qtkSlots = Set(sorted.enumerated().filter(\.element.isQTK).map(\.offset))
        return (sorted.map(\.image), qtkSlots)
    }

    /// Inspect dimensions before rasterizing, and hold access while reading.
    private static func decodeFinderFile(_ url: URL, capturedData: [URL: Data]?) -> DecodedImage {
        guard !Task.isCancelled else { return DecodedImage(image: nil, isQTK: false) }
        let data: Data
        if let capturedData {
            // A dropped batch is an immutable snapshot. Never substitute a
            // different file from disk if its snapshot is missing or corrupt.
            guard let captured = capturedData[url] else { return DecodedImage(image: nil, isQTK: false) }
            data = captured
        } else {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let read = try? Data(contentsOf: url) else { return DecodedImage(image: nil, isQTK: false) }
            data = read
        }
        if url.pathExtension.lowercased() == "qtk" {
            return DecodedImage(image: QTKDecoder().decode(
                data: data, enhanced: false, hdrEnabled: false, hdrHeadroom: 1.5), isQTK: true)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= PanoramaStitcher.maxFrameDimension,
              height <= PanoramaStitcher.maxFrameDimension else {
            return DecodedImage(image: nil, isQTK: false)
        }
        return DecodedImage(image: NSImage(data: data), isQTK: false)
    }

    /// Bake the resolved Look into just the QTK-derived frames of a mixed
    /// raw/finished Finder set, before matching; already-finished sources
    /// pass through untouched. Per-frame enhancement ahead of gain
    /// compensation can band a seam — see `PanoramaComposition.look` — but
    /// it is the only way to give the raw frames a look without also
    /// reprocessing a source that was already rendered.
    ///
    /// Runs detached, like `stitch`, because `FinishedImageLook.render` is a
    /// full-resolution pass per frame; checked between frames so a cancel
    /// during a mixed set doesn't grind through the rest of it.
    static func applyingLook(_ look: FinishedLookSettings, toQTKSlots qtkSlots: Set<Int>,
                             in frames: [CGImage]) async throws -> [CGImage] {
        guard look.enhanced || look.hdr, !qtkSlots.isEmpty else { return frames }
        let work = Task.detached(priority: .userInitiated) { () -> [CGImage] in
            var out = frames
            for index in qtkSlots {
                try Task.checkCancellation()
                guard let looked = FinishedImageLook.render(frames[index], enhanced: look.enhanced,
                                                            hdr: look.hdr, headroom: look.headroom),
                      let cg = looked.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                out[index] = cg
            }
            return out
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Camera-frame decode

    /// Develop already-fetched QTK archives in parallel, keyed by slot.
    ///
    /// The serial fetch stays in the manager (one wire, cannot be
    /// parallelised); this is the per-frame Bayer decode, which is the
    /// expensive part and does not depend between frames. Decoded without
    /// the Look — it lands on the assembled strip. `progress` reports
    /// `(decoded, archives.count)`; a caller mixing in finished frames
    /// supplies its own total. A cancelled task contributes no frame.
    static func decodeArchives(
        _ archives: [(slot: Int, data: Data)],
        progress: @Sendable (Int, Int) async -> Void
    ) async -> [(slot: Int, image: CGImage)] {
        let total = archives.count
        guard total <= PanoramaStitcher.maxFrameCount else { return [] }
        return await withTaskGroup(of: (Int, DecodedImage).self) { group in
            for a in archives {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return (a.slot, DecodedImage(image: nil, isQTK: false)) }
                    return (a.slot, DecodedImage(image: QTKDecoder().decode(
                        data: a.data, enhanced: false, hdrEnabled: false, hdrHeadroom: 1.5), isQTK: false))
                }
            }
            var out: [(slot: Int, image: CGImage)] = []
            var done = 0
            for await (slot, box) in group {
                done += 1
                await progress(done, total)
                if let cg = box.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    out.append((slot, cg))
                }
            }
            return out
        }
    }

    // MARK: - Match and blend

    /// Run the match and the single blend pass on a detached task, with the
    /// caller's cancellation forwarded into it by hand.
    ///
    /// `Task.detached` inherits nothing, cancellation included, so without
    /// the handler a Cancel would only stop the caller listening while the
    /// correlator ground on through every remaining pair for a picture
    /// nobody is going to see. `onAligning` reports `(completed, total)`
    /// pair matches; `onBlending` fires once the blend — one pass, not
    /// interruptible — begins. Throws `CancellationError` when cancelled at
    /// a pair boundary, before the blend, or DURING the blend, and
    /// `PanoramaStitcher.StitchError` otherwise. A nil strip is only ever
    /// a genuine render failure, never a cancellation — `render` also
    /// returns nil when cancelled mid-blend, and that must not read back
    /// as a successful (if empty) result.
    static func stitch(
        frames: [CGImage],
        fixedOrder: [Int]?,
        quickPanAssisted: Bool = false,
        quickPanStops: Int = 16,
        onRefining: @escaping @Sendable () -> Void = {},
        onAligning: @escaping @Sendable (Int, Int) -> Void,
        onBlending: @escaping @Sendable () -> Void
    ) async throws -> StitchOutput {
        let work = Task.detached(priority: .userInitiated) { () -> StitchOutput in
            var options = PanoramaStitcher.Options()
            // Nil unless the user arranged the frames by hand, which only
            // the Finder path allows.
            options.fixedOrder = fixedOrder
            options.quickPanAssisted = quickPanAssisted
            options.quickPanStops = quickPanStops
            let s = try PanoramaStitcher.match(frames: frames, options: options, refining: onRefining) { done, total in
                onAligning(done, total)
            }
            // Last chance to drop the work before spending a second or two
            // producing a strip that would be thrown away.
            try Task.checkCancellation()
            onBlending()
            let strip = s.render(slope: s.fittedSlope)
            // `render` also returns nil when cancelled partway through the
            // blend, not only on a real failure. Re-check here and throw
            // rather than hand the caller a nil strip it would report as
            // "could not be rendered" instead of "cancelled".
            try Task.checkCancellation()
            return StitchOutput(session: s, strip: strip)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Sweep and export

    /// Degrees covered by an OPEN arc. The stitcher measures overlap, not
    /// absolute angle, so this needs the rig's step — the QuickPan's detent
    /// is 22.5° (16 indents to the circle). This legacy estimate still
    /// assumes that rig; an unknown handheld pan has no measured absolute
    /// angle. Kept below 360 so only verified closure enables wraparound in
    /// the exported viewers.
    static func sweepEstimate(for session: PanoramaStitcher.Session) -> Double {
        let steps = Double(session.order.count - 1)
        let quickPanDetent = 22.5
        return min(359, steps * quickPanDetent
                   + quickPanDetent * (1 / max(0.001, 1 - session.overlap) - 1))
    }

    /// Stage the PNG, interactive HTML and immersive output for a finished
    /// composition on a detached task, and return the files that were
    /// published. Uses the session's measured sweep when it has one and the
    /// open-arc estimate otherwise. Staging and collision rules live in
    /// `PanoramaExport`; this only chooses the angle and leaves the main
    /// actor.
    static func export(
        strip: CGImage,
        session: PanoramaStitcher.Session,
        destination: URL,
        onStaged: @escaping @Sendable () -> Void = {}
    ) async throws -> [URL] {
        let sweep = session.sweepDegrees ?? sweepEstimate(for: session)
        let work = Task.detached(priority: .userInitiated) {
            try PanoramaExport.write(strip: strip, sweepDegrees: sweep, destination: destination,
                                     alignmentNote: session.alignmentNote, onStaged: onStaged)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
