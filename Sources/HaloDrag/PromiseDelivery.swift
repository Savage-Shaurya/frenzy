import AppKit
import HaloCore

/// A file another app has promised (Photos, Mail, a browser). Lets tests stand in for a real source app.
public protocol PromisedFileSource: AnyObject {
    /// How many files this will deliver.
    var promisedCount: Int { get }
    /// Asks the source to write its file(s) into `folder`. `reader` is called once per file, on `queue`.
    func deliver(into folder: URL, queue: OperationQueue, reader: @escaping @Sendable (URL, (any Error)?) -> Void)
}

extension NSFilePromiseReceiver: PromisedFileSource {
    public var promisedCount: Int { max(1, fileNames.count) }

    public func deliver(into folder: URL, queue: OperationQueue, reader: @escaping @Sendable (URL, (any Error)?) -> Void) {
        receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: reader)
    }
}

/// How a promised drop is going, so the app can show it. The source app may take a while: Photos may be fetching the
/// original from iCloud, and the conversion can't start until it's here.
/// `drop` names one drop, so two drops in quick succession each get their own card.
public enum PromiseDeliveryEvent {
    case began(drop: UUID, action: ActionID, count: Int, cancel: @MainActor () -> Void)
    case ended(drop: UUID, received: Int, expected: Int, cancelled: Bool)
    /// Frenzy couldn't make room for the files (the temp folder couldn't be written). Not the source app's fault.
    case couldNotReceive(drop: UUID, expected: Int)
}

/// Gathers one drop's deliveries (callbacks come on a background queue) and finishes exactly once: every file arrived,
/// or the timeout passed, or the user cancelled. A source app that never calls back can't leave the user waiting forever.
final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var finished = false
    private let isAcceptable: @Sendable (URL) -> Bool
    private let completion: @MainActor ([URL], Bool) -> Void
    /// Called (on the delivery queue) with a file that arrived after the drop finished: nothing will convert it.
    private let onLate: @Sendable (URL) -> Void
    /// The source apps' receivers. Held only until the drop finishes, so a finished drop doesn't keep them for the
    /// whole timeout.
    private var retained: [AnyObject] = []

    init(expected: Int, isAcceptable: @escaping @Sendable (URL) -> Bool, onLate: @escaping @Sendable (URL) -> Void = { _ in },
         completion: @escaping @MainActor ([URL], Bool) -> Void) {
        self.remaining = expected
        self.isAcceptable = isAcceptable
        self.onLate = onLate
        self.completion = completion
    }

    /// Keeps `objects` alive until the drop finishes.
    func retain(_ objects: [AnyObject]) {
        lock.withLock { if !finished { retained += objects } }
    }

    var retainedCount: Int { lock.withLock { retained.count } }
    var isFinished: Bool { lock.withLock { finished } }

    func add(_ url: URL?) {
        var late: URL?
        defer { if let late { onLate(late) } }
        let done: [URL]? = lock.withLock {
            guard !finished else {
                if let url, isAcceptable(url) { late = url }
                return nil
            }
            if let url, isAcceptable(url) { urls.append(url) }
            remaining -= 1
            guard remaining <= 0 else { return nil }
            finished = true
            retained = []
            return urls
        }
        if let done { deliver(done, cancelled: false) }
    }

    /// The timeout: go on with whatever has arrived.
    func expire() {
        let done: [URL]? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            retained = []
            return urls
        }
        if let done { deliver(done, cancelled: false) }
    }

    func cancel() {
        let first: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            retained = []
            return true
        }
        if first { deliver([], cancelled: true) }
    }

    private func deliver(_ urls: [URL], cancelled: Bool) {
        let completion = self.completion
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(urls, cancelled) } }
    }
}
