# QT150 and QT200 acceptance checks

Run the current project from Xcode. Test one camera at a time with the same
Connect button. Start with a few expendable test photos and a fresh destination
folder. These checks do not require erasing a camera or changing its settings.

## Recorded user results — October 2, 2026

Hardware feedback confirmed that the corrected QT150 erase flow works and a
successful QuickPan-assisted panorama and smooth viewer interaction. These are user-reported hardware/flow
passes, not an independently recorded run of every check below. QT200/Kiwi panorama
verification remains open.

## Both cameras

1. Connect with the camera powered on. Expect correct model identification,
   photo count, and thumbnails. Disconnect and reconnect without restarting
   SwiftTake; expect the gallery to return normally.
2. Import one photo, then two selected photos. Open the actual saved files in
   Preview. Expect complete images, appropriate filenames, and a finished
   progress indicator. Check the saved dimensions and capture date if available.
   During a longer import, queue one more photo; expect it to join the same batch
   and import once.
3. Import an already imported selection. If a duplicate prompt appears, test
   Skip, Keep Both, and Replace separately using the disposable destination.
   Skip must retain existing files; Keep Both must retain both copies with unique
   names. Stop must stop without reporting success for unprocessed photos — if
   photos had already imported, the notification must read "Import Stopped"
   with the count, never "Import Complete".
4. Disconnect/reconnect and import again. Previously saved photos should still
   be recognized. On QT200, verify that DSC identity and capture-date filenames
   do not cause different photos to be mistaken for the same import.
5. With a disposable photo, interrupt an active transfer by unplugging the cable.
   Try both timings if practical: during a photo's data transfer, and between
   photos (while the next header is being read) — the feedback below must be
   the same either way. Expect a recoverable interruption, no false complete
   image, and no endless busy state. The feedback must be the connection-lost alert — not the polite
   power-off reminder — with status "Import Interrupted", and if photos had
   already imported, a notification "Imported N photos before the camera
   disconnected" with the correct count. Exactly one banner, including while
   the 10-second connection monitor is running. Reconnect and retry;
   previously saved files must remain intact. A user-chosen Disconnect during
   idle must still show the power-off reminder, not the fault alert.
6. During a multi-photo import, change the export format or colour mode in
   Settings while a photo is transferring. Expect the in-flight photo to save
   with the settings it started with (filename, extension and mode agree with
   any duplicate prompt already answered), and the next photo in the batch to
   pick up the change. No existing file may be silently overwritten in a
   different format than the prompt named.

## QT150 originals and file import

- Enable Keep Original Files and choose a separate originals folder. Import a
  photo and verify that a readable rendered file and a nonempty QTK archive exist.
- Disconnect, change colour mode, and re-import the saved photo. Expect it to
  use the archive without requesting the camera. Preserve both colour outputs
  and the original archive.
- Drop a copied QTK into the app twice. Expect two uniquely named outputs and
  an unchanged source. Try a deliberately corrupt copy: expect a read/decode
  failure, not a successful import or a stuck progress bar. For a QT150
  archive with required payload bits removed, expect a decode failure. Both
  QT100 and QT150 decoders detect missing required bits; removing unused trailing
  padding alone need not fail. Complete legacy archives without dimensions retain
  compatibility, so header checks alone cannot prove their validity.
- If using the Copland Easter egg, save its image and re-import normally. Expect
  the new image to open and original QTK files to survive. A photo merely named
  with the word "copland" must not be mistaken for a generated artifact.

## QT200 diagnostics

- Note the camera's clock (Settings > Camera, or a fresh photo's capture
  time), run Camera > Capture Camera Diagnostics…, then check the clock
  again: it must be unchanged — routine diagnostics only read it. After the
  capture, a photo import must run at the same speed as before it.

## Panoramas

- Start a stitch and cancel while it is blending: expect a quiet return to
  the gallery with no "could not be rendered" message and no composer sheet
  reappearing. The composer's Save button stays disabled until the preview
  has finished rendering.

## QT200 Copland and panorama sourcing

- Copland-develop one QT200 photo, then use it in a panorama stitch or
  re-import. Expect the real finished render (from the session cache or the
  camera) or a clean "no source available" — never the Mac OS 9 framed
  Copland PNG stitched or re-imported as if it were the photo.

## What to report

For a failure, include camera model, step, exact status/error text, whether the
camera was still connected, and which files appeared. Include a diagnostic
report when a connection or transfer fails. If an image looks wrong, retain its
original and exported copy for comparison. A passing software harness is not a
replacement for these checks. Panorama testing can remain a separate session.
