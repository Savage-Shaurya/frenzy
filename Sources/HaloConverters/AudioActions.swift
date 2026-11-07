import AVFoundation
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Audio conversions: M4A (AAC), WAV, AIFF on Apple's frameworks, plus MP3 and FLAC out and OGG, Opus, WMA and friends in
/// through the media engine (`EngineActions`): macOS decodes MP3 but can't encode it, and can't read those formats at all.
/// One action per target, whichever route it takes, so a mixed drop of WAV and OGG still gets every choice.
///
/// No-op prevention: each action lists only the formats it changes. Note `public.aiff-audio` conforms to
/// `public.aifc-audio`, so "AIFF" deliberately doesn't list AIFC (it would match plain AIFF files too).
enum AudioActions {
    private static let compressed: [UTType] = [.mp3, .mpeg4Audio]
    private static let flac: [UTType] = AVSupport.flac.map { [$0] } ?? []

    static var all: [ConversionAction] { actions(engine: MediaEngine.isAvailable) }

    /// Without the engine (`engine: false`) only Apple's paths are offered: no MP3 or FLAC out, no OGG, Opus or WMA in.
    /// So a copy of Frenzy missing the engine never shows a choice that would fail.
    static func actions(engine: Bool) -> [ConversionAction] {
        let foreign = engine ? EngineActions.foreignAudio : []
        var actions: [ConversionAction] = []
        if engine {
            // MP3 first: it's what most people are after, and it's the only one macOS can't make.
            actions.append(ConversionAction(
                id: "audio.to-mp3", title: "MP3", subtitle: "Plays anywhere", symbolName: "music.note.list",
                category: .audio, inputTypes: [.wav, AVSupport.aifc, AVSupport.caf, .mpeg4Audio] + flac + foreign,
                defaultRank: 5, converter: ClosureConverter(toMP3)))
        }
        actions += [
            ConversionAction(
                id: "audio.to-m4a", title: "M4A", subtitle: "AAC", symbolName: "music.note",
                category: .audio, inputTypes: [.wav, AVSupport.aifc, .mp3, AVSupport.caf] + flac + foreign,
                defaultRank: 10, converter: ClosureConverter(toM4A)),
            ConversionAction(
                id: "audio.to-wav", title: "WAV", subtitle: "Uncompressed", symbolName: "waveform",
                category: .audio, inputTypes: [AVSupport.aifc, AVSupport.caf] + compressed + flac + foreign,
                defaultRank: 20, converter: ClosureConverter(toWAV)),
            ConversionAction(
                id: "audio.to-aiff", title: "AIFF", subtitle: "Uncompressed", symbolName: "waveform.circle",
                category: .audio, inputTypes: [.wav, AVSupport.caf] + compressed + flac + foreign,
                defaultRank: 30, converter: ClosureConverter(toAIFF)),
        ]
        if engine {
            actions.append(ConversionAction(
                id: "audio.to-flac", title: "FLAC", subtitle: "Lossless", symbolName: "waveform.badge.magnifyingglass",
                category: .audio, inputTypes: [.wav, AVSupport.aifc, AVSupport.caf, .mp3, .mpeg4Audio] + foreign,
                defaultRank: 35, converter: ClosureConverter(toFLAC)))
        }
        return actions
    }

    // MARK: - Engine

    @Sendable static func toMP3(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try await EngineActions.audio(input, job: job, format: .mp3, progress: progress)
        }
    }

    @Sendable static func toFLAC(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try await EngineActions.audio(input, job: job, format: .flac, progress: progress)
        }
    }

    // MARK: - M4A

    @Sendable static func toM4A(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            if EngineActions.isForeignAudio(input) { return try await EngineActions.audio(input, job: job, format: .m4a, progress: progress) }
            let media = try await AVSupport.open(input.url, requireAudio: true)
            let session = try await AVSupport.session(for: media.asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
            let out = try job.makeOutput(for: input, pathExtension: "m4a")
            try await AVSupport.export(session, to: out.temporaryURL, as: .m4a, progress: progress)
            return try out.commit()
        }
    }

    // MARK: - PCM (WAV / AIFF)

    @Sendable static func toWAV(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            if EngineActions.isForeignAudio(input) { return try await EngineActions.audio(input, job: job, format: .wav, progress: progress) }
            let out = try job.makeOutput(for: input, pathExtension: "wav")
            try await writePCM(from: input.url, to: out.temporaryURL, bigEndian: false, progress: progress)
            return try out.commit()
        }
    }

    @Sendable static func toAIFF(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            if EngineActions.isForeignAudio(input) { return try await EngineActions.audio(input, job: job, format: .aiff, progress: progress) }
            let out = try job.makeOutput(for: input, pathExtension: "aiff")
            try await writePCM(from: input.url, to: out.temporaryURL, bigEndian: true, progress: progress)
            return try out.commit()
        }
    }

    /// Decodes `source` and writes linear PCM at the same sample rate and channel count. The container comes from
    /// `destination`'s extension. Keeps the source bit depth for PCM sources; 16-bit for lossy ones (more is wasted).
    static func writePCM(from source: URL, to destination: URL, bigEndian: Bool,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        // AVAudioFile doesn't go through AVAsset, so refuse reference movies (e.g. a .mov header renamed .m4a) here.
        try await AVSupport.requireSelfContained(source)
        // A blocking decode/encode loop: on a dedicated dispatch queue, not the cooperative pool.
        try await AVSupport.runBlocking { cancel in
            try writePCMBlocking(from: source, to: destination, bigEndian: bigEndian, cancel: cancel, progress: progress)
        }
    }

    private static func writePCMBlocking(from source: URL, to destination: URL, bigEndian: Bool, cancel: AVCancelFlag,
                                         progress: @Sendable (Double) -> Void) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw readError(error, source) }

        let fileFormat = input.fileFormat
        let asbd = fileFormat.streamDescription.pointee
        var bits = 16, isFloat = false
        if asbd.mFormatID == kAudioFormatLinearPCM {
            let srcFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            if srcFloat {
                // WAV can hold float; AIFF (not AIFC) can't, so use 24-bit integer there.
                if bigEndian { bits = 24 } else { bits = 32; isFloat = true }
            } else {
                bits = [16, 24, 32].contains(Int(asbd.mBitsPerChannel)) ? Int(asbd.mBitsPerChannel) : (asbd.mBitsPerChannel > 16 ? 24 : 16)
            }
        }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileFormat.sampleRate,
            AVNumberOfChannelsKey: fileFormat.channelCount,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if let layout = fileFormat.channelLayout, fileFormat.channelCount > 2 {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }

        let processing = input.processingFormat
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: processing.commonFormat, interleaved: processing.isInterleaved)
        } catch {
            throw ConversionError.writeFailed(destination, (error as NSError).localizedDescription)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 65_536) else {
            throw ConversionError.engine("Couldn't allocate an audio buffer.")
        }
        let total = max(1, Double(input.length))
        var done: Int64 = 0
        // AVAudioFile throws (rather than returning 0 frames) when reading past the end, so loop on position.
        while input.framePosition < input.length {
            try cancel.check()
            do { try input.read(into: buffer) } catch { throw readError(error, source) }
            if buffer.frameLength == 0 { break }
            do { try output.write(from: buffer) } catch {
                throw ConversionError.writeFailed(destination, (error as NSError).localizedDescription)
            }
            done += Int64(buffer.frameLength)
            progress(min(0.99, Double(done) / total))
        }
        guard done > 0 else { throw ConversionError.unsupportedInput("It contains no audio.") }
        progress(1)
    }

    private static func readError(_ error: any Error, _ url: URL) -> any Error {
        if error is CancellationError { return error }
        let ns = error as NSError
        // kAudioFileUnsupportedFileTypeError 'typ?', kAudioFileUnsupportedDataFormatError 'fmt?'
        if ns.domain == NSOSStatusErrorDomain, [1_954_115_647, 1_718_449_215].contains(ns.code) {
            return ConversionError.unsupportedInput("macOS can't decode this audio format.")
        }
        return ConversionError.unreadable(url)
    }
}
