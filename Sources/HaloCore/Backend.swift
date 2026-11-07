import Foundation
import UniformTypeIdentifiers

/// Where conversions run. The app uses the sandboxed XPC worker (`XPCConversionBackend` in HaloApp); tests and
/// debugging use `InProcessBackend`. Either way the returned outcome's `outputs` are FINAL files next to the
/// originals, and cancelling the calling task cancels the conversion.
public protocol ConversionBackend: Sendable {
    func run(_ actionID: ActionID, on inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void) async -> ConversionOutcome
}

/// Runs converters in this process.
/// - `staged: false`: converters write next to the originals directly (the pre-worker behaviour).
/// - `staged: true`: the exact worker pipeline without IPC: outputs are staged in a temp folder, then placed with
///   `StagedPlacement`, so tests cover the same code paths as the XPC worker.
public struct InProcessBackend: ConversionBackend {
    public let runner: ConversionRunner
    public let staged: Bool
    public let stagingParent: URL
    public let savePolicy: SavePolicy

    public init(runner: ConversionRunner, staged: Bool = false,
                stagingParent: URL = FileManager.default.temporaryDirectory.appendingPathComponent("HaloStaging", isDirectory: true),
                savePolicy: SavePolicy = .nextToOriginalsOnly) {
        self.runner = runner
        self.staged = staged
        self.stagingParent = stagingParent
        self.savePolicy = savePolicy
    }

    public func run(_ actionID: ActionID, on inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void) async -> ConversionOutcome {
        guard staged else { return await runner.run(actionID, on: inputs, progress: progress) }
        let jobRoot = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobRoot) }
        let outcome = await runner.run(actionID, on: inputs, stagingRoot: jobRoot, progress: progress)
        if Task.isCancelled { return .failed(actionID, ConversionError.cancelled.errorDescription!) }
        let placement = StagedPlacement(allowedStagingRoot: jobRoot, inputs: inputs, savePolicy: savePolicy)
        return placement.place(outcome)
    }
}

// MARK: - Wire format (app <-> worker), JSON in `Data`

/// One staged output: where the worker left it, and where the app should put it.
public struct StagedOutput: Codable, Sendable, Hashable {
    public let stagedPath: String
    /// Intended final folder (next to the original).
    public let directory: String
    public let baseName: String
    public let suffix: String?
    public let pathExtension: String
    public let isFolder: Bool

    public init(stagedPath: String, directory: String, baseName: String, suffix: String?, pathExtension: String, isFolder: Bool) {
        self.stagedPath = stagedPath
        self.directory = directory
        self.baseName = baseName
        self.suffix = suffix
        self.pathExtension = pathExtension
        self.isFolder = isFolder
    }
}

public struct WorkerRequest: Codable, Sendable, Equatable {
    public struct Input: Codable, Sendable, Equatable {
        public let path: String
        public let typeIdentifier: String
    }

    /// A UUID string; also the name of the job's staging folder.
    public let jobID: String
    public let actionID: ActionID
    public let inputs: [Input]

    public init(jobID: String, actionID: ActionID, inputs: [InputFile]) {
        self.jobID = jobID
        self.actionID = actionID
        self.inputs = inputs.map { Input(path: $0.url.path, typeIdentifier: $0.type.identifier) }
    }

    /// Inputs as `InputFile`s, or nil if any entry is malformed.
    public func inputFiles() -> [InputFile]? {
        var files: [InputFile] = []
        for input in inputs {
            guard input.path.hasPrefix("/"), !input.path.contains("\0"), let type = UTType(input.typeIdentifier) else { return nil }
            files.append(InputFile(url: URL(fileURLWithPath: input.path), type: type))
        }
        return files
    }

    /// Canonical upper-case UUID only, so a job ID can never be a path ("../x").
    public static func isValidJobID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString == id }
}

public struct WorkerReply: Codable, Sendable {
    public let jobID: String
    public let staged: [StagedOutput]
    public let failures: [ConversionOutcome.Failure]
    public let durationSeconds: Double

    public init(jobID: String, staged: [StagedOutput], failures: [ConversionOutcome.Failure], durationSeconds: Double) {
        self.jobID = jobID
        self.staged = staged
        self.failures = failures
        self.durationSeconds = durationSeconds
    }

    public init(jobID: String, outcome: ConversionOutcome) {
        let seconds = Double(outcome.duration.components.seconds) + Double(outcome.duration.components.attoseconds) / 1e18
        self.init(jobID: jobID, staged: outcome.staged, failures: outcome.failures, durationSeconds: seconds)
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public enum WorkerWire {
    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}
