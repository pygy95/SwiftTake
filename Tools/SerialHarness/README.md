# QuickTake serial session harness

Runs the production session, command builder and wake scanner against a scripted
transport. It does not open a real port or send commands to a camera. Small
stubs replace UI/model/logging dependencies and diagnostic thumbnail rendering.
Both production camera sessions are compiled.

From the repository root:

```sh
xcrun swiftc -parse-as-library Tools/SerialHarness/main.swift \
  SwiftTake/SerialPort.swift SwiftTake/QuickTakeTransport.swift \
  SwiftTake/QuickTakeCommands.swift SwiftTake/QuickTakeCameraSession.swift \
  SwiftTake/FujiCameraSession.swift SwiftTake/CameraDiagnostics.swift -o /tmp/swifttake-serial-check && \
  /tmp/swifttake-serial-check
```

Checks cover QT100/150 identities and both selected speeds, fragmented and
misaligned wake input, already-awake detection, a silent passive probe,
missing/rejected handshake replies, configuration errors, command rejection,
concurrent liveness/metadata requests, queued cancellation, and exact/final
photo block boundaries. Additional checks cover failed sends, Fuji command/ping
serialization, and avoiding a second shutter command after a lost acknowledgement.
Further checks cover the Fuji reply-frame parser: multi-frame replies with an
escaped ESC byte inside the data, a terminator that is neither escaped-ESC,
ETX nor ETB, a full JPEG's exact/short/long/absurd announced length against
`PIC_SIZE` (a thumbnail's size stays an estimate, never enforced), and the
checksum domain resetting on a fresh open instead of judging a new link
against the previous one's. 83 checks in total, including bounded late-filler handling at the final Kodak speed ACK. Failures
terminate the executable; success prints a counted `ALL … CHECKS PASSED` line.

This does not test the physical adapter, POSIX read/write behaviour or the
manager's complete automatic-detection/lifecycle flow. Connect still uses the
unchanged Kodak-first/Fuji-second path; bench-test the real models before
claiming hardware verification. See the [research notes](../../Research/QT150-serial-review.md).
