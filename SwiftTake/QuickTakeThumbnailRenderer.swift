// MARK: - QuickTakeThumbnailRenderer
//
// Decompresses the QuickTake 100/150 camera-side 80×60 grayscale thumbnail
// block (raw 4-bit-packed nibbles) into a previewable NSImage. The two
// Kodak models pack the strip differently, so there is a decoder each.
//
// QT200 / Fuji thumbnails are not handled here — that family has no
// grayscale strip on the wire and its previews come from
// `QuickTake200JPEGDecoder`.
//
// `internal` rather than `private`: the type moved out of the manager into
// its own file, and the manager (and the rendering harness) still reach it.
// It has no other in-app callers.

import AppKit
import CoreGraphics

enum QuickTakeThumbnailRenderer {
    static let width = 80
    static let height = 60
    static let expectedByteCount = width * height / 2

    static func renderImage(from bytes: [UInt8], model: QuickTakeModel) -> NSImage? {
        // Only handles Kodak's raw 4-bit-packed thumbnail bytes. QT200
        // thumbnails come from the JPEG decode path
        // (`QuickTake200JPEGDecoder.embeddedThumbnail`); that camera has
        // no 80×60 grayscale strip on the wire.
        guard model.usesQTKFormat else { return nil }
        guard bytes.count == expectedByteCount else { return nil }

        let grayscalePixels: [UInt8]
        switch model {
        case .qt100:
            grayscalePixels = decodeQT100(bytes)
        case .qt150:
            grayscalePixels = decodeQT150(bytes)
        case .qt200, .fujiDS7, .samsungSSC350N:
            return nil // Unreachable: guarded above by `usesQTKFormat`.
        }

        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)
        for value in grayscalePixels {
            rgba.append(value)
            rgba.append(value)
            rgba.append(value)
            rgba.append(255)
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func decodeQT100(_ bytes: [UInt8]) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height)

        for byte in bytes {
            pixels.append(expand(byte >> 4))
            pixels.append(expand(byte & 0x0F))
        }

        return pixels
    }

    private static func decodeQT150(_ bytes: [UInt8]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var byteIndex = 0

        for y in stride(from: 0, to: height, by: 2) {
            let firstBlock = Array(bytes[byteIndex..<(byteIndex + 60)])
            byteIndex += 60

            var firstNibbles = nibbles(from: firstBlock)
            for evenX in stride(from: 0, to: width, by: 2) {
                pixels[(y * width) + evenX] = expand(firstNibbles.removeFirst())
                pixels[(y * width) + (evenX + 1)] = expand(firstNibbles.removeFirst())
                pixels[((y + 1) * width) + evenX] = expand(firstNibbles.removeFirst())
            }

            let secondBlock = Array(bytes[byteIndex..<(byteIndex + 20)])
            byteIndex += 20
            var secondNibbles = nibbles(from: secondBlock)
            for oddX in stride(from: 1, to: width, by: 2) {
                pixels[((y + 1) * width) + oddX] = expand(secondNibbles.removeFirst())
            }
        }

        return pixels
    }

    private static func nibbles(from bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(bytes.count * 2)

        for byte in bytes {
            result.append((byte >> 4) & 0x0F)
            result.append(byte & 0x0F)
        }

        return result
    }

    private static func expand(_ nibble: UInt8) -> UInt8 {
        UInt8((Int(nibble) * 255) / 15)
    }
}
