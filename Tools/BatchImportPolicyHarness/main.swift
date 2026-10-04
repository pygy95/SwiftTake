import Darwin
import Dispatch
import Foundation
import ImageIO

// Fixed-output and real-temp-file checks for `BatchImportPolicy` (duplicate
// collision resolution, Keep-Both naming, finish-summary wording) and for
// `QTKArchiveStore.saveSafely` (the shared byte-safe archive save both the
// batch-import and re-import paths use). No camera, no manager.
// `NamingMetadataPolicy` is compiled in so the archive-naming checks exercise
// the REAL `stripModeTag`, not a stand-in.

@main struct BatchImportPolicyChecks {
    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            passed += 1; print("PASS: " + name)
        }

        // ── resolveCollision: fresh choices → policy + sticky capture ──
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .skip(applyToAll: false))
            check(r.policy == .skip && r.updatedSticky == nil, "resolveCollision: skip, not sticky")
        }
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .skip(applyToAll: true))
            check(r.policy == .skip && r.updatedSticky == .skip, "resolveCollision: skip, applied to all")
        }
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .replace(applyToAll: true))
            check(r.policy == .replace && r.updatedSticky == .replace, "resolveCollision: replace, applied to all")
        }
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .keepBoth(applyToAll: false))
            check(r.policy == .keepBoth && r.updatedSticky == nil, "resolveCollision: keepBoth, not sticky")
        }
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .keepBoth(applyToAll: true))
            check(r.policy == .keepBoth && r.updatedSticky == .keepBoth, "resolveCollision: keepBoth, applied to all")
        }
        do {
            let r = BatchImportPolicy.resolveCollision(freshChoice: .stop)
            check(r.policy == .stop && r.updatedSticky == nil, "resolveCollision: stop never becomes sticky")
        }

        // ── keepBothName: rendered-file disambiguation, never overwrites ──
        do {
            var existing: Set<String> = ["Photo"]
            let name = BatchImportPolicy.keepBothName(originalBaseName: "Photo") { existing.contains($0) }
            check(name == "Photo 2", "keepBothName: first collision picks \" 2\"")
            existing.insert(name)
            let name2 = BatchImportPolicy.keepBothName(originalBaseName: "Photo") { existing.contains($0) }
            check(name2 == "Photo 3", "keepBothName: second collision on the same run picks \" 3\"")
            check(name != name2, "keepBothName: two distinct collisions never reuse the same rendered name")
        }
        do {
            // Defensive: called on a name that doesn't actually collide.
            let name = BatchImportPolicy.keepBothName(originalBaseName: "Solo") { _ in false }
            check(name == "Solo", "keepBothName: returns the original name when nothing collides")
        }

        // ── archiveBaseName: real stripModeTag, mode tags always trailing ──
        let stemBase = "QuickTake150_19970101_120000_005"
        let newTakeOriginal = stemBase + "_newtake"
        let enhancedOriginal = stemBase + "_enhanced"
        let archiveFromNewTake = BatchImportPolicy.archiveBaseName(originalBaseName: newTakeOriginal,
                                                                    stripModeTag: NamingMetadataPolicy.stripModeTag)
        let archiveFromEnhanced = BatchImportPolicy.archiveBaseName(originalBaseName: enhancedOriginal,
                                                                     stripModeTag: NamingMetadataPolicy.stripModeTag)
        check(archiveFromNewTake == stemBase, "archiveBaseName: strips a trailing mode tag")
        check(archiveFromNewTake == archiveFromEnhanced,
              "archiveBaseName: two colour-mode renders of the same photo share ONE candidate archive stem (a)")

        // Regression proof: the ORIGINAL bug was deriving the archive stem
        // from the Keep-Both-disambiguated RENDERED name instead of the
        // un-suffixed original. Confirm that path really does leave the tag
        // in place (i.e. the fix is not a no-op) — this exact input is what
        // `baseName` held after a Keep-Both collision in the old code.
        let keepBothRenderedName = newTakeOriginal + " 2"
        let buggyArchiveName = NamingMetadataPolicy.stripModeTag(from: keepBothRenderedName)
        check(buggyArchiveName == keepBothRenderedName,
              "regression: stripModeTag cannot see a tag once Keep-Both's \" 2\" sits after it")
        check(!archiveFromNewTake.contains("_newtake") && !archiveFromNewTake.contains(" 2"),
              "archiveBaseName: the correct stem carries no mode tag and no Keep-Both numeral (c)")

        // ── QTKArchiveStore.saveSafely: real temp files, real bytes ──────

        // (1) Occupied destination, unreadable: an existing-but-unreadable
        // file at the candidate must NOT be treated as a byte match — the
        // save must fall through to the next candidate, not assume it's safe.
        try withTempDirectory { dir in
            let occupied = dir.appendingPathComponent("Locked.qtk")
            try Data([0xFF, 0xFE]).write(to: occupied)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: occupied.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: occupied.path) }

            let newBytes = Data([0x01, 0x02, 0x03])
            let url = try QTKArchiveStore.saveSafely(newBytes, candidateStem: "Locked", in: dir)
            check(url.lastPathComponent == "Locked 2.qtk",
                  "saveSafely: an unreadable existing file is not treated as a match — moves to the next candidate")
            check(FileManager.default.contents(atPath: url.path) == newBytes,
                  "saveSafely: the new save's bytes land intact at the next candidate")
        }

        // (2) Distinct bytes at a colliding stem: no overwrite, a unique
        // name is chosen, both files survive with their own exact bytes.
        try withTempDirectory { dir in
            func bytesOnDisk(_ stem: String) -> Data? {
                FileManager.default.contents(atPath: dir.appendingPathComponent(stem).appendingPathExtension("qtk").path)
            }
            let photoX = Data([0xAA, 0xBB, 0xCC, 0xDD])
            let photoY = Data([0x11, 0x22, 0x33, 0x44, 0x55])

            let urlX = try QTKArchiveStore.saveSafely(photoX, candidateStem: "Beach", in: dir)
            let urlY = try QTKArchiveStore.saveSafely(photoY, candidateStem: "Beach", in: dir)
            check(urlX != urlY, "saveSafely: two different photos on the same stem get different archive URLs")
            check(bytesOnDisk("Beach") == photoX, "saveSafely: photo X's archive keeps photo X's exact bytes")
            check(bytesOnDisk("Beach 2") == photoY, "saveSafely: photo Y's archive keeps photo Y's exact bytes, unharmed by X")
        }

        // (3) Identical bytes at a colliding stem: reused, same URL returned
        // — proves the same photo saved under two colour modes shares ONE
        // archive rather than duplicating it.
        try withTempDirectory { dir in
            let cameraBytes = Data([0x71, 0x6B, 0x74, 0x01, 0x02, 0x03]) // mode-independent camera bytes
            let urlFirst = try QTKArchiveStore.saveSafely(cameraBytes, candidateStem: stemBase, in: dir)
            let urlSecond = try QTKArchiveStore.saveSafely(cameraBytes, candidateStem: stemBase, in: dir)
            check(urlFirst == urlSecond, "saveSafely: identical bytes at the candidate stem reuse the SAME URL")

            let filesOnDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".qtk") }
            check(filesOnDisk.count == 1, "saveSafely: two colour-mode renders of one photo leave exactly ONE .qtk on disk")
            check(FileManager.default.contents(atPath: urlFirst.path) == cameraBytes,
                  "saveSafely: the shared archive holds the camera's exact bytes")
        }

        // (4) Collision-across-saves: real concurrent saves racing on the
        // SAME candidate stem must never overwrite each other — the retry
        // path must advance every racer that loses the exclusive-publish
        // step to its own distinct name.
        try withTempDirectory { dir in
            let n = 8
            let payloads = (0..<n).map { i in Data([UInt8(i), UInt8(i &+ 1), UInt8(i &+ 2)]) }
            let lock = NSLock()
            var results = [URL?](repeating: nil, count: n)
            var caughtErrors: [Error] = []
            DispatchQueue.concurrentPerform(iterations: n) { i in
                do {
                    let url = try QTKArchiveStore.saveSafely(payloads[i], candidateStem: "Race", in: dir)
                    lock.lock(); results[i] = url; lock.unlock()
                } catch {
                    lock.lock(); caughtErrors.append(error); lock.unlock()
                }
            }
            check(caughtErrors.isEmpty, "saveSafely: concurrent racers on the same stem all succeed")
            let urls = results.compactMap { $0 }
            check(urls.count == n, "saveSafely: every concurrent racer got a URL back")
            check(Set(urls).count == n,
                  "saveSafely: every concurrent racer landed at a DISTINCT file — the retry path advanced past every collision")
            for i in 0..<n {
                guard let url = results[i] else { continue }
                check(FileManager.default.contents(atPath: url.path) == payloads[i],
                      "saveSafely: racer \(i)'s file holds exactly its own bytes, never another racer's")
            }
        }

        // (5) Retry scope: a publish failure that ISN'T a destination
        // collision (here, a candidate name too long for the filesystem —
        // `ENAMETOOLONG`, confirmed distinct from `EEXIST`) must propagate as
        // itself, never get swallowed into thousands of blind retries and a
        // generic "exhausted" error.
        try withTempDirectory { dir in
            let tooLong = String(repeating: "x", count: 300)
            do {
                _ = try QTKArchiveStore.saveSafely(Data([1, 2, 3]), candidateStem: tooLong, in: dir)
                check(false, "saveSafely: expected a thrown error for an over-long candidate name")
            } catch let error as NSError {
                check(error.domain == NSPOSIXErrorDomain && error.code == Int(ENAMETOOLONG),
                      "saveSafely: a non-collision publish failure propagates as itself (ENAMETOOLONG), not retried")
            }
        }

        // ── finishOutcome: wording preserved verbatim from the prior fix pass ──
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 0, failedPhotoCount: 0, stoppedByUser: false)
            check(o.statusMessage == "No New Photos Imported" && o.errorMessage == nil && !o.shouldPerformPostImportAction,
                  "finishOutcome: all-skipped (0,0) is not an error")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 0, failedPhotoCount: 3, stoppedByUser: false)
            check(o.statusMessage == "Import Finished with Errors"
                  && o.errorMessage == "No photos could be downloaded or saved."
                  && !o.shouldPerformPostImportAction,
                  "finishOutcome: real all-failed gets neutral wording")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 4, failedPhotoCount: 0, stoppedByUser: false)
            check(o.statusMessage == "Imported 4 Photos" && o.errorMessage == nil && o.shouldPerformPostImportAction,
                  "finishOutcome: clean success")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 3, failedPhotoCount: 2, stoppedByUser: false)
            check(o.statusMessage == "Imported 3 of 5"
                  && o.errorMessage == "Some photos couldn't be downloaded or saved."
                  && o.shouldPerformPostImportAction,
                  "finishOutcome: partial success/failure")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 2, failedPhotoCount: 0, stoppedByUser: true)
            check(o.statusMessage == "Stopped — Imported 2 Photos" && o.errorMessage == nil && o.shouldPerformPostImportAction,
                  "finishOutcome: user Stop after some imports is never an error")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 1, failedPhotoCount: 0, stoppedByUser: true)
            check(o.statusMessage == "Stopped — Imported 1 Photo", "finishOutcome: singular wording")
        }
        do {
            let o = BatchImportPolicy.finishOutcome(importedPhotoCount: 0, failedPhotoCount: 0, stoppedByUser: true)
            check(o.statusMessage == "Import Stopped" && !o.shouldPerformPostImportAction,
                  "finishOutcome: user Stop before anything imported")
        }

        // ── completionNotification: the post-import banner must never
        // read "Import Complete" for a run the user cut short themselves ──
        do {
            let n = BatchImportPolicy.completionNotification(importedPhotoCount: 4, failedPhotoCount: 0, stoppedByUser: false)
            check(n?.title == "Import Complete" && n?.body == "Successfully imported 4 photos.",
                  "completionNotification: clean success")
        }
        do {
            let n = BatchImportPolicy.completionNotification(importedPhotoCount: 3, failedPhotoCount: 2, stoppedByUser: false)
            check(n?.title == "Import Complete" && n?.body == "Imported 3 photos, 2 failed.",
                  "completionNotification: partial failure keeps the honest per-count body")
        }
        do {
            // The reproduced defect: save one photo, then Stop on a
            // duplicate prompt — must NOT read "Import Complete".
            let n = BatchImportPolicy.completionNotification(importedPhotoCount: 1, failedPhotoCount: 0, stoppedByUser: true)
            check(n?.title == "Import Stopped", "completionNotification: user Stop after an import never titles \"Import Complete\"")
            check(n?.body == "Stopped after importing 1 photo.", "completionNotification: stopped body is honest about the count, singular")
        }
        do {
            let n = BatchImportPolicy.completionNotification(importedPhotoCount: 5, failedPhotoCount: 0, stoppedByUser: true)
            check(n?.body == "Stopped after importing 5 photos.", "completionNotification: stopped body, plural")
        }
        do {
            // Nothing imported: no banner at all, stopped or not — mirrors
            // finishOutcome's (0, 0) "not worth announcing" gate.
            let n1 = BatchImportPolicy.completionNotification(importedPhotoCount: 0, failedPhotoCount: 0, stoppedByUser: true)
            let n2 = BatchImportPolicy.completionNotification(importedPhotoCount: 0, failedPhotoCount: 3, stoppedByUser: false)
            check(n1 == nil, "completionNotification: nothing imported + stopped suppresses the banner")
            check(n2 == nil, "completionNotification: nothing imported + not stopped suppresses the banner")
        }

        print("\n\(passed) checks passed.")
    }

    static func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BatchImportPolicyHarness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
