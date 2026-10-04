//
//  QTVRFormat.swift
//  SwiftTake
//
//  Reader for QuickTime VR 1.0 movies — the format the 1995 QTVR
//  Authoring Tools wrote and the format this app's QTVR export must
//  reproduce. Two container layouts exist in the wild:
//
//    • Flattened (shipping form): one data-fork file, `moov` atom
//      alongside `mdat`. All the 7/95 CD panoramas are this shape.
//    • Unflattened (authoring form): the `moov` lives in a resource
//      fork; the data fork is raw media that the moov's chunk offsets
//      index directly. The CD's Company Store objects are this shape.
//
//  The parser therefore takes the atom source (`moovData`) and the
//  media file (`mediaData`) separately; for flattened files pass the
//  same bytes for both.
//
//  Layout facts below are verified three ways — Apple TN1035/TN1036,
//  the shipped QTVRObjectAuthoring.h sample code, and byte-level parses
//  of the July 1995 QTVR CD — and the file wins wherever the documents
//  disagree:
//    • Object NAVG stores endVPan BEFORE startVPan (TN1036's prose has
//      them swapped; the header and real files agree on end-first).
//    • Panorama tiles need not be height-divisible by 4 (Apple's own
//      768×125 tiles violate the Inside-QTVR rule).
//    • The PanoramaDescription bytes at offset 8..15 are the standard
//      sample-description reserved[6]+dataRefIndex, not two longs of
//      reserved as TN1035 draws them.
//
//  All integers are big-endian; angles are Fixed 16.16.
//

import Foundation

// MARK: - Errors

enum QTVRParseError: Error, CustomStringConvertible {
    case truncated(String)
    case missing(String)
    case malformed(String)

    var description: String {
        switch self {
        case .truncated(let what): return "truncated \(what)"
        case .missing(let what):   return "missing \(what)"
        case .malformed(let what): return "malformed \(what)"
        }
    }
}

// MARK: - Big-endian cursor

/// Bounds-checked big-endian reader. Every multi-byte read throws on
/// overrun rather than trapping — these files come from 30-year-old
/// archives and drag-and-drop, so corruption is an input, not a bug.
struct QTVRReader {
    let data: Data
    var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int, of what: String) throws -> Data {
        guard count >= 0, remaining >= count else { throw QTVRParseError.truncated(what) }
        defer { offset += count }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + count)
    }

    mutating func u8(_ what: String) throws -> UInt8 {
        try bytes(1, of: what)[0]
    }

    mutating func u16(_ what: String) throws -> UInt16 {
        let b = try bytes(2, of: what)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u32(_ what: String) throws -> UInt32 {
        let b = try bytes(4, of: what)
        return UInt32(b[b.startIndex]) << 24 | UInt32(b[b.startIndex + 1]) << 16
             | UInt32(b[b.startIndex + 2]) << 8 | UInt32(b[b.startIndex + 3])
    }

    mutating func s16(_ what: String) throws -> Int16 { Int16(bitPattern: try u16(what)) }
    mutating func s32(_ what: String) throws -> Int32 { Int32(bitPattern: try u32(what)) }

    /// Fixed 16.16 → Double.
    mutating func fixed(_ what: String) throws -> Double {
        Double(try s32(what)) / 65536.0
    }

    mutating func fourCC(_ what: String) throws -> String {
        let b = try bytes(4, of: what)
        return String(bytes: b, encoding: .macOSRoman) ?? "????"
    }

    mutating func skip(_ count: Int, of what: String) throws {
        _ = try bytes(count, of: what)
    }
}

// MARK: - Atom walking

/// One classic atom: 32-bit size (including the 8-byte header) + type.
/// QTVR-era files predate 64-bit sizes; size==0 means "to end of
/// enclosing scope" and only ever appears at top level.
struct QTVRAtom {
    let type: String
    let payloadRange: Range<Int>   // offsets into the source data, header excluded

    static func walk(_ data: Data, in range: Range<Int>) -> [QTVRAtom] {
        var atoms: [QTVRAtom] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var r = QTVRReader(data, at: offset)
            guard let rawSize = try? r.u32("atom size"),
                  let type = try? r.fourCC("atom type") else { break }
            let size = rawSize == 0 ? range.upperBound - offset : Int(rawSize)
            guard size >= 8, offset + size <= range.upperBound else { break }
            atoms.append(QTVRAtom(type: type, payloadRange: offset + 8 ..< offset + size))
            offset += size
        }
        return atoms
    }

    static func first(_ type: String, in atoms: [QTVRAtom]) -> QTVRAtom? {
        atoms.first { $0.type == type }
    }
}

// MARK: - Parsed structures

/// TN1035 PanoramaDescription — the 'pano' sample description on the
/// panorama ('STpn') track. 152 bytes in every file on the 7/95 CD.
struct QTVRPanoramaDescription {
    var sceneTrackID: UInt32
    var loResSceneTrackID: UInt32
    var hotSpotTrackID: UInt32
    var hPanStart: Double
    var hPanEnd: Double
    var vPanTop: Double
    var vPanBottom: Double
    var minimumZoom: Double
    var maximumZoom: Double
    var sceneSizeX: UInt32          // width of the ROTATED image (pano height)
    var sceneSizeY: UInt32          // height of the ROTATED image (pano circumference)
    var numFrames: UInt32
    var sceneNumFramesX: UInt16
    var sceneNumFramesY: UInt16
    var sceneColorDepth: UInt16
    var hotSpotSizeX: UInt32
    var hotSpotSizeY: UInt32
    var hotSpotNumFramesX: UInt16
    var hotSpotNumFramesY: UInt16
    var hotSpotColorDepth: UInt16

    static func parse(_ data: Data, in range: Range<Int>) throws -> QTVRPanoramaDescription {
        var r = QTVRReader(data, at: range.lowerBound)
        // Standard sample-description preamble: size, format, then 6
        // reserved bytes + 2-byte data reference index.
        let size = try r.u32("pano desc size")
        guard range.lowerBound + Int(size) <= range.upperBound else {
            throw QTVRParseError.truncated("pano desc body")
        }
        let format = try r.fourCC("pano desc format")
        guard format == "pano" else { throw QTVRParseError.malformed("pano desc format \(format)") }
        try r.skip(6, of: "pano desc reserved")
        _ = try r.u16("pano desc dref index")
        _ = try r.u16("majorVersion")
        _ = try r.u16("minorVersion")
        let sceneTrackID = try r.u32("sceneTrackID")
        let loResTrackID = try r.u32("loResSceneTrackID")
        try r.skip(24, of: "reserved3")
        let hotSpotTrackID = try r.u32("hotSpotTrackID")
        try r.skip(36, of: "reserved4")
        let hPanStart = try r.fixed("hPanStart")
        let hPanEnd = try r.fixed("hPanEnd")
        let vPanTop = try r.fixed("vPanTop")
        let vPanBottom = try r.fixed("vPanBottom")
        let minZoom = try r.fixed("minimumZoom")
        let maxZoom = try r.fixed("maximumZoom")
        let sceneSizeX = try r.u32("sceneSizeX")
        let sceneSizeY = try r.u32("sceneSizeY")
        let numFrames = try r.u32("numFrames")
        _ = try r.u16("reserved5")
        let framesX = try r.u16("sceneNumFramesX")
        let framesY = try r.u16("sceneNumFramesY")
        let depth = try r.u16("sceneColorDepth")
        let hsSizeX = try r.u32("hotSpotSizeX")
        let hsSizeY = try r.u32("hotSpotSizeY")
        _ = try r.u16("reserved6")
        let hsFramesX = try r.u16("hotSpotNumFramesX")
        let hsFramesY = try r.u16("hotSpotNumFramesY")
        let hsDepth = try r.u16("hotSpotColorDepth")
        return QTVRPanoramaDescription(
            sceneTrackID: sceneTrackID, loResSceneTrackID: loResTrackID,
            hotSpotTrackID: hotSpotTrackID,
            hPanStart: hPanStart, hPanEnd: hPanEnd,
            vPanTop: vPanTop, vPanBottom: vPanBottom,
            minimumZoom: minZoom, maximumZoom: maxZoom,
            sceneSizeX: sceneSizeX, sceneSizeY: sceneSizeY,
            numFrames: numFrames,
            sceneNumFramesX: framesX, sceneNumFramesY: framesY,
            sceneColorDepth: depth,
            hotSpotSizeX: hsSizeX, hotSpotSizeY: hsSizeY,
            hotSpotNumFramesX: hsFramesX, hotSpotNumFramesY: hsFramesY,
            hotSpotColorDepth: hsDepth)
    }
}

/// TN1035 'pHdr' — the per-node header inside a panorama track sample.
/// The sample uses old-style size+type atoms, not QT atom containers.
struct QTVRPanoramaHeader {
    var nodeID: UInt32
    var defHPan: Double
    var defVPan: Double
    var defZoom: Double
    var minHPan: Double
    var minVPan: Double
    var minZoom: Double
    var maxHPan: Double
    var maxVPan: Double
    var maxZoom: Double
    var nameStrOffset: Int32
    var commentStrOffset: Int32

    static func parse(_ data: Data, in range: Range<Int>) throws -> QTVRPanoramaHeader {
        var r = QTVRReader(data, at: range.lowerBound)
        let nodeID = try r.u32("pHdr nodeID")
        let defHPan = try r.fixed("defHPan")
        let defVPan = try r.fixed("defVPan")
        let defZoom = try r.fixed("defZoom")
        let minHPan = try r.fixed("minHPan")
        let minVPan = try r.fixed("minVPan")
        let minZoom = try r.fixed("minZoom")
        let maxHPan = try r.fixed("maxHPan")
        let maxVPan = try r.fixed("maxVPan")
        let maxZoom = try r.fixed("maxZoom")
        try r.skip(8, of: "pHdr reserved")
        let nameOff = try r.s32("nameStrOffset")
        let commentOff = try r.s32("commentStrOffset")
        return QTVRPanoramaHeader(
            nodeID: nodeID,
            defHPan: defHPan, defVPan: defVPan, defZoom: defZoom,
            minHPan: minHPan, minVPan: minVPan, minZoom: minZoom,
            maxHPan: maxHPan, maxVPan: maxVPan, maxZoom: maxZoom,
            nameStrOffset: nameOff, commentStrOffset: commentOff)
    }
}

/// The 48-byte object-movie parameter record stored as movie user data
/// 'NAVG'. Field order per the shipped QTVRObjectAuthoring.h — endVPan
/// precedes startVPan in the bytes.
struct QTVRObjectInfo {
    var versionNumber: Int16
    var numberOfColumns: Int16
    var numberOfRows: Int16
    var loopSize: Int16
    var frameDuration: Int16
    var movieType: Int16            // 1 standard, 2 old scene, 3 object-in-scene
    var loopTicks: Int16
    var fieldOfView: Double
    var startHPan: Double
    var endHPan: Double
    var endVPan: Double
    var startVPan: Double
    var initialHPan: Double
    var initialVPan: Double

    static func parse(_ data: Data, in range: Range<Int>) throws -> QTVRObjectInfo {
        guard range.count >= 48 else { throw QTVRParseError.truncated("NAVG record") }
        var r = QTVRReader(data, at: range.lowerBound)
        let version = try r.s16("NAVG version")
        let cols = try r.s16("numberOfColumns")
        let rows = try r.s16("numberOfRows")
        _ = try r.s16("reserved1")
        let loopSize = try r.s16("loopSize")
        let frameDuration = try r.s16("frameDuration")
        let movieType = try r.s16("movieType")
        let loopTicks = try r.s16("loopTicks")
        let fov = try r.fixed("fieldOfView")
        let startH = try r.fixed("startHPan")
        let endH = try r.fixed("endHPan")
        let endV = try r.fixed("endVPan")
        let startV = try r.fixed("startVPan")
        let initH = try r.fixed("initialHPan")
        let initV = try r.fixed("initialVPan")
        return QTVRObjectInfo(
            versionNumber: version, numberOfColumns: cols, numberOfRows: rows,
            loopSize: loopSize, frameDuration: frameDuration,
            movieType: movieType, loopTicks: loopTicks,
            fieldOfView: fov, startHPan: startH, endHPan: endH,
            endVPan: endV, startVPan: startV,
            initialHPan: initH, initialVPan: initV)
    }
}

/// Per-track digest — enough to check the QTVR track contract (which
/// track is enabled, which codec carries the tiles, how many samples).
struct QTVRTrackInfo {
    var trackID: UInt32
    var isEnabled: Bool
    var mediaTimeScale: UInt32
    var mediaDuration: UInt32
    var sampleFormat: String        // stsd entry format ('cvid', 'pano', 'jpeg', …)
    var sampleDescriptionSize: UInt32
    var sampleCount: Int
    var width: UInt16               // video descriptions only; 0 otherwise
    var height: UInt16
    var windowWidth: Double         // tkhd track width/height (Fixed 16.16):
    var windowHeight: Double        // the player window size, every track
    var panoramaDescription: QTVRPanoramaDescription?
    var chunkOffsets: [UInt32]
    var sampleSizes: [UInt32]
}

// MARK: - The file

/// A parsed QTVR 1.0 movie (or a plain linear movie, which object
/// movies structurally are until the NAVG user data reinterprets them).
struct QTVRFile {
    enum Kind: String {
        case panoramaV1 = "pano-v1"     // ctyp 'STpn' + a 'pano' description
        case objectV1 = "object-v1"     // ctyp 'stna' + NAVG user data
        case linear = "linear"          // neither — ordinary QuickTime movie
    }

    var kind: Kind
    var controllerType: String?         // movie udta 'ctyp' payload
    var movieTimeScale: UInt32
    var movieDuration: UInt32
    var tracks: [QTVRTrackInfo]
    var objectInfo: QTVRObjectInfo?
    var panoramaHeader: QTVRPanoramaHeader?
    var panoramaSampleAtoms: [String: Int] = [:]   // type → payload size, for pHot/pLnk/strT presence

    var panoramaDescription: QTVRPanoramaDescription? {
        tracks.compactMap(\.panoramaDescription).first
    }

    /// Flattened single-fork file: atoms and media share the bytes.
    static func parse(fileData: Data) throws -> QTVRFile {
        try parse(moovData: fileData, mediaData: fileData)
    }

    /// `moovData` holds the `moov` atom (a whole file, or a bare moov
    /// resource from an unflattened movie's resource fork). Chunk
    /// offsets always index `mediaData`.
    static func parse(moovData: Data, mediaData: Data) throws -> QTVRFile {
        let top = QTVRAtom.walk(moovData, in: 0 ..< moovData.count)
        guard let moov = QTVRAtom.first("moov", in: top) else {
            throw QTVRParseError.missing("moov atom")
        }
        let moovKids = QTVRAtom.walk(moovData, in: moov.payloadRange)

        var timeScale: UInt32 = 0
        var duration: UInt32 = 0
        if let mvhd = QTVRAtom.first("mvhd", in: moovKids) {
            var r = QTVRReader(moovData, at: mvhd.payloadRange.lowerBound)
            try r.skip(12, of: "mvhd head")   // version/flags, ctime, mtime
            timeScale = try r.u32("mvhd timescale")
            duration = try r.u32("mvhd duration")
        }

        var controllerType: String?
        var objectInfo: QTVRObjectInfo?
        if let udta = QTVRAtom.first("udta", in: moovKids) {
            for child in QTVRAtom.walk(moovData, in: udta.payloadRange) {
                switch child.type {
                case "ctyp":
                    var r = QTVRReader(moovData, at: child.payloadRange.lowerBound)
                    controllerType = try? r.fourCC("ctyp payload")
                case "NAVG":
                    objectInfo = try QTVRObjectInfo.parse(moovData, in: child.payloadRange)
                default:
                    break
                }
            }
        }

        var tracks: [QTVRTrackInfo] = []
        for trak in moovKids where trak.type == "trak" {
            if let info = try Self.parseTrack(moovData, trak) {
                tracks.append(info)
            }
        }

        var kind: Kind = .linear
        if controllerType == "STpn", tracks.contains(where: { $0.panoramaDescription != nil }) {
            kind = .panoramaV1
        } else if objectInfo != nil {
            // Real files say 'stna'; accept any ctyp when NAVG is present
            // (the record, not the controller hint, is what defines an
            // object movie).
            kind = .objectV1
        }

        var file = QTVRFile(kind: kind, controllerType: controllerType,
                            movieTimeScale: timeScale, movieDuration: duration,
                            tracks: tracks, objectInfo: objectInfo,
                            panoramaHeader: nil)

        // The panorama track's single media sample holds the node
        // atoms (pHdr + optional strT/pHot/pLnk/pNav).
        if kind == .panoramaV1,
           let panoTrack = tracks.first(where: { $0.panoramaDescription != nil }),
           let offset = panoTrack.chunkOffsets.first,
           let size = panoTrack.sampleSizes.first,
           Int(offset) + Int(size) <= mediaData.count {
            let sample = 0 ..< Int(size)
            let sampleData = mediaData.subdata(in: mediaData.startIndex + Int(offset)
                                                  ..< mediaData.startIndex + Int(offset) + Int(size))
            for atom in QTVRAtom.walk(sampleData, in: sample) {
                file.panoramaSampleAtoms[atom.type] = atom.payloadRange.count
                if atom.type == "pHdr" {
                    file.panoramaHeader = try QTVRPanoramaHeader.parse(sampleData, in: atom.payloadRange)
                }
            }
        }
        return file
    }

    private static func parseTrack(_ data: Data, _ trak: QTVRAtom) throws -> QTVRTrackInfo? {
        let kids = QTVRAtom.walk(data, in: trak.payloadRange)
        guard let tkhd = QTVRAtom.first("tkhd", in: kids),
              let mdia = QTVRAtom.first("mdia", in: kids) else { return nil }

        var r = QTVRReader(data, at: tkhd.payloadRange.lowerBound)
        _ = try r.u8("tkhd version")
        try r.skip(2, of: "tkhd flags hi")
        let flagsLow = try r.u8("tkhd flags")
        try r.skip(8, of: "tkhd times")
        let trackID = try r.u32("tkhd trackID")
        // reserved(4) duration(4) reserved(8) layer/altGroup(4) volume/reserved(4)
        // matrix(36) = 60 bytes, then the Fixed 16.16 track width/height.
        try r.skip(60, of: "tkhd to window size")
        let windowWidth = try r.fixed("tkhd width")
        let windowHeight = try r.fixed("tkhd height")

        let mdiaKids = QTVRAtom.walk(data, in: mdia.payloadRange)
        var mediaScale: UInt32 = 0
        var mediaDuration: UInt32 = 0
        if let mdhd = QTVRAtom.first("mdhd", in: mdiaKids) {
            var m = QTVRReader(data, at: mdhd.payloadRange.lowerBound)
            try m.skip(12, of: "mdhd head")
            mediaScale = try m.u32("mdhd timescale")
            mediaDuration = try m.u32("mdhd duration")
        }

        guard let minf = QTVRAtom.first("minf", in: mdiaKids),
              let stbl = QTVRAtom.first("stbl", in: QTVRAtom.walk(data, in: minf.payloadRange))
        else { return nil }
        let stblKids = QTVRAtom.walk(data, in: stbl.payloadRange)

        var format = "????"
        var descSize: UInt32 = 0
        var width: UInt16 = 0
        var height: UInt16 = 0
        var panoDesc: QTVRPanoramaDescription?
        if let stsd = QTVRAtom.first("stsd", in: stblKids) {
            var s = QTVRReader(data, at: stsd.payloadRange.lowerBound)
            try s.skip(4, of: "stsd head")
            let entryCount = try s.u32("stsd count")
            if entryCount >= 1 {
                let entryStart = s.offset
                descSize = try s.u32("stsd entry size")
                format = try s.fourCC("stsd entry format")
                if format == "pano" {
                    panoDesc = try QTVRPanoramaDescription.parse(
                        data, in: entryStart ..< entryStart + Int(descSize))
                } else if descSize >= 36 {
                    // Video sample description: width/height at +32.
                    var v = QTVRReader(data, at: entryStart + 32)
                    width = try v.u16("video width")
                    height = try v.u16("video height")
                }
            }
        }

        var sampleSizes: [UInt32] = []
        if let stsz = QTVRAtom.first("stsz", in: stblKids) {
            var s = QTVRReader(data, at: stsz.payloadRange.lowerBound)
            try s.skip(4, of: "stsz head")
            let uniform = try s.u32("stsz uniform size")
            let count = try s.u32("stsz count")
            if uniform != 0 {
                // Cap like the stco/non-uniform loops below — `count` is an
                // unchecked 32-bit field from the file.
                sampleSizes = Array(repeating: uniform, count: Int(min(count, 100_000)))
            } else {
                for _ in 0 ..< min(count, 100_000) {
                    sampleSizes.append(try s.u32("stsz entry"))
                }
            }
        }

        var chunkOffsets: [UInt32] = []
        if let stco = QTVRAtom.first("stco", in: stblKids) {
            var s = QTVRReader(data, at: stco.payloadRange.lowerBound)
            try s.skip(4, of: "stco head")
            let count = try s.u32("stco count")
            for _ in 0 ..< min(count, 100_000) {
                chunkOffsets.append(try s.u32("stco entry"))
            }
        }

        return QTVRTrackInfo(
            trackID: trackID, isEnabled: flagsLow & 1 == 1,
            mediaTimeScale: mediaScale, mediaDuration: mediaDuration,
            sampleFormat: format, sampleDescriptionSize: descSize,
            sampleCount: sampleSizes.count,
            width: width, height: height,
            windowWidth: windowWidth, windowHeight: windowHeight,
            panoramaDescription: panoDesc,
            chunkOffsets: chunkOffsets, sampleSizes: sampleSizes)
    }
}
