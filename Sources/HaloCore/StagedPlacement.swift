import Foundation

/// The app's half of a staged conversion: moves each `StagedOutput` from the worker's staging folder to a free name
/// next to the original, never overwriting anything.
///
/// The worker is treated as untrusted (it parsed untrusted files). Placement therefore checks that:
/// - the staged item lives inside `allowedStagingRoot` (the worker's own container), so a confused or compromised
///   worker can't make the app copy some other file of yours;
/// - the destination folder is the folder of one of the dropped files, so it can't make the app write elsewhere;
/// - the name has no path separators and the extension is a plain document/media extension (no ".app", ".command");
/// - a folder output contains only plain files and folders (no symlinks), and nothing placed is executable;
/// - files inside a folder have allowed extensions too, except for Unzip, whose folder holds the user's own archive;
/// - every output keeps macOS's download quarantine when a dropped item had it (the strictest of them when several
///   did), so Gatekeeper still checks what came from the internet (as Archive Utility does).
///
/// Steps per output: copy into `<destination>/.halo-<uuid>[.ext]` (a clone on APFS), normalise permissions, then the
/// same exclusive atomic rename as `OutputTarget.commit()`. On any error the temp copy is removed.
public struct StagedPlacement: Sendable {
    public let allowedStagingRoot: URL
    public let allowedDirectories: Set<String>
    private let inputs: [InputFile]
    private let savePolicy: SavePolicy

    public init(allowedStagingRoot: URL, inputs: [InputFile], savePolicy: SavePolicy = .nextToOriginalsOnly) {
        self.allowedStagingRoot = allowedStagingRoot
        self.allowedDirectories = Set(inputs.map { Self.canonical($0.url.deletingLastPathComponent()) })
        self.inputs = inputs
        self.savePolicy = savePolicy
    }

    /// Actions whose folder output is the contents of the user's own archive, so any file type may be inside.
    public static let extractionActions: Set<ActionID> = ["archive.unzip", "archive.unpack"]
    /// Actions whose folder outputs may hold the user's own files of any kind. Every action's outputs inherit the
    /// inputs' download quarantine; these are the ones where losing it would matter most.
    public static let quarantineActions: Set<ActionID> = ["archive.zip", "archive.unzip", "archive.unpack", "archive.to-tgz"]

    /// Extensions an output may have. Covers every format Halo writes; anything else is refused.
    public static let allowedExtensions: Set<String> = [
        "", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif", "jp2",
        "pdf", "txt", "rtf", "rtfd", "docx", "doc", "odt", "html", "htm", "md", "csv", "json",
        "mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac", "zip", "gz", "tar", "ico",
    ]

    /// Endings macOS opens as apps, installers or scripts. Never allowed as the final ending of a placed name, even
    /// when it hides in the base name of an output with no extension ("x.app").
    public static let dangerousExtensions: Set<String> = [
        "app", "pkg", "mpkg", "dmg", "command", "tool", "terminal", "workflow", "action", "scpt", "applescript",
        "webloc", "fileloc", "inetloc", "mobileconfig", "saver", "prefpane", "kext", "plugin", "bundle", "sh",
        "framework", "appex", "xpc", "qlgenerator", "mdimporter", "service", "osax", "wdgt",
    ]

    /// True when `name` ends in one of `dangerousExtensions`.
    public static func hasDangerousExtension(_ name: String) -> Bool {
        dangerousExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Places every staged output of `outcome` and returns an outcome whose `outputs` are the final URLs. Outputs
    /// that can't be placed become failures.
    public func place(_ outcome: ConversionOutcome) -> ConversionOutcome {
        var outputs: [URL] = []
        var redirected: [URL] = []
        var failures = outcome.failures
        let anyExtension = Self.extractionActions.contains(outcome.actionID)
        // Every output, whatever the action: a PDF or a picture made from a download is still from the internet.
        let quarantine = Self.quarantine(of: inputs)
        for item in outcome.staged {
            do {
                let placed = try placeRouted(item, anyExtensionInside: anyExtension, quarantine: quarantine)
                outputs.append(placed.url)
                if placed.redirected { redirected.append(placed.url) }
            } catch {
                let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append(.init(input: nil, message: message))
            }
        }
        return ConversionOutcome(actionID: outcome.actionID, outputs: outputs, failures: failures, duration: outcome.duration,
                                 redirected: redirected)
    }

    /// Places one staged output; returns its final URL. `anyExtensionInside` lifts the extension rule for the files
    /// inside a folder output (never for the output's own name); `quarantine` is applied to everything placed.
    public func place(_ item: StagedOutput, anyExtensionInside: Bool = false, quarantine: Data? = nil) throws -> URL {
        try placeRouted(item, anyExtensionInside: anyExtensionInside, quarantine: quarantine).url
    }

    /// Validates `item`, then saves it where it was meant to go, or in the fallback folder when that isn't allowed or
    /// doesn't work. The fallback comes from the app's own policy; nothing the worker says can choose it.
    private func placeRouted(_ item: StagedOutput, anyExtensionInside: Bool, quarantine: Data?) throws -> (url: URL, redirected: Bool) {
        let staged = URL(fileURLWithPath: item.stagedPath)
        let destination = URL(fileURLWithPath: item.directory, isDirectory: true)

        guard OutputLedger.isInside(URL(fileURLWithPath: Self.canonical(staged)), URL(fileURLWithPath: Self.canonical(allowedStagingRoot))) else {
            throw ConversionError.engine("Frenzy's converter returned a file from an unexpected place, so it wasn't saved.")
        }
        guard allowedDirectories.contains(Self.canonical(destination)) else {
            throw ConversionError.engine("Frenzy's converter asked to save into an unexpected folder, so nothing was saved there.")
        }
        guard Self.isSafeName(item.baseName), item.suffix.map(Self.isSafeName) ?? true,
              Self.allowedExtensions.contains(item.pathExtension.lowercased()),
              // With no extension of its own, the base name's ending is what Finder sees ("x.app"). "a.pkg.zip" is fine.
              !item.pathExtension.isEmpty || !Self.hasDangerousExtension(item.baseName),
              !item.isFolder || item.pathExtension.isEmpty else {
            throw ConversionError.engine("Frenzy's converter suggested an unsafe file name, so it wasn't saved.")
        }
        let values = try? staged.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, (item.isFolder ? values?.isDirectory == true : values?.isRegularFile == true) else {
            throw ConversionError.engine("Frenzy's converter produced something unexpected, so it wasn't saved.")
        }
        if item.isFolder { try Self.checkFolderContents(staged, anyExtension: anyExtensionInside) }

        let fallback = savePolicy.fallbackFolder
        if savePolicy.mustRedirect(destination), let fallback {
            return (try copy(staged, item, into: fallback, anyExtensionInside: anyExtensionInside, quarantine: quarantine), true)
        }
        do {
            return (try copy(staged, item, into: destination, anyExtensionInside: anyExtensionInside, quarantine: quarantine), false)
        } catch ConversionError.folderNotWritable(let folder) {
            guard let fallback else { throw ConversionError.folderNotWritable(folder) }
            return (try copy(staged, item, into: fallback, anyExtensionInside: anyExtensionInside, quarantine: quarantine), true)
        } catch ConversionError.writeFailed(let folder, let why) {
            // Out of space, a share that dropped: the file is made, so try hard to keep it.
            guard let fallback else { throw ConversionError.writeFailed(folder, why) }
            return (try copy(staged, item, into: fallback, anyExtensionInside: anyExtensionInside, quarantine: quarantine), true)
        }
    }

    /// Copy to a hidden scratch name, check again, set permissions and quarantine, rename to a free name.
    private func copy(_ staged: URL, _ item: StagedOutput, into destination: URL, anyExtensionInside: Bool, quarantine: Data?) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path), destination == savePolicy.fallbackFolder {
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        guard fm.isWritableFile(atPath: destination.path) else { throw ConversionError.folderNotWritable(destination) }
        let temp = destination.appendingPathComponent(OutputNaming.temporaryName(pathExtension: item.pathExtension))
        do {
            try fm.copyItem(at: staged, to: temp)
            // Check the copy again: the worker could swap in a link after the first check, but it can't touch this.
            let copied = try? temp.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard copied?.isSymbolicLink != true, (item.isFolder ? copied?.isDirectory == true : copied?.isRegularFile == true) else {
                throw ConversionError.engine("Frenzy's converter produced something unexpected, so it wasn't saved.")
            }
            if item.isFolder { try Self.checkFolderContents(temp, anyExtension: anyExtensionInside) }
            try Self.normalisePermissions(temp, isFolder: item.isFolder)
            if let quarantine { try Self.applyQuarantine(quarantine, to: temp) }
            let final = try AtomicRename.moveToFreeName(temp, in: destination, baseName: item.baseName,
                                                        suffix: item.suffix, pathExtension: item.pathExtension)
            try? fm.removeItem(at: staged)
            return final
        } catch {
            try? fm.removeItem(at: temp)
            if let conversion = error as? ConversionError { throw conversion }
            if Self.isPermissionError(error) { throw ConversionError.folderNotWritable(destination) }
            throw ConversionError.writeFailed(destination, error.localizedDescription)
        }
    }

    /// A read-only volume or a refused write. Permission bits often claim otherwise, so this shows up only at the copy.
    static func isPermissionError(_ error: any Error) -> Bool {
        let posix: Int? = {
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain { return ns.code }
            return (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        }()
        if let posix, [Int(EROFS), Int(EACCES), Int(EPERM)].contains(posix) { return true }
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain
            && [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(ns.code)
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    /// Only regular files and folders, at most `maxFolderItems`, no symlinks.
    static let maxFolderItems = 20_000

    static func checkFolderContents(_ folder: URL, anyExtension: Bool = false) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var count = 0
        for case let url as URL in walker {
            count += 1
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard count <= maxFolderItems, v?.isSymbolicLink != true, v?.isRegularFile == true || v?.isDirectory == true,
                  anyExtension || allowedExtensions.contains(url.pathExtension.lowercased()) || v?.isDirectory == true else {
                throw ConversionError.engine("Frenzy's converter produced something unexpected, so it wasn't saved.")
            }
        }
    }

    /// Files 0644, folders 0755: nothing Halo writes is ever executable.
    static func normalisePermissions(_ url: URL, isFolder: Bool) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: isFolder ? 0o755 : 0o644], ofItemAtPath: url.path)
        guard isFolder, let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let child as URL in walker {
            let dir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try fm.setAttributes([.posixPermissions: dir ? 0o755 : 0o644], ofItemAtPath: child.path)
        }
    }

    static let quarantineKey = "com.apple.quarantine"

    /// The download quarantine for outputs made from `inputs`: the value of the one dropped item that has one, or, when
    /// several do, the strictest flags among them on the first one's record. Reads only the attribute, never the contents.
    static func quarantine(of inputs: [InputFile]) -> Data? {
        let values = inputs.compactMap { readQuarantine(atPath: $0.url.path) }
        guard let first = values.first else { return nil }
        if values.count == 1 || Set(values).count == 1 { return first }
        return strictest(values)
    }

    /// Flags bits that record a user's or Gatekeeper's approval (QTN_FLAG_USER_APPROVED 0x40, assessment OK 0x20).
    /// An output keeps them only if every quarantined input had them; every other bit is kept if any input had it.
    static let approvalFlags: UInt32 = 0x0060

    /// Merges quarantine records ("flags;time;agent;id"): the flags as above, the rest from the first record.
    static func strictest(_ values: [Data]) -> Data? {
        let records = values.map { String(decoding: $0, as: UTF8.self) }
        let parsed = records.map { record -> UInt32? in
            UInt32(record.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "", radix: 16)
        }
        guard let first = values.first else { return nil }
        // An unreadable record: keep the first one as it is rather than guess.
        let flags = parsed.compactMap { $0 }
        guard flags.count == parsed.count, !flags.isEmpty else { return first }
        let any = flags.reduce(0, |), all = flags.reduce(UInt32.max, &)
        let merged = (any & ~approvalFlags) | (all & approvalFlags)
        var fields = records[0].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        fields[0] = String(format: "%04x", merged)
        return Data(fields.joined(separator: ";").utf8)
    }

    private static func readQuarantine(atPath path: String) -> Data? {
        let size = getxattr(path, quarantineKey, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(path, quarantineKey, $0.baseAddress, size, 0, 0) }
        return read > 0 ? value.prefix(read) : nil
    }

    /// Sets `value` as the quarantine of `url` and everything inside it. Failing here fails the placement: an
    /// unzipped download must never lose its quarantine.
    static func applyQuarantine(_ value: Data, to url: URL) throws {
        var paths = [url.path]
        if let walker = FileManager.default.enumerator(atPath: url.path) {
            while let relative = walker.nextObject() as? String { paths.append(url.appendingPathComponent(relative).path) }
        }
        for path in paths {
            let result = value.withUnsafeBytes { setxattr(path, quarantineKey, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            guard result == 0 else {
                throw ConversionError.writeFailed(url, "Frenzy couldn't keep the file's download warning, so it wasn't saved.")
            }
        }
    }

    /// Absolute, standardised, symlinks resolved ("/var" -> "/private/var").
    static func canonical(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
