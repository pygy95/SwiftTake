import Foundation

/// The QT100/150 session's transport boundary. Production uses SerialPort;
/// scripted transports exercise framing and interleaving without a camera.
nonisolated protocol QuickTakeTransport: Sendable {
    func open(path: String, baud: Int, parity: SerialPort.Parity) async throws
    func close() async
    func reconfigure(baud: Int, parity: SerialPort.Parity) async throws
    func setDTR(_ asserted: Bool) async
    @discardableResult func send(_ bytes: [UInt8]) async -> Bool
    func receive(_ count: Int, timeout: TimeInterval) async -> [UInt8]?
    @discardableResult
    func drain(idleFor idle: TimeInterval, limit: TimeInterval) async -> Int
}

extension SerialPort: QuickTakeTransport {}

/// Bounded scanner for the camera's seven-byte wake packet. Retains a partial
/// prefix across reads, discards leading chatter, and preserves unknown model
/// bytes for the session's existing identity policy.
nonisolated struct QuickTakeWakeBuffer {
    private var bytes: [UInt8] = []
    private(set) var discardedBytes = 0

    mutating func append(_ byte: UInt8) -> [UInt8]? {
        if bytes.isEmpty {
            if byte == 0xA5 { bytes.append(byte) }
            else { discardedBytes += 1 }
        } else if bytes.count == 1 {
            if byte == 0x5A {
                bytes.append(byte)
            } else {
                discardedBytes += bytes.count
                bytes.removeAll(keepingCapacity: true)
                if byte == 0xA5 { bytes.append(byte) }
                else { discardedBytes += 1 }
            }
        } else {
            bytes.append(byte)
        }
        guard bytes.count == 7 else { return nil }
        let packet = bytes
        bytes.removeAll(keepingCapacity: true)
        return packet
    }
}
