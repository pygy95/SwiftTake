import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Stage all formats before publishing. Failed encodes never replace an
/// existing panorama or leave the composer reporting a partial success.
nonisolated enum PanoramaExport {
    enum ExportError: LocalizedError {
        case pngFailed
        var errorDescription: String? { "The flat PNG could not be written." }
    }

    static func write(strip: CGImage, sweepDegrees: Double, destination: URL,
                      alignmentNote: String? = nil,
                      onStaged: @Sendable () -> Void = {}) throws -> [URL] {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = destination.appendingPathComponent(".panorama-" + id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let stem = (alignmentNote == nil ? "Panorama_" : "Panorama_QuickPan_") + stamp.string(from: Date()) + "_" + id.prefix(8)
        let flat = staging.appendingPathComponent(stem + ".png")
        guard let encoder = CGImageDestinationCreateWithURL(flat as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.pngFailed
        }
        let properties: CFDictionary? = alignmentNote.map {
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: $0]] as CFDictionary
        }
        CGImageDestinationAddImage(encoder, strip, properties)
        guard CGImageDestinationFinalize(encoder) else { throw ExportError.pngFailed }
        try Task.checkCancellation()

        let interactive = staging.appendingPathComponent(stem + ".html")
        try InteractivePanoramaWriter.write(panorama: strip, sweepDegrees: sweepDegrees, to: interactive, alignmentNote: alignmentNote)
        try Task.checkCancellation()
        let immersive = try ImmersivePanoramaWriter.write(
            panorama: strip, sweepDegrees: sweepDegrees,
            to: staging.appendingPathComponent(stem + " (Immersive).heic"))
        onStaged()
        try Task.checkCancellation()

        var published: [URL] = []
        do {
            for source in [flat, interactive, immersive.url] {
                try Task.checkCancellation()
                let target = destination.appendingPathComponent(source.lastPathComponent)
                // moveItem refuses an existing target, including on a name collision.
                try fm.moveItem(at: source, to: target)
                published.append(target)
            }
            try Task.checkCancellation()
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
        return published
    }
}
