# SwiftTake

A native Mac companion for Apple QuickTake cameras. Browse and import photos,
keep original archives, develop images with Vintage or NewTake rendering, and
combine overlapping shots into panoramas you can explore and share.

Requires **macOS 27 or later on Apple silicon**. The application is written in
Swift with SwiftUI and AppKit, with no Swift package dependencies.

## Cameras and features

| Camera | Capabilities |
|---|---|
| QuickTake 100 / 150 | Serial browsing and import, QTK decoding, capture, flash, quality, clock, camera name and erase. |
| QuickTake 200 | Serial browsing and JPEG-based import. Remote camera controls and serial erase are not exposed. |
| Fujifilm DS-7 / Samsung Kenox SSC-350N | Fuji-family protocol and model recognition; compatibility requires testing on each model. |

One Connect button detects the camera family. A simulated camera is available
for exploring the interface without hardware. QT100 and QT150 have separate
collections of six and seven HQ photos, respectively, without repeated shots.
The QT200 demo contains three panorama sets credited to Tim Meehan: select
photos **1–6**, **7–11**, or **12–23** for a panorama, rather than combining
the whole library. The simulated model does not identify a sample photo’s
capture camera.

- Export photos to modern formats, with selectable image look and colour profile.
- Keep QTK originals and choose separate folders for photos, originals and panoramas.
- Convert dropped QTK archives, or choose a set for a panorama.
- Build panoramas from camera photos, archived originals or existing image files.
- Adjust individual panorama frames and explore with trackpad, keyboard or zoom controls.
- Save a panorama as PNG and a self-contained interactive HTML file, with immersive HEIC output also available. Open PNG in Preview; open interactive HTML in a browser.

Panorama matching supports either capture direction and optional fixed-stop
tripod assistance. A declared number of stops does not itself prove 360° closure;
the closing overlap must pass image checks. Difficult exposure changes, repeated
textures and parallax can still prevent a reliable match.

## Build

Open `SwiftTake.xcodeproj` in Xcode 27 or later and select the `SwiftTake` scheme.
Set your own signing team for a signed build. The shared scheme runs Release;
choose Debug for development diagnostics.

For an unsigned build and software checks:

```sh
xcodebuild -project SwiftTake.xcodeproj -scheme SwiftTake \
  -configuration Debug -derivedDataPath /tmp/SwiftTake-Build \
  CODE_SIGNING_ALLOWED=NO build
./Tools/check.sh
```

## Project guide

- [Development](Docs/DEVELOPMENT.md): architecture, build settings and validation.
- [Camera checks](Docs/CAMERA-ACCEPTANCE.md): hardware acceptance steps.
- [Serial reliability](Docs/QT150-RELIABILITY.md): connection behavior and test limits.
- [Panoramas](Docs/PANORAMA-RELIABILITY.md): matching, editing, export and limits.
- [Core reliability](Docs/CORE-RELIABILITY.md): cancellation, file safety and session ownership.
- [Tools](Tools/README.md): standalone checks and optional fixture requirements.
- [Protocol references](Research/QT150-serial-review.md): QT100/150 source references.

`SwiftTake/` contains the application and bundled resources. `Tools/` contains
standalone development checks outside the app target. `IMAGE03.QTK` is the
portable decoder fixture. Local research collections and development backups
are not part of this repository.

Demo panorama photographs are credited to Tim Meehan in the app. Existing
third-party asset and source credits are retained; inclusion does not establish
a blanket redistribution licence for those materials.

QuickTake is a trademark of Apple Inc. SwiftTake is not affiliated with or
endorsed by Apple.
