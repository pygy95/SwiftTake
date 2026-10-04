# Panorama composition and export checks

Runs the production composition and export code without launching the app or
connecting to a camera. Checks Save eligibility during Level changes and failed
renders, recovery with Auto, complete publication of all three formats, cleanup
on export failure, and preservation of previous saves. Fixtures use the bundled
demo photograph; generated files live in a unique temporary directory and are
removed after the run.

From the repository root, using the full Xcode toolchain:

```sh
xcrun swiftc -O -parse-as-library Tools/PanoramaHarness/main.swift \
  SwiftTake/PanoramaComposition.swift SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift \
  SwiftTake/PanoramaExport.swift SwiftTake/InteractivePanoramaWriter.swift SwiftTake/FinishedImageLook.swift \
  SwiftTake/QuickTakeDecoder.swift SwiftTake/QTDiagnosticLog.swift \
  SwiftTake/QTVRPanoramaWriter.swift SwiftTake/ImmersivePanoramaWriter.swift \
  -o /tmp/swifttake-panorama-check && /tmp/swifttake-panorama-check
```

The harness exits nonzero on failure. It allows the immersive writer's JPEG
fallback when HEIC encoding is unavailable. It does not test headset playback
or automate the SwiftUI sheet; the actual composition state is exercised.

Browser checks are separate: verify drag, keyboard zoom, Overview, Reset,
phone-width layout, and controls while in full screen. A verified 360° export
must pan across its closing seam and return to the same view after a full turn;
an open arc must stop at its edges. Embedded-image and JavaScript syntax checks
alone do not establish browser compatibility.

The harness also prints time and peak resident memory for a twelve-frame
1600×1200 set. The stitch regression harness verifies the larger-image limits.
Compile it at its repository path: its bundled fixture is located
relative to the source file, so copying `main.swift` elsewhere changes that path.
