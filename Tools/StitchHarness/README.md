# Stitcher harness

Runs the panorama stitcher over a directory of frames and
prints one deterministic digest line: frame order, step, slope, strip
size, overlap, wraparound, solved field of view. Any diff vs
`baseline.txt` means the geometry the stitcher solves has changed — stop
and explain before shipping.

Build (delete the old binary first — a failed compile otherwise leaves
the previous one in place and the diff reads green while proving
nothing):

    rm -f stitchharness
    xcrun swiftc -O main.swift sweep.swift regressions.swift ../../SwiftTake/PanoramaStitcher.swift ../../SwiftTake/PanoramaFeatureMatcher.swift ../../SwiftTake/PanoramaQuickPanMatcher.swift \
        ../../SwiftTake/DemoPanScene.swift -o stitchharness

Compare:

    diff baseline.txt <(./stitchharness "/path/to/panorama-fixtures")

`--png out.png` also writes the assembled strip, which is the only way to
catch the failures that keep perfectly good numbers — see below.

## The reference set

The optional reference set is a four-frame QuickPan + WideTake sequence, shot
right to left. It is kept privately outside the repository. Without those exact
fixtures, the historical baseline cannot be reproduced; use the portable modes
below and report the missing coverage explicitly.

The harness feeds the `_enhanced.tiff` renders, and feeds them in the
SAME orientation the app feeds the stitcher: 640x480, content lying on
its side, filename order. Rotating or reordering them first would skip
the two decisions most worth regression-testing.

The current TIFF baseline is `slope=4 strip=1017x629`. Before the September
2026 per-pair positioning fix it was `1017x628`. The raw `.qtk` path now
produces `slope=3 strip=1018x630`; these inputs differ because the TIFFs
already have enhancement applied. Baseline changes are explained in
[the reliability notes](../../Docs/PANORAMA-RELIABILITY.md).

## Additional checks

```sh
./stitchharness --demo
./stitchharness --sweep
./stitchharness --regressions
```

All three modes exit nonzero on failure. The sweep includes 31 supported
geometry cases and two expected rejections at/outside the search boundary.
The geometry regression checks compare uneven pans and closed loops against known
source pixels, and verify that weak shuffled sequences are rejected even
when a manual order is supplied. Photos must still be in capture order or
manually arranged; automatic mode determines direction only. Perspective fixtures also verify the
cylindrical fallback, angular spacing, forward/reverse rendering equivalence,
manual ordering, and rejection of a missing overlap.

## Why the PNG matters

Numbers alone do not prove a panorama is right. When `upright` briefly
offered an anticlockwise candidate, the digest still read `step=179
strip=1017x...` and only the assembled image showed it had been built
upside down. Clockwise and anticlockwise differ by 180°, which preserves
neighbour overlap exactly, so the correlations tie and noise picks the
winner. Look at the picture.
