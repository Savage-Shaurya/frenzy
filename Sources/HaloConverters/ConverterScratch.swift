import Foundation
import HaloCore

/// Private working folders for converters that need files of their own (the PNG the WebP encoder reads, the pieces of
/// an EPUB). They hold decoded copies of people's files, so they must not outlive a crash:
/// - In the worker every job has a staging folder (`<staging>/<job id>/`), and scratch goes inside it. The worker
///   deletes that folder when the app has placed the result, and the staging sweep at its start deletes the folders
///   of a worker that died (once they are an hour old, like staged results).
/// - With no staging folder (`swift test`, the in-process backend) scratch goes in the temporary folder.
/// - `sweep(_:)`, run once when the worker starts, also removes `frenzy-<kind>-<uuid>` folders older than 10 minutes
///   left directly in the worker's temporary folder (by older versions, or by a run outside a job).
public enum ConverterScratch {
    /// Makes `frenzy-<kind>-<uuid>` in the job's staging folder (or the temporary folder). The caller removes it.
    static func folder(_ kind: String, job: ConversionJob?) throws -> URL {
        let base = job?.stagingRoot ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("frenzy-\(kind)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True for exactly `frenzy-<lowercase letters>-<uuid>`.
    static func isScratchName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "frenzy", !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        return UUID(uuidString: String(parts[2])) != nil
    }

    /// Removes scratch folders directly inside `folder` that haven't changed for `maxAge` (never following a symbolic
    /// link). Run when the worker starts. The age gate is for a second copy of Frenzy (say one in Downloads and one in
    /// Applications): its worker shares this container and may be converting right now. A folder in use changes as
    /// its files are written. Returns what it removed.
    @discardableResult
    public static func sweep(_ folder: URL = FileManager.default.temporaryDirectory, maxAge: TimeInterval = 600, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [URL] = []
        for name in names where isScratchName(name) {
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
