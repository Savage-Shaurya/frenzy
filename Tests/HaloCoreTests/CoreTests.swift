import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func file(_ name: String, in dir: URL, _ text: String = "x") throws -> InputFile {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return try #require(InputFile(url: url))
}

/// Copies the input text to a ".out" file; fails when the text is "fail".
private struct CopyConverter: Converter {
    func run(_ job: ConversionJob) async throws -> [URL] {
        try job.inputs.map { input in
            let text = try String(contentsOf: input.url, encoding: .utf8)
            if text == "fail" { throw ConversionError.engine("boom") }
            let target = try job.makeOutput(for: input, pathExtension: "out")
            try Data(text.utf8).write(to: target.temporaryURL)
            return try target.commit()
        }
    }
}

private func action(_ id: ActionID, rank: Int = 100, cardinality: InputCardinality = .each) -> ConversionAction {
    ConversionAction(id: id, title: id.rawValue, symbolName: "doc", category: .text,
                     inputTypes: [.plainText], cardinality: cardinality, defaultRank: rank, converter: CopyConverter())
}

@Suite struct OutputNamingTests {
    @Test func names() {
        #expect(OutputNaming.fileName(base: "photo", suffix: nil, index: 1, pathExtension: "jpg") == "photo.jpg")
        #expect(OutputNaming.fileName(base: "photo", suffix: nil, index: 2, pathExtension: "jpg") == "photo 2.jpg")
        #expect(OutputNaming.fileName(base: "doc", suffix: "compressed", index: 3, pathExtension: "pdf") == "doc (compressed) 3.pdf")
    }

    @Test func commitNeverOverwrites() throws {
        let dir = try tempDir()
        let input = try file("a.txt", in: dir)
        try Data("old".utf8).write(to: dir.appendingPathComponent("a.out"))
        let job = ConversionJob(actionID: "t", inputs: [input])
        let target = try job.makeOutput(for: input, pathExtension: "out")
        try Data("new".utf8).write(to: target.temporaryURL)
        let url = try target.commit()
        #expect(url.lastPathComponent == "a 2.out")
        #expect(try String(contentsOf: dir.appendingPathComponent("a.out"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: target.temporaryURL.path))
    }
}

@Suite struct RegistryTests {
    @Test func filtersAndRanks() throws {
        let dir = try tempDir()
        let txt = try file("a.txt", in: dir)
        let usage = MemoryUsageStore()
        let reg = ActionRegistry(actions: [action("b", rank: 1), action("a", rank: 2), action("merge", cardinality: .combined(min: 2))], usage: usage)
        #expect(reg.actions(for: [txt]).map(\.id) == ["b", "a"])
        usage.recordUse(of: "a")
        #expect(reg.actions(for: [txt]).map(\.id) == ["a", "b"])
        #expect(reg.actions(for: [txt, txt]).map(\.id).contains("merge"))
        #expect(reg.actions(for: [txt], limit: 1).count == 1)
    }
}

@Suite struct RunnerTests {
    @Test func batchWithPartialFailure() async throws {
        let dir = try tempDir()
        let good = try file("good.txt", in: dir, "hello")
        let bad = try file("bad.txt", in: dir, "fail")
        let runner = ConversionRunner(registry: ActionRegistry(actions: [action("copy")], usage: MemoryUsageStore()))
        let outcome = await runner.run("copy", on: [good, bad])
        #expect(outcome.outputs.map(\.lastPathComponent) == ["good.out"])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.input == bad.url)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".halo-") }
        #expect(leftovers.isEmpty)
    }

    @Test func rejectsUnknownAction() async throws {
        let dir = try tempDir()
        let runner = ConversionRunner(registry: ActionRegistry(actions: [], usage: MemoryUsageStore()))
        let outcome = await runner.run("nope", on: [try file("a.txt", in: dir)])
        #expect(!outcome.succeeded)
    }
}

@Suite struct OutputFolderTests {
    @Test func folderCommitsWithFreeName() throws {
        let dir = try tempDir()
        let input = try file("doc.txt", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("doc pages"), withIntermediateDirectories: false)
        let job = ConversionJob(actionID: "t", inputs: [input])
        let folder = try job.makeOutputFolder(named: "doc pages", in: dir)
        try Data("p1".utf8).write(to: folder.temporaryURL.appendingPathComponent("doc page 1.txt"))
        let url = try folder.commit()
        #expect(url.lastPathComponent == "doc pages 2")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("doc page 1.txt").path))
    }

    @Test func uncommittedFolderIsRemoved() throws {
        let dir = try tempDir()
        let input = try file("doc.txt", in: dir)
        let job = ConversionJob(actionID: "t", inputs: [input])
        let folder = try job.makeOutputFolder(named: "doc pages", in: dir)
        try Data("p1".utf8).write(to: folder.temporaryURL.appendingPathComponent("x.txt"))
        job.outputs.discardUncommitted()
        #expect(!FileManager.default.fileExists(atPath: folder.temporaryURL.path))
    }
}
