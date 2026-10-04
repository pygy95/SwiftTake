import Foundation

/// Owns the lifetime of asynchronous camera jobs. Invalidating a connection
/// cancels its jobs; the generation also rejects results from noncancellable
/// work such as an image decode that completes after reconnect.
@MainActor
final class CameraWork {
    private(set) var generation: UInt64 = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isCurrent(_ token: UInt64) -> Bool { generation == token && !Task.isCancelled }

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID(), token = generation
        let task = Task { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            await operation()
            self.tasks.removeValue(forKey: id)
        }
        tasks[id] = task
        return task
    }

    func invalidate() {
        generation &+= 1
        let old = Array(tasks.values)
        tasks.removeAll()
        for task in old { task.cancel() }
    }
}
