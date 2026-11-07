import AVFoundation
import CoreVideo
import Darwin
import Foundation
import HaloCore

/// HDR to MP4 (H.264, SDR) without the video chip. Apple's decoder does the tone mapping (the same HDR-to-BT.709
/// video composition the old export used; decoding never touches the encoder), and its frames stream through a pipe
/// file into x264 in the sandboxed engine. The original file is the engine's second input, for the sound and tags.
///
/// The composition renders at a fixed frame rate (a pipe of raw frames carries no timestamps), so a variable frame
/// rate clip comes out at its composition rate with the same length.
enum ToneMappedMP4 {
    static func run(media: AVSupport.Media, track: AVAssetTrack, input: URL, output: URL, color: AVColorInfo,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let composition = try await AVColorInfo.sdrComposition(for: media.asset, track: track, properties: AVColorInfo.bt709)
        let width = Int(composition.renderSize.width.rounded()) & ~1, height = Int(composition.renderSize.height.rounded()) & ~1
        guard width >= 2, height >= 2 else { throw ConversionError.unsupportedInput("The video has no picture.") }
        // The composition renders at its own fixed frame duration, so that is the rate of the frames in the pipe.
        let step = composition.frameDuration.seconds
        let fps = step.isFinite && step > 0 ? 1 / step : 30

        let reader = try AVAssetReader(asset: media.asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        frames.videoComposition = composition
        guard reader.canAdd(frames) else { throw ConversionError.engine("Couldn't read this video's frames.") }
        reader.add(frames)

        // The pipe lives in this process's own temp folder, next to the engine's other work.
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("halo-frames-\(UUID().uuidString).nv12")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw ConversionError.engine("Frenzy couldn't write to its temporary folder.") }
        defer { unlink(fifo.path) }

        let probe = try await MediaEngine.probe(input)
        var settings = X264Compress.formatSettings(color, codec: .h264)
        settings.tagBT709 = true
        let pipe = ["-f", "rawvideo", "-pix_fmt", "nv12", "-video_size", "\(width)x\(height)", "-framerate", String(fps)]
        let feeder = FrameFeeder(reader: reader, output: frames, fifo: fifo, width: width, height: height)
        let feeding = Task { await feeder.runOnOwnThread() }
        do {
            try await MediaEngine.convert(input: fifo, output: output, inputOptions: pipe,
                                          secondInput: (probe.demuxerOptions, input),
                                          outputArguments: X264Compress.arguments(settings, audio: probe.audio, soundFrom: 1),
                                          expectedSeconds: probe.seconds > 0 ? probe.seconds : media.seconds, checkLength: true,
                                          progress: progress)
        } catch {
            feeder.stop()
            _ = await feeding.value
            throw error
        }
        guard await feeding.value else { throw ConversionError.engine("Couldn't read every frame of this video.") }
        try QuickTimeTags.relocate(output)
    }
}

/// Writes NV12 frames into the pipe until the reader runs out. Never raises SIGPIPE: if the engine stops reading, the
/// write fails and the feeder ends.
private final class FrameFeeder: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    private let fifo: URL
    private let width: Int, height: Int
    private let lock = NSLock()
    private var stopped = false

    init(reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput, fifo: URL, width: Int, height: Int) {
        self.reader = reader; self.output = output; self.fifo = fifo; self.width = width; self.height = height
    }

    func stop() {
        lock.withLock { stopped = true }
        reader.cancelReading()
    }

    /// Blocking reads and writes stay off Swift's shared threads: the feeder gets a thread of its own.
    func runOnOwnThread() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let thread = Thread { done.resume(returning: self.run()) }
            thread.name = "frenzy.tone-mapped-frames"
            thread.start()
        }
    }

    /// true when every frame went into the pipe.
    private func run() -> Bool {
        // A dead engine must never take the app down: SIGPIPE stays blocked on this thread, writes just fail.
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal); sigaddset(&pipeSignal, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipeSignal, nil)
        // Open without blocking and retry until the engine is reading, so stop() always ends the wait.
        var fd: Int32 = -1
        while fd < 0 {
            if lock.withLock({ stopped }) { return false }
            fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if fd < 0 { guard errno == ENXIO || errno == EINTR else { return false }; usleep(20_000) }
        }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        guard !lock.withLock({ stopped }), reader.startReading() else { return false }
        while !lock.withLock({ stopped }), let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample), write(buffer, to: fd) else {
                reader.cancelReading(); return false
            }
        }
        return reader.status == .completed
    }

    /// Both planes, row by row (the buffer's rows can be padded; the pipe carries exactly width bytes per row).
    private func write(_ buffer: CVPixelBuffer, to fd: Int32) -> Bool {
        // Exactly the NV12 frames the engine was told to expect, never a read past the buffer.
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetWidthOfPlane(buffer, 0) >= width, CVPixelBufferGetHeightOfPlane(buffer, 0) >= height,
              CVPixelBufferGetHeightOfPlane(buffer, 1) >= height / 2 else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return false }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = plane == 0 ? height : height / 2
            for row in 0..<rows where !writeAll(fd, base.advanced(by: row * stride), width) { return false }
        }
        return true
    }

    private func writeAll(_ fd: Int32, _ start: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, start.advanced(by: done), count - done)
            if n < 0 { if errno == EINTR { continue }; return false }
            done += n
        }
        return true
    }
}
