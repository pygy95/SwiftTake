// MARK: - FujiCameraSession
//
// The Fujifilm serial conversation, layered on the generic `SerialPort`.
// Parallel to `QuickTakeCameraSession` (the Kodak side) and serves the
// whole Fuji-family lineup — QuickTake 200, Fujifilm DS-7, Samsung Kenox
// SSC-350N — which all speak the same wire dialect.
//
// ───────────────────────────────────────────────────────────────────
// Wire protocol for the Fujifilm serial family (QT200 / DS-7 / Kenox).
// ───────────────────────────────────────────────────────────────────
//   Serial:   9600 8E1 to start. The camera advertises its max baud
//             code via VERSION/CMDS_VALID; the host renegotiates with
//             SPEED (0x07). See `negotiateFastestBaud`.
//
//   Framing:
//       ┌─────────┬─────────┬──────────────┬─────────┬───────┐
//       │ ESC STX │  cmd    │   payload    │ ESC end │ check │
//       │ 10 02   │  1 B    │   n B        │ 10 03   │ 1 B   │
//       └─────────┴─────────┴──────────────┴─────────┴───────┘
//     `end` = ETX (0x03) for the final frame of a reply, or ETB (0x17)
//     for an intermediate one (used during bulk JPEG transfer to chunk
//     the response). The checksum is the XOR of every byte between the
//     opening ESC STX and the closing ESC, seeded with the terminator
//     byte itself.
//
//   Escape: any 0x10 byte inside cmd+payload is doubled to 0x10 0x10.
//     (`ESC` and `DLE` are two names for that same byte; one is used here.)
//
//   ACK/NAK exchange:
//     • Host sends a request frame; camera answers ACK (0x06) — or NAK
//       (0x15) on a bad checksum, in which case the host retransmits
//       (two retries before giving up).
//     • Reply frames carry the data; the host ACKs each one, and the
//       camera follows up with another ETB-terminated frame or finishes
//       with an ETX-terminated one.
//     • EOT (0x04) sent raw, outside any frame, tears the link down.
//
//   Handshake: host writes ENQ (0x05) raw and expects ACK (0x06) back.
//
// Implemented end-to-end: connect, handshake, list (count/name/size),
// download JPEG, thumbnail, erase, plus the control commands with
// confirmed codes (flash set, remote shutter, camera ID, clock).
// Quality toggle has no documented opcode in the Fuji family enum — stubbed.
// Decoding decisions not yet confirmed on hardware are flagged inline as
// `HARDWARE-VERIFY`.

import Foundation

@MainActor
final class FujiCameraSession {

    /// Speed hint, accepted only for API parity with
    /// `QuickTakeCameraSession`. Fuji renegotiates its own line speed via
    /// `negotiateFastestBaud`, so this value is advisory.
    enum LineSpeed { case standard, fast }

    private let port: any QuickTakeTransport

    init(port: any QuickTakeTransport = SerialPort()) { self.port = port }


    // Hold the wire for the entire public operation, including every reply
    // frame and speed change. Actor isolation alone cannot span awaits.
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireTransaction(cleanup: Bool = false) async -> Bool {
        guard cleanup || !Task.isCancelled else { return false }
        if transactionActive {
            await withCheckedContinuation { transactionWaiters.append($0) }
        } else { transactionActive = true }
        guard cleanup || !Task.isCancelled else {
            releaseTransaction()
            return false
        }
        return true
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty { transactionActive = false }
        else { transactionWaiters.removeFirst().resume() }
    }

    @discardableResult
    func open(path: String, baud: Int = 9600) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await openUnlocked(path: path, baud: baud)
    }

    func disconnect() async {
        guard await acquireTransaction(cleanup: true) else { return }
        defer { releaseTransaction() }
        await disconnectUnlocked()
    }

    @discardableResult
    func handshake(speed: LineSpeed = .standard) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await handshakeUnlocked(speed: speed)
    }

    @discardableResult
    func isResponding(timeout: TimeInterval = probeTimeout) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await isRespondingUnlocked(timeout: timeout)
    }

    @discardableResult
    func negotiateFastestBaud() async -> Int {
        guard await acquireTransaction() else { return 9600 }
        defer { releaseTransaction() }
        return await negotiateFastestBaudUnlocked()
    }

    func resetToStandardSpeed() async {
        guard await acquireTransaction() else { return }
        defer { releaseTransaction() }
        await resetToStandardSpeedUnlocked()
    }

    @discardableResult
    func recoverFromStaleBaud() async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await recoverFromStaleBaudUnlocked()
    }

    func readModelString() async -> String? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readModelStringUnlocked()
    }

    func readFirmwareVersion() async -> String? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readFirmwareVersionUnlocked()
    }

    func readPhotoCount() async -> Int? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readPhotoCountUnlocked()
    }

    func readAvailableMemory() async -> Int? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readAvailableMemoryUnlocked()
    }

    func readFlashMode() async -> UInt8? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readFlashModeUnlocked()
    }

    func readPhotoName(index: Int) async -> String? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readPhotoNameUnlocked(index: index)
    }

    func readPhotoSize(index: Int) async -> Int? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readPhotoSizeUnlocked(index: index)
    }

    func readPhotoJPEG(
        index: Int,
        expectedSize: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readPhotoJPEGUnlocked(index: index, expectedSize: expectedSize, progress: progress)
    }

    func readPhotoThumbnail(index: Int) async -> [UInt8]? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readPhotoThumbnailUnlocked(index: index)
    }

    @discardableResult
    func eraseImage(named filename: String) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await eraseImageUnlocked(named: filename)
    }

    @discardableResult
    func eraseAll() async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await eraseAllUnlocked()
    }

    @discardableResult
    func setFlash(mode: UInt8) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await setFlashUnlocked(mode: mode)
    }

    @discardableResult
    func setQuality(high: Bool) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await setQualityUnlocked(high: high)
    }

    @discardableResult
    func setName(_ ascii: [UInt8]) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await setNameUnlocked(ascii)
    }

    @discardableResult
    func setClock(year: Int, month: Int, day: Int,
                  hour: Int, minute: Int, second: Int) async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await setClockUnlocked(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    func readClock() async -> (year: Int, month: Int, day: Int,
                               hour: Int, minute: Int, second: Int)? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        return await readClockUnlocked()
    }

    @discardableResult
    func capturePhoto() async -> Bool {
        guard await acquireTransaction() else { return false }
        defer { releaseTransaction() }
        return await capturePhotoUnlocked()
    }

    func captureDiagnostics() async -> String {
        guard await acquireTransaction() else { return "Cancelled" }
        defer { releaseTransaction() }
        return await captureDiagnosticsUnlocked()
    }

    /// Editable ID is separate from MODEL, which identifies the camera body.
    func readCameraName() async -> String? {
        guard await acquireTransaction() else { return nil }
        defer { releaseTransaction() }
        guard let bytes = await sendCommand(.idGet, payload: [], expectReply: true) else { return nil }
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    // MARK: Wire constants

    private static let esc: UInt8 = 0x10
    private static let stx: UInt8 = 0x02
    private static let etx: UInt8 = 0x03   // terminator of the FINAL frame
    private static let etb: UInt8 = 0x17   // terminator of an INTERMEDIATE frame
    private static let ack: UInt8 = 0x06
    private static let nak: UInt8 = 0x15
    private static let eot: UInt8 = 0x04   // out-of-band teardown
    private static let enq: UInt8 = 0x05   // out-of-band handshake probe

    /// Inner command codes for the Fuji serial family.
    private enum Cmd: UInt8 {
        case picGetThumb = 0x00   // small per-photo preview
        case picGet      = 0x02   // full JPEG
        case speed       = 0x07   // re-negotiate baud
        case version     = 0x09   // firmware version string
        case picName     = 0x0A   // DSC*.JPG filename for one index
        case picCount    = 0x0B   // total photos on the card
        case picSize     = 0x17   // byte length of one file
        case picDel      = 0x19   // erase one photo
        case availMem    = 0x1B   // free space on card
        case take        = 0x27   // remote shutter (DS-7/Kenox; QT200 may decline)
        case model       = 0x29   // camera model string
        case flashGet    = 0x30
        case flashSet    = 0x32
        case flashCharge = 0x34
        case cmdsValid   = 0x4C   // list of commands this body supports
        case preview     = 0x64   // live preview frame
        case idGet       = 0x80   // camera name
        case idSet       = 0x82
        case dateGet     = 0x84
        case dateSet     = 0x86
    }

    // MARK: Timings (seconds)

    // `nonisolated` so they can serve as default argument values (evaluated in
    // the caller's nonisolated context) — they're immutable constants.
    private nonisolated static let statusTimeout: TimeInterval = 2
    private static let bulkTimeout: TimeInterval = 60
    private nonisolated static let probeTimeout: TimeInterval = 0.5
    private static let maxRetries = 2

    /// Per-frame idle budget for a multi-frame reply: each frame must START
    /// arriving within this window of the previous one. It RESETS every frame,
    /// so a long-but-progressing JPEG transfer never trips a stale global
    /// deadline — only a genuinely stalled camera does.
    private static let frameIdleTimeout: TimeInterval = 8

    /// Conservative goodput at 9600 8E1 after framing + per-frame ACK round
    /// trips (well under the 960 B/s raw rate). Used to size the OVERALL
    /// transfer ceiling so it can't expire before a healthy transfer finishes.
    private static let bytesPerSecondFloor: Double = 700

    /// Plausible ceiling for one Fuji-family transfer (a QT200 frame is
    /// 640×480). Bounds the capacity hint against a corrupt announced size
    /// — never used to reject a real transfer.
    private static let maxPlausibleTransferBytes = 512_000

    // MARK: Connection

    /// Open the port at `baud` 8E1 (default 9600 — the Fuji family's
    /// initial line state).
    private func openUnlocked(path: String, baud: Int = 9600) async -> Bool {
        do {
            try await port.open(path: path, baud: baud, parity: .even)
            // A fresh open is a new link, not a continuation of the last
            // one: reset what was LEARNED on the previous connection
            // (checksum domain, its log budget) and the baud bookkeeping,
            // which is now simply `baud`.
            lockedChecksumDomain = nil
            checksumDomainLogged = false
            checksumLogBudget = Self.checksumLogBudgetCap
            currentBaud = baud
            return true
        } catch {
            NSLog("[FujiCameraSession] couldn't open %@: %@", path, String(describing: error))
            return false
        }
    }


    /// Put the camera back to 9600 (if ramped up), send EOT, then close — so
    /// the next connect, which opens at 9600, can reach it again.
    private func disconnectUnlocked() async {
        await resetToStandardSpeedUnlocked()
        await port.send([Self.eot])
        await port.close()
    }

    /// Wake the camera. Writes ENQ raw and expects a single ACK reply within
    /// five attempts — the standard ping shape. Always at 9600; the
    /// fast-baud ramp is a separate post-wake step (`negotiateFastestBaud`).
    /// `speed` is kept only for call-site parity with the Kodak session.
    private func handshakeUnlocked(speed: LineSpeed = .standard) async -> Bool {
        _ = speed
        // Drain stale bytes first: a cold USB-serial open (the adapter needs a
        // moment to settle) or a preceding probe of another family can leave
        // junk in the buffer, so the first byte read isn't a genuine reply to
        // the ENQ. Drain, then ENQ up to 5× and drain any non-ACK reply
        // between tries.
        _ = await drainAvailable(idleGap: 0.15, maxWait: 0.4)
        for _ in 0..<5 {
            guard await port.send([Self.enq]) else { return false }
            if let reply = await port.receive(1, timeout: Self.statusTimeout)?.first,
               reply == Self.ack {
                return true
            }
            _ = await drainAvailable(idleGap: 0.1, maxWait: 0.2)
        }
        return false
    }

    /// Liveness probe — same shape as `handshake`, short default timeout.
    private func isRespondingUnlocked(timeout: TimeInterval = probeTimeout) async -> Bool {
        guard await port.send([Self.enq]) else { return false }
        guard let reply = await port.receive(1, timeout: timeout)?.first else { return false }
        return reply == Self.ack
    }

    // MARK: - Baud ramp

    /// Ramp the line to the fastest verified rate. For each rate high→low:
    ///   1. send the SPEED command — its inner buffer is
    ///      `[0x01, 0x07, 0x01, 0x00, code]`. The leading 0x01 matters: every
    ///      other Fuji command uses `cmd[0]=0`, but SPEED uses `cmd[0]=1`.
    ///      A 0x00 there is ACK'd but never actually switches.
    ///   2. `fuji_reset` → send a raw EOT (0x04). This commits the switch
    ///      (it does NOT drop to 9600 here — that's a separate post_func step).
    ///   3. reconfigure the HOST port to the new rate.
    ///   4. `fuji_ping` at the new rate (drain, then ENQ) to confirm.
    /// On failure at a rung, fall back to 9600 and try the next. Returns the
    /// baud actually in use.
    /// The line rate the camera is currently running at. Tracked so it can be
    /// put back to 9600 on disconnect — otherwise a
    /// camera left at 115200 won't answer the next connect, which opens at 9600.
    private var currentBaud = 9600

    @discardableResult
    private func negotiateFastestBaudUnlocked() async -> Int {
        // Speed codes for the QT200:
        // 8=115200, 7=57600, 6=38400, 5=28800, 4=19200. Note 19200 is code 4
        // here, not the DS-7 sibling's 5.
        let ladder: [(code: UInt8, baud: Int)] = [(8, 115200), (7, 57600), (6, 38400), (4, 19200)]
        _ = await drainAvailable(idleGap: 0.2, maxWait: 0.4)

        for cand in ladder {
            if await switchSpeed(code: cand.code, toBaud: cand.baud, verify: true) {
                currentBaud = cand.baud
                return cand.baud
            }
            // Didn't take — restore 9600, resync, try the next rung.
            try? await port.reconfigure(baud: 9600, parity: .even)
            _ = await fujiPing()
        }
        try? await port.reconfigure(baud: 9600, parity: .even)
        currentBaud = 9600
        return 9600
    }

    /// Put the camera (and host port) back to 9600 if it was ramped up — the
    /// Disconnect cleanup: put the camera back to 9600 so the next connect
    /// (which opens at 9600) can reach it.
    private func resetToStandardSpeedUnlocked() async {
        guard currentBaud != 9600 else { return }
        _ = await switchSpeed(code: 0, toBaud: 9600, verify: false)   // FUJI_SPEED_9600 = 0
        currentBaud = 9600
    }

    /// One SPEED switch — the command followed by the host port swap:
    /// send SPEED `[0x01, 0x07, 0x01, 0x00, code]` → consume/ACK the reply →
    /// `fuji_reset` (EOT) → reconfigure the host port → optionally `fuji_ping`.
    private func switchSpeed(code: UInt8, toBaud: Int, verify: Bool) async -> Bool {
        let frame = Self.rawFrame(buffer: [0x01, Cmd.speed.rawValue, 0x01, 0x00, code],
                                  seedTerminator: true)
        guard await port.send(frame) else { return false }
        guard await port.receive(1, timeout: Self.statusTimeout)?.first == Self.ack else { return false }
        _ = await receiveCompleteReply(timeout: Self.statusTimeout)
        guard await port.send([Self.eot]) else { return false }
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await port.reconfigure(baud: toBaud, parity: .even)
        // Let the adapter apply the new divisor before probing — higher rates
        // (esp. 115200 over a USB-FTDI bridge) need a moment to settle or the
        // first ping byte gets mis-sampled, causing a needless fallback.
        try? await Task.sleep(nanoseconds: 80_000_000)
        // Be patient at the top rung: a flaky-but-present fast link can drop
        // the first ENQ or two. A genuine ACK is still required, so the extra
        // attempts can't produce a false positive that would corrupt transfers.
        return verify ? await fujiPing(attempts: 6) : true
    }

    /// Ping: drain stale input, then send ENQ up to `attempts`
    /// times, succeeding on the first ACK. Used to confirm a rate switch took.
    private func fujiPing(attempts: Int = 3) async -> Bool {
        _ = await drainAvailable(idleGap: 0.15, maxWait: 0.5)
        for _ in 0..<attempts {
            guard await port.send([Self.enq]) else { return false }
            if await port.receive(1, timeout: 0.8)?.first == Self.ack { return true }
        }
        return false
    }

    /// Rescue for the "camera won't talk until I power-cycle it" symptom: a
    /// camera left ramped to a fast rate (a session that ended without the
    /// disconnect reset — crash, force-quit, yanked cable) won't answer the
    /// 9600 wake. Sweep the plausible rates; if the camera ACKs at one, send
    /// EOT (which drops it back to 9600 locally), restore the host port, and
    /// run the normal handshake. Only called AFTER the normal wake failed, so
    /// it can never disturb a healthy connect.
    private func recoverFromStaleBaudUnlocked() async -> Bool {
        for rate in [115200, 57600, 38400, 19200] {
            try? await port.reconfigure(baud: rate, parity: .even)
            _ = await drainAvailable(idleGap: 0.15, maxWait: 0.3)
            if await fujiPing(attempts: 2) {
                await port.send([Self.eot])
                try? await Task.sleep(nanoseconds: 150_000_000)
                try? await port.reconfigure(baud: 9600, parity: .even)
                _ = await drainAvailable(idleGap: 0.2, maxWait: 0.5)
                return await handshakeUnlocked()
            }
        }
        // Nothing answered anywhere — leave the port back at the wake rate.
        try? await port.reconfigure(baud: 9600, parity: .even)
        return false
    }

    // MARK: High-level operations

    /// GetStatus / GetVersion / GetModel… aggregated by the manager.
    /// Returns the raw reply payload of cmd 0x29 (MODEL) — short ASCII
    /// like "DS-7" / "Apple QuickTake 200" / "Samsung Kenox SSC-350N".
    private func readModelStringUnlocked() async -> String? {
        guard let bytes = await sendCommand(.model, payload: [], expectReply: true),
              !bytes.isEmpty else { return nil }
        return Self.asciiString(bytes)
    }

    private func readFirmwareVersionUnlocked() async -> String? {
        guard let bytes = await sendCommand(.version, payload: [], expectReply: true),
              !bytes.isEmpty else { return nil }
        return Self.asciiString(bytes)
    }

    /// PIC_COUNT → number of photos on the card.
    /// HARDWARE-VERIFY: assumed little-endian uint16 inside the reply.
    private func readPhotoCountUnlocked() async -> Int? {
        guard let reply = await sendCommand(.picCount, payload: [], expectReply: true),
              reply.count >= 2 else { return nil }
        return Int(reply[0]) | (Int(reply[1]) << 8)
    }

    /// AVAIL_MEM → bytes of free space on the SmartMedia card.
    /// HARDWARE-VERIFY: assumed 4-byte little-endian.
    private func readAvailableMemoryUnlocked() async -> Int? {
        guard let reply = await sendCommand(.availMem, payload: [], expectReply: true),
              reply.count >= 4 else { return nil }
        var bytes: UInt32 = 0
        for i in 0..<4 { bytes |= UInt32(reply[i]) << (8 * i) }
        return Int(bytes)
    }

    /// FLASH_GET → current flash mode byte (camera-specific semantics).
    private func readFlashModeUnlocked() async -> UInt8? {
        guard let reply = await sendCommand(.flashGet, payload: [], expectReply: true),
              let first = reply.first else { return nil }
        return first
    }

    // MARK: Photo enumeration

    /// PIC_NAME → DSC*.JPG filename for `index`. Required by
    /// `eraseImageUnlocked(named:)` since the camera takes filenames, not indices.
    private func readPhotoNameUnlocked(index: Int) async -> String? {
        let payload = Self.indexPayload(index)
        guard let reply = await sendCommand(.picName, payload: payload, expectReply: true),
              !reply.isEmpty else { return nil }
        return Self.asciiString(reply)
    }

    /// PIC_SIZE → byte length of file at `index`.
    /// HARDWARE-VERIFY: assumed 4-byte little-endian.
    private func readPhotoSizeUnlocked(index: Int) async -> Int? {
        let payload = Self.indexPayload(index)
        guard let reply = await sendCommand(.picSize, payload: payload, expectReply: true),
              reply.count >= 4 else { return nil }
        var bytes: UInt32 = 0
        for i in 0..<4 { bytes |= UInt32(reply[i]) << (8 * i) }
        return Int(bytes)
    }

    // MARK: Photo transfer

    /// PIC_GET → the full JPEG for `index`. The reply spans multiple frames
    /// (ETB-terminated chunks followed by an ETX-terminated final frame);
    /// `receiveCompleteReply` stitches them.
    private func readPhotoJPEGUnlocked(
        index: Int,
        expectedSize: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        let payload = Self.indexPayload(index)
        // OVERALL ceiling: size at the worst-case goodput, +50% slack, +10s
        // startup. The per-frame idle timeout (in receiveCompleteReply) is the
        // real progress guard; this just bounds a totally dead transfer.
        let timeout: TimeInterval = {
            if let size = expectedSize, size > 0 {
                // Clamp the size that drives the budget: a QT200 frame is
                // 640×480, so a plausible JPEG is well under 512 KB. A corrupt
                // size field (e.g. from a baud mismatch) must NOT translate into
                // an hours-long ceiling that looks like a freeze.
                let bounded = min(size, Self.maxPlausibleTransferBytes)
                let budget = Double(bounded) / Self.bytesPerSecondFloor * 1.5 + 10
                return min(300, max(Self.bulkTimeout, budget))
            }
            return Self.bulkTimeout
        }()
        return await sendCommand(
            .picGet, payload: payload, expectReply: true,
            timeout: timeout, expectedSize: expectedSize, enforceExactSize: true,
            progress: progress
        )
    }

    /// PIC_GET_THUMB → small preview for `index` (size camera-defined).
    private func readPhotoThumbnailUnlocked(index: Int) async -> [UInt8]? {
        let payload = Self.indexPayload(index)
        // The QT200 thumbnail (~10,500 bytes, 60×175) streams as
        // a multi-frame reply, so it needs the bulk timeout: the 2s status
        // default expires mid-stream (~11s at 9600), aborting the transfer. The
        // per-frame idle timeout still guards a dead camera.
        return await sendCommand(.picGetThumb, payload: payload, expectReply: true,
                                 timeout: Self.bulkTimeout, expectedSize: 10_500)
    }

    // MARK: Erase

    /// PIC_DEL → erase one photo by name. The payload is the DSC*.JPG
    /// filename; the caller resolves index → name via
    /// `readPhotoNameUnlocked(index:)` first.
    private func eraseImageUnlocked(named filename: String) async -> Bool {
        let payload = Array(filename.utf8)
        return await sendCommand(.picDel, payload: payload, expectReply: false) != nil
    }

    /// No bulk-erase opcode in the family — iterate one at a time. Each delete
    /// re-indexes the camera's file list, so walking a fixed 0..<count by index
    /// skips every other photo as the list shifts. Instead always delete the
    /// current first photo, then re-read the count and confirm it dropped. The
    /// count check also avoids looping forever if a wire delete silently no-ops.
    @discardableResult
    private func eraseAllUnlocked() async -> Bool {
        guard var remaining = await readPhotoCountUnlocked() else { return false }
        while remaining > 0 {
            guard let name = await readPhotoNameUnlocked(index: 0),
                  await eraseImageUnlocked(named: name) else { return false }
            guard let newCount = await readPhotoCountUnlocked() else { return false }
            if newCount >= remaining { return false }   // delete didn't take
            remaining = newCount
        }
        return true
    }

    // MARK: Camera control

    /// FLASH_SET → set the flash mode (camera-specific byte values).
    @discardableResult
    private func setFlashUnlocked(mode: UInt8) async -> Bool {
        await sendCommand(.flashSet, payload: [mode], expectReply: false) != nil
    }

    /// Quality toggle has no documented opcode in the Fuji command set
    /// — stub until either a hardware capture or the QT200
    /// `SETFEATURE 'impm'` byte sequence is mapped.
    @discardableResult
    private func setQualityUnlocked(high: Bool) async -> Bool {
        _ = high
        NSLog("[FujiCameraSession] setQuality: no documented command in the Fuji command set.")
        return false
    }

    /// ID_SET → set the camera's stored name (ASCII bytes from caller).
    @discardableResult
    private func setNameUnlocked(_ ascii: [UInt8]) async -> Bool {
        await sendCommand(.idSet, payload: ascii, expectReply: false) != nil
    }

    /// DATE_SET (0x86) → set the camera clock. The payload is
    /// **14 ASCII digits** `"YYYYMMDDHHMMSS"` (NOT packed/BCD
    /// bytes). The frame builder supplies the `len=14` header automatically.
    /// Returns the camera's ACK (a NAK / no-answer → false).
    @discardableResult
    private func setClockUnlocked(year: Int, month: Int, day: Int,
                  hour: Int, minute: Int, second: Int) async -> Bool {
        let ascii = String(format: "%04d%02d%02d%02d%02d%02d",
                           year, month, day, hour, minute, second)
        return await sendCommand(.dateSet, payload: Array(ascii.utf8), expectReply: false) != nil
    }

    /// DATE_GET (0x84) → read the camera clock back, so a set can be verified.
    /// The reply is **14 binary digit values**
    /// (each byte 0–9, NOT ASCII): YYYY MM DD HH MM SS. Returns nil on NAK /
    /// short reply (i.e. the camera doesn't support the clock over serial).
    private func readClockUnlocked() async -> (year: Int, month: Int, day: Int,
                               hour: Int, minute: Int, second: Int)? {
        guard let buf = await sendCommand(.dateGet, payload: [], expectReply: true),
              buf.count >= 14, buf.prefix(14).allSatisfy({ $0 <= 9 }) else { return nil }
        let d = buf.map { Int($0) }
        return (d[0] * 1000 + d[1] * 100 + d[2] * 10 + d[3],
                d[4] * 10 + d[5],
                d[6] * 10 + d[7],
                d[8] * 10 + d[9],
                d[10] * 10 + d[11],
                d[12] * 10 + d[13])
    }

    /// TAKE → remote shutter. The Fuji family's firmware accepts it, but the
    /// QuickTake 200 disables it in software (`QTIC_STARTCAPTURE` returns
    /// paramErr). Works against a DS-7 or Samsung Kenox; may NAK on a QT200.
    /// Attempted either way; the camera decides.
    @discardableResult
    private func capturePhotoUnlocked() async -> Bool {
        await sendCommand(.take, payload: [], expectReply: false) != nil
    }

    // MARK: - Command dispatch

    /// Send a framed command and run the transmit
    /// choreography: the camera answers a single ACK / NAK / EOT byte first,
    /// then (on ACK) sends the reply frame(s). Retries up to `maxRetries`
    /// times on NAK.
    private func sendCommand(
        _ cmd: Cmd,
        payload: [UInt8],
        expectReply: Bool,
        timeout: TimeInterval = statusTimeout,
        expectedSize: Int? = nil,
        // Opts into treating `expectedSize` as a length the camera
        // PROMISED (PIC_SIZE), not just a capacity/timing hint — the
        // finished transfer must match it exactly. Thumbnails pass an
        // estimate and leave this false.
        enforceExactSize: Bool = false,
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        var attempts = 0
        while true {
            guard !Task.isCancelled,
                  await sendFrame(cmd: cmd, payload: payload, isLast: true) else { return nil }
            guard let answer = await port.receive(1, timeout: timeout)?.first else {
                guard expectReply else { return nil }
                attempts += 1
                if attempts > Self.maxRetries { return nil }
                continue
            }
            switch answer {
            case Self.ack:
                // Command accepted. Data commands stream their reply frame(s);
                // control commands are done.
                if expectReply {
                    return await receiveCompleteReply(
                        timeout: timeout, expectedSize: expectedSize,
                        exactSize: enforceExactSize ? expectedSize : nil,
                        progress: progress
                    )
                }
                return []
            case Self.nak:
                attempts += 1
                if attempts > Self.maxRetries { return nil }
                continue
            default:
                // EOT (camera reset) or an unexpected byte — give up.
                return nil
            }
        }
    }

    // MARK: - Wire framing

    /// Send one command frame on the wire (final-frame terminator).
    private func sendFrame(cmd: Cmd, payload: [UInt8], isLast: Bool) async -> Bool {
        await port.send(Self.frame(cmd: cmd.rawValue, payload: payload, isLast: isLast))
    }

    /// Build a Fuji command frame:
    ///
    ///   ESC STX | escaped(command buffer) | ESC term | checksum
    ///
    /// where the **command buffer** is `[0x00, opcode, payloadLen, 0x00,
    /// payload…]` (a leading 0, the opcode, a one-byte payload length, a 0,
    /// then the payload), `term` is ETX for the final frame / ETB for an
    /// intermediate one, and the checksum seeds with `term` and XORs every
    /// raw (pre-escape) command-buffer byte — nothing else. Any 0x10 (ESC)
    /// byte inside the buffer is doubled on the wire but counted once in the
    /// checksum.
    static func frame(cmd: UInt8, payload: [UInt8], isLast: Bool) -> [UInt8] {
        let terminator = isLast ? etx : etb
        let buffer: [UInt8] = [0x00, cmd, UInt8(payload.count & 0xFF), 0x00] + payload

        var check: UInt8 = terminator
        for byte in buffer { check ^= byte }

        var escaped = [UInt8]()
        escaped.reserveCapacity(buffer.count + 2)
        for byte in buffer {
            if byte == esc { escaped.append(esc) }
            escaped.append(byte)
        }

        var frame: [UInt8] = [esc, stx]
        frame.append(contentsOf: escaped)
        frame.append(esc)
        frame.append(terminator)
        frame.append(check)
        return frame
    }

    /// Read every frame of a reply (ETB-terminated intermediates + an
    /// ETX-terminated final), ACKing each in turn, and concatenate the
    /// data. Drives `progress` per byte if `expectedSize` is provided.
    private func receiveCompleteReply(
        timeout: TimeInterval,
        expectedSize: Int? = nil,
        // Non-nil only for a full JPEG's announced PIC_SIZE. A thumbnail's
        // `expectedSize` is a capacity/timing estimate and never reaches here.
        exactSize: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) async -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        var data = [UInt8]()
        var frames = 0   // verification: frames validated + accepted this reply
        // Capacity hint only — `append` grows the array regardless. Clamp
        // so a corrupt/absurd announced size can't become an oversized
        // allocation; the exact-length check and progress below use the
        // real value.
        if let size = expectedSize {
            data.reserveCapacity(max(0, min(size, Self.maxPlausibleTransferBytes)))
        }

        while true {
            let remainingOverall = deadline.timeIntervalSinceNow
            if remainingOverall <= 0 {
                await abortIfStreaming(midStream: !data.isEmpty)
                return nil
            }
            // Per-frame budget RESETS each iteration: a healthy frame arrives
            // in well under frameIdleTimeout, so a slow-but-progressing
            // transfer keeps going; a stalled one is caught in one window.
            let frameBudget = min(Self.frameIdleTimeout, remainingOverall)
            guard let (chunk, isLast) = await receiveFrame(timeout: frameBudget) else {
                await abortIfStreaming(midStream: !data.isEmpty)
                return nil
            }
            data.append(contentsOf: chunk)
            frames += 1
            if let total = expectedSize, total > 0 {
                progress?(min(1.0, Double(data.count) / Double(total)))
            }
            // ACK the frame; the camera waits for this before sending
            // the next ETB frame, or releases the link if it was ETX.
            guard await port.send([Self.ack]) else { return nil }
            if isLast {
                // The camera announced this length; short or long means a
                // truncated/padded transfer, not a complete photo. Reject
                // rather than hand up a file that will fail to decode.
                if let exact = exactSize, data.count != exact {
                    // %ld: `exact` can be a genuinely 64-bit value here,
                    // and %d would print a truncated, misleading number.
                    NSLog("[Fuji] reply length %ld != announced %ld — rejecting incomplete transfer",
                          data.count, exact)
                    return nil
                }
                return data
            }
        }
    }

    /// Recover the line after a reply read is abandoned. If a transfer was in
    /// flight (`midStream`), tell the camera to stop with EOT, then drain
    /// whatever it already queued — otherwise a half-read stream's leftover
    /// bytes corrupt every following command. When nothing was streaming yet, a
    /// light drain is enough.
    private func abortIfStreaming(midStream: Bool) async {
        if midStream {
            await port.send([Self.eot])
            _ = await drainAvailable(idleGap: 0.2, maxWait: 1.0)
            // EOT drops the camera to 9600 locally; match it so the recovery
            // handshake isn't talking at a now-stale ramped rate.
            try? await port.reconfigure(baud: 9600, parity: .even)
            _ = await drainAvailable(idleGap: 0.2, maxWait: 0.6)
        } else {
            _ = await drainAvailable(idleGap: 0.2, maxWait: 0.5)
        }
    }

    /// Read one frame: hunt for `ESC STX`, skip the 4-byte header
    /// (unknown[2] + length[2 LE], ignored — we terminate on `ESC ETX/ETB`
    /// instead), collect the data un-escaping `ESC ESC`, then eat the
    /// trailing checksum byte. Returns `(data, isLast)`.
    private func receiveFrame(timeout: TimeInterval) async -> (data: [UInt8], isLast: Bool)? {
        let deadline = Date().addingTimeInterval(timeout)

        // 1. Hunt for ESC STX, tolerating stray bytes (ACK echoes, etc.).
        var prevWasEsc = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let byte = await port.receive(1, timeout: remaining)?.first else {
                return nil
            }
            if prevWasEsc && byte == Self.stx { break }
            prevWasEsc = (byte == Self.esc)
        }

        // 2. Read the 4-byte header (unknown[2] + length[2 LE]). Kept (not
        //    discarded) so it can feed the reply-checksum verification below.
        guard let header = await port.receive(4, timeout: max(deadline.timeIntervalSinceNow, 0.5)) else {
            return nil
        }

        // 3. Collect bytes until `ESC (ETX|ETB)`, un-escaping `ESC ESC`.
        var data = [UInt8]()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let byte = await port.receive(1, timeout: remaining)?.first else {
                return nil
            }
            if byte != Self.esc {
                data.append(byte)
                continue
            }
            // ESC: next byte disambiguates escape vs. terminator.
            let r2 = deadline.timeIntervalSinceNow
            if r2 <= 0 { return nil }
            guard let next = await port.receive(1, timeout: r2)?.first else {
                return nil
            }
            if next == Self.esc {
                data.append(Self.esc)
                continue
            }
            // Frame terminator: ETX = last, ETB = more to come. Anything
            // else is corrupt framing — bail rather than guess (a prior
            // version treated any unknown byte as ETB, and its checksum,
            // seeded with that same byte, validated by construction).
            guard next == Self.etx || next == Self.etb else {
                return nil
            }
            let isLast = (next == Self.etx)
            // The trailing byte is the frame's XOR checksum. Verify it against
            // the domain learned from this session's healthy frames; a frame
            // that breaks that domain is corrupt, so bail (return nil) rather
            // than hand garbage up as image data — the caller then aborts and
            // recovers the line and the download fails cleanly (retryable).
            //
            // Asymmetry is deliberate and hardware-verified: only a checksum
            // byte that ARRIVES wrong fails the frame. A timeout is tolerated
            // — the frame data itself already ESC-terminated cleanly, and on
            // a real QT200 the trailing byte can straggle past the deadline.
            // Do not fold this into a single guard: nil and invalid are
            // different cases.
            let received = await port.receive(1, timeout: max(deadline.timeIntervalSinceNow, 0.5))?.first
            if let received,
               !replyChecksumIsValid(header: header, data: data, term: next, received: received) {
                return nil
            }
            return (data, isLast)
        }
    }

    /// The reply-frame checksum domain, learned from this session's healthy
    /// frames rather than hard-coded — because the exact domain isn't confirmed
    /// across every Fuji-family body. Candidate A covers `term XOR header XOR
    /// data`; candidate B omits the header (`term XOR data`).
    private enum ChecksumDomain { case a, b }
    /// Locked to whichever candidate matched the first frame that matched EITHER.
    /// Stays nil (→ observe-only, no enforcement) if neither ever matches, so an
    /// unknown third domain can never break otherwise-healthy transfers.
    private var lockedChecksumDomain: ChecksumDomain?
    /// "A"/"B"/"—" for the verification log.
    private var checksumDomainName: String {
        switch lockedChecksumDomain { case .a: return "A"; case .b: return "B"; case nil: return "—" }
    }
    /// Caps how many checksum lines we log per session so a flood of corruption
    /// (or a wrong guess) can't spam the console. Named so `openUnlocked` can
    /// restore the same cap on a fresh open rather than duplicating the 12.
    private static let checksumLogBudgetCap = 12
    private var checksumLogBudget = checksumLogBudgetCap
    /// One-shot: log the learned checksum domain once per session.
    private var checksumDomainLogged = false

    /// Validate the reply-frame XOR checksum. Returns `true` when the frame is
    /// acceptable — it matches the domain locked from earlier healthy frames, OR
    /// no domain has been learned yet (we can't judge, so we don't reject). Returns
    /// `false` only when the frame definitively breaks the learned domain, i.e.
    /// it's corrupt. This self-locking scheme enforces integrity without a
    /// hard-coded domain: healthy frames set the domain and always pass it;
    /// only genuine corruption fails.
    private func replyChecksumIsValid(header: [UInt8], data: [UInt8], term: UInt8, received: UInt8) -> Bool {
        var a = term
        for b in header { a ^= b }
        for b in data { a ^= b }
        var bChk = term
        for b in data { bChk ^= b }

        let matchesA = (a == received)
        let matchesB = (bChk == received)

        // Learn the domain from the first frame that matches a candidate.
        if lockedChecksumDomain == nil {
            if matchesA { lockedChecksumDomain = .a }
            else if matchesB { lockedChecksumDomain = .b }
        }

        // Log the learned domain once, so a real QT200/QT150 run confirms it.
        if !checksumDomainLogged {
            checksumDomainLogged = true
            let verdict = matchesA ? "A (term+header+data)"
                        : matchesB ? "B (term+data)"
                        : "NEITHER"
            NSLog("[Fuji] reply-frame checksum domain match: %@  got=0x%02X A=0x%02X B=0x%02X (%d-byte frame)",
                  verdict, received, a, bChk, data.count)
        }

        // Enforce only against a domain we actually locked onto. Unknown domain
        // (neither candidate ever matched) → observe-only, accept the frame.
        let valid: Bool
        switch lockedChecksumDomain {
        case .a:  valid = matchesA
        case .b:  valid = matchesB
        case nil: valid = true
        }

        if !valid, checksumLogBudget > 0 {
            checksumLogBudget -= 1
            NSLog("[Fuji] reply-frame checksum MISMATCH (domain %@): got 0x%02X A=0x%02X B=0x%02X — rejecting corrupt frame (%d bytes)",
                  lockedChecksumDomain == .a ? "A" : "B", received, a, bChk, data.count)
        }
        return valid
    }

    // MARK: - Small helpers

    /// Two-byte little-endian index payload (the family's common form
    /// for "operate on photo N").
    ///
    /// The wire index is 1-based: callers pass a 0-based gallery index and the
    /// sent value is `index + 1`. PIC_NAME 0x0A / PIC_SIZE 0x17 / PIC_GET 0x02
    /// all NAK at index 0 but succeed at 1 (idx 1 → "DSC00001.JPG", idx 2 →
    /// "DSC00002.JPG").
    private static func indexPayload(_ index: Int) -> [UInt8] {
        let wire = index + 1
        return [UInt8(wire & 0xFF), UInt8((wire >> 8) & 0xFF)]
    }

    /// Trim NUL padding and surrounding whitespace from an ASCII reply.
    private static func asciiString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    // MARK: - Diagnostics
    //
    // `captureDiagnosticsUnlocked()` exercises each command and records the raw bytes
    // the camera returns — a window into the exact reply layout (header +
    // length + payload + checksum) for pinning down the parsing.

    /// Probe the connected camera and return a human-readable, copy-pasteable
    /// report. Runs a matrix of probes in one session:
    ///
    ///   A. Handshake + line-setting note.
    ///   B. Parity sweep — 8N1 / 8E1 / 8O1 — on PIC_COUNT. ENQ(0x05) and
    ///      ACK(0x06) both carry an even number of 1-bits, so a working
    ///      handshake does NOT pin down parity; command bytes like 0x0B do,
    ///      so a wrong parity silently corrupts every frame. This rules it
    ///      in or out.
    ///   C. Framing-variant sweep on PIC_COUNT — several plausible frame
    ///      layouts/checksums, to learn which (if any) the body answers.
    ///   D. Full command probe with the current framing — every byte that
    ///      comes back is dumped as hex + ASCII, with timing and a liveness
    ///      re-check after each command.
    ///
    /// The caller must have `open`ed + `handshake`d. The probes run at 9600;
    /// if the live session was already ramped to a faster negotiated baud
    /// when capture started, that rate is restored before returning — this
    /// diagnostic must not silently strand a fast link at 9600.
    private func captureDiagnosticsUnlocked() async -> String {
        var out = Report()
        out.title("SwiftTake — QuickTake 200 / Fuji diagnostic")
        out.line("8E1.  ACK=06 NAK=15 EOT=04 ENQ=05.  '∅' = no reply.")

        // The live session may be ramped to 115200; the probes below run at
        // 9600, so reset to 9600 first for a known, clean starting state.
        // Remember what it was ramped to so it can be put back afterwards.
        let preCaptureBaud = currentBaud
        await resetToStandardSpeedUnlocked()

        await captureHandshakeSection(into: &out)
        await captureQT200NativeOpcodes(into: &out)   // GetStatus, count, name/size/thumb/data
        await captureQualitySurvey(into: &out)        // every photo's size + bits-per-pixel (Fine/Normal)
        await captureClockProbe(into: &out)           // DATE_GET only — observational, never writes
        await captureBaudCheck(into: &out)            // one clean SPEED ramp, then reset to 9600

        // Restore the negotiated rate the live session was using before this
        // routine ran, using the existing negotiate step — otherwise a user
        // connected at a fast baud is silently left at 9600 until reconnect.
        if preCaptureBaud != 9600 {
            let restored = await negotiateFastestBaudUnlocked()
            out.line(restored == preCaptureBaud
                     ? "Restored the pre-capture \(preCaptureBaud) baud link."
                     : "Could not restore the pre-capture \(preCaptureBaud) baud link (now at \(restored)).")
        }

        out.rule()
        out.line("End of capture.")
        return out.text
    }

    /// Baud section: run `negotiateFastestBaud` once and report where it lands,
    /// then reset to 9600 so the link is clean.
    private func captureBaudCheck(into out: inout Report) async {
        out.section("BAUD  (SPEED ramp)")
        let rate = await negotiateFastestBaudUnlocked()
        out.line(rate > 9600 ? "Ramped to \(rate) baud ✓" : "Stayed at 9600 (camera declined the ramp).")
        await resetToStandardSpeedUnlocked()
        out.line("Reset to 9600 for a clean link.")
    }

    /// Quality survey: list every photo's compressed size and the resulting
    /// bits-per-pixel. All QT200 frames are 640×480, so size alone separates
    /// Fine from Normal. Reading sizes is cheap (GetImageSize per index, no full
    /// download) and confirms the Fine/Normal threshold straight from the card:
    /// a bimodal split (a low ~2.2 bpp cluster vs a higher one) is Normal vs Fine.
    private func captureQualitySurvey(into out: inout Report) async {
        out.section("QUALITY SURVEY  (size → bits/pixel @ 640×480)")

        // Resync first: the prior section's GetImageData starts an ~86 KB
        // transfer and only reads its leading bytes, so even after the EOT
        // abort there can be image bytes still in flight. A fresh handshake +
        // drain clears them; without it readPhotoCount reads garbage and the
        // survey wrongly reports "No photos".
        _ = await handshakeUnlocked()
        _ = await drainAvailable(idleGap: 0.2, maxWait: 0.6)

        guard let count = await readPhotoCountUnlocked(), count > 0 else {
            out.line("No photos / PIC_COUNT unavailable.")
            return
        }
        // Same clamp as the production metadata path (fetchMetadata's
        // gallery index space): PIC_COUNT is a raw 16-bit wire field, and an
        // unclamped loop over a corrupt reply would run away.
        let bounded = min(count, 255)
        let pixels = 640.0 * 480.0
        for index in 0..<bounded {
            if Task.isCancelled {
                out.line("Cancelled after \(index) of \(bounded) — stopping.")
                return
            }
            let name = await readPhotoNameUnlocked(index: index) ?? "idx\(index + 1)"
            if let bytes = await readPhotoSizeUnlocked(index: index) {
                let bpp = Double(bytes) * 8.0 / pixels
                out.line(String(format: "%@  %7d B  %.3f bpp  %@",
                                name, bytes, bpp, bpp >= 1.95 ? "→ Fine" : "→ Normal"))
            } else {
                out.line("\(name)  size ∅")
            }
        }
        out.line("Threshold 1.95 bpp (confirmed): Fine ≈ 2.23–2.36, Normal ≈ 1.66–1.68.")
    }

    /// Clock section: OBSERVE the native Fuji clock only (DATE_GET 0x84).
    /// This routine must never write the camera clock — QT200 filenames are
    /// date-derived, so a silent write here on every "Capture Diagnostics"
    /// run would quietly rewrite it. Setting the clock stays an explicit,
    /// user-initiated action (`setClock(...)`, the Settings "Set to Computer
    /// Date/Time" path) — untouched by this diagnostic.
    private func captureClockProbe(into out: inout Report) async {
        out.section("CLOCK  (DATE_GET 0x84 — observational; capture never writes the clock)")

        if let clock = await readClockUnlocked() {
            out.line(String(format: "DATE_GET → %04d-%02d-%02d %02d:%02d:%02d ✓",
                            clock.year, clock.month, clock.day,
                            clock.hour, clock.minute, clock.second))
        } else {
            out.line("DATE_GET → NAK/∅ (camera may not expose the clock).")
        }
    }

    // MARK: Diagnostics — sections

    /// Section A: re-probe the handshake so the report stands alone, and note
    /// the line settings the sweep starts from.
    private func captureHandshakeSection(into out: inout Report) async {
        out.section("A. HANDSHAKE  (line starts 9600 8E1)")
        await port.send([Self.enq])
        let (reply, ms) = await timedDrain(idleGap: 0.4, maxWait: 1.5)
        out.exchange(label: "ENQ 0x05", sent: [Self.enq], got: reply, ms: ms)
        out.line(reply.first == Self.ack
                 ? "  → ACK. Link awake. (ENQ/ACK can't confirm parity.)"
                 : "  → no ACK; the rest of the sweep may also stay silent.")
    }

    /// Section E: confirm the QT200 import recipe in the Apple `cmra` dialect,
    /// which differs from the DS-7 sibling's codes in places.
    /// The per-photo payload byte is the 1-based picture
    /// index — `0x0A`/`0x17`/`0x02` NAK at index 0 but ACK at index 1+ (name
    /// `DSC00001.JPG`, size 86697, …). This section walks the first few images
    /// by 1-based index and peeks at the start of the JPEG stream to confirm
    /// the whole path.
    ///
    /// Index 0xFF makes the camera send EOT and drop the link, so this section
    /// never probes out of range; it bounds the walk by the live picture count.
    private func captureQT200NativeOpcodes(into out: inout Report) async {
        out.section("E. QT200 IMPORT RECIPE  (Apple cmra, 1-based index, line 8E1)")

        // Resync first: an earlier probe can leave undrained bytes that desync
        // the link and make the multi-frame thumbnail/image reads below fail
        // spuriously. A fresh handshake + drain restores a clean state.
        _ = await handshakeUnlocked()
        _ = await drainAvailable(idleGap: 0.2, maxWait: 0.5)

        // GetStatus 0x0C — the standard call issued after handshake.
        await probe(into: &out, label: "GetStatus  0x0C", cmd: 0x0C, payload: [])

        // Discover how many pictures are present so the walk stays in range.
        let count = (await readPhotoCountUnlocked()) ?? 0
        out.line("")
        out.line("PIC_COUNT 0x0B → \(count) photo(s). Walking 1-based indices.")

        // Walk the first few images (1-based): name + size per image.
        let walk = min(count, 3)
        if walk >= 1 {
            for index in 1...walk {
                let payload: [UInt8] = [UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)]
                await probe(into: &out, label: "GetImageName 0x0A idx\(index)", cmd: 0x0A, payload: payload)
                await probe(into: &out, label: "GetImageSize 0x17 idx\(index)", cmd: 0x17, payload: payload)
            }
        }

        // Thumbnail: PIC_GET_THUMB (0x00) returns a fixed ~10,500-byte (60×175)
        // preview. Fetch it via the full multi-frame reader
        // (readPhotoThumbnail handles the 1-based index + chunked ACK) to show
        // the real size and byte layout.
        if walk >= 1 {
            _ = await drainAvailable(idleGap: 0.15, maxWait: 0.3)
            let thumb = await readPhotoThumbnailUnlocked(index: 0)   // 0-based → wire idx 1
            out.line("")
            if let thumb {
                out.line("[PIC_GET_THUMB 0x00 idx1] \(thumb.count) bytes (EXIF block)")
                out.line("  first32 \(Self.hex(Array(thumb.prefix(32))))")
                // Parse the EXIF IFD1 thumbnail descriptor — confirms dimensions,
                // compression, and pixel format the renderer needs.
                out.line("  \(QuickTake200ThumbnailRenderer.describe(thumb))")
            } else {
                out.line("[PIC_GET_THUMB 0x00 idx1] ∅ no thumbnail returned")
            }
        }

        // GetImageData 0x02 at index 1 — pull just the leading bytes and look
        // for the JPEG SOI marker (FF D8) to confirm the full-image path, then
        // EOT to abort the in-flight transfer and leave the link clean.
        if walk >= 1 {
            out.line("")
            _ = await drainAvailable(idleGap: 0.15, maxWait: 0.3)
            let dataFrame = Self.frame(cmd: 0x02, payload: [0x01, 0x00], isLast: true)
            await port.send(dataFrame)
            let (head, ms) = await timedDrain(idleGap: 0.5, maxWait: 2.5)
            out.exchange(label: "GetImageData 0x02 idx1 (leading bytes only)", sent: dataFrame, got: head, ms: ms)
            out.line("  \(Self.interpret(head))")
            out.line(Self.containsJPEGSOI(head)
                     ? "  → JPEG SOI (FF D8) present — full-image transfer works."
                     : "  → no SOI yet in the leading bytes (header frame only, or more frames follow).")
            await port.send([Self.eot])
            _ = await drainAvailable(idleGap: 0.2, maxWait: 0.5)
        }
    }

    /// Send one framed command and append a labelled, ACK-aware exchange to
    /// the report. Shared by Section E. ACKs any data frame that came back so
    /// the camera releases.
    private func probe(into out: inout Report, label: String, cmd: UInt8, payload: [UInt8]) async {
        _ = await drainAvailable(idleGap: 0.15, maxWait: 0.3)
        let frame = Self.frame(cmd: cmd, payload: payload, isLast: true)
        await port.send(frame)
        let (reply, ms) = await timedDrain(idleGap: 0.5, maxWait: 3.0)
        out.line("")
        out.exchange(label: label, sent: frame, got: reply, ms: ms)
        out.line("  \(Self.interpret(reply))")
        if !reply.isEmpty { await port.send([Self.ack]) }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// True if `bytes` contain the JPEG start-of-image marker `FF D8`.
    private static func containsJPEGSOI(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 {
            return true
        }
        return false
    }

    // MARK: Diagnostics — wire helpers

    /// Build a frame from an explicit inner `buffer` (no automatic
    /// leading-0/len/trailing-0), used by the framing sweep to try layouts the
    /// production `frame(cmd:…)` doesn't. `seedTerminator` chooses whether the
    /// XOR checksum is seeded with the ETX byte (production behaviour) or 0.
    private static func rawFrame(buffer: [UInt8], seedTerminator: Bool) -> [UInt8] {
        var check: UInt8 = seedTerminator ? etx : 0
        for byte in buffer { check ^= byte }

        var escaped = [UInt8]()
        for byte in buffer {
            if byte == esc { escaped.append(esc) }
            escaped.append(byte)
        }
        return [esc, stx] + escaped + [esc, etx, check]
    }

    /// Read whatever the port offers, one byte at a time, until it goes idle
    /// for `idleGap` or `maxWait` elapses. Unlike `receive(_:timeout:)` this
    /// doesn't need the reply length up front — what a diagnostic probe needs.
    private func drainAvailable(idleGap: TimeInterval, maxWait: TimeInterval) async -> [UInt8] {
        var out = [UInt8]()
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            guard let byte = await port.receive(1, timeout: idleGap)?.first else { break }
            out.append(byte)
        }
        return out
    }

    /// `drainAvailable` plus the milliseconds until the *first* byte arrived
    /// (-1 if nothing came), so the report can show how fast the body answers.
    private func timedDrain(idleGap: TimeInterval, maxWait: TimeInterval) async -> (bytes: [UInt8], ms: Int) {
        let start = Date()
        var out = [UInt8]()
        var firstByteAt: Date?
        let deadline = start.addingTimeInterval(maxWait)
        while Date() < deadline {
            guard let byte = await port.receive(1, timeout: idleGap)?.first else { break }
            if firstByteAt == nil { firstByteAt = Date() }
            out.append(byte)
        }
        let ms = firstByteAt.map { Int($0.timeIntervalSince(start) * 1000) } ?? -1
        return (out, ms)
    }

    /// One-line interpretation of a raw reply's leading byte for the report.
    private static func interpret(_ bytes: [UInt8]) -> String {
        guard let first = bytes.first else { return "∅ no response" }
        switch first {
        case ack: return "starts ACK 0x06 — \(bytes.count > 1 ? "data follows" : "bare ACK, no frame")"
        case nak: return "starts NAK 0x15 — frame rejected (bad checksum/framing)"
        case eot: return "starts EOT 0x04 — camera tore the link down"
        case esc: return "starts ESC 0x10 — looks like a frame with no leading ACK"
        default:  return "starts 0x\(String(format: "%02X", first)) — unexpected leading byte"
        }
    }

    /// Hex-dump helper for the report.
    private nonisolated static func hex(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "∅ (no reply)" }
        let body = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(body)   (\(bytes.count) bytes)"
    }

    /// Printable-ASCII rendering of a reply ('.' for non-printables), so model
    /// strings and filenames jump out of an otherwise hex dump.
    private nonisolated static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    /// Tiny report builder — keeps the section methods readable and the
    /// formatting (hex + ASCII + timing) consistent across the matrix.
    private struct Report {
        private(set) var text = ""
        mutating func line(_ s: String = "") { text += s + "\n" }
        mutating func rule() { line(String(repeating: "─", count: 60)) }
        mutating func title(_ s: String) { line(s); rule() }
        mutating func section(_ s: String) { line(); rule(); line(s); rule() }

        /// One sent→received exchange with timing and an ASCII gutter.
        mutating func exchange(label: String, sent: [UInt8], got: [UInt8], ms: Int) {
            line("[\(label)] sent \(FujiCameraSession.hex(sent))")
            if got.isEmpty {
                line("  ∅ no response")
            } else {
                let when = ms >= 0 ? " (first byte +\(ms)ms)" : ""
                line("  got \(FujiCameraSession.hex(got))\(when)")
                line("  ascii \"\(FujiCameraSession.ascii(got))\"")
            }
        }
    }
}
