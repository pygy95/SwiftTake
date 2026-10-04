import Foundation

// Exercise the production Easter-egg methods without starting serial hardware
// or reading the user's settings. Only the surrounding app state is a fixture.
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
func declaration(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError("Missing \(signature)") }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unterminated \(signature)")
}
print(#"""
import AppKit
import Darwin

enum QuickTakeModel: CaseIterable { case qt100, qt150, qt200 }
@MainActor final class Fixture {
    var selectedModel: QuickTakeModel { didSet { modelWrites += 1 } }
    var modelWrites = 0
    var errorMessage: String? = "Existing camera error"
    var phantomEgg: PhantomEgg?
    var isConnected: Bool
    var isBusy: Bool
    var isConnecting: Bool
    var selectedPortPath = "/dev/cu.fixture"
    var photoIndices: [UInt8] = [0,1,2]
    var selectedPhotoIndices: Set<UInt8> = [1,2]
    var statusMessage = "Existing session"
    var generation = 17
    init(model: QuickTakeModel, state: Int) {
        selectedModel = model
        isConnected = state == 1 || state == 2
        isBusy = state == 2
        isConnecting = state == 3
    }
"""#)
for signature in ["enum PhantomEgg:", "func loadPhantomQTK(named", "func dismissPhantom()"] {
    print(declaration(signature))
}
print(#"""
}
@main struct Checks {
    @MainActor static func main() {
        var checks = 0, failures = 0
        func check(_ success: Bool, _ label: String) {
            checks += 1; if !success { failures += 1 }
            print("\(success ? "PASS" : "FAIL"): \(label)")
        }
        // Register small stand-ins for bundled artwork in AppKit's image cache.
        let artwork = Fixture.PhantomEgg.allCases.map { egg in
            let image = NSImage(size: NSSize(width: 2, height: 2))
            precondition(image.setName(NSImage.Name(egg.asset)))
            return image
        }
        withExtendedLifetime(artwork) {
            for model in QuickTakeModel.allCases {
                for state in 0..<4 {
                    let f = Fixture(model: model, state: state)
                    for egg in Fixture.PhantomEgg.allCases {
                        let name = "\(model)/state\(state)/\(egg.rawValue)"
                        check(f.loadPhantomQTK(named: egg.rawValue.uppercased()) && f.phantomEgg == egg,
                              "\(name): matching artwork still opens")
                        check(f.selectedModel == model && f.modelWrites == 0,
                              "\(name): camera model and its persistence are untouched")
                        check(f.errorMessage == "Existing camera error" && f.statusMessage == "Existing session"
                              && f.selectedPortPath == "/dev/cu.fixture" && f.generation == 17
                              && f.photoIndices == [0,1,2] && f.selectedPhotoIndices == [1,2]
                              && f.isConnected == (state == 1 || state == 2)
                              && f.isBusy == (state == 2) && f.isConnecting == (state == 3),
                              "\(name): session state is preserved")
                        f.dismissPhantom()
                        check(f.phantomEgg == nil && f.selectedModel == model,
                              "\(name): dismissal preserves the active profile")
                    }
                }
            }
            let f = Fixture(model: .qt150, state: 1)
            _ = f.loadPhantomQTK(named: "mars")
            check(!f.loadPhantomQTK(named: "ordinary-photo") && f.phantomEgg == .mars && f.modelWrites == 0,
                  "unrecognized names leave the existing overlay and camera alone")
            artwork[2].setName(nil)
            check(!f.loadPhantomQTK(named: "neptune") && f.phantomEgg == .mars && f.modelWrites == 0,
                  "missing artwork leaves the overlay and camera alone")
        }
        print("\(checks - failures)/\(checks) phantom session checks passed")
        if failures > 0 { exit(1) }
    }
}
"""#)
