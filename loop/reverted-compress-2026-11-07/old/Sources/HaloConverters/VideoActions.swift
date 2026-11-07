import AVFoundation
import CoreMedia
import Foundation
import HaloCore
import ImageIO
import UniformTypeIdentifiers

/// Video conversions: MP4 (H.264), HEVC, compress, GIF, extract audio. AVFoundation only.
///
/// No-op prevention: the ring matches on `inputTypes` by conformance, so each action lists the concrete containers it
/// makes sense for. "MP4" lists QuickTime/M4V/3GP but not `public.mpeg-4`, so it never appears for an MP4. Codec-level
/// no-ops the type system can't see (HEVC -> HEVC) are refused at run time with a clear message.
enum VideoActions {
    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "video.to-mp4", title: "MP4", subtitle: "H.264", symbolName: "film",
                category: .video,
                // Deliberately not `.mpeg4Movie`: MP4 -> MP4 would be a no-op. M4V is listed explicitly (it conforms to
                // public.mpeg-4 but an .m4v -> .mp4 rewrap is a real, useful change of container).
                inputTypes: [.quickTimeMovie, AVSupport.m4v, AVSupport.threeGPP, AVSupport.threeGPP2],
                defaultRank: 10, converter: ClosureConverter(toMP4)),
            ConversionAction(
                id: "video.compress", title: "Compress", subtitle: "Smaller file",
                symbolName: "arrow.down.right.and.arrow.up.left", category: .video,
                inputTypes: AVSupport.videoInputs, defaultRank: 20, converter: ClosureConverter(compress)),
            ConversionAction(
                id: "video.to-gif", title: "GIF", subtitle: "Looping", symbolName: "photo.stack",
                category: .video, inputTypes: AVSupport.videoInputs, defaultRank: 30, converter: ClosureConverter(toGIF)),
            ConversionAction(
                id: "video.extract-audio", title: "Audio", subtitle: "M4A sound", symbolName: "waveform",
                category: .video, inputTypes: AVSupport.videoInputs, defaultRank: 40, converter: ClosureConverter(extractAudio)),
            ConversionAction(
                id: "video.to-hevc", title: "HEVC", subtitle: "H.265", symbolName: "film.stack",
                category: .video, inputTypes: AVSupport.videoInputs, defaultRank: 50, converter: ClosureConverter(toHEVC)),
        ]
    }

    // MARK: - MP4

    /// Rewraps losslessly (passthrough) when the streams are already MP4-friendly (8-bit SDR H.264 + AAC), otherwise
    /// re-encodes to H.264 at the highest-quality preset. H.264 here is 8-bit SDR, so HDR sources are tone-mapped to
    /// BT.709 through a video composition, and every re-encode is tagged explicitly.
    @Sendable static func toMP4(_ job: ConversionJob) async throws -> [URL] {
        try await eachInput(job) { input, progress in
            let media = try await AVSupport.open(input.url, requireVideo: true)
            guard let track = media.videoTracks.first else { throw ConversionError.unsupportedInput("It has no video track.") }
            let color = await AVColorInfo.of(track)
            var passthroughOK = !color.wantsTenBit
            for track in media.videoTracks {
                if await AVSupport.codec(of: track) != kCMVideoCodecType_H264 { passthroughOK = false }
            }
            for track in media.audioTracks {
                if await AVSupport.codec(of: track) != kAudioFormatMPEG4AAC { passthroughOK = false }
            }
            var preset = AVAssetExportPresetHighestQuality
            if passthroughOK, await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: media.asset, outputFileType: .mp4) {
                preset = AVAssetExportPresetPassthrough
            }
            let session = try await AVSupport.session(for: media.asset, preset: preset, fileType: .mp4)
            session.shouldOptimizeForNetworkUse = true
            if preset != AVAssetExportPresetPassthrough {
                session.videoComposition = try await AVColorInfo.sdrComposition(
                    for: media.asset, track: track, properties: color.isHDR ? AVColorInfo.bt709 : color.sdrProperties)
            }
            let out = try job.makeOutput(for: input, pathExtension: "mp4")
            try await AVSupport.export(session, to: out.temporaryURL, as: .mp4, progress: progress)
            return try out.commit()
        }
    }

    // MARK: - HEVC

    /// HEVC keeps HDR: the HEVC preset re-encodes HDR/10-bit sources as Main10 with the source's colour tags and HDR10
    /// metadata, and the result is checked (an output that lost HDR is refused rather than kept). SDR sources without a
    /// complete set of colour tags are rendered to explicit BT.709.
    @Sendable static func toHEVC(_ job: ConversionJob) async throws -> [URL] {
        try await eachInput(job) { input, progress in
            let media = try await AVSupport.open(input.url, requireVideo: true)
            guard let track = media.videoTracks.first else { throw ConversionError.unsupportedInput("It has no video track.") }
            if await AVSupport.codec(of: track) == kCMVideoCodecType_HEVC {
                throw ConversionError.unsupportedInput("It's already HEVC.")
            }
            let color = await AVColorInfo.of(track)
            let session = try await AVSupport.session(for: media.asset, preset: AVAssetExportPresetHEVCHighestQuality, fileType: .mp4)
            session.shouldOptimizeForNetworkUse = true
            if !color.isHDR, !color.hasCompleteSDRTags {
                session.videoComposition = try await AVColorInfo.sdrComposition(for: media.asset, track: track, properties: color.sdrProperties)
            }
            let out = try job.makeOutput(for: input, pathExtension: "mp4", suffix: "HEVC")
            try await AVSupport.export(session, to: out.temporaryURL, as: .mp4, progress: progress)
            if color.isHDR {
                let written = try await AVSupport.makeAsset(out.temporaryURL).loadTracks(withMediaType: .video).first
                let result = await written.asyncMap { await AVColorInfo.of($0) }
                guard let result, result.isHDR, result.transfer == color.preservedProperties[AVVideoTransferFunctionKey],
                      result.bitsPerComponent >= 10 else {
                    throw ConversionError.engine("macOS couldn't keep this video's HDR when converting to HEVC.")
                }
            }
            return try out.commit()
        }
    }

    // MARK: - Compress

    /// HEVC (H.264 fallback) capped at 1080p and a bitrate budget well under the source's. Refuses to keep a result
    /// that isn't actually smaller.
    @Sendable static func compress(_ job: ConversionJob) async throws -> [URL] {
        try await eachInput(job) { input, progress in
            let media = try await AVSupport.open(input.url, requireVideo: true)
            let out = try job.makeOutput(for: input, pathExtension: "mp4", suffix: "compressed")
            try await AVTranscoder.transcode(media, to: out.temporaryURL, fileType: .mp4, plan: .init(), progress: progress)
            let before = AVSupport.fileSize(input.url), after = AVSupport.fileSize(out.temporaryURL)
            if before > 0, after >= before {
                throw ConversionError.alreadySmall(input.url.lastPathComponent)
            }
            return try out.commit()
        }
    }

    // MARK: - GIF

    static let gifMaxEdge: CGFloat = 480
    static let gifFPS = 12.0
    static let gifMaxSeconds = 15.0

    /// Up to the first 15 s at 12 fps, scaled to fit 480 x 480, looping forever.
    @Sendable static func toGIF(_ job: ConversionJob) async throws -> [URL] {
        try await eachInput(job) { input, progress in
            let media = try await AVSupport.open(input.url, requireVideo: true)
            guard let track = media.videoTracks.first else { throw ConversionError.unsupportedInput("It has no video track.") }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            guard w > 0, h > 0 else { throw ConversionError.unsupportedInput("The video has no picture.") }
            let scale = min(1, gifMaxEdge / max(w, h))
            let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())

            let seconds = min(media.seconds, gifMaxSeconds)
            let count = max(1, Int((seconds * gifFPS).rounded(.down)))
            let times = (0..<count).map { CMTime(seconds: Double($0) / gifFPS, preferredTimescale: 600) }

            let generator = AVAssetImageGenerator(asset: media.asset)
            generator.appliesPreferredTrackTransform = true
            // GIF is 8-bit sRGB: render through a BT.709 composition (tone-maps HDR), then draw each frame into sRGB.
            generator.videoComposition = try await AVColorInfo.sdrComposition(for: media.asset, track: track)
            generator.maximumSize = size
            let tolerance = CMTime(seconds: 0.5 / gifFPS, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let out = try job.makeOutput(for: input, pathExtension: "gif")
            guard let dest = CGImageDestinationCreateWithURL(out.temporaryURL as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw ConversionError.writeFailed(out.temporaryURL, "Couldn't create the GIF.")
            }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
            let frameProps = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 1 / gifFPS,
                    kCGImagePropertyGIFUnclampedDelayTime: 1 / gifFPS,
                ],
            ] as CFDictionary

            // Every slot gets a frame so timing stays right: a frame that fails to decode repeats the previous one.
            var last: CGImage?
            var owed = 0, added = 0
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                if let decoded = try? result.image, let image = sRGB(decoded) {
                    for _ in 0..<(owed + 1) { CGImageDestinationAddImage(dest, image, frameProps) }
                    added += owed + 1
                    owed = 0
                    last = image
                } else if let last {
                    CGImageDestinationAddImage(dest, last, frameProps)
                    added += 1
                } else {
                    owed += 1
                }
                progress(min(0.99, Double(added + owed) / Double(count)))
            }
            try Task.checkCancellation()
            guard last != nil, added == count, CGImageDestinationFinalize(dest) else {
                throw ConversionError.engine("Couldn't read frames from this video.")
            }
            return try out.commit()
        }
    }

    // MARK: - Extract audio

    @Sendable static func extractAudio(_ job: ConversionJob) async throws -> [URL] {
        try await eachInput(job) { input, progress in
            let media = try await AVSupport.open(input.url, requireAudio: true)
            let session = try await AVSupport.session(for: media.asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
            let out = try job.makeOutput(for: input, pathExtension: "m4a")
            try await AVSupport.export(session, to: out.temporaryURL, as: .m4a, progress: progress)
            return try out.commit()
        }
    }

    // MARK: - Helpers

    /// `image` as 8-bit sRGB (what GIF players assume). Returns it untouched when it already is.
    static func sRGB(_ image: CGImage) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if image.colorSpace?.name == CGColorSpace.sRGB, image.bitsPerComponent == 8 { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Runs `body` for each input (the runner normally hands `.each` actions one file), splitting progress evenly.
    static func eachInput(_ job: ConversionJob,
                          _ body: (InputFile, @escaping @Sendable (Double) -> Void) async throws -> URL) async throws -> [URL] {
        var urls: [URL] = []
        let n = Double(job.inputs.count)
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            let report = job.progress
            let base = Double(i)
            urls.append(try await body(input) { report((base + min(1, max(0, $0))) / n) })
        }
        return urls
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
