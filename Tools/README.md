# Development tools

Run `./Tools/check.sh` for the self-contained core, serial, trace,
naming/metadata, photo export, import storage, camera rendering, panorama,
file-import, batch-policy and re-import checks, plus the fixture-free stitch,
QTVR writer and immersive modes. It uses temporary build products and requires
no camera or personal fixtures. See the [development guide](../Docs/DEVELOPMENT.md)
for Xcode setup.

These standalone tools are outside the Xcode app target. Run build commands
from each tool's directory unless its guide says otherwise. Only execute a
binary after its compilation succeeds; a stale binary is not validation.

| Tool | Purpose | Inputs |
|---|---|---|
| [SerialHarness](SerialHarness/README.md) | Kodak/Fuji framing, replies and transaction ordering | Scripted transport; no camera needed. |
| [CoreReliabilityHarness](CoreReliabilityHarness/README.md) | Atomic saves, job cancellation and bounded serial I/O | Temporary files and a pseudo-terminal; no camera needed. |
| [CoplandDemoHarness](CoplandDemoHarness/README.md) | Demo disconnect, effect cancellation and original-source routing | Extracted production methods, controlled I/O and real compositing helpers. |
| [PhantomSessionHarness](PhantomSessionHarness/generate.swift) | Planet Easter eggs preserve camera model, errors and session state | Extracted production methods with controlled AppKit artwork and session fixtures; no hardware or user settings. |
| [TraceHarness](TraceHarness/README.md) | Trace persistence, retries and write failures | Temporary directories and a controlled writer; no camera needed. |
| [NamingMetadataHarness](NamingMetadataHarness/README.md) | Filename-stem and export-metadata policy edge cases | Fixed inputs plus the committed `IMAGE03.QTK`; no camera needed. |
| [PhotoExporterHarness](PhotoExporterHarness/README.md) | Image export, colour profiles, metadata, date stamps and write failures | Synthetic images and temporary files; no camera needed. |
| [ImportStorageHarness](ImportStorageHarness/README.md) | Bookmark persistence, destination fallback, Fuji import records and QTK archive saves | Isolated preferences and temporary files. |
| [CameraRenderingHarness](CameraRenderingHarness/README.md) | Kodak thumbnail layouts and camera image rendering | Synthetic images and the committed QTK sample. |
| [PanoramaPipelineHarness](PanoramaPipelineHarness/README.md) | File order, decoding, cancellation, matching and export dispatch | Synthetic images and bundled panorama source. |
| [PanoramaLifecycleHarness](PanoramaLifecycleHarness/README.md) | Cancel/restart ownership and late progress rejection in manager methods | Extracted production orchestration with controlled decode callbacks; no camera or SwiftUI runtime. |
| [FileImportPipelineHarness](FileImportPipelineHarness/README.md) | File-import stages, cancellation, outcomes and identity | Injected callbacks and temporary files. |
| [CameraBatchImportHarness](CameraBatchImportHarness/README.md) | Camera batch sequencing, retries and stale-result rejection | Simulated camera callbacks and temporary files. |
| [BatchImportPolicyHarness](BatchImportPolicyHarness/README.md) | Duplicate choices and archive collision safety | Real temporary files, including concurrent saves. |
| [ReimportSourceHarness](ReimportSourceHarness/README.md) | Source precedence, stale results and Copland retirement | Injected fetches and temporary files. |
| [DecoderHarness](DecoderHarness/README.md) | Pixel hashes and rendering-combination checks | Repository QTK sample and synthetic data by default; real hardware-captured QTKs and finished images are optional, CLI-supplied — no absolute personal-machine paths. |
| [StitchHarness](StitchHarness/README.md) | Stitch geometry and optional rendered strip | Demo, sweep and regression modes use repository/generated fixtures; the personal-photo baseline is optional. |
| [PanoramaHarness](PanoramaHarness/README.md) | Composer state and export failure/retry checks | Bundled demo photo; temporary outputs are removed. |
| [QuickPanHarness](QuickPanHarness/README.md) | Known-angle assistance, estimated joins, reverse order and closure safeguards | Views generated from the bundled scene; no personal photos. |
| [PanoramaKeyboardHarness](PanoramaKeyboardHarness/README.md) | Smooth keyboard movement and lifecycle in the generated viewer | JavaScriptCore with a controlled clock and DOM/WebGL doubles; no live GPU check. |
| [QTVRHarness](QTVRHarness/README.md) | QTVR parsing and writer round trips | `--writer-checks` needs no external corpus; the optional corpus guide describes extraction. |
| [ImmersiveHarness](ImmersiveHarness/README.md) | Independently calculated geometry and metadata checks | Synthetic strips; writes HEIC files in the temporary directory. |
| `identify-qt100-vs-150.py` | Compares two saved device-info reports | Report paths supplied as arguments; differences are candidates, not proven model identifiers. |

The serial harness checks host-side logic, including limited QT200 command
cases. It does not validate a physical adapter or the full QT200 protocol.
Camera simulation helps with UI work but does not validate real serial framing,
timing or recovery.
See the [serial reliability notes](../Docs/QT150-RELIABILITY.md).
