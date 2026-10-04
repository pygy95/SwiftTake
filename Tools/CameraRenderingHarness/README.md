# Camera rendering harness

Behavioural checks for the decode/render helpers extracted from
`QuickTakeSerialManager`:

- `QuickTakeThumbnailRenderer` — the QT100 / QT150 camera-side 80×60
  grayscale thumbnail decoders (synthetic-nibble behaviour, the model gate,
  and the exact-length gate that rejects short / truncated / oversize input).
- `CameraImageRenderer` — `render` branch selection (demo finished-JPEG vs
  QTK Bayer vs Fuji JPEG) and `applyFinishedLook` (nil / no-op / rendered).
- `FujiQualityClassifier` — the Fine/Normal bits-per-pixel threshold.
- `QuickTake200JPEGDecoder` metadata (EXIF capture date, geometry).

No camera or personal photos are required. Inputs are synthetic buffers,
ImageIO-encoded JPEGs and the committed `IMAGE03.QTK`. Run with a full Xcode
toolchain. All 51 checks passed, including exact QT150 thumbnail positions and
Vintage/NewTake pixel equality with the unchanged direct QTK decoder.

## Build and run

From the repository root:

```sh
xcrun swiftc -parse-as-library \
  Tools/CameraRenderingHarness/main.swift \
  SwiftTake/CameraImageRenderer.swift \
  SwiftTake/QuickTakeThumbnailRenderer.swift \
  SwiftTake/FujiQualityClassifier.swift \
  SwiftTake/QuickTakeDecoder.swift \
  SwiftTake/FinishedImageLook.swift \
  SwiftTake/QTDiagnosticLog.swift \
  SwiftTake/QuickTake200JPEGDecoder.swift \
  SwiftTake/QTKFormatter.swift \
  -o /tmp/swifttake-camera-rendering-check && \
  /tmp/swifttake-camera-rendering-check
```

The executable exits non-zero on the first failed assertion (via
`precondition`) and otherwise prints one `PASS:` line per check followed by a
summary count.
