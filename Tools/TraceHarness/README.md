# Trace persistence checks

Run `./Tools/check.sh` from the repository root to include these 19 checks.
For this harness alone:

```sh
xcrun swiftc -parse-as-library Tools/TraceHarness/main.swift \
  SwiftTake/QTDiagnosticLog.swift -o /tmp/swifttake-trace-check && \
  /tmp/swifttake-trace-check
```

The harness exercises the production logger with temporary directories and a
controlled disk writer. It checks snapshot preservation across retries, unique
filenames, writes after manual export, buffer rollover, failed writes, stale
completion handling, and persistence after the logger's owner releases it.
A blocked writer verifies that MainActor can continue processing a new session.

One export-failure diagnostic is expected. No camera or personal Pictures folder
is used. These checks do not simulate the complete manager/UI connection flow.
