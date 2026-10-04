// MARK: - QTKFormatter
//
// Model and file-format scaffolding:
//
//   - `QuickTakeModel` — the Apple QuickTake trio (100/150/200) plus
//     their cable-mate siblings, grouped by the two physical serial-cable
//     families:
//       • 8-pin mini-DIN (Kodak): QT100, QT150
//       • 2.5 mm stereo (Fujifilm): QT200, Fujifilm DS-7,
//         Samsung Kenox SSC-350N
//     QT100/150 are Kodak-built (proprietary `.QTK` Bayer); QT200 is the
//     rebadged Fujifilm DS-7 (standard JPEG on SmartMedia, different wire
//     protocol from Kodak's). Capability flags below let UI surfaces query
//     the model rather than branch on the enum case.
//
//   - `QuickTakeExportFormat` — TIFF / PNG / JPEG / HEIC plus metadata
//     helpers (`displayName`, `fileExtension`, `isLossless`, `utType`).
//     HEIC is the only format that carries HDR through to the saved file;
//     the others clamp to SDR.
//
//   - `QTKFormatter` — reassembles the 736-byte `.QTK` header plus decoded
//     image bytes into an authentic QuickTake file on disk (the "Keep
//     Original Files" toggle). Applies only to the Kodak-family cameras;
//     QT200 stores standard JPEG and has no `.QTK` equivalent.

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Which serial-protocol family a given camera speaks.
///
/// `kodak` — QT100/QT150 only. The Apple-branded cameras Kodak built,
/// speaking the Kodak command family implemented in
/// `QuickTakeCommands.swift`.
/// `fuji` — QT200 plus the Fujifilm DS-7 and Samsung Kenox SSC-350N.
/// The wire protocol lives in `FujiCameraSession.swift`.
enum QuickTakeProtocolFamily {
    case kodak
    case fuji
}

enum QuickTakeModel: String, CaseIterable, Identifiable {

    // ─── Apple QuickTake (the headliners) ──────────────────────────
    case qt100 = "QT100"
    case qt150 = "QT150"
    case qt200 = "QT200"

    // ─── Fujifilm siblings (2.5 mm stereo cable family) ────────────
    // Same Fuji DS-7 wire protocol and JPEG-on-SmartMedia files as the
    // QT200 (a rebadged DS-7).
    /// Fujifilm DS-7 (1996) — the camera Apple rebadged a year later as the
    /// QuickTake 200. Same protocol and JPEG on SmartMedia.
    case fujiDS7 = "FujiDS7"
    /// Samsung Kenox SSC-350N — Samsung-branded camera in the same Fujifilm
    /// DS-7 cable + protocol family (a rebadge or close sibling sold in the
    /// Korean market). Byte-level verification pending.
    case samsungSSC350N = "SamsungSSC350N"

    var id: String { rawValue }

    /// Human-readable name. Used in Settings, the EXIF "Model" tag, mismatch
    /// alerts, and anywhere the camera is shown to the user.
    var displayName: String {
        switch self {
        case .qt100:          return "QuickTake 100"
        case .qt150:          return "QuickTake 150"
        case .qt200:          return "QuickTake 200"
        case .fujiDS7:        return "Fujifilm DS-7"
        case .samsungSSC350N: return "Samsung Kenox SSC-350N"
        }
    }

    /// Filename prefix for photos imported from this camera — the display
    /// name with spaces removed ("QuickTake150", "FujifilmDS7"), per the
    /// app-wide `Prefix_YYYYMMDD_HHMMSS_NNN[_mode]` naming scheme.
    var fileNamePrefix: String {
        displayName.replacingOccurrences(of: " ", with: "")
    }

    /// Wire-protocol family. Two families across the supported cameras:
    ///   - `.kodak` for QT100/QT150 (the Apple-branded Kodak-built ones)
    ///   - `.fuji` for QT200 + Fujifilm DS-7 + Samsung Kenox
    var protocolFamily: QuickTakeProtocolFamily {
        switch self {
        case .qt100, .qt150:
            return .kodak
        case .qt200, .fujiDS7, .samsungSSC350N:
            return .fuji
        }
    }

    /// Does the camera write Apple's proprietary 736-byte `.QTK` Bayer
    /// container? Only the QuickTake-branded Kodak models do. The
    /// Fuji-family cameras write JPEG.
    var usesQTKFormat: Bool {
        switch self {
        case .qt100, .qt150:
            return true
        case .qt200, .fujiDS7, .samsungSSC350N:
            return false
        }
    }

    /// Does the camera produce a proprietary raw worth keeping a verbatim copy
    /// of, so it can be re-decoded through any colour pipeline later? True for
    /// the QTK Bayer format (QT100/150). The Fuji/QT200 family writes finished
    /// JPEGs, so there's no original worth a second copy — the rendered
    /// export is the same picture.
    var producesProprietaryRaw: Bool {
        protocolFamily != .fuji
    }

    /// Does the camera offer a two-step quality toggle? Every supported
    /// model does. The QuickTake 100 shoots the same HQ 640×480 / SQ
    /// 320×240 pair as the 150 — its own archives record which was used
    /// (QTK byte 7: 0x08 HQ, 0x04 SQ), its status block reports the mode
    /// in byte 27 (16 HQ / 32 SQ), and the set command is the shared
    /// Kodak-family one, so nothing about the wire path is 150-specific.
    var supportsQualityToggle: Bool { true }

    /// Wording for the quality toggle (`high` is the bigger / better
    /// mode, `low` is the more-compressed one). Kodak family uses HQ/SQ;
    /// Fuji family uses Fine/Normal.
    var qualityModeLabels: (high: String, low: String) {
        switch self {
        case .qt100, .qt150:
            return ("HQ", "SQ")
        case .qt200, .fujiDS7, .samsungSSC350N:
            return ("Fine", "Normal")
        }
    }

    /// Whether the live camera-control UI (take-picture, flash, quality,
    /// self-timer, battery readout) is wired up for this model. True only
    /// for hardware-verified models.
    var supportsCameraControlUI: Bool {
        switch self {
        case .qt100, .qt150:
            return true
        case .qt200, .fujiDS7, .samsungSSC350N:
            return false
        }
    }

    /// Whether the camera accepts an erase-over-serial command, gating the
    /// delete button. The QuickTake 200 NAKs the erase opcode (0x19) on real
    /// hardware despite its capability descriptor, and the DS-7 / Kenox
    /// siblings (which would need a delete-by-index path) are unverified — so
    /// the whole Fuji family hides delete and leaves photos on the camera.
    /// Kodak QT100/150 erase works.
    var supportsSerialErase: Bool {
        protocolFamily != .fuji
    }

    /// Whether the serial-connect path is HARDWARE-VERIFIED for this model.
    /// True for every model this app ships: QT100/150 via
    /// `QuickTakeCameraSession`, and QT200 / Fujifilm DS-7 / Samsung Kenox
    /// via `FujiCameraSession`.
    var serialProtocolImplemented: Bool { true }

    /// Connector on the camera side, shown by ConnectionHelpView so users
    /// know which cable they need. Kodak shares an 8-pin mini-DIN;
    /// Fuji/Samsung share a 2.5 mm stereo miniplug.
    var cameraConnectorDescription: String {
        switch self {
        case .qt100, .qt150:
            return "8-pin mini-DIN serial (same as the classic-Mac modem cable)"
        case .qt200, .fujiDS7, .samsungSSC350N:
            return "2.5 mm stereo miniplug (shared across the Fujifilm family; needs a 2.5 mm-to-DIN-8 adapter on the Mac side)"
        }
    }

    /// The camera's release date — used as the vintage fallback for `.qtk`
    /// files whose date header is missing or unreadable (instead of the usual
    /// 1970 UNIX epoch). Dates are the models' public introductions; day-level
    /// precision is approximate where only a month/year is documented.
    var releaseDate: Date {
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")
        switch self {
        case .qt100:          (c.year, c.month, c.day) = (1994, 6, 20)
        case .qt150:          (c.year, c.month, c.day) = (1995, 4, 17)
        case .qt200:          (c.year, c.month, c.day) = (1997, 3, 1)
        case .fujiDS7:        (c.year, c.month, c.day) = (1996, 3, 1)
        case .samsungSSC350N: (c.year, c.month, c.day) = (1997, 1, 1)
        }
        c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    /// The user-facing selection profile this model belongs to. Several models
    /// that speak the *identical* protocol collapse into one profile so the
    /// camera picker isn't a flat list of near-duplicates.
    var profile: CameraProfile {
        switch protocolFamily {
        case .kodak: return self == .qt100 ? .quickTake100 : .quickTake150
        case .fuji:  return .quickTake200
        }
    }
}

/// A user-facing camera profile for selection. The Fuji family (QuickTake 200,
/// Fujifilm DS-7/DS-8, Samsung Kenox SSC-350N) speaks one identical serial
/// protocol, so it's a single choice. The exact model is auto-refined on
/// connect (`resolveModel`) or from the file header (the QTK decoder reads
/// `qktk`/`qktn`), so the user never has to disambiguate near-identical
/// siblings.
enum CameraProfile: String, CaseIterable, Identifiable {
    case quickTake100
    case quickTake150
    case quickTake200      // QT200 + Fuji DS-7/DS-8 + Samsung Kenox — identical protocol

    /// The cameras this app is ABOUT: the three QuickTakes.
    ///
    /// A Kodak DC40/DC50/DC120 (+ Chinon ES-3000) profile lived here once —
    /// added because those bodies shared the QT200's protocol and the
    /// QT100/150's decoders, so supporting them looked nearly free. It was
    /// not free — it bought a fourth protocol family, two extra decoders, a
    /// thumbnail renderer, and a branch in every format decision — and none
    /// of it was ever run against real hardware, because there was none to
    /// run it against. Support nobody can test is a claim, not a feature.
    /// Removed for good (tag `kodak-dc-support-before-removal` keeps the
    /// code); everything user-facing iterates `shipping` still, kept as the
    /// one gate for any future non-shipping profile.
    static let shipping: [CameraProfile] = [.quickTake100, .quickTake150, .quickTake200]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickTake100: return "QuickTake 100"
        case .quickTake150: return "QuickTake 150 / 100 Plus"
        case .quickTake200: return "QuickTake 200 / Fuji DS-7"
        }
    }

    /// One-line description shown in the picker help / chooser rows.
    var blurb: String {
        switch self {
        case .quickTake100: return "Apple's 1994 QuickTake (Kodak-built)."
        case .quickTake150: return "Apple's 1995 QuickTake — adds standard/high quality. Auto-distinguished from the QT100 on connect."
        case .quickTake200: return "Apple QuickTake 200 + Fujifilm DS-7/DS-8 + Samsung Kenox SSC-350N — one identical serial protocol."
        }
    }

    /// The model the app adopts when this profile is chosen; the exact sibling
    /// is refined automatically afterward.
    var representativeModel: QuickTakeModel {
        switch self {
        case .quickTake100: return .qt100
        case .quickTake150: return .qt150
        case .quickTake200: return .qt200
        }
    }

    /// Tight brand label for the sidebar header (shorter than `displayName`,
    /// which can overflow the fixed pane).
    var shortName: String {
        switch self {
        case .quickTake100: return "QuickTake 100"
        case .quickTake150: return "QuickTake 150"
        case .quickTake200: return "QuickTake 200"
        }
    }

    /// Name of the custom brand icon image in the asset catalog. When no asset
    /// with this name exists yet, the sidebar header falls back to
    /// `placeholderSymbol`.
    var iconAssetName: String {
        switch self {
        case .quickTake100: return "CameraIcon-QT100"
        case .quickTake150: return "CameraIcon-QT150"
        case .quickTake200: return "CameraIcon-QT200"
        }
    }

    /// SF Symbol placeholder shown until the custom `iconAssetName` art exists,
    /// distinct per profile so each camera reads differently in the meantime.
    var placeholderSymbol: String {
        switch self {
        case .quickTake100: return "camera"
        case .quickTake150: return "camera.fill"
        case .quickTake200: return "camera.aperture"
        }
    }
}

enum QuickTakeExportFormat: String, CaseIterable, Identifiable {
    case tiff
    case png
    case bmp
    case jpeg
    case heic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiff:
            return "TIFF"
        case .png:
            return "PNG"
        case .bmp:
            return "BMP"
        case .jpeg:
            return "JPEG"
        case .heic:
            return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .tiff:
            return "tiff"
        case .png:
            return "png"
        case .bmp:
            return "bmp"
        case .jpeg:
            return "jpeg"
        case .heic:
            return "heic"
        }
    }

    var isLossless: Bool {
        switch self {
        case .tiff, .png, .bmp:
            return true
        case .jpeg, .heic:
            return false
        }
    }

    var uti: UTType {
        switch self {
        case .tiff:
            return .tiff
        case .png:
            return .png
        case .bmp:
            return .bmp
        case .jpeg:
            return .jpeg
        case .heic:
            return .heic
        }
    }
}

final class QTKFormatter {
    static func buildQTKData(model: QuickTakeModel, imageHeader: [UInt8], imageData: [UInt8]) -> Data {
        // QT200 writes standard JPEGs to a SmartMedia card — there is no
        // `.QTK` Bayer container to rebuild, so "Keep Original Files" saves
        // the raw JPEG bytes verbatim rather than running through this builder.
        // Empty Data signals to callers that no QTK was assembled.
        guard model.usesQTKFormat else { return Data() }

        guard imageHeader.count > 24 else {
            return Data()
        }

        var fileHeader = [UInt8](repeating: 0, count: 736)
        fileHeader[0] = 0x71
        fileHeader[1] = 0x6B
        fileHeader[2] = 0x74

        switch model {
        case .qt100:
            fileHeader[3] = 0x6B
            fileHeader[7] = (imageHeader[24] == 16) ? 0x08 : 0x04
        case .qt150:
            fileHeader[3] = 0x6E
            fileHeader[7] = 0x04
        case .qt200, .fujiDS7, .samsungSSC350N:
            // Unreachable: the `usesQTKFormat` guard above filters the
            // whole Fuji family out (it stores JPEG). Compiler
            // exhaustiveness only.
            return Data()
        }

        fileHeader[9] = imageHeader[5]
        fileHeader[10] = imageHeader[6]
        fileHeader[11] = imageHeader[7]
        fileHeader[544] = imageHeader[10]
        fileHeader[545] = imageHeader[11]
        fileHeader[546] = imageHeader[8]
        fileHeader[547] = imageHeader[9]
        fileHeader[13] = imageHeader[19]

        for i in 0..<60 where (4 + i) < imageHeader.count {
            fileHeader[14 + i] = imageHeader[4 + i]
        }

        var finalData = Data(fileHeader)
        finalData.append(contentsOf: imageData)
        return finalData
    }
}
