# Panorama lifecycle checks

Included in `Tools/check.sh`. The generator extracts the manager's actual start,
decode, retry, dismiss and failure methods into a temporary Swift executable. It omits
access-control modifiers and supplies controlled I/O and minimal presentation
state; the orchestration itself is not rewritten. A changed method signature
that cannot be extracted fails generation.

Checks cover cancellation before a queued job starts, immediate replacement,
late camera/Finder decode callbacks after dismissal, idle/error state, and failure
dismissal. Decode continuations are deliberately released after cancellation to
reproduce callbacks from noninterruptible work. Matching is a stub here; the
pipeline and QuickPan harnesses exercise the real matcher separately.

Controlled decode results also exercise all-finished, all-QTK and mixed-file
branches while settings change during a suspended decode. The checks verify
that the captured look reaches the correct stage and that assisted retry
preserves frames, order, look and spacing. The real pixel transforms and
cancellation of the detached mixed-file pass are checked separately in
`PanoramaPipelineHarness`.

This checks production orchestration, not SwiftUI sheet presentation, camera
transport, or a complete linked instance of QuickTakeSerialManager. All generated
sources and binaries are temporary. No camera or personal files are used.
