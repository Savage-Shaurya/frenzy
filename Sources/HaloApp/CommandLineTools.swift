import Foundation
import HaloCore
import HaloConverters

/// `--worker-self-test`, `--worker-crash-test` and `--convert`: small diagnostics that talk to the real sandboxed worker, used by
/// `scripts/e2e.sh` and when checking a release (docs/RELEASE.md). They don't start the menu-bar app.
enum CommandLineTools {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "--worker-self-test": return blocking { await selfTest() }
        case "--convert": return blocking { await convert(Array(arguments.dropFirst(2))) }
        case "--worker-crash-test": return blocking { await crashTest(Array(arguments.dropFirst(2))) }
        default: return nil
        }
    }

    private static func blocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = ExitBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.code = await body()
            done.signal()
        }
        // Keep the main run loop alive for XPC callbacks while waiting.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.code
    }

    private final class ExitBox: @unchecked Sendable { var code: Int32 = 0 }

    static func selfTest() async -> Int32 {
        let backend = XPCConversionBackend()
        defer { backend.shutdown() }
        switch await backend.selfTest() {
        case .failure(let error):
            print("WORKER_SELF_TEST ERROR \(error): could not reach the worker (is this the binary inside Frenzy.app?)")
            return 2
        case .success(let result):
            print("worker pid: \(result.pid)")
            print("sandbox container: \(result.sandboxContainer ?? "(none: NOT SANDBOXED)")")
            print("worker home: \(result.homeDirectory)")
            print("worker temp: \(result.temporaryDirectory)")
            print("| Probe | Expected | Observed | Result |")
            print("|---|---|---|---|")
            for p in result.probes {
                print("| \(p.name) | \(p.expected) | \(p.observed) | \(p.pass ? "PASS" : "FAIL") |")
            }
            let ok = result.allPass && result.sandboxContainer != nil
            print(ok ? "WORKER_SELF_TEST PASS" : "WORKER_SELF_TEST FAIL")
            return ok ? 0 : 1
        }
    }

    /// Starts `<action-id> FILE` in the worker, SIGKILLs the worker mid-job (as a parser crash or the memory
    /// watchdog would), checks the job fails with the friendly message, then checks the SAME connection relaunches
    /// a fresh worker that passes the sandbox self-test.
    static func crashTest(_ args: [String]) async -> Int32 {
        guard args.count == 2, let input = InputFile(url: URL(fileURLWithPath: args[1])) else {
            print("usage: Frenzy --worker-crash-test <action-id> FILE   (pick a job that runs for a few seconds)")
            return 64
        }
        let backend = XPCConversionBackend()
        defer { backend.shutdown() }
        guard case .success(let before) = await backend.selfTest() else { print("CRASH_TEST FAIL: worker unreachable"); return 1 }
        print("worker pid before: \(before.pid)")
        let job = Task { await backend.run(ActionID(rawValue: args[0]), on: [input]) { _ in } }
        try? await Task.sleep(for: .milliseconds(700))
        print("kill -9 \(before.pid): \(kill(before.pid, SIGKILL) == 0 ? "sent" : "failed")")
        let outcome = await job.value
        let message = outcome.failures.first?.message ?? "(no failure)"
        print("job outcome: \(outcome.outputs.count) outputs, failure: \(message)")
        let failedCleanly = outcome.outputs.isEmpty && message == XPCConversionBackend.crashMessage
        guard case .success(let after) = await backend.selfTest() else { print("CRASH_TEST FAIL: worker did not relaunch"); return 1 }
        print("worker pid after: \(after.pid), sandbox self-test \(after.allPass ? "PASS" : "FAIL")")
        let ok = failedCleanly && after.pid != before.pid && after.allPass
        print(ok ? "CRASH_TEST PASS" : "CRASH_TEST FAIL")
        return ok ? 0 : 1
    }

    static func convert(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            print("usage: Frenzy --convert <action-id> FILE...")
            return 64
        }
        let actionID = ActionID(rawValue: args[0])
        let inputs = args.dropFirst().compactMap { InputFile(url: URL(fileURLWithPath: $0)) }
        let backend = XPCConversionBackend()
        defer { backend.shutdown() }
        let outcome = await backend.run(actionID, on: inputs) { _ in }
        for url in outcome.outputs { print("OUTPUT \(url.path)") }
        for f in outcome.failures { print("FAILURE \(f.input?.lastPathComponent ?? "-"): \(f.message)") }
        return outcome.outputs.isEmpty ? 1 : 0
    }
}
