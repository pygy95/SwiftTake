// MARK: - CameraDiagnostics
//
// Cross-family camera diagnostics. Each session type knows how to probe its
// own (private) serial port, so the capture routine has to live inside the
// session — but they all expose the same parameter-free async entry point
// here, so the manager can run diagnostics for any connected camera through
// one switch.
//
// `FujiCameraSession` already implements `captureDiagnostics()` (its big A–E
// matrix), so it conforms with an empty extension — no edits to that file.
// `QuickTakeCameraSession` (Kodak QT100/150) implements it in its own file
// using the shared `DiagReport` builder below so every report reads the
// same way.

import Foundation

/// A camera session that can produce a copy-pasteable diagnostic report.
/// Async + parameter-free so `final class` and `actor` sessions alike conform.
protocol CameraDiagnosticsCapable {
    func captureDiagnostics() async -> String
}

// Fuji already has the method (FujiCameraSession.captureDiagnostics()).
extension FujiCameraSession: CameraDiagnosticsCapable {}
extension QuickTakeCameraSession: CameraDiagnosticsCapable {}

/// Tiny report builder shared by the Kodak diagnostics so its output matches
/// the Fuji session's house format (title / sections / hex+ASCII). Fuji
/// keeps its own private equivalent; this is the shared one.
///
/// `nonisolated` so an `actor`-based session can build a report on its own
/// executor without hopping to the main actor — it's a pure value type with
/// no shared state, so it's safe from anywhere.
nonisolated struct DiagReport {
    private(set) var text = ""

    mutating func line(_ s: String = "") { text += s + "\n" }
    mutating func rule() { line(String(repeating: "─", count: 60)) }
    mutating func title(_ s: String) { line(s); rule() }
    mutating func section(_ s: String) { line(); rule(); line(s); rule() }

    /// A labelled reply: hex dump + printable-ASCII gutter, or the empty mark.
    mutating func reply(label: String, bytes: [UInt8]) {
        line("[\(label)]")
        if bytes.isEmpty {
            line("  ∅ no response")
        } else {
            line("  \(DiagReport.hex(bytes))")
            line("  ascii \"\(DiagReport.ascii(bytes))\"")
        }
    }

    /// A sent→received exchange (what we put on the wire, then what came back).
    mutating func exchange(label: String, sent: [UInt8], got: [UInt8]) {
        line("[\(label)] sent \(DiagReport.hex(sent))")
        if got.isEmpty {
            line("  ∅ no response")
        } else {
            line("  got \(DiagReport.hex(got))")
            line("  ascii \"\(DiagReport.ascii(got))\"")
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "∅ (no reply)" }
        let body = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(body)   (\(bytes.count) bytes)"
    }

    static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}
