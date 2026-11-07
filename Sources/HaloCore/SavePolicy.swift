import Foundation

/// Where finished files may go when "next to the original" isn't possible or doesn't make sense.
///
/// - `neverSaveIn`: folders whose items must not get outputs beside them, because the user would never find them: the
///   promised-files inbox in the temp folder, and the Trash.
/// - `fallbackFolder`: where outputs go instead, and where they go when the source folder turns out to be read-only
///   (a disk image, a network share, a protected folder). Chosen by the app, never by the worker.
public struct SavePolicy: Sendable, Equatable {
    public var fallbackFolder: URL?
    public var neverSaveIn: [URL]

    public init(fallbackFolder: URL?, neverSaveIn: [URL] = []) {
        self.fallbackFolder = fallbackFolder
        self.neverSaveIn = neverSaveIn
    }

    /// Fail instead of falling back. Unit tests and the direct (unbundled) pipeline use this.
    public static let nextToOriginalsOnly = SavePolicy(fallbackFolder: nil)

    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// What the app uses: Downloads, and never the promised-files inbox or the Trash.
    public static func standard(inbox: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SavePolicy {
        SavePolicy(fallbackFolder: downloads, neverSaveIn: [inbox, home.appendingPathComponent(".Trash", isDirectory: true)])
    }

    /// True when outputs for an item in `folder` must not be saved beside it.
    public func mustRedirect(_ folder: URL) -> Bool {
        let path = StagedPlacement.canonical(folder)
        if path.contains("/.Trashes/") || path.hasSuffix("/.Trashes") { return true }
        return neverSaveIn.contains { root in
            let rootPath = StagedPlacement.canonical(root)
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// What will happen to a job's outputs, worked out before the job starts.
    public enum Plan: Sendable, Equatable {
        case nextToOriginals
        /// Some or all outputs go to `folder`. `blocked` lists the source folders that can't be written.
        case fallback(folder: URL, blocked: [URL])
        /// Nowhere to save: fail now, not after the work.
        case nowhere(blocked: [URL])
    }

    /// Checks each distinct source folder (a real write, see `canWrite`). Run it off the main thread: a slow share or a
    /// macOS permission prompt blocks here. Checks at most `limit` folders; a batch wider than that finds out at placing.
    public func plan(forFolders folders: [URL], limit: Int = 50,
                     canWrite: (URL) -> Bool = SavePolicy.canWrite) -> Plan {
        var seen = Set<String>()
        var blocked: [URL] = []
        var redirected = false
        for folder in folders where seen.insert(StagedPlacement.canonical(folder)).inserted {
            if seen.count > limit { break }
            if mustRedirect(folder) { redirected = true } else if !canWrite(folder) { blocked.append(folder) }
        }
        guard redirected || !blocked.isEmpty else { return .nextToOriginals }
        guard let fallbackFolder, canWriteOrCreate(fallbackFolder, canWrite) else { return .nowhere(blocked: blocked) }
        return .fallback(folder: fallbackFolder, blocked: blocked)
    }

    /// The fallback folder (Downloads) may be made if it's missing. Only that one: a source folder that vanished
    /// mid-drag must not be recreated just to test it.
    private func canWriteOrCreate(_ folder: URL, _ canWrite: (URL) -> Bool) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        return canWrite(folder)
    }

    /// A real test: creates and removes a scratch file. Permission bits can't answer this: a network share may claim
    /// to be writable and refuse, and a read-only volume may report the owner's bits. The scratch name is one
    /// `TempSweeper` recognises, so a crash here leaves nothing that stays. A missing folder is not writable and is
    /// never created here.
    public static func canWrite(_ folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(OutputNaming.temporaryName(pathExtension: "")).path
        let fd = open(probe, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        unlink(probe)
        return true
    }
}

/// Folders macOS guards with a permission prompt, or that can stall or wake a drive when touched. Halo must only list
/// these right after the user dropped something from them, never at launch or mid-drag.
public enum PrivacyFolders {
    public static func isProtected(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = folder.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { "\(homePath)/\($0)" } + ["/Volumes"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
