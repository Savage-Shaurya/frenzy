import Foundation

/// Runs blocking document work (TextKit import, layout, PDF drawing) on one dedicated serial queue, off Swift's
/// cooperative pool, and bridges it back with a checked continuation.
///
/// Cancellation: the calling task's cancellation flips a `DocumentCancellation` flag that the blocking body polls in
/// its loops (per page while paginating and drawing). Work queued behind a cancelled job is skipped before it starts.
enum DocumentWorker {
    private static let queue = DispatchQueue(label: "app.halo.document-worker", qos: .userInitiated)

    static func run<T: Sendable>(_ body: @escaping @Sendable (DocumentCancellation) throws -> T) async throws -> T {
        let flag = DocumentCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    do {
                        try flag.check()
                        continuation.resume(returning: try body(flag))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// Thread-safe cancellation flag polled by blocking document code.
final class DocumentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init(cancelled: Bool = false) { self.cancelled = cancelled }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// Lets only one HTML import run at a time (WebKit-backed import spins a nested main run loop; overlapping imports
/// would stack those loops). FIFO; a waiter cancelled while queued gives up its turn.
actor HTMLImportGate {
    static let shared = HTMLImportGate()

    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func withTurn<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }
}
