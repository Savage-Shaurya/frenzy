import Foundation
import UniformTypeIdentifiers

/// Where files from Photos, Mail and browsers wait while they're converted. These apps only hand a file over once the
/// drop lands, so each drop gets its own folder under `root`; outputs go elsewhere (`SavePolicy`) and the copies are
/// removed when the job ends. Whatever a crash leaves is removed at the next launch.
public struct PromiseInbox: Sendable, Equatable {
    public let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Frenzy Promised Files", isDirectory: true)) {
        self.root = root
    }

    /// True for anything inside a drop folder. Compares paths only, so asking about a file on a stuck share can't hang.
    public func contains(_ url: URL) -> Bool { relativePath(of: url) != nil }

    /// The path below `root`, under either spelling of a temp folder ("/var/..." or "/private/var/...").
    private func relativePath(of url: URL) -> Substring? {
        let path = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if rootPath.hasPrefix("/private/") { rootPath.removeFirst("/private".count) }
        for prefix in [rootPath + "/", "/private" + rootPath + "/"] where path.hasPrefix(prefix) {
            return path.dropFirst(prefix.count)
        }
        return nil
    }

    /// How old a drop folder must be before the launch sweep removes it. Promised copies are private files from Mail,
    /// Photos or a browser, so what a crash leaves goes soon. No delivery runs across a launch, so nothing live is this old.
    public static let leftoverMaxAge: TimeInterval = 5 * 60

    /// A new drop folder. The inbox and each drop folder are 0700: other users on this Mac can't list or read the copies.
    public func makeDropFolder() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An inbox made by an older version, or with a looser umask: tighten it.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The choice for `urls` was cancelled or replaced, or nothing fits them: their promised copies will never convert.
    /// Removes the drop folders holding them, except a folder that also holds something in `keeping` (a running job's
    /// files, the choice now on screen). URLs outside the inbox are ignored.
    public func remove(abandoned urls: [URL], keeping: [URL] = []) {
        let kept = Set(keeping.compactMap(dropName(of:)))
        let abandoned = urls.filter { url in dropName(of: url).map { !kept.contains($0) } ?? false }
        remove(dropsHolding: abandoned)
    }

    private func dropName(of url: URL) -> String? {
        relativePath(of: url)?.split(separator: "/").first.map(String.init)
    }

    /// Saves image bytes carried directly on the pasteboard (no file, no promise). Written as they came: never parsed.
    public func save(imageData data: Data, typeIdentifier: String, name: String = "Dragged image") throws -> URL {
        let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        let url = try makeDropFolder().appendingPathComponent(name).appendingPathExtension(ext)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Removes the drop folders holding `urls`. URLs outside the inbox are ignored, so this can never touch a user's file.
    public func remove(dropsHolding urls: [URL]) {
        var folders = Set<String>()
        for url in urls {
            if let first = relativePath(of: url)?.split(separator: "/").first { folders.insert(String(first)) }
        }
        for name in folders where UUID(uuidString: name) != nil {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Removes one drop folder (a delivery that failed or was cancelled).
    public func remove(dropFolder: URL) {
        guard contains(dropFolder), UUID(uuidString: dropFolder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: dropFolder)
    }

    /// Removes drop folders older than `maxAge`: what a crash left behind (at launch).
    public func sweep(maxAge: TimeInterval = PromiseInbox.leftoverMaxAge, now: Date = Date()) {
        TempSweeper.sweepStaging(root, maxAge: maxAge, now: now)
    }

    /// Removes every drop folder (at quit, once jobs have stopped).
    public func removeAll() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}

/// What the ring offers for files that don't exist yet, only their promised types.
public enum PromisedChoices {
    /// The promised items as `InputFile`s with placeholder paths, for asking the registry what fits. Unknown types
    /// stay out: a guess could offer a conversion the file can't take.
    public static func inputs(forTypes identifiers: [String]) -> [InputFile] {
        identifiers.enumerated().compactMap { index, identifier in
            guard let type = UTType(identifier), type.conforms(to: .content) || type.conforms(to: .archive) else { return nil }
            return InputFile(url: URL(fileURLWithPath: "/promised/\(index)"), type: type)
        }
    }

    /// Conversions for a promised drag. Zip alone isn't offered: it fits anything, so a Mail message hovering over a
    /// mailbox would open a ring with nothing useful on it.
    public static func actions(forTypes identifiers: [String], registry: ActionRegistry, limit: Int = .max) -> [ConversionAction] {
        let inputs = inputs(forTypes: identifiers)
        guard inputs.count == identifiers.count, !inputs.isEmpty else { return [] }
        let actions = registry.actions(for: inputs, limit: limit)
        return actions.allSatisfy { $0.id == "archive.zip" } ? [] : actions
    }

    /// "1 image", "3 images", "2 videos", "4 files".
    public static func subject(forTypes identifiers: [String]) -> String {
        let types = identifiers.compactMap { UTType($0) }
        let count = identifiers.count
        let noun: String
        if !types.isEmpty, types.allSatisfy({ $0.conforms(to: .image) }) { noun = "image" }
        else if !types.isEmpty, types.allSatisfy({ $0.conforms(to: .movie) }) { noun = "video" }
        else { noun = "file" }
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    /// The real files can differ from what was promised: a Live Photo arrives as a picture and a movie. Keep what fits
    /// `action` rather than refusing everything, and report what was left out.
    public static func fitting(_ action: ConversionAction, inputs: [InputFile]) -> (kept: [InputFile], leftOut: Int) {
        if action.accepts(inputs) { return (inputs, 0) }
        let kept = inputs.filter { file in action.inputTypes.contains { file.type.conforms(to: $0) } }
        return (action.accepts(kept) ? kept : [], action.accepts(kept) ? inputs.count - kept.count : inputs.count)
    }
}

/// Failure wording that needs to know a little about the file.
public enum FailureText {
    /// A file in a folder macOS guards, and the worker couldn't read it: the fix is in System Settings, not the file.
    public static func explain(_ message: String, input: URL?) -> String {
        guard message.hasPrefix("Couldn't read"), let input, PrivacyFolders.isProtected(input.deletingLastPathComponent()) else { return message }
        return "\(message) macOS may be blocking Frenzy from this folder. You can allow it in System Settings > Privacy & Security > Files and Folders."
    }

    /// The card saved something but some files failed. It only counts them, so this says which and why.
    public static func partialFailure(_ failures: [ConversionOutcome.Failure]) -> (title: String, message: String)? {
        guard let first = failures.first else { return nil }
        let name = first.input?.lastPathComponent
        let reason = explain(first.message, input: first.input)
        let line = name.map { reason.contains($0) ? reason : "\($0): \(reason)" } ?? reason
        return failures.count == 1
            ? ("1 file couldn't be converted", line)
            : ("\(failures.count) files couldn't be converted", "First one: \(line)")
    }

    /// Why outputs ended up in the fallback folder.
    public static func redirectNotice(fallbackName: String, blocked: [String], inputCount: Int) -> (title: String, message: String) {
        let place = blocked.count == 1 ? "\"\(blocked[0])\"" : "the original folders"
        return ("Saved in \(fallbackName)",
                "Frenzy couldn't save in \(place): it's read-only, or macOS isn't letting Frenzy write there. "
                    + "\(inputCount == 1 ? "The new file is" : "The new files are") in \(fallbackName) instead.")
    }

    public static func nowhereToSave(fallbackName: String) -> String {
        "Frenzy can't save next to the original or in \(fallbackName), so it didn't start. Move the file to a folder you can change, or allow Frenzy in System Settings > Privacy & Security > Files and Folders."
    }
}

/// Retrying a job the Mac's sleep may have broken.
public enum WakeRetry {
    /// True when the job died with nothing to show, wasn't cancelled, and the Mac slept while it ran. Video encoders and
    /// file shares often fail on wake through no fault of the file. One retry only: the caller runs it once.
    public static func shouldRetry(_ outcome: ConversionOutcome, cancelled: Bool, sleptDuringJob: Bool) -> Bool {
        sleptDuringJob && !cancelled && outcome.outputs.isEmpty && !outcome.failures.isEmpty && !outcome.wasCancelled
            && !outcome.failures.allSatisfy { ConversionError.isAlreadySmall($0.message) }
    }
}
