import Darwin
import Foundation
import HaloCore
import HaloConverters

/// Self-test: proves, inside the sandbox, that a media engine left behind by a dead worker is found and killed.
/// It makes a real orphan: `/bin/sh` starts the engine in the background (reading a pipe from `sleep`, so it idles) and
/// exits at once, which hands the engine to launchd exactly as a killed worker would. Then the start-up sweep runs on a
/// registry of its own and must kill it. Nothing is converted.
enum OrphanProbe {
    static func run() -> [WorkerSelfTest.Probe] {
        let name = "engine orphaned by a dead worker is killed"
        guard let engine = EngineOrphans.engineExecutable else {
            return [.init(name: name, expected: "killed", observed: "no engine in this build", pass: false)]
        }
        let registry = FileManager.default.temporaryDirectory.appendingPathComponent("frenzy-orphan-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: registry) }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"/bin/sleep 5 | "$0" -hide_banner -nostdin -loglevel quiet -protocol_whitelist pipe -f wav -i pipe:0 -f null - >/dev/null 2>&1 & echo $!"#,
                           engine.path]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        do { try shell.run() } catch {
            return [.init(name: name, expected: "killed", observed: "couldn't start: \(error.localizedDescription)", pass: false)]
        }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        guard let pid = pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return [.init(name: name, expected: "killed", observed: "no pid", pass: false)]
        }
        var orphaned = false
        for _ in 0..<20 where !orphaned {
            orphaned = EngineOrphans.isOrphan(pid)
            if !orphaned { usleep(50_000) }
        }
        guard orphaned else {
            kill(pid, SIGKILL)
            return [.init(name: name, expected: "killed", observed: "engine \(pid) never became an orphan", pass: false)]
        }
        EngineOrphans.record(pid, registry: registry)
        let killed = EngineOrphans.killOrphans(executable: engine, registry: registry)
        var gone = false
        for _ in 0..<20 where !gone {
            gone = kill(pid, 0) == -1 && errno == ESRCH
            if !gone { usleep(50_000) }
        }
        if !gone { kill(pid, SIGKILL) }
        return [.init(name: name, expected: "killed", observed: killed.contains(pid) && gone ? "orphan \(pid) killed" : "still running",
                      pass: killed.contains(pid) && gone)]
    }
}
