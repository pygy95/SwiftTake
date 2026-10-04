# Panorama keyboard checks

`Tools/check.sh` includes these camera-free checks. To run them alone from the
repository root:

```sh
xcrun swiftc -O -parse-as-library Tools/PanoramaKeyboardHarness/main.swift \
  SwiftTake/InteractivePanoramaWriter.swift -o /tmp/swifttake-keyboard-checks && \
  /tmp/swifttake-keyboard-checks
```

The harness executes the production-generated viewer script in JavaScriptCore
with a controlled clock and DOM/WebGL doubles. It checks both embedded and
exported presentations: tap distance, elapsed-time speed, frame-rate independence,
OS repeat, reverse movement, reduced motion, focus/visibility/context loss,
reset, Overview, delayed frames, modifier shortcuts and movement bounds.

It does not establish GPU rendering or subjective smoothness in a live browser.
