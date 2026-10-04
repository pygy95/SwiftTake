import AppKit
import CoreGraphics

/// Transfers a decoded image between tasks. Callers must not mutate the image
/// after handing it off; `NSImage` is not itself Sendable.
struct SendableImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// Carries an immutable Core Graphics image and its camera slot between tasks.
struct SendableSlotFrame: @unchecked Sendable {
    let slot: UInt8
    let image: CGImage
}
