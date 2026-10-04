# Camera batch import checks

Run `./Tools/check.sh` from the repository root with a full Xcode selected.

The harness runs the production `CameraBatchImportEngine` with simulated session
and presentation adapters and real temporary files. Its checks cover header
and download retries, duplicate choices, dynamic queue additions, QT200 naming,
original preservation, failed exports, disconnection and stale async results.
QT200 duplicate choices are checked against the final EXIF name, including
sticky Skip/Replace/Keep Both/Stop behavior and replacement permission.

It does not open a serial port, run the manager's UI adapters or validate physical
camera timing. Use `Docs/CAMERA-ACCEPTANCE.md` for those acceptance checks.
