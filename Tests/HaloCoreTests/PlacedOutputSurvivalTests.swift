import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloCore

// Backlog B1 "vanished result": once Halo has placed an output next to the original, no Halo cleanup path may ever
// delete it. These tests run real staged conversions (the exact worker pipeline, via `InProcessBackend(staged: true)`)
// and then throw every cleanup path at the folder with the most aggressive settings.
//
// No test waits on the wall clock. Sweepers get `maxAge: 0` and a `now` two hours in the future, and placed outputs
// are back-dated by a day, so every age check is already passed: only the name/shape filters can protect a file.
// This replaces sleeping past `TempSweeper.defaultMaxAge`.

// MARK: - Fixtures

/// A `halo-test-<uuid>` input folder plus its own staging parent (never the shared `$TMPDIR/HaloStaging`, which
/// other tests running in parallel use). Removed by `cleanUp()`.
private struct Fixture {
    let folder: URL
    let stagingParent: URL

    init() throws {
        let id = UUID().uuidString
        let tmp = FileManager.default.temporaryDirectory
        folder = tmp.appendingPathComponent("halo-test-\(id)", isDirectory: true)
        stagingParent = tmp.appendingPathComponent("halo-test-\(id)-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)
    }

    func input(_ name: String, _ text: String) throws -> InputFile {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return InputFile(url: url, type: .plainText)
    }

    func backend() -> InProcessBackend {
        InProcessBackend(runner: ConversionRunner(registry: survivalRegistry()), staged: true, stagingParent: stagingParent)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: stagingParent)
    }
}

/// Copies each input's bytes into "<base>.md". `steps` cancellable 10 ms waits happen first. Like AVFoundation it
/// also leaves a `<temp>.sb-1` scratch sibling, so the ledger's cleanup runs on every job.
private struct CopyConverter: Converter {
    var steps = 0
    func run(_ job: ConversionJob) async throws -> [URL] {
        var urls: [URL] = []
        for input in job.inputs {
            for _ in 0..<steps { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            let bytes = try Data(contentsOf: input.url)
            let target = try job.makeOutput(for: input, pathExtension: "md")
            try bytes.write(to: target.temporaryURL)
            try Data().write(to: URL(fileURLWithPath: target.temporaryURL.path + ".sb-1"))
            urls.append(try target.commit())
        }
        return urls
    }
}

private func survivalRegistry() -> ActionRegistry {
    ActionRegistry(actions: [
        ConversionAction(id: "test.copy", title: "Copy", symbolName: "doc", category: .text,
                         inputTypes: [.plainText], converter: CopyConverter()),
        ConversionAction(id: "test.copy-slow", title: "Copy slowly", symbolName: "doc", category: .text,
                         inputTypes: [.plainText], converter: CopyConverter(steps: 300)),
    ], usage: MemoryUsageStore())
}

/// Everything that identifies a placed file: its bytes and its inode (a delete + re-create would change the inode).
private struct Fingerprint: Equatable {
    let bytes: Data
    let inode: UInt64

    init(_ url: URL) throws {
        bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

private func names(_ dir: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
}

/// Back-dates a placed output so no age check can be what protects it.
private func ageByADay(_ url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: url.path)
}

/// Plants a stale scratch file of the exact shape the sweeper owns, so every sweep below demonstrably removes something.
@discardableResult
private func plantStaleScratch(in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(OutputNaming.temporaryName(pathExtension: "md"))
    try Data("scratch".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: url.path)
    return url
}

/// Ledger of placed outputs: each must keep the exact fingerprint it had when it was placed.
private final class Placed {
    private(set) var fingerprints: [URL: Fingerprint] = [:]

    func record(_ outcome: ConversionOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for url in outcome.outputs {
            #expect(FileManager.default.fileExists(atPath: url.path), "placed output missing right after placement: \(url.lastPathComponent)",
                    sourceLocation: sourceLocation)
            fingerprints[url] = try Fingerprint(url)
            try ageByADay(url)
        }
    }

    func expectAllSurvive(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for (url, expected) in fingerprints {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("vanished result after \(step): \(url.lastPathComponent)", sourceLocation: sourceLocation)
                continue
            }
            #expect(try Fingerprint(url) == expected, "placed output changed after \(step): \(url.lastPathComponent)",
                    sourceLocation: sourceLocation)
        }
    }
}

/// Every name that disappeared between two listings must be a Halo scratch name (`.halo-<uuid>[.ext][.sb-…]`).
private func expectOnlyScratchRemoved(before: Set<String>, after: Set<String>, _ step: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
    for name in before.subtracting(after) {
        #expect(OutputNaming.isTemporaryName(name), "\(step) removed a non-scratch item: \(name)", sourceLocation: sourceLocation)
    }
}

private extension Date {
    /// Two hours ahead: past `TempSweeper.defaultMaxAge` for everything on disk, with no wall-clock wait.
    static var sweepNow: Date { Date().addingTimeInterval(7200) }
}

// MARK: - Tests

@Suite struct PlacedOutputSurvivalTests {
    /// The whole gauntlet on one folder: place, sweep, sweep staging, race, cancel, sweep again.
    @Test func placedOutputSurvivesEveryCleanupPath() async throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let input = try fx.input("x.txt", "hello halo")
        let originalInput = try Fingerprint(input.url)
        let backend = fx.backend()
        let placed = Placed()

        // 1. A real staged conversion, exactly like the app.
        let first = await backend.run("test.copy", on: [input]) { _ in }
        #expect(first.failures.isEmpty)
        #expect(first.outputs.map(\.lastPathComponent) == ["x.md"])
        try placed.record(first)
        #expect(try String(contentsOf: fx.folder.appendingPathComponent("x.md"), encoding: .utf8) == "hello halo")

        // 2. Launch sweep with the most aggressive settings.
        let stale = try plantStaleScratch(in: fx.folder)
        var before = try names(fx.folder)
        let swept = TempSweeper.sweep(folders: [fx.folder], maxAge: 0, now: .sweepNow)
        #expect(swept.map(\.lastPathComponent).contains(stale.lastPathComponent)) // the sweeper really ran
        #expect(swept.allSatisfy { OutputNaming.isTemporaryName($0.lastPathComponent) })
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "TempSweeper.sweep")
        try placed.expectAllSurvive("TempSweeper.sweep")

        // 3. Worker-style staging sweep on the staging parent, everything counted as stale.
        let staleJob = fx.stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staleJob, withIntermediateDirectories: false)
        before = try names(fx.folder)
        let stagingSwept = TempSweeper.sweepStaging(fx.stagingParent, maxAge: 0, now: .sweepNow)
        #expect(stagingSwept.map(\.lastPathComponent) == [staleJob.lastPathComponent])
        #expect(try names(fx.folder) == before) // the staging sweep never looks at the input folder
        try placed.expectAllSurvive("TempSweeper.sweepStaging")

        // 4. Two identical jobs racing on the same input: both survive, under the next free names.
        before = try names(fx.folder)
        async let a = backend.run("test.copy", on: [input]) { _ in }
        async let b = backend.run("test.copy", on: [input]) { _ in }
        let (ra, rb) = await (a, b)
        #expect(ra.failures.isEmpty && rb.failures.isEmpty)
        #expect(Set((ra.outputs + rb.outputs).map(\.lastPathComponent)) == ["x 2.md", "x 3.md"])
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "racing jobs")
        try placed.expectAllSurvive("racing jobs")
        try placed.record(ra)
        try placed.record(rb)

        // 5a. A job cancelled the instant it starts.
        before = try names(fx.folder)
        let instant = Task { await backend.run("test.copy", on: [input]) { _ in } }
        instant.cancel()
        let instantOutcome = await instant.value
        // Cancellation can lose the race against a tiny job; then its output is simply one more placed result.
        if !instantOutcome.wasCancelled { try placed.record(instantOutcome) }
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "instant cancel")
        try placed.expectAllSurvive("instant cancel")

        // 5b. A job cancelled mid-conversion (this one always runs the runner's cancellation cleanup).
        before = try names(fx.folder)
        let slow = Task { await backend.run("test.copy-slow", on: [input]) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        slow.cancel()
        let slowOutcome = await slow.value
        #expect(slowOutcome.wasCancelled)
        #expect(slowOutcome.outputs.isEmpty)
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "mid-job cancel")
        try placed.expectAllSurvive("mid-job cancel")

        // 6. Every sweep once more, after all of the above.
        try plantStaleScratch(in: fx.folder)
        before = try names(fx.folder)
        let finalSweep = TempSweeper.sweep(folders: [fx.folder, fx.folder], maxAge: 0, now: .sweepNow)
        TempSweeper.sweepStaging(fx.stagingParent, maxAge: 0, now: .sweepNow)
        #expect(finalSweep.allSatisfy { OutputNaming.isTemporaryName($0.lastPathComponent) })
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "final sweep")
        try placed.expectAllSurvive("final sweep")

        // Nothing but the input and placed outputs remain; no scratch, and the input is untouched.
        let expected = Set(placed.fingerprints.keys.map(\.lastPathComponent)).union(["x.txt"])
        #expect(try names(fx.folder) == expected)
        #expect(try Fingerprint(input.url) == originalInput)
        // Every job's staging folder is gone.
        #expect(try names(fx.stagingParent).isEmpty)
    }

    /// Two jobs racing on one input in a fresh folder get "x.md" and "x 2.md", and both survive the sweepers.
    /// Repeated so the race actually interleaves at least some of the time.
    @Test(arguments: 0..<5)
    func twoRacingJobsBothSurvive(round: Int) async throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let input = try fx.input("x.txt", "round \(round)")
        let backend = fx.backend()
        let placed = Placed()

        async let a = backend.run("test.copy", on: [input]) { _ in }
        async let b = backend.run("test.copy", on: [input]) { _ in }
        let (ra, rb) = await (a, b)
        #expect(ra.failures.isEmpty && rb.failures.isEmpty)
        #expect(ra.outputs.count == 1 && rb.outputs.count == 1)
        #expect(Set((ra.outputs + rb.outputs).map(\.lastPathComponent)) == ["x.md", "x 2.md"])
        try placed.record(ra)
        try placed.record(rb)

        let before = try names(fx.folder)
        TempSweeper.sweep(folders: [fx.folder], maxAge: 0, now: .sweepNow)
        TempSweeper.sweepStaging(fx.stagingParent, maxAge: 0, now: .sweepNow)
        expectOnlyScratchRemoved(before: before, after: try names(fx.folder), "sweeps after race")
        try placed.expectAllSurvive("sweeps after race")
        #expect(try names(fx.folder) == ["x.txt", "x.md", "x 2.md"])
    }

    /// The launch sweeper hammering the folder WHILE conversions place outputs. A sweep may delete an in-flight
    /// `.halo-` copy (only possible because maxAge is 0 here; the app uses 1 hour), which can turn a job into a reported
    /// failure, but it may never remove an output a job reported as placed.
    @Test func sweeperRacingPlacementNeverRemovesAPlacedOutput() async throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let input = try fx.input("x.txt", "under fire")
        let backend = fx.backend()
        let removed = Locked<[String]>([])
        let stop = Locked(false)

        let sweeper = Task.detached {
            while !stop.value {
                let gone = TempSweeper.sweep(folders: [fx.folder], maxAge: 0, now: .sweepNow)
                removed.mutate { $0.append(contentsOf: gone.map(\.lastPathComponent)) }
                await Task.yield()
            }
        }
        let outcomes = await withTaskGroup(of: ConversionOutcome.self) { group in
            for _ in 0..<8 { group.addTask { await backend.run("test.copy", on: [input]) { _ in } } }
            var all: [ConversionOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        stop.mutate { $0 = true }
        await sweeper.value

        let reported = outcomes.flatMap(\.outputs)
        #expect(!reported.isEmpty)
        #expect(Set(reported).count == reported.count) // no two jobs were handed the same name
        for url in reported {
            #expect(FileManager.default.fileExists(atPath: url.path), "vanished result: \(url.lastPathComponent)")
            #expect(try String(contentsOf: url, encoding: .utf8) == "under fire")
        }
        #expect(removed.value.allSatisfy(OutputNaming.isTemporaryName))
        #expect(try names(fx.folder) == Set(reported.map(\.lastPathComponent)).union(["x.txt"]))
    }

    /// Edge case found in B1: a hidden input whose name already has the scratch shape (".halo-<uuid>.txt") converted
    /// with a suffix-less action used to be placed as ".halo-<uuid>.md", which the launch sweeper deleted an hour
    /// later. `OutputNaming.fileName` now drops the leading dot ("halo-<uuid>.md").
    @Test func outputOfAScratchShapedInputIsNotSwept() async throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let input = try fx.input(".halo-\(UUID().uuidString).txt", "hidden")
        let outcome = await fx.backend().run("test.copy", on: [input]) { _ in }
        #expect(outcome.failures.isEmpty)
        let output = try #require(outcome.outputs.first)
        try ageByADay(output)

        TempSweeper.sweep(folders: [fx.folder], maxAge: TempSweeper.defaultMaxAge, now: Date())
        #expect(!OutputNaming.isTemporaryName(output.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: output.path), "vanished result: \(output.lastPathComponent)")
    }
}
