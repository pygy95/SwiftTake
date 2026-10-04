// MARK: - QuickTakeCameraSession
//
// The QuickTake 100 / 150 serial conversation, layered on the generic
// `SerialPort`. It owns the wake + handshake and the request/response
// choreography that the camera dictates:
//
//     send command → read the 1-byte status reply → (for data commands)
//     send our ACK → read the payload
//
// Bulk payloads (thumbnails, full images) arrive in 512-byte runs, each
// of which we acknowledge before the next is sent. The choreography lives
// here, once, instead of being repeated per operation.
//
// Domain methods return raw payload bytes (or a success flag); turning
// those bytes into camera state, photos, and UI is the manager's job —
// this layer only knows the wire.
//
// Isolation: this type runs on the main actor, but all its work is at
// `await` suspension points rather than blocking calls, so it never
// stalls the UI. The blocking termios syscalls are quarantined inside
// the `SerialPort` actor, which runs off the main thread.

import Foundation

@MainActor
final class QuickTakeCameraSession {

    /// Line speed to settle on after the handshake.
    enum LineSpeed {
        case standard   // stay at 9600
        case fast       // ramp to 57600
    }

    private let port: any QuickTakeTransport

    init(port: any QuickTakeTransport = SerialPort()) {
        self.port = port
    }

    // Actor isolation protects state, not a conversation across await points.
    // Each wire transaction holds this FIFO gate through its final reply.
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireTransaction() async -> Bool {
        guard !Task.isCancelled else { return false }
        if transactionActive {
            await withCheckedContinuation { transactionWaiters.append($0) }
        } else {
            transactionActive = true
        }
        guard !Task.isCancelled else {
            releaseTransaction()
            return false
        }
        return true
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionActive = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }

    /// Byte 3 of the camera's wake burst, captured during `handshake`.
    /// Identifies the model at the FIRMWARE level: 0xC8 = QT150, anything
    /// else = QT100. nil until a handshake has seen a burst.
    ///
    /// Verified on a real QT150. The QT100 value (0x01, in the burst
    /// A5 5A 01 01 01 00 02) comes from Colin Leroy's protocol write-up and
    /// a real QT100 of his — NOT from ours: the body on this bench turned
    /// out to be a QuickTake 100 **Plus** with its model sticker missing.
    ///
    /// There are three bodies, not two, and the Plus's byte has never been
    /// recorded by anyone. Testing `== 0xC8` and defaulting everything else
    /// to the QT100 path is therefore deliberate rather than lazy: an
    /// unknown Plus lands on the QT100 image path, which is where it
    /// belongs. Testing `== 0x01` instead would strand it. Both other
    /// implementations (JQuickTake, a2tools) take the same shape for the
    /// same reason.
    private(set) var wakeModelByte: UInt8?

    /// What the wake byte actually says, rather than what it isn't.
    ///
    /// The detection used to read `wake == 0xC8 ? .qt150 : .qt100`, which
    /// says "not a 150" where it means "is a 100" — so a byte nobody has
    /// seen before was absorbed silently and looked exactly like a
    /// confirmed QuickTake 100. Naming the two known values makes the
    /// third case a thing that happened rather than a fallthrough.
    ///
    /// `unrecognised` still runs on the QuickTake 100 image path. That is
    /// the safe landing: the bodies in this family that aren't 150s take
    /// 100-shaped pictures, so an unknown one belongs there. The point of
    /// the case is that it gets SAID.
    enum WakeIdentity: Equatable {
        case quickTake100          // 0x01
        case quickTake150          // 0xC8
        case unrecognised(UInt8)

        init(byte: UInt8) {
            switch byte {
            case 0xC8: self = .quickTake150
            case 0x01: self = .quickTake100
            default:   self = .unrecognised(byte)
            }
        }

        /// The model to drive the wire and the decoder with.
        var model: QuickTakeModel {
            self == .quickTake150 ? .qt150 : .qt100
        }

        /// True when this is a guess rather than a reading. Callers that
        /// persist the identity should not treat a guess as proven.
        var isKnown: Bool {
            if case .unrecognised = self { return false }
            return true
        }

        var describedForLog: String {
            switch self {
            case .quickTake100:      return "QT100"
            case .quickTake150:      return "QT150"
            case .unrecognised(let b):
                return String(format: "UNRECOGNISED 0x%02X — using the QT100 path", b)
            }
        }
    }

    /// The wake byte, classified. nil when no aligned burst was seen.
    var wakeIdentity: WakeIdentity? {
        guard let wakeModelByte else { return nil }
        return WakeIdentity(byte: wakeModelByte)
    }

    // Camera response timings, in seconds.
    private static let statusTimeout: TimeInterval = 2
    private static let chunkTimeout: TimeInterval = 2
    private static let chunkSize = 512

    // MARK: Connection

    /// Open `path`, wake the camera, and run the handshake, finishing at
    /// the requested speed. Returns true once the camera is responding.
    /// Open the port at 9600 8N1 (the camera's initial speed). Returns
    /// false if the device node can't be opened.
    func open(path: String) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        wakeModelByte = nil
        do {
            try await port.open(path: path, baud: 9600, parity: .none)
            QTLog.note("PORT", "opened", detail: "\(path) @9600 8N1")
            return true
        } catch {
            QTLog.note("PORT", "OPEN FAILED", detail: "\(path): \(error)")
            NSLog("[QuickTakeCameraSession] couldn't open %@: %@", path, String(describing: error))
            return false
        }
    }

    func disconnect() async {
        // Closing is ordered after any in-flight transaction, even when the
        // caller is cancelled. A queued cancelled command never touches the wire.
        if transactionActive {
            await withCheckedContinuation { transactionWaiters.append($0) }
        } else {
            transactionActive = true
        }
        defer { releaseTransaction() }
        wakeModelByte = nil
        await port.close()
    }

    /// Wake the camera and run the handshake, settling at `speed`. Call
    /// after `open(path:)`; returns true once the camera responds.
    ///
    /// `assumeAwake` is the existing detection fallback for a camera that
    /// has already emitted its wake burst. It cannot establish model identity.
    func handshake(speed: LineSpeed, assumeAwake: Bool = false) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        wakeModelByte = nil
        await port.setDTR(false)

        if !assumeAwake {
            // Read one byte at a time under one deadline: receive(7) used to
            // consume and discard partial bursts on each short timeout.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            var wake = QuickTakeWakeBuffer()
            var burst: [UInt8]?
            while !Task.isCancelled, clock.now < deadline {
                let remaining = clock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1e18
                guard let byte = await port.receive(1, timeout: seconds)?.first else { break }
                if let packet = wake.append(byte) {
                    burst = packet
                    break
                }
            }
            guard let burst else {
                QTLog.note("WAKE", "NO COMPLETE BURST", detail:
                    "waiting for A5 5A + 5 bytes; discarded \(wake.discardedBytes) leading bytes")
                return false
            }
            wakeModelByte = burst[3]
            QTLog.note("WAKE", "aligned burst received", bytes: burst)
            QTLog.note("WAKE", "model byte", detail:
                "\(WakeIdentity(byte: burst[3]).describedForLog); discarded \(wake.discardedBytes) leading bytes")
            let extra = await port.drain(idleFor: 0.15, limit: 1)
            if extra > 0 {
                QTLog.note("WAKE", "cleared post-burst chatter", detail: "\(extra) bytes")
            }
        }
        guard !Task.isCancelled else { return false }

        let baud = (speed == .fast) ? 57600 : 9600

        // Identify + advertise the session speed (the open packet's bytes
        // 6–7/12 encode it), then move to the 8E1 framing the camera uses
        // for the rest of the session.
        QTLog.note("HANDSHAKE", "open packet", bytes: QuickTakeCommands.open(baud: baud))
        guard await port.send(QuickTakeCommands.open(baud: baud)) else { return false }
        let openReply = await port.receive(10, timeout: Self.statusTimeout)
        QTLog.note("HANDSHAKE", "open reply", bytes: openReply ?? [])

        guard openReply?.count == 10 else {
            QTLog.note("HANDSHAKE", "incomplete open reply")
            return false
        }
        do {
            try await port.reconfigure(baud: 9600, parity: .even)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            QTLog.note("HANDSHAKE", "parity change interrupted or failed", detail: "\(error)")
            return false
        }

        guard await issueUnlocked(QuickTakeCommands.ping()) else { return false }

        // Speed negotiation ALWAYS runs — the QT100-verified flow sends the
        // port-speed command even when staying at 9600, matching what the
        // open packet advertised. The 57600 path's bytes are the
        // hardware-verified QT150 sequence; the reconfigure at 9600 is a
        // no-op re-apply of the same line settings.
        guard await issueUnlocked(QuickTakeCommands.selectBaud(baud)) else { return false }
        guard await port.send(QuickTakeCommands.acknowledge()) else { return false }

        do {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await port.reconfigure(baud: baud, parity: .even)
        } catch {
            QTLog.note("HANDSHAKE", "baud change interrupted or failed", detail: "\(error)")
            return false
        }

        // The protocol reference recommends discarding baud-change filler
        // until the line is quiet, rather than requiring exactly 1024 bytes.
        // The FTDI/QT150 trace shows the filler starting after a 200 ms
        // quiet gap. Wait 500 ms of silence before the closing ACK; an
        // earlier ACK can be ignored while the camera is still sending.
        let flood = await port.drain(idleFor: 0.5, limit: 5)
        QTLog.note("HANDSHAKE", "drained across baud change",
                   detail: "\(flood) bytes")
        guard await finalizeSpeedChange() else { return false }
        do { try await Task.sleep(nanoseconds: 100_000_000) }
        catch { return false }
        return true
    }

    /// Requires the final speed-change status, tolerating delayed `0xAA` filler.
    /// The quiet-interval drain can finish before this filler reaches the host.
    /// Send one ACK and bound the reply by both elapsed time and filler count;
    /// ordinary command replies remain strict. See the QT150 serial review.
    private func finalizeSpeedChange() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await port.send(QuickTakeCommands.acknowledge()) else { return false }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        let fillerCap = 1024
        var skippedFiller = 0

        while true {
            guard !Task.isCancelled else {
                QTLog.note("HANDSHAKE", "final speed ACK cancelled",
                           detail: "after \(skippedFiller) AA filler byte(s)")
                return false
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                QTLog.note("HANDSHAKE", "final speed ACK deadline",
                           detail: "no status within 2s; skipped \(skippedFiller) AA filler byte(s)")
                return false
            }
            let seconds = Double(remaining.components.seconds)
                + Double(remaining.components.attoseconds) / 1e18
            guard let byte = await port.receive(1, timeout: seconds)?.first else {
                QTLog.note("HANDSHAKE", "final speed ACK no byte",
                           detail: "nil read after \(skippedFiller) AA filler byte(s)")
                return false
            }
            if byte == 0xAA {
                skippedFiller += 1
                if skippedFiller > fillerCap {
                    QTLog.note("HANDSHAKE", "final speed ACK filler overrun",
                               detail: "more than \(fillerCap) AA filler bytes with no status")
                    return false
                }
                continue
            }
            let accepted = (byte == 0x00) && !Task.isCancelled && clock.now < deadline
            QTLog.note("HANDSHAKE",
                       accepted ? "final speed ACK accepted" : "final speed ACK rejected",
                       detail: String(format: "status 0x%02X after %d AA filler byte(s)",
                                      byte, skippedFiller))
            return accepted
        }
    }

    /// Use the protocol's no-op ping for liveness, not a transfer ACK.
    func isResponding(timeout: TimeInterval = 0.5) async -> Bool {
        await issue(QuickTakeCommands.ping(), timeout: timeout)
    }

    // MARK: Reads

    /// 128-byte device-info block (battery, frame counts, flash, name…).
    func readDeviceInfo() async -> [UInt8]? {
        await fetchFixed(QuickTakeCommands.deviceInfo(), length: 128)
    }

    /// 64-byte per-photo header (carries the capture timestamp).
    func readPhotoHeader(index: UInt8) async -> [UInt8]? {
        await fetchFixed(QuickTakeCommands.photoHeader(index: index), length: 64)
    }

    /// Fixed 2400-byte thumbnail.
    func readThumbnail(index: UInt8) async -> [UInt8]? {
        await fetchStream(QuickTakeCommands.thumbnail(index: index), total: 2400)
    }

    /// Full image. `sizeField` is the 3-byte length echoed in the request
    /// (taken from the photo header); `byteCount` is how many bytes come
    /// back.
    func readPhoto(
        index: UInt8,
        byteCount: Int,
        sizeField: [UInt8],
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        guard sizeField.count == 3, byteCount > 0,
              byteCount == (Int(sizeField[0]) << 16 | Int(sizeField[1]) << 8 | Int(sizeField[2]))
        else { return nil }
        return await fetchStream(
            QuickTakeCommands.photo(index: index, sizeField: sizeField),
            total: byteCount,
            progress: progress
        )
    }

    // MARK: Control (true once the camera acknowledges)

    @discardableResult func setFlash(mode: UInt8) async -> Bool {
        await issue(QuickTakeCommands.setFlash(mode: mode))
    }

    @discardableResult func setQuality(high: Bool) async -> Bool {
        await issue(QuickTakeCommands.setQuality(high: high))
    }

    @discardableResult func capturePhoto() async -> Bool {
        await issue(QuickTakeCommands.capture(), timeout: 10)
    }

    enum EraseOutcome { case acknowledged, rejected, unconfirmed }

    /// A full QT150 erase can outlast eight seconds. Keep ownership of the
    /// wire until its completion reply; an early metadata request can consume
    /// the late erase status and shift the following device-info payload.
    func eraseAll() async -> EraseOutcome {
        guard await acquireTransaction() else { return .unconfirmed }
        defer { releaseTransaction() }
        guard await port.send(QuickTakeCommands.eraseAll()) else { return .unconfirmed }
        let reply = await port.receive(1, timeout: 45)
        guard !Task.isCancelled else { return .unconfirmed }
        QTLog.note("ERASE", "completion status", bytes: reply ?? [])
        switch reply {
        case [0x00]: return .acknowledged
        case [0x02]: return .rejected
        default: return .unconfirmed
        }
    }

    @discardableResult func setName(_ ascii: [UInt8]) async -> Bool {
        await issue(QuickTakeCommands.setName(ascii))
    }

    @discardableResult func setClock(_ dateTime: [UInt8]) async -> Bool {
        await issue(QuickTakeCommands.setClock(dateTime))
    }

    // MARK: Choreography

    /// Send a command and wait for the camera's one-byte status reply.
    @discardableResult
    private func issue(_ command: [UInt8], timeout: TimeInterval = 2) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await issueUnlocked(command, timeout: timeout)
    }

    /// Caller owns the transaction gate. Camera success is 0x00; 0x06 is
    /// the host ACK. Reject 0x02 (command error) and unexpected/stale bytes.
    private func issueUnlocked(_ command: [UInt8], timeout: TimeInterval = 2) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await port.send(command) else { return false }
        let reply = await port.receive(1, timeout: timeout)
        guard reply == [0x00] else {
            QTLog.note("COMMAND", "failed", bytes: command)
            QTLog.note("COMMAND", reply == [0x02] ? "camera rejected command" : "missing or unexpected status",
                       bytes: reply ?? [])
            return false
        }
        return !Task.isCancelled
    }

    /// command → status byte → our ACK → fixed-length payload.
    private func fetchFixed(_ command: [UInt8], length: Int) async -> [UInt8]? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        guard await issueUnlocked(command) else { return nil }
        guard await port.send(QuickTakeCommands.acknowledge()) else { return nil }
        return await port.receive(length, timeout: Self.statusTimeout)
    }

    /// command → status byte → our ACK → `total` bytes pulled in
    /// `chunkSize` runs, acknowledging each run.
    private func fetchStream(
        _ command: [UInt8],
        total: Int,
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        guard await issueUnlocked(command) else { return nil }
        guard await port.send(QuickTakeCommands.acknowledge()) else { return nil }

        var buffer = [UInt8]()
        buffer.reserveCapacity(total)
        while buffer.count < total {
            let want = min(Self.chunkSize, total - buffer.count)
            guard !Task.isCancelled,
                  let run = await port.receive(want, timeout: Self.chunkTimeout) else {
                QTLog.note("TRANSFER", "incomplete stream", detail:
                    "received \(buffer.count) complete bytes of \(total); next block \(want)")
                break
            }
            buffer.append(contentsOf: run)
            progress?(Double(buffer.count) / Double(total))
            if buffer.count < total {
                guard await port.send(QuickTakeCommands.acknowledge()) else { return nil }
            }
        }
        return buffer.count == total ? buffer : nil
    }

    // MARK: Diagnostics

    /// Probe the connected QuickTake 100/150 and return a copy-pasteable
    /// report: liveness, the 128-byte device-info block (parsed name / counts
    /// / flash), the first photo's 64-byte header, and a post-probe liveness
    /// check. The caller must have `open`ed + `handshake`d already; this
    /// leaves the link untouched.
    func captureDiagnostics() async -> String {
        var out = DiagReport()
        out.title("SwiftTake — QuickTake 100/150 (Kodak) diagnostic capture")
        out.line("Each command: send → 1-byte status → ACK → fixed payload.")

        out.section("A. LIVENESS")
        let aliveBefore = await isResponding(timeout: 1.0)
        out.line(aliveBefore ? "Camera answered the ping — link awake." : "No valid answer to the ping.")
        if let wake = wakeModelByte {
            // The whole burst, verbatim. The decoded name is the app's
            // reading; the bytes are the evidence, and for a body nobody
            // has recorded they are the only part worth having.
            out.line(String(format: "Wake-burst model byte [3] = 0x%02X → %@",
                            wake, WakeIdentity(byte: wake).describedForLog))
            out.line("  known values: 0x01 = QuickTake 100, 0xC8 = QuickTake 150")
        }

        out.section("B. DEVICE INFO  (128-byte block)")
        if let info = await readDeviceInfo() {
            out.reply(label: "deviceInfo", bytes: info)
            if info.count > 78 {
                let name = String(bytes: info[47..<79], encoding: .ascii)?
                    .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? ""
                out.line("  name      [47..79] = \"\(name)\"")
            }
            if info.count > 6 {
                out.line("  battery   [2]      = \(info[2])")
                out.line("  taken     [4]      = \(info[4])")
                out.line("  remaining [6]      = \(info[6])")
            }
            if info.count > 27 {
                out.line("  flash     [22]     = \(info[22])")
                out.line("  quality   [27]     = 0x\(String(format: "%02X", info[27])) (0x10=HQ 0x20=SQ)")
            }
        } else {
            out.line("∅ no device-info reply.")
        }

        out.section("C. PHOTO[0] HEADER  (64-byte block)")
        if let header = await readPhotoHeader(index: 0) {
            out.reply(label: "photoHeader[0]", bytes: header)
            if header.count > 24 {
                out.line("  quality byte [24] = 0x\(String(format: "%02X", header[24])) (0x10=HQ 0x20=SQ)")
            }
        } else {
            out.line("∅ no photo-header reply (no photos, or no answer).")
        }

        out.section("D. LIVENESS AFTER")
        let aliveAfter = await isResponding(timeout: 1.0)
        out.line(aliveAfter ? "Still awake." : "✗ No answer — link may have dropped.")

        out.rule()
        out.line("End of capture.")
        return out.text
    }
}
