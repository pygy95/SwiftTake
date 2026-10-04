import Foundation

// Fixed-output checks for the re-import source-resolution pieces extracted
// from `QuickTakeSerialManager`:
//
//   • `CoplandArtifactPolicy` — exact-match identification (and retirement)
//     of the app-generated Copland PNG, replacing the old
//     `lastPathComponent.contains("copland")` substring check that could
//     have deleted an arbitrary user file. Also covers the legacy
//     `preferredDiskCandidate` helper. Panorama source loading now bypasses
//     rendered exports entirely; CoplandDemoHarness checks that routing.
//   • `ReimportPostExportDecision` — the actual post-export decision
//     `performReimportBatch` calls (retire the Copland artifact and record
//     the new URL on success; change nothing on failure). The harness below
//     calls this SAME function directly, not a hand-copied mirror of it.
//   • `ReimportSourceResolver` — the shared disk -> session-cache -> camera
//     ordering used by QTK re-import (finished panorama frames skip disk),
//     including the generation re-check that must fire on BOTH the success
//     and the failure branch of the camera fetch.
//
// No camera, no manager, no app UI. Section 1 uses real temporary files on
// disk (Copland identification is inherently about real filenames/paths).
// Section 2 is pure — `ReimportSourceResolver` takes injected closures, so
// staleness is simulated deterministically by flipping a captured flag
// from inside the "camera fetch" closure itself, standing in for "the
// generation changed while this await was suspended."
//
// `ReimportSourceResolver` is `@MainActor` (matching `CameraWork` and every
// real call site), so this harness's checks run on the main actor too.

@main struct ReimportSourceChecks {

    static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1
            print("PASS: " + name)
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("swifttake-reimport-source-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeFile(_ name: String, in dir: URL, bytes: UInt8 = 0x2A) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data([bytes]).write(to: url)
            return url
        }

        // ════════════════════════════════════════════════════════════════
        // 1. CoplandArtifactPolicy — exact identification, never substring
        // ════════════════════════════════════════════════════════════════
        let destination = scratch.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let cleanStem = "QuickTake150_20260101_000000_005"

        // Logical-only check (no file written — a case-differing extension
        // would collide on disk with the real artifact created below on a
        // case-insensitive-but-preserving filesystem like APFS, which would
        // only prove something about the filesystem, not the classifier):
        // the classifier's match is case-SENSITIVE on the extension, so
        // "_copland.PNG" is never treated as the generated "_copland.png".
        check(
            !CoplandArtifactPolicy.isGeneratedArtifact(
                destination.appendingPathComponent("\(cleanStem)_copland.PNG"),
                cleanStem: cleanStem, in: destination
            ),
            "isGeneratedArtifact is case-sensitive on the generated extension"
        )

        // (a) A user file that merely CONTAINS "copland" in its name, in
        // several shapes, must never be identified as the artifact — any
        // extension, any stem, even one that shares the destination folder.
        let userLookalikes = try [
            makeFile("my_copland_notes.qtk", in: destination),
            makeFile("vacation_copland_shot.png", in: destination),
            makeFile("Copland.png", in: destination),                 // no leading stem/underscore at all
            makeFile("\(cleanStem)_copland.png.qtk", in: destination) // "copland" substring, wrong extension
        ]
        for lookalike in userLookalikes {
            check(
                !CoplandArtifactPolicy.isGeneratedArtifact(lookalike, cleanStem: cleanStem, in: destination),
                "isGeneratedArtifact rejects lookalike \(lookalike.lastPathComponent)"
            )
        }
        for lookalike in userLookalikes {
            check(fm.fileExists(atPath: lookalike.path), "lookalike \(lookalike.lastPathComponent) still exists before retiring")
        }
        var removedByRetiring: [URL] = []
        let untouchedURLs = CoplandArtifactPolicy.retiring(
            userLookalikes, cleanStem: cleanStem, in: destination,
            remove: { removedByRetiring.append($0) }
        )
        check(removedByRetiring.isEmpty, "retiring(_:) removes nothing when no real artifact is present")
        check(untouchedURLs == userLookalikes, "retiring(_:) passes an all-lookalike list through unchanged")
        for lookalike in userLookalikes {
            check(fm.fileExists(atPath: lookalike.path), "lookalike \(lookalike.lastPathComponent) NOT deleted by retiring")
        }

        // (b) The REAL generated Copland PNG (saveCoplandImage's exact
        // naming: "<cleanStem>_copland.png") IS identified and retired.
        let realArtifact = try makeFile("\(cleanStem)_copland.png", in: destination)
        check(
            CoplandArtifactPolicy.isGeneratedArtifact(realArtifact, cleanStem: cleanStem, in: destination),
            "isGeneratedArtifact accepts the exact generated name"
        )
        var urlsWithArtifact = userLookalikes + [realArtifact]
        var removed: [URL] = []
        urlsWithArtifact = CoplandArtifactPolicy.retiring(
            urlsWithArtifact, cleanStem: cleanStem, in: destination,
            remove: { removed.append($0); try? fm.removeItem(at: $0) }
        )
        check(removed == [realArtifact], "retiring(_:) removes only the real artifact, one call")
        check(!urlsWithArtifact.contains(realArtifact), "real artifact dropped from the returned list")
        check(urlsWithArtifact.count == userLookalikes.count, "every lookalike survives in the returned list")
        check(!fm.fileExists(atPath: realArtifact.path), "real artifact actually removed from disk")
        for lookalike in userLookalikes {
            check(fm.fileExists(atPath: lookalike.path), "lookalike \(lookalike.lastPathComponent) still on disk after real retirement")
        }

        // (c) / (d) Retirement must only run AFTER a replacement export has
        // already succeeded; a failed export must leave the artifact (and
        // the URL list) completely untouched. Calls the REAL production
        // function `ReimportPostExportDecision.apply` directly — the same
        // one `performReimportBatch` calls — not a hand-copied mirror of it.
        let artifactForFailureCase = try makeFile("\(cleanStem)_copland.png", in: destination)
        let newURL = destination.appendingPathComponent("\(cleanStem)_newtake.jpg")

        var ranOnFailure = false
        let decisionOnFailure = ReimportPostExportDecision.apply(
            exportedURL: nil,   // what `performReimportBatch` passes on a failed export
            existingURLs: [artifactForFailureCase],
            cleanStem: cleanStem, destination: destination,
            removeFile: { _ in ranOnFailure = true }
        )
        check(decisionOnFailure == nil, "apply(exportedURL: nil, …) reports no change on a failed export")
        check(!ranOnFailure, "apply(exportedURL: nil, …) never removes a file")
        check(fm.fileExists(atPath: artifactForFailureCase.path), "Copland artifact untouched on disk after a failed re-export")

        var ranOnSuccess = false
        let decisionOnSuccess = ReimportPostExportDecision.apply(
            exportedURL: newURL,   // what `performReimportBatch` passes on a successful export
            existingURLs: [artifactForFailureCase],
            cleanStem: cleanStem, destination: destination,
            removeFile: { url in ranOnSuccess = true; try? fm.removeItem(at: url) }
        )
        check(ranOnSuccess, "apply(exportedURL: newURL, …) retires the Copland artifact on a successful export")
        check(decisionOnSuccess == [newURL], "apply(exportedURL: newURL, …) swaps the artifact for the new export in the returned list")
        check(!fm.fileExists(atPath: artifactForFailureCase.path), "Copland artifact removed from disk only via the real decision function, after export success")

        // ════════════════════════════════════════════════════════════════
        // 2. ReimportSourceResolver — disk -> cache -> camera ordering,
        //    and the generation re-check on both the success AND the
        //    failure branch of the camera fetch.
        // ════════════════════════════════════════════════════════════════

        // 2a. Disk wins outright — cache and camera are never consulted.
        do {
            var cacheCalled = false, cameraCalled = false
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { "disk-bytes" },
                sessionCacheLookup: { cacheCalled = true; return "cache-bytes" },
                isCurrent: { true },
                cameraFetch: { cameraCalled = true; return "camera-bytes" }
            )
            check(isResolved(outcome, equalTo: "disk-bytes", origin: .disk), "disk lookup wins when present")
            check(!cacheCalled, "cache is never consulted when disk already satisfied the request")
            check(!cameraCalled, "camera is never consulted when disk already satisfied the request")
        }

        // 2b. No disk, cache wins — camera is never consulted.
        do {
            var cameraCalled = false
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { nil as String? },
                sessionCacheLookup: { "cache-bytes" },
                isCurrent: { true },
                cameraFetch: { cameraCalled = true; return "camera-bytes" }
            )
            check(isResolved(outcome, equalTo: "cache-bytes", origin: .sessionCache), "session cache wins when disk is empty")
            check(!cameraCalled, "camera is never consulted when the session cache already satisfied the request")
        }

        // 2c. No disk, no cache, camera fetch succeeds while still current.
        do {
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { nil as String? },
                sessionCacheLookup: { nil as String? },
                isCurrent: { true },
                cameraFetch: { "camera-bytes" }
            )
            check(isResolved(outcome, equalTo: "camera-bytes", origin: .camera), "camera fetch used as last resort")
        }

        // 2d. No disk, no cache, camera fetch genuinely fails (nil) while
        // still current -> `.unavailable`, NOT `.stale`.
        do {
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { nil as String? },
                sessionCacheLookup: { nil as String? },
                isCurrent: { true },
                cameraFetch: { nil as String? }
            )
            check(isUnavailable(outcome), "a genuine camera-fetch failure (generation unchanged) reports unavailable")
        }

        // 2e. STALE ON SUCCESS: the camera fetch produces a value, but the
        // generation moved on while it was suspended. Must be `.stale`,
        // and must NOT be treated as a usable resolved value.
        do {
            var isCurrentFlag = true
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { nil as String? },
                sessionCacheLookup: { nil as String? },
                isCurrent: { isCurrentFlag },
                cameraFetch: {
                    // Simulates the generation changing while this await
                    // was suspended (e.g. a reconnect superseded the job).
                    isCurrentFlag = false
                    return "camera-bytes-that-arrived-too-late"
                }
            )
            check(isStale(outcome), "a stale generation after a SUCCESSFUL camera fetch is discarded, not resolved")
        }

        // 2f. STALE ON FAILURE: the camera fetch returns nil AND the
        // generation moved on while it was suspended. Must still be
        // `.stale`, not `.unavailable` — this is the exact gap the
        // generation-guard audit found and fixed in `loadOrFetchQTK` /
        // `loadOrFetchFinishedFrame` (the old code's combined
        // `guard let header = await fetch(), header.count >= 25 else { return nil }`
        // returned on the failure branch WITHOUT ever re-checking
        // currency).
        do {
            var isCurrentFlag = true
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { nil as String? },
                sessionCacheLookup: { nil as String? },
                isCurrent: { isCurrentFlag },
                cameraFetch: {
                    isCurrentFlag = false
                    return nil as String?
                }
            )
            check(isStale(outcome), "a stale generation after a FAILED camera fetch is discarded as stale, not reported as merely unavailable")
        }

        // 2g. Stale from the very start — disk/cache/camera are never
        // consulted at all.
        do {
            var diskCalled = false, cacheCalled = false, cameraCalled = false
            let outcome = await ReimportSourceResolver.resolve(
                diskLookup: { diskCalled = true; return nil as String? },
                sessionCacheLookup: { cacheCalled = true; return nil as String? },
                isCurrent: { false },
                cameraFetch: { cameraCalled = true; return "camera-bytes" }
            )
            check(isStale(outcome), "already-stale generation short-circuits before any lookup")
            check(!diskCalled, "disk lookup skipped when already stale")
            check(!cacheCalled, "cache lookup skipped when already stale")
            check(!cameraCalled, "camera fetch skipped when already stale")
        }

        for (name, expected) in [
            ("Photo_copland.png", true), ("Photo_copland.PNG", true),
            ("my-copland-notes.png", false), ("Photo_copland.qtk", false),
            ("Photo_copland.jpg", false), ("Photo_copland.png.old", false)
        ] {
            check(CoplandArtifactPolicy.isDisplayArtifact(scratch.appendingPathComponent(name)) == expected,
                  "gallery artifact classification: \(name)")
        }

        // ════════════════════════════════════════════════════════════════
        // 1b. CoplandArtifactPolicy.preferredDiskCandidate — the exact
        //    legacy rendered-file selection helper.
        //    A Copland-developed QT200 photo's `importedPhotoURLs` entry
        //    can be exactly `[..._copland.png]` (the Mac OS 9 framed
        //    artifact, `registerCoplandFile` deletes everything else since
        //    QT200 has no `.qtk`); panorama stitching must never pick that
        //    frame as the finished render.
        // ════════════════════════════════════════════════════════════════
        let readableExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]
        func url(_ name: String) -> URL { scratch.appendingPathComponent(name) }

        // An ordinary render sits alongside the framed PNG: the ordinary
        // file wins, regardless of list order.
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("x_copland.png"), url("x.jpg")], readableExtensions: readableExtensions
            ) == url("x.jpg"),
            "preferredDiskCandidate skips the Copland artifact and picks the ordinary render"
        )
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("x.jpg"), url("x_copland.png")], readableExtensions: readableExtensions
            ) == url("x.jpg"),
            "preferredDiskCandidate picks the ordinary render regardless of list order"
        )

        // Only the framed artifact exists (the exact QT200-after-Copland
        // shape): no disk candidate, so the caller falls back to the
        // session cache or the camera instead of stitching the frame.
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("x_copland.png")], readableExtensions: readableExtensions
            ) == nil,
            "preferredDiskCandidate returns nil when every readable entry is a Copland artifact"
        )
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("a_copland.png"), url("b_copland.png")], readableExtensions: readableExtensions
            ) == nil,
            "preferredDiskCandidate returns nil for a multi-entry artifact-only list too"
        )

        // An ordinary single-render list (the common case, no Copland
        // involved at all) is unchanged.
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("x.jpg")], readableExtensions: readableExtensions
            ) == url("x.jpg"),
            "preferredDiskCandidate passes an ordinary single-render list through unchanged"
        )

        // A non-readable extension (e.g. a QT150's `.qtk`, handled by
        // `loadOrFetchQTK` instead) is never a candidate, artifact or not.
        check(
            CoplandArtifactPolicy.preferredDiskCandidate(
                in: [url("x.qtk"), url("x_copland.png")], readableExtensions: readableExtensions
            ) == nil,
            "preferredDiskCandidate ignores non-readable extensions and still rejects the artifact"
        )

        print("\n\(passed) checks passed.")
    }
}

// MARK: - Small outcome-matching helpers (avoid requiring Equatable on the
// resolver's generic payload just for these checks).

private func isResolved(
    _ outcome: ReimportSourceOutcome<String>, equalTo expected: String, origin: ReimportSourceOrigin
) -> Bool {
    if case .resolved(let value, let actualOrigin) = outcome {
        return value == expected && actualOrigin == origin
    }
    return false
}

private func isUnavailable(_ outcome: ReimportSourceOutcome<String>) -> Bool {
    if case .unavailable = outcome { return true }
    return false
}

private func isStale(_ outcome: ReimportSourceOutcome<String>) -> Bool {
    if case .stale = outcome { return true }
    return false
}
