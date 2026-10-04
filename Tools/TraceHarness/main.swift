import Foundation

/// Hold one disk write until the test releases it, without blocking MainActor.
final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    func write(_ body: String, to url: URL) throws {
        lock.lock()
        let shouldWait = !entered && body.contains("old-session")
        if shouldWait { entered = true }
        lock.unlock()
        if shouldWait {
            guard releaseSignal.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func release() { releaseSignal.signal() }
}

@main struct TraceHarness {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTakeTraceChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var passed = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, "FAIL: " + label)
            passed += 1
            print("PASS: " + label)
        }
        func read(_ url: URL?) throws -> String {
            guard let url else { throw CocoaError(.fileReadNoSuchFile) }
            return try String(contentsOf: url, encoding: .utf8)
        }

        let log = QTDiagnosticLog(traceDirectory: directory)
        check(log.beginSession("attempt-one") == nil, "empty logger has no previous trace to save")
        log.log("CONNECT", "failed-handshake")
        let firstSave = log.flush()
        let rescued = log.beginSession("attempt-two")
        let firstURL = await firstSave.value
        let firstText = try read(firstURL)
        check(firstText.contains("failed-handshake") && !firstText.contains("attempt-two"),
              "flush snapshots the failed attempt before an immediate retry")
        _ = await rescued?.value
        check(log.text.contains("attempt-two") && !log.text.contains("failed-handshake"),
              "new attempt starts with its own trace")

        let saveA = log.flush()
        let saveB = log.flush()
        let urlA = await saveA.value
        let urlB = await saveB.value
        check(urlA != nil && urlB != nil && urlA != urlB, "rapid exports have distinct filenames")
        check(try read(urlA) == read(urlB), "rapid exports preserve both identical snapshots")
        check(log.lastExportURL == urlB, "latest requested successful save supplies the reveal URL")
        check(log.beginSession("after-complete-export") == nil, "fully saved trace needs no rescue")

        _ = await log.export()
        log.log("CONNECT", "failure-after-manual-export")
        let afterManual = log.beginSession("after-manual")
        check(try read(await afterManual?.value).contains("failure-after-manual-export"),
              "entries added after manual export survive the next connect")

        for index in 0..<4010 { log.log("TEST", "entry-\(index)") }
        check(log.text.components(separatedBy: "\n").count == 4000, "trace buffer stays bounded")
        _ = await log.export()
        log.log("TEST", "after-ring-rollover")
        let rollover = log.beginSession("after-rollover")
        check(try read(await rollover?.value).contains("after-ring-rollover"),
              "new entries remain detectable after the ring is full")

        let goodURL = await log.export()
        check(goodURL?.deletingLastPathComponent().path == directory.path,
              "export uses the instance's injected directory by default")
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        log.log("TEST", "unsaved-after-failure")
        check(await log.export(to: blocker) == nil, "unwritable destination reports failure")
        check(log.lastExportURL == goodURL, "failed write preserves the last successful URL")
        let afterFailure = log.beginSession("after-write-failure")
        check(try read(await afterFailure?.value).contains("unsaved-after-failure"),
              "failed export does not mark unsaved entries as persisted")

        let gate = WriteGate()
        defer { gate.release() }
        let delayed = QTDiagnosticLog(traceDirectory: directory,
                                      writer: { body, url in try gate.write(body, to: url) })
        delayed.beginSession("old-session")
        for index in 0..<10 { delayed.log("TEST", "old-\(index)") }
        let slowSave = delayed.flush()
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        check(gate.hasEntered, "main actor remains responsive while the disk writer is blocked")
        let oldRescue = delayed.beginSession("new-session")
        _ = await oldRescue?.value
        let newestURL = await delayed.export()
        delayed.log("TEST", "new-session-unsaved")
        gate.release()
        check(await slowSave.value != nil, "accepted old-session save completes after reconnect")
        check(delayed.lastExportURL == newestURL, "late old save cannot replace the newer reveal URL")
        let lateRescue = delayed.beginSession("third-session")
        check(try read(await lateRescue?.value).contains("new-session-unsaved"),
              "late old completion cannot mark new-session entries as saved")

        var shortLived: QTDiagnosticLog? = QTDiagnosticLog(traceDirectory: directory)
        shortLived?.beginSession("released-owner")
        let acceptedSave = shortLived!.flush()
        shortLived = nil
        check(try read(await acceptedSave.value).contains("released-owner"),
              "accepted save survives release of its logger owner")

        print("ALL \(passed) TRACE CHECKS PASSED")
    }
}
