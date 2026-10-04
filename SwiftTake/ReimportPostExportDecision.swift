import Foundation

/// Updates saved-file references only after a successful replacement export.
nonisolated enum ReimportPostExportDecision {
    static func apply(
        exportedURL: URL?,
        existingURLs: [URL],
        cleanStem: String,
        destination: URL,
        removeFile: (URL) -> Void
    ) -> [URL]? {
        guard let exportedURL else { return nil }
        var urls = CoplandArtifactPolicy.retiring(
            existingURLs, cleanStem: cleanStem, in: destination, remove: removeFile
        )
        if !urls.contains(exportedURL) { urls.append(exportedURL) }
        return urls
    }
}
