// MARK: - QuickTakeCommands
//
// The byte sequences the QuickTake 100 / 150 expects over the serial
// line. These are protocol *facts* — the wire format the camera's own
// firmware defines — not creative code, so they're identical in any
// working client.
//
// Packet shape: apart from the irregular session-control packets (`open`,
// `acknowledge`), every command is a frame of
//
//     0x16, <op>, 0x00, <sub>, 0x00, 0x00, <tail …>
//
// where `op` selects the operation (read / erase / set / capture / ping)
// and `sub` selects the specific function within it. The `tail` carries
// indices, lengths, and embedded payloads. `frame(_:sub:tail:)` builds
// that common shape so each command reads as just "op + sub + its tail."

import Foundation

enum QuickTakeCommands {

    // Operation codes (the second byte of a framed packet).
    private enum Op {
        static let ping: UInt8     = 0x00
        static let capture: UInt8  = 0x1B
        static let read: UInt8     = 0x28
        static let erase: UInt8    = 0x29
        static let set: UInt8      = 0x2A
    }

    /// Build the standard 6-byte command prefix plus a tail.
    private static func frame(_ op: UInt8, sub: UInt8, tail: [UInt8] = []) -> [UInt8] {
        [0x16, op, 0x00, sub, 0x00, 0x00] + tail
    }

    // MARK: Session control

    /// Wake / open packet sent right after the DTR nudge. Irregular shape.
    /// Bytes 6–7 ADVERTISE the session speed the host will negotiate and
    /// byte 12 is the matching checksum — speed-specific, hardware-verified
    /// values for the QuickTake 100. A fixed packet that always advertised
    /// 57600 would break sessions where 9600 was chosen in Settings.
    static func open(baud: Int) -> [UInt8] {
        let (b6, b7, check): (UInt8, UInt8, UInt8) =
            (baud == 9600) ? (0x25, 0x80, 0x80) : (0xE1, 0x00, 0xBC)
        return [0x5A, 0xA5, 0x55, 0x05, 0x00, 0x00, b6, b7, 0x00, 0x80, 0x02, 0x00, check]
    }

    /// The single-byte ACK (0x06) we send to advance a transfer.
    static func acknowledge() -> [UInt8] { [0x06] }

    /// No-op keep-alive / readiness probe.
    static func ping() -> [UInt8] { frame(Op.ping, sub: 0x00, tail: [0x00]) }

    /// Request the camera switch its port to `baud`. Speed byte per the
    /// hardware-verified table: 9600 = 0x08, 19200 = 0x10,
    /// 38400 = 0x20, 57600 = 0x30. Sent even when STAYING at 9600 — the
    /// negotiation the open packet advertised always runs.
    static func selectBaud(_ baud: Int) -> [UInt8] {
        let speedByte: UInt8
        switch baud {
        case 9600:  speedByte = 0x08
        case 19200: speedByte = 0x10
        case 38400: speedByte = 0x20
        default:    speedByte = 0x30   // 57600
        }
        return frame(Op.set, sub: 0x03, tail: [0x00, 0x00, 0x00, 0x05, 0x00, 0x03, 0x03, speedByte, 0x04, 0x00])
    }

    // MARK: Reads

    /// 128-byte device-info block (battery, frame counts, flash, name…).
    static func deviceInfo() -> [UInt8] {
        frame(Op.read, sub: 0x30, tail: [0x00, 0x00, 0x00, 0x80, 0x00])
    }

    /// 64-byte header for one photo (the `0x40` tail byte is the length).
    static func photoHeader(index: UInt8) -> [UInt8] {
        frame(Op.read, sub: 0x21, tail: [index &+ 1, 0x00, 0x00, 0x40, 0x00])
    }

    /// Fixed 2400-byte thumbnail (`0x0960` length in the tail).
    static func thumbnail(index: UInt8) -> [UInt8] {
        frame(Op.read, sub: 0x00, tail: [index &+ 1, 0x00, 0x09, 0x60, 0x00])
    }

    /// Full image. `sizeField` is the camera's own 3-byte length echoed
    /// back from the photo header.
    static func photo(index: UInt8, sizeField: [UInt8]) -> [UInt8] {
        frame(Op.read, sub: 0x10, tail: [index &+ 1] + sizeField + [0x00])
    }

    // MARK: Writes / control

    /// Erase every photo on the camera.
    static func eraseAll() -> [UInt8] {
        frame(Op.erase, sub: 0x00, tail: [0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// Trip the shutter.
    static func capture() -> [UInt8] { frame(Op.capture, sub: 0x00, tail: [0x00]) }

    /// Flash mode: 0 auto, 1 off, 2 forced.
    static func setFlash(mode: UInt8) -> [UInt8] {
        frame(Op.set, sub: 0x07, tail: [0x00, 0x00, 0x00, 0x03, 0x00, 0x07, 0x01, mode])
    }

    /// Capture quality: high (0x10) vs standard (0x20).
    static func setQuality(high: Bool) -> [UInt8] {
        frame(Op.set, sub: 0x06, tail: [0x00, 0x00, 0x00, 0x04, 0x00, 0x06, 0x02, high ? 0x10 : 0x20, 0x00])
    }

    /// Set the camera clock (6 BCD-ish date/time bytes supplied by caller).
    static func setClock(_ dateTime: [UInt8]) -> [UInt8] {
        frame(Op.set, sub: 0x01, tail: [0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x06] + dateTime)
    }

    /// Set the camera's stored name (ASCII bytes supplied by caller).
    static func setName(_ ascii: [UInt8]) -> [UInt8] {
        frame(Op.set, sub: 0x02, tail: [0x00, 0x00, 0x00, 0x22, 0x00, 0x02, 0x20] + ascii)
    }
}
