import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
import VideoToolbox

/// Re-encodes a movie with an explicit size cap and bitrate budget using `AVAssetReader` -> `AVAssetWriter`.
/// Export presets choose their own (often generous) bitrate, so they can't promise a smaller file; this can.
enum AVTranscoder {
    struct Plan: Sendable {
        /// The longest and shortest edge the output may have (1920 x 1080 for "1080p max").
        var maxLongEdge: CGFloat = 1920
        var maxShortEdge: CGFloat = 1080
        /// Encoded bits per pixel per frame. ~0.05 for HEVC keeps 1080p30 around 3 Mbit/s.
        var bitsPerPixel: Double = 0.05
        /// Never spend more than this fraction of the source's own video bitrate.
        var maxFractionOfSource: Double = 0.6
        var minVideoBitRate: Double = 150_000
        var preferHEVC = true
    }

    static func transcode(_ media: AVSupport.Media, to url: URL, fileType: AVFileType, plan: Plan,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let videoTrack = media.videoTracks.first else { throw ConversionError.unsupportedInput("It has no video track.") }
        let (naturalSize, transform, frameRate, dataRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)

        // Output size: fit inside the cap, never upscale, even dimensions for 4:2:0.
        let w = abs(naturalSize.width), h = abs(naturalSize.height)
        guard w >= 2, h >= 2 else { throw ConversionError.unsupportedInput("The video has no picture.") }
        let scale = min(1, plan.maxLongEdge / max(w, h), plan.maxShortEdge / min(w, h))
        let outW = max(2, Int((w * scale / 2).rounded()) * 2)
        let outH = max(2, Int((h * scale / 2).rounded()) * 2)

        let fps = frameRate > 0 ? min(Double(frameRate), 60) : 30
        var bitRate = Double(outW * outH) * fps * plan.bitsPerPixel
        if dataRate > 0 { bitRate = min(bitRate, Double(dataRate) * plan.maxFractionOfSource) }
        bitRate = max(bitRate, plan.minVideoBitRate)

        let reader: AVAssetReader, writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: media.asset)
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw AVSupport.mapped(error, url: url)
        }
        writer.shouldOptimizeForNetworkUse = true

        // Colour: HDR / 10-bit sources stay 10-bit HEVC Main10 with their own tags + HDR10 metadata; everything else is
        // 8-bit with explicit SDR tags (untagged sources are converted to BT.709 while decoding).
        let color = await AVColorInfo.of(videoTrack)
        let video = try videoSetup(color: color, plan: plan, width: outW, height: outH, scaled: scale < 1,
                                   bitRate: bitRate, fps: fps, writer: writer)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: video.readerSettings)
        // No copies: decoded frames come from the decoder's pool and go straight to the encoder. Combined with the
        // writer's back-pressure (`isReadyForMoreMediaData`) this keeps only a few frames in flight, even for 8K.
        videoOut.alwaysCopiesSampleData = false
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: video.writerSettings)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw ConversionError.engine("Couldn't set up the video encoder.") }
        reader.add(videoOut)
        writer.add(videoIn)
        pairs.append((videoOut, videoIn))

        // Audio: mix every audio track down to <= 2 channels of AAC.
        if !media.audioTracks.isEmpty {
            var sampleRate = 44_100.0, channels = 2
            if let desc = try? await media.audioTracks[0].load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                channels = Int(max(1, min(2, asbd.mChannelsPerFrame)))
            }
            sampleRate = min(48_000, max(8_000, sampleRate))
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: media.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            audioIn.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOut), writer.canAdd(audioIn) {
                reader.add(audioOut)
                writer.add(audioIn)
                pairs.append((audioOut, audioIn))
            }
        }

        let metadata = (try? await media.asset.load(.metadata)) ?? []
        writer.metadata = metadata

        let pump = Pump(reader: reader, writer: writer, pairs: pairs, duration: media.seconds, progress: progress)
        defer { AVSupport.removeWriterScratch(for: url) }
        try await pump.run()
    }

    struct VideoSetup {
        var readerSettings: [String: Any]
        var writerSettings: [String: Any]
        var tenBit: Bool
    }

    /// Chooses decode format and encoder settings for `color`. Throws when an HDR source can't be kept HDR (no HEVC
    /// Main10 encoder), rather than silently writing washed-out 8-bit HDR.
    static func videoSetup(color: AVColorInfo, plan: Plan, width: Int, height: Int, scaled: Bool,
                           bitRate: Double, fps: Double, writer: AVAssetWriter) throws -> VideoSetup {
        func settings(_ codec: AVVideoCodecType, tenBit: Bool, colorProperties: [String: String]) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if tenBit {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                compression.merge(color.hdrMetadataCompressionProperties) { $1 }
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoColorPropertiesKey: colorProperties,
                AVVideoCompressionPropertiesKey: compression,
            ]
        }
        func reader(tenBit: Bool, convertTo colorProperties: [String: String]?) -> [String: Any] {
            var s: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: tenBit
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            // Downscale in the decoder so an 8K source never produces full-size frames we'd only shrink again.
            if scaled {
                s[kCVPixelBufferWidthKey as String] = width
                s[kCVPixelBufferHeightKey as String] = height
            }
            if let colorProperties { s[AVVideoColorPropertiesKey] = colorProperties }
            return s
        }

        if plan.preferHEVC, color.wantsTenBit {
            let hdr = settings(.hevc, tenBit: true, colorProperties: color.preservedProperties)
            if writer.canApply(outputSettings: hdr, forMediaType: .video) {
                // 10-bit SDR with incomplete tags gets converted to its (BT.709) output tags; HDR is passed as is.
                let convert = !color.isHDR && !color.hasCompleteSDRTags ? color.sdrProperties : nil
                return VideoSetup(readerSettings: reader(tenBit: true, convertTo: convert), writerSettings: hdr, tenBit: true)
            }
            if color.isHDR { throw ConversionError.engine("This Mac can't encode HDR video (HEVC 10-bit).") }
        }
        if color.isHDR, !plan.preferHEVC {
            throw ConversionError.engine("HDR video needs HEVC to stay HDR.")
        }
        let props = color.sdrProperties
        let convert = color.hasCompleteSDRTags ? nil : props
        var out = settings(plan.preferHEVC ? .hevc : .h264, tenBit: false, colorProperties: props)
        if !writer.canApply(outputSettings: out, forMediaType: .video) { out = settings(.h264, tenBit: false, colorProperties: props) }
        guard writer.canApply(outputSettings: out, forMediaType: .video) else {
            throw ConversionError.engine("This Mac can't encode video at that size.")
        }
        return VideoSetup(readerSettings: reader(tenBit: false, convertTo: convert), writerSettings: out, tenBit: false)
    }

    /// Output URLs of transcodes whose pump (and so reader, writer and buffers) is still alive. Lets tests prove a
    /// finished or cancelled transcode releases everything.
    static let live = LiveSet()

    final class LiveSet: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL: Int] = [:]
        func insert(_ url: URL) { lock.withLock { urls[url, default: 0] += 1 } }
        func remove(_ url: URL) { lock.withLock { urls[url] = (urls[url] ?? 1) > 1 ? urls[url]! - 1 : nil } }
        func contains(inDirectory dir: URL) -> Bool {
            let path = dir.standardizedFileURL.path
            return lock.withLock { urls.keys.contains { $0.deletingLastPathComponent().standardizedFileURL.path == path } }
        }
    }

    /// Owns the reader/writer for one transcode.
    ///
    /// Everything (start, the per-input pull blocks, cancel, failure, finishing) runs on one serial `queue`, so the
    /// AVFoundation calls that raise Objective-C exceptions when misordered (`markAsFinished` / `finishWriting` after
    /// `cancelWriting`, `cancelWriting` before `startWriting`) are always guarded by a status check made on the same
    /// queue that changes it. The pull blocks capture the pump weakly (the writer input retains them), so there's no
    /// pump -> writer -> input -> block -> pump cycle; `transcode` keeps the pump alive while it awaits `run()`.
    private final class Pump: @unchecked Sendable {
        private enum Phase { case idle, running, finishing, done }

        private let queue = DispatchQueue(label: "halo.transcode", qos: .userInitiated)
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
        private let duration: Double
        private let progress: @Sendable (Double) -> Void
        // State below is only touched on `queue`.
        private var phase = Phase.idle
        private var cancelled = false
        private var unfinished: Set<Int>
        private var continuation: CheckedContinuation<Void, any Error>?

        init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
             duration: Double, progress: @escaping @Sendable (Double) -> Void) {
            self.reader = reader
            self.writer = writer
            self.pairs = pairs
            self.duration = duration
            self.progress = progress
            self.unfinished = Set(pairs.indices)
            AVTranscoder.live.insert(writer.outputURL)
        }

        deinit { AVTranscoder.live.remove(writer.outputURL) }

        func run() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    queue.async {
                        self.continuation = c
                        self.start()
                    }
                }
            } onCancel: {
                queue.async { self.cancel() }
            }
        }

        private var outputURL: URL { writer.outputURL }

        private func start() {
            // A cancel that arrived first (even before the continuation existed) left `cancelled` set.
            if cancelled { return complete(CancellationError()) }
            guard writer.startWriting() else {
                return complete(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't start writing."), url: outputURL))
            }
            guard reader.startReading() else {
                writer.cancelWriting() // status is .writing here
                return complete(AVSupport.mapped(reader.error ?? ConversionError.engine("Couldn't read the video."), url: outputURL))
            }
            writer.startSession(atSourceTime: .zero)
            phase = .running
            for index in pairs.indices {
                pairs[index].1.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pull(index) }
            }
        }

        /// Called on `queue` whenever input `index` wants more samples.
        private func pull(_ index: Int) {
            guard phase == .running, unfinished.contains(index) else { return }
            let (output, input) = pairs[index]
            let reportsProgress = input.mediaType == .video && duration > 0
            while phase == .running, input.isReadyForMoreMediaData {
                // Drain autoreleased decoder objects per sample, not once per (possibly minutes-long) block.
                let more: Bool = autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else {
                        if reader.status == .failed {
                            fail(AVSupport.mapped(reader.error ?? ConversionError.engine("Couldn't read the video."), url: outputURL))
                        } else {
                            inputFinished(index)
                        }
                        return false
                    }
                    if reportsProgress {
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if t.isFinite { progress(min(0.99, max(0, t / duration))) }
                    }
                    guard input.append(sample) else {
                        fail(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't encode the video."), url: outputURL))
                        return false
                    }
                    return true
                }
                if !more { return }
            }
        }

        private func inputFinished(_ index: Int) {
            guard unfinished.remove(index) != nil else { return }
            if writer.status == .writing { pairs[index].1.markAsFinished() }
            if unfinished.isEmpty { finishWriting() }
        }

        private func finishWriting() {
            guard phase == .running else { return }
            guard writer.status == .writing else {
                return fail(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't finish the video."), url: outputURL))
            }
            phase = .finishing
            writer.finishWriting { [self] in
                queue.async { self.finishedWriting() }
            }
        }

        private func finishedWriting() {
            if cancelled { return complete(CancellationError()) }
            if writer.status == .completed { return complete(nil) }
            complete(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't finish the video."), url: outputURL))
        }

        private func fail(_ error: any Error) {
            guard phase == .running || phase == .idle else { return }
            stopEngines()
            complete(error)
        }

        private func cancel() {
            cancelled = true
            switch phase {
            case .idle, .done: return               // `start` sees the flag / nothing left to do
            case .finishing: return                 // `finishedWriting` reports the cancel; never cancel mid-finish
            case .running:
                stopEngines()
                complete(CancellationError())
            }
        }

        private func stopEngines() {
            phase = .done
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }

        /// Resumes the continuation exactly once.
        private func complete(_ error: (any Error)?) {
            phase = .done
            guard let c = continuation else { return }
            continuation = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}
