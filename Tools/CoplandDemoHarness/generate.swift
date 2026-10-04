import Foundation

// Run production entry points with isolated session state; no camera, user
// preferences or photo library is touched.
func declaration(_ path: String, _ signature: String) throws -> String {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError(signature) }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError(signature)
}

print(#"""
import AppKit
import SwiftUI
import ImageIO

@MainActor enum TestClock {
    static var stopAt = 0, calls = 0
    static var paused: CheckedContinuation<Void, Never>?
    static func sleep(nanoseconds: UInt64) async throws {
        calls += 1
        if calls == stopAt { await withCheckedContinuation { paused = $0 } }
        else { await Task.yield() }
        try Task.checkCancellation()
    }
    static func release() { let pending = paused; paused = nil; pending?.resume() }
}
@MainActor final class Session {
    var closes = 0
    func disconnect() async { closes += 1 }
}
enum TestLog {
    static func note(_ topic: String, _ message: String) {}
    static func flush() {}
}

enum QuickTakeModel: CaseIterable {
    case qt100, qt150, qt200
    var usesQTKFormat: Bool { self != .qt200 }
    var profile: Self { self }
    var shortName: String { String(describing: self) }
}
@MainActor final class Work {
    var pending: Task<Void, Never>?
    var generation: UInt64 = 0
    func isCurrent(_ token: UInt64) -> Bool { token == generation && !Task.isCancelled }
    func start(_ body: @escaping @MainActor () async -> Void) {
        pending = Task { await body() }
    }
}
@MainActor final class DemoCamera {
    static let shared = DemoCamera()
    var isConnected = false
    func disconnect() { isConnected = false }
    struct Photo { let payload: [UInt8]; let container: [UInt8]? }
    var source: Photo?
    func photo(at index: UInt8) -> Photo? { source }
"""#)
print(try declaration("SwiftTake/SimulatedCamera.swift", "func decodedPreview(at"))
print(#"""
}
@MainActor final class Manager {
    var selectedModel = QuickTakeModel.qt150
    var isBusy = false, areThumbnailsLoading = false, isProbingLiveness = false
    var isConnected = true
    var photoSessionGeneration: UInt64 = 0
    var photoIndices: [UInt8] = [0]
    var connectionTimer: Task<Void, Never>?, sessionTeardown: Task<Void, Never>?
    let session = Session(), fujiSession = Session()
    var metadata: Int?, previewImage: NSImage?, previewedPhotoIndex: UInt8?
    var downloadProgress = 0.0, statusMessage = "", errorMessage: String?
    var isConnecting = false, detectedPortPath: String? = "demo"
    var cameraTransfers: [PhotoTransfer] = []
    var fujiJPEGCache: [UInt8: [UInt8]] = [:]
    var fetchedFrameCache: [UInt8: (header: [UInt8], data: [UInt8])] = [:]
    var effectiveImportDestinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
    var fetches = 0, looks = 0
    var payload: [UInt8] = []
    var invalidateDuringFetch = false
    enum Toast { case poweredDownReminder }
    func presentToast(_ toast: Toast) {}
    func invalidateCameraWork() { photoSessionGeneration += 1; cameraWork.generation += 1 }
    func clearGalleryState(keepingSlots: Bool) { if !keepingSlots { photoIndices = [] } }
    func clearCameraProgress() {}
    func fetchImageHeader(forImageIndex: UInt8) async -> [UInt8]? {
        var header = [UInt8](repeating: 0, count: 64)
        header[7] = 1
        return header
    }
    func fetchFullImage(forImageIndex: UInt8, imageSize: Int, sizeBytes: [UInt8],
                        progress: ((Double) -> Void)?) async -> [UInt8]? {
        fetches += 1
        if invalidateDuringFetch { cameraWork.generation += 1 }
        return payload
    }
    // A tripwire: source loading must not invoke the display Look.
    func renderCameraImage(model: QuickTakeModel, header: [UInt8], imageData: [UInt8]) -> NSImage? {
        looks += 1
        return NSImage(data: Data(imageData))
    }
    var importSucceeds = true
    func cameraTransfer(for index: UInt8) -> PhotoTransfer? {
        PhotoTransfer(index: index, progress: importSucceeds ? 1 : 0,
                      status: importSucceeds ? .imported : .failedDownload, savedFiles: [])
    }
    var cameraWork = Work()
    var rawImports = 0, demoImports = 0
    var importedPhotoURLs: [UInt8: [URL]] = [:]
    var enhancedPreviewImages: [UInt8: NSImage] = [:]
    var saved: (Data, String)?
    func demoImport(_ indices: [UInt8]) async { demoImports += 1; isBusy = false }
    func performReimportBatch(indices: [UInt8], requireConfirmation: Bool) async { rawImports += 1; isBusy = false }
    func captureDate(forIndex index: UInt8) -> Date? { nil }
    func saveCoplandImage(_ data: Data, baseName: String, for index: UInt8) -> URL? {
        saved = (data, baseName)
        return nil
    }
"""#)
print(try declaration("SwiftTake/QuickTakeSerialManager.swift", "func reimportPhoto(at"))
for signature in ["var canDevelopCopland:", "func disconnectCamera()", "func demoDisconnect()",
                  "private func loadOrFetchFinishedFrame(", "private func fetchFinishedFrameFromCamera("] {
    print(try declaration("SwiftTake/QuickTakeSerialManager.swift", signature)
        .replacingOccurrences(of: "private func", with: "func")
        .replacingOccurrences(of: "QTLog.", with: "TestLog."))
}
print(#"""
}
@MainActor final class Composer {
    let serialManager = Manager()
    func bake() { bakeCoplandFile(for: 0) }
    func begin() { beginCopland(at: 0) }
    func cancel() { cancelCopland() }
    var coplandTask: Task<Void, Never>?, coplandTaskID: UUID?
    var coplandIndex: UInt8?, coplandShrinkIndex: UInt8?
    var coplandActive = false, apertureOrbActive = true
    var coplandMorph: CGFloat = 0, apertureStretch: CGFloat = 0, apertureMorph: CGFloat = 0
    var coplandBubbleOpacity = 1.0, apertureTrailFade = 0.0
    var coplandReleasePoint = CGPoint.zero, apertureOrbGlobal = CGPoint.zero
    var apertureRect = CGRect.zero
    var apertureTrail: [CGPoint] = []
    func importPhoto(_ index: UInt8) { serialManager.isBusy = false }
"""#)
for signature in ["private func bakeCoplandFile(for", "private func charcoalNSFont(",
                  "private func transparentHole(of", "private func composeCoplandPNG(",
                  "private func beginCopland(at", "private func cancelCopland()", "private func resetCopland()"] {
    print(try declaration("SwiftTake/ContentView.swift", signature)
        .replacingOccurrences(of: "Task.sleep(nanoseconds:", with: "TestClock.sleep(nanoseconds:"))
}
print(#"""
}
@main struct Checks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
                exit(1)
            }
            checks += 1
            print("PASS: \(label)")
        }
        let image = NSImage(size: NSSize(width: 640, height: 480))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 480).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        DemoCamera.shared.source = .init(payload: [UInt8](jpeg), container: nil)
        let chrome = NSImage(contentsOfFile: "SwiftTake/Assets.xcassets/CoplandWindow.imageset/CoplandFrame.png")!
        check(chrome.setName("CoplandWindow"), "Load actual Copland frame")
        for model in QuickTakeModel.allCases {
            DemoCamera.shared.isConnected = true
            let composer = Composer()
            let manager = composer.serialManager
            manager.selectedModel = model
            manager.reimportPhoto(at: 0)
            await manager.cameraWork.pending?.value
            check(manager.rawImports == 0, "\(model) demo never enters raw re-import")
            check(manager.demoImports == (model.usesQTKFormat ? 1 : 0), "\(model) demo routing")
            // A stale/garbled cached preview must not be the bake source.
            manager.enhancedPreviewImages[0] = NSImage(size: NSSize(width: 1, height: 1))
            composer.bake()
            let saved = manager.saved
            check(saved != nil && saved!.1.hasPrefix("Demo_"), "\(model) exports without an intermediate file")
            let output = NSBitmapImageRep(data: saved!.0)!
            // Allow display-profile conversion, but require the source's
            // solid red content throughout the photo, not a scrambled mosaic.
            let retainsRed = [0.35, 0.5, 0.65].allSatisfy { y in
                [0.35, 0.5, 0.65].allSatisfy { x in
                    let color = output.colorAt(x: Int(Double(output.pixelsWide) * x),
                                               y: Int(Double(output.pixelsHigh) * y))!.usingColorSpace(.sRGB)!
                    return color.redComponent > 0.85 && color.greenComponent < 0.25 && color.blueComponent < 0.25
                }
            }
            check(retainsRed, "\(model) framed PNG retains source content instead of Bayer garbage")

            DemoCamera.shared.isConnected = false
            let live = Manager()
            live.selectedModel = model
            live.reimportPhoto(at: 0)
            await live.cameraWork.pending?.value
            check(live.rawImports == (model.usesQTKFormat ? 1 : 0) && live.demoImports == 0,
                  "\(model) hardware routing unchanged")
        }
        DemoCamera.shared.isConnected = true
        for flag in 0..<3 {
            let manager = Manager()
            manager.isBusy = flag == 0
            manager.areThumbnailsLoading = flag == 1
            manager.isProbingLiveness = flag == 2
            manager.reimportPhoto(at: 0)
            check(manager.cameraWork.pending == nil, "Busy gate \(flag) remains enforced")
        }
        let disconnect = Manager()
        disconnect.disconnectCamera()
        check(!DemoCamera.shared.isConnected && !disconnect.isConnected && disconnect.photoIndices.isEmpty,
              "Normal Disconnect ends the demo session and clears its gallery")
        check(disconnect.sessionTeardown == nil, "Demo disconnect does not touch hardware")
        disconnect.isConnected = true
        disconnect.fujiJPEGCache[0] = [UInt8](jpeg)
        disconnect.disconnectCamera()
        await disconnect.sessionTeardown?.value
        check(disconnect.session.closes == 1 && disconnect.fujiSession.closes == 1,
              "Hardware disconnect still closes both protocol sessions")
        let offline = await disconnect.loadOrFetchFinishedFrame(forIndex: 0)
        check(offline != nil && disconnect.fetches == 0,
              "Offline gallery retains original JPEGs for panoramas after disconnect")

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let enhanced = scratch.appendingPathComponent("photo_newtake.jpg")
        try jpeg.write(to: enhanced)
        for cache in 0..<3 {
            let manager = Manager()
            manager.selectedModel = .qt200
            manager.importedPhotoURLs[0] = [enhanced]
            manager.payload = [UInt8](jpeg)
            if cache == 0 { manager.fetchedFrameCache[0] = ([], [UInt8](jpeg)) }
            if cache == 1 { manager.fujiJPEGCache[0] = [UInt8](jpeg) }
            let frame = await manager.loadOrFetchFinishedFrame(forIndex: 0)
            check(frame != nil && manager.looks == 0, "Panorama source \(cache) bypasses the display Look")
            check(manager.fetches == (cache == 2 ? 1 : 0), "Panorama source \(cache) uses original cache or camera, never processed export")
        }
        let stale = Manager()
        stale.payload = [UInt8](jpeg)
        stale.invalidateDuringFetch = true
        let staleFrame = await stale.loadOrFetchFinishedFrame(forIndex: 0)
        check(staleFrame == nil && stale.fetchedFrameCache.isEmpty, "Stale panorama fetch cannot publish or populate cache")

        DemoCamera.shared.isConnected = true
        for stop in [1, 2, 3] {
            TestClock.calls = 0; TestClock.stopAt = stop
            let composer = Composer()
            composer.begin()
            let task = composer.coplandTask!
            while TestClock.paused == nil { await Task.yield() }
            // Reconnect can return to the same model, connected state and slot.
            // Generation must still reject the old task even without a UI hook.
            composer.serialManager.photoSessionGeneration += 1
            TestClock.release()
            await task.value
            check(composer.serialManager.saved == nil && !composer.coplandActive && composer.coplandTask == nil,
                  "Copland session change at suspension \(stop) prevents export and resets overlay")
        }
        TestClock.calls = 0; TestClock.stopAt = 1
        let cancelled = Composer()
        cancelled.begin()
        let cancelledTask = cancelled.coplandTask!
        while TestClock.paused == nil { await Task.yield() }
        cancelled.cancel()
        // Simulate a newer effect being installed before the old task resumes.
        let replacementID = UUID()
        cancelled.coplandTaskID = replacementID
        cancelled.coplandActive = true
        TestClock.release()
        await cancelledTask.value
        check(cancelled.serialManager.saved == nil && cancelled.coplandTaskID == replacementID && cancelled.coplandActive,
              "Cancelled Copland task cannot export or reset its replacement")
        for succeeds in [false, true] {
            TestClock.calls = 0; TestClock.stopAt = 0
            let composer = Composer()
            composer.serialManager.importSucceeds = succeeds
            composer.begin()
            await composer.coplandTask?.value
            check((composer.serialManager.saved != nil) == succeeds && !composer.coplandActive,
                  "Copland exports only after a successful transfer (success=\(succeeds))")
        }
        print("\(checks) Copland and session checks passed")
    }
}
"""#)
