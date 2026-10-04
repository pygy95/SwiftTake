# Panorama reliability

The UI uses the shared composer with automatic alignment and optional per-photo
adjustments. The stitcher accepts
photos in capture order, detects forward/reverse direction, and validates every
join. Finder's ordering sheet allows manual arrangement; automatic mode does
not solve arbitrary permutations. Both manual and automatic sequences must pass
the same confidence and search-boundary checks.

## Behavior

- Preserve individual horizontal and vertical pair offsets during assembly and
  use those positions when comparing exposure in overlaps. Level adds a
  correction to the measured path.
- Image-only matching requires correlation of at least 0.60 for every join. Validate closing overlap
  more strictly, check vertical closure, blend the duplicate tail into the start,
  and crop a closed panorama to exactly one measured circumference. Level uses
  a periodic correction for a closed panorama.
- Scale the coarse search's minimum overlap to its downsampled resolution.
- Apply enhancement once after stitching raw QTK frames, for both Finder and
  camera-gallery input. Reject an incomplete source set instead of silently
  omitting unreadable photos or associating the remaining frames with wrong slots.
- A Finder panorama's sources can be raw `.qtk` archives, already-finished
  images (earlier exports or camera JPEGs copied in), or a mix. The current
  Look is snapshotted before decoding and threaded through retries and saves.
  An all-finished set is left exactly as decoded — a second NewTake/HDR pass
  no longer double-processes it. A mixed set bakes the snapshotted look into
  only the raw frames before matching, off the main actor and cancellable,
  then blends with a neutral look; an all-raw set is unchanged (one pass after
  blending). The mixed case cannot get the single gain-compensated pass a
  uniform set gets without touching an already-finished source — a documented
  tradeoff, not a general regression. Camera-gallery input is unaffected: it
  has no pre-rendered export to protect, so it keeps applying the snapshotted
  look once after blending.
- Camera-gallery QT200 and finished-image demo panoramas decode original JPEG
  bytes without the display Look, then apply NewTake/HDR once to the blended
  strip. Processed photo exports are not reused as original sources. Raw session
  caches avoid repeat transfers and remain available with the offline gallery.
- Block Save until the requested Level adjustment has rendered. Debounce slider
  events and forward cancellation to obsolete rendering work.
- Export on a background task. Stage PNG, interactive HTML and immersive output together,
  publish only after all encoders succeed, and retain the composition on failure.
  Distinct filenames prevent repeated saves from overwriting one another.
- Acquire the saved destination scope when reopening panorama/source images.
  Preview loading runs once per file and ignores results after cancellation.

## Software validation

`Tools/check.sh` runs the pipeline, composition, geometry sweep, fixed-order and
360-degree closure regressions, QTVR writer round trips, and immersive metadata
checks. Source-scope tests exercise the production adapter with a recording fake;
they do not claim to exercise App Sandbox entitlements.

Cancellation is forwarded into stitching and export. The export test cancels
after the real PNG, interactive HTML and immersive encoders finish staging and verifies that
nothing is published, temporary files are removed, and existing files survive.
Preview loads belong to the view's task and reject cancelled results. A stale
save completion cannot overwrite a newer panorama's status or error.

QTVR checks cover invalid angles, window and tile dimensions, JPEG quality,
partial arcs, boundary values, and oversized sample-table counts. Immersive
failure tests preserve existing destinations. Playback on period QuickTime and
headsets remains a separate compatibility check.

Commands: [stitch harness](../Tools/StitchHarness/README.md),
[composition/export harness](../Tools/PanoramaHarness/README.md),
[QTVR harness](../Tools/QTVRHarness/README.md),
[immersive harness](../Tools/ImmersiveHarness/README.md).

## Resource limits

A panorama accepts at most 32 frames, at most 1600 pixels on either side of each
frame, and at most 24 megapixels across the set. These checks run before the
float-plane allocations; oversized inputs receive a message instead of silent
resampling. Finder input checks image dimensions before rasterization and reads
at most two files concurrently, holding file access while reading.

The combined harness measured about 2 GB peak resident memory and 39 seconds
for the twelve-frame 1600×1200 case on the development Mac. The process peak
includes preceding checks. Timings depend on the host and image content; the
harness prints fresh measurements.
Normal QuickTake-sized input retains its full resolution and existing rendering.

## Remaining limits

The stitcher combines translation/stretch alignment with bounded cylindrical
and feature-based recovery, not general projective reconstruction. Large parallax,
moving subjects, ambiguous repeated textures, lens distortion and widely differing
exposures still need real-world testing. Conservative confidence checks can reject
usable but difficult photos; passing them does not prove a stitch is correct.

Open-arc angular metadata still uses the legacy 22.5° QuickPan-step estimate.
An unknown handheld sequence has no measured absolute angle. The estimate is
capped below 360° so it cannot independently enable wraparound. Correct headset
projection and playback need actual device testing; metadata checks alone do not
establish compatibility. The existing 8-bit stitching path does not preserve
original HDR headroom.

Modern saves include a self-contained HTML panorama with drag, keyboard, zoom,
and full-image controls. The embedded viewer uses WebGL 2 without network access
and falls back to the image if graphics are unavailable. PNG remains the Preview
format. QTVR is a legacy format; its writer and regression harness remain for
compatibility work, but normal Save no longer produces a MOV.
The viewer keeps its compact toolbar below the photo inside the full-screen surface, adapts
to phone-width windows, and uses repeating texture sampling only for verified
360° coverage. Browser interaction checks remain separate from export checks.

Explore is also available inside the composer and saved-panorama preview.
Both use the same renderer as the export, hosted in a nonpersistent WebKit view
with an inline image and no file-folder access. Overview remains available;
Adjust Photos returns the composer to Overview while the new strip renders.
The saved record retains the same angular coverage as its exports. WebKit needs
the outgoing-network sandbox entitlement to launch even for in-memory HTML;
the generated document's content policy blocks network requests, and the host
blocks navigation away from its blank document. No server is used.

If translation matching fails, the stitcher tries three shared cylindrical
projections and retains the strongest sequence whose every join passes the same
confidence and search-boundary checks. Existing successful matches are unchanged.
Projection crops to valid pixels and checks cancellation during resampling and
between pair searches. Its fitted focal ratio is not a calibrated lens profile;
this remains a limited panorama solver, without general perspective or radial
lens-distortion correction.

## Fixed-stop tripod assistance

When image-only matching cannot establish the sequence, an explicit assisted
retry can use the tripod spacing. Supported stops per revolution are 6–32,
with 12, 14, 16, 18 and 20-stop presets. An 18-stop ring represents 20° steps;
16 stops represents 22.5°. This assumes consecutive detents without skipped
positions. The selected spacing persists through retries of that source set.

Estimated joins are identified. Frame count and declared spacing alone never
force a full rotation: the closing join still needs independent image evidence.
QT200 uses the same stitching path with original JPEG sources, but real
QT200/KiWi+ acceptance remains separate from software geometry checks.

## Interaction

Overview and Explore share the presentation and gesture controls. Overview
supports an anchored pinch, Fit/Fill controls and an accessible zoom slider.
Explore supports horizontal trackpad movement, pinch or vertical-wheel zoom,
keyboard movement, reset and zoom controls in the embedded and exported viewer.

Adjust Photos shows a source selector and highlights the selected region in the
panorama. Selection can be made in the image or thumbnail strip; arrow keys
change the selected photo. Horizontal and vertical nudges update the preview,
with reset available per photo or for all photos. Reduce Motion suppresses
animated transitions, and Classic uses its own themed controls.

## Fixture coverage

The portable stitch checks use bundled demonstration images and generated
geometry. An optional private four-frame reverse-order WideTake sequence has
an enhanced-TIFF baseline of `slope=4 strip=1017x629`; its raw-QTK path produces
`slope=3 strip=1018x630`. These differ because the TIFF inputs are already
processed. The baseline records measured per-pair positions rather than rounding
an averaged step. Private images are not bundled with the repository.

Real QT150 feedback has confirmed assisted stitching, smooth interaction and
QTK drag-and-drop panorama creation. This does not imply every difficult scene
will match, nor does it establish QT200/KiWi+ hardware compatibility. Inspect
rendered seams and full-circle closure as well as numerical test output.
