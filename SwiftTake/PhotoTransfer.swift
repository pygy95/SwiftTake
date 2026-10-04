// MARK: - Per-photo transfer model
//
// The value type for one in-flight or finished camera transfer, plus the
// out-of-band progress store the UI reads while a transfer runs. Both are
// consumed by the manager and by ContentView; neither carries transfer
// logic, so they live away from the manager.

import Foundation

/// Live per-photo transfer progress, kept OUTSIDE the manager's @Published
/// state. Progress ticks ~8×/s during an import or develop (per-chunk
/// callbacks, the simulated develop, the decode phantom ticker); routing those
/// through @Published mutations would re-evaluate the entire ContentView body
/// every tick, which reads as scroll stutter during a Copland develop. Same
/// idea as ContentView's ThumbFrameStore: writes here invalidate only the
/// small views that read the store (BatchProgressBar). Terminal values still
/// flow through PhotoTransfer on status edges, so array-based logic and
/// summaries stay correct.
@Observable
final class TransferProgressStore {
    /// Fractional progress per gallery index while its transfer runs.
    /// Cleared whenever a new transfer list is built.
    var values: [UUID: Double] = [:]
}

struct PhotoTransfer: Identifiable {
    let id = UUID()
    let index: UInt8
    var progress: Double
    var status: Status
    var savedFiles: [URL]

    /// Lifecycle of one transfer chip. An enum (rather than a free-form String
    /// compared with `==`) so the compiler owns the state names and a renamed
    /// state can't silently break a comparison. The text is never displayed;
    /// the states exist for control flow and debugging.
    enum Status: Equatable {
        // In flight
        case waiting
        case reading
        case downloading
        case decoding
        case writing
        case converting
        case developing
        // Terminal — success
        case imported
        case reimported
        case skipped
        case alreadyCurrent
        // Terminal — failure / cancel
        case cancelled
        case failedHeader
        case failedDownload
        case decodingFailed
        case noSource
        case couldntWriteFile
        case saveError(detail: String?)
    }
}
