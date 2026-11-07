import Darwin
import Foundation
import HaloCore

/// Runs the bundled media engine (a CPU-only GPL FFmpeg with x264 and x265, see `scripts/build-media-engine.sh`) for formats macOS can't
/// handle. It lives inside the worker's bundle and is a child of the worker, so it inherits the worker's sandbox: no
/// network, and writes only inside the container.
///
/// Safety rules, all enforced here:
/// - **No shell, a fixed argument list.** `posix_spawn` with an array; every path goes in as `file:<absolute path>`, so
///   a name can't become an option or a protocol. The engine also accepts only the `file` and `pipe` protocols.
/// - **Nothing inherited:** `POSIX_SPAWN_CLOEXEC_DEFAULT` and a small fixed environment (no `FFREPORT` and friends).
/// - **Stays in the worker's process group,** so launchd can remove it with the worker. It also dies of SIGPIPE at its
///   next progress line once the worker is gone (its stdout is a pipe only the worker reads), and every running engine's
///   pid is recorded in the worker's container so the next worker kills any that survived (`EngineOrphans`).
/// - **Bounded:** wall-clock, CPU time, no-progress and memory limits; a breach kills it with SIGKILL.
/// - **Plain messages:** a crash or error never shows the engine's own text, which can quote the hostile file.
enum MediaEngine {
    static let executableName = "frenzy-media-engine"

    /// The worker's bundle id, which names its folder in `Contents/XPCServices`.
    static let workerBundleName = "com.snappycrew.frenzy.worker.xpc"

    /// Where the engine is for this process, nil when it isn't there.
    /// - In the worker (`.xpc`), which runs it: `Contents/Helpers` of its own bundle.
    /// - In the app (`.app`), which only decides what the ring offers: the same file, inside the worker it bundles.
    /// - Outside a bundle (`swift test`, `swift run`): the build output in the source tree. A shipped app never looks there.
    static var executableURL: URL? { executableURL(bundle: Bundle.main.bundleURL) }

    static func executableURL(bundle: URL, developmentRoot: URL? = sourceRoot) -> URL? {
        let url: URL
        switch bundle.pathExtension {
        case "xpc":
            url = bundle.appendingPathComponent("Contents/Helpers/\(executableName)")
        case "app":
            url = bundle.appendingPathComponent("Contents/XPCServices/\(workerBundleName)/Contents/Helpers/\(executableName)")
        default:
            guard let developmentRoot else { return nil }
            url = developmentRoot.appendingPathComponent("vendor/build/arm64/bin/\(executableName)")
        }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// `apps/halo`, from this file's place in the source tree.
    static let sourceRoot: URL? = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Whether the choices that need the engine may be offered. Checked once: the engine ships inside the app and
    /// doesn't come or go while it runs.
    /// The engine is arm64 only, so an Intel Mac never gets these choices either.
    static let isAvailable: Bool = executableURL != nil && hasAppleSilicon

    private static var hasAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    struct Limits: Sendable {
        /// Killed when the job runs longer than this.
        var maxRuntime: TimeInterval
        /// Killed when the output's position hasn't moved for this long. A hostile file can spin without producing anything.
        var stallTimeout: TimeInterval
        /// Killed when its memory footprint passes this.
        var maxFootprint: UInt64

        /// `min(6 GB, max(1.5 GB, RAM / 3))`: under the worker's own watchdog, so the engine goes first.
        static let defaultFootprint: UInt64 = {
            let ram = ProcessInfo.processInfo.physicalMemory
            return min(6 << 30, max(3 << 29, ram / 3))
        }()

        /// Longer media gets longer: six times real time, at least 20 minutes, at most 12 hours.
        static func forMedia(seconds: Double) -> Limits {
            Limits(maxRuntime: min(12 * 3600, max(20 * 60, seconds * 6)), stallTimeout: 300, maxFootprint: defaultFootprint)
        }

        static let probe = Limits(maxRuntime: 60, stallTimeout: 60, maxFootprint: defaultFootprint)
    }

    enum Ending: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case tooSlow, stalled, tooMuchMemory, cancelled
    }

    struct Result: Sendable {
        let ending: Ending
        /// What the engine printed on stderr, capped. For parsing only; never show it to people.
        let log: String
        /// The last `out_time_us` from `-progress`.
        let lastPosition: Double
    }

    static let missing = ConversionError.engine("This copy of Frenzy is missing the part that handles this format. Please reinstall Frenzy.")

    /// Runs the engine with `arguments` and waits. `total` turns reported positions into 0...1 progress.
    /// Throws only when it can't start; how it ended is in the result. Cancelling the task kills the process.
    /// `executable` is for tests, which need a program that misbehaves.
    static func run(_ arguments: [String], total: Double?, limits: Limits, executable override: URL? = nil,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        guard let executable = override ?? executableURL else { throw missing }
        let flag = KillFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
                queue.async {
                    do {
                        try flag.check()
                        continuation.resume(returning: try spawnAndWait(executable, arguments, total: total, limits: limits,
                                                                        flag: flag, progress: progress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// Threads for the blocking poll loop: not the cooperative pool, and GCD can add threads while these block.
    private static let queue = DispatchQueue(label: "frenzy.media-engine", qos: .userInitiated, attributes: .concurrent)

    private final class KillFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
        func check() throws { if isSet { throw CancellationError() } }
    }

    /// Only what system frameworks need inside the sandbox. Anything else (`FFREPORT`, `DYLD_*`) stays out.
    static func childEnvironment() -> [String] {
        let env = ProcessInfo.processInfo.environment
        return ["HOME", "TMPDIR", "CFFIXED_USER_HOME", "APP_SANDBOX_CONTAINER_ID"].compactMap { key in
            env[key].map { "\(key)=\($0)" }
        } + ["PATH=/usr/bin:/bin", "LC_ALL=C"]
    }

    private static func spawnAndWait(_ executable: URL, _ arguments: [String], total: Double?, limits: Limits, flag: KillFlag,
                                     progress: (@Sendable (Double) -> Void)?) throws -> Result {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw ConversionError.engine("Frenzy couldn't start the conversion.") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw ConversionError.engine("Frenzy couldn't start the conversion.")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close everything else, and start with default signal handling and an empty mask whatever the worker set.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = childEnvironment().map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard spawned == 0 else {
            close(out[0])
            close(err[0])
            if spawned == EBADARCH { throw ConversionError.engine("This format needs a Mac with Apple silicon.") }
            throw missing
        }

        EngineOrphans.record(pid)
        var reader = Pipes(stdout: out[0], stderr: err[0], total: total, progress: progress)
        defer { reader.closeAll() }

        let start = Date()
        var lastMove = start
        var lastPosition = -1.0
        var lastMemoryCheck = start
        var verdict: Ending?
        while reader.isOpen {
            reader.pump(timeoutMilliseconds: 200)
            let now = Date()
            if reader.position > lastPosition {
                lastPosition = reader.position
                lastMove = now
            }
            guard verdict == nil else { continue } // Killed: just drain until the pipes close.
            if flag.isSet { verdict = .cancelled }
            else if now.timeIntervalSince(start) > limits.maxRuntime { verdict = .tooSlow }
            else if now.timeIntervalSince(lastMove) > limits.stallTimeout { verdict = .stalled }
            else if now.timeIntervalSince(lastMemoryCheck) >= 0.5 {
                lastMemoryCheck = now
                if footprint(of: pid) > limits.maxFootprint { verdict = .tooMuchMemory }
            }
            if verdict != nil { kill(pid, SIGKILL) }
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        EngineOrphans.forget(pid)
        let code = status & 0x7f
        let ending = verdict ?? (code == 0 ? .exited((status >> 8) & 0xff) : .signalled(code))
        if ending == .cancelled { throw CancellationError() }
        return Result(ending: ending, log: reader.log, lastPosition: max(0, reader.position))
    }

    /// The child's physical footprint in bytes, 0 when it can't be read.
    private static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    /// Reads both of the child's pipes without blocking on either, so a full stderr can never stall the engine.
    private struct Pipes {
        private var stdoutFD: Int32
        private var stderrFD: Int32
        private let total: Double?
        private let progress: (@Sendable (Double) -> Void)?
        private var partialLine = Data()
        private var logData = Data()
        private(set) var position = 0.0
        private var lastFraction = -1.0

        /// Enough for any real file's stream list; a file with a megabyte of tags can't grow this further.
        private static let maxLog = 1 << 20

        init(stdout: Int32, stderr: Int32, total: Double?, progress: (@Sendable (Double) -> Void)?) {
            self.stdoutFD = stdout
            self.stderrFD = stderr
            self.total = total
            self.progress = progress
            _ = fcntl(stdout, F_SETFL, fcntl(stdout, F_GETFL) | O_NONBLOCK)
            _ = fcntl(stderr, F_SETFL, fcntl(stderr, F_GETFL) | O_NONBLOCK)
        }

        var isOpen: Bool { stdoutFD >= 0 || stderrFD >= 0 }
        var log: String { String(decoding: logData, as: UTF8.self) }

        mutating func closeAll() {
            if stdoutFD >= 0 { close(stdoutFD); stdoutFD = -1 }
            if stderrFD >= 0 { close(stderrFD); stderrFD = -1 }
        }

        mutating func pump(timeoutMilliseconds: Int32) {
            var fds = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, timeoutMilliseconds) > 0 else { return }
            if fds[0].revents != 0 {
                let (bytes, open) = Self.drain(stdoutFD)
                if !open { stdoutFD = -1 }
                if let bytes { consumeProgress(bytes) }
            }
            if fds[1].revents != 0 {
                let (bytes, open) = Self.drain(stderrFD)
                if !open { stderrFD = -1 }
                if let bytes, logData.count < Self.maxLog { logData.append(bytes.prefix(Self.maxLog - logData.count)) }
            }
        }

        /// What is available now, and whether the descriptor stays open: at end of file it's closed here.
        private static func drain(_ fd: Int32) -> (Data?, Bool) {
            guard fd >= 0 else { return (nil, false) }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return (Data(buffer[0..<count]), true) }
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                close(fd)
                return (nil, false)
            }
            return (nil, true)
        }

        /// `-progress` prints `key=value` lines; only `out_time_us` matters.
        private mutating func consumeProgress(_ bytes: Data) {
            partialLine.append(bytes)
            while let end = partialLine.firstIndex(of: 0x0A) {
                let line = String(decoding: partialLine[partialLine.startIndex..<end], as: UTF8.self)
                partialLine.removeSubrange(partialLine.startIndex...end)
                guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)), micros >= 0 else { continue }
                position = micros / 1_000_000
                guard let total, total > 0, let progress else { continue }
                let fraction = min(0.99, position / total)
                if fraction > lastFraction {
                    lastFraction = fraction
                    progress(fraction)
                }
            }
            // A single line can't be this long, so whatever this is isn't `-progress`.
            if partialLine.count > 1 << 16 { partialLine.removeAll() }
        }
    }
}

// MARK: - Probing

/// What the engine reports about a file, parsed from its `-i` listing.
///
/// Hostile metadata can't fake a line here to any useful effect: the engine indents tag values under "Metadata:" and
/// continues multi-line values with "  : ", the patterns below are anchored at the start of a line, and a wrong answer
/// only makes the conversion fail plainly.
struct MediaProbe: Sendable, Equatable {
    struct Video: Sendable, Equatable {
        var codec: String
        var pixelFormat: String
        var width: Int
        var height: Int
        var isAttachedPicture: Bool
        var isHDR: Bool
        var isTenBit: Bool { pixelFormat.contains("10") || pixelFormat.contains("12") }
        /// 8-bit 4:2:0, the only H.264 flavour QuickTime and iPhones play.
        var is8Bit420: Bool { ["yuv420p", "yuvj420p"].contains(pixelFormat) }
    }

    struct Audio: Sendable, Equatable {
        var codec: String
        var sampleRate: Int
        var channels: Int
        /// Bits worth keeping in a lossless output: 24 for 24-bit and 32-bit sources, otherwise 16.
        var bitDepth: Int
    }

    var seconds: Double
    var video: [Video]
    var audio: [Audio]
    /// The demuxer the engine picked, as it names it: "mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "wav".
    var container: String = ""

    /// Pinned options for the demuxer this file opens with. Only the MOV demuxer has them, and the engine refuses any
    /// option the demuxer doesn't know, so they can only be passed once the probe has said which demuxer it is.
    /// - `-enable_drefs 0`: never open the other files a QuickTime "data reference" names.
    /// - `-use_absolute_path 0`: never follow an absolute path in one either.
    /// Both are already FFmpeg's defaults; pinning them means a future default can't change it.
    var demuxerOptions: [String] {
        container.hasPrefix("mov,") ? ["-use_absolute_path", "0", "-enable_drefs", "0"] : []
    }

    /// The picture track, ignoring cover art.
    var mainVideo: Video? { video.first { !$0.isAttachedPicture } }

    static func parse(_ log: String) -> MediaProbe? {
        var probe = MediaProbe(seconds: 0, video: [], audio: [])
        var sawInput = false
        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("Input #0, ") {
                sawInput = true
                // "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'file:…':" The name comes after " from ", so it can't add to this.
                if let from = line.range(of: ", from '") {
                    probe.container = String(line[line.index(line.startIndex, offsetBy: 10)..<from.lowerBound])
                }
            }
            if line.hasPrefix("  Duration: ") {
                let value = line.dropFirst(12).prefix { $0 != "," }
                let parts = value.split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 { probe.seconds = parts[0] * 3600 + parts[1] * 60 + parts[2] }
            } else if line.hasPrefix("  Stream #0:") {
                if let range = line.range(of: ": Video: ") { probe.video.append(video(String(line[range.upperBound...]))) }
                else if let range = line.range(of: ": Audio: ") { probe.audio.append(audio(String(line[range.upperBound...]))) }
            }
        }
        guard sawInput, !probe.video.isEmpty || !probe.audio.isEmpty else { return nil }
        return probe
    }

    private static func codec(_ text: String) -> String {
        String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    private static func video(_ text: String) -> Video {
        // "vp9 (Profile 0), yuv420p(tv, bt709, progressive), 1920x1080, SAR 1:1 DAR 16:9, 30 fps, ..."
        let pieces = splitOutsideParentheses(text)
        let format = pieces.count > 1 ? String(pieces[1].prefix { $0.isLetter || $0.isNumber }) : ""
        var width = 0, height = 0
        for piece in pieces {
            let trimmed = piece.split(separator: " ").first.map(String.init) ?? ""
            let size = trimmed.split(separator: "x").compactMap { Int($0) }
            if size.count == 2, trimmed.first?.isNumber == true {
                width = size[0]
                height = size[1]
                break
            }
        }
        return Video(codec: codec(text), pixelFormat: format, width: width, height: height,
                     isAttachedPicture: text.contains("(attached pic)"),
                     isHDR: pieces.count > 1 && (pieces[1].contains("smpte2084") || pieces[1].contains("arib-std-b67")))
    }

    private static func audio(_ text: String) -> Audio {
        // "opus, 48000 Hz, stereo, fltp (default)" or "pcm_s24le ([1][0][0][0] / 0x0001), 48000 Hz, 5.1, s32 (24 bit)"
        let pieces = splitOutsideParentheses(text)
        var rate = 0
        for piece in pieces where piece.hasSuffix(" Hz") { rate = Int(piece.dropLast(3)) ?? 0 }
        let layout = pieces.count > 2 ? pieces[2] : ""
        let format = pieces.count > 3 ? pieces[3] : ""
        var depth = 16
        if format.hasPrefix("s24") || format.hasPrefix("s32") { depth = 24 }
        return Audio(codec: codec(text), sampleRate: rate, channels: channelCount(layout), bitDepth: depth)
    }

    static func channelCount(_ layout: String) -> Int {
        let name = layout.prefix { $0 != "(" }
        switch name {
        case "mono": return 1
        case "stereo", "downmix": return 2
        case "2.1", "3.0": return 3
        case "quad", "3.1", "4.0": return 4
        case "4.1", "5.0": return 5
        case "5.1", "6.0": return 6
        case "6.1", "7.0": return 7
        case "7.1", "octagonal": return 8
        default:
            // "6 channels"
            return Int(name.prefix { $0.isNumber }) ?? 2
        }
    }

    private static func splitOutsideParentheses(_ text: String) -> [String] {
        var pieces: [String] = [], current = "", depth = 0
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth = max(0, depth - 1) }
            if ch == ",", depth == 0 {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        pieces.append(current.trimmingCharacters(in: .whitespaces))
        return pieces
    }
}

// MARK: - Arguments and messages

extension MediaEngine {
    /// The largest picture a single frame may have: 8K in both directions is about 67 megapixels. Stops a tiny file from
    /// declaring a frame that takes gigabytes.
    static let maxFramePixels = 67_108_864
    /// The largest single allocation the engine may ask for.
    static let maxAllocation = 2_147_483_648

    /// Paths as the engine sees them. The `file:` prefix means a name can't be read as an option or another protocol.
    static func path(_ url: URL) -> String { "file:" + url.standardizedFileURL.path }

    /// The start of every real run: quiet log, progress on stdout, no stdin, only local files, kernel-enforced CPU limit.
    /// `logLevel` is "info" only for the probe, which reads the stream listing the engine prints at that level.
    static func inputArguments(_ input: URL, limits: Limits, options: [String] = [], maxPixels: Int = maxFramePixels,
                               cores: Int = ProcessInfo.processInfo.activeProcessorCount, logLevel: String = "error") -> [String] {
        // Progress five times a second, so even a short clip moves the bar more than once.
        ["-hide_banner", "-nostdin", "-nostats", "-loglevel", logLevel, "-progress", "pipe:1", "-stats_period", "0.2",
         "-max_alloc", String(maxAllocation),
         // At least one second: a CPU limit of zero would kill the engine before it starts.
         "-timelimit", String(max(1, Int(limits.maxRuntime.rounded(.up))) * max(1, cores)),
         "-protocol_whitelist", "file,pipe",
         "-max_pixels", String(maxPixels)]
            + options + ["-i", path(input)]
    }

    /// The probe's arguments: the same hardened start as every run (memory, CPU-time, protocol and frame-size caps), at
    /// the log level that lists the streams, and no output.
    static func probeArguments(_ input: URL) -> [String] {
        inputArguments(input, limits: .probe, logLevel: "info")
    }

    /// Reads the file's streams. Throws a plain message when the engine can't read it at all.
    static func probe(_ input: URL) async throws -> MediaProbe {
        let result = try await run(probeArguments(input), total: nil, limits: .probe)
        switch result.ending {
        case .exited: break // The engine always "fails" here: it was given no output.
        default: throw failure(result, input: input)
        }
        guard let probe = MediaProbe.parse(result.log) else { throw failure(result, input: input) }
        return probe
    }

    static let damaged = ConversionError.unsupportedInput("It looks damaged, or Frenzy can't read its format.")

    /// Turns how the engine ended into a plain sentence. Its log only picks the sentence; none of it is shown.
    static func failure(_ result: Result, input: URL) -> any Error {
        switch result.ending {
        case .cancelled: return CancellationError()
        case .tooSlow: return ConversionError.engine("This file was taking too long to convert, so Frenzy stopped.")
        case .stalled: return ConversionError.engine("The conversion stopped making progress, so Frenzy ended it. The file may be damaged.")
        case .tooMuchMemory: return ConversionError.engine("This file needs too much memory to convert, so Frenzy stopped.")
        case .signalled: return damaged
        case .exited:
            if result.log.contains("No space left on device") { return ConversionError.engine("The disk is full.") }
            if result.log.contains("Permission denied") || result.log.contains("Operation not permitted") {
                return ConversionError.unreadable(input)
            }
            if result.log.contains("No such file or directory") { return ConversionError.unreadable(input) }
            if result.log.contains("Decoder (codec") || result.log.contains("no decoder found") || result.log.contains("Unknown decoder") {
                return ConversionError.unsupportedInput("It uses a format Frenzy can't decode.")
            }
            return damaged
        }
    }

    /// Runs a conversion to `output`. Throws a plain message on any failure; on success the file exists and isn't empty.
    /// A shorter result than the file promises (`expectedSeconds`) is refused, because the rest of it is damaged.
    /// `secondInput`: another file opened after `input` (input 1), for example the original file's sound next to frames
    /// that arrive through a pipe.
    static func convert(input: URL, output: URL, inputOptions: [String] = [], maxPixels: Int = maxFramePixels,
                        secondInput: (options: [String], url: URL)? = nil,
                        outputArguments: [String], expectedSeconds: Double, checkLength: Bool,
                        limits: Limits? = nil, freeSpace: (@Sendable (URL) -> Int64?)? = nil,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let limits = limits ?? .forMedia(seconds: expectedSeconds)
        var sizeCap: [String] = []
        // `freeSpace` lets a test play a nearly full disk; the app always asks the volume.
        let folder = output.deletingLastPathComponent()
        let free = freeSpace.map { $0(folder) } ?? (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var capBytes: Int64?
        if let free, free > 0 {
            let room = max(1 << 20, free - (256 << 20))
            sizeCap = ["-fs", String(room)]
            capBytes = room
        }
        // `-n`: never overwrite. The name is Frenzy's own temporary one, so nothing should be there.
        let second = secondInput.map { $0.options + ["-i", path($0.url)] } ?? []
        let arguments = inputArguments(input, limits: limits, options: inputOptions, maxPixels: maxPixels) + second
            + outputArguments + sizeCap + ["-n", path(output)]
        let result = try await run(arguments, total: expectedSeconds > 0 ? expectedSeconds : nil, limits: limits, progress: progress)
        try Task.checkCancellation()
        guard result.ending == .exited(0) else { throw failure(result, input: input) }
        let size = AVSupport.fileSize(output)
        guard size > 0 else { throw damaged }
        if let capBytes, size >= capBytes { throw ConversionError.engine("There isn't enough free space to finish this conversion.") }
        if checkLength, expectedSeconds > 2, result.lastPosition < expectedSeconds * 0.9 {
            throw ConversionError.unsupportedInput("It looks incomplete or damaged: only part of it could be read.")
        }
    }
}
