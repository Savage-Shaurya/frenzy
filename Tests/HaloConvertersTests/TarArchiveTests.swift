import Compression
import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite("Tar, gzip and xz")
struct TarArchiveTests {
    private func tool(_ path: String, _ args: [String], in dir: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func unpack(_ file: URL) async throws -> ConversionOutcome {
        await ArchiveFixtures.runner().run("archive.unpack", on: [try #require(InputFile(url: file))])
    }

    private func expectDamaged(_ outcome: ConversionOutcome, in dir: URL) {
        #expect(outcome.outputs.isEmpty, "\(outcome.outputs)")
        #expect(!outcome.failures.isEmpty)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    // MARK: Real archives, made by Apple's own tar

    @Test(arguments: [("tgz", "czf"), ("tar.gz", "czf"), ("tar", "cf"), ("tar.xz", "cJf")])
    func unpacksWhatTarMakes(ending: String, flags: String) async throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let archive = dir.appendingPathComponent("holiday.\(ending)")
        #expect(try tool("/usr/bin/tar", [flags, archive.path, "-C", dir.path, "Trip"]).status == 0)
        try FileManager.default.moveItem(at: trip, to: dir.appendingPathComponent("Original"))

        let outcome = try await unpack(archive)
        #expect(outcome.succeeded, "\(outcome.failures)")
        let folder = try #require(outcome.outputs.first)
        // One folder at the top unpacks as that folder.
        #expect(folder.lastPathComponent == "Trip")
        try ArchiveFixtures.expectSameTree(dir.appendingPathComponent("Original"), folder, ignoring: [".DS_Store", "link"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("link").path), "links stay out")
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func looseFilesGoInAFolderNamedAfterTheArchive() async throws {
        let dir = try Fixtures.tempDir()
        try Data("one".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let archive = dir.appendingPathComponent("loose.tgz")
        #expect(try tool("/usr/bin/tar", ["czf", archive.path, "-C", dir.path, "a.txt", "b.txt"]).status == 0)
        let outcome = try await unpack(archive)
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "loose")
        #expect(try Data(contentsOf: folder.appendingPathComponent("b.txt")) == Data("two".utf8))
    }

    @Test func keepsDatesAndLongNames() async throws {
        let dir = try Fixtures.tempDir()
        let top = dir.appendingPathComponent("Top")
        let deep = (0..<12).reduce(top) { url, i in url.appendingPathComponent("folder-with-a-long-name-\(i)") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let long = deep.appendingPathComponent(String(repeating: "x", count: 150) + " ünï.txt")
        try Data("deep".utf8).write(to: long)
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: long.path)

        for format in ["pax", "gnutar", "ustar"] where format != "ustar" {
            let archive = dir.appendingPathComponent("names-\(format).tar")
            #expect(try tool("/usr/bin/tar", ["--format=\(format)", "-cf", archive.path, "-C", dir.path, "Top"]).status == 0)
            let outcome = try await unpack(archive)
            #expect(outcome.succeeded, "\(format): \(outcome.failures)")
            let folder = try #require(outcome.outputs.first)
            let relative = long.path.replacingOccurrences(of: top.path + "/", with: "")
            let found = folder.appendingPathComponent(relative)
            #expect(try Data(contentsOf: found) == Data("deep".utf8), "\(format)")
            let stamp = try FileManager.default.attributesOfItem(atPath: found.path)[.modificationDate] as? Date
            #expect(stamp == date, "\(format): \(String(describing: stamp))")
            try FileManager.default.removeItem(at: folder)
        }
    }

    @Test func tarGzRoundTrip() async throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let long = trip.appendingPathComponent(String(repeating: "n", count: 140) + ".txt")
        try Data("long name".utf8).write(to: long)

        let made = await ArchiveFixtures.runner().run("archive.to-tgz", on: [try #require(InputFile(url: trip))])
        #expect(made.succeeded, "\(made.failures)")
        let archive = try #require(made.outputs.first)
        #expect(archive.lastPathComponent == "Trip.tar.gz")
        #expect(archive.pathExtension == "gz")

        // Apple's own tar and gzip accept it.
        #expect(try tool("/usr/bin/gzip", ["-t", archive.path]).status == 0)
        let out = dir.appendingPathComponent("tar-out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let extracted = try tool("/usr/bin/tar", ["xzf", archive.path, "-C", out.path])
        #expect(extracted.status == 0, "\(extracted.output)")
        try ArchiveFixtures.expectSameTree(trip, out.appendingPathComponent("Trip"), ignoring: [".DS_Store", "link"])

        // And Frenzy reads back what it wrote.
        try FileManager.default.moveItem(at: trip, to: dir.appendingPathComponent("Original"))
        let back = try await unpack(archive)
        #expect(back.succeeded, "\(back.failures)")
        try ArchiveFixtures.expectSameTree(dir.appendingPathComponent("Original"), try #require(back.outputs.first), ignoring: [".DS_Store", "link"])
    }

    // MARK: Plain .gz

    private func gzip(_ name: String, _ contents: Data, in dir: URL) throws -> URL {
        let plain = dir.appendingPathComponent(name)
        try contents.write(to: plain)
        #expect(try tool("/usr/bin/gzip", ["-f", plain.path]).status == 0)
        return plain.appendingPathExtension("gz")
    }

    @Test func plainGzGivesTheFileBack() async throws {
        let dir = try Fixtures.tempDir()
        let text = Data(String(repeating: "hello frenzy ", count: 20_000).utf8)
        let archive = try gzip("notes.txt", text, in: dir)
        let outcome = try await unpack(archive)
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: out) == text)
    }

    /// `.sql` isn't a format Frenzy would write on its own, so it comes in a folder, as with Unzip.
    @Test func unusualEndingsGoInAFolder() async throws {
        let dir = try Fixtures.tempDir()
        let archive = try gzip("dump.sql", Data("select 1;".utf8), in: dir)
        let outcome = try await unpack(archive)
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "dump.sql")
        #expect(try Data(contentsOf: folder.appendingPathComponent("dump.sql")) == Data("select 1;".utf8))
    }

    @Test func gzCantPretendToBeAnApp() async throws {
        let dir = try Fixtures.tempDir()
        let archive = try gzip("run.command", Data("#!/bin/sh\ntouch /tmp/pwned\n".utf8), in: dir)
        let staging = dir.appendingPathComponent("staging")
        let runner = ArchiveFixtures.runner()
        let outcome = await runner.run("archive.unpack", on: [try #require(InputFile(url: archive))], stagingRoot: staging)
        #expect(outcome.succeeded, "\(outcome.failures)")
        let staged = try #require(outcome.staged.first)
        #expect(staged.isFolder)
        #expect(!StagedPlacement.hasDangerousExtension(staged.baseName), "\(staged.baseName)")
        let placed = StagedPlacement(allowedStagingRoot: staging, inputs: [try #require(InputFile(url: archive))]).place(outcome)
        #expect(placed.failures.isEmpty, "\(placed.failures)")
        let folder = try #require(placed.outputs.first)
        let file = folder.appendingPathComponent("run.command")
        let permissions = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o111 == 0, "never executable")
    }

    @Test func nameInsideTheGzipIsIgnored() async throws {
        let dir = try Fixtures.tempDir()
        // FNAME says "../../evil.txt". The file on disk says "safe.txt.gz".
        let member = try Self.gzipMember(Data("hi".utf8), name: "../../evil.txt")
        let file = dir.appendingPathComponent("safe.txt.gz")
        try member.write(to: file)
        let outcome = try await unpack(file)
        #expect(try #require(outcome.outputs.first).lastPathComponent == "safe.txt")
    }

    @Test func severalMembersJoinUp() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("joined.txt.gz")
        try (Self.gzipMember(Data("one ".utf8)) + Self.gzipMember(Data("two".utf8))).write(to: file)
        let outcome = try await unpack(file)
        #expect(try Data(contentsOf: try #require(outcome.outputs.first)) == Data("one two".utf8))
    }

    // MARK: Damage

    @Test(arguments: ["tar", "gz", "tgz", "xz"])
    func randomBytesAreRefused(ext: String) async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("junk.\(ext)")
        var bytes = Data(count: 100_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: file)
        expectDamaged(try await unpack(file), in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["junk.\(ext)"])
    }

    @Test(arguments: [("tgz", "czf"), ("tar", "cf"), ("tar.xz", "cJf")])
    func truncatedIsRefusedWhole(ending: String, flags: String) async throws {
        let dir = try Fixtures.tempDir()
        _ = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let archive = dir.appendingPathComponent("whole.\(ending)")
        #expect(try tool("/usr/bin/tar", [flags, archive.path, "-C", dir.path, "Trip"]).status == 0)
        let bytes = try Data(contentsOf: archive)
        let cut = dir.appendingPathComponent("cut.\(ending)")
        try bytes.prefix(bytes.count * 3 / 5).write(to: cut)
        let outcome = try await unpack(cut)
        #expect(outcome.outputs.isEmpty, "half an archive is not a result")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cut").path))
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func wrongGzipChecksumIsRefused() async throws {
        let dir = try Fixtures.tempDir()
        var bytes = try Self.gzipMember(Data(String(repeating: "x", count: 5_000).utf8))
        bytes[bytes.count - 6] ^= 0xFF
        let file = dir.appendingPathComponent("bad.txt.gz")
        try bytes.write(to: file)
        expectDamaged(try await unpack(file), in: dir)
    }

    @Test func wrongTarChecksumIsRefused() async throws {
        let dir = try Fixtures.tempDir()
        var block = Self.tarEntry("a.txt", body: Data("hi".utf8))
        block[0] = 0x62 // Changes the name without fixing the checksum.
        let file = dir.appendingPathComponent("bad.tar")
        try (block + Data(count: 1024)).write(to: file)
        expectDamaged(try await unpack(file), in: dir)
    }

    // MARK: Hostile

    @Test(arguments: ["../evil.txt", "a/../../evil.txt", "/etc/evil.txt", "a\\..\\..\\evil.txt"])
    func unsafePathsRefuseTheWholeArchive(name: String) async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("trap.tar")
        // A good file first: nothing at all gets written, not even that.
        try (Self.tarEntry("good.txt", body: Data("fine".utf8)) + Self.tarEntry(name, body: Data("bad".utf8)) + Data(count: 1024)).write(to: file)
        let outcome = try await unpack(file)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("outside its folder") == true, "\(outcome.failures)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["trap.tar"])
    }

    @Test func linksAndDevicesAreSkipped() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("links.tar")
        let link = Self.tarEntry("escape", body: Data(), type: 0x32, linkTarget: "/etc/passwd")
        let hard = Self.tarEntry("hard", body: Data(), type: 0x31, linkTarget: "/etc/passwd")
        let device = Self.tarEntry("device", body: Data(), type: 0x33)
        let fifo = Self.tarEntry("fifo", body: Data(), type: 0x36)
        try (link + hard + device + fifo + Self.tarEntry("real.txt", body: Data("real".utf8)) + Data(count: 1024)).write(to: file)
        let outcome = try await unpack(file)
        let folder = try #require(outcome.outputs.first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["real.txt"])
    }

    /// A symlink can't be planted and then written through, because links are never created at all.
    @Test func cantWriteThroughALink() async throws {
        let dir = try Fixtures.tempDir()
        let target = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("trick.tar")
        let link = Self.tarEntry("top/link", body: Data(), type: 0x32, linkTarget: target.path)
        let through = Self.tarEntry("top/link/pwned.txt", body: Data("pwned".utf8))
        try (link + through + Data(count: 1024)).write(to: file)
        _ = try await unpack(file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func bombsHitTheCap() async throws {
        let dir = try Fixtures.tempDir()
        // 3 MB of zeros, compressed to almost nothing, against a 1 MB cap.
        let bomb = try Self.gzipMember(Data(count: 3_000_000))
        #expect(bomb.count < 10_000)
        let file = dir.appendingPathComponent("bomb.txt.gz")
        try bomb.write(to: file)
        let input = try #require(InputFile(url: file))
        var limits = ArchiveActions.Limits()
        limits.maxUnpackedBytes = 1 << 20
        let job = ConversionJob(actionID: "archive.unpack", inputs: [input])
        #expect(throws: ConversionError.self) { _ = try ArchiveActions.unpack(input, job: job, limits: limits) { _ in } }

        let tar = dir.appendingPathComponent("bomb.tar.gz")
        try (Self.gzipMember(Self.tarEntry("zeros.bin", body: Data(count: 3_000_000)) + Data(count: 1024))).write(to: tar)
        let tarInput = try #require(InputFile(url: tar))
        let tarJob = ConversionJob(actionID: "archive.unpack", inputs: [tarInput])
        #expect(throws: ConversionError.self) { _ = try ArchiveActions.unpack(tarInput, job: tarJob, limits: limits) { _ in } }
        // The size is checked in the first pass, so no folder ever appears.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bomb").path))
    }

    @Test func tooManyItemsHitTheCap() async throws {
        let dir = try Fixtures.tempDir()
        var data = Data()
        for i in 0..<20 { data += Self.tarEntry("f\(i).txt", body: Data("x".utf8)) }
        let file = dir.appendingPathComponent("many.tar")
        try (data + Data(count: 1024)).write(to: file)
        let input = try #require(InputFile(url: file))
        var limits = ArchiveActions.Limits()
        limits.maxItems = 10
        let job = ConversionJob(actionID: "archive.unpack", inputs: [input])
        #expect(throws: ConversionError.self) { _ = try ArchiveActions.unpack(input, job: job, limits: limits) { _ in } }
    }

    @Test func aHugeClaimedSizeIsDamageNotAnAllocation() async throws {
        let dir = try Fixtures.tempDir()
        // The header claims a petabyte. Only the bytes that exist get read.
        let file = dir.appendingPathComponent("liar.tar")
        try (Self.tarEntry("big.bin", body: Data("tiny".utf8), claimedSize: 1 << 50) + Data(count: 1024)).write(to: file)
        let outcome = try await unpack(file)
        #expect(outcome.outputs.isEmpty)
        #expect(!outcome.failures.isEmpty)
    }

    @Test func sparseIsSaidPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("sparse.tar")
        try (Self.tarEntry("hole.bin", body: Data(), type: 0x53) + Data(count: 1024)).write(to: file)
        let outcome = try await unpack(file)
        #expect(outcome.failures.first?.message.contains("can't open yet") == true, "\(outcome.failures)")
    }

    @Test func emptyIsSaidPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("empty.tar")
        try Data(count: 1024).write(to: file)
        let outcome = try await unpack(file)
        #expect(outcome.outputs.isEmpty)
        #expect(!outcome.failures.isEmpty)
    }

    @Test func cancelStopsAndLeavesNothing() async throws {
        let dir = try Fixtures.tempDir()
        var contents = Data()
        for i in 0..<30 {
            var body = Data(count: 4_000_000)
            body.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            contents += Self.tarEntry("f\(i).bin", body: body)
        }
        let file = dir.appendingPathComponent("big.tar")
        try (contents + Data(count: 1024)).write(to: file)
        let input = try #require(InputFile(url: file))
        let task = Task { await ArchiveFixtures.runner().run("archive.unpack", on: [input]) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.outputs.isEmpty)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["big.tar"])
    }

    @Test func offeredForTheRightFiles() {
        func ids(_ ext: String) -> [String] {
            let type = UTType(filenameExtension: ext)!
            return DefaultActions.registry(usage: MemoryUsageStore())
                .actions(for: [InputFile(url: URL(fileURLWithPath: "/tmp/x.\(ext)"), type: type)], limit: 99).map(\.id.rawValue)
        }
        for ext in ["tar", "gz", "tgz", "xz"] { #expect(ids(ext).first == "archive.unpack", "\(ext): \(ids(ext))") }
        #expect(!ids("zip").contains("archive.unpack"))
        #expect(!ids("txt").contains("archive.to-tgz"), "folders only")
    }

    // MARK: Builders

    /// One tar entry written by hand, so a test can say things no honest tool would.
    static func tarEntry(_ name: String, body: Data, type: UInt8 = 0x30, linkTarget: String = "", claimedSize: Int64? = nil) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func set(_ text: String, at start: Int) { for (i, b) in text.utf8.enumerated() { block[start + i] = b } }
        set(name, at: 0)
        set("0000644\0", at: 100)
        set("0000000\0", at: 108)
        set("0000000\0", at: 116)
        set(String(format: "%011llo\0", claimedSize ?? Int64(body.count)), at: 124)
        set("14000000000\0", at: 136)
        set("        ", at: 148)
        block[156] = type
        set(linkTarget, at: 157)
        set("ustar\0" + "00", at: 257)
        let sum = block.reduce(0) { $0 + Int($1) }
        set(String(format: "%06o\0 ", sum), at: 148)
        var data = Data(block) + body
        if body.count % 512 != 0 { data += Data(count: 512 - body.count % 512) }
        return data
    }

    /// A gzip member, written by hand so the header can carry whatever the test wants.
    static func gzipMember(_ contents: Data, name: String? = nil) throws -> Data {
        let box = DeflateBox()
        let filter = try OutputFilter(.compress, using: .zlib) { if let chunk = $0 { box.data.append(chunk) } }
        try filter.write(contents)
        try filter.finalize()
        var member = Data([0x1F, 0x8B, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 0x03])
        if let name { member += Data(name.utf8) + Data([0]) }
        member += box.data
        var crc = CRC32()
        crc.update(contents)
        withUnsafeBytes(of: crc.value.littleEndian) { member.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: contents.count).littleEndian) { member.append(contentsOf: $0) }
        return member
    }
}

private final class DeflateBox: @unchecked Sendable { var data = Data() }
