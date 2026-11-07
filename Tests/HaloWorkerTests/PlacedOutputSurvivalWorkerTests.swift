import Foundation
import Testing
import UniformTypeIdentifiers
import HaloCore
@testable import HaloWorkerKit

// Backlog B1 "vanished result", worker side: WorkerEngine.run -> StagedPlacement.place -> engine.discard(jobID) ->
// a fresh WorkerEngine (whose init sweeps staging). An output placed next to the original must survive all of it.
//
// No wall-clock waits: placed outputs are back-dated by a day and the explicit staging sweep uses maxAge 0 with a
// `now` two hours ahead, which replaces sleeping past `TempSweeper.defaultMaxAge`.

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-test-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Copies the input into "<base> (copy).txt"; a scratch sibling is left like AVFoundation does.
private struct CopyConverter: Converter {
    func run(_ job: ConversionJob) async throws -> [URL] {
        var urls: [URL] = []
        for input in job.inputs {
            let target = try job.makeOutput(for: input, pathExtension: "txt", suffix: "copy")
            try Data(contentsOf: input.url).write(to: target.temporaryURL)
            try Data().write(to: URL(fileURLWithPath: target.temporaryURL.path + ".sb-1"))
            urls.append(try target.commit())
        }
        return urls
    }
}

private func makeEngine(staging: URL) -> WorkerEngine {
    let action = ConversionAction(id: "test.copy", title: "Copy", symbolName: "doc", category: .text,
                                  inputTypes: [.plainText], converter: CopyConverter())
    return WorkerEngine(registry: ActionRegistry(actions: [action], usage: MemoryUsageStore()), stagingRoot: staging)
}

/// What the app does with a reply (see XPCConversionBackend): place, then discard the job's staging.
private func placeAndDiscard(_ reply: WorkerReply, inputs: [InputFile], engine: WorkerEngine, staging: URL) async -> ConversionOutcome {
    let jobRoot = staging.appendingPathComponent(reply.jobID, isDirectory: true)
    let outcome = StagedPlacement(allowedStagingRoot: jobRoot, inputs: inputs)
        .place(ConversionOutcome(actionID: "test.copy", outputs: [], staged: reply.staged, failures: reply.failures, duration: .zero))
    await engine.discard(reply.jobID)
    return outcome
}

private func fingerprint(_ url: URL) throws -> (Data, UInt64) {
    let inode = try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    return (try Data(contentsOf: url), inode)
}

@Suite struct PlacedOutputSurvivalWorkerTests {
    @Test func placedOutputSurvivesDiscardAndAFreshEngineSweep() async throws {
        let folder = try tempDir("in")
        let staging = try tempDir("staging")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: staging)
        }
        let url = folder.appendingPathComponent("note.txt")
        try Data("hello worker".utf8).write(to: url)
        let input = InputFile(url: url, type: .plainText)
        let fm = FileManager.default
        let worker = makeEngine(staging: staging)

        // Run + place + discard, like the app.
        let request = WorkerRequest(jobID: UUID().uuidString, actionID: "test.copy", inputs: [input])
        let reply = await worker.run(request) { _ in }
        #expect(reply.failures.isEmpty)
        let first = await placeAndDiscard(reply, inputs: [input], engine: worker, staging: staging)
        #expect(first.failures.isEmpty)
        let placed = try #require(first.outputs.first)
        #expect(placed.lastPathComponent == "note (copy).txt")
        #expect(!fm.fileExists(atPath: staging.appendingPathComponent(request.jobID).path))

        // Two jobs racing on the same input in the same engine: both placed, under different names.
        let r1 = WorkerRequest(jobID: UUID().uuidString, actionID: "test.copy", inputs: [input])
        let r2 = WorkerRequest(jobID: UUID().uuidString, actionID: "test.copy", inputs: [input])
        async let a = worker.run(r1) { _ in }
        async let b = worker.run(r2) { _ in }
        let (ra, rb) = await (a, b)
        async let pa = placeAndDiscard(ra, inputs: [input], engine: worker, staging: staging)
        async let pb = placeAndDiscard(rb, inputs: [input], engine: worker, staging: staging)
        let (oa, ob) = await (pa, pb)
        #expect(oa.failures.isEmpty && ob.failures.isEmpty)
        let raced = oa.outputs + ob.outputs
        #expect(Set(raced.map(\.lastPathComponent)) == ["note (copy) 2.txt", "note (copy) 3.txt"])

        // A cancelled job on the same input: discard it too, as the app would.
        let rc = WorkerRequest(jobID: UUID().uuidString, actionID: "test.copy", inputs: [input])
        let cancelled = Task { await worker.run(rc) { _ in } }
        await worker.cancel(rc.jobID)
        let rcReply = await cancelled.value
        let oc = await placeAndDiscard(rcReply, inputs: [input], engine: worker, staging: staging)

        let all = [placed] + raced + oc.outputs
        var prints: [URL: (Data, UInt64)] = [:]
        for out in all {
            prints[out] = try fingerprint(out)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: out.path)
        }
        let namesBefore = Set(try fm.contentsOfDirectory(atPath: folder.path))

        // A stale job folder so the sweeps demonstrably remove something.
        let staleJob = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staleJob, withIntermediateDirectories: false)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: staleJob.path)

        // A fresh engine on the same staging root (a relaunched worker) sweeps staging in init.
        let relaunched = makeEngine(staging: staging)
        #expect(!fm.fileExists(atPath: staleJob.path))
        // The most aggressive staging sweep, and the launch sweep of the input folder.
        TempSweeper.sweepStaging(await relaunched.stagingRoot, maxAge: 0, now: Date().addingTimeInterval(7200))
        let swept = TempSweeper.sweep(folders: [folder], maxAge: 0, now: Date().addingTimeInterval(7200))
        #expect(swept.allSatisfy { OutputNaming.isTemporaryName($0.lastPathComponent) })
        // Discarding jobs that are already gone (and a bogus ID) is harmless.
        for id in [request.jobID, r1.jobID, r2.jobID, rc.jobID, "../" + folder.lastPathComponent] { await relaunched.discard(id) }

        for (out, expected) in prints {
            #expect(fm.fileExists(atPath: out.path), "vanished result: \(out.lastPathComponent)")
            let now = try fingerprint(out)
            #expect(now.0 == expected.0 && now.1 == expected.1, "placed output changed: \(out.lastPathComponent)")
        }
        let namesAfter = Set(try fm.contentsOfDirectory(atPath: folder.path))
        for name in namesBefore.subtracting(namesAfter) {
            #expect(OutputNaming.isTemporaryName(name), "a sweep removed a non-scratch item: \(name)")
        }
        #expect(namesAfter == Set(all.map(\.lastPathComponent)).union(["note.txt"]))
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello worker")
        #expect(try fm.contentsOfDirectory(atPath: staging.path).isEmpty)
    }
}
