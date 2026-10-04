# QTVR parser harness

Parses every movie on the July 1995 QuickTime VR demo CD through
`SwiftTake/QTVRFormat.swift` and prints one deterministic digest line
per file. Any diff vs `baseline.txt` = the parser's reading of the
period files changed = stop and explain before shipping.

The corpus is Apple-copyrighted, so it stays out of the repo
(`Research/QTVR/corpus/`, gitignored). Regenerate it from the CD image
provided separately:

    python3 extract_corpus.py "/path/to/QuickTime VR 7-95.toast"  # needs: pip install machfs

Movies come in two layouts and the corpus preserves both: `<name>.mov`
is the data fork; a `<name>.moov` sidecar is the movie's resource-fork
`moov` (authoring-form files keep their atoms there, with chunk offsets
indexing the data fork). The harness prefers the sidecar when present.

Build and compare:

    xcrun swiftc -O main.swift ../../SwiftTake/QTVRFormat.swift \
        ../../SwiftTake/QTVRPanoramaWriter.swift -o qtvrharness

Delete the old `qtvrharness` binary first. A failed compile leaves the
previous one in place and the diff then reads green while proving
nothing — which is exactly what this line already did once, after
main.swift gained its writer round-trip and the command still listed
only QTVRFormat.swift.
    diff baseline.txt <(./qtvrharness)

An empty diff means the parser reads all 38 period files exactly as
baselined. Coverage: single-node panos (24-tile, both ±42.5 default and
cropped vPan), multi-node panos with hot-spot tracks and pLnk/pNav
tables, a dual-resolution pano (low-res scene track), object movies
from 36x1 single-row turntables to 36x14 multi-row rigs, a loop=9
frame-animation object, partial-pan objects, and plain linear movies
that must NOT be classified as VR.

This baseline also referees Phase 1: the writer's output must parse
into the same structural shapes as the corpus originals.
