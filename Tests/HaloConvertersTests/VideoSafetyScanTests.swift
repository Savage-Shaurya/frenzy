import Foundation
import Testing

/// NON-VIDEO. Reads the source files as text; builds, encodes and decodes nothing.
///
/// The build that kernel-panicked the founder's Mac three times on 7 Nov 2026 drove VideoToolbox directly: its own
/// compression sessions next to AVAssetWriter's (two hardware encode sessions at once is the trigger of Apple's
/// FB23045975). These checks fail the moment that path, or the habits around it, come back into `Sources/`.
@Suite("Video safety scan (no encoding)")
struct VideoSafetyScanTests {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// Every Swift file under `Sources/`, with comments removed (a comment may explain the danger by name).
    private static func code() throws -> [(path: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let raw = try String(contentsOf: url, encoding: .utf8)
            files.append((url.path.replacingOccurrences(of: sources.path + "/", with: ""), stripComments(raw)))
        }
        return files
    }

    static func stripComments(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        out = out.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
        return out
    }

    @Test func scannerSeesTheSources() throws {
        let files = try Self.code()
        #expect(files.count > 20, "found \(files.count) files under \(Self.sources.path)")
        #expect(files.contains { $0.path.hasSuffix("HaloConverters/AVTranscoder.swift") })
        #expect(Self.stripComments("let a = 1 // VTCompressionSession\n/* kVTCompressionPropertyKey_Quality */") == "let a = 1 \n")
    }

    /// No direct VideoToolbox encoding anywhere: no compression sessions, no session properties, no compression keys.
    @Test func noDirectVideoToolboxEncoding() throws {
        let banned = ["VTCompressionSession", "kVTCompressionPropertyKey", "VTSessionSetProperty", "VTSessionSetProperties",
                      "VTCompressionSessionEncodeFrame", "VTMultiPassStorage", "VTFrameSiloCreate"]
        var hits: [String] = []
        for file in try Self.code() {
            for word in banned where file.text.contains(word) { hits.append("\(file.path): \(word)") }
        }
        #expect(hits.isEmpty, "Direct VideoToolbox encoding is back. It kernel-panicked the Mac on 7 Nov 2026: \(hits)")
    }

    /// Decoded frames are always copied before the encoder sees them.
    @Test func decoderBuffersAreNeverSharedWithTheEncoder() throws {
        var hits: [String] = []
        for file in try Self.code() where file.text.range(of: #"alwaysCopiesSampleData\s*=\s*false"#, options: .regularExpression) != nil {
            hits.append(file.path)
        }
        #expect(hits.isEmpty, "\(hits)")
        let transcoder = try #require(try Self.code().first { $0.path.hasSuffix("AVTranscoder.swift") })
        #expect(transcoder.text.contains("videoOut.alwaysCopiesSampleData = true"))
    }

    /// The writer stops before the reader, and only one place in the transcoder ever stops them.
    @Test func writerStopsBeforeReader() throws {
        let transcoder = try #require(try Self.code().first { $0.path.hasSuffix("AVTranscoder.swift") }).text
        let writer = try #require(transcoder.range(of: "if writer.status == .writing { writer.cancelWriting() }"))
        let reader = try #require(transcoder.range(of: "if reader.status == .reading { reader.cancelReading() }"))
        #expect(writer.lowerBound < reader.lowerBound)
        #expect(transcoder.components(separatedBy: "cancelReading()").count - 1 == 1,
                "cancelReading from more than one place raced and crashed the test process on 7 Nov 2026")
    }

    /// Every AVAssetWriter that encodes video, and every re-encoding export session, sits behind the gate.
    @Test func everyEncoderIsGated() throws {
        let files = try Self.code()
        for file in files where file.text.contains("AVAssetWriter(outputURL") {
            let gated = file.text.contains("HardwareEncodeGate.shared")
            let audioProbeOnly = !file.text.contains("startWriting()")
            #expect(gated || audioProbeOnly, "\(file.path) creates an AVAssetWriter outside HardwareEncodeGate")
        }
        // Video exports only copy (passthrough) or extract sound: no export preset that encodes video, anywhere.
        let video = try #require(files.first { $0.path.hasSuffix("VideoActions.swift") }).text
        for file in files {
            for preset in ["AVAssetExportPresetHighestQuality", "AVAssetExportPresetHEVCHighestQuality", "AVAssetExportPresetMediumQuality",
                           "AVAssetExportPresetLowQuality", "AVAssetExportPreset1920x1080", "AVAssetExportPreset3840x2160"] {
                #expect(!file.text.contains(preset), "\(file.path) uses \(preset), which encodes video on the hardware encoder")
            }
        }
        #expect(video.contains("gatedExport"))
        #expect(!video.contains("try await AVSupport.export(session, to: out.temporaryURL, as: .mp4"),
                "a video export that re-encodes must go through gatedExport")
        let images = try #require(files.first { $0.path.hasSuffix("ImageSupport.swift") }).text
        #expect(images.contains("HardwareImageEncode.run(format)"), "HEIC/AVIF stills must take the gate")
    }

    /// Video test suites stay off unless someone opts in for one deliberate run, and run one test at a time.
    /// Checked per suite: a file may hold a non-video suite next to a gated one.
    @Test func videoSuitesStayGated() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // These two only name the patterns below as text.
        let textOnly: Set<String> = ["VideoSafetyScanTests.swift", "VideoPlanTests.swift"]
        let names = try FileManager.default.contentsOfDirectory(atPath: tests.path).filter { $0.hasSuffix(".swift") && !textOnly.contains($0) }
        var checked = 0
        for name in names {
            let text = Self.stripComments(try String(contentsOf: tests.appendingPathComponent(name), encoding: .utf8))
            for suite in text.components(separatedBy: "@Suite(").dropFirst() {
                let encodes = suite.contains("AVFixtures.movie(") || suite.contains("AVAssetWriter(outputURL")
                    || suite.contains("TrackFixtures.") || suite.contains("AVTranscoder.transcode(")
                guard encodes else { continue }
                checked += 1
                let header = suite.components(separatedBy: "\nstruct ").first ?? suite
                let title = header.prefix(80)
                #expect(header.contains("HardwareVideoTests.allowed") || header.contains("HALO_REAL_JOBS"), "\(name): \(title) encodes video but isn't gated")
                #expect(header.contains(".serialized"), "\(name): \(title) must be .serialized")
            }
        }
        #expect(checked >= 4, "found only \(checked) video suites")
    }
}
