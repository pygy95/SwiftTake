import Foundation

/// Duplicate choices, archive stems and completion summaries for camera imports.
/// File publication belongs to QTKArchiveStore; serial work stays with the manager.
nonisolated enum BatchImportPolicy {

    // MARK: Duplicate-collision resolution

    enum StickyPolicy: Equatable {
        case skip, replace, keepBoth, stop
    }

    enum DuplicateChoice: Equatable {
        case skip(applyToAll: Bool)
        case replace(applyToAll: Bool)
        case keepBoth(applyToAll: Bool)
        case stop
    }

    struct CollisionResolution: Equatable {
        let policy: StickyPolicy
        let updatedSticky: StickyPolicy?
    }

    static func resolveCollision(freshChoice: DuplicateChoice) -> CollisionResolution {
        switch freshChoice {
        case .skip(let all):
            return CollisionResolution(policy: .skip, updatedSticky: all ? .skip : nil)
        case .replace(let all):
            return CollisionResolution(policy: .replace, updatedSticky: all ? .replace : nil)
        case .keepBoth(let all):
            return CollisionResolution(policy: .keepBoth, updatedSticky: all ? .keepBoth : nil)
        case .stop:
            return CollisionResolution(policy: .stop, updatedSticky: nil)
        }
    }

    // MARK: Keep-Both rendered-file naming

    static func keepBothName(originalBaseName: String, fileExists: (String) -> Bool) -> String {
        guard fileExists(originalBaseName) else { return originalBaseName }
        var n = 2
        var candidate = "\(originalBaseName) \(n)"
        while fileExists(candidate) {
            n += 1
            candidate = "\(originalBaseName) \(n)"
        }
        return candidate
    }

    // MARK: Raw-archive naming (the Keep Both / mode-tag fix)

    static func archiveBaseName(originalBaseName: String, stripModeTag: (String) -> String) -> String {
        stripModeTag(originalBaseName)
    }

    // MARK: Finish-summary wording

    struct FinishOutcome: Equatable {
        let statusMessage: String
        let errorMessage: String?
        let shouldPerformPostImportAction: Bool
    }

    static func finishOutcome(importedPhotoCount: Int, failedPhotoCount: Int, stoppedByUser: Bool) -> FinishOutcome {
        if stoppedByUser {
            let status = importedPhotoCount > 0
                ? "Stopped — Imported \(importedPhotoCount) Photo\(importedPhotoCount == 1 ? "" : "s")"
                : "Import Stopped"
            return FinishOutcome(statusMessage: status, errorMessage: nil,
                                 shouldPerformPostImportAction: importedPhotoCount > 0)
        }

        switch (importedPhotoCount, failedPhotoCount) {
        case (0, 0):
            return FinishOutcome(statusMessage: "No New Photos Imported", errorMessage: nil,
                                 shouldPerformPostImportAction: false)
        case (0, _):
            return FinishOutcome(statusMessage: "Import Finished with Errors",
                                 errorMessage: "No photos could be downloaded or saved.",
                                 shouldPerformPostImportAction: false)
        case (_, 0):
            return FinishOutcome(statusMessage: "Imported \(importedPhotoCount) Photos", errorMessage: nil,
                                 shouldPerformPostImportAction: true)
        default:
            return FinishOutcome(
                statusMessage: "Imported \(importedPhotoCount) of \(importedPhotoCount + failedPhotoCount)",
                errorMessage: "Some photos couldn't be downloaded or saved.",
                shouldPerformPostImportAction: true
            )
        }
    }

    // MARK: Post-import notification wording

    /// Nil suppresses the banner entirely — nothing imported means nothing
    /// to announce, mirroring `finishOutcome`'s (0, 0) case. When the user
    /// stopped the batch, the title and body say so honestly instead of
    /// reusing the success wording for a run they cut short themselves.
    static func completionNotification(importedPhotoCount: Int, failedPhotoCount: Int,
                                        stoppedByUser: Bool) -> (title: String, body: String)? {
        guard importedPhotoCount > 0 else { return nil }
        if stoppedByUser {
            return ("Import Stopped", "Stopped after importing \(importedPhotoCount) photo\(importedPhotoCount == 1 ? "" : "s").")
        }
        if failedPhotoCount > 0 {
            return ("Import Complete", "Imported \(importedPhotoCount) photos, \(failedPhotoCount) failed.")
        }
        return ("Import Complete", "Successfully imported \(importedPhotoCount) photos.")
    }

    // MARK: Batch summary

    struct Summary {
        let importedPhotoCount: Int
        let failedPhotoCount: Int
        let savedFiles: [URL]
        var stoppedByUser = false
    }
}
