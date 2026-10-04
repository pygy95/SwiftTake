# BatchImportPolicyHarness

Run `./Tools/check.sh` with a full Xcode toolchain.

41 checks. Checks duplicate decisions, completion summaries and archive names. Real temporary
files exercise shared QTKArchiveStore reuse, distinct-byte preservation, occupied
paths, unreadable files and concurrent publication.

These checks do not use a camera or validate real external-volume permissions.
All files are temporary; no camera or personal fixtures are used.
