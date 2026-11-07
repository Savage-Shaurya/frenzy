import Foundation

/// Cleans up Halo's own scratch files left behind by a crash, a force quit or a power cut.
///
/// It never scans the disk: it only looks in folders Halo recorded as used (`UsedFolders`), lists each one once, and
/// removes only names of the exact shape `.halo-<uuid>`, `.halo-<uuid>.<ext>` and their engine siblings
/// (`.halo-<uuid>.mp4.sb-…`) whose modification date is older than `maxAge`.
public enum TempSweeper {
    public static let defaultMaxAge: TimeInterval = 3600

    /// Returns the removed paths.
    @discardableResult
    public static func sweep(folders: [URL], maxAge: TimeInterval = defaultMaxAge, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for folder in Set(folders.map(\.standardizedFileURL)) {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where OutputNaming.isTemporaryName(name) {
                let url = folder.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) > maxAge else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
            }
        }
        return removed
    }

    /// Removes per-job staging folders (named by job UUID) under `stagingRoot` older than `maxAge`.
    @discardableResult
    public static func sweepStaging(_ stagingRoot: URL, maxAge: TimeInterval = defaultMaxAge, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: stagingRoot.path) else { return [] }
        var removed: [URL] = []
        for name in names where UUID(uuidString: name) != nil {
            let url = stagingRoot.appendingPathComponent(name)
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}

/// The small set of folders Halo has written into, most recent first, capped at `limit`. Stored in UserDefaults.
public final class UsedFolders: @unchecked Sendable {
    public static let limit = 200
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "halo.usedFolders") {
        self.defaults = defaults
        self.key = key
    }

    public var all: [URL] {
        lock.withLock { (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    public func record(_ folders: [URL]) {
        lock.withLock {
            var paths = defaults.stringArray(forKey: key) ?? []
            for folder in folders {
                let path = folder.standardizedFileURL.path
                paths.removeAll { $0 == path }
                paths.insert(path, at: 0)
            }
            defaults.set(Array(paths.prefix(Self.limit)), forKey: key)
        }
    }

    public func clear() { lock.withLock { defaults.removeObject(forKey: key) } }
}
