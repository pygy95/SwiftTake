import Darwin
import Foundation

/// Preserves camera originals: reuse identical bytes or publish a uniquely named copy.
/// Publication uses an exclusive rename; only destination collisions are retried.
nonisolated enum QTKArchiveStore {
    static func saveSafely(_ data: Data, candidateStem: String, in directory: URL) throws -> URL {
        let hasAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { directory.stopAccessingSecurityScopedResource() }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fm = FileManager.default
        var stem = candidateStem
        var n = 2
        while n < 10_000 {
            let destination = directory.appendingPathComponent(stem).appendingPathExtension("qtk")
            if fm.fileExists(atPath: destination.path) {
                if let existing = try? Data(contentsOf: destination), existing == data {
                    return destination
                }
                stem = "\(candidateStem) \(n)"; n += 1
                continue
            }

            let staging = directory.appendingPathComponent(".qtkstage-\(UUID().uuidString)").appendingPathExtension("qtk")
            try data.write(to: staging, options: .atomic)
            let rc = staging.path.withCString { src in
                destination.path.withCString { dst in
                    renamex_np(src, dst, UInt32(RENAME_EXCL))
                }
            }
            if rc == 0 { return destination }
            let publishErrno = errno
            try? fm.removeItem(at: staging)
            guard publishErrno == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(publishErrno))
            }
            stem = "\(candidateStem) \(n)"; n += 1
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
