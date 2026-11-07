import Foundation
import UniformTypeIdentifiers

/// Stable identifier for a conversion action, e.g. "image.to-jpg". Persisted in usage stats, so never rename one.
public struct ActionID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Which family an action belongs to. Drives the ring's colour accents and default ordering.
public enum ActionCategory: String, Sendable, CaseIterable, Codable {
    case image, pdf, video, audio, document, text, archive
}

/// How many input files an action needs.
public enum InputCardinality: Sendable, Equatable {
    /// Each file is converted on its own (batch drops run the action once per file).
    case each
    /// All files are combined into one output (e.g. merge PDFs). Needs at least `min` files.
    case combined(min: Int)
}

/// One choice on the ring, e.g. "JPG" for a HEIC photo.
public struct ConversionAction: Sendable, Identifiable {
    public let id: ActionID
    /// Short label shown on the ring segment ("JPG", "Compress").
    public let title: String
    /// Optional second line ("Smaller file", "Per page").
    public let subtitle: String?
    /// SF Symbol name for the segment icon.
    public let symbolName: String
    public let category: ActionCategory
    /// Inputs must conform to at least one of these types.
    public let inputTypes: [UTType]
    public let cardinality: InputCardinality
    /// Lower = shown earlier before the user has any usage history.
    public let defaultRank: Int
    public let converter: any Converter

    public init(
        id: ActionID,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        category: ActionCategory,
        inputTypes: [UTType],
        cardinality: InputCardinality = .each,
        defaultRank: Int = 100,
        converter: any Converter
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.category = category
        self.inputTypes = inputTypes
        self.cardinality = cardinality
        self.defaultRank = defaultRank
        self.converter = converter
    }

    /// True when every input matches `inputTypes` and the file count fits `cardinality`.
    public func accepts(_ inputs: [InputFile]) -> Bool {
        guard !inputs.isEmpty else { return false }
        return accepts(types: Set(inputs.map(\.type)), count: inputs.count)
    }

    /// `accepts` over the distinct types of a selection. Conformance checks are slow enough that doing them per file
    /// per action froze the ring for a few thousand files, while a real selection only has a handful of types.
    func accepts(types: Set<UTType>, count: Int) -> Bool {
        guard count > 0 else { return false }
        let typesOK = types.allSatisfy { type in inputTypes.contains { type.conforms(to: $0) } }
        switch cardinality {
        case .each: return typesOK
        case .combined(let min): return typesOK && count >= min
        }
    }
}

/// A dropped file with its resolved content type.
public struct InputFile: Sendable, Hashable {
    public let url: URL
    public let type: UTType

    public init(url: URL, type: UTType) {
        self.url = url
        self.type = type
    }

    /// Resolves the type from the file's metadata, falling back to its extension. Nil for unknown items. A plain folder
    /// resolves as `public.folder`, so only actions that take any item (Zip) fit it.
    public init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return nil }
        self.init(url: url, type: type)
    }

    /// Cheap variant for very large selections: the type comes from the extension only, with no file-system call.
    /// Nil when the extension is missing or unknown.
    public init?(extensionOf url: URL) {
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        self.init(url: url, type: type)
    }

    /// From the name alone: never touches the disk, so it can't stall on a slow or dead volume. A directory URL is a
    /// folder, unless its extension says otherwise (a package).
    public init?(nameOf url: URL) {
        if !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension) {
            self.init(url: url, type: type)
        } else if url.hasDirectoryPath {
            self.init(url: url, type: .folder)
        } else {
            return nil
        }
    }

    /// `resolve`, for the main thread: it never waits longer than `budget`. A network share that has gone away, or one
    /// taking its time, can't freeze a drag: past the budget, types come from the names alone.
    public static func resolveWithin(_ budget: TimeInterval, _ urls: [URL], inspectLimit: Int = 50, gate: ResolveGate = .shared,
                                     inspect: @escaping @Sendable ([URL], Int) -> [InputFile] = { InputFile.resolve($0, inspectLimit: $1) }) -> [InputFile] {
        resolveWithinBudget(budget, urls, inspectLimit: inspectLimit, gate: gate, inspect: inspect).inputs
    }

    /// `resolveWithin`, also saying whether the disk answered. `complete` is false when the types came from the names
    /// alone, so an item the names can't place (a folder with no trailing slash, a file with no extension) may still be
    /// convertible: the caller must not say "can't convert" then.
    ///
    /// Checks run one at a time on `gate`'s serial queue. While one is still stuck on a dead share, a new summon doesn't
    /// queue up behind it (or pile up blocked threads): it goes straight to the names.
    public static func resolveWithinBudget(_ budget: TimeInterval, _ urls: [URL], inspectLimit: Int = 50, gate: ResolveGate = .shared,
                                           inspect: @escaping @Sendable ([URL], Int) -> [InputFile] = { InputFile.resolve($0, inspectLimit: $1) })
        -> (inputs: [InputFile], complete: Bool) {
        let byName = { urls.compactMap(InputFile.init(nameOf:)) }
        guard gate.tryEnter() else { return (byName(), false) }
        let box = ResolveBox()
        let done = DispatchSemaphore(value: 0)
        gate.queue.async {
            box.set(inspect(urls, inspectLimit))
            gate.leave()
            done.signal()
        }
        if done.wait(timeout: .now() + budget) == .success, let inspected = box.value { return (inspected, true) }
        return (byName(), false)
    }

    /// Resolves `urls`, inspecting at most `inspectLimit` of them on disk; the rest use the extension fast path.
    /// Items without an extension (usually folders) are always inspected, so a big drop never loses its folders.
    public static func resolve(_ urls: [URL], inspectLimit: Int = 50) -> [InputFile] {
        urls.prefix(inspectLimit).compactMap(InputFile.init(url:))
            + urls.dropFirst(inspectLimit).compactMap { $0.pathExtension.isEmpty ? InputFile(url: $0) : InputFile(extensionOf: $0) }
    }
}

/// One disk check at a time for `InputFile.resolveWithin`: a serial queue and a busy flag.
public final class ResolveGate: @unchecked Sendable {
    public static let shared = ResolveGate()
    let queue: DispatchQueue
    private let lock = NSLock()
    private var busy = false

    public init(label: String = "com.snappycrew.frenzy.resolve") {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// True while a check is still running (for tests and logs).
    public var isBusy: Bool { lock.withLock { busy } }

    func tryEnter() -> Bool {
        lock.withLock {
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    func leave() { lock.withLock { busy = false } }
}

private final class ResolveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var inspected: [InputFile]?
    func set(_ value: [InputFile]) { lock.withLock { inspected = value } }
    var value: [InputFile]? { lock.withLock { inspected } }
}
