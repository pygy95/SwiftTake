# Naming & metadata policy checks

Run `./Tools/check.sh` from the repository root to include these 53 checks.
For this harness alone:

```sh
xcrun swiftc -parse-as-library Tools/NamingMetadataHarness/main.swift \
  SwiftTake/NamingMetadataPolicy.swift -o /tmp/swifttake-naming-check && \
  /tmp/swifttake-naming-check
```

`NamingMetadataPolicy` is the pure filename and export-metadata policy split
out of `QuickTakeSerialManager`; the manager keeps thin adapters that pass the
model prefix, custom name, release-date fallback, app version and colour-mode
label explicitly. These checks cover the behaviour the extraction must preserve:

- `stripModeTag` — case-sensitive, trailing-only, stacked-tag removal.
- `importStem` / `baseFilenameStem` — `Prefix_date_NNN` vs `Prefix_NNN`,
  three-digit index padding, and the difference in how the two treat an empty
  custom name (import ignores it; re-import accepts it).
- `fujiDateStem` — date formatting in a supplied time zone, and the
  camera-name / `QuickTake200` fallbacks (JPEG date decoding stays at the
  caller).
- `parseImageDate` / `parseImageDateAsDate` — the year-80 pivot, month/day
  range guards, the 19-byte minimum, Gregorian normalisation, and the
  release-date easter-egg fallback.
- `imageHeaderFromQTK` — the file-offset-14 → header-4 mapping, the 74-byte
  minimum, and `qkt` signature acceptance, exercised on both synthetic buffers
  and the committed `IMAGE03.QTK` fixture.
- `exportMetadataProperties` — the exact TIFF/EXIF/PNG keys and strings, the
  omit-all-date-keys no-date dictionary, and UTC vs numeric-offset stamps.

Time zones are injected explicitly so the date assertions are deterministic;
the manager's adapters use the `.current` default, matching shipped behaviour.
No camera, no `UserDefaults`, no personal Pictures folder.
