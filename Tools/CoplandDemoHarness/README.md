# Copland demo regression checks

Included in `Tools/check.sh`. Extracts the production re-import entry point,
demo preview decoder and Copland compositor into an isolated AppKit executable.
The surrounding session and export destination are fixtures; no camera or user
photos are accessed.

Checks QT100/150 demo routing bypasses raw QTK reconstruction, QT200 remains on
its existing import path, busy gates remain enforced, and hardware re-import
routing is unchanged. For each model, bakes the real bundled Copland frame around
a generated JPEG with no intermediate export and a stale cached preview, then
checks that nine interior PNG samples retain the source's solid red content.

This verifies image processing and routing, not the on-screen animation.

The same harness covers the shared demo/hardware Disconnect action, original
JPEG panorama sources from both caches and the camera, stale fetch rejection,
and offline cache retention. Copland's production sequence runs against a
controlled sleep clock: session changes before import, after import and just
before export must abort; cancellation must not reset a replacement effect;
failed transfers must not save. Hardware I/O and export destinations are fixtures.
