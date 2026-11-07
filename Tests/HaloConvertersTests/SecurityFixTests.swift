import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import HaloConverters
@testable import HaloCore

// Regression tests for the Nov 2026 security review: the SVG allowlist, per-job scratch folders, the engine probe's
// limits, the MOV data-reference options and orphaned engines. No test here touches video.

// MARK: - SVG allowlist (finding 1)

@Suite("SVG guard")
struct SVGGuardTests {
    private static let head = #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="20" height="20">"#
    private static func doc(_ body: String) -> String { head + body + "</svg>" }
    private static let standardDoctype = #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"#

    static let hostile: [String] = [
        doc(#"<image href=" file:///etc/hosts"/>"#),
        doc(#"<image href="FILE:///etc/hosts"/>"#),
        doc(#"<image href="&#102;ile:///etc/hosts"/>"#),
        doc(#"<image xlink:href="&#x66;&#x69;&#x6c;&#x65;&#x3a;///etc/hosts"/>"#),
        doc(#"<image href="file&#x3A;///etc/hosts"/>"#),
        doc(#"<image href="../secret.png"/>"#),
        doc(#"<image href="secret.png"/>"#),
        doc(#"<image href="/Users/someone/Pictures/secret.png"/>"#),
        doc(#"<image href="//example.com/x.png"/>"#),
        doc(#"<image href="javascript:alert(1)"/>"#),
        doc(#"<image href=""/>"#),
        doc(#"<use href="other.svg#a"/>"#),
        doc(#"<image href="data:image/svg+xml;base64,PHN2Zy8+"/>"#),
        doc(#"<rect fill="url(other.svg#g)"/>"#),
        doc(#"<rect fill="url( 'file:///etc/hosts' )"/>"#),
        doc(#"<rect style="fill:URL(file:///etc/hosts)"/>"#),
        doc(#"<rect style="fill:\75 rl(file:///etc/hosts)"/>"#),
        doc(#"<style>rect { fill: url("x.png") }</style>"#),
        doc(#"<style><![CDATA[ rect { fill: url(file:///etc/hosts) } ]]></style>"#),
        doc(#"<style>@IMPORT 'x.css';</style>"#),
        doc(#"<style>@import url(#ok);</style>"#),
        doc(#"<style>rect { fill: \75 rl(x.png) }</style>"#),
        doc(#"<style>rect { background: image-set("x.png" 1x) }</style>"#),
        doc(#"<animate attributeName="href" to="file:///etc/hosts"/>"#),
        doc(#"<set attributeName="xlink:href" to="x.png"/>"#),
        doc(#"<foreignObject width="9" height="9"><img xmlns="http://www.w3.org/1999/xhtml" src="file:///etc/hosts"/></foreignObject>"#),
        #"<?xml-stylesheet href="file:///etc/x.css"?>"# + doc(""),
        #"<!DOCTYPE svg SYSTEM "file:///etc/passwd">"# + doc(""),
        #"<!DOCTYPE svg>"# + doc(""),
        #"<!doctype svg [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;">]>"# + doc("<text>&b;</text>"),
        #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [<!ENTITY a "b">]>"# + doc(""),
        standardDoctype + standardDoctype + doc(""),
        doc("<g>" + standardDoctype + "</g>"),
        #"<?xml version="1.0" encoding="UTF-16"?>"# + doc(""),
        #"<?xml version="1.0" encoding="ISO-8859-1"?>"# + doc(""),
        #"<?xml version="1.0" encoding='utf-7'?>"# + doc(""),
        doc("<text>&unknown;</text>"),
    ]

    @Test(arguments: hostile)
    func hostileSVGIsRefused(text: String) {
        #expect(throws: ConversionError.self, "\(text)") { try VectorActions.checkSafe(Data(text.utf8)) }
    }

    @Test func otherEncodingsAreRefused() {
        let text = Self.doc(#"<image href="file:///etc/hosts"/>"#)
        for data in [Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!,
                     Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!,
                     text.data(using: .utf16LittleEndian)!,
                     text.data(using: .utf32LittleEndian)!,
                     Data([0x3C, 0x73, 0x76, 0x67, 0xC0, 0xAF, 0x3E])] {
            #expect(throws: ConversionError.self) { try VectorActions.checkSafe(data) }
        }
    }

    static let fine: [String] = [
        doc(##"<image href="data:image/png;base64,AAAA"/><use href="#a"/><rect fill="url(#g)"/>"##),
        doc(#"<image xlink:href=" DATA:image/jpeg;base64,AAAA"/><rect style="fill: url( '#g' ); stroke:red"/>"#),
        doc(#"<style>rect { fill: url(#g) } /* a comment */</style><rect id="a"/>"#),
        doc(#"<!-- <!ENTITY in a comment is just text --><text>Tom &amp; Jerry &#x263A;</text>"#),
        doc(##"<a href="#top"><text>C:\Users\path in plain text</text></a>"##),
        #"<?xml version="1.0" encoding="UTF-8" standalone="no"?>"# + doc("<rect/>"),
        #"<?xml version="1.0" encoding="utf-8"?><!-- Generator: Adobe Illustrator -->"# + "\n" + standardDoctype + "\n" + doc("<rect/>"),
        "\u{FEFF}" + doc("<rect/>"),
    ]

    @Test(arguments: fine)
    func ordinarySVGIsAccepted(text: String) throws {
        try VectorActions.checkSafe(Data(text.utf8))
    }

    @Test func theStandardDoctypeIsCutOutBeforeAnyParserSeesIt() throws {
        let text = #"<?xml version="1.0"?>"# + Self.standardDoctype + Self.doc(#"<rect width="9" height="9"/>"#)
        let clean = String(decoding: try VectorActions.sanitized(Data(text.utf8)), as: UTF8.self)
        #expect(!clean.lowercased().contains("doctype"))
        #expect(clean.contains("<rect"))
    }

    /// The reason for the guard: CoreSVG really does draw a picture from another file into the result, by relative path,
    /// absolute path or file URL. Measured on macOS 27 (7 Nov 2026). If Apple ever stops this, the first expectation
    /// fails and this comment needs updating; the guard stays either way.
    @Test func coreSVGLoadsAnOutsidePicture() async throws {
        let dir = try Fixtures.tempDir()
        let red = dir.appendingPathComponent("red.png")
        try ImageWriter.write(Self.solid(r: 255, g: 0, b: 0), as: .png, to: red)
        let hostile = Self.doc(#"<image href="file://\#(red.path)" width="20" height="20"/>"#)

        let unguarded = try #require(NSImage(data: Data(hostile.utf8)))
        let pixel = try Self.centre(try VectorActions.render(unguarded, width: 20, height: 20))
        #expect(pixel.r > 200 && pixel.g < 50 && pixel.a > 200, "CoreSVG loaded the outside file: \(pixel)")

        // Through Frenzy it is refused before CoreSVG sees it, and nothing is written.
        let file = dir.appendingPathComponent("hostile.svg")
        try Data(hostile.utf8).write(to: file)
        let registry = DefaultActions.registry(usage: MemoryUsageStore())
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("image.svg-to-png", on: [try #require(InputFile(url: file))])
        #expect(outcome.outputs.isEmpty && outcome.failures.count == 1)
        #expect(outcome.failures.first?.message.contains("outside itself") == true, "\(outcome.failures)")
    }

    private static func solid(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private static func centre(_ image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
        let p = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2], p[3])
    }
}

// MARK: - Scratch folders (finding 3)

@Suite("Converter scratch")
struct ConverterScratchTests {
    @Test func scratchGoesInsideTheJobsStagingFolder() throws {
        let staging = try Fixtures.tempDir().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let job = ConversionJob(actionID: "image.to-webp", inputs: [], stagingRoot: staging)
        let folder = try ConverterScratch.folder("webp", job: job)
        #expect(folder.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
        #expect(ConverterScratch.isScratchName(folder.lastPathComponent))

        let loose = try ConverterScratch.folder("epub", job: ConversionJob(actionID: "x", inputs: [], stagingRoot: nil))
        defer { try? FileManager.default.removeItem(at: loose) }
        #expect(loose.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test func startupSweepRemovesOnlyScratchFolders() throws {
        let dir = try Fixtures.tempDir()
        let fm = FileManager.default
        let webp = dir.appendingPathComponent("frenzy-webp-\(UUID().uuidString)")
        let epub = dir.appendingPathComponent("frenzy-epub-\(UUID().uuidString)")
        for folder in [webp, epub] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("decoded picture".utf8).write(to: folder.appendingPathComponent("image.png"))
        }
        let keep = ["frenzy-engine-pids", "frenzy-webp-notauuid", "Frenzy-webp-\(UUID().uuidString)", "frenzy-\(UUID().uuidString)", "HaloStaging", "notes.txt"]
        for name in keep { try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }
        // A link that looks like scratch is never followed or removed.
        let target = try Fixtures.tempDir()
        try Data("x".utf8).write(to: target.appendingPathComponent("precious"))
        let link = dir.appendingPathComponent("frenzy-epub-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        // Fresh ones may belong to another copy of Frenzy converting right now.
        #expect(ConverterScratch.sweep(dir).isEmpty)
        let removed = Set(ConverterScratch.sweep(dir, now: Date().addingTimeInterval(601)).map(\.lastPathComponent))
        #expect(removed == [webp.lastPathComponent, epub.lastPathComponent])
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == Set(keep + [link.lastPathComponent]))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("precious").path))
    }
}

// MARK: - Engine probe and MOV data references (findings 7 and 9)

@Suite("Engine hardening")
struct EngineHardeningTests {
    @Test func probeUsesTheHardenedArguments() {
        let url = URL(fileURLWithPath: "/tmp/-i http:x.webm")
        let args = MediaEngine.probeArguments(url)
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("-max_alloc") == String(MediaEngine.maxAllocation))
        #expect(value("-timelimit").flatMap(Int.init).map { $0 >= 60 } == true)
        #expect(value("-protocol_whitelist") == "file,pipe")
        #expect(value("-max_pixels") == String(MediaEngine.maxFramePixels))
        #expect(value("-loglevel") == "info")
        #expect(args.contains("-nostdin"))
        #expect(Array(args.suffix(2)) == ["-i", "file:/tmp/-i http:x.webm"])
    }

    @Test func containerIsReadFromTheProbeAndOnlyMOVGetsDrefOptions() throws {
        let mov = try #require(MediaProbe.parse("""
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'file:/x/a, from 'b.wav':
          Duration: 00:00:01.00, start: 0.000000, bitrate: 1 kb/s
          Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s (default)
        """))
        #expect(mov.container == "mov,mp4,m4a,3gp,3g2,mj2")
        #expect(mov.demuxerOptions == ["-use_absolute_path", "0", "-enable_drefs", "0"])

        // A hostile file name can't make another file look like MOV.
        let wav = try #require(MediaProbe.parse("""
        Input #0, wav, from 'file:/x/Input #0, mov,mp4, from 'y.wav':
          Duration: 00:00:01.00, bitrate: 128 kb/s
          Stream #0:0: Audio: pcm_s16le ([1][0][0][0] / 0x0001), 8000 Hz, mono, s16, 128 kb/s
        """))
        #expect(wav.container == "wav")
        #expect(wav.demuxerOptions.isEmpty)
    }

    /// The built engine accepts the pinned MOV options (so they really are applied) and an M4A still converts.
    @Test(.enabled(if: MediaEngine.isAvailable))
    func movInputConvertsWithDrefsPinnedOff() async throws {
        let dir = try Fixtures.tempDir()
        let m4a = dir.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for i in 0..<44_100 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.06) * 0.3 }
            try file.write(from: buffer)
        }
        let probe = try await MediaEngine.probe(m4a)
        #expect(probe.container.hasPrefix("mov,"))
        #expect(!probe.demuxerOptions.isEmpty)

        let out = dir.appendingPathComponent("tone.mp3")
        try await MediaEngine.convert(input: m4a, output: out, inputOptions: probe.demuxerOptions,
                                      outputArguments: ["-c:a", "libmp3lame", "-q:a", "4", "-f", "mp3"],
                                      expectedSeconds: probe.seconds, checkLength: true) { _ in }
        #expect(try AVAudioFile(forReading: out).length > 0)

        // And end to end through the ring's action.
        let registry = ActionRegistry(actions: DefaultActions.all(engine: true), usage: MemoryUsageStore())
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("audio.to-mp3", on: [try #require(InputFile(url: m4a))])
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        #expect(outcome.outputs.count == 1)
    }
}

// MARK: - Orphaned engines (finding 8)

@Suite("Engine orphans", .serialized)
struct EngineOrphanTests {
    private static let sleep = URL(fileURLWithPath: "/bin/sleep")

    /// Starts `/bin/sleep` in the background of a shell that exits at once, so launchd adopts it like a dead worker's engine.
    private static func orphan() throws -> pid_t {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30 >/dev/null 2>&1 </dev/null & echo $!"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Wait until it is both adopted by launchd and already /bin/sleep: under load the forked shell child can be
        // orphaned before it execs, and a note taken then names /bin/sh (the real engine is spawned directly).
        for _ in 0..<100 where !(EngineOrphans.isOrphan(pid) && Self.path(of: pid) == sleep.path) { usleep(50_000) }
        return pid
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isGone(_ pid: pid_t) -> Bool {
        for _ in 0..<40 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(50_000)
        }
        return false
    }

    @Test func anOrphanedEngineIsKilledAndItsNoteRemoved() throws {
        let registry = try Fixtures.tempDir()
        let pid = try Self.orphan()
        defer { kill(pid, SIGKILL) }
        #expect(EngineOrphans.isOrphan(pid))
        EngineOrphans.record(pid, registry: registry)
        #expect(EngineOrphans.killOrphans(executable: Self.sleep, registry: registry) == [pid])
        #expect(Self.isGone(pid))
        #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path).isEmpty)
    }

    @Test func anEngineWithALivingWorkerIsLeftAlone() throws {
        let registry = try Fixtures.tempDir()
        let child = Process()
        child.executableURL = Self.sleep
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        EngineOrphans.record(child.processIdentifier, registry: registry)
        #expect(EngineOrphans.killOrphans(executable: Self.sleep, registry: registry).isEmpty)
        #expect(child.isRunning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path) == [String(child.processIdentifier)])
    }

    @Test func aReusedPidOrAnotherProgramIsLeftAlone() throws {
        let registry = try Fixtures.tempDir()
        let pid = try Self.orphan()
        defer { kill(pid, SIGKILL) }
        // Wrong start time: the pid was reused by something else.
        try Data("1.2".utf8).write(to: registry.appendingPathComponent(String(pid)))
        #expect(EngineOrphans.killOrphans(executable: Self.sleep, registry: registry).isEmpty)
        #expect(kill(pid, 0) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path).isEmpty)
        // Right start time, but not the engine's executable.
        EngineOrphans.record(pid, registry: registry)
        #expect(EngineOrphans.killOrphans(executable: URL(fileURLWithPath: "/bin/cat"), registry: registry).isEmpty)
        #expect(kill(pid, 0) == 0)
        // Junk notes are cleared.
        try Data("x".utf8).write(to: registry.appendingPathComponent("not-a-pid"))
        _ = EngineOrphans.killOrphans(executable: Self.sleep, registry: registry)
        #expect(!FileManager.default.fileExists(atPath: registry.appendingPathComponent("not-a-pid").path))
    }

    /// Every engine run is noted while it runs, and the note goes when it ends.
    @Test func runsAreNotedWhileRunning() async throws {
        let registry = EngineOrphans.defaultRegistry
        // The note is written just after the spawn, so wait for it before reading it.
        let script = #"for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$0/$$" ] && break; sleep 0.1; done; echo "pid=$$" >&2; cat "$0/$$" >&2"#
        let result = try await MediaEngine.run(["-c", script, registry.path], total: nil, limits: .probe,
                                               executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(result.ending == .exited(0), "\(result.log)")
        let lines = result.log.split(whereSeparator: \.isNewline).map(String.init)
        let pid = try #require(lines.first { $0.hasPrefix("pid=") }.map { String($0.dropFirst(4)) })
        #expect(lines.contains { $0.contains(".") && !$0.hasPrefix("pid=") }, "the note holds the start time: \(result.log)")
        #expect(!FileManager.default.fileExists(atPath: registry.appendingPathComponent(pid).path), "the note is removed after the run")
    }
}
