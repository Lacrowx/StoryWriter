import Foundation

// Actor isolation alone does not serialize work across suspension points.
// Cancelled waiters must leave the queue without waiting for GPU generation.
actor MLXOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiting: [Waiter] = []
    var waitingCount: Int { waiting.count }

    func withAccess<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if occupied {
                    waiting.append(Waiter(id: id, continuation: continuation))
                } else {
                    occupied = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancellation can race with release granting this request ownership.
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().continuation.resume() }
    }
}
