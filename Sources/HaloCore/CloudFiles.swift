import Foundation

/// iCloud Drive and other file-provider folders keep "dataless" placeholders: the name and size are here, the contents
/// are not. Reading one blocks until macOS has downloaded it, which looks like a stuck job.
public enum CloudFileState: Sendable, Equatable {
    case local
    /// A placeholder nobody has asked to download yet.
    case placeholder
    case downloading
    case failed(String)
}

public protocol CloudFileProbing: Sendable {
    func state(of url: URL) -> CloudFileState
    /// Asks macOS to fetch the file. False when it can't be asked: reading the file will still fetch it.
    func startDownload(of url: URL) -> Bool
}

/// The real system. Reads metadata only; the download itself is macOS's own, for the user's own files.
public struct SystemCloudProbe: CloudFileProbing {
    /// `SF_DATALESS` in <sys/stat.h>: the file's contents are not on this Mac.
    static let datalessFlag: UInt32 = 0x4000_0000

    public init() {}

    public func state(of url: URL) -> CloudFileState {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_flags & Self.datalessFlag != 0, info.st_mode & S_IFMT == S_IFREG else { return .local }
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey]
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: keys)
        if let error = values?.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        return values?.ubiquitousItemIsDownloading == true ? .downloading : .placeholder
    }

    public func startDownload(of url: URL) -> Bool {
        (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil
    }
}

public enum CloudDownloads {
    public enum Result: Sendable, Equatable {
        case ready
        case failed(URL, String)
        case cancelled
    }

    /// Names the cloud when we can tell, and never claims one we can't.
    public static func isInICloudDrive(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        url.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/Library/Mobile Documents/")
    }

    /// Downloads any placeholders among `urls` and waits for them. Returns at once when none are, with no download asked for.
    ///
    /// - Parameters:
    ///   - stallLimit: how long a file may sit undownloaded with no download under way before we give up. A download
    ///     that's actually running has no limit (only macOS can say it failed, and the card's Cancel is always there).
    ///   - onProgress: called with how many are still missing, out of how many needed fetching.
    public static func fetch(_ urls: [URL], probe: any CloudFileProbing = SystemCloudProbe(),
                             poll: Duration = .milliseconds(500), stallLimit: Duration = .seconds(60),
                             onProgress: @Sendable (_ waiting: Int, _ total: Int) -> Void = { _, _ in }) async -> Result {
        var waiting = urls.filter { probe.state(of: $0) != .local }
        guard !waiting.isEmpty else { return .ready }
        let total = waiting.count
        var cannotAsk = Set<URL>()
        for url in waiting where !probe.startDownload(of: url) { cannotAsk.insert(url) }
        // A provider that can't be asked: the worker's read fetches it. Don't wait here for something we can't start.
        waiting.removeAll { cannotAsk.contains($0) }
        let clock = ContinuousClock()
        var lastMovement = clock.now
        while !waiting.isEmpty {
            onProgress(waiting.count, total)
            if Task.isCancelled { return .cancelled }
            do { try await Task.sleep(for: poll) } catch { return .cancelled }
            var stillWaiting: [URL] = []
            var anyRunning = false
            for url in waiting {
                switch probe.state(of: url) {
                case .local: continue
                case .failed(let why): return .failed(url, downloadMessage(url, why: why))
                case .downloading: anyRunning = true; stillWaiting.append(url)
                case .placeholder: stillWaiting.append(url)
                }
            }
            if stillWaiting.count != waiting.count || anyRunning { lastMovement = clock.now }
            waiting = stillWaiting
            if !waiting.isEmpty, clock.now - lastMovement >= stallLimit, let first = waiting.first {
                return .failed(first, downloadMessage(first, why: nil))
            }
        }
        return .ready
    }

    private static func downloadMessage(_ url: URL, why: String?) -> String {
        let base = "Couldn't download \(url.lastPathComponent) to this Mac, so nothing was converted."
        return why.map { "\(base) \($0)" } ?? "\(base) Check your internet connection and try again."
    }
}
