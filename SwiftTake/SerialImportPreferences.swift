// MARK: - Serial / import preference options
//
// Small user-facing enums that back the manager's persisted serial and
// import settings and populate the Settings screen pickers. Kept together
// because they are the same kind of thing — a `String`-raw, `CaseIterable`
// choice list with display strings — and share no logic with the transfer
// pipeline.

import Foundation

enum SerialBaudRate: String, CaseIterable, Identifiable {
    case bps57600 = "57600"
    case bps9600 = "9600"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bps57600:
            return "57600 baud"
        case .bps9600:
            return "9600 baud"
        }
    }

    var detail: String {
        switch self {
        case .bps57600:
            return "Default"
        case .bps9600:
            return "Slower, more reliable"
        }
    }
}

enum PostImportAction: String, CaseIterable, Identifiable {
    case doNothing = "doNothing"
    case showInFinder = "showInFinder"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doNothing:
            return "Do Nothing"
        case .showInFinder:
            return "Show in Finder"
        }
    }
}
