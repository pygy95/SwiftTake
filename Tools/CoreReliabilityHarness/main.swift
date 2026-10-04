import Foundation
import Darwin

@main struct CoreChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1; print("PASS: " + name)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftTakeCore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("photo.tiff")
        let original = Data("original complete image".utf8)
        try original.write(to: target)
        enum TestFailure: Error { case failed }
        do {
            try AtomicFileWriter.write(to: target) { url in
                try Data("partial".utf8).write(to: url)
                throw TestFailure.failed
            }
            check(false, "failed encoder throws")
        } catch TestFailure.failed { check(true, "failed encoder throws") }
        check(try Data(contentsOf: target) == original, "failed replacement preserves original")
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["photo.tiff"], "failed encoder leaves no temporary file")
        let replacement = Data("new complete image".utf8)
        try AtomicFileWriter.write(to: target) { try replacement.write(to: $0) }
        check(try Data(contentsOf: target) == replacement, "successful replacement published")
        let occupied = directory.appendingPathComponent("folder.tiff")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        do {
            try AtomicFileWriter.write(to: occupied) { try replacement.write(to: $0) }
            check(false, "rename failure throws")
        } catch { check(true, "rename failure throws") }
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2, "rename failure cleans its temporary file")

        let work = CameraWork()
        let generation = work.generation
        var latePublished = false
        let late = work.start {
            let token = work.generation
            // Simulates a library call which finishes despite cancellation.
            _ = await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value
            if work.isCurrent(token) { latePublished = true }
        }
        try await Task.sleep(for: .milliseconds(10))
        work.invalidate()
        var newPublished = false
        let fresh = work.start { newPublished = true }
        await late.value; await fresh.value
        check(!latePublished, "late result from old connection rejected")
        check(newPublished && !work.isCurrent(generation), "new connection work remains valid")
        var neverStarted = false
        let queued = work.start { neverStarted = true }
        work.invalidate()
        await queued.value
        check(!neverStarted, "invalidated queued work cannot start")

        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(master); Darwin.close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let path = String(cString: name)
        let port = SerialPort()
        try await port.open(path: path, baud: 9600, parity: .none)
        var line = termios()
        check(tcgetattr(slave, &line) == 0, "pseudo-terminal line settings readable")
        let cc = withUnsafeBytes(of: line.c_cc) { ($0[Int(VMIN)], $0[Int(VTIME)]) }
        check(cc.0 == 0 && cc.1 == 0, "read timing explicitly configured")
        check(line.c_cflag & tcflag_t(CCTS_OFLOW | CRTS_IFLOW | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW) == 0, "hardware flow control explicitly disabled")
        // A PTY's output queue drains only when its simulated peer reads.
        let peer = Task { () -> [UInt8] in
            let deadline = ContinuousClock.now + .seconds(2)
            var bytes = [UInt8](repeating: 0, count: 3)
            while ContinuousClock.now < deadline {
                let n = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, 3) }
                if n > 0 { return Array(bytes.prefix(n)) }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return []
        }
        check(await port.send([0x10,0x20,0x30]), "bounded send succeeds")
        check(await peer.value == [0x10,0x20,0x30], "outgoing bytes intact")
        let partial = Task { await port.receive(2, timeout: 0.05) }
        _ = [UInt8(7)].withUnsafeBytes { Darwin.write(master, $0.baseAddress, 1) }
        check(await partial.value == nil, "partial read times out")
        let stale = Task { await port.receive(3, timeout: 1) }
        try await Task.sleep(for: .milliseconds(10))
        await port.close()
        try await port.open(path: path, baud: 9600, parity: .none)
        _ = [UInt8(4),5,6].withUnsafeBytes { Darwin.write(master, $0.baseAddress, 3) }
        check(await stale.value == nil, "old read cannot consume a reopened port")
        check(await port.receive(3, timeout: 0.2) == [4,5,6], "new connection retains its incoming bytes")
        let cancellation = Task { await port.receive(8, timeout: 10) }
        cancellation.cancel()
        check(await cancellation.value == nil, "cancelled receive exits")
        let started = ContinuousClock.now
        let blocked = await port.send([UInt8](repeating: 65, count: 1_000_000), timeout: 0.03)
        check(!blocked && started.duration(to: .now) < .seconds(1), "backpressured write has a bounded deadline")
        check(await port.isOpen == false, "partial failed send invalidates the port")
        print("\(passed) core reliability checks passed")
    }
}
