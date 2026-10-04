# Import storage checks

Run `./Tools/check.sh` from the repository root with a full Xcode toolchain.
The 52 checks cover preference migration, bookmark save/resolve/refresh/clear,
destination fallback, lazy QTK-folder selection, Fuji import path/size records, and atomic QTK archive saves. Archive checks
cover nested folders, exact bytes, identical-byte reuse, preservation of distinct bytes, and blocked destinations.

All preferences use a unique UserDefaults suite. Files and fallback destinations
stay inside one temporary directory, which is removed on exit. The harness does
not override HOME or access the user's photo folders.

Bookmark checks use plain bookmarks. They exercise persistence and resolution
logic, including following a moved directory, but do not validate sandbox
entitlements or real external-volume access. Production keeps security-scoped
bookmark options. The app's Settings UI remains outside this harness.
