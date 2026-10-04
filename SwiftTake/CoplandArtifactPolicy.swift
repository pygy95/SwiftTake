import Foundation

/// Recognizes Copland exports for presentation and matches exact paths for retirement.
nonisolated enum CoplandArtifactPolicy {
    /// A filename hint for display only; deletion requires the exact-path check below.
    static func isDisplayArtifact(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "png"
            && url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("_copland")
    }

    static let artifactSuffix = "_copland.png"

    static func artifactFilename(cleanStem: String) -> String {
        "\(cleanStem)\(artifactSuffix)"
    }

    static func artifactURL(in destination: URL, cleanStem: String) -> URL {
        destination.appendingPathComponent(artifactFilename(cleanStem: cleanStem))
    }

    static func isGeneratedArtifact(_ url: URL, cleanStem: String, in destination: URL) -> Bool {
        url.standardizedFileURL == artifactURL(in: destination, cleanStem: cleanStem).standardizedFileURL
    }

    static func retiring(
        _ urls: [URL],
        cleanStem: String,
        in destination: URL,
        remove: (URL) -> Void
    ) -> [URL] {
        urls.filter { existing in
            guard isGeneratedArtifact(existing, cleanStem: cleanStem, in: destination) else { return true }
            remove(existing)
            return false
        }
    }

    /// Picks a "finished frame" candidate from a photo's on-disk URLs: the
    /// first entry with a readable extension that is NOT the Copland
    /// gallery artifact (filename hint only, matching `isDisplayArtifact`).
    /// After Copland develop, a QT200 photo's URL list can be exactly
    /// `[..._copland.png]` — the Mac OS 9 framed window, not a real render —
    /// so when every readable entry is an artifact this returns `nil`
    /// rather than the framed PNG, letting the caller fall back to the
    /// session cache or the camera.
    static func preferredDiskCandidate(in urls: [URL], readableExtensions: Set<String>) -> URL? {
        urls.first { url in
            readableExtensions.contains(url.pathExtension.lowercased()) && !isDisplayArtifact(url)
        }
    }
}
