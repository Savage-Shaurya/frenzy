import Foundation

/// A weighted, FIFO, cancellable semaphore shared by every conversion in the process, so ten drops at once don't
/// start ten video encodes. Heavy work (video, PDF rendering, very large images) takes 2 slots.
///
/// In the app the conversions run in the sandboxed worker, which is one process for all drops, so `shared` there
/// bounds work across ALL drops, not per drop.
public actor ConcurrencyLimiter {
    public static let shared = ConcurrencyLimiter(capacity: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    public let capacity: Int
    private var inUse = 0
    private var waiters: [(id: UUID, weight: Int, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Slots currently held (for tests and diagnostics).
    public var used: Int { inUse }

    /// Runs `body` while holding `weight` slots (clamped to 1...capacity). Throws `CancellationError` if the task is
    /// cancelled while waiting; a cancelled waiter gives up its place in the queue.
    public func withSlots<T: Sendable>(_ weight: Int, _ body: @Sendable () async throws -> T) async throws -> T {
        let w = min(max(1, weight), capacity)
        try await acquire(w)
        defer { release(w) }
        return try await body()
    }

    private func acquire(_ weight: Int) async throws {
        try Task.checkCancellation()
        if waiters.isEmpty && inUse + weight <= capacity {
            inUse += weight
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                waiters.append((id, weight, c))
                // The task may have been cancelled between the check above and enqueueing.
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
        wake()
    }

    private func release(_ weight: Int) {
        inUse = max(0, inUse - weight)
        wake()
    }

    /// Strict FIFO: the head waiter goes first, so a heavy job is never starved by a stream of light ones.
    private func wake() {
        while let head = waiters.first, inUse + head.weight <= capacity {
            waiters.removeFirst()
            inUse += head.weight
            head.continuation.resume()
        }
    }
}

public extension ConversionAction {
    /// Limiter slots one part of this action takes. Video work and PDF page rendering are heavy, and so is any
    /// image above `largeImageBytes`.
    func slotWeight(for inputs: [InputFile]) -> Int {
        switch category {
        case .video: return 2
        case .pdf where id == "pdf.to-images" || id == "pdf.to-text": return 2
        case .image:
            let bytes = inputs.reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return bytes > Self.largeImageBytes ? 2 : 1
        default: return 1
        }
    }

    static let largeImageBytes = 40 * 1024 * 1024
}
