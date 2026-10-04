# ReimportSourceHarness

Run `./Tools/check.sh` with a full Xcode toolchain.

49 checks. Exercises production source ordering and stale-result rejection, exact Copland
retirement, post-export decisions, and the gallery filename classifier. Temporary
files verify that originals and similar user filenames survive.

The manager/UI lifecycle still needs app testing. Display uses a filename hint;
retirement requires the exact expected path.
All files are temporary; no camera or personal fixtures are used.
