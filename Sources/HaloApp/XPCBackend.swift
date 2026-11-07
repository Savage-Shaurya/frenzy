import Foundation
import os
import HaloCore

/// Runs conversions in the sandboxed worker (`com.snappycrew.frenzy.worker.xpc`) and places the staged results next
/// to the originals, or in Downloads when they can't or shouldn't go there (`SavePolicy`).
///
/// - Progress comes back on the same connection (the app exports `HaloWorkerClientProtocol`); XPC delivers messages
///   in order, and the app clamps them to be monotonic.
/// - Cancelling the calling task sends `cancel(jobID)`; if the worker hasn't replied `cancelBackstop` later, the
///   connection is invalidated (the worker then cancels or exits) and the job fails as cancelled.
/// - If the worker dies (a parser bug, a bad file, the memory watchdog), `WorkerRecovery` works out which file did it:
///   the other jobs run again, alone, and only the cause fails, with a message saying why. The app never crashes with
///   it, and the next message relaunches the worker.
final class XPCConversionBackend: ConversionBackend, @unchecked Sendable {
    static let crashMessage = WorkerFailureText.crash
    static let cancelBackstop: Duration = .seconds(8)

    private let log = Logger(subsystem: "com.snappycrew.frenzy", category: "worker-client")
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: [String: PendingJob] = [:]
    private let sink = ProgressSink()
    private let recovery = WorkerRecovery()
    /// Says which actions convert each file on its own, so a batch can be retried per file. Nil retries it whole.
    private let registry: ActionRegistry?
    private let savePolicy: SavePolicy
    /// The app bundle as it was at launch: if it changed, a dead worker means an update, not a bad file.
    private let bundleStamp = AppBundleStamp(bundle: Bundle.main.bundleURL)

    init(registry: ActionRegistry? = nil, savePolicy: SavePolicy = .standard(inbox: PromiseInbox().root)) {
        self.registry = registry
        self.savePolicy = savePolicy
    }

    func run(_ actionID: ActionID, on inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void) async -> ConversionOutcome {
        let canSplit = registry?.action(actionID)?.cardinality == .each
        return await recovery.run(actionID, on: inputs, canSplit: canSplit, progress: progress) { [self] part, partProgress in
            await attempt(actionID, on: part, progress: partProgress)
        }
    }

    /// One trip to the worker: a fresh job ID (so a retry never collides with a dead attempt's staging) and, if it
    /// answers, placement of the results.
    private func attempt(_ actionID: ActionID, on inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void) async -> WorkerAttemptResult {
        let jobID = UUID().uuidString
        let request = WorkerRequest(jobID: jobID, actionID: actionID, inputs: inputs)
        let job = PendingJob()
        let started = Date()
        sink.register(jobID, progress)
        defer { sink.unregister(jobID) }

        let result: Result<WorkerReply, WorkerError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<WorkerReply, WorkerError>, Never>) in
                job.continuation = continuation
                // Cancelled before it was sent: don't start work nobody will collect.
                if Task.isCancelled { job.resume(.failure(.cancelled)); return }
                let live = currentConnection()
                job.connection = ObjectIdentifier(live)
                lock.withLock { pending[jobID] = job }
                let proxy = live.remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.log.error("worker message failed: \(error.localizedDescription, privacy: .public)")
                    let code = (error as NSError).code
                    job.resume(.failure(code == NSXPCConnectionInvalid ? .lost : .crashed))
                } as? any HaloWorkerProtocol
                proxy?.run(WorkerWire.encode(request)) { data in
                    if let reply = WorkerWire.decode(WorkerReply.self, from: data) { job.resume(.success(reply)) }
                    else { job.resume(.failure(.badReply)) }
                }
                if proxy == nil { job.resume(.failure(.lost)) }
            }
        } onCancel: {
            self.cancel(jobID, job: job)
        }
        lock.withLock { pending[jobID] = nil }

        switch result {
        case .success(let reply):
            defer { discardStaging(jobID) }
            let base = ConversionOutcome(actionID: actionID, outputs: reply.staged.map { URL(fileURLWithPath: $0.stagedPath) },
                                         staged: reply.staged, failures: reply.failures,
                                         duration: .milliseconds(Int(reply.durationSeconds * 1000)))
            if Task.isCancelled { return .finished(.init(actionID: actionID, outputs: [], failures: [Self.cancelledFailure], duration: base.duration)) }
            let staging = stagingFolder.appendingPathComponent(jobID)
            return .finished(StagedPlacement(allowedStagingRoot: staging, inputs: inputs, savePolicy: savePolicy).place(base))
        case .failure(let error):
            discardStaging(jobID)
            switch error {
            case .cancelled:
                return .finished(.failed(actionID, ConversionError.cancelled.errorDescription ?? "Cancelled."))
            case .badReply:
                return .finished(.failed(actionID, "Frenzy's converter sent an unreadable answer, so nothing was saved."))
            case .crashed, .lost:
                return .died(death(from: error, since: started))
            }
        }
    }

    /// What's most likely behind a dead attempt, most specific first.
    private func death(from error: WorkerError, since started: Date) -> WorkerDeath {
        if let bundleStamp, !bundleStamp.isUnchanged { return .appReplaced }
        if WorkerExitNote.memoryLimitHit(since: started, stagingRoot: stagingFolder) { return .memoryLimit }
        return error == .lost ? .connectionLost : .crashed
    }

    private var stagingFolder: URL {
        HaloWorkerService.containerDataURL().appendingPathComponent("tmp/\(HaloWorkerService.stagingFolderName)", isDirectory: true)
    }

    static let cancelledFailure = ConversionOutcome.Failure(input: nil, message: ConversionError.cancelled.errorDescription ?? "Cancelled.")

    /// Debug: asks the worker to probe its sandbox.
    func selfTest(timeout: Duration = .seconds(30)) async -> Result<WorkerSelfTest, WorkerError> {
        let job = SelfTestJob()
        return await withCheckedContinuation { (c: CheckedContinuation<Result<WorkerSelfTest, WorkerError>, Never>) in
            job.continuation = c
            let proxy = currentConnection().remoteObjectProxyWithErrorHandler { _ in job.resume(.failure(.crashed)) } as? any HaloWorkerProtocol
            proxy?.selfTest { data in
                if let r = WorkerWire.decode(WorkerSelfTest.self, from: data) { job.resume(.success(r)) } else { job.resume(.failure(.badReply)) }
            }
            if proxy == nil { job.resume(.failure(.crashed)) }
            Task { try? await Task.sleep(for: timeout); job.resume(.failure(.crashed)) }
        }
    }

    // MARK: Connection

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let c = NSXPCConnection(serviceName: HaloWorkerService.bundleIdentifier)
            c.remoteObjectInterface = NSXPCInterface(with: (any HaloWorkerProtocol).self)
            c.exportedInterface = NSXPCInterface(with: (any HaloWorkerClientProtocol).self)
            c.exportedObject = sink
            let id = ObjectIdentifier(c)
            // Interrupted = the worker process died. The connection stays usable; the next message relaunches it.
            c.interruptionHandler = { [weak self] in
                self?.log.error("worker interrupted (crashed or was killed); recovering its jobs")
                self?.failPending(on: id, .crashed)
            }
            // Invalidated = this connection is over: we dropped it, or the service can't be reached (the app was moved,
            // replaced or deleted while running). Jobs on any newer connection have nothing to do with it.
            c.invalidationHandler = { [weak self, weak c] in
                guard let self else { return }
                self.log.notice("worker connection invalidated")
                self.lock.withLock { if self.connection === c { self.connection = nil } }
                self.failPending(on: id, .lost)
            }
            c.resume()
            connection = c
            return c
        }
    }

    private func failPending(on connection: ObjectIdentifier, _ error: WorkerError) {
        let jobs = lock.withLock { pending.values.filter { $0.connection == connection } }
        jobs.forEach { $0.resume(.failure(error)) }
    }

    private func cancel(_ jobID: String, job: PendingJob) {
        let connection = lock.withLock { self.connection }
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? any HaloWorkerProtocol)?.cancel(jobID)
        let connectionID = connection.map(ObjectIdentifier.init)
        Task { [weak self] in
            try? await Task.sleep(for: Self.cancelBackstop)
            guard let self, !job.isDone else { return }
            self.log.error("worker ignored cancel for \(Self.cancelBackstop, privacy: .public); dropping the connection")
            job.resume(.failure(.cancelled))
            let stale = self.lock.withLock { () -> NSXPCConnection? in
                guard let current = self.connection, ObjectIdentifier(current) == connectionID else { return nil }
                self.connection = nil
                return current
            }
            // Other jobs on this connection get `.lost` from its invalidation handler and run again on a new one.
            stale?.invalidate()
        }
    }

    private func discardStaging(_ jobID: String) {
        let connection = lock.withLock { self.connection }
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? any HaloWorkerProtocol)?.discardStaging(jobID)
    }

    /// Drops the connection (at quit).
    func shutdown() {
        let c = lock.withLock { () -> NSXPCConnection? in defer { connection = nil }; return connection }
        c?.invalidate()
    }

    /// `crashed`: the process died under the job. `lost`: the connection was closed, which says nothing about the file.
    enum WorkerError: Error, Equatable { case cancelled, crashed, lost, badReply }
}

/// A continuation that resumes exactly once, whichever of reply / error handler / interruption / backstop wins.
final class PendingJob: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Result<WorkerReply, XPCConversionBackend.WorkerError>, Never>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }
    private var _continuation: CheckedContinuation<Result<WorkerReply, XPCConversionBackend.WorkerError>, Never>?
    /// The connection this job's message went out on.
    var connection: ObjectIdentifier? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
    private var _connection: ObjectIdentifier?
    private var done = false
    var isDone: Bool { lock.withLock { done } }

    func resume(_ result: Result<WorkerReply, XPCConversionBackend.WorkerError>) {
        let c: CheckedContinuation<Result<WorkerReply, XPCConversionBackend.WorkerError>, Never>? = lock.withLock {
            guard !done, let c = _continuation else { return nil }
            done = true
            _continuation = nil
            return c
        }
        c?.resume(returning: result)
    }
}

final class SelfTestJob: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Result<WorkerSelfTest, XPCConversionBackend.WorkerError>, Never>?

    func resume(_ result: Result<WorkerSelfTest, XPCConversionBackend.WorkerError>) {
        let c = lock.withLock { () -> CheckedContinuation<Result<WorkerSelfTest, XPCConversionBackend.WorkerError>, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: result)
    }
}

/// The app's exported object: routes worker progress to the job that asked for it.
final class ProgressSink: NSObject, HaloWorkerClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (Double) -> Void] = [:]

    func register(_ jobID: String, _ handler: @escaping @Sendable (Double) -> Void) { lock.withLock { handlers[jobID] = handler } }
    func unregister(_ jobID: String) { _ = lock.withLock { handlers.removeValue(forKey: jobID) } }

    func progress(_ jobID: String, fraction: Double) {
        guard fraction.isFinite else { return }
        let handler = lock.withLock { handlers[jobID] }
        handler?(min(1, max(0, fraction)))
    }
}
