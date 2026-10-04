# Development guide

This guide describes the application architecture and reproducible checks.

## Architecture

| Component | Responsibility |
|---|---|
| `SwiftTakeApp` | Creates one shared manager and supplies it to the app's scenes. |
| Views, `AppTheme`, overlays | Presentation, gallery interaction, themes and easter eggs. |
| `QuickTakeSerialManager` | Connections, camera state, imports, previews, exports and panorama coordination. |
| `CameraImageRenderer` / `QuickTakeThumbnailRenderer` / `FujiQualityClassifier` | Camera image decoding, Kodak thumbnail layout and Fuji JPEG quality classification. |
| `PhotoTransfer` / `SerialImportPreferences` | Transfer state, observable progress and serial/import preference options. |
| `DestinationBookmarkStore` | Independent photo, panorama and QTK folder bookmarks, destination fallback and legacy preference migration. Folder choices are grouped under General → Save Locations. |
| `QTKArchiveStore` | Security-scoped archive reuse and exclusive publication that preserves existing originals. |
| `FujiImportLedger` | Persistent QT200 import paths and camera-reported sizes. |
| `PanoramaPipeline` | File/archive decoding, cancellable matching and panorama export dispatch. |
| `FileImportPipeline` | Dropped-file decode/export sequencing, progress and cancellation outcomes. |
| `CameraBatchImportEngine` | Camera import sequencing, bounded retries, dynamic queues and save outcomes through explicit adapters. |
| `BatchImportPolicy` | Duplicate choices, archive stems and camera-batch completion summaries. |
| `ReimportSourceResolver` | Disk → cache → camera source precedence with stale-result rejection. |
| `CoplandArtifactPolicy` / `ReimportPostExportDecision` | Artifact classification and saved-file changes after successful export. |
| `PhotoExporter` | Date-stamp drawing, colour conversion, background encoding and guarded publication. |
| `NamingMetadataPolicy` | Filename and export-metadata rules with explicit inputs from the manager. |
| `CameraWork` | Camera task cancellation and connection generations. |
| `QuickTakeCameraSession` / `QuickTakeCommands` | QT100/150 protocol choreography and command bytes. |
| `FujiCameraSession` | QT200 / Fuji-family protocol and recovery. |
| `SerialPortFinder` / `SerialPort` | Adapter discovery and bounded POSIX serial transport. |
| `QTKFormatter` / `QTKDecoder` | QTK reconstruction and raw image decoding. |
| `FinishedImageLook` / JPEG helpers | Rendering finished images from Fuji-family cameras. |
| `AtomicFileWriter` | Atomic exclusive or replacement publication of staged files. |
| Panorama components | Image-based and opt-in QuickPan alignment, composition, embedded exploration, PNG/HTML/immersive export; retained legacy QTVR writer. |

The UI uses Combine's `@Published` / `ObservableObject`, plus Observation for
selected state. Async work uses Swift concurrency. The project sets default
actor isolation to MainActor but uses Swift 5 language mode. Both camera sessions
hold a transaction gate across complete async exchanges; actor isolation alone
would not prevent commands interleaving at suspension points.

## Build

From the repository root, with a compatible full Xcode selected:

```sh
xcodebuild -project SwiftTake.xcodeproj -scheme SwiftTake \
  -configuration Debug -derivedDataPath /tmp/SwiftTake-Development \
  CODE_SIGNING_ALLOWED=NO build
```

This is an unsigned validation build, not a distribution archive. Use Xcode's
normal signing configuration for running with production entitlements or
shipping. The project contains no development-team identifier. The public
bundle identifier is `org.swifttake.SwiftTake`; builds using an older private
identifier have separate preferences and sandbox storage. Do not rename or move
those containers to migrate data; choose the existing export folders in Settings.

If the shell selects Command Line Tools, set `DEVELOPER_DIR` to the
installed Xcode's `Contents/Developer` directory for the command. Do not change
project settings to compensate for selecting the wrong toolchain.

The app requires macOS 27 or later on Apple silicon (M-series Macs). Both Debug
and Release explicitly build only `arm64`; Intel builds are not supported. Xcode
generates the minimum-system metadata from the deployment target.
The shared scheme's Run action uses Release; Test and Analyze use Debug. There is no dedicated XCTest target.

## Software validation

Run `./Tools/check.sh` from any directory with a compatible full Xcode selected.
It uses temporary outputs and repository fixtures, and stops on failure. The
harnesses cover serial transactions, cancellation, atomic publication, imports,
bookmarks, naming, rendering, panorama geometry and writer metadata. Decoder
pixel baselines are a separate run; see [Tools](../Tools/README.md).

The portable decoder corpus covers 63 of 99 historical baseline rows. Supply
the documented external fixtures for complete coverage. Missing optional inputs
are reported explicitly; never substitute images or regenerate a baseline to
make a comparison pass.

## Current reliability behavior

- Each camera operation belongs to a connection generation. Obsolete results
  cannot update a newer connection. Camera and dropped-file transfers have
  separate ownership and progress.
- Imports snapshot settings for each photo. QT200/Fuji duplicate decisions use
  the final EXIF-derived filename; Skip, Replace, Keep Both and Stop share the
  same policy as QT100/150, including choices applied to the rest of a batch.
- Photo encoding runs off-main. `PhotoExporter.exportOffMain` checks cancellation
  and the owning job on the main actor immediately before atomic publication.
  Exclusive publication protects a file created after the duplicate check;
  replacement requires the caller's explicit duplicate decision. Production-path
  tests pause a real encode and verify that cancellation or a newer generation
  preserves a newer file and removes the old stage.
- QT100 and QT150 decoding rejects missing required payload bits. Huffman
  look-ahead accepts a shorter complete code at EOF. Recognizable SwiftTake
  archive headers also check the declared payload length. Complete legacy QT150
  archives with missing dimensions retain their previous rendering; their length
  fields cannot prove the original content is valid. Malformed RADC dimensions
  are rejected before decompression.
- Saved-folder bookmarks survive transient resolution failures. Source readers
  balance security-scope access; tests exercise the production adapter with a
  recording scope, rather than claiming a real sandbox entitlement test.
- Fuji diagnostics read the clock without setting it, bound the quality survey,
  and restore the negotiated speed. Serial command bytes and connection timing
  remain unchanged.
- Panorama matching validates every join and full-circle closure. Rendering,
  preview loads and export respect cancellation; multi-format exports stage
  before publication and clean up failed or cancelled work. See the
  [panorama notes](PANORAMA-RELIABILITY.md) for geometry and resource limits.
- Tripod-spacing assistance is an explicit retry for consecutive detents at a
  declared stops-per-revolution (6...32; presets for the 12/14/16/18/20-stop
  QuickPan/KiWi+ discs, 16 the default). Degrees are derived as 360/stops; a
  full turn is only accepted when the frame count matches the declared stops
  AND the closing join independently passes the same image evidence as every
  other join — frame count alone never forces closure. A failed assisted
  retry can be corrected and retried again on the same decoded originals; the
  chosen spacing persists across that retry and resets at the next new job.
- A Finder panorama's source files can mix raw `.qtk` archives with
  already-finished images (earlier exports, or camera JPEGs copied in
  directly). The current Look (NewTake/HDR) is captured once before decoding
  and applied once after blending only when every source is raw; an
  all-finished set is left exactly as decoded; a mixed set bakes the captured
  look into just the raw frames before matching (off the main actor,
  cancellable) and blends with a neutral look, since reprocessing an
  already-finished source would double it. The mixed case trades the single
  gain-compensated pass a uniform set gets for not touching a source that was
  already rendered — see `PanoramaPipeline.applyingLook`.
- QT100/150 erase holds the serial transaction while awaiting completion and
  distinguishes rejection from a missing acknowledgement. Metadata is refreshed
  before success is claimed. The corrected erase flow has a reported QT150
  hardware pass; this does not establish QT100 or QT200 hardware behavior.
- Camera Controls starts collapsed in each new window and stays available in
  short windows. Panorama arrow-key movement uses elapsed time and stops on
  focus loss, with easing disabled by Reduce Motion.
- Window-level Reduce Motion disables animated layout and transitions; timed
  effects have separate static variants. Reduce Transparency provides opaque
  text-bearing panels. Keyboard focus, Classic help hints and toast announcements
  are explicit, and the shortcut list follows the current commands. Default
  themes, layout and Easter eggs retain their normal behavior.

## Working boundaries

Preserve the UI, themes and Easter eggs, and one automatic Connect path for
QT100/150 and QT200. All application implementation remains Swift. Use protocol
sources before changing command bytes or timing. Backups, local work notes and
Xcode user settings stay outside the publication snapshot.

Software harnesses and unsigned builds do not establish physical-camera,
VoiceOver, Full Keyboard Access, sandbox entitlement or headset compatibility.
Hardware acceptance is tracked separately and does not block software work.

- [Core reliability](CORE-RELIABILITY.md): save safety, task lifetime and serial I/O.
- [QT150 notes](QT150-RELIABILITY.md): protocol findings and hardware evidence.
- [Panorama reliability](PANORAMA-RELIABILITY.md): geometry, export and limits.
