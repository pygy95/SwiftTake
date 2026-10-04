import Foundation
import Darwin

/// Stage beside the destination, then publish atomically. Exclusive publication
/// refuses collisions; replacement requires an explicit caller decision.
nonisolated enum AtomicFileWriter {
    enum CollisionMode: Sendable { case exclusive, replace }

    /// The job was no longer current when publication was attempted —
    /// nothing was written; any prior file at the destination is untouched.
    struct ObsoleteJobError: LocalizedError {
        var errorDescription: String? { "the import was cancelled before this photo could be saved." }
    }
    /// `.exclusive` publication lost the race to a file that appeared at the
    /// destination after the caller's own duplicate check.
    struct DestinationExistsError: LocalizedError {
        var errorDescription: String? { "another file appeared with that name while saving — try again." }
    }

    /// Keep staging on the destination filesystem so rename remains atomic.
    static func temporaryURL(besides destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".swifttake-" + UUID().uuidString)
            .appendingPathExtension(destination.pathExtension)
    }

    /// Check currency after encoding, immediately before publication.
    static func write(to destination: URL, collisionMode: CollisionMode = .replace,
                      isCurrent: @Sendable () -> Bool = { true },
                      encode: (URL) throws -> Void) throws {
        let temporary = temporaryURL(besides: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encode(temporary)
        try publish(temporary, to: destination, collisionMode: collisionMode, isCurrent: isCurrent)
    }

    /// Publish an already-staged file. Actor-bound callers check their own
    /// generation immediately before this call, with no intervening await.
    static func publish(_ temporary: URL, to destination: URL, collisionMode: CollisionMode,
                        isCurrent: @Sendable () -> Bool = { true }) throws {
        guard isCurrent() else {
            try? FileManager.default.removeItem(at: temporary)
            throw ObsoleteJobError()
        }
        switch collisionMode {
        case .replace:
            guard rename(temporary.path, destination.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        case .exclusive:
            let rc = temporary.path.withCString { src in
                destination.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) }
            }
            guard rc == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temporary)
                if code == EEXIST { throw DestinationExistsError() }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }
}
