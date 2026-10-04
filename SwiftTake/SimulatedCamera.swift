// Demo cameras supply bundled finished images at the same transfer seams as
// physical cameras. Imports, colour settings and exports use the normal pipeline.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - The camera

/// The demo camera's state and its photo library.
///
/// A singleton because the manager consults it from deep inside private fetch
/// paths where threading a reference through would mean changing signatures
/// on the most bench-verified code in the app.
@MainActor
final class DemoCamera {
    static let shared = DemoCamera()
    private init() {}

    /// One photo as the camera holds it: exactly the bytes the wire would
    /// carry, plus the camera-side thumbnail block.
    struct Photo {
        /// The wire payload. JPEG for the Fuji/QT200 family; the raw QTK
        /// payload (NOT a wrapped .qtk file) for the Kodak/QT100/150 family.
        let payload: [UInt8]
        /// The camera's own thumbnail block, in that family's format, or nil
        /// to let the gallery fall back to its placeholder.
        let thumbnail: [UInt8]?
        let isHQ: Bool
        /// When the photo was taken, for the info popover's Captured row.
        let captured: Date
        /// The full `.qtk` container, kept only for the Kodak family: its
        /// camera-side thumbnail is a separate 80x60 strip that never travels
        /// inside the file, so it has to be derived from the photo itself.
        var container: [UInt8]? = nil
    }

    private(set) var isConnected = false
    private(set) var photos: [Photo] = []
    private var model: QuickTakeModel = .qt200

    /// Camera-body state the controls change. Held here rather than faked in
    /// the UI so the controls behave like controls — set the flash, and the
    /// sidebar reads it back from "the camera".
    private var flashMode: String = "Auto"
    private var highQuality = true
    private var cameraName = "Demo QuickTake"
    /// Derived Kodak thumbnail strips, so a gallery reload doesn't re-decode.
    private var kodakThumbnails: [UInt8: [UInt8]] = [:]
    /// Slots already handed over once this session.
    ///
    /// The pacing below is theatre — it exists so the progress bar is worth
    /// watching the FIRST time a photo comes across. Charging it again for a
    /// photo the app has already read is just a wait: it is what made a
    /// panorama pay a second and a half a photo to fetch frames it had
    /// already fetched to build the panorama. A real camera would re-send
    /// the bytes; the real cost there is the wire, and the Fuji family
    /// already keeps its own cache for exactly this reason
    /// (`fujiJPEGCache`).
    private var alreadyDelivered: Set<UInt8> = []

    // MARK: Lifecycle

    /// Demo photos are finished JPEGs, including when simulating a QTK body.
    /// Renderers use this flag to avoid treating them as compressed Bayer data.
    private(set) var servesFinishedImages = false

    func connect(as model: QuickTakeModel) {
        self.model = model
        highQuality = true
        photos = DemoPhotoLibrary.photos(for: model)
        servesFinishedImages = true
        kodakThumbnails.removeAll()
        alreadyDelivered.removeAll()
        cameraName = model.profile.shortName + " (Demo)"
        isConnected = true
    }

    func disconnect() {
        isConnected = false
        photos = []
        kodakThumbnails = [:]
        alreadyDelivered = []
    }

    // MARK: The four byte seams

    func metadata() -> CameraMetadata? {
        guard isConnected else { return nil }
        return CameraMetadata(
            // The Fuji family genuinely has no battery opcode, so a demo
            // QT200 must report nil here too — otherwise the sidebar would
            // show a battery row the real camera can never fill.
            batteryLevel: model.protocolFamily == .fuji ? nil : 82,
            picturesTaken: photos.count,
            // Likewise: variable-count JPEGs on a card have no meaningful
            // "frames left".
            picturesRemaining: remainingPhotos,
            flashMode: flashMode,
            cameraName: cameraName,
            quality: highQuality ? "HQ" : "SQ",
            isHighQuality: highQuality)
    }

    /// Kodak cameras have 16 (QT100) or 32 (QT150) storage units.
    /// An HQ image occupies two units; an SQ image occupies one.
    private var remainingPhotos: Int? {
        guard model.protocolFamily != .fuji else { return nil }
        let capacity = model == .qt100 ? 16 : 32
        let used = photos.reduce(0) { $0 + ($1.isHQ ? 2 : 1) }
        return max(0, capacity - used) / (highQuality ? 2 : 1)
    }

    /// When the simulated camera says this photo was taken.
    ///
    /// The real path reads this out of the .qtk header on disk, which demo
    /// mode never writes — so the info popover's Captured row came up empty
    /// on every demo photo. The demo camera has always known the date; it
    /// just had no way to be asked.
    func captureDate(at index: UInt8) -> Date? { photo(at: index)?.captured }

    /// Payload size in bytes, for the info popover's file-size row.
    func payloadSize(at index: UInt8) -> Int? { photo(at: index)?.payload.count }

    /// The 64-byte block the Kodak callers parse, with the payload size at
    /// [5][6][7] big-endian — the same shape `fetchImageHeader` already
    /// synthesises for the Fuji family.
    func imageHeader(at index: UInt8) -> [UInt8]? {
        guard let photo = photo(at: index) else { return nil }
        let size = photo.payload.count
        var header = [UInt8](repeating: 0, count: 64)
        header[5] = UInt8((size >> 16) & 0xFF)
        header[6] = UInt8((size >> 8) & 0xFF)
        header[7] = UInt8(size & 0xFF)
        // Per-photo quality byte, which takePicture() reads to badge a
        // freshly-shot photo before any download: 0x10 HQ, 0x20 SQ.
        header[24] = photo.isHQ ? 0x10 : 0x20
        return header
    }

    /// Paced like a camera-side thumbnail read (~1s each at the negotiated
    /// baud) so the streaming bar and the per-cell fizzle-in are actually
    /// visible rather than completing in one frame.
    func thumbnailBytes(at index: UInt8) async -> [UInt8]? {
        guard let photo = photo(at: index) else { return nil }
        try? await Task.sleep(nanoseconds: 420_000_000)
        if let ready = photo.thumbnail { return ready }
        if let cached = kodakThumbnails[index] { return cached }

        // Kodak: the 80x60 strip is its own camera read and isn't in the
        // .qtk, so decode the photo and build the strip from it. ~45 ms in an
        // optimised build, and this call is already paced like a wire read.
        guard let container = photo.container,
              let image = QTKDecoder().decode(data: Data(container), enhanced: false),
              let block = DemoPhotoLibrary.kodakThumbnailBlock(from: image, model: model)
        else { return nil }
        kodakThumbnails[index] = block
        return block
    }

    /// Hands over the payload in paced steps so the import progress bar moves
    /// the way it does on a real transfer.
    ///
    /// Deliberately faster than the wire (a real 87 KB QT200 photo is ~15s at
    /// 57600). A demo that makes someone wait 15s per photo to see the bar
    /// isn't showing off the app, it's testing their patience — but snapping
    /// to 100% would hide the progress work entirely. This lands between.
    func fullImage(at index: UInt8, progress: ((Double) -> Void)?) async -> [UInt8]? {
        guard let photo = photo(at: index) else { return nil }
        // Paced the first time, instant afterwards — see `alreadyDelivered`.
        // 24 x 62ms = 1.5s a photo. Was 110ms (2.6s), which was tuned for
        // showing off a SINGLE import; a twelve-frame panorama reads every
        // photo first, and at the old pace that was half a minute before the
        // stitch could start. Same step count, so the bar moves just as
        // smoothly.
        if alreadyDelivered.contains(index) {
            progress?(1)
            return photo.payload
        }
        let steps = 24
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 62_000_000)
            progress?(Double(step) / Double(steps))
        }
        alreadyDelivered.insert(index)
        return photo.payload
    }

    // MARK: Camera-body controls

    /// Wire codes, matching what CameraControlView's cycleFlash sends and
    /// what the cameras report back: 0 Auto, 1 Disabled, 2 Forced.
    func setFlash(mode: UInt8) {
        switch mode {
        case 1:  flashMode = "Disabled"
        case 2:  flashMode = "Forced"
        default: flashMode = "Auto"
        }
    }
    func setQuality(high: Bool) { highQuality = high }
    func setName(_ name: String) { cameraName = name }

    /// The shutter: appends a photo from the library, wrapping around so it
    /// never runs dry.
    func takePicture() {
        guard isConnected, remainingPhotos != 0 else { return }
        let source = DemoPhotoLibrary.photos(for: model)
        guard !source.isEmpty else { return }
        var next = source[photos.count % source.count]
        next = Photo(payload: next.payload, thumbnail: next.thumbnail,
                     isHQ: highQuality, captured: Date())
        photos.append(next)
    }

    func eraseAll() { photos.removeAll() }

    // MARK: Routing helper

    /// Picks the demo answer or the live one.
    ///
    /// Exists for the handful of call sites that are an `if let` over an
    /// `await` — rewriting those as an early-return guard would mean
    /// restructuring the surrounding logic in the most bench-verified file in
    /// the app, which is not worth it for a demo. Live behaviour is unchanged:
    /// when demo mode is off this is exactly the original call.
    func orLive<T>(demo: () -> T?, live: () async -> T?) async -> T? {
        isConnected ? demo() : await live()
    }

    /// The camera's internal DSC name — the dedup key and last-resort naming
    /// fallback. Mirrors the QT200's own DSC00001.JPG numbering.
    func photoName(at index: UInt8) -> String? {
        guard photo(at: index) != nil else { return nil }
        return String(format: "DSC%05d.JPG", Int(index) + 1)
    }

    /// The camera-reported byte size, which the gallery turns into the HQ/SQ
    /// badge before any photo is downloaded.
    func photoSize(at index: UInt8) -> Int? {
        photo(at: index)?.payload.count
    }

    /// The full-size colour image the decoder would produce, for the demo
    /// import to drop into the gallery in place of a real export.
    func decodedPreview(at index: UInt8) -> NSImage? {
        guard let photo = photo(at: index) else { return nil }
        if let container = photo.container {
            return QTKDecoder().decode(data: Data(container), enhanced: false)
        }
        return NSImage(data: Data(photo.payload))
    }

    private func photo(at index: UInt8) -> Photo? {
        let i = Int(index)
        guard i >= 0, i < photos.count else { return nil }
        return photos[i]
    }
}

// MARK: - The photo library

/// Curated finished photos for the simulated camera libraries.
/// QT200 contains three consecutive panorama sets; QT100 and QT150 have
/// separate mixed collections. The simulated body does not identify the capture camera.
enum DemoPhotoLibrary {
    /// Packs an image into the camera's 80x60 4-bit grayscale thumbnail
    /// strip — the exact inverse of QuickTakeThumbnailRenderer's QT150
    /// unpacking, including its interleave: per pair of rows, a 60-byte block
    /// carrying (even row even/odd pixels + odd row even pixels), then a
    /// 20-byte block carrying the odd row's odd pixels.
    /// The QT200's `PIC_GET_THUMB` block, built the way the camera builds it.
    ///
    /// This is NOT a downscaled JPEG, which is what the demo used to hand
    /// over. `QuickTake200ThumbnailRenderer` parses the block as an EXIF
    /// APP1 segment and pulls the thumbnail out of IFD1 — a plain JPEG has
    /// no IFD1, so the renderer returned nil and EVERY demo cell fell back
    /// to the grey placeholder. A gallery of empty frames is not a demo.
    ///
    /// Shape is the hardware-confirmed one the renderer documents: 80x60,
    /// uncompressed, photometric 6, YCbCr 4:2:2 at two bytes a pixel —
    /// 9600 bytes of strip, packed Y0 Y1 Cb Cr per pixel pair.
    static func fujiThumbnailBlock(from image: NSImage) -> [UInt8]? {
        let w = 80, h = 60
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = ctx.data
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rgba = pixels.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // No row flip. A CGBitmapContext's coordinate system has its origin
        // bottom-left, but its MEMORY is top-down — row 0 is the top — which
        // is the same order the TIFF strip wants. Flipping here on the
        // strength of the coordinate system turned every thumbnail upside
        // down.
        var strip = [UInt8](); strip.reserveCapacity(w * h * 2)
        for row in 0..<h {
            let y = row
            for pair in 0..<(w / 2) {
                var luma = [Int](), cb = 0, cr = 0
                for k in 0..<2 {
                    let p = (y * w + pair * 2 + k) * 4
                    let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                    luma.append(min(255, max(0, (299 * r + 587 * g + 114 * b) / 1000)))
                    cb += (-169 * r - 331 * g + 500 * b) / 1000
                    cr += (500 * r - 419 * g - 81 * b) / 1000
                }
                // Chroma is shared across the pair, so it is the average of
                // the two — that is what 4:2:2 subsampling means.
                strip.append(UInt8(luma[0]))
                strip.append(UInt8(luma[1]))
                strip.append(UInt8(min(255, max(0, cb / 2 + 128))))
                strip.append(UInt8(min(255, max(0, cr / 2 + 128))))
            }
        }

        // TIFF, little-endian, laid out so IFD0 is empty and points at an
        // IFD1 carrying only the seven tags the renderer reads.
        let ifd1 = 14, stripAt = 104
        var tiff: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
             UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        tiff += u32(8)                       // IFD0 at +8
        tiff += u16(0)                       // IFD0: no entries
        tiff += u32(ifd1)                    // …next is IFD1
        let entries: [(Int, Int, Int)] = [    // tag, TIFF type, value
            (0x0100, 4, w), (0x0101, 4, h),
            (0x0103, 3, 1),                  // compression: none
            (0x0106, 3, 6),                  // photometric: YCbCr
            (0x0111, 4, stripAt),            // strip offset
            (0x0115, 3, 3),                  // samples per pixel
            (0x0117, 4, strip.count)         // strip length
        ]
        tiff += u16(entries.count)
        for (tag, type, value) in entries {
            tiff += u16(tag) + u16(type) + u32(1) + u32(value)
        }
        tiff += u32(0)                       // no IFD2
        tiff += strip

        // Wrapped as a JPEG APP1 segment, which is what comes off the wire
        // and where the parser expects to find the "Exif\0\0" marker.
        let payload = Array("Exif\0\0".utf8) + tiff
        return [0xFF, 0xD8, 0xFF, 0xE1]
            + [UInt8(((payload.count + 2) >> 8) & 0xFF), UInt8((payload.count + 2) & 0xFF)]
            + payload
    }

    /// The camera-side 80x60 grey strip, in the packing THAT MODEL uses.
    ///
    /// The two are not the same, and this used to emit the 150's for both.
    /// `QuickTakeThumbnailRenderer` has a decoder each: the 100's is plain
    /// sequential nibbles, two pixels a byte, row by row; the 150's is the
    /// interleaved 60-then-20-byte block scheme below. Feeding the 100's
    /// renderer the 150's packing unpacks to scan-line garbage.
    ///
    /// It went unnoticed while only the 150 had a demo, and then hid a while
    /// longer because the ice-shelf scene is mostly smooth sky and snow —
    /// scrambled order still reads as a vague grey picture. The station
    /// scene has railings and siding, and the scramble was obvious at once.
    static func kodakThumbnailBlock(from image: NSImage,
                                    model: QuickTakeModel = .qt150) -> [UInt8]? {
        let w = 80, h = 60
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: w, bitsPerPixel: 8) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let gray = rep.bitmapData else { return nil }

        // The renderer's `expand` is n * 255 / 15, so quantising back is / 17.
        func q(_ x: Int, _ y: Int) -> UInt8 { gray[y * w + x] / 17 }
        func pack(_ nibbles: [UInt8]) -> [UInt8] {
            stride(from: 0, to: nibbles.count, by: 2).map {
                (nibbles[$0] << 4) | (nibbles[$0 + 1] & 0x0F)
            }
        }

        var out: [UInt8] = []
        out.reserveCapacity(w * h / 2)

        // QuickTake 100: straight row-major, high nibble then low.
        if model == .qt100 {
            for y in 0..<h {
                for x in stride(from: 0, to: w, by: 2) {
                    out.append((q(x, y) << 4) | (q(x + 1, y) & 0x0F))
                }
            }
            return out.count == w * h / 2 ? out : nil
        }

        // QuickTake 150: interleaved, 60 bytes then 20 per pair of rows.
        for y in stride(from: 0, to: h, by: 2) {
            var first: [UInt8] = []
            for evenX in stride(from: 0, to: w, by: 2) {
                first.append(q(evenX, y))
                first.append(q(evenX + 1, y))
                first.append(q(evenX, y + 1))
            }
            out += pack(first)                    // 120 nibbles -> 60 bytes

            var second: [UInt8] = []
            for oddX in stride(from: 1, to: w, by: 2) {
                second.append(q(oddX, y + 1))
            }
            out += pack(second)                   // 40 nibbles -> 20 bytes
        }
        return out.count == w * h / 2 ? out : nil
    }

    /// Resources from the synchronized source group are flattened into the
    /// app bundle. Explicit names keep unrelated image assets out of the roll.
    static func photos(for model: QuickTakeModel) -> [DemoCamera.Photo] {
        func photo(_ image: NSImage, hq: Bool, at date: Date) -> DemoCamera.Photo? {
            guard let jpeg = jpegData(image, maxEdge: hq ? 640 : 320) else { return nil }
            // Each family's own thumbnail block, because each family's own
            // renderer is what will be handed it. A stand-in that skips
            // that lands on the grey placeholder in every cell.
            return DemoCamera.Photo(
                payload: [UInt8](jpeg),
                thumbnail: model.protocolFamily == .fuji
                    ? fujiThumbnailBlock(from: image)
                    : kodakThumbnailBlock(from: image, model: model),
                isHQ: hq,
                captured: date,
                container: nil)
        }

        let start = Date().addingTimeInterval(-600)
        let images: [NSImage]
        if model.protocolFamily == .fuji {
            images = DemoPanScene.Scene.allCases.flatMap { DemoPanScene.frames($0) }
        } else {
            // Disjoint selections, with one version of the shed photograph.
            let indices = model == .qt100
                ? [1, 4, 6, 8, 10, 13]
                : [2, 3, 5, 7, 9, 11, 12]
            images = indices.compactMap { index in
                let name = String(format: "DemoPhoto%02d", index)
                guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                    return nil
                }
                return NSImage(contentsOf: url)
            }
        }
        let library = images.enumerated().compactMap { index, image in
            photo(image, hq: true, at: start.addingTimeInterval(Double(index) * 6))
        }
        guard library.isEmpty else { return library }

        // Nothing to photograph. Test cards say so plainly; an empty
        // gallery would look like a camera with no film in it.
        return (0..<4).compactMap { i in
            photo(testCard(index: i, of: 4, hq: i % 2 == 0),
                  hq: i % 2 == 0,
                  at: start.addingTimeInterval(Double(-i) * 3600))
        }
    }

    private static func jpegData(_ image: NSImage, maxEdge: Int) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A 4:3 test card: hue ramp, colour bars, and a large numeral, so a
    /// misordered or duplicated cell is obvious at a glance.
    private static func testCard(index: Int, of count: Int, hq: Bool) -> NSImage {
        let size = NSSize(width: 640, height: 480)
        // An explicit 640x480 bitmap, not lockFocus — that draws into a
        // backing store at the DISPLAY's scale, so on a Retina Mac the
        // demo camera was serving 1280x960 "QuickTake" photos.
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 480,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage(size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let hue = Double(index % max(1, count)) / Double(max(1, count))
        NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.82, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))

        let bars: [NSColor] = [.systemGray, .systemYellow, .systemTeal, .systemGreen,
                               .systemPurple, .systemRed, .systemBlue]
        let barWidth = size.width / CGFloat(bars.count)
        for (i, colour) in bars.enumerated() {
            colour.setFill()
            NSBezierPath.fill(NSRect(x: CGFloat(i) * barWidth, y: 0,
                                     width: barWidth, height: size.height * 0.28))
        }

        let label = "\(index + 1)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 190, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let bounds = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(
            at: NSPoint(x: (size.width - bounds.width) / 2,
                        y: (size.height - bounds.height) / 2 + size.height * 0.08),
            withAttributes: attrs)

        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        ((hq ? "HQ" : "SQ") as NSString).draw(at: NSPoint(x: 22, y: size.height - 70),
                                              withAttributes: tagAttrs)
        ("PLACEHOLDER" as NSString).draw(
            at: NSPoint(x: 22, y: 26),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75)
            ])

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Menu

/// The Simulator menu. Present only while demo mode is on — see AppCommands.
struct SimulatorCommands: Commands {
    @ObservedObject var serialManager: QuickTakeSerialManager

    var body: some Commands {
        CommandMenu("Simulator") {
            Button("Connect Demo QuickTake 200") {
                Task { await serialManager.demoConnect(model: .qt200) }
            }
            .keyboardShortcut("c", modifiers: [.option, .command])
            .disabled(serialManager.isConnected || serialManager.isBusy)

            Button("Connect Demo QuickTake 150") {
                Task { await serialManager.demoConnect(model: .qt150) }
            }
            .disabled(serialManager.isConnected || serialManager.isBusy)

            // The 100 belongs here as much as the other two. It is the
            // camera the app is named after, it shares the QTK pipeline
            // with the 150, and leaving it out meant a third of the
            // supported QuickTakes could not be tried without hardware.
            Button("Connect Demo QuickTake 100") {
                Task { await serialManager.demoConnect(model: .qt100) }
            }
            .disabled(serialManager.isConnected || serialManager.isBusy)

            Button("Disconnect") {
                serialManager.demoDisconnect()
            }
            .keyboardShortcut("d", modifiers: [.option, .command])
            .disabled(!DemoCamera.shared.isConnected)
        }
    }
}
