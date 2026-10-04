// MARK: - SerialPortFinder
//
// Locates a USB-to-serial adapter's `/dev/cu.*` callout node by walking
// the IOKit serial-BSD registry, so the app can auto-pick a port at
// connect time instead of making the user dig one out of System
// Information. Returns the best-looking candidate, or nil if none match.
//
// The matching is a name heuristic on the device path — the registry
// exposes adapters under names like `usbserial-*`, `usbmodem*`, etc.

import Foundation
import IOKit
import IOKit.serial

// A pure utility — no actor state — so everything is `nonisolated` and
// callable from any context (the project defaults types to `@MainActor`).
nonisolated enum SerialPortFinder {

    /// Path fragments that mark a USB-serial bridge. Preference between
    /// matches is decided by `score(_:)`, not this list's order; CH340 is
    /// still matched, just ranked last.
    private static let knownMarkers: [String] = [
        "pl2303",
        "usbserial",
        "usbtouart",
        "usbmodem",
        "serialadapter",
        "usb-to-serial",
        "uart",
        "wchusbserial",   // CH340 — usable but not recommended
    ]

    /// The `/dev/cu.*` path most likely to be the camera adapter, or nil.
    static func bestCandidate() -> String? {
        candidatePaths()
            .filter(isUSBSerial)
            .max { score($0) < score($1) }
    }

    /// Every serial callout device path the IORegistry currently lists.
    private static func candidatePaths() -> [String] {
        guard var query = IOServiceMatching(kIOSerialBSDServiceValue) as? [String: Any] else {
            return []
        }
        query[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, query as CFDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var paths: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            // IORegistryEntryCreateCFProperty follows the Create rule
            // (returns +1), so the result must be released — take it
            // retained and let ARC drop it.
            if let value = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String {
                paths.append(value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return paths
    }

    private static func isUSBSerial(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return knownMarkers.contains { lowered.contains($0) }
    }

    /// Higher score = more likely the adapter we want. CH340 parts work
    /// but are unreliable on the QuickTake's clock, so they rank last —
    /// and must be checked first, since "wchusbserial" contains the
    /// substring "usbserial" and would otherwise look like a generic FTDI.
    private static func score(_ path: String) -> Int {
        let lowered = path.lowercased()
        if lowered.contains("wchusbserial") { return 1 }    // CH340 — bottom
        if lowered.contains("pl2303") { return 6 }          // Prolific
        if lowered.contains("usbserial") { return 5 }       // usually FTDI
        if lowered.contains("usbtouart") { return 4 }
        if lowered.contains("usbmodem") { return 3 }
        if lowered.contains("serialadapter") || lowered.contains("usb-to-serial") || lowered.contains("uart") { return 2 }
        return 0
    }
}
