import Foundation

// Only app/UI dependencies are stubbed. The session, commands, wake scanner
// and POSIX transport compile from the production sources.
@MainActor enum QuickTakeModel { case qt100, qt150 }
@MainActor enum QTLog {
    static func note(_ category: String, _ message: String, detail: String? = nil) {}
    static func note(_ category: String, _ message: String, bytes: [UInt8]) {}
}
enum QuickTake200ThumbnailRenderer {
    static func describe(_ bytes: [UInt8]) -> String { "unused diagnostic rendering" }
}

actor ScriptedPort: QuickTakeTransport {
    struct Read: Sendable {
        let count: Int
        let bytes: [UInt8]?
        var delay: UInt64 = 0
    }
    enum Failure: Error { case configure }
    private var reads: [Read]
    private(set) var sent: [[UInt8]] = []
    private(set) var readCount = 0
    private(set) var readTimeouts: [TimeInterval] = []
    private(set) var configurations: [Int] = []
    private(set) var closes = 0
    private(set) var opens = 0
    var failConfiguration: Int?

    init(_ reads: [Read], failConfiguration: Int? = nil) {
        self.reads = reads
        self.failConfiguration = failConfiguration
    }
    func open(path: String, baud: Int, parity: SerialPort.Parity) { opens += 1 }
    func close() { closes += 1 }
    func reconfigure(baud: Int, parity: SerialPort.Parity) throws {
        configurations.append(baud)
        if configurations.count == failConfiguration { throw Failure.configure }
    }
    func setDTR(_ asserted: Bool) {}
    var sendSucceeds = true
    func failSends() { sendSucceeds = false }
    func send(_ bytes: [UInt8]) -> Bool { sent.append(bytes); return sendSucceeds }
    func drain(idleFor idle: TimeInterval, limit: TimeInterval) -> Int { 0 }
    func receive(_ count: Int, timeout: TimeInterval) async -> [UInt8]? {
        precondition(!reads.isEmpty, "Unexpected read of \(count) bytes")
        let next = reads.removeFirst()
        precondition(next.count == count, "Expected read of \(next.count), got \(count)")
        readCount += 1
        readTimeouts.append(timeout)
        if next.delay > 0 {
            do { try await Task.sleep(nanoseconds: next.delay) }
            catch { return nil }
        }
        return next.bytes
    }
}

@main struct SerialHarness {
    @MainActor static var passed = 0
    @MainActor static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        passed += 1
        print("PASS: \(name)")
    }
    static func read(_ count: Int, _ bytes: [UInt8]?, delay: UInt64 = 0) -> ScriptedPort.Read {
        .init(count: count, bytes: bytes, delay: delay)
    }
    static func handshakeReads(wake: [UInt8], ping: UInt8 = 0, final: UInt8 = 0,
                               finalReads: [ScriptedPort.Read]? = nil) -> [ScriptedPort.Read] {
        wake.map { read(1, [$0], delay: 20_000_000) }
        + [read(10, Array(repeating: 0, count: 10)), read(1, [ping]), read(1, [0])]
        + (finalReads ?? [read(1, [final])])
    }
    static func waitForRead(_ count: Int, on port: ScriptedPort) async {
        while await port.readCount < count { await Task.yield() }
    }
    /// Script one Fuji reply frame: ESC STX, header, `data` (escaping any
    /// literal 0x10), ESC `term`, checksum — matching
    /// `replyChecksumIsValid`'s two candidate domains.
    static func fujiFrame(_ data: [UInt8], term: UInt8 = 0x03, includeHeaderInChecksum: Bool = true) -> [ScriptedPort.Read] {
        let header: [UInt8] = [0, 0, UInt8(data.count & 0xFF), 0]
        var checksum = term
        for b in data { checksum ^= b }
        if includeHeaderInChecksum { for b in header { checksum ^= b } }
        var wireData: [ScriptedPort.Read] = []
        for b in data {
            if b == 0x10 { wireData.append(read(1, [0x10])) }
            wireData.append(read(1, [b]))
        }
        return [read(1, [0x10]), read(1, [2]), read(4, header)]
            + wireData
            + [read(1, [0x10]), read(1, [term]), read(1, [checksum])]
    }
    @MainActor static func main() async {
        let qt150: [UInt8] = [0xA5, 0x5A, 0, 0xC8, 0, 1, 2]
        let qt100: [UInt8] = [0xA5, 0x5A, 1, 1, 1, 0, 2]
        for (name, bytes, discarded) in [
            ("QT150 aligned", qt150, 0),
            ("QT100 aligned", qt100, 0),
            ("leading chatter", [0xC0] + qt150, 1),
            ("overlapping prefix", [0xA5] + qt150, 1),
            ("false prefix", [0xA5, 0, 0xAA] + qt150, 3)
        ] {
            var parser = QuickTakeWakeBuffer()
            var packets: [[UInt8]] = []
            for byte in bytes { if let p = parser.append(byte) { packets.append(p) } }
            check(packets == [name == "QT100 aligned" ? qt100 : qt150]
                  && parser.discardedBytes == discarded, name)
        }
        var truncated = QuickTakeWakeBuffer()
        check(qt150.dropLast().allSatisfy { truncated.append($0) == nil }, "truncated wake never accepted")

        for (model, burst, speed, baud) in [
            ("QT150", [0xC0] + qt150, QuickTakeCameraSession.LineSpeed.fast, 57600),
            ("QT100", qt100, QuickTakeCameraSession.LineSpeed.standard, 9600)
        ] {
            let port = ScriptedPort(handshakeReads(wake: burst))
            let session = QuickTakeCameraSession(port: port)
            check(await session.open(path: "script"), "\(model) opens")
            check(await session.handshake(speed: speed), "\(model) fragmented handshake")
            check(session.wakeModelByte == (model == "QT150" ? 0xC8 : 1), "\(model) identity")
            let commands = await port.sent
            check(commands == [QuickTakeCommands.open(baud: baud), QuickTakeCommands.ping(),
                               QuickTakeCommands.selectBaud(baud), [6], [6]], "\(model) command order and selected speed")
            check(await port.configurations == [9600, baud], "\(model) host baud sequence")
            check(await session.open(path: "new script"), "reopen succeeds")
            check(session.wakeModelByte == nil, "reopen clears identity")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: []))
            let session = QuickTakeCameraSession(port: port)
            check(await session.handshake(speed: .fast, assumeAwake: true), "already-awake fallback still works")
            check(session.wakeIdentity == nil, "already-awake fallback does not invent identity")
        }
        do {
            let port = ScriptedPort([read(1, nil)])
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast)), "silent camera fails passive probe")
            check(await port.sent.isEmpty, "passive Kodak probe sends no commands to silent/Fuji line")
        }
        do {
            let port = ScriptedPort([read(10, nil)])
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)), "missing open reply fails handshake")
            check(await port.sent.count == 1, "failed open reply stops before speed command")
        }
        for rejected: UInt8 in [2, 6, 0xAA] {
            let port = ScriptedPort([read(1, [rejected])])
            let session = QuickTakeCameraSession(port: port)
            check(await session.readDeviceInfo() == nil, "reject status \(rejected)")
            check(await port.sent == [QuickTakeCommands.deviceInfo()], "no payload ACK after rejected status \(rejected)")
        }
        for failAt in [1, 2] {
            let port = ScriptedPort(handshakeReads(wake: []), failConfiguration: failAt)
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)), "configuration error \(failAt) fails handshake")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], final: 2))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)), "final baud status must succeed")
        }
        // MARK: - Final speed-change ACK: skip only 0xAA filler, require 0x00
        do {
            // The camera pads its post-baud ACK with 0xAA filler and then 0x00.
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA], delay: 100_000_000), read(1, [0xAA]), read(1, [0])]))
            let session = QuickTakeCameraSession(port: port)
            check(await session.handshake(speed: .fast, assumeAwake: true),
                  "final speed ACK skips leading AA filler and accepts 0x00")
            check(await port.sent == [QuickTakeCommands.open(baud: 57600), QuickTakeCommands.ping(),
                                      QuickTakeCommands.selectBaud(57600), [6], [6]],
                  "final speed ACK is sent exactly once despite the filler")
        }
        do {
            // Exactly the reference's 1024-byte filler flood, then the status.
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                Array(repeating: read(1, [0xAA]), count: 1024) + [read(1, [0])]))
            let session = QuickTakeCameraSession(port: port)
            check(await session.handshake(speed: .fast, assumeAwake: true),
                  "final speed ACK accepts exactly 1024 AA filler bytes then 0x00")
        }
        do {
            // One filler byte past the 1024 cap, still no status: fail.
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                Array(repeating: read(1, [0xAA]), count: 1025) + [read(1, [0])]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK fails when AA filler overruns the 1024-byte cap")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA]), read(1, [2])]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK rejects 0x02 after filler")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA]), read(1, nil)]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK fails on a nil read after filler")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA]), read(1, [0x99])]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK rejects an unexpected non-AA, non-status byte")
        }
        do {
            // Filler still streaming when the handshake task is cancelled.
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                Array(repeating: read(1, [0xAA], delay: 20_000_000), count: 200) + [read(1, [0])]))
            let session = QuickTakeCameraSession(port: port)
            let task = Task { await session.handshake(speed: .fast, assumeAwake: true) }
            await waitForRead(6, on: port)
            task.cancel()
            check(!(await task.value),
                  "final speed ACK fails when the handshake is cancelled mid-filler")
        }
        do {
            // The single 2-second budget elapses before the status byte.
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA], delay: 2_050_000_000), read(1, [0])]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK fails when the 2-second deadline passes before 0x00")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], finalReads:
                [read(1, [0xAA], delay: 750_000_000),
                 read(1, [0xAA], delay: 750_000_000),
                 read(1, [0], delay: 750_000_000)]))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)),
                  "final speed ACK cannot renew its deadline for each filler byte")
        }
        do {
            let port = ScriptedPort(handshakeReads(wake: [], ping: 2))
            let session = QuickTakeCameraSession(port: port)
            check(!(await session.handshake(speed: .fast, assumeAwake: true)), "rejected handshake ping stops negotiation")
            check(await port.sent.count == 2, "no baud command after rejected ping")
        }
        do {
            let payload = Array(repeating: UInt8(7), count: 128)
            let port = ScriptedPort([read(1, [0], delay: 100_000_000), read(128, payload), read(1, [0])])
            let session = QuickTakeCameraSession(port: port)
            let info = Task { await session.readDeviceInfo() }
            await waitForRead(1, on: port)
            let ping = Task { await session.isResponding() }
            let infoResult = await info.value
            let pingResult = await ping.value
            check(infoResult == payload && pingResult, "concurrent metadata and monitor finish")
            check(await port.sent == [QuickTakeCommands.deviceInfo(), [6], QuickTakeCommands.ping()], "monitor cannot interleave with metadata")
        }
        do {
            let port = ScriptedPort([read(1, [0], delay: 100_000_000), read(128, nil), read(1, [0])])
            let session = QuickTakeCameraSession(port: port)
            let info = Task { await session.readDeviceInfo() }
            await waitForRead(1, on: port)
            let cancelled = Task { await session.isResponding() }
            await Task.yield()
            cancelled.cancel()
            check(await info.value == nil, "failed payload returns nil")
            check(!(await cancelled.value), "cancelled queued transaction fails")
            check(await session.isResponding(), "gate released after failure and queued cancellation")
            check(await port.sent == [QuickTakeCommands.deviceInfo(), [6], QuickTakeCommands.ping()], "cancelled command never sent")
        }
        for count in [512, 513, 1024] {
            let blocks = stride(from: 0, to: count, by: 512).map { offset in
                read(min(512, count - offset), Array(repeating: 9, count: min(512, count - offset)))
            }
            let port = ScriptedPort([read(1, [0])] + blocks)
            let session = QuickTakeCameraSession(port: port)
            let size: [UInt8] = [0, UInt8(count >> 8), UInt8(count & 255)]
            check(await session.readPhoto(index: 0, byteCount: count, sizeField: size)?.count == count,
                  "stream length \(count)")
            check(await port.sent.filter { $0 == [6] }.count == blocks.count,
                  "no trailing ACK for \(count)-byte image")
        }
        do {
            let port = ScriptedPort([])
            let session = QuickTakeCameraSession(port: port)
            check(await session.readPhoto(index: 0, byteCount: 512, sizeField: [0, 0, 1]) == nil,
                  "mismatched photo length rejected before wire")
            check(await port.sent.isEmpty, "invalid length sends nothing")
        }
        do {
            let port = ScriptedPort([])
            await port.failSends()
            let session = QuickTakeCameraSession(port: port)
            check(await session.readDeviceInfo() == nil, "failed Kodak write rejects command")
            check(await port.readCount == 0, "failed Kodak write never waits for a reply")
        }
        for (reply, expected): ([UInt8]?, QuickTakeCameraSession.EraseOutcome) in [
            ([0], .acknowledged), ([2], .rejected), (nil, .unconfirmed), ([6], .unconfirmed)
        ] {
            let port = ScriptedPort([read(1, reply)])
            let session = QuickTakeCameraSession(port: port)
            check(await session.eraseAll() == expected, "Kodak erase distinguishes completion, rejection and uncertainty: \(String(describing: reply))")
            check(await port.sent == [QuickTakeCommands.eraseAll()], "erase is sent exactly once")
        }
        do {
            // A real full-card erase outlasted the old eight-second budget.
            // Hold the transaction across that interval, including queued reads.
            let port = ScriptedPort([read(1, [0], delay: 9_000_000_000), read(1, [0]),
                                     read(128, [UInt8](repeating: 0, count: 128))])
            let session = QuickTakeCameraSession(port: port)
            let erase = Task { await session.eraseAll() }
            await waitForRead(1, on: port)
            let info = Task { await session.readDeviceInfo() }
            try? await Task.sleep(for: .milliseconds(20))
            check(await port.sent == [QuickTakeCommands.eraseAll()], "metadata waits for erase completion")
            check(await port.readTimeouts == [45], "erase has a bounded completion budget longer than eight seconds")
            check(await erase.value == .acknowledged, "delayed erase acknowledgement accepted")
            check(await info.value?.count == 128, "metadata follows erase acknowledgement")
            check(await port.sent == [QuickTakeCommands.eraseAll(), QuickTakeCommands.deviceInfo(), [6]],
                  "late erase status cannot shift metadata transaction")
        }
        do {
            let port = ScriptedPort([read(1, [6], delay: 100_000_000), read(1, [6])])
            let session = FujiCameraSession(port: port)
            let setting = Task { await session.setFlash(mode: 1) }
            await waitForRead(1, on: port)
            let ping = Task { await session.isResponding() }
            try? await Task.sleep(for: .milliseconds(20))
            check(await port.sent.count == 1, "Fuji ping waits for setting acknowledgement")
            check(await setting.value, "Fuji acknowledged setting succeeds")
            check(await ping.value, "Fuji queued ping succeeds")
        }
        do {
            let port = ScriptedPort([read(1, nil)])
            let session = FujiCameraSession(port: port)
            check(!(await session.capturePhoto()), "missing Fuji shutter acknowledgement fails")
            check(await port.sent.count == 1, "unconfirmed Fuji shutter is not fired again")
        }
        do {
            let port = ScriptedPort([])
            await port.failSends()
            let session = FujiCameraSession(port: port)
            check(!(await session.setFlash(mode: 0)), "failed Fuji write rejects command")
            check(await port.readCount == 0, "failed Fuji write never waits for a reply")
        }
        // MARK: - Fuji reply framing (parser hardening)
        do {
            // A literal 0x10 in the data must decode as one byte, not a
            // terminator lead-in, and a two-frame (ETB then ETX) reply
            // must join in order.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame([0x10, 0x05], term: 0x17)
                + fujiFrame([0x00], term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoCount() == 0x510,
                  "multi-frame reply with an embedded escaped-ESC byte decodes correctly")
            check(await port.sent.filter { $0 == [6] }.count == 2,
                  "each reply frame is ACKed once, intermediate and final")
        }
        do {
            // An unknown byte after ESC used to be silently treated as
            // ETB, and its checksum validated by construction. Now
            // rejected outright — the trailing checksum byte and a final
            // nil are drained, not read as a second frame.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame([1, 0], term: 0x99)
                + [read(1, nil)])
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoCount() == nil,
                  "a terminator that is neither escaped-ESC, ETX nor ETB is rejected")
        }
        do {
            // The common case: announced and actual length agree.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame(Array(repeating: 0x5A, count: 12), term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoJPEG(index: 0, expectedSize: 12)?.count == 12,
                  "a JPEG reply matching its announced PIC_SIZE exactly succeeds")
        }
        do {
            // No PIC_SIZE supplied — nothing to enforce.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame(Array(repeating: 0x5A, count: 12), term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoJPEG(index: 0, expectedSize: nil)?.count == 12,
                  "a JPEG reply with no announced size is accepted at whatever length it is")
        }
        do {
            // PIC_SIZE announced 10 bytes; the camera actually sent 2.
            let port = ScriptedPort([read(1, [6])] + fujiFrame([0xAA, 0xBB], term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoJPEG(index: 0, expectedSize: 10) == nil,
                  "a JPEG reply shorter than its announced PIC_SIZE is rejected, not returned truncated")
        }
        do {
            // PIC_SIZE announced 10 bytes; the camera actually sent 20.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame(Array(repeating: 0x42, count: 20), term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoJPEG(index: 0, expectedSize: 10) == nil,
                  "a JPEG reply longer than its announced PIC_SIZE is rejected, not silently accepted")
        }
        do {
            // Thumbnail's expectedSize (10_500 in production) is a
            // capacity/timing estimate, not an exact length — any size
            // must succeed.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame(Array(repeating: 0x11, count: 40), term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoThumbnail(index: 0)?.count == 40,
                  "a thumbnail reply is accepted regardless of its size estimate")
        }
        for size in [Int.max, -1] {
            // A corrupt/scrambled size must not become an oversized
            // allocation, and still correctly rejects the mismatch.
            let port = ScriptedPort([read(1, [6])] + fujiFrame([0xAA, 0xBB, 0xCC], term: 0x03))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoJPEG(index: 0, expectedSize: size) == nil,
                  "announced size \(size) is bounded for allocation and still rejects the mismatch")
        }
        do {
            // Checksum domain is learned per link; a fresh open must not
            // judge new frames against the old one's domain.
            let port = ScriptedPort([read(1, [6])]
                + fujiFrame([1, 0], term: 0x03, includeHeaderInChecksum: true)
                + [read(1, [6])]
                + fujiFrame([1, 0], term: 0x03, includeHeaderInChecksum: false))
            let session = FujiCameraSession(port: port)
            check(await session.readPhotoCount() == 1,
                  "first read locks the checksum domain from its own healthy frame")
            check(await session.open(path: "reopen"), "reopen succeeds")
            check(await session.readPhotoCount() == 1,
                  "a fresh open resets the learned checksum domain for the new link")
        }
        // MARK: - captureDiagnostics: reliability findings 1–3
        //
        // Command-frame byte 3 (after ESC STX 0x00) identifies the opcode
        // for every request `frame(cmd:payload:isLast:)` builds — see
        // `FujiCameraSession.frame`. Used below to find specific commands
        // (or their absence) in `port.sent` without needing access to the
        // session's private `Cmd` enum.
        func sentCmd(_ frame: [UInt8]) -> UInt8? { frame.count > 3 ? frame[3] : nil }

        do {
            // Finding 1: "Capture Camera Diagnostics" must never write the
            // camera clock — the clock section may only read it back
            // (DATE_GET 0x84), and must send no DATE_SET (0x86) frame.
            // Finding 2: the quality survey must clamp its per-photo walk
            // to the same 255-photo ceiling as the production metadata
            // path (QuickTakeSerialManager.fetchMetadata), not the raw
            // wire PIC_COUNT.
            //
            // Handshake + section E are scripted to fail fast (0 photos)
            // so the run stays focused on what's under test. The quality
            // survey's PIC_COUNT replies 65535; every per-photo probe
            // fails in a single read (an answer byte that is neither
            // ACK nor NAK, which `sendCommand` rejects immediately with
            // no retry). The baud-ramp section declines at every rung.
            let handshakeSection: [ScriptedPort.Read] = [read(1, nil)]
            let sectionE: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])]      // section E's own handshakeUnlocked: drain, ENQ→ACK
                + [read(1, nil)]                   // post-handshake drainAvailable
                + [read(1, nil), read(1, nil)]     // GetStatus 0x0C probe: pre-drain + timedDrain (∅)
                + [read(1, [0])]                   // section E's own PIC_COUNT fails → 0 photos, walk 0
            let picCount65535: [ScriptedPort.Read] = [read(1, [6])] + fujiFrame([0xFF, 0xFF], term: 0x03)
            let clampedPerPhoto = Array(repeating: read(1, [0]), count: 255 * 2)   // 255 × (name + size)
            let qualitySurvey: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])]       // survey's own handshakeUnlocked
                + [read(1, nil)]                    // post-handshake drainAvailable
                + picCount65535
                + clampedPerPhoto
            let clockProbe: [ScriptedPort.Read] = [read(1, [0])]   // DATE_GET fails
            let baudCheck = Array(repeating: read(1, nil), count: 21)   // pre-loop drain + 4 rungs × (switchSpeed + fujiPing)

            let port = ScriptedPort(handshakeSection + sectionE + qualitySurvey + clockProbe + baudCheck)
            let session = FujiCameraSession(port: port)
            let report = await session.captureDiagnostics()
            let sent = await port.sent

            check(!sent.contains { sentCmd($0) == 0x86 },
                  "Finding 1: captureDiagnostics sends no DATE_SET 0x86 frame")
            check(sent.filter({ sentCmd($0) == 0x0A }).count == 255,
                  "Finding 2: quality survey clamps PIC_NAME probes to 255 despite PIC_COUNT=65535")
            check(sent.filter({ sentCmd($0) == 0x17 }).count == 255,
                  "Finding 2: quality survey clamps PIC_SIZE probes to 255 despite PIC_COUNT=65535")
            check(!report.isEmpty, "captureDiagnostics still returns a report when every probe NAKs")
        }
        do {
            // Finding 2 (cancellation): once the capture task is cancelled
            // mid-survey, the loop must stop cleanly at the top of its next
            // iteration — no further per-photo probes, and the report notes
            // the cancellation.
            let handshakeSection: [ScriptedPort.Read] = [read(1, nil)]
            let sectionE: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])] + [read(1, nil)]
                + [read(1, nil), read(1, nil)] + [read(1, [0])]
            let picCount65535: [ScriptedPort.Read] = [read(1, [6])] + fujiFrame([0xFF, 0xFF], term: 0x03)
            let survey: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])] + [read(1, nil)] + picCount65535
                + [read(1, [0])]                                    // photo 0's PIC_NAME probe fails outright
                + [read(1, [0], delay: 50_000_000)]                  // photo 0's PIC_SIZE probe — cancel while this sleeps
            let baudCheck = Array(repeating: read(1, nil), count: 21)   // unaffected by cancellation (see report)

            let allReads = handshakeSection + sectionE + survey + baudCheck
            let port = ScriptedPort(allReads)
            let session = FujiCameraSession(port: port)
            let task = Task { await session.captureDiagnostics() }
            // Wait until photo 0's delayed PIC_SIZE read has been dequeued
            // (readCount increments the instant a read is popped, before its
            // delay elapses), then cancel while it is still "in flight".
            await waitForRead(handshakeSection.count + sectionE.count + survey.count, on: port)
            task.cancel()
            let report = await task.value
            let sent = await port.sent

            check(sent.filter({ sentCmd($0) == 0x0A }).count == 1,
                  "cancelling mid-survey lets the in-flight photo's PIC_NAME probe finish")
            check(sent.filter({ sentCmd($0) == 0x17 }).count == 1,
                  "cancelling mid-survey lets the in-flight photo's PIC_SIZE probe finish, then stops")
            check(!sent.contains { sentCmd($0) == 0x84 },
                  "a cancelled capture sends no further commands (clock probe skipped)")
            check(report.contains("Cancelled"), "the report notes the cancellation")
        }
        do {
            // Finding 3: if the live session was already ramped to a faster
            // negotiated baud before "Capture Diagnostics" ran, that rate
            // must be restored when the routine finishes, not left at 9600.
            // `switchSpeed`'s wire choreography (SPEED frame → ACK → drain
            // any reply → EOT → host reconfigure → settle → fujiPing) is
            // exercised as-is; nothing about its bytes/timing is touched.
            // `receiveCompleteReply` bailing on no reply frame costs TWO reads,
            // not one: `receiveFrame`'s ESC-STX hunt gets a nil and returns,
            // then (since nothing streamed yet) `abortIfStreaming` drains
            // once more before giving up.
            let negotiateToFast: [ScriptedPort.Read] =
                [read(1, nil)]      // negotiateFastestBaudUnlocked's pre-loop drain
                + [read(1, [6])]     // SPEED frame ACK
                + [read(1, nil), read(1, nil)]   // receiveCompleteReply bails: hunt, then abortIfStreaming's drain
                + [read(1, nil)]     // fujiPing: drain
                + [read(1, [6])]     // fujiPing: ENQ → ACK, ramp confirmed
            let resetAtCaptureStart: [ScriptedPort.Read] =
                [read(1, [6])]     // SPEED(0) frame ACK
                + [read(1, nil), read(1, nil)]    // receiveCompleteReply bail (verify:false skips fujiPing)
            let handshakeSection: [ScriptedPort.Read] = [read(1, nil)]
            let sectionE: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])] + [read(1, nil)]
                + [read(1, nil), read(1, nil)] + [read(1, [0])]
            let quickSurvey: [ScriptedPort.Read] =
                [read(1, nil), read(1, [6])] + [read(1, nil)] + [read(1, [0])]   // PIC_COUNT fails → "No photos"
            let clockProbe: [ScriptedPort.Read] = [read(1, [0])]
            let baudCheckDecline = Array(repeating: read(1, nil), count: 21)   // pre-loop drain + 4 rungs × (switchSpeed + fujiPing)

            let allReads = negotiateToFast + resetAtCaptureStart + handshakeSection + sectionE
                + quickSurvey + clockProbe + baudCheckDecline + negotiateToFast
            let port = ScriptedPort(allReads)
            let session = FujiCameraSession(port: port)

            check(await session.negotiateFastestBaud() == 115200,
                  "pre-capture negotiation ramps to 115200")
            let report = await session.captureDiagnostics()
            let configurations = await port.configurations

            check(configurations.last == 115200,
                  "Finding 3: captureDiagnostics restores the pre-capture 115200 baud instead of stranding the link at 9600")
            check(report.contains("Restored the pre-capture 115200 baud link"),
                  "the report notes the restored baud")
        }
        print("ALL \(passed) CHECKS PASSED")
    }
}
