import AppKit

/// Makes sure only one Halo runs per user session, even for unbundled `swift run` builds (which have no bundle id,
/// so `NSRunningApplication` alone can't tell copies apart). Uses an advisory file lock that the OS releases
/// automatically when the process exits or crashes, so a stale lock can never block launch.
enum SingleInstance {
    /// Posted (locally, via the distributed notification centre; nothing leaves the Mac) by a second copy so the
    /// running one can show itself.
    static let reopenNotification = Notification.Name("com.snappycrew.frenzy.reopen")

    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// Returns true when this process is the only Halo. Otherwise pings the running copy and returns false.
    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.snappycrew.frenzy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true } // Can't create the lock: don't refuse to launch over it.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd // Held for the life of the process.
            return true
        }
        close(fd)
        DistributedNotificationCenter.default().postNotificationName(reopenNotification, object: nil, userInfo: nil,
                                                                      deliverImmediately: true)
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != getpid() }) {
            other.activate()
        }
        return false
    }
}
