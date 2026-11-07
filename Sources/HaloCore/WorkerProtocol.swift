import Foundation

/// The sandboxed conversion worker, `Halo.app/Contents/XPCServices/com.snappycrew.halo.worker.xpc`.
public enum HaloWorkerService {
    public static let bundleIdentifier = "com.snappycrew.frenzy.worker"
    /// Code-signing requirement the worker checks on every incoming connection. Ad-hoc builds have no team, so this
    /// pins the identifier; a Developer ID build should add `anchor apple generic and certificate leaf[subject.OU] = TEAM`.
    public static let clientRequirement = "identifier \"com.snappycrew.frenzy\""
    /// The worker's sandbox container data folder, as seen by the (unsandboxed) app.
    public static func containerDataURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data", isDirectory: true)
    }
    /// Name of the staging folder inside the worker's temporary directory.
    public static let stagingFolderName = "HaloStaging"
}

/// Messages the app sends to the worker. Payloads are JSON (`WorkerRequest` / `WorkerReply`) in `Data`, so the
/// interface stays tiny and nothing but plain data crosses the boundary.
@objc public protocol HaloWorkerProtocol {
    /// Runs one drop. `reply` gets a JSON `WorkerReply`. Progress arrives through `HaloWorkerClientProtocol`.
    func run(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Cancels a running job (no-op if unknown). Its `run` reply still arrives, with a "Cancelled." failure.
    func cancel(_ jobID: String)
    /// Deletes the job's staging folder once the app has placed (or given up on) its outputs.
    func discardStaging(_ jobID: String)
    /// Debug: probes what the sandbox allows (network, writes outside the container) and replies with JSON
    /// `WorkerSelfTest`.
    func selfTest(_ reply: @escaping @Sendable (Data) -> Void)
}

/// Messages the worker sends back to the app on the same connection (the reverse proxy).
@objc public protocol HaloWorkerClientProtocol {
    func progress(_ jobID: String, fraction: Double)
}

/// Result of the worker's sandbox probe.
public struct WorkerSelfTest: Codable, Sendable {
    public struct Probe: Codable, Sendable {
        public let name: String
        /// What a correctly sandboxed worker must see.
        public let expected: String
        public let observed: String
        public let pass: Bool

        public init(name: String, expected: String, observed: String, pass: Bool) {
            self.name = name
            self.expected = expected
            self.observed = observed
            self.pass = pass
        }
    }

    public let pid: Int32
    public let sandboxContainer: String?
    public let homeDirectory: String
    public let temporaryDirectory: String
    public let probes: [Probe]
    public var allPass: Bool { probes.allSatisfy(\.pass) }

    public init(pid: Int32, sandboxContainer: String?, homeDirectory: String, temporaryDirectory: String, probes: [Probe]) {
        self.pid = pid
        self.sandboxContainer = sandboxContainer
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.probes = probes
    }
}
