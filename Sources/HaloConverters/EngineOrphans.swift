import Darwin
import Foundation

/// Media engines that outlived their worker.
///
/// The worker can die without a chance to clean up (SIGKILL from its memory watchdog, a crash, jetsam). Its engine child
/// is then adopted by launchd (parent pid 1) and could keep reading a file for up to its CPU-time limit. macOS has no
/// "die with your parent" switch, so three things cover it:
/// - the engine's stdout is a pipe only the worker reads, so its next `-progress` line after the worker is gone kills
///   it with SIGPIPE (conversions print one about twice a second);
/// - launchd removes the processes left in a dead XPC service's process group, which the engine stays in;
/// - and this: every engine the worker starts is recorded as `<temp>/frenzy-engine-pids/<pid>` (with its start time),
///   and the next worker, when it starts, kills any recorded engine that is still running with launchd as its parent.
///
/// Only processes this worker's container recorded are ever looked at, and one is killed only when its pid, start time,
/// owner and executable all still match: a reused pid or anyone else's process is left alone.
public enum EngineOrphans {
    /// `frenzy-engine-pids` in the worker's temporary folder, which is inside its sandbox container.
    public static var defaultRegistry: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("frenzy-engine-pids", isDirectory: true)
    }

    struct ProcessFacts: Equatable {
        var parent: pid_t
        var owner: uid_t
        var started: String
        var executable: String
    }

    /// What the kernel says about `pid` now, nil when it isn't running (or can't be read).
    static func facts(_ pid: pid_t) -> ProcessFacts? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ProcessFacts(parent: pid_t(info.pbi_ppid), owner: info.pbi_uid,
                            started: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)",
                            executable: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Notes a just-started engine. Best effort: a full disk only means this safety net is missing for that run.
    public static func record(_ pid: pid_t, registry: URL = defaultRegistry) {
        guard let started = facts(pid)?.started else { return }
        try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try? Data(started.utf8).write(to: registry.appendingPathComponent(String(pid)), options: .atomic)
    }

    /// Drops the note once the engine has been reaped.
    static func forget(_ pid: pid_t, registry: URL = defaultRegistry) {
        unlink(registry.appendingPathComponent(String(pid)).path)
    }

    /// Kills every recorded engine that is still running, is ours, runs `executable`, and has lost its worker (its
    /// parent is launchd). Notes for processes that are gone or aren't engines any more are removed; an engine that
    /// still has a living parent is left alone with its note. Returns the pids it killed.
    @discardableResult
    public static func killOrphans(executable: URL?, registry: URL = defaultRegistry) -> [pid_t] {
        guard let executable else { return [] }
        let expected = executable.resolvingSymlinksInPath().path
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: registry.path) else { return [] }
        var killed: [pid_t] = []
        for name in names {
            let note = registry.appendingPathComponent(name)
            guard let pid = pid_t(name), pid > 1,
                  let recorded = try? String(contentsOf: note, encoding: .utf8) else {
                unlink(note.path)
                continue
            }
            guard let now = facts(pid), now.started == recorded, now.owner == getuid(),
                  URL(fileURLWithPath: now.executable).resolvingSymlinksInPath().path == expected else {
                unlink(note.path) // Gone, or the pid now belongs to something else.
                continue
            }
            guard now.parent == 1 else { continue } // Its worker is alive: not an orphan.
            if kill(pid, SIGKILL) == 0 { killed.append(pid) }
            unlink(note.path)
        }
        return killed
    }

    /// The engine this process would run, nil when it isn't there.
    public static var engineExecutable: URL? { MediaEngine.executableURL }

    /// Whether `pid` is still running with launchd as its parent (the test and the self-test use it).
    public static func isOrphan(_ pid: pid_t) -> Bool { facts(pid)?.parent == 1 }

    /// For the worker's start: the bundled engine, and this container's notes.
    @discardableResult
    public static func killOrphansOfThisWorker() -> [pid_t] {
        killOrphans(executable: MediaEngine.executableURL)
    }
}
