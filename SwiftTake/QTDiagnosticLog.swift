// A bounded serial-session trace. Snapshots are captured synchronously;
// filesystem work runs in detached tasks so it cannot stall camera exchanges.

import Foundation

nonisolated final class QTDiagnosticLog: @unchecked Sendable {
    static let shared = QTDiagnosticLog()
    private static let maxEntries = 4000
    private static let maxHexBytes = 32

    private struct Snapshot: Sendable {
        let body: String
        let session: UInt64
        let entryCount: Int
        let exportID: UInt64
    }

    private let lock = NSLock()
    private var entries: [String] = []
    private var started = Date()
    private var session: UInt64 = 0
    // Count appends, not buffer length: the latter stops growing at maxEntries.
    private var entryCount = 0
    private var savedEntryCount = 0
    private var nextExportID: UInt64 = 0
    private var lastSuccessfulExportID: UInt64 = 0
    private var exportedURL: URL?
    private let writer: @Sendable (String, URL) throws -> Void
    let traceDirectory: URL

    init(traceDirectory: URL = QTDiagnosticLog.defaultDirectory,
         writer: (@Sendable (String, URL) throws -> Void)? = nil) {
        self.traceDirectory = traceDirectory
        self.writer = writer ?? { @Sendable body, url in try Self.writeTrace(body, to: url) }
    }

    // Accessed only while this instance's lock is held.
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func log(_ category: String, _ message: String, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let elapsed = String(format: "%7.3f", now.timeIntervalSince(started))
        var line = "[\(stamp.string(from: now)) +\(elapsed)s] \(category.padding(toLength: 9, withPad: " ", startingAt: 0)) \(message)"
        if let detail, !detail.isEmpty { line += " — \(detail)" }
        append(line)
    }

    func log(_ category: String, _ message: String, bytes: [UInt8]) {
        let shown = bytes.prefix(Self.maxHexBytes)
            .map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = bytes.count > Self.maxHexBytes ? " … (\(bytes.count) bytes)" : " (\(bytes.count) bytes)"
        log(category, message, detail: shown.isEmpty ? "EMPTY" : shown + suffix)
    }

    /// Preserve any unsaved entries before clearing the buffer for a new attempt.
    /// The returned task allows callers to await persistence when necessary.
    @discardableResult
    func beginSession(_ header: String) -> Task<URL?, Never>? {
        lock.lock()
        let previous = entryCount > savedEntryCount ? snapshotLocked() : nil
        entries.removeAll(keepingCapacity: true)
        started = Date()
        session &+= 1
        entryCount = 0
        savedEntryCount = 0
        append("════ \(header)")
        append("════ SwiftTake \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lock.unlock()
        return previous.map { persist($0, to: traceDirectory) }
    }

    // Caller holds lock.
    private func append(_ line: String) {
        entries.append(line)
        entryCount += 1
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }

    var lastExportURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return exportedURL
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SwiftTake Traces", isDirectory: true)
    }

    @discardableResult
    @MainActor func export(to directory: URL? = nil) async -> URL? {
        await persist(snapshot(), to: directory ?? traceDirectory).value
    }

    /// Capture before returning: the next connect may immediately clear the ring.
    @discardableResult
    func flush() -> Task<URL?, Never> {
        persist(snapshot(), to: traceDirectory)
    }

    private func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    // Caller holds lock. Export IDs also prevent late writes replacing the
    // most recently requested successful export's reveal URL.
    private func snapshotLocked() -> Snapshot {
        nextExportID &+= 1
        return Snapshot(body: entries.joined(separator: "\n"), session: session,
                        entryCount: entryCount, exportID: nextExportID)
    }

    private func persist(_ snapshot: Snapshot, to directory: URL) -> Task<URL?, Never> {
        // Retain this logger until an accepted save completes, even if its
        // owner releases it immediately after calling flush/beginSession.
        Task.detached(priority: .utility) {
            self.write(snapshot, to: directory)
        }
    }

    private func write(_ snapshot: Snapshot, to directory: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "SwiftTake-Trace-\(formatter.string(from: Date()))-\(UUID().uuidString).txt"
        let url = directory.appendingPathComponent(name)
        do {
            try writer(snapshot.body, url)
            lock.lock()
            if snapshot.session == session {
                savedEntryCount = max(savedEntryCount, snapshot.entryCount)
            }
            if snapshot.exportID >= lastSuccessfulExportID {
                lastSuccessfulExportID = snapshot.exportID
                exportedURL = url
            }
            lock.unlock()
            return url
        } catch {
            NSLog("[QTDiagnosticLog] trace export failed: %@", String(describing: error))
            return nil
        }
    }

    private static func writeTrace(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor enum QTLog {
    nonisolated static func note(_ category: String, _ message: String, detail: String? = nil) {
        QTDiagnosticLog.shared.log(category, message, detail: detail)
    }

    nonisolated static func note(_ category: String, _ message: String, bytes: [UInt8]) {
        QTDiagnosticLog.shared.log(category, message, bytes: bytes)
    }

    static func begin(_ header: String) {
        QTDiagnosticLog.shared.beginSession(header)
    }

    /// Persist connection failures and disconnects without waiting for disk I/O.
    static func flush() {
        QTDiagnosticLog.shared.flush()
    }

    /// Summarise a decoded frame. A picture and a dead sensor both
    /// "succeed"; the histogram is what separates them, so it is logged
    /// on every decode rather than reconstructed later from a saved file.
    nonisolated static func frameStats(_ label: String, raw: [UInt16], maxValue: UInt16) {
        guard !raw.isEmpty else {
            note("DECODE", "\(label) produced NO pixels")
            return
        }
        // Sampled, allocation-free: a diagnostic that slows the decode is
        // a diagnostic nobody leaves switched on. Every 17th pixel (a
        // stride coprime with the row width, so it never samples one
        // Bayer phase) over 64 fixed buckets.
        var lo = UInt16.max, hi = UInt16.min
        var sum = 0.0
        var count = 0
        var buckets = [Bool](repeating: false, count: 64)
        let shift = max(0, Int(log2(Double(max(1, maxValue)))) - 5)
        var i = 0
        while i < raw.count {
            let v = raw[i]
            if v < lo { lo = v }
            if v > hi { hi = v }
            sum += Double(v)
            count += 1
            buckets[min(63, Int(v >> UInt16(shift)))] = true
            i += 17
        }
        let occupied = buckets.filter { $0 }.count
        let mean = sum / Double(max(1, count))
        // A real photograph — even a dark one — carries sensor noise and
        // so spreads across many levels. One or two occupied buckets over
        // a whole frame means filler, not a picture.
        let verdict = (occupied <= 2 || hi == lo) ? "FLAT / NO IMAGE" : "has detail"
        note("DECODE", "\(label) frame", detail:
            "min=\(lo) max=\(hi) mean=\(String(format: "%.1f", mean)) of 0…\(maxValue) · "
            + "levels=\(occupied)/64 → \(verdict)")
    }
}
