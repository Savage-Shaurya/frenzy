import Compression
import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct ArchiveActionTests {
    // MARK: Zip

    @Test func zipFolderOpensInMacOSToolsAndRoundTrips() async throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let outcome = await ArchiveFixtures.runner().run("archive.zip", on: [try #require(InputFile(url: trip))])
        #expect(outcome.succeeded, "\(outcome.failures)")
        let zip = try #require(outcome.outputs.first)
        #expect(zip.lastPathComponent == "Trip.zip")

        // Apple's own tools accept it: `unzip -t` checks every CRC, `ditto` extracts it.
        let test = try ArchiveFixtures.shell("/usr/bin/unzip", ["-t", zip.path])
        #expect(test.status == 0 && test.output.contains("No errors detected"), "\(test.output)")
        let listing = try ArchiveFixtures.shell("/usr/bin/unzip", ["-Z1", zip.path]).output
        #expect(!listing.contains(".DS_Store") && !listing.contains("link"), "links and .DS_Store stay out: \(listing)")
        let dittoOut = dir.appendingPathComponent("ditto-out")
        #expect(try ArchiveFixtures.shell("/usr/bin/ditto", ["-x", "-k", zip.path, dittoOut.path]).status == 0)
        try ArchiveFixtures.expectSameTree(trip, dittoOut.appendingPathComponent("Trip"), ignoring: [".DS_Store", "link"])

        // And Halo reads its own archive back: one top folder unpacks as that folder ("Trip 2", "Trip" is taken).
        let back = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        #expect(back.succeeded, "\(back.failures)")
        let folder = try #require(back.outputs.first)
        #expect(folder.lastPathComponent == "Trip 2")
        try ArchiveFixtures.expectSameTree(trip, folder, ignoring: [".DS_Store", "link"])
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func zipNamesFollowFinder() async throws {
        let dir = try Fixtures.tempDir()
        let notes = dir.appendingPathComponent("notes.txt")
        let todo = dir.appendingPathComponent("todo.md")
        try Data(String(repeating: "hello halo ", count: 500).utf8).write(to: notes)
        try Data("buy milk".utf8).write(to: todo)
        let one = await ArchiveFixtures.runner().run("archive.zip", on: [try #require(InputFile(url: notes))])
        #expect(one.outputs.map(\.lastPathComponent) == ["notes.txt.zip"])
        let original = try ArchiveFixtures.size(notes)
        #expect(try ArchiveFixtures.size(try #require(one.outputs.first)) < original / 4, "text is deflated")

        let many = await ArchiveFixtures.runner().run("archive.zip", on: [notes, todo].compactMap(InputFile.init(url:)))
        #expect(many.outputs.map(\.lastPathComponent) == ["Archive.zip"])
        let listing = try ArchiveFixtures.shell("/usr/bin/unzip", ["-Z1", try #require(many.outputs.first).path]).output
        #expect(listing.split(separator: "\n").sorted() == ["notes.txt", "todo.md"])
    }

    @Test func zipRefusesMoreThanItCanAddress() throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let job = ConversionJob(actionID: "archive.zip", inputs: [try #require(InputFile(url: trip))])
        var limits = ArchiveActions.Limits()
        limits.maxZipItems = 2
        #expect(throws: ConversionError.self) { try ArchiveActions.zip(job, limits: limits) }
        job.outputs.discardUncommitted()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Trip"])
    }

    // MARK: Unzip

    @Test func unzipReadsFinderStyleArchivesAndDropsResourceForks() async throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        try ArchiveFixtures.shell("/usr/bin/xattr", ["-w", "com.example.note", "hi", trip.appendingPathComponent("notes.txt").path])
        let zip = dir.appendingPathComponent("Trip (Finder).zip")
        // What Finder's Compress runs: resource forks and attributes go to __MACOSX.
        #expect(try ArchiveFixtures.shell("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", trip.path, zip.path]).status == 0)
        #expect(try ArchiveFixtures.shell("/usr/bin/unzip", ["-Z1", zip.path]).output.contains("__MACOSX"))

        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        #expect(outcome.succeeded, "\(outcome.failures)")
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "Trip 2")
        try ArchiveFixtures.expectSameTree(trip, folder, ignoring: [".DS_Store", "link"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("__MACOSX").path))
    }

    @Test func looseFilesUnpackIntoAFolderNamedAfterTheZip() async throws {
        let dir = try Fixtures.tempDir()
        let zip = try RawZip()
            .file("a.txt", Data("alpha".utf8))
            .file("b.txt", Data(String(repeating: "beta ", count: 100).utf8), deflate: true)
            .write(to: dir.appendingPathComponent("letters.zip"))
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "letters")
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha")
        #expect(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8).count == 500)
    }

    @Test(arguments: ["../evil.txt", "/tmp/halo-evil.txt", "safe/../../evil.txt", "..\\evil.txt", "a/./../../evil.txt"])
    func pathsThatEscapeAreRefusedWhole(_ name: String) async throws {
        let dir = try Fixtures.tempDir()
        let inner = dir.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let zip = try RawZip().file("fine.txt", Data("ok".utf8)).file(name, Data("pwned".utf8))
            .write(to: inner.appendingPathComponent("trap.zip"))
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        #expect(!outcome.succeeded)
        #expect(outcome.failures.first?.message.contains("outside its folder") == true, "\(outcome.failures)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: inner.path) == ["trap.zip"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["inner"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/halo-evil.txt"))
    }

    @Test func aLinkEntryNeverBecomesAWayOut() async throws {
        let dir = try Fixtures.tempDir()
        let zip = try RawZip()
            .link("box/escape", target: "/tmp")
            .file("box/escape/halo-through-link.txt", Data("x".utf8))
            .file("box/kept.txt", Data("kept".utf8))
            .write(to: dir.appendingPathComponent("links.zip"))
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        #expect(outcome.succeeded, "\(outcome.failures)")
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "box")
        let escape = try folder.appendingPathComponent("escape").resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        #expect(escape.isSymbolicLink == false && escape.isDirectory == true, "the link entry is skipped, never created")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/halo-through-link.txt"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kept.txt").path))
    }

    @Test func refusesPasswordsUnknownMethodsAndDamage() async throws {
        let dir = try Fixtures.tempDir()
        let text = Data(String(repeating: "halo ", count: 400).utf8)
        let cases: [(String, RawZip, String)] = [
            ("locked", RawZip().file("a.txt", text, flags: 1), "password"),
            ("bzip", RawZip().file("a.txt", text, method: 12), "compression method"),
            ("crc", RawZip().file("a.txt", text, crc: 0xDEAD_BEEF), "damaged"),
            // Declares 10 bytes but inflates to 2,000: the stream stops at the declared size.
            ("liar", RawZip().file("a.txt", text, deflate: true, declaredSize: 10), "damaged"),
            ("short", RawZip().file("a.txt", text, deflate: true, declaredSize: text.count + 50), "damaged"),
        ]
        for (name, zip, expected) in cases {
            let url = try zip.write(to: dir.appendingPathComponent("\(name).zip"))
            let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: url))])
            #expect(!outcome.succeeded, "\(name)")
            #expect(outcome.failures.first?.message.contains(expected) == true, "\(name): \(outcome.failures)")
        }
        // Not a zip at all, and a zip cut in half.
        let junk = dir.appendingPathComponent("junk.zip")
        try Data(repeating: 7, count: 300).write(to: junk)
        let whole = try Data(contentsOf: try RawZip().file("a.txt", text).write(to: dir.appendingPathComponent("whole.zip")))
        let cut = dir.appendingPathComponent("cut.zip")
        try whole.prefix(whole.count / 2).write(to: cut)
        for url in [junk, cut] {
            let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [InputFile(url: url, type: .zip)])
            #expect(outcome.failures.first?.message.contains("damaged") == true, "\(url.lastPathComponent): \(outcome.failures)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasSuffix(".zip") }
        #expect(left.isEmpty, "a refused zip leaves nothing behind: \(left)")
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func zipBombsHitTheCaps() throws {
        let dir = try Fixtures.tempDir()
        // 64 MB of zeros deflates to about 64 KB: an honest header, but far more than the (lowered) cap.
        let bomb = try RawZip().file("zeros.bin", Data(count: 64 << 20), deflate: true)
            .write(to: dir.appendingPathComponent("bomb.zip"))
        #expect(try ArchiveFixtures.size(bomb) < 1 << 20)
        var limits = ArchiveActions.Limits()
        limits.maxUnpackedBytes = 16 << 20
        let input = InputFile(url: bomb, type: .zip)
        let job = ConversionJob(actionID: "archive.unzip", inputs: [input])
        #expect(throws: ConversionError.engine("This zip would unpack to 67.1 MB, more than the 16.8 MB Frenzy unpacks at once.")) {
            try ArchiveActions.unzip(input, job: job, limits: limits) { _ in }
        }
        job.outputs.discardUncommitted()

        // Many tiny items, counting the folders they imply.
        var many = RawZip()
        for i in 0..<6 { many = many.file("d\(i)/f.txt", Data("x".utf8)) }
        let crowd = try many.write(to: dir.appendingPathComponent("crowd.zip"))
        limits = ArchiveActions.Limits()
        limits.maxItems = 10
        let crowdInput = InputFile(url: crowd, type: .zip)
        let crowdJob = ConversionJob(actionID: "archive.unzip", inputs: [crowdInput])
        #expect(throws: ConversionError.self) { try ArchiveActions.unzip(crowdInput, job: crowdJob, limits: limits) { _ in } }
        crowdJob.outputs.discardUncommitted()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["bomb.zip", "crowd.zip"])
    }

    @Test func entriesSharingDataAreRefused() async throws {
        let dir = try Fixtures.tempDir()
        // One deflated stream listed three times: the classic overlapping-entry bomb.
        let zip = try RawZip().file("a.bin", Data(count: 1 << 20), deflate: true)
            .write(to: dir.appendingPathComponent("overlap.zip"), aliasesOfFirst: 2)
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        #expect(outcome.failures.first?.message.contains("damaged") == true, "\(outcome.failures)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["overlap.zip"])
    }

    @Test func appLikeNamesNeverBecomeTheFolder() async throws {
        let dir = try Fixtures.tempDir()
        let zip = try RawZip().file("Tool.app/Contents/Info.plist", Data("<plist/>".utf8))
            .write(to: dir.appendingPathComponent("Tool.app.zip"))
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        let folder = try #require(outcome.outputs.first, "\(outcome.failures)")
        #expect(folder.lastPathComponent == "Tool")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Tool.app/Contents/Info.plist").path))

        // Placement refuses an app-like name even when it hides in the base name with no extension.
        let staging = try Fixtures.tempDir()
        let staged = staging.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [InputFile(url: zip, type: .zip)])
        for name in ["Evil.app", "Run.command", "Setup.PKG"] {
            let item = StagedOutput(stagedPath: staged.path, directory: dir.path, baseName: name, suffix: nil, pathExtension: "", isFolder: true)
            #expect(throws: ConversionError.self) { try placement.place(item, anyExtensionInside: true) }
        }
    }

    @Test func oldDOSNamesDecode() async throws {
        let dir = try Fixtures.tempDir()
        // "café.txt" in code page 437 (é = 0x82), no UTF-8 flag, as old Windows tools wrote it.
        let zip = try RawZip().file(rawName: Array("caf".utf8) + [0x82] + Array(".txt".utf8), Data("au lait".utf8))
            .file("menu.txt", Data("x".utf8))
            .write(to: dir.appendingPathComponent("old.zip"))
        let outcome = await ArchiveFixtures.runner().run("archive.unzip", on: [try #require(InputFile(url: zip))])
        let folder = try #require(outcome.outputs.first)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).map { $0.precomposedStringWithCanonicalMapping }
        #expect(names.sorted() == ["café.txt", "menu.txt"])
    }

    // MARK: Ring and placement

    @Test func foldersGetZipAndZipsGetUnzipFirst() throws {
        let dir = try Fixtures.tempDir()
        let trip = try ArchiveFixtures.folder(in: dir, name: "Trip")
        let folder = try #require(InputFile(url: trip))
        #expect(folder.type.conforms(to: .folder))
        let registry = DefaultActions.registry(usage: MemoryUsageStore())
        // Zip first, then tar.gz (folders only; checked end to end by TarArchiveTests.tarGzRoundTrip).
        #expect(registry.actions(for: [folder]).map(\.id) == ["archive.zip", "archive.to-tgz"])

        let zip = try RawZip().file("a.txt", Data("a".utf8)).write(to: dir.appendingPathComponent("a.zip"))
        #expect(registry.actions(for: [try #require(InputFile(url: zip))]).map(\.id) == ["archive.unzip", "archive.zip"])

        let png = InputFile(url: dir.appendingPathComponent("p.png"), type: .png)
        let pngActions = registry.actions(for: [png]).map(\.id)
        #expect(pngActions.first?.rawValue.hasPrefix("image.") == true)
        #expect(pngActions.last == "archive.zip", "Zip is offered, but after every real conversion")
        #expect(registry.actions(for: [png, folder]).map(\.id) == ["archive.zip"])
    }

    @Test func placedUnzipKeepsAnyFileTypeAndTheDownloadQuarantine() async throws {
        let dir = try Fixtures.tempDir()
        let zip = try RawZip()
            .file("Kit/build.swift", Data("print(1)".utf8))
            .file("Kit/run.command", Data("echo hi".utf8), unixMode: 0o100755)
            .write(to: dir.appendingPathComponent("Kit.zip"))
        let quarantine = "0083;6724a2b1;Safari;"
        try ArchiveFixtures.shell("/usr/bin/xattr", ["-w", "com.apple.quarantine", quarantine, zip.path])
        let backend = InProcessBackend(runner: ArchiveFixtures.runner(), staged: true)
        let outcome = await backend.run("archive.unzip", on: [try #require(InputFile(url: zip))]) { _ in }
        #expect(outcome.succeeded, "\(outcome.failures)")
        let folder = try #require(outcome.outputs.first)
        #expect(folder.lastPathComponent == "Kit")
        for item in [folder, folder.appendingPathComponent("build.swift"), folder.appendingPathComponent("run.command")] {
            let value = try ArchiveFixtures.shell("/usr/bin/xattr", ["-p", "com.apple.quarantine", item.path]).output
            #expect(value.trimmingCharacters(in: .whitespacesAndNewlines) == quarantine, "\(item.lastPathComponent)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("run.command").path)[.posixPermissions] as? Int
        #expect(mode == 0o644, "nothing Frenzy places is executable")

        // The lifted extension rule is for Unzip only: the same folder from any other action is refused.
        let staging = try Fixtures.tempDir()
        let staged = staging.appendingPathComponent("Kit", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged.appendingPathComponent("run.command"))
        let item = StagedOutput(stagedPath: staged.path, directory: dir.path, baseName: "Kit", suffix: nil, pathExtension: "", isFolder: true)
        let placement = StagedPlacement(allowedStagingRoot: staging, inputs: [InputFile(url: zip, type: .zip)])
        let other = placement.place(ConversionOutcome(actionID: "pdf.split", outputs: [staged], staged: [item], failures: [], duration: .zero))
        #expect(other.outputs.isEmpty && other.failures.count == 1)
    }

    @Test func zipOfADownloadStaysQuarantined() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("installer.pkg")
        try Data("pkg".utf8).write(to: file)
        try ArchiveFixtures.shell("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;6724a2b1;Safari;", file.path])
        let backend = InProcessBackend(runner: ArchiveFixtures.runner(), staged: true)
        let outcome = await backend.run("archive.zip", on: [try #require(InputFile(url: file))]) { _ in }
        let zip = try #require(outcome.outputs.first)
        #expect(try ArchiveFixtures.shell("/usr/bin/xattr", ["-p", "com.apple.quarantine", zip.path]).status == 0)
    }

    @Test func crcMatchesTheStandard() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        #expect(crc.value == 0xCBF4_3926)
    }
}

// MARK: - Fixtures

enum ArchiveFixtures {
    static func runner() -> ConversionRunner {
        ConversionRunner(registry: ActionRegistry(actions: ArchiveActions.all, usage: MemoryUsageStore()), maxConcurrent: 1)
    }

    /// "Trip/notes.txt" (compressible), "Trip/photos/beach.jpg" (random, stored), an empty folder, a hidden file,
    /// a `.DS_Store` and a symlink.
    static func folder(in dir: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let root = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data(String(repeating: "Day one: the sea. ", count: 2000).utf8).write(to: root.appendingPathComponent("notes.txt"))
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: root.appendingPathComponent("photos/beach.jpg"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("photos/blank.txt"))
        try Data([0, 0, 0, 1]).write(to: root.appendingPathComponent(".DS_Store"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc")
        return root
    }

    /// Same relative paths and bytes, ignoring `ignoring` names.
    static func expectSameTree(_ a: URL, _ b: URL, ignoring: Set<String>) throws {
        func tree(_ root: URL) throws -> [String: Data?] {
            var out: [String: Data?] = [:]
            let walker = try #require(FileManager.default.enumerator(atPath: root.path))
            while let relative = walker.nextObject() as? String {
                if ignoring.contains((relative as NSString).lastPathComponent) { continue }
                let url = root.appendingPathComponent(relative)
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                out[relative] = isDir ? nil : try Data(contentsOf: url)
            }
            return out
        }
        let left = try tree(a), right = try tree(b)
        #expect(left.keys.sorted() == right.keys.sorted())
        for (key, data) in left { #expect(right[key] == data, "\(key) differs") }
    }

    static func size(_ url: URL) throws -> Int { try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) }

    @discardableResult
    static func shell(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Builds ZIP files byte by byte, including broken and hostile ones.
struct RawZip {
    private struct Entry {
        var name: [UInt8]
        var payload: Data
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var size: UInt32
        var external: UInt32
    }

    private var entries: [Entry] = []

    func file(_ name: String, _ data: Data, deflate: Bool = false, method: UInt16? = nil, flags: UInt16 = 0,
              crc: UInt32? = nil, declaredSize: Int? = nil, unixMode: UInt32 = 0o100644) -> RawZip {
        file(rawName: Array(name.utf8), data, deflate: deflate, method: method, flags: flags, crc: crc,
             declaredSize: declaredSize, unixMode: unixMode)
    }

    func file(rawName: [UInt8], _ data: Data, deflate: Bool = false, method: UInt16? = nil, flags: UInt16 = 0,
              crc: UInt32? = nil, declaredSize: Int? = nil, unixMode: UInt32 = 0o100644) -> RawZip {
        var checksum = CRC32()
        checksum.update(data)
        let payload = deflate ? Self.deflate(data) : data
        var copy = self
        copy.entries.append(Entry(name: rawName, payload: payload, method: method ?? (deflate ? 8 : 0), flags: flags,
                                  crc: crc ?? checksum.value, size: UInt32(declaredSize ?? data.count),
                                  external: unixMode << 16))
        return copy
    }

    func link(_ name: String, target: String) -> RawZip { file(name, Data(target.utf8), unixMode: 0o120755) }

    /// `aliasesOfFirst` adds extra directory records that point at the first entry's data (a hostile trick).
    func write(to url: URL, aliasesOfFirst: Int = 0) throws -> URL {
        var out = Data()
        var central = Data()
        var all = entries.map { ($0, Optional<UInt32>.none) }
        if let first = entries.first {
            for i in 0..<aliasesOfFirst {
                var alias = first
                alias.name = Array("alias\(i).bin".utf8)
                all.append((alias, 0))
            }
        }
        for (e, sharedOffset) in all {
            if let sharedOffset {
                central.u32(0x0201_4b50); central.u16(3 << 8 | 20); central.u16(20); central.u16(e.flags); central.u16(e.method)
                central.u16(0); central.u16(0x21); central.u32(e.crc); central.u32(UInt32(e.payload.count)); central.u32(e.size)
                central.u16(UInt16(e.name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
                central.u32(e.external); central.u32(sharedOffset)
                central.append(contentsOf: e.name)
                continue
            }
            let offset = UInt32(out.count)
            out.u32(0x0403_4b50); out.u16(20); out.u16(e.flags); out.u16(e.method); out.u16(0); out.u16(0x21)
            out.u32(e.crc); out.u32(UInt32(e.payload.count)); out.u32(e.size); out.u16(UInt16(e.name.count)); out.u16(0)
            out.append(contentsOf: e.name)
            out.append(e.payload)
            central.u32(0x0201_4b50); central.u16(3 << 8 | 20); central.u16(20); central.u16(e.flags); central.u16(e.method)
            central.u16(0); central.u16(0x21); central.u32(e.crc); central.u32(UInt32(e.payload.count)); central.u32(e.size)
            central.u16(UInt16(e.name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(e.external); central.u32(offset)
            central.append(contentsOf: e.name)
        }
        let start = UInt32(out.count)
        out.append(central)
        out.u32(0x0605_4b50); out.u16(0); out.u16(0); out.u16(UInt16(all.count)); out.u16(UInt16(all.count))
        out.u32(UInt32(central.count)); out.u32(start); out.u16(0)
        try out.write(to: url)
        return url
    }

    /// Raw DEFLATE, as ZIP stores it.
    static func deflate(_ data: Data) -> Data {
        var out = Data()
        let filter = try! OutputFilter(.compress, using: .zlib) { if let chunk = $0 { out.append(chunk) } }
        try! filter.write(data)
        try! filter.finalize()
        return out
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
