import Foundation
import ImageIO

// Fixed-output checks for `NamingMetadataPolicy` — the pure filename and
// export-metadata policy split out of `QuickTakeSerialManager`. No camera,
// no manager, no personal fixtures. The one on-disk input is the committed
// `IMAGE03.QTK` sample at the repository root.

@main struct NamingMetadataChecks {
    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1; print("PASS: " + name)
        }

        let utc = TimeZone(identifier: "UTC")!
        let pst = TimeZone(identifier: "America/Los_Angeles")!

        // ── stripModeTag: case-sensitive, trailing-only, stacked ───────
        check(NamingMetadataPolicy.stripModeTag(from: "QuickTake150_005") == "QuickTake150_005",
              "stripModeTag leaves an untagged stem alone")
        check(NamingMetadataPolicy.stripModeTag(from: "photo_enhanced") == "photo",
              "stripModeTag removes a single trailing tag")
        check(NamingMetadataPolicy.stripModeTag(from: "photo_enhanced_newtake_copland") == "photo",
              "stripModeTag peels a full stack of tags")
        check(NamingMetadataPolicy.stripModeTag(from: "photo_Copland") == "photo_Copland",
              "stripModeTag is case-sensitive (does not strip _Copland)")
        check(NamingMetadataPolicy.stripModeTag(from: "photo_copland_x") == "photo_copland_x",
              "stripModeTag only strips at the trailing edge")
        check(NamingMetadataPolicy.stripModeTag(from: "_copland") == "",
              "stripModeTag can reduce a bare tag to the empty string")

        // ── importStem: empty custom name ignored; date/no-date forms ──
        check(NamingMetadataPolicy.importStem(customName: nil, prefix: "QuickTake150", index: 5,
                                              dateStr: "19970315_142233") == "QuickTake150_19970315_142233_005",
              "importStem builds Prefix_date_NNN")
        check(NamingMetadataPolicy.importStem(customName: nil, prefix: "QuickTake150", index: 5,
                                              dateStr: nil) == "QuickTake150_005",
              "importStem builds Prefix_NNN when there is no date")
        check(NamingMetadataPolicy.importStem(customName: "", prefix: "QuickTake150", index: 5,
                                              dateStr: nil) == "QuickTake150_005",
              "importStem ignores an empty custom name")
        check(NamingMetadataPolicy.importStem(customName: "Beach_enhanced", prefix: "QuickTake150", index: 5,
                                              dateStr: "19970315_142233") == "Beach",
              "importStem honours a custom name and strips its mode tag")
        check(NamingMetadataPolicy.importStem(customName: nil, prefix: "FujifilmDS7", index: 250,
                                              dateStr: nil) == "FujifilmDS7_250",
              "importStem pads to at least three index digits without truncating")

        // ── baseFilenameStem: saved stem wins; empty custom accepted ──
        check(NamingMetadataPolicy.baseFilenameStem(savedFileStem: "QuickTake150_19970315_142233_005_newtake",
                                                    customName: "ignored", prefix: "QuickTake150", index: 5)
              == "QuickTake150_19970315_142233_005",
              "baseFilenameStem prefers the on-disk stem and strips its tag")
        check(NamingMetadataPolicy.baseFilenameStem(savedFileStem: nil, customName: "Trip_copland",
                                                    prefix: "QuickTake150", index: 5) == "Trip",
              "baseFilenameStem falls back to the custom name")
        check(NamingMetadataPolicy.baseFilenameStem(savedFileStem: nil, customName: "",
                                                    prefix: "QuickTake150", index: 5) == "",
              "baseFilenameStem accepts an empty custom name (unlike importStem)")
        check(NamingMetadataPolicy.baseFilenameStem(savedFileStem: nil, customName: nil,
                                                    prefix: "QuickTake150", index: 5) == "QuickTake150_005",
              "baseFilenameStem falls back to the generic indexed stem")

        // ── fujiDateStem: formatting and fallbacks ────────────────────
        check(NamingMetadataPolicy.fujiDateStem(captureDate: Date(timeIntervalSince1970: 0),
                                                cameraName: "DSC00007", timeZone: utc) == "QuickTake200_19700101_000000",
              "fujiDateStem formats the capture date in the given time zone")
        check(NamingMetadataPolicy.fujiDateStem(captureDate: nil, cameraName: "DSC00007", timeZone: utc) == "DSC00007",
              "fujiDateStem falls back to a non-empty camera name")
        check(NamingMetadataPolicy.fujiDateStem(captureDate: nil, cameraName: "", timeZone: utc) == "QuickTake200",
              "fujiDateStem falls back to QuickTake200 when the name is empty")
        check(NamingMetadataPolicy.fujiDateStem(captureDate: nil, cameraName: nil, timeZone: utc) == "QuickTake200",
              "fujiDateStem falls back to QuickTake200 when the name is nil")

        // ── parseImageDate: ranges and the year-80 pivot ─────────────
        func header(month: UInt8, day: UInt8, year: UInt8, h: UInt8, m: UInt8, s: UInt8) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 19)
            b[13] = month; b[14] = day; b[15] = year; b[16] = h; b[17] = m; b[18] = s
            return b
        }
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 3, day: 15, year: 97, h: 14, m: 22, s: 33))
              == "19970315_142233",
              "parseImageDate formats YYYYMMDD_HHMMSS with year >= 80 → 1900+y")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 1, day: 1, year: 5, h: 0, m: 0, s: 0))
              == "20050101_000000",
              "parseImageDate treats year 5 as 2005 (pivot at 80)")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 6, day: 1, year: 79, h: 0, m: 0, s: 0))
              == "20790601_000000",
              "parseImageDate treats year 79 as 2079 (just under the pivot)")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 6, day: 1, year: 80, h: 0, m: 0, s: 0))
              == "19800601_000000",
              "parseImageDate treats year 80 as 1980 (pivot boundary)")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 0, day: 15, year: 97, h: 0, m: 0, s: 0)) == nil,
              "parseImageDate rejects month 0")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 13, day: 15, year: 97, h: 0, m: 0, s: 0)) == nil,
              "parseImageDate rejects month 13")
        check(NamingMetadataPolicy.parseImageDate(from: header(month: 3, day: 32, year: 97, h: 0, m: 0, s: 0)) == nil,
              "parseImageDate rejects day 32")
        check(NamingMetadataPolicy.parseImageDate(from: [UInt8](repeating: 0, count: 18)) == nil,
              "parseImageDate needs at least 19 header bytes")

        check(NamingMetadataPolicy.parseImageDate(from: header(month: 1, day: 1, year: 97, h: 25, m: 61, s: 62))
              == "19970101_256162",
              "parseImageDate preserves out-of-range time fields")

        // ── parseImageDateAsDate: Gregorian/tz + release-date fallback ─
        let releaseFallback = Date(timeIntervalSince1970: 123_456_789)
        let parsed = NamingMetadataPolicy.parseImageDateAsDate(
            from: header(month: 3, day: 15, year: 97, h: 14, m: 22, s: 33),
            fallbackDate: releaseFallback, timeZone: utc)
        var gregUTC = Calendar(identifier: .gregorian); gregUTC.timeZone = utc
        let comps = gregUTC.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed ?? .distantPast)
        check(comps.year == 1997 && comps.month == 3 && comps.day == 15
              && comps.hour == 14 && comps.minute == 22 && comps.second == 33,
              "parseImageDateAsDate returns the header instant in the given time zone")
        check(NamingMetadataPolicy.parseImageDateAsDate(from: [UInt8](repeating: 0, count: 10),
              fallbackDate: releaseFallback, timeZone: utc) == releaseFallback,
              "parseImageDateAsDate returns the release-date fallback for a short header")
        // Feb 30 is in-range for the digit guards, so the Gregorian calendar
        // normalises it (→ Mar 2) rather than tripping the release-date
        // fallback — matching the manager's original behaviour exactly.
        let feb30 = NamingMetadataPolicy.parseImageDateAsDate(
            from: header(month: 2, day: 30, year: 97, h: 0, m: 0, s: 0),
            fallbackDate: releaseFallback, timeZone: utc)
        let feb30Comps = gregUTC.dateComponents([.year, .month, .day], from: feb30 ?? .distantPast)
        check(feb30 != releaseFallback && feb30Comps.year == 1997
              && feb30Comps.month == 3 && feb30Comps.day == 2,
              "parseImageDateAsDate normalises Feb 30 to Mar 2 via the Gregorian calendar")

        check(NamingMetadataPolicy.parseImageDateAsDate(
            from: header(month: 0, day: 15, year: 97, h: 0, m: 0, s: 0),
            fallbackDate: releaseFallback, timeZone: utc) == releaseFallback,
              "parseImageDateAsDate uses the release date for an invalid month")
        let parsedPST = NamingMetadataPolicy.parseImageDateAsDate(
            from: header(month: 3, day: 15, year: 97, h: 14, m: 22, s: 33),
            fallbackDate: releaseFallback, timeZone: pst)
        check(parsedPST == parsed?.addingTimeInterval(8 * 60 * 60),
              "parseImageDateAsDate interprets camera fields in the supplied time zone")

        // ── imageHeaderFromQTK: offset 14→header 4 mapping, signatures ─
        var qtk = [UInt8](repeating: 0, count: 74)
        qtk[0] = 0x71; qtk[1] = 0x6B; qtk[2] = 0x74; qtk[3] = 0x6E   // "qktn"
        for i in 0..<60 { qtk[14 + i] = UInt8((i * 7 + 1) & 0xFF) }
        let rebuilt = NamingMetadataPolicy.imageHeaderFromQTK(Data(qtk))
        check(rebuilt?.count == 64, "imageHeaderFromQTK returns a 64-byte buffer")
        check(rebuilt?.prefix(4).allSatisfy { $0 == 0 } == true, "imageHeaderFromQTK zero-fills header bytes 0..3")
        check((0..<60).allSatisfy { rebuilt?[4 + $0] == qtk[14 + $0] },
              "imageHeaderFromQTK maps file offset 14+i to header 4+i")
        check(NamingMetadataPolicy.imageHeaderFromQTK(Data(qtk.prefix(73))) == nil,
              "imageHeaderFromQTK needs at least 74 bytes")
        var badSig = qtk; badSig[2] = 0x00
        check(NamingMetadataPolicy.imageHeaderFromQTK(Data(badSig)) == nil,
              "imageHeaderFromQTK rejects a buffer without the qkt signature")

        var alternateSignature = qtk
        alternateSignature[3] = 0x00
        check(NamingMetadataPolicy.imageHeaderFromQTK(Data(alternateSignature)) == rebuilt,
              "imageHeaderFromQTK preserves acceptance of an arbitrary fourth signature byte")

        // Round-trip a synthetic QTK through both header helpers.
        var datedQTK = qtk
        datedQTK[23] = 3; datedQTK[24] = 15; datedQTK[25] = 97
        datedQTK[26] = 14; datedQTK[27] = 22; datedQTK[28] = 33
        check(NamingMetadataPolicy.imageHeaderFromQTK(Data(datedQTK))
                .flatMap(NamingMetadataPolicy.parseImageDate) == "19970315_142233",
              "imageHeaderFromQTK + parseImageDate round-trips a synthetic dated QTK")

        // Real committed fixture: signature is accepted and the mapping
        // holds; its reconstructed day byte (0x5D = 93) is out of range,
        // so date parsing declines — the documented real-data outcome.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("IMAGE03.QTK")
        let fixtureData = try Data(contentsOf: fixture)
        let fixtureHeader = NamingMetadataPolicy.imageHeaderFromQTK(fixtureData)
        check(fixtureHeader?.count == 64, "imageHeaderFromQTK accepts the committed IMAGE03.QTK fixture")
        check((0..<60).allSatisfy { fixtureHeader?[4 + $0] == fixtureData[14 + $0] },
              "imageHeaderFromQTK mirrors the fixture's bytes 14..73")
        check(fixtureHeader.flatMap(NamingMetadataPolicy.parseImageDate) == nil,
              "parseImageDate declines the fixture's out-of-range day byte")

        // ── exportMetadataProperties: keys, strings, optional dates ───
        func dict(_ props: [String: Any], _ key: CFString) -> [String: Any] {
            props[key as String] as? [String: Any] ?? [:]
        }
        func str(_ d: [String: Any], _ key: CFString) -> String? { d[key as String] as? String }

        let noDate = NamingMetadataPolicy.exportMetadataProperties(
            modelName: "QuickTake 150", appVersion: "1.2", modeLabel: "Vintage",
            captureDate: nil, timeZone: utc)
        let tiffND = dict(noDate, kCGImagePropertyTIFFDictionary)
        let exifND = dict(noDate, kCGImagePropertyExifDictionary)
        let pngND = dict(noDate, kCGImagePropertyPNGDictionary)
        check(str(tiffND, kCGImagePropertyTIFFMake) == "Apple"
              && str(tiffND, kCGImagePropertyTIFFModel) == "QuickTake 150"
              && str(tiffND, kCGImagePropertyTIFFSoftware) == "SwiftTake 1.2 — Vintage",
              "exportMetadataProperties writes the TIFF make/model/software strings")
        check(str(exifND, kCGImagePropertyExifUserComment) == "Shot on Apple QuickTake 150"
              && str(pngND, kCGImagePropertyPNGDescription) == "Shot on Apple QuickTake 150"
              && str(pngND, kCGImagePropertyPNGAuthor) == "Apple"
              && str(pngND, kCGImagePropertyPNGSoftware) == "SwiftTake 1.2 — Vintage",
              "exportMetadataProperties writes the EXIF/PNG comment and software strings")
        check(tiffND[kCGImagePropertyTIFFDateTime as String] == nil
              && exifND[kCGImagePropertyExifDateTimeOriginal as String] == nil
              && exifND[kCGImagePropertyExifDateTimeDigitized as String] == nil
              && pngND[kCGImagePropertyPNGCreationTime as String] == nil,
              "exportMetadataProperties omits every date key when there is no capture date")

        let expectedNoDate: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "QuickTake 150",
                kCGImagePropertyTIFFSoftware as String: "SwiftTake 1.2 — Vintage"
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "Shot on Apple QuickTake 150"
            ],
            kCGImagePropertyPNGDictionary as String: [
                kCGImagePropertyPNGAuthor as String: "Apple",
                kCGImagePropertyPNGDescription as String: "Shot on Apple QuickTake 150",
                kCGImagePropertyPNGSoftware as String: "SwiftTake 1.2 — Vintage"
            ]
        ]
        check(NSDictionary(dictionary: noDate).isEqual(to: expectedNoDate),
              "exportMetadataProperties produces exactly the expected no-date dictionary")

        let dated = NamingMetadataPolicy.exportMetadataProperties(
            modelName: "QuickTake 150", appVersion: "1.2", modeLabel: "NewTake HDR",
            captureDate: Date(timeIntervalSince1970: 0), timeZone: utc)
        let tiffD = dict(dated, kCGImagePropertyTIFFDictionary)
        let exifD = dict(dated, kCGImagePropertyExifDictionary)
        let pngD = dict(dated, kCGImagePropertyPNGDictionary)
        check(str(tiffD, kCGImagePropertyTIFFDateTime) == "1970:01:01 00:00:00",
              "exportMetadataProperties writes the EXIF-style TIFF DateTime in UTC")
        check(str(exifD, kCGImagePropertyExifDateTimeOriginal) == "1970:01:01 00:00:00"
              && str(exifD, kCGImagePropertyExifDateTimeDigitized) == "1970:01:01 00:00:00",
              "exportMetadataProperties writes matching EXIF original/digitized stamps")
        check(str(pngD, kCGImagePropertyPNGCreationTime) == "1970-01-01T00:00:00Z",
              "exportMetadataProperties writes an ISO-8601 PNG CreationTime (Z for UTC)")
        check(str(tiffD, kCGImagePropertyTIFFSoftware) == "SwiftTake 1.2 — NewTake HDR",
              "exportMetadataProperties folds the mode label into the software string")

        let datedPST = NamingMetadataPolicy.exportMetadataProperties(
            modelName: "QuickTake 200", appVersion: "1.3", modeLabel: "Vintage",
            captureDate: Date(timeIntervalSince1970: 0), timeZone: pst)
        check(str(dict(datedPST, kCGImagePropertyTIFFDictionary), kCGImagePropertyTIFFDateTime)
              == "1969:12:31 16:00:00",
              "exportMetadataProperties honours a non-UTC time zone for the TIFF stamp")
        check(str(dict(datedPST, kCGImagePropertyPNGDictionary), kCGImagePropertyPNGCreationTime)
              == "1969-12-31T16:00:00-08:00",
              "exportMetadataProperties emits the numeric offset for a non-UTC PNG CreationTime")

        print("\nAll \(passed) naming/metadata checks passed.")
    }
}
