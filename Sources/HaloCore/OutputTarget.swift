import Foundation

/// A reserved output file. Converters write to `temporaryURL` and then call `commit()`.
///
/// Two modes, same API for converters:
/// - **Direct** (in-process, tests): `temporaryURL` is a hidden `.halo-<uuid>` file in the final folder, and `commit()`
///   atomically renames it to a free final name next to the original ("photo.jpg", then "photo 2.jpg", ...).
/// - **Staged** (the sandboxed worker): the worker may not write next to the original, so `temporaryURL` lives in a
///   per-job staging folder and `commit()` only moves it to a staged name inside that folder. The target keeps the
///   intended final `directory`, `baseName`, `suffix`, `pathExtension` and `isFolder`, which travel back to the app
///   as a `StagedOutput`; the app does the final never-overwrite placement (`StagedPlacement`).
///
/// Final names never overwrite anything and always fit the 255-byte file-name limit (see `OutputNaming`).
public final class OutputTarget: @unchecked Sendable {
    /// The folder the final file goes to (next to the original). In staged mode the worker never writes here.
    public let directory: URL
    public let baseName: String
    public let suffix: String?
    public let pathExtension: String
    public let temporaryURL: URL
    /// True for a folder output (e.g. "report pages"): `temporaryURL` is an empty directory to fill, then `commit()`.
    public let isFolder: Bool

    /// Per-target staging folder (staged mode only).
    let stagingFolder: URL?

    private let lock = NSLock()
    private var _finalURL: URL?

    /// Set once `commit()` succeeds. In staged mode this is the staged file, not the final location.
    public var finalURL: URL? { lock.withLock { _finalURL } }

    /// True when this target was staged (the app still has to place it).
    public var isStaged: Bool { stagingFolder != nil }

    init(directory: URL, baseName: String, suffix: String?, pathExtension: String, isFolder: Bool = false,
         stagingRoot: URL? = nil) throws {
        self.directory = directory
        self.baseName = baseName
        self.suffix = suffix
        self.pathExtension = isFolder ? "" : pathExtension
        self.isFolder = isFolder
        let tempName = OutputNaming.temporaryName(pathExtension: isFolder ? "" : pathExtension)
        let fm = FileManager.default

        if let stagingRoot {
            let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { throw ConversionError.writeFailed(folder, error.localizedDescription) }
            self.stagingFolder = folder
            self.temporaryURL = folder.appendingPathComponent(tempName)
        } else {
            guard fm.isWritableFile(atPath: directory.path) else {
                throw ConversionError.folderNotWritable(directory)
            }
            self.stagingFolder = nil
            self.temporaryURL = directory.appendingPathComponent(tempName)
        }
        if isFolder {
            do { try fm.createDirectory(at: temporaryURL, withIntermediateDirectories: false) }
            catch { throw ConversionError.writeFailed(temporaryURL, error.localizedDescription) }
        }
    }

    /// Moves the finished temporary file to a free final name (or, staged, to its staged name) and returns it.
    @discardableResult
    public func commit() throws -> URL {
        try lock.withLock {
            if let done = _finalURL { return done }
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw ConversionError.engine("Frenzy couldn't make a new file from this.")
            }
            let url = try AtomicRename.moveToFreeName(temporaryURL, in: stagingFolder ?? directory,
                                                      baseName: baseName, suffix: suffix, pathExtension: pathExtension)
            _finalURL = url
            return url
        }
    }

    /// What the app needs to place this target. Nil unless staged and committed.
    public var stagedOutput: StagedOutput? {
        guard isStaged, let staged = finalURL else { return nil }
        return StagedOutput(stagedPath: staged.path, directory: directory.path, baseName: baseName, suffix: suffix,
                            pathExtension: pathExtension, isFolder: isFolder)
    }

    /// Deletes the temporary file if it was never committed. Scratch siblings are handled by `OutputLedger`, which
    /// lists each folder once per job.
    func discardTemporaryIfUncommitted() {
        lock.withLock {
            if _finalURL == nil { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }

    /// Folder whose listing holds this target's temporary file and its scratch siblings.
    var scratchFolder: URL { temporaryURL.deletingLastPathComponent() }
}

/// Exclusive, atomic "rename to the first free name" used by `commit()` and by the app's final placement.
public enum AtomicRename {
    /// Renames `source` to `<directory>/<free name>`. Never replaces an existing item: uses `renamex_np(RENAME_EXCL)`,
    /// which fails with EEXIST if the name appeared meanwhile, and then tries the next index.
    public static func moveToFreeName(_ source: URL, in directory: URL, baseName: String, suffix: String?,
                                      pathExtension: String) throws -> URL {
        let fm = FileManager.default
        for n in 1...10_000 {
            let name = OutputNaming.fileName(base: baseName, suffix: suffix, index: n, pathExtension: pathExtension)
            let candidate = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { continue }
            if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            switch code {
            case EEXIST, ENOTEMPTY:
                continue
            case ENOTSUP, EINVAL:
                // File systems without RENAME_EXCL (some network volumes): checked rename.
                do {
                    try fm.moveItem(at: source, to: candidate)
                    return candidate
                } catch CocoaError.fileWriteFileExists {
                    continue
                } catch {
                    throw ConversionError.writeFailed(candidate, error.localizedDescription)
                }
            default:
                throw ConversionError.writeFailed(candidate, String(cString: strerror(code)))
            }
        }
        throw ConversionError.writeFailed(directory, "Too many files with the same name.")
    }
}

public enum OutputNaming {
    /// Longest file name most macOS volumes accept, in UTF-8 bytes.
    public static let maxNameBytes = 255
    /// Longest suffix kept in a name; longer ones are shortened so the base keeps some room.
    static let maxSuffixBytes = 64

    /// "report" + "compressed" + 1 + "pdf" -> "report (compressed).pdf"; index 2 -> "report (compressed) 2.pdf".
    /// The base is shortened (whole characters only, never splitting an emoji or accented letter) so the result
    /// fits `maxNameBytes` including suffix, index and extension.
    public static func fileName(base: String, suffix: String?, index: Int, pathExtension: String) -> String {
        var tail = ""
        if let suffix, !suffix.isEmpty { tail += " (\(truncate(suffix, toUTF8Bytes: maxSuffixBytes)))" }
        if index > 1 { tail += " \(index)" }
        let ext = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let budget = maxNameBytes - tail.utf8.count - ext.utf8.count
        var fitted = truncate(base, toUTF8Bytes: max(1, budget))
        if fitted.isEmpty { fitted = "Frenzy output" }
        // A final name must never look like Halo's scratch (".halo-<uuid>…"), or `TempSweeper` would delete the
        // result an hour later. Only an input already named that way can cause it; drop the leading dot.
        if isTemporaryName(fitted + tail + ext) { fitted.removeFirst() }
        return fitted + tail + ext
    }

    /// Hidden scratch name, ".halo-<uuid>" or ".halo-<uuid>.jpg". `TempSweeper` recognises exactly this shape.
    public static func temporaryName(pathExtension: String) -> String {
        let id = UUID().uuidString
        return pathExtension.isEmpty ? "\(tempPrefix)\(id)" : "\(tempPrefix)\(id).\(pathExtension)"
    }

    public static let tempPrefix = ".halo-"

    /// True for ".halo-<uuid>", ".halo-<uuid>.<ext>" and their engine scratch siblings (".halo-<uuid>.mp4.sb-...").
    public static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(tempPrefix) else { return false }
        let rest = name.dropFirst(tempPrefix.count)
        guard rest.count >= 36, UUID(uuidString: String(rest.prefix(36))) != nil else { return false }
        let after = rest.dropFirst(36)
        return after.isEmpty || after.hasPrefix(".")
    }

    /// Cuts `text` to at most `limit` UTF-8 bytes on a grapheme-cluster boundary, trimming trailing spaces.
    public static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        while out.last == " " { out.removeLast() }
        return out
    }
}

/// Tracks every target a job reserved so the runner can clean up after failures or cancellation.
final class OutputLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [OutputTarget] = []

    func track(_ target: OutputTarget) { lock.withLock { targets.append(target) } }

    var all: [OutputTarget] { lock.withLock { targets } }

    /// Removes uncommitted temporaries and every engine scratch sibling ("<temp>.sb-*"). Each folder is listed once
    /// per job, not once per target, so a 500-page Split stays linear.
    func discardUncommitted() {
        let targets = all
        targets.forEach { $0.discardTemporaryIfUncommitted() }
        let fm = FileManager.default
        let byFolder = Dictionary(grouping: targets, by: { $0.scratchFolder.path })
        for (folder, group) in byFolder {
            let prefixes = Set(group.map { $0.temporaryURL.lastPathComponent + "." })
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasPrefix(OutputNaming.tempPrefix) {
                if prefixes.contains(where: { name.hasPrefix($0) }) {
                    try? fm.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
                }
            }
        }
    }

    /// Top-level committed targets. A file committed inside a folder output belongs to that folder, so a folder
    /// counts as ONE output ("report pages"), not one per page.
    func committedTargets() -> [OutputTarget] {
        let targets = all
        let folders = targets.filter(\.isFolder)
        return targets.filter { target in
            guard let url = target.finalURL else { return false }
            return !folders.contains { folder in
                folder !== target && (Self.isInside(url, folder.temporaryURL) || folder.finalURL.map { Self.isInside(url, $0) } == true)
            }
        }
    }

    func committed() -> [URL] { committedTargets().compactMap(\.finalURL) }

    /// Every committed URL, nested ones included (for removing a failed part's partial results).
    func allCommitted() -> [URL] { all.compactMap(\.finalURL) }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
