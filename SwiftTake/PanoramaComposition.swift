import AppKit
import Combine

/// Holds automatic alignment and reversible per-photo corrections. Renders
/// publish only when they still match the current edits.
@MainActor
final class PanoramaComposition: ObservableObject {
    @Published private(set) var strip: CGImage?
    @Published private(set) var isRendering = false
    @Published var isSaving = false
    @Published var saveError: String?

    var canSave: Bool {
        strip != nil && !isRendering && !isSaving && slope == renderedSlope
            && adjustments == renderedAdjustments
    }
    @Published private(set) var adjustments: [Int: PanoramaStitcher.FrameAdjustment] = [:]
    private var renderedAdjustments: [Int: PanoramaStitcher.FrameAdjustment] = [:]
    var photoCenters: [Double] { session.frameCenters(slope: renderedSlope, adjustments: renderedAdjustments) }

    var hasPendingPhotoAdjustments: Bool { isRendering && adjustments != renderedAdjustments }

    func photoRegions(for source: Int) -> [CGRect] {
        guard let strip else { return [] }
        return session.frameRegions(for: source, slope: renderedSlope,
                                    adjustments: hasPendingPhotoAdjustments ? adjustments : renderedAdjustments,
                                    displayedSlope: renderedSlope, displayedAdjustments: renderedAdjustments,
                                    canvas: CGSize(width: strip.width, height: strip.height))
    }

    /// Pick in normalized image coordinates, including wrapped coverage. In a
    /// blended overlap, prefer the source whose centre is closest to the click.
    func photo(at point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        var nearest: (source: Int, distance: CGFloat)?
        for source in session.order {
            for region in photoRegions(for: source) where region.contains(point) {
                let distance = abs(region.midX - point.x)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (source, distance)
                }
            }
        }
        return nearest?.source
    }

    func adjustmentPreview(for source: Int) async -> CGImage? {
        let session = session, slope = renderedSlope, adjustments = renderedAdjustments, look = look
        let work = Task.detached(priority: .userInitiated) {
            Self.finished(session.adjustmentPreview(for: source, slope: slope, adjustments: adjustments), look)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func adjustment(for source: Int) -> PanoramaStitcher.FrameAdjustment {
        adjustments[source] ?? .init()
    }

    func nudgePhoto(_ source: Int, x: Int = 0, y: Int = 0) {
        guard sources.indices.contains(source), !isSaving else { return }
        var value = adjustment(for: source)
        value.x = max(-20, min(20, value.x + x))
        value.y = max(-20, min(20, value.y + y))
        guard value != adjustment(for: source) else { return }
        if value == .init() { adjustments.removeValue(forKey: source) }
        else { adjustments[source] = value }
        scheduleRender()
    }

    func resetPhoto(_ source: Int) {
        guard !isSaving, adjustments.removeValue(forKey: source) != nil else { return }
        scheduleRender()
    }

    func resetPhotos() {
        guard !isSaving, !adjustments.isEmpty else { return }
        adjustments.removeAll()
        scheduleRender()
    }
    @Published var slope: Int {
        didSet { if slope != oldValue { scheduleRender() } }
    }

    let session: PanoramaStitcher.Session
    let sources: [CGImage]
    let thumbnails: [CGImage]
    let frameCount: Int

    /// The slope the picture currently on screen was actually built at.
    /// `slope` runs ahead of it while a render is in flight.
    @Published private(set) var renderedSlope: Int

    private var renderTask: Task<Void, Never>?

    /// The Look, applied to the FINISHED strip rather than to each frame
    /// before stitching.
    ///
    /// Enhancing per frame fought the gain compensation: a non-linear tone
    /// curve applied separately to frames of differing exposure leaves the
    /// overlaps disagreeing in a way one gain factor per frame cannot
    /// absorb, which showed up as a vertical brightness band at a seam. The
    /// same frames stitched unenhanced come out clean. Applying it once at
    /// the end is also N times less work.
    let look: FinishedLookSettings

    init(session: PanoramaStitcher.Session, sources: [CGImage],
         initial: CGImage?, look: FinishedLookSettings) {
        self.session = session
        self.sources = sources
        self.thumbnails = sources.indices.map { session.thumbnail(for: $0) ?? sources[$0] }
        self.frameCount = sources.count
        self.slope = session.fittedSlope
        self.renderedSlope = session.fittedSlope
        self.look = look
        // The Look is a per-pixel pass over the whole strip. Cheap for a
        // handful of QuickTake 100 frames, but Tools/PanoramaHarness
        // measures ~390ms on a full-rotation set of 1600x1200 QuickTake
        // 200 frames — running that on the main actor here would freeze
        // the composer at the moment it appears. Show the raw blend first
        // and apply the Look through the same off-main path a Level change
        // uses, so this stall exists nowhere in the app.
        if let initial, look.enhanced || look.hdr {
            self.strip = initial
            scheduleInitialLook(initial)
        } else {
            self.strip = Self.finished(initial, look)
        }
    }

    /// The `init` half of the off-main Look path: applies the Look to the
    /// already-blended `initial` strip. No `session.render` call, since
    /// that geometry — fitted at construction — cannot be stale yet;
    /// `scheduleRender` below re-solves it after a Level change instead.
    /// Guarded exactly like `scheduleRender`: a Level change that lands
    /// before this finishes cancels it and its own result wins.
    private func scheduleInitialLook(_ strip: CGImage) {
        isRendering = true
        let look = self.look
        let slope = self.slope
        let adjustments = self.adjustments
        renderTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                Self.finished(strip, look)
            }
            let image = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, self.slope == slope, self.adjustments == adjustments else { return }
            if let image {
                self.strip = image
                self.renderedSlope = slope
                self.renderedAdjustments = adjustments
            }
            self.isRendering = false
        }
    }

    /// Every strip the user sees or saves passes through here, so the
    /// preview and the written file cannot disagree about the Look.
    /// `nonisolated` because the render runs on a detached task, and returns
    /// to CGImage because that is what the composer draws and the writers
    /// take — FinishedImageLook hands back an NSImage, which is the wrong
    /// currency for everything downstream of here.
    nonisolated fileprivate static func finished(
        _ image: CGImage?, _ look: FinishedLookSettings
    ) -> CGImage? {
        guard let image, look.enhanced || look.hdr else { return image }
        guard let looked = FinishedImageLook.render(
                image, enhanced: look.enhanced,
                hdr: look.hdr, headroom: look.headroom),
              let cg = looked.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }
        return cg
    }

    /// A shear approximates the pending correction for an open arc.
    /// Closed panoramas use a periodic correction; show their last render
    /// with the spinner instead of previewing an incorrect linear shear.
    ///
    /// Level shifts every frame by a fixed number of pixels per step, so
    /// changing it shears the whole strip — which means the picture
    /// already on screen can be sheared by the difference and show,
    /// immediately, what the renderer is about to produce. Assembling a
    /// strip takes long enough to feel; without this the image sits
    /// perfectly still while the slider moves under the pointer, and a
    /// control with no response reads as a broken one.
    ///
    /// Dimensionless (vertical pixels per horizontal pixel), so it can be
    /// applied in view space without knowing the display scale.
    /// Gated on `isRendering`, not merely on the two slopes differing. The
    /// shear means one thing — "the picture you are looking at is one
    /// render behind" — so when nothing is in flight there is nothing to
    /// stand in for and it must read exactly zero. Deriving it from the
    /// slopes alone left the preview permanently skewed if the two ever
    /// drifted apart (a cancelled or failed render never updates
    /// `renderedSlope`), and a composer that shows a leaning panorama
    /// while the control says "Aligned automatically" is worse than one
    /// with no live feedback at all.
    var previewShear: CGFloat {
        guard isRendering, !session.isFullRotation, let strip, strip.width > 0 else { return 0 }
        let drift = Double(slope - renderedSlope) * Double(max(1, frameCount - 1))
        return CGFloat(drift / Double(strip.width))
    }

    var isAuto: Bool { slope == session.fittedSlope }

    /// Which way the camera swept. Worth surfacing because it is the one
    /// thing a viewer can immediately check against their own memory of
    /// the shoot, and getting it backwards silently produces a plausible
    /// but scrambled panorama.
    var sweptRightToLeft: Bool {
        guard let first = session.order.first, let last = session.order.last else { return false }
        return first > last
    }

    var summary: String {
        var parts = ["\(frameCount) photos",
                     "\(Int((session.overlap * 100).rounded()))% overlap",
                     sweptRightToLeft ? "shot right to left" : "shot left to right"]
        if session.isFullRotation {
            parts.append("full rotation")
        } else if let s = session.sweepDegrees {
            parts.append("\(Int(s.rounded()))° arc")
        }
        if let f = session.impliedHFOV {
            parts.append(String(format: "%.0f° lens", f))
        }
        return parts.joined(separator: " · ")
    }

    func nudge(_ delta: Int) {
        slope = max(session.fittedSlope - 20, min(session.fittedSlope + 20, slope + delta))
    }
    func resetToAuto() { slope = session.fittedSlope }

    private func scheduleRender() {
        renderTask?.cancel()
        isRendering = true
        let session = self.session
        let slope = self.slope
        let adjustments = self.adjustments
        let look = self.look
        renderTask = Task { [weak self] in
            // Coalesce slider events before starting expensive work. Forward
            // cancellation to the worker so obsolete renders stop at a frame.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let work = Task.detached(priority: .userInitiated) {
                guard let strip = session.render(slope: slope, adjustments: adjustments), !Task.isCancelled else { return nil as CGImage? }
                return Self.finished(strip, look)
            }
            let image = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, self.slope == slope, self.adjustments == adjustments else { return }
            if let image {
                self.strip = image
                self.renderedSlope = slope
                self.renderedAdjustments = adjustments
                self.saveError = nil
            } else {
                self.saveError = "These adjustments leave too little overlap. Reset the photo or use a smaller adjustment."
            }
            self.isRendering = false
        }
    }
}
