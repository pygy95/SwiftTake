# Panorama pipeline checks

Runs `SwiftTake/PanoramaPipeline.swift` — the state-independent panorama
work split out of `QuickTakeSerialManager` — without launching the app or
connecting to a camera. Covers file read, decode and slot ordering; the
rejection of unreadable, corrupt and non-image entries so a short set is
detectable; cancellation of the file decode; the match/blend under a
forwarded cancel, its progress callbacks, and a prompt unwind when the
work is pre-cancelled; the open-arc sweep estimate; cancellation before export and after all formats are staged; oversized input
rejection; and
the `DestinationScope` adapter (`ReimportSourceResolver.swift`) behind the
panorama/source security-scoped disk reads, against a recording fake. This
command-line harness checks the begin/end contract without exercising actual
App Sandbox permissions.

It also covers `decodeFinderFrames`'s QTK-vs-already-finished classification
and `applyingLook`, the detached, cancellable pass that bakes a captured Look
into just the raw-archive frames of a mixed Finder set — the fix for
double-processing an already-rendered PNG/JPEG/HEIC a second time. Checks an
all-archive set, an all-finished set, and a mixed set; that `applyingLook`
never touches a slot outside `qtkSlots`, that a neutral look and an empty
`qtkSlots` are true no-ops, that a baked frame matches `FinishedImageLook.render`
called directly, and that cancelling mid-bake surfaces `CancellationError`
rather than a result. QTK fixtures are synthesized in-process (same tiny
header-plus-noise generator `Tools/DecoderHarness` uses), no personal photos.

Fixtures are deterministic: solid-colour PNGs generated in a unique
temporary directory, plus crops of the committed `SwiftTake/DemoPanSource.jpg`
that the other panorama harnesses already use. Generated files are removed
after the run.

From the repository root, using the full Xcode toolchain:

```sh
xcrun swiftc -O -parse-as-library Tools/PanoramaPipelineHarness/main.swift \
  SwiftTake/PanoramaPipeline.swift SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift \
  SwiftTake/PanoramaExport.swift SwiftTake/InteractivePanoramaWriter.swift SwiftTake/PanoramaComposition.swift \
  SwiftTake/FinishedImageLook.swift SwiftTake/QuickTakeDecoder.swift \
  SwiftTake/QTDiagnosticLog.swift SwiftTake/QTVRPanoramaWriter.swift \
  SwiftTake/ImmersivePanoramaWriter.swift SwiftTake/ReimportSourceResolver.swift \
  -o /tmp/swifttake-panorama-pipeline-check && /tmp/swifttake-panorama-pipeline-check
```

The harness exits nonzero on failure. It allows the immersive writer's
JPEG fallback when HEIC encoding is unavailable. It does not automate the
SwiftUI composer or the camera-frame fetch, which stay in the manager.
