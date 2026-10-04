import Foundation

// Compile the manager's actual orchestration against controlled I/O. The
// application methods are extracted unchanged; only access control is omitted.
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
func method(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError("Missing method: \(signature)") }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]).replacingOccurrences(of: "private func", with: "func") }
    }
    fatalError("Unterminated method: \(signature)")
}
let methods = ["var canPrepareDroppedPanorama:", "func prepareDroppedPanorama(", "func cancelPanoramaOrdering()", "func startPanorama(files:", "private func performPanoramaStitch(fileURLs:",
               "func stitchSelectedPanorama()", "func retryPanoramaWithQuickPan(", "func dismissPanoramaComposer(",
               "private func performPanoramaStitch(indices:", "private func presentPanoramaFailure("]
print(#"""
import Foundation
import Darwin

typealias CGImage = Int
enum PanoramaPhase: Equatable { case decoding(done: Int, total: Int); case refining }
enum PanoramaStitcher { static let maxFrameCount = 32; static let maxFrameDimension = 1600; static let quickPanStopsRange = 6...32 }
struct Model { var usesQTKFormat = true }
struct DemoCamera: Sendable {
    static let shared = DemoCamera()
    let isConnected = false, servesFinishedImages = false
}
// A plain-value stand-in; the production pipeline harness checks pixels.
struct FinishedLookSettings: Equatable {
    let enhanced: Bool
    let hdr: Bool
    let headroom: Double
    static let neutral = FinishedLookSettings(enhanced: false, hdr: false, headroom: 1.0)
}
actor DecodeControl {
    var calls = 0
    var qtkSlots: Set<Int> = []
    var bakedLook: FinishedLookSettings?
    func configure(slots: Set<Int>) { qtkSlots = slots }
    func bake(_ look: FinishedLookSettings) { bakedLook = look }
    var snapshot: [URL: Data]?
    func record(_ data: [URL: Data]?) { snapshot = data }
    var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        calls += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { let pending = waiters; waiters.removeAll(); for c in pending { c.resume() } }
    func reset() { precondition(waiters.isEmpty); calls = 0; snapshot = nil; qtkSlots = []; bakedLook = nil }
}
enum PanoramaPipeline {
    static let control = DecodeControl()
    static func decodeFinderFrames(urls: [URL], capturedData: [URL: Data]? = nil, progress: @Sendable (Int, Int) async -> Void) async -> (frames: [CGImage], qtkSlots: Set<Int>) {
        await control.record(capturedData)
        await control.pause()
        await progress(urls.count, urls.count)
        return (Array(urls.indices), await control.qtkSlots)
    }
    static func decodeArchives(_ archives: [(slot: Int, data: Data)], progress: @Sendable (Int, Int) async -> Void) async -> [(slot: Int, image: CGImage)] {
        await control.pause()
        await progress(archives.count, archives.count)
        return archives.map { ($0.slot, $0.slot) }
    }
    static func applyingLook(_ look: FinishedLookSettings, toQTKSlots qtkSlots: Set<Int>, in frames: [CGImage]) async throws -> [CGImage] {
        await control.bake(look)
        return frames.enumerated().map { qtkSlots.contains($0.offset) ? $0.element + 100 : $0.element }
    }
}
@MainActor final class Fixture {
    var panoramaGeneration = 0
    var panoramaTask: Task<Void, Never>?
    var panoramaRetryInput: (frames: [CGImage], order: [Int]?, look: FinishedLookSettings)?
    var canRetryQuickPan = false
    var panoramaQuickPanStops = 16
    var pendingPanoramaFiles: [URL]?
    var pendingPanoramaData: [URL: Data]?
    var isConnecting = false, isRefreshing = false, areThumbnailsLoading = false, dropConversionActive = false
    var panoramaFailure: String?
    var panoramaSourceSlots: [UInt8] = []
    var panorama: Int?
    var panoramaPhase: PanoramaPhase?
    var showingPanoramaComposer = false
    var selectedPhotoIndices: Set<UInt8> = [1,2]
    var selectedModel = Model()
    var isBusy = false, finishes = 0
    var statusMessage = "Idle"
    let defaultIdleStatus = "Idle"
    var finishedLook = FinishedLookSettings.neutral
    var receivedLook: FinishedLookSettings?
    var receivedFrames: [CGImage] = []
    var receivedOrder: [Int]?
    var receivedStops: Int?
    func setBusy(_ busy: Bool, status: String) { isBusy = busy; statusMessage = status }
    func endBusy(status: String = "") { isBusy = false; if !status.isEmpty { statusMessage = status } }
    func loadOrFetchQTK(forIndex: UInt8) async -> Data? { Data([forIndex]) }
    func loadOrFetchFinishedFrame(forIndex: UInt8) async -> CGImage? { Int(forIndex) }
    func finishPanoramaStitch(frames: [CGImage], generation: Int, fixedOrder: [Int]? = nil, quickPanAssisted: Bool = false, quickPanStops: Int = 16, look: FinishedLookSettings) async {
        receivedLook = look; receivedFrames = frames; receivedOrder = fixedOrder
        receivedStops = quickPanAssisted ? quickPanStops : nil
        finishes += 1; panorama = frames.count
    }
"""#)
for signature in methods { print(method(signature)) }
print(#"""
}
@main struct Checks {
    @MainActor static func main() async {
        var failures = 0, checks = 0
        func check(_ pass: Bool, _ label: String) {
            checks += 1; if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL"): \(label)")
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        func waitForDecode() async {
            let deadline = ContinuousClock.now + .seconds(3)
            while await PanoramaPipeline.control.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        }
        let files = [URL(fileURLWithPath: "/fake/1.png"), URL(fileURLWithPath: "/fake/2.png")]
        for camera in [false, true] {
            await PanoramaPipeline.control.reset()
            let f = Fixture()
            if camera { f.stitchSelectedPanorama() } else { f.startPanorama(files: files, fixedOrder: nil) }
            let old = f.panoramaTask!
            // Cancel and restart in the same main-actor turn, before either
            // unstructured task has executed its first instruction.
            f.dismissPanoramaComposer()
            if camera { f.stitchSelectedPanorama() } else { f.startPanorama(files: files, fixedOrder: nil) }
            let current = f.panoramaTask!
            await waitForDecode(); await settle()
            check(await PanoramaPipeline.control.calls == 1, "\(camera ? "camera" : "Finder"): cancelled queued job never enters decoding")
            await PanoramaPipeline.control.release()
            await old.value; await current.value
            check(f.finishes == 1 && f.panorama == 2 && !f.isBusy && f.panoramaPhase == nil,
                  "\(camera ? "camera" : "Finder"): replacement completes and clears its own progress")
        }
        for camera in [false, true] {
            await PanoramaPipeline.control.reset()
            let f = Fixture()
            if camera { f.stitchSelectedPanorama() } else { f.startPanorama(files: files, fixedOrder: nil) }
            let job = f.panoramaTask!
            await waitForDecode()
            f.dismissPanoramaComposer()
            check(!f.isBusy && f.panoramaPhase == nil && !f.showingPanoramaComposer,
                  "\(camera ? "camera" : "Finder"): Cancel immediately restores idle UI")
            await PanoramaPipeline.control.release(); await job.value
            check(f.panoramaPhase == nil && !f.isBusy && !f.showingPanoramaComposer && f.finishes == 0,
                  "\(camera ? "camera" : "Finder"): late decode progress cannot revive cancelled UI")
        }
        let failed = Fixture()
        failed.setBusy(true, status: "Aligning")
        failed.presentPanoramaFailure("Could not find a confident overlap between frames.")
        check(!failed.isBusy && failed.panoramaPhase == nil && failed.showingPanoramaComposer && failed.panoramaFailure != nil,
              "overlap failure stays in composer and clears busy state")
        failed.dismissPanoramaComposer()
        check(!failed.showingPanoramaComposer && failed.panoramaFailure == nil && !failed.canRetryQuickPan,
              "dismissing failure clears retry and error state")
        await PanoramaPipeline.control.reset()
        let dropped = Fixture()
        let two = URL(fileURLWithPath: "/original/Photo 2.qtk")
        let ten = URL(fileURLWithPath: "/original/Photo 10.qtk")
        let snapshot = [two: Data([2]), ten: Data([10])]
        dropped.prepareDroppedPanorama(snapshot)
        check(dropped.pendingPanoramaFiles == [two, ten] && dropped.pendingPanoramaData == snapshot,
              "drop review sorts naturally and retains every source byte")
        dropped.cancelPanoramaOrdering()
        check(dropped.pendingPanoramaFiles == nil && dropped.pendingPanoramaData == nil,
              "cancelling drop ordering releases the snapshot")
        dropped.isBusy = true
        dropped.prepareDroppedPanorama(snapshot)
        check(dropped.pendingPanoramaFiles == nil, "drop cannot replace a busy operation")
        dropped.isBusy = false
        dropped.showingPanoramaComposer = true
        dropped.prepareDroppedPanorama(snapshot)
        check(dropped.pendingPanoramaFiles == nil, "drop cannot replace an open unsaved panorama")
        dropped.showingPanoramaComposer = false
        dropped.prepareDroppedPanorama([two: Data([2])])
        check(dropped.pendingPanoramaFiles == nil, "single-file input cannot start a panorama")
        let oversized = Dictionary(uniqueKeysWithValues: (0..<33).map { (URL(fileURLWithPath: "/original/\($0).qtk"), Data([0])) })
        dropped.prepareDroppedPanorama(oversized)
        check(dropped.pendingPanoramaFiles == nil, "oversized drop cannot enter panorama ordering")
        dropped.prepareDroppedPanorama(snapshot)
        dropped.startPanorama(files: dropped.pendingPanoramaFiles!, fixedOrder: [ten, two])
        let dropTask = dropped.panoramaTask!
        await waitForDecode()
        check(await PanoramaPipeline.control.snapshot == snapshot,
              "stitch receives the captured bytes after the order sheet releases them")
        check(dropped.pendingPanoramaData == nil && dropped.pendingPanoramaFiles == nil,
              "starting clears pending drop presentation state")
        dropped.dismissPanoramaComposer()
        await PanoramaPipeline.control.release()
        await dropTask.value
        check(dropped.panorama == nil && !dropped.showingPanoramaComposer,
              "cancelled dropped panorama cannot publish late results")
        // Exercise the actual manager branches with suspended input, so live
        // settings can change after the job has captured its original look.
        let enhanced = FinishedLookSettings(enhanced: true, hdr: true, headroom: 1.8)
        for rawSlots: Set<Int> in [[], [0, 1], [0]] {
            await PanoramaPipeline.control.reset()
            await PanoramaPipeline.control.configure(slots: rawSlots)
            let f = Fixture()
            f.finishedLook = enhanced
            f.startPanorama(files: files, fixedOrder: nil)
            let job = f.panoramaTask!
            await waitForDecode()
            f.finishedLook = .neutral
            await PanoramaPipeline.control.release(); await job.value
            check(f.receivedLook == (rawSlots.count == 2 ? enhanced : .neutral),
                  "Finder raw slots \(rawSlots.sorted()): correct strip treatment survives a settings change")
            check(f.receivedFrames == (rawSlots == [0] ? [100, 1] : [0, 1]),
                  "Finder raw slots \(rawSlots.sorted()): only mixed raw frames are preprocessed")
            check(await PanoramaPipeline.control.bakedLook == (rawSlots == [0] ? enhanced : nil),
                  "Finder raw slots \(rawSlots.sorted()): mixed processing uses the captured look exactly once")
        }
        let retry = Fixture()
        retry.finishedLook = .neutral
        retry.canRetryQuickPan = true
        retry.panoramaRetryInput = (Array(0..<18), Array((0..<18).reversed()), enhanced)
        retry.retryPanoramaWithQuickPan(stops: 18)
        await retry.panoramaTask?.value
        check(retry.receivedLook == enhanced && retry.receivedFrames == Array(0..<18)
              && retry.receivedOrder == Array((0..<18).reversed()) && retry.receivedStops == 18,
              "assisted retry forwards cached frames, order, look and declared spacing")
        retry.dismissPanoramaComposer()
        check(retry.panoramaRetryInput == nil && retry.panoramaQuickPanStops == 16,
              "dismissing an assisted job clears cached input and resets spacing")
        print("\(checks-failures)/\(checks) panorama lifecycle checks passed")
        if failures > 0 { exit(1) }
    }
}
"""#)
