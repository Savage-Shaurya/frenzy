import Foundation

/// Outcome of running one action on one drop.
public struct ConversionOutcome: Sendable {
    public let actionID: ActionID
    /// Top-level outputs. A folder output ("report pages") is ONE entry. In staged mode these are staged files; a
    /// `ConversionBackend` returns final, placed URLs.
    public let outputs: [URL]
    /// Staged-mode placement data, one per output. Empty in direct mode.
    public let staged: [StagedOutput]
    /// Per-input failures for `.each` actions; a single entry for `.combined` ones.
    public let failures: [Failure]
    public let duration: Duration
    /// Outputs saved in the fallback folder because they couldn't, or shouldn't, go next to the original.
    public let redirected: [URL]

    public struct Failure: Sendable, Codable, Equatable {
        public let input: URL?
        public let message: String
        public init(input: URL?, message: String) {
            self.input = input
            self.message = message
        }
    }

    public init(actionID: ActionID, outputs: [URL], staged: [StagedOutput] = [], failures: [Failure], duration: Duration,
                redirected: [URL] = []) {
        self.redirected = redirected
        self.actionID = actionID
        self.outputs = outputs
        self.staged = staged
        self.failures = failures
        self.duration = duration
    }

    public var succeeded: Bool { failures.isEmpty && !outputs.isEmpty }
    /// True when every failure is a cancellation (and nothing was produced).
    public var wasCancelled: Bool {
        outputs.isEmpty && !failures.isEmpty && failures.allSatisfy { $0.message == ConversionError.cancelled.errorDescription }
    }

    public static func failed(_ id: ActionID, _ message: String, input: URL? = nil) -> ConversionOutcome {
        ConversionOutcome(actionID: id, outputs: [], failures: [.init(input: input, message: message)], duration: .zero)
    }
}

/// Runs actions with cleanup, cancellation and bounded parallelism.
///
/// Parallelism has two bounds: `maxConcurrent` parts per drop, and the process-wide `ConcurrencyLimiter` (heavy
/// parts take 2 slots), which applies across every drop in flight.
///
/// The runner does not record usage: the app records a use only after a conversion produced something.
public actor ConversionRunner {
    private let registry: ActionRegistry
    private let maxConcurrent: Int
    private let limiter: ConcurrencyLimiter

    public init(registry: ActionRegistry,
                maxConcurrent: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 2),
                limiter: ConcurrencyLimiter = .shared) {
        self.registry = registry
        self.maxConcurrent = max(1, maxConcurrent)
        self.limiter = limiter
    }

    /// Runs `actionID` on `inputs`, writing outputs next to the originals. `.each` actions run once per file (in
    /// parallel, bounded); `.combined` ones run once.
    public func run(_ actionID: ActionID, on inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConversionOutcome {
        await run(actionID, on: inputs, stagingRoot: nil, progress: progress)
    }

    /// Like `run(_:on:progress:)`; with a `stagingRoot` every output is staged under it (see `OutputTarget`).
    public func run(_ actionID: ActionID, on inputs: [InputFile], stagingRoot: URL?,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConversionOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard let action = registry.action(actionID) else { return .failed(actionID, "Unknown action.") }
        guard action.accepts(inputs) else { return .failed(actionID, "These files don't fit \(action.title).") }

        let groups: [[InputFile]]
        switch action.cardinality {
        case .each: groups = inputs.map { [$0] }
        case .combined: groups = [inputs]
        }

        let tracker = ProgressTracker(parts: groups.count, report: progress)
        let limiter = self.limiter
        var outputs: [URL] = []
        var staged: [StagedOutput] = []
        var failures: [ConversionOutcome.Failure] = []

        typealias PartResult = Result<(urls: [URL], staged: [StagedOutput]), any Error>
        await withTaskGroup(of: (Int, PartResult).self) { group in
            var next = 0
            func add(_ i: Int) {
                let files = groups[i]
                let weight = action.slotWeight(for: files)
                group.addTask {
                    let job = ConversionJob(actionID: actionID, inputs: files, stagingRoot: stagingRoot) {
                        tracker.update(part: i, fraction: $0)
                    }
                    do {
                        let result = try await limiter.withSlots(weight) {
                            try Task.checkCancellation()
                            _ = try await action.converter.run(job)
                            try Task.checkCancellation()
                            return (job.outputs.committed(), job.stagedOutputs())
                        }
                        job.outputs.discardUncommitted()
                        if result.0.isEmpty { throw ConversionError.engine("Frenzy couldn't make a new file from this.") }
                        tracker.update(part: i, fraction: 1)
                        return (i, .success((result.0, result.1)))
                    } catch {
                        job.outputs.discardUncommitted()
                        // Remove partial results of a failed part so a failure never leaves half a batch item behind.
                        for url in job.outputs.committed() { try? FileManager.default.removeItem(at: url) }
                        let cancelled = error is CancellationError || (error as? ConversionError) == .cancelled
                        return (i, .failure(cancelled ? ConversionError.cancelled : error))
                    }
                }
            }
            while next < min(maxConcurrent, groups.count) { add(next); next += 1 }
            for await (i, result) in group {
                switch result {
                case .success(let part):
                    outputs.append(contentsOf: part.urls)
                    staged.append(contentsOf: part.staged)
                case .failure(let error):
                    failures.append(.init(input: groups[i].count == 1 ? groups[i][0].url : nil,
                                          message: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
                if next < groups.count { add(next); next += 1 }
            }
        }
        return ConversionOutcome(actionID: actionID, outputs: outputs, staged: staged, failures: failures,
                                 duration: clock.now - start)
    }
}

/// Combines per-part progress into one 0...1 value that never goes backwards.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private var lastReported = 0.0
    private let report: @Sendable (Double) -> Void

    init(parts: Int, report: @escaping @Sendable (Double) -> Void) {
        self.fractions = Array(repeating: 0, count: max(1, parts))
        self.report = report
    }

    /// Reports while holding the lock, so concurrent parts can never deliver an older total after a newer one.
    func update(part: Int, fraction: Double) {
        lock.withLock {
            guard fractions.indices.contains(part), fraction.isFinite else { return }
            fractions[part] = min(1, max(fractions[part], fraction))
            let total = fractions.reduce(0, +) / Double(fractions.count)
            guard total > lastReported else { return }
            lastReported = total
            report(total)
        }
    }
}
