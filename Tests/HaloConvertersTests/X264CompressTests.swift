import AVFoundation
import Foundation
import Testing
@testable import HaloConverters

/// The x264 command Compress and Smaller hand the engine. Pure: builds argument lists, encodes nothing.
@Suite struct X264CompressTests {
    private func settings(crf: Int = X264Compress.compressCRF, scale: Bool = false, tag: Bool = false,
                          economy: Bool = false) -> X264Compress.Settings {
        .init(crf: crf, width: 1280, height: 720, scale: scale, tagBT709: tag, economyAudio: economy)
    }
    private func audio(_ codec: String, channels: Int = 2) -> MediaProbe.Audio {
        .init(codec: codec, sampleRate: 48_000, channels: channels, bitDepth: 16)
    }
    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @Test func compressIsConstantQualityX264WithNoCap() {
        let args = X264Compress.arguments(settings(), audio: [])
        #expect(value(after: "-c:v", in: args) == "libx264")
        #expect(value(after: "-crf", in: args) == "20")
        #expect(value(after: "-preset", in: args) == "slow")
        #expect(!args.contains("-maxrate") && !args.contains("-bufsize"), "a cap starved hard scenes: quality first")
        #expect(value(after: "-pix_fmt", in: args) == "yuv420p")
        #expect(value(after: "-f", in: args) == "mp4")
    }

    @Test func neverTheHardwareEncoder() {
        let all = X264Compress.arguments(settings(scale: true, tag: true, economy: true), audio: [audio("mp3"), audio("ac3", channels: 6)])
        #expect(!all.joined(separator: " ").localizedCaseInsensitiveContains("videotoolbox"))
    }

    @Test func smallerUsesItsOwnQualityAndScales() {
        let args = X264Compress.arguments(settings(crf: X264Compress.smallerCRF, scale: true, economy: true), audio: [])
        #expect(value(after: "-crf", in: args) == "22")
        #expect(value(after: "-vf", in: args) == "scale=1280:720:flags=lanczos")
    }

    @Test func soundMacOSCanSeeIsCopiedTheRestBecomesAAC() {
        #expect(value(after: "-c:a", in: X264Compress.arguments(settings(), audio: [audio("aac"), audio("alac")])) == "copy")
        // MP3 inside MP4 is invisible to QuickTime: a real clip came out silent. AC-3 5.1 keeps its six channels.
        let mixed = X264Compress.arguments(settings(), audio: [audio("aac"), audio("mp3"), audio("ac3", channels: 6), audio("dts", channels: 8)])
        #expect(value(after: "-c:a:0", in: mixed) == "copy")
        #expect(value(after: "-c:a:1", in: mixed) == "aac_at")
        #expect(value(after: "-c:a:2", in: mixed) == "aac_at" && value(after: "-b:a:2", in: mixed) == "384k")
        #expect(value(after: "-ac:a:3", in: mixed) == "2", "7.1 folds to stereo")
        #expect(!mixed.contains("-c:a"), "no blanket copy when one track can't be copied")
    }

    @Test func noLocationAndUntaggedColourGetsLabelledNotChanged() {
        let args = X264Compress.arguments(settings(tag: true), audio: [])
        #expect(args.contains("location=") && args.contains("com.apple.quicktime.location.ISO6709="))
        #expect(value(after: "-color_primaries", in: args) == "bt709")
        #expect(!X264Compress.arguments(settings(tag: false), audio: []).contains("-color_primaries"))
    }

    @Test func hevcIsX265WithTheTagQuickTimeNeeds() {
        var s = settings(crf: X264Compress.hevcCRF); s.codec = .hevc
        let args = X264Compress.arguments(s, audio: [])
        #expect(value(after: "-c:v", in: args) == "libx265")
        #expect(value(after: "-tag:v", in: args) == "hvc1")
        #expect(value(after: "-pix_fmt", in: args) == "yuv420p" && value(after: "-profile:v", in: args) == "main")
        s.tenBit = true; s.pq = true
        let hdr = X264Compress.arguments(s, audio: [])
        #expect(value(after: "-pix_fmt", in: hdr) == "yuv420p10le" && value(after: "-profile:v", in: hdr) == "main10")
        #expect(value(after: "-x265-params", in: hdr)?.contains("hdr10=1") == true)
    }

    @Test func theFormatButtonsKeepHDROnlyInHEVC() {
        let pq = AVColorInfo(codec: 0x6876_6331, primaries: "ITU_R_2020", transfer: AVColorInfo.pq, matrix: "ITU_R_2020",
                             bitsPerComponent: 10, masteringDisplay: nil, contentLightLevel: nil, ambientViewing: nil)
        let hevc = X264Compress.formatSettings(pq, codec: .hevc)
        #expect(hevc.codec == .hevc && hevc.tenBit && hevc.pq && hevc.crf == X264Compress.hevcCRF && !hevc.tagBT709)
        let mp4 = X264Compress.formatSettings(pq, codec: .h264)
        #expect(mp4.codec == .h264 && !mp4.tenBit && mp4.crf == X264Compress.mp4CRF)
    }

    @Test func everyFrameKeepsItsTimestamp() {
        #expect(value(after: "-fps_mode", in: X264Compress.arguments(settings(), audio: [])) == "passthrough")
    }
}
