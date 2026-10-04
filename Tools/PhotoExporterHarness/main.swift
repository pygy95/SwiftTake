import AppKit
import CoreGraphics
import Foundation
import ImageIO

// Behavioural checks for `PhotoExporter` — the state-independent export tail
// (date stamp, colour-space tag, atomic encode) split out of
// `QuickTakeSerialManager`. Synthetic CGImages and temp files only; every
// assertion is on an externally observable outcome (a written file's pixels,
// dimensions, embedded profile, or metadata), not on helper internals.

@main struct PhotoExporterChecks {
    static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1; print("PASS: " + name)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTakeExportChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // ── helpers ──────────────────────────────────────────────────
        func solidImage(width: Int, height: Int,
                        rgb: (CGFloat, CGFloat, CGFloat)) -> CGImage {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()!
        }
        /// Rasterise into a fixed RGBA8/sRGB buffer so two images are
        /// byte-comparable regardless of their own backing format. Row 0 is
        /// the top of the image.
        func rgba(_ image: CGImage) -> [UInt8] {
            let w = image.width, h = image.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { raw in
                let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        func readBack(_ url: URL) -> (image: CGImage, properties: [CFString: Any])? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            else { return nil }
            return (img, props)
        }
        func job(_ image: CGImage, to url: URL, uti: String,
                 stamp: Bool = false, date: Date? = nil, useP3: Bool = false,
                 properties: [String: Any] = [:],
                 collisionMode: AtomicFileWriter.CollisionMode = .exclusive,
                 isCurrent: @escaping @Sendable () -> Bool = { true }) -> PhotoExporter.ExportJob {
            PhotoExporter.ExportJob(
                cgImage: image, properties: properties, stampEnabled: stamp,
                captureDate: date, useP3: useP3, formatUTI: uti, fileURL: url,
                collisionMode: collisionMode, isCurrent: isCurrent)
        }
        /// Any RGB pixel differs from `other` inside the fractional rect
        /// (row 0 = top).
        func regionDiffers(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int,
                           xFrac: ClosedRange<Double>, yFrac: ClosedRange<Double>) -> Bool {
            for y in Int(Double(h) * yFrac.lowerBound)..<Int(Double(h) * yFrac.upperBound) {
                for x in Int(Double(w) * xFrac.lowerBound)..<Int(Double(w) * xFrac.upperBound) {
                    let i = (y * w + x) * 4
                    if a[i] != b[i] || a[i+1] != b[i+1] || a[i+2] != b[i+2] { return true }
                }
            }
            return false
        }

        let base = solidImage(width: 64, height: 48, rgb: (0.40, 0.55, 0.70))
        let stampDate = Date(timeIntervalSince1970: 858_450_000)  // 1997-03-16

        // 1 ── TIFF encodes and round-trips at full dimensions ────────
        do {
            let url = tmp.appendingPathComponent("dims.tiff")
            let out = try PhotoExporter.performExport(job(base, to: url, uti: "public.tiff"))
            check(out == url && FileManager.default.fileExists(atPath: url.path),
                  "TIFF export writes the requested file")
            let back = readBack(url)
            check(back?.image.width == 64 && back?.image.height == 48,
                  "exported TIFF decodes at the source pixel dimensions")
        }

        // 2 ── the caller's metadata dictionary reaches the file ──────
        do {
            let url = tmp.appendingPathComponent("meta.tiff")
            let stampStr = "1997:03:15 14:22:33"
            let props: [String: Any] = [
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFMake as String: "Apple",
                    kCGImagePropertyTIFFModel as String: "QuickTake 150",
                ],
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifDateTimeOriginal as String: stampStr,
                ],
            ]
            _ = try PhotoExporter.performExport(
                job(base, to: url, uti: "public.tiff", properties: props))
            guard let back = readBack(url) else { check(false, "meta.tiff re-read"); return }
            let tiff = back.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = back.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            check(tiff?[kCGImagePropertyTIFFModel] as? String == "QuickTake 150",
                  "TIFF Model string is written through to the file")
            check(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == stampStr,
                  "EXIF capture date is written through to the file")
        }

        // 3 ── useP3 selects the embedded profile; default is sRGB ────
        do {
            let sURL = tmp.appendingPathComponent("srgb.tiff")
            let pURL = tmp.appendingPathComponent("p3.tiff")
            _ = try PhotoExporter.performExport(job(base, to: sURL, uti: "public.tiff", useP3: false))
            _ = try PhotoExporter.performExport(job(base, to: pURL, uti: "public.tiff", useP3: true))
            let sName = (readBack(sURL)?.properties[kCGImagePropertyProfileName] as? String) ?? ""
            let pName = (readBack(pURL)?.properties[kCGImagePropertyProfileName] as? String) ?? ""
            check(sName.range(of: "sRGB", options: .caseInsensitive) != nil,
                  "default export embeds an sRGB profile (got \"\(sName)\")")
            check(pName.range(of: "P3", options: .caseInsensitive) != nil
                  && pName.range(of: "sRGB", options: .caseInsensitive) == nil,
                  "useP3 export embeds a Display P3 profile (got \"\(pName)\")")
            check(sName != pName, "the two colour-space choices produce different profiles")
        }

        // 4 ── stampDate alters pixels and never mutates its source ───
        do {
            let src = solidImage(width: 200, height: 150, rgb: (0.5, 0.5, 0.5))
            let before = rgba(src)
            guard let stamped = PhotoExporter.stampDate(on: src, at: stampDate) else {
                check(false, "stampDate returns an image"); return
            }
            check(stamped.width == 200 && stamped.height == 150,
                  "stamped image keeps the source dimensions")
            let after = rgba(stamped)
            check(after != before, "stamped image differs from the flat source")
            // The stamp is bottom-right (rasterised row 0 = top, so the high-y band).
            check(regionDiffers(after, before, w: 200, h: 150, xFrac: 0.5...1.0, yFrac: 0.6...1.0),
                  "the pixel change lands in the bottom-right corner")
            check(!regionDiffers(after, before, w: 200, h: 150, xFrac: 0.0...0.4, yFrac: 0.0...0.4),
                  "the opposite (top-left) corner is untouched")
            check(rgba(src) == before, "the source CGImage is unchanged after stamping")
        }

        // 4b ── stampEnabled flag changes the *exported* file, end to end
        do {
            let plainURL = tmp.appendingPathComponent("nostamp.tiff")
            let stampURL = tmp.appendingPathComponent("stamp.tiff")
            let src = solidImage(width: 200, height: 150, rgb: (0.5, 0.5, 0.5))
            _ = try PhotoExporter.performExport(job(src, to: plainURL, uti: "public.tiff", stamp: false))
            _ = try PhotoExporter.performExport(job(src, to: stampURL, uti: "public.tiff",
                                                    stamp: true, date: stampDate))
            guard let plain = readBack(plainURL)?.image, let stamped = readBack(stampURL)?.image else {
                check(false, "stamp/nostamp TIFFs re-read"); return
            }
            let p = rgba(plain), s = rgba(stamped)
            check(p != s, "stampEnabled:true produces a different file from stampEnabled:false")
            check(regionDiffers(s, p, w: 200, h: 150, xFrac: 0.5...1.0, yFrac: 0.6...1.0),
                  "the exported stamp difference is in the bottom-right corner")
            check(!regionDiffers(s, p, w: 200, h: 150, xFrac: 0.0...0.4, yFrac: 0.0...0.4),
                  "the rest of the exported frame is unchanged by the stamp")
        }

        // 5 ── an unwritable destination throws rather than returning ─
        do {
            let deadURL = tmp.appendingPathComponent("no-such-dir-\(UUID().uuidString)")
                .appendingPathComponent("out.tiff")
            var threw = false
            do { _ = try PhotoExporter.performExport(job(base, to: deadURL, uti: "public.tiff")) }
            catch { threw = true }
            check(threw, "performExport throws when the destination folder is missing")
            check(!FileManager.default.fileExists(atPath: deadURL.path),
                  "a failed export leaves no file behind")
        }

        // 5b ── atomic replace: a failed encode leaves the existing file and
        //       no temp artifacts behind ───────────────────────────────
        do {
            let dir = tmp.appendingPathComponent("atomic")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("existing.tiff")
            let sentinel = Data("SENTINEL-\(UUID().uuidString)".utf8)
            try sentinel.write(to: dest)

            var threw = false
            // An unregistered UTI makes CGImageDestinationCreateWithURL return
            // nil inside AtomicFileWriter's encode closure.
            do { _ = try PhotoExporter.performExport(job(base, to: dest, uti: "org.swifttake.not-a-real-uti")) }
            catch { threw = true }
            check(threw, "an unencodable format throws")
            check((try? Data(contentsOf: dest)) == sentinel,
                  "the pre-existing destination file is left byte-for-byte intact")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            check(leftovers.sorted() == ["existing.tiff"],
                  "no atomic-write temp artifacts remain (\(leftovers.sorted()))")
        }

        // 6 ── HDR: a float source is encoded into Rec.2100 PQ ────────
        hdrCheck: do {
            let heicProbe = tmp.appendingPathComponent("probe-\(UUID().uuidString).heic")
            guard CGImageDestinationCreateWithURL(heicProbe as CFURL, "public.heic" as CFString, 1, nil) != nil else {
                print("SKIP: HEIC encoding unavailable on this platform"); break hdrCheck
            }
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let ctx = CGContext(
                    data: nil, width: 32, height: 24, bitsPerComponent: 16, bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue
                        | CGBitmapInfo.floatComponents.rawValue) else {
                print("SKIP: extended-linear float context unavailable on this platform"); break hdrCheck
            }
            ctx.setFillColor(red: 2.0, green: 1.5, blue: 0.2, alpha: 1)   // > 1.0 headroom
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let floatImage = ctx.makeImage(),
                  floatImage.bitmapInfo.contains(.floatComponents) else {
                print("SKIP: platform did not produce a float-components CGImage"); break hdrCheck
            }
            // Past this point the format and input are known good — a throw is a failure.
            let url = tmp.appendingPathComponent("hdr.heic")
            let out = try PhotoExporter.performExport(job(floatImage, to: url, uti: "public.heic"))
            check(out == url && FileManager.default.fileExists(atPath: url.path),
                  "float/HDR source encodes to a HEIC file")
            let name = (readBack(url)?.image.colorSpace?.name as String?) ?? ""
            check(name == (CGColorSpace.itur_2100_PQ as String)
                  || name.range(of: "2100") != nil
                  || name.range(of: "PQ") != nil,
                  "the HDR file carries a Rec.2100 PQ colour space (got \"\(name)\")")
        }

        // 7 ── A2: exclusive publish refuses an existing file, leaving it
        //      byte-for-byte intact and no temp artifact behind ──────────
        do {
            let dir = tmp.appendingPathComponent("exclusive-refuse")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("shot.tiff")
            let sentinel = Data("SENTINEL-\(UUID().uuidString)".utf8)
            try sentinel.write(to: dest)

            var threw = false
            do { _ = try PhotoExporter.performExport(job(base, to: dest, uti: "public.tiff")) }
            catch is AtomicFileWriter.DestinationExistsError { threw = true }
            check(threw, "exclusive publish (the default) refuses an existing file with DestinationExistsError")
            check((try? Data(contentsOf: dest)) == sentinel, "the existing file is left byte-for-byte identical")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            check(leftovers == ["shot.tiff"], "no temp artifact remains after a refused exclusive publish")
        }

        // 7b ── A2: replace mode overwrites the file it was told to ───────
        do {
            let dir = tmp.appendingPathComponent("replace-mode")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("shot.tiff")
            try Data("SENTINEL".utf8).write(to: dest)

            let out = try PhotoExporter.performExport(job(base, to: dest, uti: "public.tiff", collisionMode: .replace))
            check(out == dest, "replace mode publishes to the requested destination")
            let back = readBack(dest)
            check(back?.image.width == 64 && back?.image.height == 48,
                  "replace mode's published file decodes at the source dimensions, not the sentinel bytes")
        }

        // 7c ── A2: a job whose isCurrent is false at publish time writes
        //       nothing and removes its own temp file ───────────────────
        do {
            let dir = tmp.appendingPathComponent("obsolete")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("shot.tiff")

            var threw = false
            do { _ = try PhotoExporter.performExport(job(base, to: dest, uti: "public.tiff", isCurrent: { false })) }
            catch is AtomicFileWriter.ObsoleteJobError { threw = true }
            check(threw, "a job whose isCurrent is false at publish time throws ObsoleteJobError")
            check(!FileManager.default.fileExists(atPath: dest.path), "an obsolete job publishes nothing")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            check(leftovers.isEmpty, "an obsolete job removes its own temp file")
        }

        // 7d ── A2: two concurrent exports to the same brand-new name —
        //       exactly one wins, the other fails cleanly, never a mix ───
        do {
            let dir = tmp.appendingPathComponent("concurrent")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("shot.tiff")
            let imageA = solidImage(width: 10, height: 10, rgb: (1, 0, 0))
            let imageB = solidImage(width: 20, height: 20, rgb: (0, 1, 0))
            // Built here, synchronously, and captured as plain (`@unchecked
            // Sendable`) values below — calling the local `job(...)` helper
            // itself from inside `Task.detached` would need it marked
            // `@Sendable`, which a MainActor-inferred local function can't be.
            let jobA = job(imageA, to: dest, uti: "public.tiff")
            let jobB = job(imageB, to: dest, uti: "public.tiff")

            async let outcomeA: Result<URL?, Error> = Task.detached {
                Result { try PhotoExporter.performExport(jobA) }
            }.value
            async let outcomeB: Result<URL?, Error> = Task.detached {
                Result { try PhotoExporter.performExport(jobB) }
            }.value
            let (ra, rb) = await (outcomeA, outcomeB)
            let results = [ra, rb]
            let succeeded = results.filter { if case .success = $0 { return true }; return false }
            let failed = results.filter { if case .failure = $0 { return true }; return false }
            check(succeeded.count == 1, "exactly one of two concurrent same-name exports publishes")
            check(failed.count == 1, "the other fails rather than silently overwriting or corrupting the file")
            let loserIsCollision = failed.contains {
                if case .failure(let error) = $0 { return error is AtomicFileWriter.DestinationExistsError }
                return false
            }
            check(loserIsCollision, "the losing export fails with DestinationExistsError, not a generic I/O error")
            guard let publishedImage = readBack(dest)?.image else {
                check(false, "the destination re-reads after the race resolves"); return
            }
            let matchesA = publishedImage.width == imageA.width && publishedImage.height == imageA.height
            let matchesB = publishedImage.width == imageB.width && publishedImage.height == imageB.height
            check(matchesA != matchesB, "the published file is exactly one complete image, never a mix of both")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            check(leftovers == ["shot.tiff"], "no temp artifacts remain once the race resolves")
        }

        // Pause the production path after a real ImageIO encode. A newer file
        // lands while the old job is suspended; only a current Replace may win.
        for scenario in ["cancelled", "new generation", "current"] {
            let dir = tmp.appendingPathComponent("staged-" + scenario)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("shot.tiff")
            let oldJob = job(base, to: dest, uti: "public.tiff", collisionMode: .replace)
            let work = CameraWork()
            let generation = work.generation
            let (started, signal) = AsyncStream<Void>.makeStream()
            let release = DispatchSemaphore(value: 0)
            let pending = Task {
                try await PhotoExporter.exportOffMain(oldJob, isCurrent: { work.isCurrent(generation) }) { job in
                    defer { signal.finish() }
                    let staged = try PhotoExporter.encodeToTemporary(job)
                    signal.yield(())
                    release.wait()
                    return staged
                }
            }
            for await _ in started { break }
            if scenario == "cancelled" { pending.cancel() }
            if scenario == "new generation" { work.invalidate() }
            let newer = solidImage(width: 20, height: 20, rgb: (0, 1, 0))
            do {
                _ = try PhotoExporter.performExport(job(newer, to: dest, uti: "public.tiff"))
            } catch {
                release.signal()
                _ = try? await pending.value
                throw error
            }
            release.signal()
            let result = try await pending.value
            let current = scenario == "current"
            check(current ? result == dest : result == nil, "\(scenario): production publication outcome")
            check(readBack(dest)?.image.width == (current ? base.width : 20),
                  "\(scenario): obsolete Replace preserves the newer image")
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            check(entries == ["shot.tiff"], "\(scenario): staged export is cleaned up")
        }

        print("\nAll \(passed) PhotoExporter checks passed.")
    }
}
