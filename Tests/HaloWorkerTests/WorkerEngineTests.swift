import Foundation
import Testing
import UniformTypeIdentifiers
import HaloCore
@testable import HaloWorkerKit

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-worker-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func textFile(_ name: String, in dir: URL, _ text: String) throws -> InputFile {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return try #require(InputFile(url: url))
}

/// Uppercases text into "<name> (upper).txt"; "slow" waits (cancellably) for up to 5 s; "crash" is never used here.
private struct UpperConverter: Converter {
    func run(_ job: ConversionJob) async throws -> [URL] {
        try await job.inputs.asyncMap { input in
            let text = try String(contentsOf: input.url, encoding: .utf8)
            if text == "slow" {
                for _ in 0..<500 { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            }
            let target = try job.makeOutput(for: input, pathExtension: "txt", suffix: "upper")
            try Data(text.uppercased().utf8).write(to: target.temporaryURL)
            job.progress(0.5)
            return try target.commit()
        }
    }
}

private extension Array where Element: Sendable {
    func asyncMap<T>(_ body: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await body(e)) }
        return out
    }
}

private func engine(staging: URL) -> WorkerEngine {
    let action = ConversionAction(id: "text.upper", title: "Upper", symbolName: "textformat", category: .text,
                                  inputTypes: [.plainText], converter: UpperConverter())
    return WorkerEngine(registry: ActionRegistry(actions: [action], usage: MemoryUsageStore()), stagingRoot: staging)
}

@Suite struct WorkerEngineTests {
    @Test func stagesInsideItsRootAndTheAppPlacesNextToTheOriginal() async throws {
        let inputs = try tempDir("in")
        let staging = try tempDir("staging")
        let file = try textFile("note.txt", in: inputs, "hello")
        let worker = engine(staging: staging)
        let request = WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [file])

        let progress = Locked<[Double]>([])
        let reply = await worker.run(request) { f in progress.mutate { $0.append(f) } }
        #expect(reply.failures.isEmpty)
        let staged = try #require(reply.staged.first)
        // The worker wrote nothing next to the original.
        #expect(try FileManager.default.contentsOfDirectory(atPath: inputs.path) == ["note.txt"])
        #expect(staged.stagedPath.hasPrefix(staging.appendingPathComponent(request.jobID).path))
        #expect(progress.value.last == 1)

        // The app side: place, then discard the job's staging.
        let jobRoot = staging.appendingPathComponent(request.jobID)
        let placed = StagedPlacement(allowedStagingRoot: jobRoot, inputs: [file])
            .place(ConversionOutcome(actionID: "text.upper", outputs: [], staged: reply.staged, failures: reply.failures, duration: .zero))
        #expect(placed.outputs.map(\.lastPathComponent) == ["note (upper).txt"])
        #expect(try String(contentsOf: placed.outputs[0], encoding: .utf8) == "HELLO")
        await worker.discard(request.jobID)
        #expect(!FileManager.default.fileExists(atPath: jobRoot.path))
    }

    @Test func rejectsBadRequests() async throws {
        let inputs = try tempDir("in")
        let worker = engine(staging: try tempDir("staging"))
        let file = try textFile("a.txt", in: inputs, "x")
        let badID = await worker.run(WorkerRequest(jobID: "../../escape", actionID: "text.upper", inputs: [file])) { _ in }
        #expect(badID.staged.isEmpty && badID.failures.count == 1)
        let unknown = await worker.run(WorkerRequest(jobID: UUID().uuidString, actionID: "nope", inputs: [file])) { _ in }
        #expect(unknown.staged.isEmpty && unknown.failures.first?.message == "Unknown action.")
        let wrongType = InputFile(url: file.url, type: .png)
        let mismatch = await worker.run(WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [wrongType])) { _ in }
        #expect(mismatch.staged.isEmpty)
        let none = await worker.run(WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [])) { _ in }
        #expect(none.staged.isEmpty)
    }

    @Test func cancelStopsAJobAndLeavesNoStaging() async throws {
        let inputs = try tempDir("in")
        let staging = try tempDir("staging")
        let worker = engine(staging: staging)
        let request = WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [try textFile("s.txt", in: inputs, "slow")])
        let running = Task { await worker.run(request) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await worker.runningJobs == 1)
        let started = ContinuousClock.now
        await worker.cancel(request.jobID)
        let reply = await running.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(reply.staged.isEmpty)
        #expect(reply.failures.first?.message == ConversionError.cancelled.errorDescription)
        #expect(await worker.runningJobs == 0)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent(request.jobID).path))
    }

    @Test func cancelAllForOneOwnerOnly() async throws {
        let inputs = try tempDir("in")
        let worker = engine(staging: try tempDir("staging"))
        let a = UUID(), b = UUID()
        let ra = WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [try textFile("a.txt", in: inputs, "slow")])
        let rb = WorkerRequest(jobID: UUID().uuidString, actionID: "text.upper", inputs: [try textFile("b.txt", in: inputs, "quick")])
        let ta = Task { await worker.run(ra, owner: a) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        await worker.cancelAll(owner: b)
        #expect(await worker.runningJobs(owner: a) == 1)
        await worker.cancelAll(owner: a)
        let reply = await ta.value
        #expect(reply.failures.first?.message == ConversionError.cancelled.errorDescription)
        let rbReply = await worker.run(rb, owner: b) { _ in }
        #expect(rbReply.staged.count == 1)
    }

    @Test func sweepsOldStagingOnStart() throws {
        let staging = try tempDir("staging")
        let stale = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: stale.path)
        _ = engine(staging: staging)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}

@Suite struct SandboxProbeTests {
    // Only local, offline checks here: the full probe (which would try public hosts when NOT sandboxed) runs inside
    // the real worker via `Halo --worker-self-test`.
    @Test func loopbackConnectIsRefusedNotDeniedOutsideTheSandbox() {
        // The test runner is not sandboxed, so this shows the probe tells "refused" apart from "denied".
        let result = SandboxProbe.tcpConnect("127.0.0.1", port: 9)
        #expect(result.errno == ECONNREFUSED)
    }

    @Test func writeProbeReportsSuccessAndFailure() throws {
        let dir = try tempDir("probe")
        #expect(SandboxProbe.tryWrite(dir.appendingPathComponent("x")).ok)
        #expect(!SandboxProbe.tryWrite(URL(fileURLWithPath: "/System/halo-probe-\(UUID().uuidString)")).ok)
    }

    @Test func memoryFootprintIsReadable() {
        let footprint = MemoryWatchdog.currentFootprint()
        #expect((footprint ?? 0) > 1 << 20)
        #expect(MemoryWatchdog.defaultLimit >= 2 << 30)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
