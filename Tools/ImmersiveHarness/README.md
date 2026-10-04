# Immersive panorama harness

Checks `ImmersivePanoramaWriter` geometry, metadata and horizon placement
against independently calculated values. Uses synthetic strips; no camera
or personal photos are needed.

From this directory:

```sh
xcrun swiftc -O main.swift ../../SwiftTake/ImmersivePanoramaWriter.swift \
  -o /tmp/swifttake-immersive-check && /tmp/swifttake-immersive-check
```

It exits with failure if a check fails and prints `ALL PASSED` on success.
Outputs are `immersive_360.heic`, `immersive_67.heic` and `immersive_180.heic`
in the system temporary directory, overwriting previous files of those names.
If HEIC encoding is unavailable the writer returns a `.jpg` fallback; the
harness verifies that returned file, including its panorama metadata.
These checks validate the writer, not playback in every viewer.
