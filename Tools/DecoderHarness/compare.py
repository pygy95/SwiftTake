#!/usr/bin/env python3
"""Compare decoder output with the saved baseline without changing either file."""

import argparse
from pathlib import Path


def records(path, allow_skipped=False):
    rows = {}
    for line in path.read_text().splitlines():
        if line.startswith("FAIL:"):
            raise ValueError(line)
        if "|" not in line:
            continue
        fields = line.split("|")
        if len(fields) < 3:
            raise ValueError(f"Malformed record: {line}")
        if fields[1] == "SKIPPED" and allow_skipped:
            continue
        if fields[1] in {"SKIPPED", "MISSING", "BROKEN"}:
            raise ValueError(line)
        key = tuple(fields[:2])
        if key in rows:
            raise ValueError(f"Duplicate record: {'|'.join(key)}")
        rows[key] = fields[2]
    if not rows:
        raise ValueError(f"No baseline records in {path}")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline", type=Path,
                        default=Path(__file__).with_name("baseline.txt"))
    parser.add_argument("--allow-partial", action="store_true",
                        help="Allow explicitly skipped/missing baseline coverage")
    args = parser.parse_args()
    try:
        expected = records(args.baseline)
        actual = records(args.output, allow_skipped=args.allow_partial)
        missing = expected.keys() - actual.keys()
        extra = actual.keys() - expected.keys()
        changed = {key for key in expected.keys() & actual.keys()
                   if expected[key] != actual[key]}
        if extra or changed or (missing and not args.allow_partial):
            for label, keys in [("Missing", missing), ("Unexpected", extra), ("Changed", changed)]:
                for key in sorted(keys):
                    print(f"{label}: {'|'.join(key)}")
            return 1
        if missing:
            print(f"PARTIAL: {len(actual)}/{len(expected)} baseline rows match; "
                  f"{len(missing)} rows untested.")
        else:
            print(f"PASS: all {len(expected)} baseline rows match.")
        return 0
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
