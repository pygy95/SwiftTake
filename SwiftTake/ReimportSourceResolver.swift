import Foundation

/// Security-scope lifetime, injectable for source-read verification.
nonisolated protocol DestinationScope: Sendable {
    /// Returns whether the caller must balance access with `end()`.
    func begin() -> Bool
    func end()
}

/// Production adapter: a plain `URL.start/stopAccessingSecurityScopedResource`
/// pair, exactly like the manager's existing scoped regions.
nonisolated struct URLDestinationScope: DestinationScope {
    let url: URL
    func begin() -> Bool { url.startAccessingSecurityScopedResource() }
    func end() { url.stopAccessingSecurityScopedResource() }
}

/// Balance successful access even on an early return. An unscoped URL may
/// already be readable when `begin()` returns false; it requires no `end()`.
nonisolated func withDestinationScope<T>(_ scope: DestinationScope, _ read: () -> T?) -> T? {
    let began = scope.begin()
    defer { if began { scope.end() } }
    return read()
}

/// The source that satisfied a lookup.
enum ReimportSourceOrigin: Equatable {
    case disk
    case sessionCache
    case camera
}

enum ReimportSourceOutcome<T> {
    case resolved(T, origin: ReimportSourceOrigin)
    case unavailable
    /// Discard without publishing failure or updating caches.
    case stale
}

/// Resolves disk, cache and camera in order, rejecting stale camera results.
@MainActor
enum ReimportSourceResolver {
    static func resolve<T>(
        diskLookup: () -> T?,
        sessionCacheLookup: () -> T?,
        isCurrent: () -> Bool,
        cameraFetch: () async -> T?
    ) async -> ReimportSourceOutcome<T> {
        guard isCurrent() else { return .stale }

        if let disk = diskLookup() {
            return .resolved(disk, origin: .disk)
        }
        if let cached = sessionCacheLookup() {
            return .resolved(cached, origin: .sessionCache)
        }

        let fetched = await cameraFetch()
        guard isCurrent() else { return .stale }
        guard let fetched else { return .unavailable }
        return .resolved(fetched, origin: .camera)
    }
}
