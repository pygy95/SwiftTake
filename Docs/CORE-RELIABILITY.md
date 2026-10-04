# Core reliability

## File safety

Photo exports encode to staged files and publish atomically after successful
finalization. Failed replacement retains the existing file. Exclusive publication
protects files created after a duplicate check. QTK archive storage reuses
identical bytes and chooses another name for different or unreadable contents.
Only naming collisions retry; other errors are reported.

Encoding runs off the main actor. Cancellation and job ownership are checked
immediately before publication. Independent folder bookmarks cover photos,
originals and panoramas, with balanced security-scoped access and explicit
fallback behavior.

## Session and job ownership

Camera imports and file conversions have separate transfer state. Camera work
belongs to a connection generation; cancelled or obsolete progress, thumbnails,
decodes and exports cannot update a newer camera session. Reconnection waits
for teardown. Slot-based caches and saved-file associations are invalidated
when slots can be reused, including after erase; saved files remain intact.

Whole serial exchanges retain transaction ownership across suspension points.
Reads and writes are bounded. See [serial reliability](QT150-RELIABILITY.md).

## Demo and effect isolation

Disconnect ends a simulated session. Hardware disconnection retains original
JPEGs for the offline gallery; a new session resets them before slot reuse.

Copland development owns a cancellable task and checks photo-session identity
after suspension. Failed imports cannot produce framed exports. Re-import and
panorama sourcing distinguish originals from generated framed artifacts.

Planet-name QTK drops change their visual overlay without changing a connected
camera's model, session behavior, saved preference or existing error.

## Validation

`Tools/check.sh` exercises production helpers, extracted orchestration methods,
scripted serial replies, temporary files and a pseudo-terminal. Checks cover
cancel/restart ownership, late callbacks, duplicate saves, failed publication,
archive preservation and effect isolation. The test entry points and limits are
listed in [Tools](../Tools/README.md).

These checks do not replace end-to-end UI, real sandbox or physical-camera
acceptance. See [camera acceptance](CAMERA-ACCEPTANCE.md) and
[panorama reliability](PANORAMA-RELIABILITY.md).
