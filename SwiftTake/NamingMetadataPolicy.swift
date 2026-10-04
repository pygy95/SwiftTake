import Foundation
import ImageIO

/// Filename and image metadata rules, independent of camera and application state.
nonisolated enum NamingMetadataPolicy {

    // MARK: Filename stems

    /// Removes stacked, case-sensitive trailing mode tags. Keep `enhanced` for
    /// compatibility with files exported before the NewTake rename.
    static func stripModeTag(from stem: String) -> String {
        var stripped = stem
        while true {
            var changed = false
            for tag in ["copland", "newtake", "enhanced"] {
                let suffix = "_\(tag)"
                if stripped.hasSuffix(suffix) {
                    stripped = String(stripped.dropLast(suffix.count))
                    changed = true
                }
            }
            if !changed { return stripped }
        }
    }

    /// Uses a non-empty custom name, otherwise a dated or indexed model stem.
    static func importStem(customName: String?, prefix: String, index: Int, dateStr: String?) -> String {
        if let customName, !customName.isEmpty {
            return stripModeTag(from: customName)
        }
        if let dateStr {
            return String(format: "%@_%@_%03d", prefix, dateStr, index)
        }
        return String(format: "%@_%03d", prefix, index)
    }

    /// Prefers the saved stem, then a custom name, then an indexed model stem.
    /// Unlike initial import, re-import historically accepts an empty custom name.
    static func baseFilenameStem(savedFileStem: String?, customName: String?, prefix: String, index: Int) -> String {
        if let savedFileStem {
            return stripModeTag(from: savedFileStem)
        }
        if let customName {
            return stripModeTag(from: customName)
        }
        return String(format: "%@_%03d", prefix, index)
    }

    /// Formats a QT200 capture date, falling back to the camera name or model.
    /// JPEG date decoding remains the caller's responsibility.
    static func fujiDateStem(captureDate: Date?, cameraName: String?, timeZone: TimeZone = .current) -> String {
        guard let captureDate else {
            return (cameraName?.isEmpty == false ? cameraName! : "QuickTake200")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"   // matches the app-wide Prefix_date_time scheme
        df.timeZone = timeZone
        return "QuickTake200_\(df.string(from: captureDate))"
    }

    // MARK: Capture-date parsing

    /// Reads date fields at header offsets 13...18; two-digit years pivot at 80.
    /// Preserves the camera format's month/day guards without validating the time.
    static func parseImageDate(from header: [UInt8]) -> String? {
        guard header.count >= 19 else { return nil }
        let month = Int(header[13])
        let day = Int(header[14])
        let y = Int(header[15])
        let hour = Int(header[16])
        let minute = Int(header[17])
        let second = Int(header[18])

        guard month > 0, month <= 12, day > 0, day <= 31 else { return nil }

        let year = y < 80 ? 2000 + y : 1900 + y
        return String(format: "%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
    }

    /// Uses Gregorian calendar normalisation in the supplied time zone.
    /// Missing or invalid month/day fields use the camera's release-date Easter egg.
    static func parseImageDateAsDate(from header: [UInt8], fallbackDate: Date, timeZone: TimeZone = .current) -> Date? {
        guard header.count >= 19 else { return fallbackDate }
        let month = Int(header[13])
        let day = Int(header[14])
        let y = Int(header[15])
        let hour = Int(header[16])
        let minute = Int(header[17])
        let second = Int(header[18])
        guard month > 0, month <= 12, day > 0, day <= 31 else { return fallbackDate }

        var comp = DateComponents()
        comp.year = y < 80 ? 2000 + y : 1900 + y
        comp.month = month
        comp.day = day
        comp.hour = hour
        comp.minute = minute
        comp.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: comp) ?? fallbackDate
    }

    /// Maps QTK file bytes 14...73 to image header bytes 4...63.
    /// Only the first three signature bytes are checked for compatibility.
    static func imageHeaderFromQTK(_ data: Data) -> [UInt8]? {
        guard data.count >= 74 else { return nil }
        let bytes = [UInt8](data.prefix(74))
        guard bytes[0] == 0x71, bytes[1] == 0x6B, bytes[2] == 0x74 else { return nil }
        var fake = [UInt8](repeating: 0, count: 64)
        for i in 0..<60 {
            fake[4 + i] = bytes[14 + i]
        }
        return fake
    }

    // MARK: Export metadata

    /// Builds TIFF, EXIF and PNG properties, omitting date keys when no date exists.
    static func exportMetadataProperties(
        modelName: String,
        appVersion: String,
        modeLabel: String,
        captureDate: Date?,
        timeZone: TimeZone = .current
    ) -> [String: Any] {
        let software = "SwiftTake \(appVersion) — \(modeLabel)"
        let shotComment = "Shot on Apple \(modelName)"

        var tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: modelName,
            kCGImagePropertyTIFFSoftware as String: software
        ]
        var exif: [String: Any] = [
            kCGImagePropertyExifUserComment as String: shotComment
        ]
        var png: [String: Any] = [
            kCGImagePropertyPNGAuthor as String: "Apple",
            kCGImagePropertyPNGDescription as String: shotComment,
            kCGImagePropertyPNGSoftware as String: software
        ]

        if let captureDate {
            let exifFormatter = DateFormatter()
            exifFormatter.locale = Locale(identifier: "en_US_POSIX")
            exifFormatter.timeZone = timeZone
            exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let stamp = exifFormatter.string(from: captureDate)
            tiff[kCGImagePropertyTIFFDateTime as String] = stamp
            exif[kCGImagePropertyExifDateTimeOriginal as String] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized as String] = stamp

            let isoFormatter = DateFormatter()
            isoFormatter.locale = Locale(identifier: "en_US_POSIX")
            isoFormatter.timeZone = timeZone
            isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            png[kCGImagePropertyPNGCreationTime as String] = isoFormatter.string(from: captureDate)
        }

        return [
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyPNGDictionary as String: png
        ]
    }
}
