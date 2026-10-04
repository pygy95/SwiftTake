# FileImportPipelineHarness

Run `./Tools/check.sh` with a full Xcode toolchain.

27 checks. Exercises the production file-import loop with injected decode/export callbacks:
ordering, decode/save errors, cancellation at progress boundaries, settings changes
between items, and distinct transfer identities for 300 files.

The Settings UI, manager queue, and destination preflight require app testing.
The settings handoff in the manager was also reviewed in source.
All files are temporary; no camera or personal fixtures are used.
