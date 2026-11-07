import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloCore

private func tempDir(_ label: String = "fix") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

// MARK: - Review 5: one disk check at a time

@Suite struct ResolveGateTests {
    /// Each summon on a stalled share used to leave one more blocked thread behind. Now the second one doesn't wait or
    /// queue: it goes to the names, and says the answer is incomplete.
    @Test func aStuckCheckIsNotJoinedByMore() {
        let gate = ResolveGate(label: "test.gate")
        let release = DispatchSemaphore(value: 0)
        let calls = Counter()
        let urls = [URL(fileURLWithPath: "/Volumes/slow/Folder"), URL(fileURLWithPath: "/Volumes/slow/a.png")]
        let first = InputFile.resolveWithinBudget(0.03, urls, gate: gate) { _, _ in
            calls.bump()
            release.wait()
            return []
        }
        #expect(!first.complete)
        #expect(gate.isBusy)
        let started = Date()
        let second = InputFile.resolveWithinBudget(1, urls, gate: gate) { _, _ in calls.bump(); return [] }
        #expect(Date().timeIntervalSince(started) < 0.5, "doesn't wait behind the stuck one")
        #expect(!second.complete)
        #expect(second.inputs.map(\.type) == [.png])
        #expect(calls.count == 1, "no second check queued")
        release.signal()
        for _ in 0..<100 where gate.isBusy { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!gate.isBusy)
        let third = InputFile.resolveWithinBudget(1, urls, gate: gate) { urls, _ in
            [InputFile(url: urls[0], type: .folder), InputFile(url: urls[1], type: .png)]
        }
        #expect(third.complete && third.inputs.map(\.type) == [.folder, .png])
    }
}

// MARK: - Review 11: a vanished folder stays vanished

@Suite struct CanWriteTests {
    @Test func aMissingSourceFolderIsNotRecreated() throws {
        let gone = try tempDir().appendingPathComponent("Moved Away", isDirectory: true)
        #expect(!SavePolicy.canWrite(gone))
        #expect(!FileManager.default.fileExists(atPath: gone.path), "the check made the folder again")
    }

    @Test func aMissingFallbackFolderIsStillMade() throws {
        let fallback = try tempDir().appendingPathComponent("Downloads", isDirectory: true)
        let gone = try tempDir().appendingPathComponent("Moved Away", isDirectory: true)
        let policy = SavePolicy(fallbackFolder: fallback)
        #expect(policy.plan(forFolders: [gone]) == .fallback(folder: fallback, blocked: [gone]))
        #expect(FileManager.default.fileExists(atPath: fallback.path))
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }
}

// MARK: - Security 6: promised copies

@Suite struct PromiseInboxHardeningTests {
    @Test func theInboxAndDropFoldersArePrivate() throws {
        let root = try tempDir().appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let inbox = PromiseInbox(root: root)
        let drop = try inbox.makeDropFolder()
        func mode(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        #expect(try mode(root) == 0o700, "an existing looser inbox is tightened")
        #expect(try mode(drop) == 0o700)
    }

    @Test func aCrashesLeftoversGoAfterFiveMinutes() throws {
        #expect(PromiseInbox.leftoverMaxAge == 300)
        let inbox = PromiseInbox(root: try tempDir().appendingPathComponent("inbox"))
        let old = try inbox.makeDropFolder(), fresh = try inbox.makeDropFolder()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 60)], ofItemAtPath: old.path)
        inbox.sweep()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Review 4: Cancel, a replacing drop or a drop nothing fits leaves promised copies nobody will convert.
    @Test func abandonedCopiesGoButKeptOnesStay() throws {
        let inbox = PromiseInbox(root: try tempDir().appendingPathComponent("inbox"))
        let a = try inbox.makeDropFolder(), b = try inbox.makeDropFolder()
        let fa = a.appendingPathComponent("IMG_1.heic"), fb = b.appendingPathComponent("IMG_2.heic")
        try Data([1]).write(to: fa)
        try Data([1]).write(to: fb)
        let outside = try tempDir().appendingPathComponent("mine.heic")
        try Data([1]).write(to: outside)
        inbox.remove(abandoned: [fa, fb, outside], keeping: [fb])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: fb.path), "a running job's copy stays")
        #expect(FileManager.default.fileExists(atPath: outside.path), "never a user's own file")
    }
}

// MARK: - Security 5: quarantine on every output

@Suite struct QuarantineEveryOutputTests {
    private func setQuarantine(_ value: String, on url: URL) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { setxattr(url.path, StagedPlacement.quarantineKey, $0.baseAddress, data.count, 0, 0) }
    }

    private func quarantine(of url: URL) -> String? {
        let size = getxattr(url.path, StagedPlacement.quarantineKey, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, StagedPlacement.quarantineKey, $0.baseAddress, size, 0, 0) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A JPG made from a downloaded HEIC used to lose the download warning; only archives kept it.
    @Test func aConvertedDownloadKeepsItsQuarantine() throws {
        let folder = try tempDir(), staging = try tempDir("staging")
        let input = folder.appendingPathComponent("photo.heic")
        try Data([1]).write(to: input)
        setQuarantine("0083;6724a2b1;Safari;", on: input)
        let staged = staging.appendingPathComponent("out.jpg")
        try Data([2]).write(to: staged)
        let item = StagedOutput(stagedPath: staged.path, directory: folder.path, baseName: "photo", suffix: nil, pathExtension: "jpg", isFolder: false)
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [InputFile(url: input, type: .heic)])
        let placed = placement.place(ConversionOutcome(actionID: "image.to-jpg", outputs: [], staged: [item], failures: [], duration: .zero))
        let output = try #require(placed.outputs.first)
        #expect(quarantine(of: output) == "0083;6724a2b1;Safari;")
    }

    @Test func noQuarantineOnTheInputsMeansNoneOnTheOutput() throws {
        let folder = try tempDir()
        let input = folder.appendingPathComponent("a.png")
        try Data([1]).write(to: input)
        #expect(StagedPlacement.quarantine(of: [InputFile(url: input, type: .png)]) == nil)
    }

    /// Two downloads merged into one PDF: the output takes the strictest flags, not just the first file's.
    @Test func severalQuarantinedInputsGiveTheStrictestFlags() throws {
        let folder = try tempDir()
        let approved = folder.appendingPathComponent("a.png"), fresh = folder.appendingPathComponent("b.png")
        let plain = folder.appendingPathComponent("c.png")
        for url in [approved, fresh, plain] { try Data([1]).write(to: url) }
        setQuarantine("0041;6724a2b1;Safari;AAA", on: approved) // the user already opened it
        setQuarantine("0083;6724a2b2;Chrome;BBB", on: fresh)
        let inputs = [plain, approved, fresh].map { InputFile(url: $0, type: .png) }
        let merged = try #require(StagedPlacement.quarantine(of: inputs)).map { $0 }
        let text = String(decoding: Data(merged), as: UTF8.self)
        #expect(text == "0083;6724a2b1;Safari;AAA", "download bits from both, approval only if both had it")
        #expect(StagedPlacement.strictest([Data("0041;1;A;".utf8), Data("0043;2;B;".utf8)]).map { String(decoding: $0, as: UTF8.self) } == "0043;1;A;")
    }
}
