import Foundation
import HaloCore

/// The worker's conversion logic, free of XPC so it can be tested in-process.
///
/// Each job runs `ConversionRunner` in staged mode under `<stagingRoot>/<jobID>/`, inside the worker's sandbox
/// container. The app then places the staged outputs and calls `discard(_:)`.
public actor WorkerEngine {
    public let stagingRoot: URL
    private let runner: ConversionRunner
    private var jobs: [String: (owner: UUID?, task: Task<WorkerReply, Never>)] = [:]

    public init(registry: ActionRegistry, stagingRoot: URL, limiter: ConcurrencyLimiter = .shared) {
        self.stagingRoot = stagingRoot
        self.runner = ConversionRunner(registry: registry, limiter: limiter)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        // Leftovers of a worker that crashed or was killed mid-job.
        TempSweeper.sweepStaging(stagingRoot)
    }

    /// The default staging folder: `<worker temp dir>/HaloStaging`, which is inside the sandbox container.
    public static var defaultStagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(HaloWorkerService.stagingFolderName, isDirectory: true)
    }

    public var runningJobs: Int { jobs.count }

    /// Jobs started by one connection.
    public func runningJobs(owner: UUID) -> Int { jobs.values.filter { $0.owner == owner }.count }

    public func run(_ request: WorkerRequest, owner: UUID? = nil, progress: @escaping @Sendable (Double) -> Void) async -> WorkerReply {
        func reject(_ message: String) -> WorkerReply {
            WorkerReply(jobID: request.jobID, staged: [], failures: [.init(input: nil, message: message)], durationSeconds: 0)
        }
        guard WorkerRequest.isValidJobID(request.jobID) else { return reject("Invalid job.") }
        guard jobs[request.jobID] == nil else { return reject("This job is already running.") }
        guard let inputs = request.inputFiles(), !inputs.isEmpty else { return reject("Frenzy didn't receive the files.") }

        let jobRoot = stagingRoot.appendingPathComponent(request.jobID, isDirectory: true)
        let runner = self.runner
        let task = Task {
            // The app holds an activity too, but this is a separate process: without its own, App Nap can slow a long
            // conversion to a crawl once Frenzy has no window on screen.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Converting files")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let outcome = await runner.run(request.actionID, on: inputs, stagingRoot: jobRoot, progress: progress)
            return WorkerReply(jobID: request.jobID, outcome: outcome)
        }
        jobs[request.jobID] = (owner, task)
        let reply = await task.value
        jobs[request.jobID] = nil
        if reply.staged.isEmpty { try? FileManager.default.removeItem(at: jobRoot) }
        return reply
    }

    public func cancel(_ jobID: String) { jobs[jobID]?.task.cancel() }

    public func cancelAll() { jobs.values.forEach { $0.task.cancel() } }

    /// Cancels the jobs of one connection (when it goes away).
    public func cancelAll(owner: UUID) { jobs.values.filter { $0.owner == owner }.forEach { $0.task.cancel() } }

    public func discard(_ jobID: String) {
        guard WorkerRequest.isValidJobID(jobID) else { return }
        try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(jobID, isDirectory: true))
    }
}
