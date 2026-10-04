#!/usr/bin/env python3
"""Find the byte that tells a QuickTake 100 from a QuickTake 150.

Run SwiftTake's Diagnostics with each camera attached, save both reports,
then:

    python3 identify-qt100-vs-150.py qt150-report.txt qt100-report.txt

It pulls the 128-byte DEVICE INFO block out of each report and prints every
offset where they differ, with the fields SwiftTake already knows about
labelled so you can discount them.

WHY THIS EXISTS
---------------
SwiftTake reads a 128-byte device-info block on every connect and uses six
fields from it (battery, pictures taken, pictures remaining, flash mode,
quality, name). Over a hundred bytes are ignored, and the model identity is
very likely among them.

Today the app identifies a QT100 vs QT150 from the wake burst (byte 3:
0xC8 = QT150) — which only exists if the camera was ASLEEP when you
connected. Connect to an already-awake QT100 with no remembered identity and
it is assumed to be a 150. Asking the camera outright would fix that, and
the device-info block is the app asking.

WHAT TO IGNORE IN THE OUTPUT
----------------------------
Differences at the labelled offsets prove nothing — they are just the two
cameras being in different states. What you want is a byte that differs and
has no business differing: a ROM revision, a model code, a capability
bitmask. Ideally confirm it by dumping the same camera twice (it should be
identical) before trusting it as identity.
"""

import re
import sys

# What SwiftTake already reads, so a difference here is expected state and
# not a model marker. Offsets from QuickTakeSerialManager's parse.
KNOWN = {
    2: "battery level",
    4: "pictures taken",
    6: "pictures remaining",
    22: "flash mode",
    27: "quality (16 HQ / 32 SQ)",
}
KNOWN.update({o: "camera name (user-editable — ignore)" for o in range(47, 79)})


def device_info(path):
    """The 128-byte block following the 'DEVICE INFO' heading."""
    text = open(path, errors="replace").read()
    idx = text.find("DEVICE INFO")
    if idx == -1:
        sys.exit(f"{path}: no 'DEVICE INFO' section — is this a SwiftTake "
                 f"diagnostic report?")
    # The report prints "[deviceInfo]" then a line of "AA BB CC ..." hex.
    window = text[idx:idx + 6000]
    for line in window.splitlines():
        pairs = re.findall(r"\b[0-9A-Fa-f]{2}\b", line)
        if len(pairs) >= 32:                      # the hex dump line
            return [int(p, 16) for p in pairs]
    sys.exit(f"{path}: found the DEVICE INFO heading but no hex dump under it.")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a_path, b_path = sys.argv[1], sys.argv[2]
    a, b = device_info(a_path), device_info(b_path)

    print(f"A: {a_path}  ({len(a)} bytes)")
    print(f"B: {b_path}  ({len(b)} bytes)")
    print()

    n = min(len(a), len(b))
    diffs = [(i, a[i], b[i]) for i in range(n) if a[i] != b[i]]
    if not diffs:
        print("No differences at all. Either both reports are from the same "
              "camera, or the model is not in this block — in which case the "
              "wake burst stays the only hardware evidence.")
        return

    print(f"{len(diffs)} differing byte(s):\n")
    print(f"{'offset':>7}  {'A':>4}  {'B':>4}   note")
    candidates = []
    for i, av, bv in diffs:
        note = KNOWN.get(i, "")
        if not note:
            candidates.append(i)
            note = "<-- CANDIDATE"
        print(f"{i:>7}  0x{av:02X}  0x{bv:02X}   {note}")

    print()
    if candidates:
        print("Candidates (differ, and nothing known reads them):",
              ", ".join(str(c) for c in candidates))
        print()
        print("Next: dump the SAME camera twice and re-run this. Any offset "
              "that also differs between two dumps of one camera is state, "
              "not identity. Whatever survives is the byte worth wiring into "
              "resolveModel.")
    else:
        print("Every difference is a field SwiftTake already reads, i.e. just "
              "the two cameras being in different states. No identity byte "
              "here.")


if __name__ == "__main__":
    main()
