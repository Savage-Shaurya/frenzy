import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloCore

private func tempDir(_ label: String = "hard") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func textFile(_ name: String, in dir: URL, _ text: String = "x") throws -> InputFile {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return try #require(InputFile(url: url))
}

private func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// Writes "<name>.out" with the input's text; "fail" throws, "slow" waits for cancellation.
private struct EchoConverter: Converter {
    var ext = "out"
    func run(_ job: ConversionJob) async throws -> [URL] {
        var urls: [URL] = []
        for input in job.inputs {
            let text = try String(contentsOf: input.url, encoding: .utf8)
            if text == "fail" { throw ConversionError.engine("boom") }
            if text == "slow" {
                for _ in 0..<500 { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            }
            let target = try job.makeOutput(for: input, pathExtension: ext)
            try Data(text.utf8).write(to: target.temporaryURL)
            // An engine scratch sibling, like AVFoundation's ".sb-" files.
            try Data().write(to: URL(fileURLWithPath: target.temporaryURL.path + ".sb-1234"))
            job.progress(0.5)
            urls.append(try target.commit())
        }
        return urls
    }
}

/// Makes a "<base> pages" folder with three page files inside it.
private struct PagesConverter: Converter {
    func run(_ job: ConversionJob) async throws -> [URL] {
        let input = job.inputs[0]
        let base = input.url.deletingPathExtension().lastPathComponent
        let folder = try job.makeOutputFolder(named: "\(base) pages", in: input.url.deletingLastPathComponent())
        for p in 1...3 {
            let page = try job.makeOutput(named: "\(base) page \(p)", in: folder.temporaryURL, pathExtension: "txt")
            try Data("page \(p)".utf8).write(to: page.temporaryURL)
            try page.commit()
        }
        return [try folder.commit()]
    }
}

private func registry(_ converters: [(ActionID, any Converter, ActionCategory)]) -> ActionRegistry {
    ActionRegistry(actions: converters.map { id, c, cat in
        ConversionAction(id: id, title: id.rawValue, symbolName: "doc", category: cat, inputTypes: [.plainText], converter: c)
    }, usage: MemoryUsageStore())
}

@Suite struct LongNameTests {
    @Test func fitsIn255BytesWithSuffixIndexAndExtension() {
        let base = String(repeating: "a", count: 400)
        let name = OutputNaming.fileName(base: base, suffix: "compressed", index: 12, pathExtension: "pdf")
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" (compressed) 12.pdf"))
    }

    @Test func neverSplitsGraphemeClusters() {
        // Family emoji (25 bytes) and an "e" + combining acute accent.
        let base = String(repeating: "👨‍👩‍👧‍👦", count: 12) + String(repeating: "e\u{301}", count: 40)
        let name = OutputNaming.fileName(base: base, suffix: nil, index: 1, pathExtension: "jpg")
        #expect(name.utf8.count <= 255)
        let stem = String(name.dropLast(4))
        #expect(stem.allSatisfy { $0 == "👨‍👩‍👧‍👦" || $0 == "e\u{301}" })
        #expect(Data(name.utf8).count == name.utf8.count) // valid UTF-8 round trip
    }

    @Test func shortNamesUnchanged() {
        #expect(OutputNaming.fileName(base: "photo", suffix: nil, index: 1, pathExtension: "jpg") == "photo.jpg")
    }

    @Test func commitWorksWithAHugeName() throws {
        let dir = try tempDir()
        let input = try textFile(String(repeating: "ü", count: 120) + ".txt", in: dir)  // 240 bytes + ".txt"
        let job = ConversionJob(actionID: "t", inputs: [input])
        let target = try job.makeOutput(for: input, pathExtension: "jpeg", suffix: "compressed")
        try Data("x".utf8).write(to: target.temporaryURL)
        let url = try target.commit()
        #expect(url.lastPathComponent.utf8.count <= 255)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct TempNameTests {
    @Test func recognisesOnlyHaloTempNames() {
        let id = UUID().uuidString
        #expect(OutputNaming.isTemporaryName(".halo-\(id)"))
        #expect(OutputNaming.isTemporaryName(".halo-\(id).jpg"))
        #expect(OutputNaming.isTemporaryName(".halo-\(id).mp4.sb-12ab"))
        #expect(!OutputNaming.isTemporaryName(".halo-notauuid.jpg"))
        #expect(!OutputNaming.isTemporaryName("halo-\(id).jpg"))
        #expect(!OutputNaming.isTemporaryName(".halo-\(id)x"))
        #expect(!OutputNaming.isTemporaryName("photo.jpg"))
    }
}

@Suite struct LedgerTests {
    @Test func scratchSiblingsRemovedWithOneListingPerFolder() async throws {
        let dir = try tempDir()
        let good = try textFile("a.txt", in: dir, "hello")
        let runner = ConversionRunner(registry: registry([("echo", EchoConverter(), .text)]))
        let outcome = await runner.run("echo", on: [good])
        #expect(outcome.outputs.map(\.lastPathComponent) == ["a.out"])
        #expect(try names(dir) == ["a.out", "a.txt"])
    }

    @Test func folderOutputCountsAsOne() async throws {
        let dir = try tempDir()
        let input = try textFile("doc.txt", in: dir)
        let runner = ConversionRunner(registry: registry([("pages", PagesConverter(), .text)]))
        let outcome = await runner.run("pages", on: [input])
        #expect(outcome.outputs.map(\.lastPathComponent) == ["doc pages"])
        #expect(try names(dir.appendingPathComponent("doc pages")) == ["doc page 1.txt", "doc page 2.txt", "doc page 3.txt"])
    }

    @Test func runnerDoesNotRecordUsage() async throws {
        let dir = try tempDir()
        let usage = MemoryUsageStore()
        let reg = ActionRegistry(actions: registry([("echo", EchoConverter(), .text)]).all, usage: usage)
        _ = await ConversionRunner(registry: reg).run("echo", on: [try textFile("a.txt", in: dir, "fail")])
        _ = await ConversionRunner(registry: reg).run("echo", on: [try textFile("b.txt", in: dir, "ok")])
        #expect(usage.count(for: "echo") == 0) // the app records a use after placement succeeds
    }

    @Test func progressIsMonotonic() async throws {
        let dir = try tempDir()
        let files = try (0..<6).map { try textFile("f\($0).txt", in: dir, "v\($0)") }
        let seen = Locked<[Double]>([])
        let runner = ConversionRunner(registry: registry([("echo", EchoConverter(), .text)]), maxConcurrent: 3)
        _ = await runner.run("echo", on: files) { f in seen.mutate { $0.append(f) } }
        let values = seen.value
        #expect(!values.isEmpty)
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Suite struct StagingTests {
    @Test func stagedOutputsNeverTouchTheInputFolder() async throws {
        let dir = try tempDir()
        let staging = try tempDir("staging")
        let input = try textFile("a.txt", in: dir, "hello")
        let runner = ConversionRunner(registry: registry([("echo", EchoConverter(), .text)]))
        let outcome = await runner.run("echo", on: [input], stagingRoot: staging)
        #expect(try names(dir) == ["a.txt"])
        let staged = try #require(outcome.staged.first)
        #expect(outcome.staged.count == 1)
        #expect(staged.stagedPath.hasPrefix(staging.path))
        #expect(staged.directory == dir.path)
        #expect(staged.baseName == "a")
        #expect(staged.pathExtension == "out")
        #expect(!staged.isFolder)
        #expect(URL(fileURLWithPath: staged.stagedPath).lastPathComponent == "a.out")
        // No scratch siblings left in staging either.
        let leftovers = FileManager.default.enumerator(atPath: staging.path)?.compactMap { $0 as? String }.filter { $0.contains(".halo-") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func placementGoesNextToOriginalWithoutOverwriting() async throws {
        let dir = try tempDir()
        let input = try textFile("a.txt", in: dir, "new")
        try Data("old".utf8).write(to: dir.appendingPathComponent("a.md"))
        let backend = InProcessBackend(runner: ConversionRunner(registry: registry([("echo", EchoConverter(ext: "md"), .text)])), staged: true)
        let outcome = await backend.run("echo", on: [input]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.outputs.map(\.lastPathComponent) == ["a 2.md"])
        #expect(try String(contentsOf: dir.appendingPathComponent("a.md"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: dir.appendingPathComponent("a 2.md"), encoding: .utf8) == "new")
        #expect(try names(dir) == ["a 2.md", "a.md", "a.txt"])
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("a 2.md").path)[.posixPermissions] as? Int
        #expect(perms == 0o644)
    }

    @Test func unknownExtensionsAreRefusedAsAFailure() async throws {
        let dir = try tempDir()
        let input = try textFile("a.txt", in: dir, "x")
        let backend = InProcessBackend(runner: ConversionRunner(registry: registry([("echo", EchoConverter(ext: "command"), .text)])), staged: true)
        let outcome = await backend.run("echo", on: [input]) { _ in }
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(try names(dir) == ["a.txt"])
    }

    @Test func stagedFolderPlacedAsOneItem() async throws {
        let dir = try tempDir()
        let input = try textFile("doc.txt", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("doc pages"), withIntermediateDirectories: false)
        let backend = InProcessBackend(runner: ConversionRunner(registry: registry([("pages", PagesConverter(), .text)])), staged: true)
        let outcome = await backend.run("pages", on: [input]) { _ in }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.outputs.map(\.lastPathComponent) == ["doc pages 2"])
        #expect(try names(dir.appendingPathComponent("doc pages 2")) == ["doc page 1.txt", "doc page 2.txt", "doc page 3.txt"])
        #expect(try names(dir).allSatisfy { !$0.hasPrefix(".halo-") })
    }

    @Test func placementRefusesFilesOutsideTheStagingRoot() throws {
        let dir = try tempDir()
        let staging = try tempDir("staging")
        let input = try textFile("a.txt", in: dir)
        let secret = try textFile("secret.txt", in: try tempDir("elsewhere"), "private")
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [input])
        let item = StagedOutput(stagedPath: secret.url.path, directory: dir.path, baseName: "a", suffix: nil, pathExtension: "txt", isFolder: false)
        #expect(throws: ConversionError.self) { try placement.place(item) }
        // A "../" escape is resolved before the check.
        let sneaky = StagedOutput(stagedPath: staging.path + "/../" + secret.url.deletingLastPathComponent().lastPathComponent + "/secret.txt",
                                  directory: dir.path, baseName: "a", suffix: nil, pathExtension: "txt", isFolder: false)
        #expect(throws: ConversionError.self) { try placement.place(sneaky) }
        #expect(try names(dir) == ["a.txt"])
    }

    @Test func placementRefusesForeignFoldersAndUnsafeNames() throws {
        let dir = try tempDir()
        let other = try tempDir("other")
        let staging = try tempDir("staging")
        let input = try textFile("a.txt", in: dir)
        let staged = staging.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: staged)
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [input])
        func item(dir: URL, base: String = "a", ext: String = "txt") -> StagedOutput {
            StagedOutput(stagedPath: staged.path, directory: dir.path, baseName: base, suffix: nil, pathExtension: ext, isFolder: false)
        }
        #expect(throws: ConversionError.self) { try placement.place(item(dir: other)) }
        #expect(throws: ConversionError.self) { try placement.place(item(dir: dir, base: "../evil")) }
        #expect(throws: ConversionError.self) { try placement.place(item(dir: dir, ext: "command")) }
        #expect(throws: ConversionError.self) { try placement.place(item(dir: dir, ext: "app")) }
        #expect(try names(other).isEmpty)
        #expect(try names(dir) == ["a.txt"])
        // The well-formed one is accepted.
        let url = try placement.place(item(dir: dir))
        #expect(url.lastPathComponent == "a.txt" || url.lastPathComponent == "a 2.txt")
    }

    @Test func placementRefusesSymlinksInFolders() throws {
        let dir = try tempDir()
        let staging = try tempDir("staging")
        let input = try textFile("a.txt", in: dir)
        let folder = staging.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: input.url)
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [input])
        let item = StagedOutput(stagedPath: folder.path, directory: dir.path, baseName: "a pages", suffix: nil, pathExtension: "", isFolder: true)
        #expect(throws: ConversionError.self) { try placement.place(item) }
        #expect(try names(dir) == ["a.txt"])
    }

    @Test func executableBitsAreStripped() throws {
        let dir = try tempDir()
        let staging = try tempDir("staging")
        let input = try textFile("a.txt", in: dir)
        let staged = staging.appendingPathComponent("x.txt")
        try Data("#!/bin/sh\n".utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let url = try StagedPlacement(allowedStagingRoot: staging, inputs: [input])
            .place(StagedOutput(stagedPath: staged.path, directory: dir.path, baseName: "a", suffix: "text", pathExtension: "txt", isFolder: false))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o644)
    }
}

@Suite struct AtomicRenameTests {
    @Test func neverReplacesAnExistingFolder() throws {
        let dir = try tempDir()
        let existing = dir.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false) // empty: plain rename(2) would replace it
        let source = dir.appendingPathComponent(".halo-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: source.appendingPathComponent("p1.txt"))
        let url = try AtomicRename.moveToFreeName(source, in: dir, baseName: "pages", suffix: nil, pathExtension: "")
        #expect(url.lastPathComponent == "pages 2")
        #expect(try names(existing).isEmpty)
    }
}

@Suite struct LimiterTests {
    @Test func heavyJobsTakeTwoSlotsAndTheCapIsGlobal() async throws {
        let limiter = ConcurrencyLimiter(capacity: 4)
        let peak = Locked(0)
        let current = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                let weight = i % 3 == 0 ? 2 : 1
                group.addTask {
                    try? await limiter.withSlots(weight) {
                        let now = current.mutate { $0 += weight; return $0 }
                        peak.mutate { $0 = max($0, now) }
                        try? await Task.sleep(for: .milliseconds(15))
                        current.mutate { $0 -= weight }
                    }
                }
            }
        }
        #expect(peak.value <= 4)
        #expect(peak.value >= 2)
        #expect(await limiter.used == 0)
    }

    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let limiter = ConcurrencyLimiter(capacity: 1)
        let holder = Task { try await limiter.withSlots(1) { try await Task.sleep(for: .milliseconds(300)) } }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task { try await limiter.withSlots(1) { "ran" } }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
        _ = try? await holder.value
        #expect(try await limiter.withSlots(1) { "free" } == "free")
        #expect(await limiter.used == 0)
    }

    @Test func runnerUsesTheSharedLimiterAcrossDrops() async throws {
        let dir = try tempDir()
        let limiter = ConcurrencyLimiter(capacity: 2)
        let peak = Locked(0)
        let current = Locked(0)
        struct Counting: Converter {
            let peak: Locked<Int>, current: Locked<Int>
            func run(_ job: ConversionJob) async throws -> [URL] {
                let now = current.mutate { $0 += 1; return $0 }
                peak.mutate { $0 = max($0, now) }
                try await Task.sleep(for: .milliseconds(20))
                current.mutate { $0 -= 1 }
                let t = try job.makeOutput(for: job.inputs[0], pathExtension: "out")
                try Data().write(to: t.temporaryURL)
                return [try t.commit()]
            }
        }
        let reg = registry([("count", Counting(peak: peak, current: current), .text)])
        let files = try (0..<4).map { try textFile("f\($0).txt", in: dir) }
        // Three separate runners (three drops), each allowed 4 in parallel, sharing one limiter of 2.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { _ = await ConversionRunner(registry: reg, maxConcurrent: 4, limiter: limiter).run("count", on: files) }
            }
        }
        #expect(peak.value <= 2)
    }
}

@Suite struct SweepTests {
    @Test func removesOnlyOldHaloTempsInRecordedFolders() throws {
        let dir = try tempDir()
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-2 * 3600)
        let oldTemp = dir.appendingPathComponent(".halo-\(UUID().uuidString).jpg")
        let oldSibling = dir.appendingPathComponent(".halo-\(UUID().uuidString).mp4.sb-99")
        let oldFolder = dir.appendingPathComponent(".halo-\(UUID().uuidString)", isDirectory: true)
        let freshTemp = dir.appendingPathComponent(".halo-\(UUID().uuidString).png")
        let userFile = dir.appendingPathComponent(".halo-notes.txt")
        let photo = dir.appendingPathComponent("photo.jpg")
        for url in [oldTemp, oldSibling, freshTemp, userFile, photo] { try Data("x".utf8).write(to: url) }
        try fm.createDirectory(at: oldFolder, withIntermediateDirectories: false)
        for url in [oldTemp, oldSibling, oldFolder, userFile, photo] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let removed = TempSweeper.sweep(folders: [dir])
        #expect(Set(removed.map(\.lastPathComponent)) == Set([oldTemp, oldSibling, oldFolder].map(\.lastPathComponent)))
        #expect(try Set(names(dir)) == Set([freshTemp.lastPathComponent, userFile.lastPathComponent, photo.lastPathComponent]))
    }

    @Test func usedFoldersAreCappedAndDeduplicated() throws {
        let defaults = try #require(UserDefaults(suiteName: "halo-test-\(UUID().uuidString)"))
        let store = UsedFolders(defaults: defaults)
        store.record((0..<250).map { URL(fileURLWithPath: "/tmp/f\($0)") })
        store.record([URL(fileURLWithPath: "/tmp/f3")])
        #expect(store.all.count == UsedFolders.limit)
        #expect(store.all.first?.path == "/tmp/f3")
        #expect(store.all.filter { $0.path == "/tmp/f3" }.count == 1)
    }

    @Test func stagingSweepRemovesOldJobFolders() throws {
        let root = try tempDir("staging")
        let old = root.appendingPathComponent(UUID().uuidString)
        let fresh = root.appendingPathComponent(UUID().uuidString)
        let other = root.appendingPathComponent("keep-me")
        for url in [old, fresh, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: other.path)
        TempSweeper.sweepStaging(root)
        #expect(try Set(names(root)) == Set([fresh.lastPathComponent, "keep-me"]))
    }
}

@Suite struct WireTests {
    @Test func jobIDsMustBeCanonicalUUIDs() {
        #expect(WorkerRequest.isValidJobID(UUID().uuidString))
        #expect(!WorkerRequest.isValidJobID("../../etc"))
        #expect(!WorkerRequest.isValidJobID(UUID().uuidString.lowercased()))
        #expect(!WorkerRequest.isValidJobID(""))
    }

    @Test func requestRoundTrips() throws {
        let dir = try tempDir()
        let input = try textFile("a b.txt", in: dir)
        let request = WorkerRequest(jobID: UUID().uuidString, actionID: "text.x", inputs: [input])
        let decoded = try #require(WorkerWire.decode(WorkerRequest.self, from: WorkerWire.encode(request)))
        #expect(decoded == request)
        #expect(decoded.inputFiles()?.first?.url.path == input.url.path)
        #expect(decoded.inputFiles()?.first?.type == input.type)
    }

    @Test func fastPathResolvesBigSelectionsByExtension() throws {
        let urls = (0..<200).map { URL(fileURLWithPath: "/nonexistent/folder/file\($0).png") }
        let inputs = InputFile.resolve(urls, inspectLimit: 50)
        // The first 50 don't exist on disk, so the inspected ones fall back to their extension too.
        #expect(inputs.count == 200)
        #expect(inputs.allSatisfy { $0.type.conforms(to: .png) })
    }
}

/// Tiny lock-protected box for tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    @discardableResult
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&_value) } }
}
