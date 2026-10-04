# QuickPan checks

Run from the repository root with `bash Tools/check.sh`, or compile just this
harness:

```sh
xcrun swiftc -O -parse-as-library Tools/QuickPanHarness/main.swift \
  SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift \
  SwiftTake/PanoramaQuickPanMatcher.swift -o /tmp/swifttake-quickpan-checks && \
  /tmp/swifttake-quickpan-checks
```

The fixture generator renders known 22.5° camera views from the bundled demo
scene, including a blank overlap. Checks cover standard and wider lens geometry,
reverse and explicit ordering, estimated-join provenance, measured closure,
partial and unverified closure, skipped/repeated/uneven/misordered frames, invalid
calibration input, cancellation, and the unchanged image-only rejection path.
No camera or private photo collection is required.
