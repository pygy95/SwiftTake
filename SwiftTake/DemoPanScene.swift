// Overlapping crops of credited panorama photographs for the QT200 demo.
// The deterministic drawing remains a fallback and a stitcher test fixture.

import AppKit
import CoreGraphics

enum DemoPanScene {
    static let frameWidth = 640
    static let frameHeight = 480
    static let defaultStep = 256

    /// Three panorama sets presented consecutively in the QT200 demo.
    enum Scene {
        /// The Ross Ice Shelf from the Crary Lab. First set.
        case iceShelf
        /// The Crary Science and Engineering Center buildings. Second set.
        case station
        /// Inside the Crary lab. Third set.
        case interior

        var resource: (name: String, ext: String) {
            switch self {
            case .iceShelf: return ("DemoPanSource", "jpg")
            case .station:  return ("DemoPanSourceStation", "png")
            case .interior: return ("DemoPanSourceInterior", "png")
            }
        }

        /// Chosen so each roll's overlap lands where a QuickPan actually
        /// puts it. The head clicks every 22.5 degrees, which with the bare
        /// lens (~38 degrees) leaves ~41% overlap and with the WideTake
        /// (60.3 degrees, fitted to a hardware capture sequence) leaves ~63%. Between
        /// those is what a real sequence looks like; well above it is a
        /// sequence nobody would shoot.
        ///
        ///     iceShelf  6 frames  47%   bare-lens QuickPan
        ///     station   5 frames  57%
        ///     interior 12 frames  43%   bare-lens QuickPan, and the long one
        var frameCount: Int {
            switch self {
            case .iceShelf: return 6
            case .station:  return 5
            case .interior: return 12
            }
        }

        /// All three demo photographs are by Tim Meehan. The credit is drawn
        /// into the corner of each scene — see `credited`.
        ///
        /// Optional rather than a plain String on purpose: if a scene is
        /// ever added from an unconfirmed source it gets no name instead of
        /// inheriting someone else's, which is the failure worth designing
        /// against here.
        var photographer: String? {
            switch self {
            case .iceShelf, .station, .interior: return "Tim Meehan"
            }
        }

        /// Every bundled scene, so `DemoPhotoLibrary` can keep them out of
        /// the photo enumeration — a wide scene served as a single photo
        /// would replace the whole demo gallery with itself, which is
        /// exactly what happened the first time one shipped.
        static var allFileNames: [String] {
            allCases.map { "\($0.resource.name).\($0.resource.ext)" }
        }
        static let allCases: [Scene] = [.iceShelf, .station, .interior]
    }

    /// Overlapping frames, left to right.
    static func frames(_ scene: Scene = .iceShelf) -> [NSImage] {
        cgFrames(scene).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }

    static func cgFrames(_ scene: Scene) -> [CGImage] {
        cgFrames(count: scene.frameCount, step: defaultStep, scene: scene)
    }

    /// The real work, in CoreGraphics all the way through.
    ///
    /// Not NSImage/lockFocus, which draws into a backing store at the
    /// DISPLAY's scale: on a Retina Mac that quietly yielded 1280x960
    /// frames — a size no QuickTake ever produced, from a camera the demo
    /// claims is a QuickTake. Pixel dimensions here have to be the ones
    /// asked for, on any machine.
    static func cgFrames(count: Int = 5, step: Int = defaultStep,
                         scene sceneKind: Scene = .iceShelf) -> [CGImage] {
        guard count >= 2 else { return [] }

        // The photograph if it shipped, the drawing if it did not. Both are
        // one wide scene sliced the same way, so everything downstream —
        // and the harness — is indifferent to which one arrived.
        let source = bundledScene(sceneKind)
            ?? wideScene(width: frameWidth + (count - 1) * step, height: frameHeight)
        guard let scene = source,
              scene.width >= frameWidth, scene.height >= frameHeight else { return [] }

        // Offsets span the scene rather than assuming a fixed step, since a
        // photograph is whatever width it happens to be. Rounded per frame
        // so the last one lands exactly on the right edge instead of
        // accumulating a gap — the stitcher would read that gap as real and
        // report an overlap the demo does not have.
        let travel = scene.width - frameWidth
        return (0..<count).compactMap { i in
            let x = Int((Double(travel) * Double(i) / Double(count - 1)).rounded())
            guard let cut = scene.cropping(to: CGRect(x: x, y: 0,
                                                      width: frameWidth,
                                                      height: frameHeight)) else { return nil }
            // A gentle exposure ramp along the sweep. Real pans have one —
            // the reference set brightens hard into the sun — and absorbing
            // it is exactly what the gain compensation is for, so a demo
            // without it would leave that step untested.
            let t = Double(i) / Double(count - 1)
            return exposed(cut, by: 1.0 + 0.14 * (t - 0.5)) ?? cut
        }
    }

    /// Where the photograph lives when there is no app bundle to ask.
    /// Tools/StitchHarness runs as a plain binary, and a harness that
    /// silently fell back to the drawing would report the demo green
    /// without ever having looked at what actually ships.
    nonisolated(unsafe) static var sourceOverrideURL: URL?

    /// The width of the scene the frames were cut from — the strip a
    /// correct stitch has to reproduce. Not circular: the stitcher is
    /// never shown this, it has to recover it from the pixels.
    static func sceneWidth(count: Int = 5, step: Int = defaultStep,
                           scene: Scene = .iceShelf) -> Int {
        bundledScene(scene)?.width ?? (frameWidth + (count - 1) * step)
    }

    /// The photograph, if it is in the bundle.
    ///
    /// A 1990s panorama of the Ross Ice Shelf, looking out from the Crary
    /// Lab at McMurdo. Photograph by Tim Meehan; preserve this credit
    /// wherever the image is shown or distributed.
    ///
    /// Worth having over the drawing for one reason: it is a real
    /// photograph, so it carries grain, a film-scan colour cast and a
    /// horizon that is genuinely not straight, where a drawn scene is
    /// mathematically perfect and flatters the correlator.
    ///
    /// Cropped to the frame height, never scaled — the source is already a
    /// generous upscale of a small period JPEG, and resampling it twice
    /// would show. At 640x480 the softness reads as a QuickTake 150 photo,
    /// which is what it is standing in for.
    private static func bundledScene(_ scene: Scene = .iceShelf) -> CGImage? {
        let res = scene.resource
        guard let url = sourceOverrideURL
                ?? Bundle.main.url(forResource: res.name, withExtension: res.ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= frameWidth, image.height >= frameHeight
        else { return nil }
        let cropped = image.height > frameHeight
            ? (image.cropping(to: CGRect(x: 0, y: (image.height - frameHeight) / 2,
                                         width: image.width, height: frameHeight)) ?? image)
            : image
        guard let who = scene.photographer else { return cropped }
        return credited(cropped, to: who) ?? cropped
    }

    /// Tim Meehan's name, in the corner of his photograph.
    ///
    /// Drawn ONCE into the wide scene rather than onto each frame. Per-frame
    /// would stamp it five times across a stitched panorama — and the frames
    /// overlap, so some copies would be sliced in half by the blend. Here it
    /// lands where a photo credit belongs: the bottom-right of the finished
    /// picture. Only the frames covering that corner carry it in the gallery,
    /// which is the trade for the panorama reading properly.
    private static func credited(_ image: CGImage, to photographer: String) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Wrapped rather than lockFocus'd: this has to render at the pixel
        // size asked for, not the display's scale.
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let shadow = NSShadow()
        // The credit sits over snow and sky, which run to white — so it
        // carries its own dark halo rather than trusting the background.
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let line = NSAttributedString(string: "Photograph by \(photographer)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .shadow: shadow
        ])
        let size = line.size()
        line.draw(at: NSPoint(x: CGFloat(w) - size.width - 14, y: 10))

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Deterministic, so the demo gallery is the same every launch and a
    /// change in the stitched result means the STITCHER changed.
    private struct Seeded {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func unit() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFF_FFFF) / CGFloat(0xFF_FFFF)
        }
        mutating func between(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo + (hi - lo) * unit()
        }
    }

    /// One wide cylindrical scene. Everything here exists to give the
    /// correlator something to bite on: hard vertical edges at varied
    /// spacing, detail at several scales, and no exactly repeating motif —
    /// a row of identical windows is a row of equally good false matches.
    private static func wideScene(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let W = CGFloat(width), H = CGFloat(height)
        let horizon = H * 0.46
        var rng = Seeded(0x51F7_A4E3)

        // Sky.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon, width: W, height: H - horizon))
        if let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.30, green: 0.55, blue: 0.86, alpha: 1),
            CGColor(srgbRed: 0.79, green: 0.90, blue: 0.96, alpha: 1)] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H),
                                   end: CGPoint(x: 0, y: horizon), options: [])
        }
        ctx.restoreGState()

        // Sun, off to one side so the exposure ramp has a reason.
        let sun = CGPoint(x: W * 0.72, y: H * 0.82)
        if let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 0.98, blue: 0.88, alpha: 0.95),
            CGColor(srgbRed: 1, green: 0.94, blue: 0.72, alpha: 0)] as CFArray,
            locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0,
                                   endCenter: sun, endRadius: H * 0.34, options: [])
        }

        // Clouds.
        for _ in 0..<14 {
            let cx = rng.between(0, W), cy = rng.between(horizon + H * 0.12, H * 0.98)
            let rw = rng.between(H * 0.10, H * 0.30), rh = rw * rng.between(0.22, 0.38)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1,
                                     alpha: rng.between(0.20, 0.55)))
            ctx.fillEllipse(in: CGRect(x: cx - rw/2, y: cy - rh/2, width: rw, height: rh))
        }

        // Two ridges, the far one hazier — depth, and a horizon that is not
        // a straight line to lock onto.
        func ridge(base: CGFloat, amp: CGFloat, wave: CGFloat, phase: CGFloat, colour: CGColor) {
            ctx.setFillColor(colour)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= W {
                let y = base + amp * (sin(x / wave + phase)
                                      + 0.45 * sin(x / (wave * 0.37) + phase * 1.7))
                ctx.addLine(to: CGPoint(x: x, y: y))
                x += 3
            }
            ctx.addLine(to: CGPoint(x: W, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        ridge(base: horizon + H * 0.10, amp: H * 0.035, wave: 210, phase: 0.6,
              colour: CGColor(srgbRed: 0.62, green: 0.72, blue: 0.80, alpha: 1))
        ridge(base: horizon + H * 0.045, amp: H * 0.028, wave: 130, phase: 2.4,
              colour: CGColor(srgbRed: 0.42, green: 0.56, blue: 0.58, alpha: 1))

        // Ground.
        ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.46, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: horizon + H * 0.02))

        // Buildings, at irregular spacing and heights.
        var x: CGFloat = rng.between(10, 60)
        while x < W - 40 {
            let bw = rng.between(52, 132)
            let bh = rng.between(H * 0.10, H * 0.26)
            let base = horizon - rng.between(0, H * 0.03)
            let shade = rng.between(0.52, 0.86)
            ctx.setFillColor(CGColor(srgbRed: shade * 0.78, green: shade * 0.70,
                                     blue: shade * 0.63, alpha: 1))
            ctx.fill(CGRect(x: x, y: base, width: bw, height: bh))

            // Roof, so the silhouette is not all rectangles.
            if rng.unit() > 0.45 {
                ctx.setFillColor(CGColor(srgbRed: shade * 0.44, green: shade * 0.34,
                                         blue: shade * 0.30, alpha: 1))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x - 6, y: base + bh))
                ctx.addLine(to: CGPoint(x: x + bw / 2, y: base + bh + rng.between(14, 34)))
                ctx.addLine(to: CGPoint(x: x + bw + 6, y: base + bh))
                ctx.closePath()
                ctx.fillPath()
            }

            // Windows: a grid with gaps punched in it, so no two façades
            // read the same.
            let cols = max(1, Int(bw / 26)), rows = max(1, Int(bh / 30))
            for c in 0..<cols {
                for r in 0..<rows where rng.unit() > 0.26 {
                    let lit = rng.unit() > 0.62
                    ctx.setFillColor(lit
                        ? CGColor(srgbRed: 0.98, green: 0.90, blue: 0.60, alpha: 1)
                        : CGColor(srgbRed: 0.16, green: 0.20, blue: 0.26, alpha: 1))
                    ctx.fill(CGRect(x: x + CGFloat(c) * 26 + 7,
                                    y: base + CGFloat(r) * 30 + 9,
                                    width: 12, height: 16))
                }
            }
            x += bw + rng.between(16, 78)
        }

        // Trees along the near edge.
        var tx: CGFloat = rng.between(0, 90)
        while tx < W {
            let th = rng.between(H * 0.09, H * 0.20)
            let base = horizon - rng.between(H * 0.02, H * 0.10)
            ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.22, blue: 0.14, alpha: 1))
            ctx.fill(CGRect(x: tx - 3, y: base, width: 6, height: th * 0.45))
            let leaf = rng.between(0.30, 0.48)
            ctx.setFillColor(CGColor(srgbRed: leaf * 0.55, green: leaf * 1.25,
                                     blue: leaf * 0.48, alpha: 1))
            for _ in 0..<5 {
                let r = th * rng.between(0.22, 0.40)
                ctx.fillEllipse(in: CGRect(x: tx - r + rng.between(-12, 12),
                                           y: base + th * 0.35 + rng.between(-8, 16),
                                           width: r * 2, height: r * 1.7))
            }
            tx += rng.between(70, 190)
        }

        // A path that crosses the whole sweep. A long continuous feature is
        // the sort of thing a stitch failure breaks visibly.
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.66, blue: 0.50, alpha: 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: horizon * 0.24))
        var px: CGFloat = 0
        while px <= W {
            ctx.addLine(to: CGPoint(x: px, y: horizon * 0.24 + 26 * sin(px / 260 + 1.1)))
            px += 6
        }
        while px >= 0 {
            ctx.addLine(to: CGPoint(x: px, y: horizon * 0.24 + 54 + 26 * sin(px / 260 + 1.1)))
            px -= 6
        }
        ctx.closePath()
        ctx.fillPath()

        // Grass.
        for _ in 0..<2600 {
            let gx = rng.between(0, W), gy = rng.between(0, horizon)
            let shade = rng.between(0.22, 0.58)
            ctx.setFillColor(CGColor(srgbRed: shade * 0.72, green: shade * 1.15,
                                     blue: shade * 0.52, alpha: rng.between(0.25, 0.7)))
            ctx.fill(CGRect(x: gx, y: gy, width: rng.between(1, 3), height: rng.between(2, 7)))
        }

        return ctx.makeImage()
    }

    private static func exposed(_ cg: CGImage, by exposure: Double) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.draw(cg, in: rect)
        if exposure > 1 {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1,
                                     alpha: CGFloat(exposure - 1)))
            ctx.fill(rect)
        } else if exposure < 1 {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0,
                                     alpha: CGFloat(1 - exposure)))
            ctx.fill(rect)
        }
        return ctx.makeImage()
    }
}
