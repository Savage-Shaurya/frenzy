import Foundation

/// Why the worker stopped answering a job.
public enum WorkerDeath: Sendable, Equatable {
    /// The process died: a parser bug, a bad file, or something killed it.
    case crashed
    /// The memory watchdog ended it (`MemoryWatchdog`).
    case memoryLimit
    /// The connection was closed under the job. Nothing suggests the file is at fault.
    case connectionLost
    /// Frenzy's own bundle changed on disk while it ran: an update, a rebuild, or the app was moved or deleted.
    case appReplaced
}

public enum WorkerAttemptResult: Sendable {
    /// The worker answered and the results were placed (or the job was cancelled).
    case finished(ConversionOutcome)
    case died(WorkerDeath)
}

/// What the user reads when the worker dies. Plain words, and honest about what we know: a crash can't prove a file is
/// damaged, and a memory death has nothing to do with damage.
public enum WorkerFailureText {
    public static let crash = "Frenzy's converter stopped while reading this file, so nothing was saved. The file may be damaged."
    public static let memory = "This file needs more memory than Frenzy can safely use on this Mac, so nothing was saved. Your original is untouched. Try a smaller copy."
    public static let replaced = "Frenzy was updated or moved while this was running, so nothing was saved. Open Frenzy again and try once more."
    public static let lost = "Frenzy lost touch with its converter, so nothing was saved. Your original is untouched. Try again."

    /// `name` is set when the file is one of a batch, so the message says which one.
    public static func message(for death: WorkerDeath, name: String? = nil) -> String {
        switch death {
        case .crashed:
            return name.map { "Frenzy's converter stopped while reading \($0), so that file wasn't saved. It may be damaged." } ?? crash
        case .memoryLimit:
            return name.map { "\($0) needs more memory than Frenzy can safely use on this Mac, so it wasn't saved. Try a smaller copy." } ?? memory
        case .appReplaced: return replaced
        case .connectionLost: return lost
        }
    }
}

/// Recovers from a worker death so one bad file costs only itself.
///
/// All running jobs share one worker process, so a crash kills them all and nobody can say which file did it. So:
/// - a job that was alone with one file IS the cause: it fails at once with a clear message;
/// - anything else runs again, once, alone: a job of many files one file at a time. What dies alone is the cause; the
///   rest finish. This also rescues batches that only ran out of memory because they ran in parallel.
///
/// `WorkerGate` keeps each retry alone: normal jobs wait while a retry is queued or running. Everything here is
/// transport-free so tests can drive it with a fake worker.
public final class WorkerRecovery: Sendable {
    public typealias Attempt = @Sendable (_ inputs: [InputFile], _ progress: @escaping @Sendable (Double) -> Void) async -> WorkerAttemptResult

    private let gate = WorkerGate()

    public init() {}

    /// - Parameter canSplit: the action converts each file on its own, so a batch can be retried per file.
    public func run(_ actionID: ActionID, on inputs: [InputFile], canSplit: Bool,
                    progress: @escaping @Sendable (Double) -> Void, attempt: Attempt) async -> ConversionOutcome {
        let clamped = MonotonicProgress(progress)
        guard let ticket = await gate.enter(exclusive: false) else { return Self.cancelled(actionID) }
        let first = await attempt(inputs, { clamped.report($0) })
        let hadCompany = await gate.leave(ticket)

        guard case .died(let death) = first else {
            if case .finished(let outcome) = first { return outcome }
            return Self.cancelled(actionID)
        }
        if Task.isCancelled { return Self.cancelled(actionID) }

        let splittable = canSplit && inputs.count > 1
        let solo = !hadCompany && !splittable && death != .connectionLost
        if solo || death == .appReplaced {
            return .failed(actionID, WorkerFailureText.message(for: death))
        }

        let parts = splittable ? inputs.map { [$0] } : [inputs]
        var outputs: [URL] = []
        var redirected: [URL] = []
        var failures: [ConversionOutcome.Failure] = []
        var duration = Duration.zero
        for (index, part) in parts.enumerated() {
            guard !Task.isCancelled, let retryTicket = await gate.enter(exclusive: true) else { break }
            let share = 1 / Double(parts.count), base = Double(index) * share
            let result = await attempt(part, { clamped.report(base + $0 * share) })
            _ = await gate.leave(retryTicket)
            switch result {
            case .finished(let outcome):
                outputs += outcome.outputs
                redirected += outcome.redirected
                // Cancelled partway: the files that didn't run aren't failures.
                failures += outcome.failures.filter { $0.message != ConversionError.cancelled.errorDescription }
                duration += outcome.duration
            case .died(let again):
                let name = parts.count > 1 ? part.first?.url.lastPathComponent : nil
                failures.append(.init(input: part.count == 1 ? part[0].url : nil,
                                      message: WorkerFailureText.message(for: again, name: name)))
            }
        }
        if outputs.isEmpty && failures.isEmpty { return Self.cancelled(actionID) }
        return ConversionOutcome(actionID: actionID, outputs: outputs, failures: failures, duration: duration, redirected: redirected)
    }

    private static func cancelled(_ actionID: ActionID) -> ConversionOutcome {
        .failed(actionID, ConversionError.cancelled.errorDescription ?? "Cancelled.")
    }
}

/// A newest-max filter: retried work never moves a job's bar backwards.
private final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var best = 0.0
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func report(_ fraction: Double) {
        lock.withLock {
            guard fraction > best else { return }
            best = fraction
            report(fraction)
        }
    }
}

/// Lets normal jobs share the worker, and lets one retry have it to itself. First come, first served, so a retry isn't
/// starved by new drops, and a new drop never joins a retry (it could be blamed for a crash that isn't its own).
actor WorkerGate {
    private struct Waiter {
        let id: UUID
        let exclusive: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Attempts inside now, and whether each has shared the worker with another.
    private var inside: [UUID: Bool] = [:]
    private var exclusiveInside = false
    private var waiters: [Waiter] = []

    /// Waits for a turn. Returns the ticket for `leave`, or nil if the task was cancelled while waiting.
    func enter(exclusive: Bool) async -> UUID? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        if waiters.isEmpty, canEnter(exclusive: exclusive) {
            admit(id, exclusive: exclusive)
            return id
        }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, exclusive: exclusive, continuation: continuation))
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return admitted ? id : nil
    }

    /// Returns true if this attempt ever shared the worker with another.
    func leave(_ id: UUID) -> Bool {
        let hadCompany = inside.removeValue(forKey: id) ?? false
        if inside.isEmpty { exclusiveInside = false }
        wake()
        return hadCompany
    }

    private func canEnter(exclusive: Bool) -> Bool {
        exclusive ? inside.isEmpty : !exclusiveInside
    }

    private func admit(_ id: UUID, exclusive: Bool) {
        if !inside.isEmpty { for key in inside.keys { inside[key] = true } }
        inside[id] = !inside.isEmpty
        if exclusive { exclusiveInside = true }
    }

    private func wake() {
        while let head = waiters.first, canEnter(exclusive: head.exclusive) {
            waiters.removeFirst()
            admit(head.id, exclusive: head.exclusive)
            head.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
        wake()
    }
}

/// The note the memory watchdog leaves just before ending the worker, so the app can tell that death from a crash.
/// Only the file's date is ever read: the worker is not trusted to write anything the app parses.
public enum WorkerExitNote {
    public static let memoryMarkerName = ".memory-limit"

    public static func memoryMarker(inStagingRoot root: URL) -> URL {
        root.appendingPathComponent(memoryMarkerName)
    }

    public static func writeMemoryMarker(inStagingRoot root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data().write(to: memoryMarker(inStagingRoot: root))
    }

    /// True when the watchdog fired after `since`.
    public static func memoryLimitHit(since: Date, stagingRoot: URL) -> Bool {
        let url = memoryMarker(inStagingRoot: stagingRoot)
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return date >= since.addingTimeInterval(-1)
    }
}

/// A fingerprint of the app bundle taken at launch. If it changes, a dead worker is explained by an update, not a file.
public struct AppBundleStamp: Sendable, Equatable {
    private let inode: UInt64
    private let modified: Date
    private let bundle: URL

    /// Nil for anything that isn't a bundle (`swift run`, tests): such a build can't be "replaced".
    public init?(bundle: URL) {
        guard bundle.pathExtension == "app" else { return nil }
        guard let (inode, modified) = Self.fingerprint(bundle) else { return nil }
        self.bundle = bundle
        self.inode = inode
        self.modified = modified
    }

    public var isUnchanged: Bool {
        guard let (inode, modified) = Self.fingerprint(bundle) else { return false }
        return inode == self.inode && modified == self.modified
    }

    private static func fingerprint(_ bundle: URL) -> (UInt64, Date)? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: plist),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (inode.uint64Value, modified)
    }
}
