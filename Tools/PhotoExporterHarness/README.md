# Photo exporter checks

Run from the repository root with a compatible full Xcode selected:

```sh
./Tools/check.sh
```

The exporter harness uses synthetic images and temporary files. It verifies TIFF
round trips, metadata, sRGB and Display P3 profiles, date-stamp pixels and source
immutability, missing-directory errors, preservation of an existing file after
encoding failure, staging-file cleanup and HDR HEIC output tagged Rec.2100 PQ.
Temporary outputs are removed when the run finishes.

Publication checks use real encoded images, including concurrent same-name
exports and a deterministic pause before publication. Cancellation and connection
generation changes must preserve a newer image, while a current Replace may
publish. These tests call the same async helper as the manager; removing its
publication guard causes the cancellation regression to fail.

The HDR check reports a skip
only if HEIC encoding or a float input context is unavailable. Once those are
available, encoding and read-back errors fail the check. This verifies export
behavior in isolation; it does not exercise serial transfers or the app UI.
