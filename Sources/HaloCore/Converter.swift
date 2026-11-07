import Foundation

/// Does the actual work for one `ConversionAction`. Implementations must be offline-only:
/// no network access of any kind, and the original input files are never modified.
public protocol Converter: Sendable {
    /// Converts `job.inputs`. Write every output through `job.makeOutput(...)` and `commit()` it;
    /// anything left uncommitted is deleted by the runner. Check `Task.isCancelled` in long loops.
    func run(_ job: ConversionJob) async throws -> [URL]
}

/// Adapts a closure into a `Converter`, handy for small actions.
public struct ClosureConverter: Converter {
    private let body: @Sendable (ConversionJob) async throws -> [URL]
    public init(_ body: @escaping @Sendable (ConversionJob) async throws -> [URL]) { self.body = body }
    public func run(_ job: ConversionJob) async throws -> [URL] { try await body(job) }
}

/// Everything a converter needs for one run.
public struct ConversionJob: Sendable {
    public let actionID: ActionID
    public let inputs: [InputFile]
    /// Reports 0...1 progress. Safe to call from any thread; cheap to call often.
    public let progress: @Sendable (Double) -> Void
    /// Staged mode (the sandboxed worker): every output is written under this folder and placed by the app later.
    /// Nil = direct mode, outputs land next to the originals.
    public let stagingRoot: URL?
    let outputs: OutputLedger

    public init(actionID: ActionID, inputs: [InputFile], progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.init(actionID: actionID, inputs: inputs, stagingRoot: nil, progress: progress)
    }

    public init(actionID: ActionID, inputs: [InputFile], stagingRoot: URL?, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.actionID = actionID
        self.inputs = inputs
        self.progress = progress
        self.stagingRoot = stagingRoot
        self.outputs = OutputLedger()
    }

    /// Reserves an output next to `input` (or in `directory`). Write to `temporaryURL`, then call `commit()`.
    /// - Parameters:
    ///   - pathExtension: new extension without the dot, e.g. "jpg".
    ///   - suffix: label added to the name, e.g. "compressed" -> "report (compressed).pdf". Use one when the
    ///     extension does not change, so the output never looks like the original.
    public func makeOutput(for input: InputFile, pathExtension: String, suffix: String? = nil, directory: URL? = nil) throws -> OutputTarget {
        let dir = directory ?? input.url.deletingLastPathComponent()
        let base = input.url.deletingPathExtension().lastPathComponent
        return try reserve(directory: dir, baseName: base, suffix: suffix, pathExtension: pathExtension, isFolder: false)
    }

    /// Reserves an output folder (e.g. "report pages" for Split). Fill `temporaryURL` (already created, empty) with
    /// files, then `commit()`; the folder gets a free name ("report pages", "report pages 2"...). The folder is the
    /// job's single output, so the app reveals one item instead of hundreds of pages. Files reserved with
    /// `makeOutput(named:in: folder.temporaryURL, ...)` belong to the folder and are not counted separately.
    public func makeOutputFolder(named baseName: String, in directory: URL) throws -> OutputTarget {
        try reserve(directory: directory, baseName: baseName, suffix: nil, pathExtension: "", isFolder: true)
    }

    /// Reserves an output with an explicit base name (e.g. "Merged" for a combined PDF, or "report page 3").
    public func makeOutput(named baseName: String, in directory: URL, pathExtension: String, suffix: String? = nil) throws -> OutputTarget {
        try reserve(directory: directory, baseName: baseName, suffix: suffix, pathExtension: pathExtension, isFolder: false)
    }

    private func reserve(directory: URL, baseName: String, suffix: String?, pathExtension: String, isFolder: Bool) throws -> OutputTarget {
        // Inside the staging area (e.g. a page inside a staged output folder) the target behaves directly: it is
        // committed in place and travels with its folder.
        let staged = stagingRoot.flatMap { root in OutputLedger.isInside(directory, root) ? nil : root }
        let target = try OutputTarget(directory: directory, baseName: baseName, suffix: suffix,
                                      pathExtension: pathExtension, isFolder: isFolder, stagingRoot: staged)
        outputs.track(target)
        return target
    }

    /// Staged outputs committed so far (top level only). Empty in direct mode.
    public func stagedOutputs() -> [StagedOutput] { outputs.committedTargets().compactMap(\.stagedOutput) }
}

public enum ConversionError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedInput(String)
    case unreadable(URL)
    case writeFailed(URL, String)
    /// The folder can't take new files: read-only, or macOS isn't letting Frenzy write there.
    case folderNotWritable(URL)
    case engine(String)
    case cancelled

    /// Compress found nothing to gain. Not a failure: the file is fine as it is, and the app says so calmly.
    public static func alreadySmall(_ name: String) -> ConversionError {
        .engine("\(name) \(alreadySmallText)")
    }
    static let alreadySmallText = "is already as small as Frenzy can make it."
    public static func isAlreadySmall(_ message: String) -> Bool { message.hasSuffix(alreadySmallText) }

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let why): return "This file can't be converted that way. \(why)"
        case .unreadable(let url): return "Couldn't read \(url.lastPathComponent)."
        case .writeFailed(let url, let why): return "Couldn't save \(url.lastPathComponent). \(why)"
        case .folderNotWritable(let folder):
            return "Couldn't save in \"\(folder.lastPathComponent)\". It's read-only, or macOS isn't letting Frenzy write there."
        case .engine(let why): return why
        case .cancelled: return "Cancelled."
        }
    }
}
