// Decoder pixel hashes and rendering invariants. The default corpus uses
// repository and synthetic inputs; optional fixtures are supplied via CLI.
// See README.md for fixture options and baseline comparison commands.
import AppKit
import CryptoKit

setbuf(stdout, nil)

// Reject malformed arguments before reading fixtures or creating dump files.
let knownValueFlags: Set<String> = ["--dump", "--fixture", "--fixtures-dir", "--finished", "--finished-dir"]
let knownBoolFlags: Set<String> = ["--strict", "--require-fixtures"]
do {
    var i = 1   // skip argv[0]
    let args = CommandLine.arguments
    while i < args.count {
        let token = args[i]
        if knownBoolFlags.contains(token) {
            i += 1
        } else if knownValueFlags.contains(token) {
            // A following token that is itself a flag (`--fixture --strict`)
            // is a missing value too, not `--strict` accepted as a path.
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                FileHandle.standardError.write("error: \(token) requires a value\n".data(using: .utf8)!)
                exit(2)
            }
            i += 2
        } else {
            FileHandle.standardError.write("error: unrecognized argument '\(token)'\n".data(using: .utf8)!)
            exit(2)
        }
    }
}

// Invariant failures determine the exit status; baseline comparison is separate.
var hadFailure = false

func hashImage(_ image: NSImage?) -> String {
    guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data as Data? else { return "NIL-IMAGE" }
    var hasher = SHA256()
    hasher.update(data: data)
    // Include geometry so a wrong-size-but-same-prefix bug can't hide.
    hasher.update(data: Data("\(cg.width)x\(cg.height)x\(cg.bitsPerPixel)".utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
}

// Deterministic LCG so synthetic fuzz files are identical on every run.
func lcgBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var s = seed
    return (0..<count).map { _ in
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: s >> 33)
    }
}

func syntheticQTK(qt100: Bool, width: Int, height: Int, offset738: Bool, seed: UInt64) -> Data {
    var b = [UInt8](repeating: 0, count: offset738 ? 738 : 736)
    let magic = qt100 ? "qktk" : "qktn"
    for (i, ch) in magic.utf8.enumerated() { b[i] = ch }
    b[544] = UInt8(height >> 8); b[545] = UInt8(height & 0xFF)
    b[546] = UInt8(width >> 8);  b[547] = UInt8(width & 0xFF)
    let check = offset738 ? 30 : 0            // 30 -> dataOffset 738 branch
    b[552] = UInt8(check >> 8); b[553] = UInt8(check & 0xFF)
    b += lcgBytes(120_000, seed: seed)
    return Data(b)
}

// Header-boundary regression: malformed drops must fail before any field
// access. This deliberately includes every length that used to index past EOF.
for magic in ["qktk", "qktn"] {
    for length in [0, 4, 547, 548, 549, 550, 551, 552, 553, 735, 736] {
        var bytes = Data(repeating: 0, count: length)
        if length >= 4 { bytes.replaceSubrange(0..<4, with: magic.utf8) }
        precondition(QTKDecoder().decode(data: bytes) == nil,
                     "Truncated \(magic) file accepted at length \(length)")
    }
    for length in [737, 738] {
        var bytes = Data(repeating: 0, count: length)
        bytes.replaceSubrange(0..<4, with: magic.utf8)
        bytes[553] = 30
        precondition(QTKDecoder().decode(data: bytes) == nil,
                     "Offset-738 file without payload accepted")
    }
}
precondition(QTKDecoder().decode(data: Data(repeating: 0, count: 800)) == nil,
             "Unrecognised file signature accepted")
print("PASS: 27 malformed QTK header/signature checks")

// Both predictor families must reject a payload that ends before the image.
for qt100 in [false, true] {
    let truncated = syntheticQTK(qt100: qt100, width: 640, height: 480, offset738: false, seed: 0xDEAD_BEEF)
        .prefix(736 + 500)
    precondition(QTKDecoder().decode(data: Data(truncated)) == nil,
                 "Truncated payload accepted for qt100=\(qt100)")
}
print("PASS: 2 payload-truncation checks")

for (width, height) in [(1, 1), (2, 2), (3, 3), (6, 4), (7, 5), (639, 479), (641, 481)] {
    let malformed = syntheticQTK(qt100: false, width: width, height: height, offset738: false, seed: 0xDEAD_BEEF)
    precondition(QTKDecoder().decode(data: malformed) == nil,
                 "Partial RADC stripe accepted: \(width)x\(height)")
}
print("PASS: 7 malformed RADC geometry checks")

// An eight-bit Huffman lookup may legally finish with a shorter code at EOF.
do {
    let shortCodes = [UInt16](repeating: 0x0107, count: 256)
    var reader = BitReader(data: Data([0x01]), offset: 0)
    precondition(reader.getBits(7) == 0)
    precondition(reader.getBitHuff(nbits: 8, huff: shortCodes) == 7)
    precondition(!reader.isExhausted)
    precondition(reader.getBitHuff(nbits: 8, huff: shortCodes) == 0 && reader.isExhausted)
    precondition(reader.getBits(1) == 0 && reader.isExhausted)
    var incomplete = BitReader(data: Data([0]), offset: 0)
    _ = incomplete.getBits(7)
    precondition(incomplete.getBitHuff(nbits: 8, huff: [UInt16](repeating: 0x0207, count: 256)) == 0)
    precondition(incomplete.isExhausted)
}

// Reconstructed archive headers carry two copies of the payload length.
// Missing dimensions retain the legacy rendering only for a complete payload.
for qt100 in [false, true] {
    var archive = syntheticQTK(qt100: qt100, width: 640, height: 480, offset738: false, seed: 0xDEAD_BEEF)
    let length = archive.count - 736
    for start in [9, 15] {
        archive[start] = UInt8((length >> 16) & 255)
        archive[start + 1] = UInt8((length >> 8) & 255)
        archive[start + 2] = UInt8(length & 255)
    }
    precondition(QTKDecoder().decode(data: archive) != nil)
    for missing in [1, length / 10, length / 2, length * 9 / 10] {
        precondition(QTKDecoder().decode(data: Data(archive.dropLast(missing))) == nil)
    }
    if !qt100 {
        archive.replaceSubrange(544..<548, with: [0, 0, 0, 0])
        precondition(QTKDecoder().decode(data: archive) != nil)
        precondition(QTKDecoder().decode(data: Data(archive.dropLast())) == nil)
    }
}
print("PASS: Huffman EOF and archive-length integrity checks")

let decoder = QTKDecoder()
var clock = ContinuousClock()

// Optional raw-pixel output for measuring intentional rendering changes.
let dumpDir: String? = {
    guard let i = CommandLine.arguments.firstIndex(of: "--dump"),
          i + 1 < CommandLine.arguments.count else { return nil }
    let d = CommandLine.arguments[i + 1]
    try? FileManager.default.createDirectory(atPath: d,
                                             withIntermediateDirectories: true)
    return d
}()

func dump(_ label: String, _ combo: String, _ img: NSImage?) {
    guard let dir = dumpDir, let img,
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data as Data? else { return }
    let safe = label.replacingOccurrences(of: "/", with: "_")
    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(safe)__\(combo).raw"))
}

// All FOUR combinations, not three. Look (vintage/enhanced) and output
// range (SDR/HDR) are independent axes; the old three-row layout had no
// way to say "enhanced, in HDR" and so could not notice when that stopped
// working.
func run(_ label: String, _ data: Data) {
    if data.count > 736 {
        let length = Int(data[9]) << 16 | Int(data[10]) << 8 | Int(data[11])
        let repeated = Int(data[15]) << 16 | Int(data[16]) << 8 | Int(data[17])
        if length > 0, length == repeated, length == data.count - 736,
           data[552] == 0, data[553] != 30 {
            for missing in [1, max(1, length / 10), max(1, length / 2)] {
                precondition(decoder.decode(data: Data(data.dropLast(missing))) == nil,
                             "Shortened archive accepted: \(label), missing \(missing) bytes")
            }
        }
    }
    let combos: [(String, Bool, Bool)] = [
        ("vintage-sdr",  false, false),
        ("enhanced-sdr", true,  false),
        ("vintage-hdr",  false, true),
        ("enhanced-hdr", true,  true),
    ]
    var hash: [String: String] = [:]
    for (name, enhanced, hdr) in combos {
        let t0 = clock.now
        let img = decoder.decode(data: data, enhanced: enhanced,
                                 hdrEnabled: hdr, hdrHeadroom: 1.5)
        let ms = Double((clock.now - t0).components.attoseconds) / 1e15
        let h = hashImage(img)
        if h == "NIL-IMAGE" {
            // A resolved, well-formed fixture decoded to nothing. That's
            // a real regression, not a missing-input story — always fatal.
            hadFailure = true
        }
        hash[name] = h
        dump(label, name, img)
        print("\(label)|\(name)|\(h)|\(String(format: "%.0f", ms))ms")
    }

    // Composition invariants. A hash COLLISION here means one axis is
    // being ignored — which is the failure mode that shipped: HDR
    // returned early and silently discarded Enhanced, and Enhanced-off
    // silently disabled HDR entirely.
    func check(_ what: String, _ a: String, _ b: String) {
        let collided = hash[a] == hash[b]
        if collided { hadFailure = true }
        print("\(label)|CHECK \(what)|\(collided ? "FAIL-identical" : "ok")|-")
    }
    check("enhanced changes HDR", "vintage-hdr",  "enhanced-hdr")
    check("HDR changes enhanced", "enhanced-sdr", "enhanced-hdr")
    check("HDR changes vintage",  "vintage-sdr",  "vintage-hdr")
}

// MARK: - Optional fixture arguments
let cliArgs = CommandLine.arguments

func repeatedValues(for flag: String) -> [String] {
    var values: [String] = []
    var idx = 0
    while idx < cliArgs.count {
        if cliArgs[idx] == flag, idx + 1 < cliArgs.count {
            values.append(cliArgs[idx + 1])
            idx += 2
        } else {
            idx += 1
        }
    }
    return values
}

let strict = cliArgs.contains("--strict") || cliArgs.contains("--require-fixtures")
let explicitFixtures = repeatedValues(for: "--fixture")
let fixtureDirs = repeatedValues(for: "--fixtures-dir")
let explicitFinished = repeatedValues(for: "--finished")
let finishedDirs = repeatedValues(for: "--finished-dir")

func existingPath(_ raw: String) -> String? {
    let expanded = (raw as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
}

// Every filename directly inside `dir` whose extension (case-insensitively)
// is in `extensions`. Returns nil if `dir` itself doesn't exist, so callers
// can tell "empty directory" apart from "no such directory".
func filesInDir(_ dir: String, extensions: Set<String>) -> [String]? {
    let expanded = (dir as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
          isDir.boolValue else { return nil }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []
    return entries
        .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        .sorted()
        .map { expanded + "/" + $0 }
}

// Optional absence is reported explicitly; strict runs require every fixture.
func reportUnresolved(_ label: String, _ path: String, kind: String) {
    if strict {
        hadFailure = true
        print("\(label)|MISSING|\(kind) fixture requested but not found: \(path)")
    } else {
        print("\(label)|SKIPPED|optional \(kind) fixture not supplied or not found: \(path)")
    }
}

// An unreadable or corrupt supplied file always fails, including portable runs.
func reportBroken(_ label: String, _ path: String, kind: String, reason: String) {
    hadFailure = true
    print("\(label)|BROKEN|\(kind) fixture found but \(reason): \(path)")
}

// Native headers have no trusted SwiftTake length field: validate actual code bits.
func checkPayloadTruncationFails(_ label: String, _ data: Data) {
    let checkVal = Int(data[552]) << 8 | Int(data[553])
    let dataOffset = checkVal == 30 ? 738 : 736
    guard data.count > dataOffset else { return }
    let payloadLen = data.count - dataOffset
    for frac in [0.9, 0.5, 0.1] {
        let end = dataOffset + Int(Double(payloadLen) * frac)
        precondition(QTKDecoder().decode(data: data.subdata(in: 0..<end)) == nil,
                     "\(label): payload truncated to \(Int(frac * 100))% accepted")
    }
    print("PASS: \(label) payload-truncation checks (90/50/10%)")
}

// MARK: - Portable default corpus (checked into the repo)

// The repository sample is required. An explicit override must resolve;
// otherwise accept the documented repository-root or harness-directory cwd.
if let override = ProcessInfo.processInfo.environment["SWIFTTAKE_IMAGE03_PATH"] {
    if let path = existingPath(override), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        run("IMAGE03.QTK", data)
        checkPayloadTruncationFails("IMAGE03.QTK", data)
    } else {
        hadFailure = true
        print("IMAGE03.QTK|MISSING|SWIFTTAKE_IMAGE03_PATH is set but not found or unreadable: \(override)")
    }
} else {
    let relativeCandidates = ["../../IMAGE03.QTK", "IMAGE03.QTK"]   // Tools/DecoderHarness, repo root
    if let image03 = relativeCandidates.lazy.compactMap(existingPath).first,
       let data = try? Data(contentsOf: URL(fileURLWithPath: image03)) {
        run("IMAGE03.QTK", data)
        checkPayloadTruncationFails("IMAGE03.QTK", data)
    } else {
        hadFailure = true
        print("IMAGE03.QTK|MISSING|required portable fixture not found (tried: \(relativeCandidates.joined(separator: ", ")))")
    }
}

// MARK: - Optional hardware-captured QTK fixtures (CLI-supplied only)

// Baseline identities, independent of where the files are stored.
let expectedQTKFixtureNames = ["mars.qtk", "neptune.qtk", "venus.qtk"]

var qtkCandidatePaths = explicitFixtures
for dir in fixtureDirs {
    if let found = filesInDir(dir, extensions: ["qtk"]), !found.isEmpty {
        qtkCandidatePaths += found
    } else {
        reportUnresolved((dir as NSString).lastPathComponent, dir, kind: "fixtures-dir")
    }
}

for expectedName in expectedQTKFixtureNames {
    if let idx = qtkCandidatePaths.firstIndex(where: { ($0 as NSString).lastPathComponent == expectedName }) {
        let path = (qtkCandidatePaths.remove(at: idx) as NSString).expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            run(expectedName, data)
        } else if FileManager.default.fileExists(atPath: path) {
            reportBroken(expectedName, path, kind: "QTK", reason: "could not be read")
        } else {
            reportUnresolved(expectedName, path, kind: "QTK")
        }
    } else {
        reportUnresolved(expectedName, "not supplied (use --fixture <path> or --fixtures-dir <dir>)", kind: "QTK")
    }
}
for rawPath in qtkCandidatePaths {
    let path = (rawPath as NSString).expandingTildeInPath
    let label = (path as NSString).lastPathComponent
    guard FileManager.default.fileExists(atPath: path) else {
        reportUnresolved(label, path, kind: "QTK")
        continue
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        reportBroken(label, path, kind: "QTK", reason: "could not be read")
        continue
    }
    run(label, data)
}
// Synthetic coverage for both predictor families, HQ/SQ and offset-738 headers.
for (qt100, tag) in [(true, "qt100"), (false, "qt150")] {
    run("fuzz-\(tag)-hq-a",  syntheticQTK(qt100: qt100, width: 640, height: 480, offset738: false, seed: 0xDEAD_BEEF))
    run("fuzz-\(tag)-hq-b",  syntheticQTK(qt100: qt100, width: 640, height: 480, offset738: false, seed: 0x1234_5678))
    run("fuzz-\(tag)-sq",    syntheticQTK(qt100: qt100, width: 320, height: 240, offset738: false, seed: 0xCAFE_F00D))
    run("fuzz-\(tag)-o738",  syntheticQTK(qt100: qt100, width: 640, height: 480, offset738: true,  seed: 0x0F0F_5A5A))
}

// MARK: - Finished-image Look (QT200 / Fuji family)
//
// These cameras hand over completed JPEGs, so there is no Bayer decode —
// but the Look still applies, via the shared enhancement and an sRGB curve.
// Covered here for the same reason the QTK combos are: the failure mode is
// a combination silently collapsing into another, and a hash collision is
// the only thing that catches it.
// Real QuickTake 200 content. The Kodak DC frames that stood in here
// first were badly unrepresentative: they put 0.000-0.080% of samples
// above white, where a genuine sunlit QT200 frame puts 8.985%. Conclusions
// drawn from the stand-ins were wrong by two orders of magnitude.
// Three real QT200 frames spanning the set's tonal range — darkest,
// middle, brightest — rather than one. The first single sample was a
// bright one, and tuning against it alone produced a recipe the other 27
// disagreed with.
// Historical finished-image fixtures are supplied through CLI paths.
let expectedFinishedFixtureNames = [
    "QuickTake200_19960509_141432.tiff",
    "QuickTake200_19960509_151444.tiff",
    "QuickTake200_19960509_152224.tiff",
]

var finishedCandidatePaths = explicitFinished
for dir in finishedDirs {
    if let found = filesInDir(dir, extensions: ["tiff", "tif", "jpg", "jpeg", "png"]), !found.isEmpty {
        finishedCandidatePaths += found
    } else {
        reportUnresolved((dir as NSString).lastPathComponent, dir, kind: "finished-dir")
    }
}

var finishedPaths: [String] = []
for expectedName in expectedFinishedFixtureNames {
    if let idx = finishedCandidatePaths.firstIndex(where: { ($0 as NSString).lastPathComponent == expectedName }) {
        finishedPaths.append(finishedCandidatePaths.remove(at: idx))
    } else {
        reportUnresolved(expectedName, "not supplied (use --finished <path> or --finished-dir <dir>)", kind: "finished-image")
    }
}
finishedPaths += finishedCandidatePaths

for rawPath in finishedPaths {
    let path = (rawPath as NSString).expandingTildeInPath
    let name = (path as NSString).lastPathComponent
    guard FileManager.default.fileExists(atPath: path) else {
        reportUnresolved(name, path, kind: "finished-image")
        continue
    }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        reportBroken(name, path, kind: "finished-image", reason: "could not be decoded")
        continue
    }
    var h: [String: String] = [:]
    for (label, enh, hdr) in [("vintage", false, false),
                              ("enhanced", true, false),
                              ("enhanced-hdr", true, true)] {
        let t0 = clock.now
        let img = FinishedImageLook.render(cg, enhanced: enh, hdr: hdr, headroom: 1.5)
        let ms = Double((clock.now - t0).components.attoseconds) / 1e15
        let hh = hashImage(img)
        if hh == "NIL-IMAGE" { hadFailure = true }
        h[label] = hh
        print("\(name)|finished-\(label)|\(hh)|\(String(format: "%.0f", ms))ms")
    }
    func chk(_ what: String, _ a: String, _ b: String) {
        let collided = h[a] == h[b]
        if collided { hadFailure = true }
        print("\(name)|CHECK \(what)|\(collided ? "FAIL-identical" : "ok")|-")
    }
    chk("enhanced changes finished", "vintage",  "enhanced")
    chk("HDR changes finished",      "enhanced", "enhanced-hdr")
}

// MARK: - Exit status
if hadFailure {
    print("FAIL: inspect the missing/broken input or rendering errors above.")
    exit(1)
}
print("PASS: harness completed with no invariant failures.")
