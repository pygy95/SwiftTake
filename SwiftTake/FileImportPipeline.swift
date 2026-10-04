import AppKit
import Foundation

/// Processes dropped files through detached decoding and MainActor export callbacks.
/// The manager owns destination access, transfer identities and presentation.
nonisolated enum FileImportPipeline {

    /// The image is read-only after leaving its decode task.
    struct DropConversion: @unchecked Sendable {
        let image: NSImage
        let captureDate: Date?
        let baseName: String
        let header: [UInt8]?
    }

    struct Item {
        let id: UUID
        let url: URL
        let data: Data
    }

    struct Summary {
        var importedFiles: [URL] = []
        var decodeFailures = 0
        var saveFailures = 0
        var cancelled = false
        var succeeded: Int { importedFiles.count }
        var failed: Int { decodeFailures + saveFailures }
    }

    static func sortedByFilename(_ urlDataMap: [URL: Data]) -> [(url: URL, data: Data)] {
        urlDataMap
            .sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
            .map { (url: $0.key, data: $0.value) }
    }

    /// The export callback must resolve its name and snapshot settings before suspending.
    static func run(
        items: [Item],
        decode: @escaping @Sendable (URL, Data) -> DropConversion?,
        exportDecoded: @escaping @MainActor @Sendable (
            _ baseName: String, _ image: NSImage, _ captureDate: Date?, _ header: [UInt8]?
        ) async throws -> URL?,
        onUpdate: @escaping @MainActor @Sendable (
            _ id: UUID, _ progress: Double, _ status: PhotoTransfer.Status, _ savedFiles: [URL]?
        ) async -> Void
    ) async -> Summary {
        var summary = Summary()

        for item in items {
            guard !Task.isCancelled else { summary.cancelled = true; break }
            await onUpdate(item.id, 0.05, .converting, nil)
            guard !Task.isCancelled else { summary.cancelled = true; break }

            let ticker = Task {
                var p = 0.05
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    if Task.isCancelled { return }
                    p += (0.9 - p) * 0.14
                    await onUpdate(item.id, p, .converting, nil)
                }
            }

            let url = item.url
            let data = item.data
            let result = await Task.detached(priority: .userInitiated) {
                decode(url, data)
            }.value
            ticker.cancel()
            // Drain any in-flight progress callback before publishing terminal state.
            await ticker.value
            guard !Task.isCancelled else { summary.cancelled = true; break }

            guard let result else {
                summary.decodeFailures += 1
                await onUpdate(item.id, 0, .decodingFailed, nil)
                continue
            }
            await onUpdate(item.id, 0.95, .converting, nil)
            guard !Task.isCancelled else { summary.cancelled = true; break }

            do {
                if let saved = try await exportDecoded(result.baseName, result.image, result.captureDate, result.header) {
                    summary.importedFiles.append(saved)
                    await onUpdate(item.id, 1.0, .imported, [saved])
                } else {
                    summary.decodeFailures += 1
                    await onUpdate(item.id, 0, .decodingFailed, nil)
                }
            } catch is CancellationError {
                summary.cancelled = true
                break
            } catch {
                summary.saveFailures += 1
                await onUpdate(item.id, 0, .saveError(detail: error.localizedDescription), nil)
            }
        }

        return summary
    }
}
