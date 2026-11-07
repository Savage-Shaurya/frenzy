import Foundation
import os
import HaloCore

private let log = Logger(subsystem: "com.snappycrew.frenzy.worker", category: "worker")

/// Accepts connections from Halo.app and wires each to a `WorkerConnectionHandler`.
public final class WorkerListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine: WorkerEngine

    public init(engine: WorkerEngine) { self.engine = engine }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only Halo itself may talk to the worker (bundled XPC services are private to their app anyway).
        connection.setCodeSigningRequirement(HaloWorkerService.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: (any HaloWorkerProtocol).self)
        connection.remoteObjectInterface = NSXPCInterface(with: (any HaloWorkerClientProtocol).self)
        let handler = WorkerConnectionHandler(engine: engine, connection: connection)
        connection.exportedObject = handler
        let engine = self.engine
        let owner = handler.id
        connection.invalidationHandler = {
            // The app quit, crashed or gave up on us: stop everything. If a converter ignores cancellation (stuck
            // in a parser), exit so launchd starts a fresh worker next time.
            log.notice("connection invalidated; cancelling jobs")
            Task {
                await engine.cancelAll(owner: owner)
                try? await Task.sleep(for: .seconds(5))
                if await engine.runningJobs(owner: owner) > 0 {
                    log.error("jobs ignored cancellation; exiting")
                    exit(0)
                }
            }
        }
        connection.resume()
        return true
    }
}

/// One connection's exported object.
final class WorkerConnectionHandler: NSObject, HaloWorkerProtocol, @unchecked Sendable {
    let id = UUID()
    private let engine: WorkerEngine
    private weak var connection: NSXPCConnection?

    init(engine: WorkerEngine, connection: NSXPCConnection) {
        self.engine = engine
        self.connection = connection
    }

    func run(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = WorkerWire.decode(WorkerRequest.self, from: request) else {
            reply(WorkerReply(jobID: "", staged: [], failures: [.init(input: nil, message: "Invalid request.")], durationSeconds: 0).encoded())
            return
        }
        let client = connection?.remoteObjectProxyWithErrorHandler { _ in } as? any HaloWorkerClientProtocol
        let sink = ClientProgress(client: client, jobID: decoded.jobID)
        let engine = self.engine
        let owner = id
        Task {
            let result = await engine.run(decoded, owner: owner) { sink.send($0) }
            reply(result.encoded())
        }
    }

    func cancel(_ jobID: String) {
        let engine = self.engine
        Task { await engine.cancel(jobID) }
    }

    func discardStaging(_ jobID: String) {
        let engine = self.engine
        Task { await engine.discard(jobID) }
    }

    func selfTest(_ reply: @escaping @Sendable (Data) -> Void) {
        Task.detached {
            let result = await SandboxProbe.run()
            reply(WorkerWire.encode(result))
        }
    }
}

/// Forwards progress to the app at most every 1% (XPC messages are ordered per connection).
final class ClientProgress: @unchecked Sendable {
    private let client: (any HaloWorkerClientProtocol)?
    private let jobID: String
    private let lock = NSLock()
    private var last = -1.0

    init(client: (any HaloWorkerClientProtocol)?, jobID: String) {
        self.client = client
        self.jobID = jobID
    }

    func send(_ fraction: Double) {
        let ok: Bool = lock.withLock {
            guard fraction - last >= 0.01 || (fraction >= 1 && last < 1) else { return false }
            last = fraction
            return true
        }
        if ok { client?.progress(jobID, fraction: fraction) }
    }
}

/// Kills the worker if its memory footprint passes `limit` (decompression bombs, runaway parsers), long before the
/// system starts swapping. The app sees the connection drop and reports a friendly failure.
public enum MemoryWatchdog {
    nonisolated(unsafe) private static var timer: (any DispatchSourceTimer)?

    public static var defaultLimit: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        return max(2 << 30, min(physical / 2, 12 << 30))
    }

    /// - Parameter stagingRoot: where to leave the note that tells the app why this process is about to end.
    public static func start(limit: UInt64 = defaultLimit, stagingRoot: URL = WorkerEngine.defaultStagingRoot) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "halo.worker.watchdog", qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler {
            check(footprint: currentFootprint(), limit: limit, stagingRoot: stagingRoot) { _exit(70) }
        }
        t.resume()
        timer = t
    }

    /// Over the limit: leave the note first (the app reads it once this process is gone), then end. A note, not an XPC
    /// message: a message could be lost as the process exits.
    static func check(footprint: UInt64?, limit: UInt64, stagingRoot: URL, exit: () -> Void) {
        guard let footprint, footprint > limit else { return }
        log.error("memory footprint \(footprint, privacy: .public) over limit \(limit, privacy: .public); exiting")
        WorkerExitNote.writeMemoryMarker(inStagingRoot: stagingRoot)
        exit()
    }

    public static func currentFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
