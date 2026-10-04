# Decoder regression harness

Checks QTK decoding and finished-image rendering with pixel hashes and rendering
invariants. It is separate from the app target and requires no camera.

## Build and run

From this directory, using a compatible macOS Swift toolchain:

```sh
xcrun swiftc -O main.swift stub.swift \
  ../../SwiftTake/QuickTakeDecoder.swift \
  ../../SwiftTake/FinishedImageLook.swift \
  ../../SwiftTake/QTDiagnosticLog.swift -o /tmp/swifttake-decoder-check && \
  /tmp/swifttake-decoder-check > /tmp/swifttake-decoder-output.txt
```

The default run uses the repository's `IMAGE03.QTK` and eight deterministic
synthetic inputs. It checks 27 malformed headers/signatures and produces 63
hash/invariant rows. Six optional historical fixtures are explicitly reported
as skipped; they account for the remaining 36 rows of the 99-row baseline.

The executable exits nonzero for invalid arguments, broken supplied images,
failed rendering invariants, or missing required inputs. **It does not compare
pixel hashes with the saved baseline automatically.** Use the comparison below
before concluding that rendering is unchanged.

## Fixture options

| Option | Meaning |
|---|---|
| `--fixture PATH` | Add a QTK file; repeatable. |
| `--fixtures-dir DIR` | Add QTK files directly inside a directory. |
| `--finished PATH` | Add a finished image; repeatable. |
| `--finished-dir DIR` | Add TIFF, JPEG and PNG files directly inside a directory. |
| `--strict` / `--require-fixtures` | Fail unless all six historical fixtures are supplied, and fail on other missing requested inputs. |
| `--dump DIR` | Save raw decoded pixels for examining deliberate rendering changes. |

The required repository sample is resolved from the repository root or this
directory. When running elsewhere, set `SWIFTTAKE_IMAGE03_PATH` explicitly.
An invalid explicit override fails; it does not fall back to another file.

Full baseline coverage needs `neptune.qtk`, `venus.qtk`, `mars.qtk`, and the three
QT200 TIFFs named below. Supply their actual locations; do not substitute other
photos or copy personal fixture collections into the repository.

```sh
fixture_dir="/path/to/qtk-fixtures"
finished_dir="/path/to/qt200-fixtures"
/tmp/swifttake-decoder-check --strict \
  --fixture "$fixture_dir/neptune.qtk" \
  --fixture "$fixture_dir/venus.qtk" \
  --fixture "$fixture_dir/mars.qtk" \
  --finished "$finished_dir/QuickTake200_19960509_141432.tiff" \
  --finished "$finished_dir/QuickTake200_19960509_151444.tiff" \
  --finished "$finished_dir/QuickTake200_19960509_152224.tiff" \
  > /tmp/swifttake-decoder-output.txt && \
  python3 compare.py /tmp/swifttake-decoder-output.txt
```

## Baseline comparison

`compare.py` fails on missing, unexpected, duplicate or changed rows, broken
inputs, and empty output. It ignores timing differences and does not modify the
baseline. To compare a deliberately partial portable run:

```sh
python3 compare.py /tmp/swifttake-decoder-output.txt --allow-partial
```

This reports `PARTIAL: 63/99` when the optional fixtures are absent. That result
is not complete baseline coverage. Actual missing-input errors still fail.
Extra fixtures can be rendered, but have no approved baseline until reviewed;
the default comparison rejects their unexpected rows.

The September 9 cleanup matched all 99 historical rows and all 27 malformed
header checks. The synthetic cases cover QT100/QT150 HQ, SQ and offset-738
headers; they do not replace real QT100 sensor samples or hardware testing.

Integrity checks cover malformed RADC dimensions, both predictor families, Huffman codes shorter than
the EOF lookup window, native QT150 payloads shortened to 90%, 50% and 10%,
and reconstructed archives missing even one declared payload byte. Supplied
archives with mirrored length fields also receive shortening checks before
their pixel hashes are calculated. Complete legacy archives with missing
dimensions retain their historical rendering; the declared length protects
against shortening, but cannot establish that their original content is valid.
Do not use a QT150 payload relabelled `qktk` as a valid QT100 fixture.

## Deliberate rendering changes

Use `--dump` with separate before/after directories to inspect pixel changes.
A differing hash only establishes that the pixels changed. Update a baseline
only after explaining and visually verifying an intentional rendering change.
