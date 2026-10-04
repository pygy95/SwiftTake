# Core reliability checks

Runs 20 checks against the production atomic file writer, camera job owner and
POSIX serial transport. No camera is used; serial traffic stays inside a temporary
pseudo-terminal pair. Temporary files are removed after the run.

```sh
xcrun swiftc -parse-as-library Tools/CoreReliabilityHarness/main.swift \
  SwiftTake/SerialPort.swift SwiftTake/CameraWork.swift SwiftTake/AtomicFileWriter.swift \
  -o /tmp/swifttake-core-check && /tmp/swifttake-core-check
```

Covers failed/successful file replacement and staging cleanup; cancelled queued
jobs and late results; explicit serial line settings; outgoing byte integrity;
partial reads, cancellation, descriptor reuse and write backpressure deadlines.
The expected timeout test logs one `send failed: timedOut` message.

A PTY has no USB adapter, electrical signalling or camera firmware. These tests
do not establish hardware reliability or exercise the complete SwiftUI manager.
