#!/bin/bash
# Run the self-contained checks from any working directory. No camera is used.
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swifttake-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/CoreReliabilityHarness/main.swift SwiftTake/SerialPort.swift \
  SwiftTake/CameraWork.swift SwiftTake/AtomicFileWriter.swift \
  -o "$scratch/core"
"$scratch/core"

xcrun swift Tools/PhantomSessionHarness/generate.swift \
  SwiftTake/QuickTakeSerialManager.swift > "$scratch/phantom-session.swift"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  "$scratch/phantom-session.swift" -o "$scratch/phantom-session"
"$scratch/phantom-session"

xcrun swift Tools/CoplandDemoHarness/generate.swift > "$scratch/copland-demo.swift"
xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  "$scratch/copland-demo.swift" SwiftTake/QuickTakeDecoder.swift \
  SwiftTake/QTDiagnosticLog.swift SwiftTake/CoplandArtifactPolicy.swift \
  SwiftTake/QuickTake200JPEGDecoder.swift SwiftTake/ReimportSourceResolver.swift SwiftTake/PhotoTransfer.swift \
  -o "$scratch/copland-demo"
"$scratch/copland-demo"

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/SerialHarness/main.swift SwiftTake/SerialPort.swift \
  SwiftTake/QuickTakeTransport.swift SwiftTake/QuickTakeCommands.swift \
  SwiftTake/QuickTakeCameraSession.swift SwiftTake/FujiCameraSession.swift \
  SwiftTake/CameraDiagnostics.swift -o "$scratch/serial"
"$scratch/serial"

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/TraceHarness/main.swift SwiftTake/QTDiagnosticLog.swift \
  -o "$scratch/traces"
"$scratch/traces"

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/NamingMetadataHarness/main.swift SwiftTake/NamingMetadataPolicy.swift \
  -o "$scratch/naming"
"$scratch/naming"

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/PhotoExporterHarness/main.swift SwiftTake/PhotoExporter.swift \
  SwiftTake/AtomicFileWriter.swift SwiftTake/CameraWork.swift -o "$scratch/export"
"$scratch/export"

xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/ImportStorageHarness/main.swift SwiftTake/DestinationBookmarkStore.swift \
  SwiftTake/FujiImportLedger.swift SwiftTake/PreferenceKeys.swift SwiftTake/QTKArchiveStore.swift \
  -o "$scratch/storage"
"$scratch/storage"

xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/CameraRenderingHarness/main.swift SwiftTake/CameraImageRenderer.swift \
  SwiftTake/QuickTakeThumbnailRenderer.swift SwiftTake/FujiQualityClassifier.swift \
  SwiftTake/QuickTakeDecoder.swift SwiftTake/FinishedImageLook.swift \
  SwiftTake/QTDiagnosticLog.swift SwiftTake/QuickTake200JPEGDecoder.swift \
  SwiftTake/QTKFormatter.swift -o "$scratch/rendering"
"$scratch/rendering"

xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/PanoramaPipelineHarness/main.swift SwiftTake/PanoramaPipeline.swift \
  SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift SwiftTake/PanoramaExport.swift SwiftTake/InteractivePanoramaWriter.swift \
  SwiftTake/PanoramaComposition.swift SwiftTake/FinishedImageLook.swift \
  SwiftTake/QuickTakeDecoder.swift SwiftTake/QTDiagnosticLog.swift \
  SwiftTake/QTVRPanoramaWriter.swift SwiftTake/ImmersivePanoramaWriter.swift \
  SwiftTake/ReimportSourceResolver.swift \
  -o "$scratch/panorama-pipeline"
"$scratch/panorama-pipeline"

# Exercise the manager's production lifecycle methods with controlled decode
# callbacks. Extraction avoids linking the entire app into a test executable.
xcrun swift Tools/PanoramaLifecycleHarness/generate.swift \
  SwiftTake/QuickTakeSerialManager.swift > "$scratch/panorama-lifecycle.swift"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
  "$scratch/panorama-lifecycle.swift" -o "$scratch/panorama-lifecycle"
"$scratch/panorama-lifecycle"

xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/PanoramaHarness/main.swift SwiftTake/PanoramaComposition.swift \
  SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift SwiftTake/PanoramaExport.swift SwiftTake/InteractivePanoramaWriter.swift \
  SwiftTake/FinishedImageLook.swift SwiftTake/QuickTakeDecoder.swift \
  SwiftTake/QTDiagnosticLog.swift SwiftTake/QTVRPanoramaWriter.swift \
  SwiftTake/ImmersivePanoramaWriter.swift -o "$scratch/panorama"
"$scratch/panorama"

xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/PanoramaKeyboardHarness/main.swift SwiftTake/InteractivePanoramaWriter.swift \
  -o "$scratch/panorama-keyboard"
"$scratch/panorama-keyboard"

xcrun swiftc -O -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/QuickPanHarness/main.swift SwiftTake/PanoramaStitcher.swift \
  SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift \
  -o "$scratch/quickpan"
"$scratch/quickpan"

# Stitch/QTVR/Immersive harnesses also have fixture-dependent modes (a
# personal photo set, an Apple-copyrighted CD corpus) that stay manual —
# see their READMEs. These modes need only repository fixtures.
xcrun swiftc -O -module-cache-path "$scratch/modules" \
  Tools/StitchHarness/main.swift Tools/StitchHarness/sweep.swift \
  Tools/StitchHarness/regressions.swift SwiftTake/PanoramaStitcher.swift SwiftTake/PanoramaFeatureMatcher.swift SwiftTake/PanoramaQuickPanMatcher.swift \
  SwiftTake/DemoPanScene.swift -o "$scratch/stitch"
"$scratch/stitch" --demo
"$scratch/stitch" --sweep
"$scratch/stitch" --regressions

xcrun swiftc -O -module-cache-path "$scratch/modules" \
  Tools/QTVRHarness/main.swift SwiftTake/QTVRFormat.swift \
  SwiftTake/QTVRPanoramaWriter.swift -o "$scratch/qtvr"
"$scratch/qtvr" --writer-checks

xcrun swiftc -O -module-cache-path "$scratch/modules" \
  Tools/ImmersiveHarness/main.swift SwiftTake/ImmersivePanoramaWriter.swift \
  -o "$scratch/immersive"
"$scratch/immersive"

xcrun swiftc -warnings-as-errors -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/FileImportPipelineHarness/main.swift SwiftTake/FileImportPipeline.swift \
  SwiftTake/PhotoTransfer.swift -o "$scratch/file-import"
"$scratch/file-import"

xcrun swiftc -warnings-as-errors -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/BatchImportPolicyHarness/main.swift SwiftTake/BatchImportPolicy.swift \
  SwiftTake/NamingMetadataPolicy.swift SwiftTake/QTKArchiveStore.swift \
  -o "$scratch/batch-import"
"$scratch/batch-import"

xcrun swiftc -warnings-as-errors -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/ReimportSourceHarness/main.swift SwiftTake/ReimportSourceResolver.swift \
  SwiftTake/CoplandArtifactPolicy.swift SwiftTake/ReimportPostExportDecision.swift \
  -o "$scratch/reimport"
"$scratch/reimport"

xcrun swiftc -warnings-as-errors -parse-as-library -module-cache-path "$scratch/modules" \
  Tools/CameraBatchImportHarness/main.swift SwiftTake/CameraBatchImportEngine.swift \
  SwiftTake/BatchImportPolicy.swift SwiftTake/NamingMetadataPolicy.swift \
  SwiftTake/QTKArchiveStore.swift SwiftTake/PhotoTransfer.swift -o "$scratch/camera-batch"
"$scratch/camera-batch"
