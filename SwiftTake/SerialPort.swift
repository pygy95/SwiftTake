// MARK: - SerialPort
//
// A small, self-contained POSIX serial transport. It opens a USB-to-
// serial adapter's `/dev/cu.*` node, applies line settings, toggles the
// DTR control line, and moves raw bytes — and that's all. It knows
// nothing about the QuickTake itself; the camera conversation (wake,
// handshake, commands, transfers) lives one layer up in
// `QuickTakeCameraSession`.
//
// Actor isolation owns the descriptor. Nonblocking syscalls and cancellable
// waits keep I/O bounded. Protocol sessions must additionally serialize whole
// exchanges because actor methods can interleave at suspension points.
//
// Why termios: configuring a serial line's baud, parity, and framing has
// exactly one interface on macOS — the POSIX termios API. The particular
// values used here (8 data bits, no flow control, the 9600/57600 rates,
// even vs. no parity) are dictated by what the camera expects.

import Foundation
import Darwin

actor SerialPort {

    /// Parity framing. The QuickTake starts at 8N1 and the handshake
    /// switches it to 8E1, so the transport exposes both — plus odd, kept
    /// for protocol bring-up experiments (no shipping path uses it).
    enum Parity {
        case none
        case even
        case odd
    }

    enum Failure: Error {
        case openFailed(path: String, code: Int32)
        case lockFailed(code: Int32)
        case configureFailed(code: Int32)
        case notOpen
        case writeFailed(code: Int32)
        case timedOut
        case cancelled
    }

    private var handle: Int32 = -1
    private var generation: UInt64 = 0
    private var baudRate = 9600
    private var writing = false
    private(set) var lastFailure: Failure?

    var isOpen: Bool { handle >= 0 }

    // MARK: Opening

    /// Open `path` and bring the line up: `baud`, the given `parity`,
    /// 8 data bits, 1 stop bit, no flow control (the camera is a 3-wire
    /// device). Throws — rather than returning a flag — so the caller can
    /// report *why* it failed.
    func open(path: String, baud: Int, parity: Parity = .none) throws {
        try Task.checkCancellation()
        close()

        // O_NONBLOCK on the open() so it can't stall waiting for carrier
        // detect on a 3-wire cable; it stays nonblocking for bounded I/O.
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.openFailed(path: path, code: errno) }
        handle = fd

        // Take the port exclusively so a stray `screen`/helper process
        // can't grab bytes out from under an in-progress transfer.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let code = errno
            close()
            throw Failure.lockFailed(code: code)
        }

        do {
            try applyLineSettings(baud: baud, parity: parity)
        } catch {
            close()
            throw error
        }

        // Keep O_NONBLOCK: poll readiness is advisory, and neither read nor
        // write may block a Swift executor or bypass the operation deadline.
        lastFailure = nil
    }

    /// Re-apply baud/parity on an already-open port. The handshake uses
    /// this to flip to even parity and later to ramp the line to 57600.
    func reconfigure(baud: Int, parity: Parity) throws {
        try Task.checkCancellation()
        guard isOpen else { throw Failure.notOpen }
        try applyLineSettings(baud: baud, parity: parity)
    }

    private func applyLineSettings(baud: Int, parity: Parity) throws {
        var line = termios()
        guard tcgetattr(handle, &line) == 0 else { throw Failure.configureFailed(code: errno) }
        cfmakeraw(&line)

        // On Darwin the Bxxxx speed constants are literally the rate, so
        // a plain `speed_t(baud)` is the standard 9600 / 57600 value.
        let rate = speed_t(baud)
        cfsetispeed(&line, rate)
        cfsetospeed(&line, rate)

        // 8 data bits, 1 stop bit, receiver on, ignore modem-control lines.
        line.c_cflag &= ~tcflag_t(CSIZE | CSTOPB | CCTS_OFLOW | CRTS_IFLOW | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW)
        line.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)

        switch parity {
        case .none:
            line.c_cflag &= ~tcflag_t(PARENB)
        case .even:
            line.c_cflag |= tcflag_t(PARENB)
            line.c_cflag &= ~tcflag_t(PARODD)
        case .odd:
            line.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        // Fully raw: no canonical line editing, echo, signal chars, or
        // output post-processing — deliver bytes exactly as they arrive.
        line.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        line.c_oflag &= ~tcflag_t(OPOST)
        line.c_iflag = 0

        withUnsafeMutableBytes(of: &line.c_cc) {
            $0[Int(VMIN)] = 0
            $0[Int(VTIME)] = 0
        }
        guard tcsetattr(handle, TCSANOW, &line) == 0 else {
            throw Failure.configureFailed(code: errno)
        }
        baudRate = baud
    }

    // MARK: Control lines

    /// Assert (true) or clear (false) the DTR line. The QuickTake wakes
    /// from sleep on the DTR transition the host drives here.
    func setDTR(_ asserted: Bool) {
        guard !Task.isCancelled, isOpen else { return }
        let request = asserted ? TIOCSDTR : TIOCCDTR
        _ = ioctl(handle, request)
    }

    // MARK: Transfer

    /// Nonblocking writes and output-queue polling share one monotonic
    /// deadline. Failures invalidate this port; a partial command must never
    /// be followed by another command as though it had completed.
    @discardableResult
    func send(_ bytes: [UInt8]) async -> Bool { await send(bytes, timeout: 2) }

    @discardableResult
    func send(_ bytes: [UInt8], timeout: TimeInterval) async -> Bool {
        guard isOpen, !Task.isCancelled, !writing else { return false }
        guard !bytes.isEmpty else { return true }
        let token = generation, fd = handle
        writing = true
        defer { if generation == token { writing = false } }
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        func failed(_ error: Failure) -> Bool {
            if generation == token {
                lastFailure = error
                NSLog("[SerialPort] send failed: %@", String(describing: error))
                close()
            }
            return false
        }
        var offset = 0
        while offset < bytes.count {
            guard generation == token else { return false }
            guard !Task.isCancelled else { return failed(.cancelled) }
            guard ContinuousClock.now < deadline else { return failed(.timedOut) }
            let n = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return failed(.writeFailed(code: n == 0 ? EIO : errno))
            }
            do { try await Task.sleep(for: .milliseconds(2)) }
            catch { return failed(.cancelled) }
        }
        while true {
            guard generation == token else { return false }
            guard !Task.isCancelled else { return failed(.cancelled) }
            guard ContinuousClock.now < deadline else { return failed(.timedOut) }
            var pending: Int32 = 0
            guard ioctl(fd, TIOCOUTQ, &pending) == 0 else { return failed(.writeFailed(code: errno)) }
            if pending == 0 { break }
            do { try await Task.sleep(for: .milliseconds(2)) }
            catch { return failed(.cancelled) }
        }
        // TIOCOUTQ covers the driver queue, not necessarily the USB adapter's
        // shift register. Allow one packet's wire time (8E1 worst case) plus
        // 2 ms before starting the reply deadline; this wait is cancellable.
        let settle = Double(bytes.count) * 11 / Double(baudRate) + 0.002
        guard ContinuousClock.now + .seconds(settle) < deadline else { return failed(.timedOut) }
        do { try await Task.sleep(for: .seconds(settle)) }
        catch { return failed(.cancelled) }
        return generation == token && !Task.isCancelled
    }

    /// Read exactly `count` bytes, or return `nil` if they don't all
    /// arrive before `timeout`. The camera's frames are fixed-length, so
    /// a short read is unconditionally a failure — there is no partial
    /// result to hand back.
    /// Read and discard whatever is waiting, until the line stays quiet.
    ///
    /// A fixed-length receive consumes partial bytes even on timeout, but
    /// may wait unnecessarily or leave bytes beyond its requested count.
    /// Drain instead observes a bounded quiet interval.
    ///
    /// Returns the number of bytes thrown away, which is worth logging:
    /// on a healthy connect it should be the flood and nothing else.
    @discardableResult
    func drain(idleFor idle: TimeInterval = 0.2,
               limit: TimeInterval = 5) async -> Int {
        guard isOpen else { return 0 }
        var discarded = 0
        let token = generation
        let deadline = ContinuousClock.now + .seconds(limit)
        var scratch = [UInt8](repeating: 0, count: 512)

        while ContinuousClock.now < deadline, generation == token, !Task.isCancelled {
            let window = min(idle, secondsRemaining(deadline))
            if window <= 0 { break }
            // Nothing for a whole idle window means the line has settled.
            guard await waitForReadable(within: window, token: token), generation == token else { break }
            let n = scratch.withUnsafeMutableBytes {
                Darwin.read(handle, $0.baseAddress, 512)
            }
            if n > 0 {
                discarded += n
            } else if n == 0 {
                break                                       // EOF: device gone
            } else if !(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                break                                       // hard read error
            }
        }
        return discarded
    }

    func receive(_ count: Int, timeout: TimeInterval) async -> [UInt8]? {
        guard isOpen else { return nil }
        guard count > 0 else { return [] }

        var inbox = [UInt8]()
        inbox.reserveCapacity(count)
        let token = generation
        let deadline = ContinuousClock.now + .seconds(timeout)

        while inbox.count < count {
            if Task.isCancelled || generation != token { return nil }

            let remaining = secondsRemaining(deadline)
            if remaining <= 0 { return nil }
            guard await waitForReadable(within: remaining, token: token), generation == token else { return nil }

            let wanted = count - inbox.count
            var slice = [UInt8](repeating: 0, count: wanted)
            let n = slice.withUnsafeMutableBytes {
                Darwin.read(handle, $0.baseAddress, wanted)
            }

            if n > 0 {
                inbox.append(contentsOf: slice[0..<n])
            } else if n == 0 {
                return nil                                  // EOF: device gone
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try? await Task.sleep(nanoseconds: 8_000_000)
            } else {
                return nil                                  // hard read error
            }
        }
        return inbox
    }

    /// Wait until the descriptor is readable or `seconds` elapses.
    ///
    /// A single `poll()` with the full timeout would park the underlying Swift-
    /// concurrency cooperative-pool thread for the whole window (up to seconds) —
    /// no actual suspension — which on a low-core machine can starve other tasks
    /// (e.g. the detached image decodes). Instead we poll *non-blocking*
    /// (timeout 0) and `await Task.sleep` a few ms between checks: poll returns
    /// instantly and the sleep is a real suspension that frees the thread. The
    /// 5 ms cadence is far finer than the camera's ms-to-seconds response, so it
    /// adds no meaningful latency. Same contract: true iff readable before the
    /// deadline; false on timeout / cancellation / poll error.
    private func waitForReadable(within seconds: TimeInterval, token: UInt64) async -> Bool {
        guard isOpen else { return false }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            if Task.isCancelled || generation != token { return false }
            if ContinuousClock.now >= deadline { return false }

            var fds = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, 0)            // non-blocking probe
            if ready > 0 {
                return fds.revents & Int16(POLLIN) != 0
            }
            if ready < 0 && errno != EINTR { return false }

            try? await Task.sleep(nanoseconds: 5_000_000)   // yield ~5 ms, then re-poll
        }
    }

    // MARK: Closing

    private func secondsRemaining(_ deadline: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }

    func close() {
        generation &+= 1
        writing = false
        guard handle >= 0 else { return }
        _ = ioctl(handle, TIOCNXCL)
        _ = Darwin.close(handle)
        handle = -1
    }
}
