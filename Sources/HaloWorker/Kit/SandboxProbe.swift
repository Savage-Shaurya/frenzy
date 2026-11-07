import Foundation
import HaloCore

/// Debug self-test run INSIDE the worker: tries things the sandbox must forbid (network, writing outside the
/// container) and things it must allow (reading files, writing its own temp folder). `Halo --worker-self-test`
/// prints the result. Nothing is sent anywhere when the sandbox works; if it didn't, the probes would at most open
/// a TCP connection to 1.1.1.1 and fetch https://example.com, and the result would say FAIL.
///
/// The media engine gets its own probes, because it runs as a child of the worker and has to stay inside the same
/// sandbox: see `engineProbes`.
public enum SandboxProbe {
    /// Probes that need code outside this module (the worker sets it to the engine-orphan check, which lives with the
    /// engine in HaloConverters).
    nonisolated(unsafe) public static var extraProbes: (@Sendable () -> [WorkerSelfTest.Probe])?

    public static func run() async -> WorkerSelfTest {
        var probes: [WorkerSelfTest.Probe] = []
        let denied: Set<Int32> = [EPERM, EACCES]

        // 1-3: raw sockets. A sandbox without network entitlements denies socket connect/send with EPERM.
        let local = tcpConnect("127.0.0.1", port: 9)
        probes.append(.init(name: "TCP connect 127.0.0.1:9", expected: "EPERM (denied by sandbox)",
                            observed: local.description, pass: local.errno.map(denied.contains) ?? false))
        let publicTCP = tcpConnect("1.1.1.1", port: 443)
        probes.append(.init(name: "TCP connect 1.1.1.1:443", expected: "EPERM (denied by sandbox)",
                            observed: publicTCP.description, pass: publicTCP.errno.map(denied.contains) ?? false))
        let udp = udpSend("8.8.8.8", port: 53)
        probes.append(.init(name: "UDP sendto 8.8.8.8:53", expected: "EPERM (denied by sandbox)",
                            observed: udp.description, pass: udp.errno.map(denied.contains) ?? false))

        // 4: DNS. The resolver lives behind mDNSResponder, which the sandbox only lets network clients reach.
        let dns = resolve("example.com")
        probes.append(.init(name: "DNS lookup example.com", expected: "fails", observed: dns.observed, pass: !dns.ok))
        // The resolver's own socket, the way every DNS API reaches it: denied, so no DNS through any library either.
        let mdns = unixConnect("/private/var/run/mDNSResponder")
        probes.append(.init(name: "connect to the DNS resolver (mDNSResponder socket)", expected: "EPERM (denied by sandbox)",
                            observed: mdns.description, pass: mdns.errno.map(denied.contains) ?? false))

        probes += launchServicesProbes()

        // 5: URLSession, the high-level API WebKit, AVFoundation and PDFKit would use for remote resources.
        let session = await urlSessionProbe()
        probes.append(.init(name: "URLSession GET https://example.com", expected: "error, no response",
                            observed: session.observed, pass: !session.ok))

        // 6-7: writes outside the container.
        let home = realHome()
        let homeWrite = tryWrite(home.appendingPathComponent(".halo-sandbox-probe-\(UUID().uuidString)"))
        probes.append(.init(name: "write ~/ (real home)", expected: "denied", observed: homeWrite.observed, pass: !homeWrite.ok))
        let tmpWrite = tryWrite(URL(fileURLWithPath: "/private/tmp/.halo-sandbox-probe-\(UUID().uuidString)"))
        probes.append(.init(name: "write /private/tmp", expected: "denied", observed: tmpWrite.observed, pass: !tmpWrite.ok))

        // 8-9: what the worker legitimately needs.
        let ownTemp = tryWrite(FileManager.default.temporaryDirectory.appendingPathComponent(".halo-probe-\(UUID().uuidString)"))
        probes.append(.init(name: "write own container temp", expected: "allowed", observed: ownTemp.observed, pass: ownTemp.ok))
        let read = FileManager.default.isReadableFile(atPath: "/etc/hosts") && (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))) != nil
        probes.append(.init(name: "read /etc/hosts (read-only exception)", expected: "allowed",
                            observed: read ? "read ok" : "read failed", pass: read))

        probes += engineProbes()
        probes += extraProbes?() ?? []

        let env = ProcessInfo.processInfo.environment
        return WorkerSelfTest(pid: getpid(), sandboxContainer: env["APP_SANDBOX_CONTAINER_ID"],
                              homeDirectory: NSHomeDirectory(), temporaryDirectory: FileManager.default.temporaryDirectory.path,
                              probes: probes)
    }

    // MARK: Opening links and apps

    /// What the App Sandbox does NOT stop. macOS lets every sandboxed app ask LaunchServices to open a link or an app
    /// (the `lsopen` operation, and the `com.apple.CoreServices.coreservicesd` service), and to use the pasteboard.
    /// A worker taken over by a hostile file could therefore open a web address in the browser (visibly) or put text on
    /// the clipboard. Frenzy's code never does either, and a process already inside the App Sandbox can't add a
    /// stricter sandbox to itself (`sandbox_init` returns EPERM), so these are reported, and documented in PRIVACY.md,
    /// rather than claimed to be denied. Asking costs nothing: no link is opened, nothing is put on the clipboard.
    /// A probe passes when the answer matches what PRIVACY.md says; if macOS ever starts denying these, it fails so the
    /// document gets updated.
    static func launchServicesProbes() -> [WorkerSelfTest.Probe] {
        let documented = "allowed (App Sandbox limit, see PRIVACY.md)"
        var probes: [WorkerSelfTest.Probe] = []
        let lsopen = sandboxVerdict("lsopen")
        probes.append(.init(name: "kernel: worker may ask macOS to open a link or app (lsopen)", expected: documented,
                            observed: lsopen.observed, pass: lsopen.allowed == true))
        let launchServices = machLookup("com.apple.CoreServices.coreservicesd")
        probes.append(.init(name: "reach LaunchServices (coreservicesd)", expected: documented,
                            observed: launchServices.observed, pass: launchServices.ok))
        let pasteboard = machLookup("com.apple.pasteboard.1")
        probes.append(.init(name: "reach the pasteboard server", expected: documented,
                            observed: pasteboard.observed, pass: pasteboard.ok))
        return probes
    }

    /// The kernel's answer for this process and `operation` (no filter), without logging a violation.
    /// `sandbox_check` is private and used only by this self-test.
    static func sandboxVerdict(_ operation: String) -> (allowed: Bool?, observed: String) {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return (nil, "sandbox_check unavailable") }
        let check = unsafeBitCast(symbol, to: Check.self)
        let result = check(getpid(), operation, 0x4000_0000)
        switch result {
        case 0: return (true, "\(operation) = allowed")
        case 1: return (false, "\(operation) = denied")
        default: return (nil, "\(operation) = \(result)")
        }
    }

    /// Looks a Mach service up by name, which is where the sandbox allows or denies talking to it. Nothing is sent.
    static func machLookup(_ service: String) -> (ok: Bool, observed: String) {
        typealias LookUp = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up") else { return (false, "bootstrap_look_up unavailable") }
        let lookUp = unsafeBitCast(symbol, to: LookUp.self)
        var bootstrap: mach_port_t = 0
        guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS else { return (false, "no bootstrap port") }
        var port: mach_port_t = 0
        let kr = lookUp(bootstrap, service, &port)
        if kr == KERN_SUCCESS {
            mach_port_deallocate(mach_task_self_, port)
            return (true, "look-up succeeded")
        }
        // 1100 is BOOTSTRAP_NOT_PRIVILEGED: the sandbox said no.
        return (false, kr == 1100 ? "denied (BOOTSTRAP_NOT_PRIVILEGED)" : "look-up failed (\(kr))")
    }

    static func unixConnect(_ path: String) -> SocketResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { let e = Darwin.errno; return SocketResult(errno: e, detail: "socket() failed: \(name(e))") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return SocketResult(errno: nil, detail: "path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc == 0 { return SocketResult(errno: nil, detail: "CONNECTED") }
        let e = Darwin.errno
        return SocketResult(errno: e, detail: "connect() = -1, \(name(e))")
    }

    // MARK: Media engine

    /// `Contents/Helpers/frenzy-media-engine` in the worker's bundle. Nil outside a bundle (unit tests).
    static var engineURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "xpc" else { return nil }
        return bundle.appendingPathComponent("Contents/Helpers/frenzy-media-engine")
    }

    /// Runs the real engine as a child of the worker, then checks it is as locked down as the worker:
    /// - it runs, says GPL (x264 / x265 since 7 Nov 2026), has no VideoToolbox encoder (the video chip), and has only
    ///   the `file` and `pipe` protocols, so it has no way to ask for a network;
    /// - the kernel's own answer for its process id is "sandboxed, network denied";
    /// - it can't write outside the container, which proves the worker's sandbox reached it;
    /// - an ordinary system tool started the same way really does try the network and gets refused, since the engine
    ///   itself has no socket code to try with.
    static func engineProbes() -> [WorkerSelfTest.Probe] {
        guard let engine = engineURL else { return [] }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            return [.init(name: "media engine in the worker's bundle", expected: "present", observed: "missing", pass: false)]
        }
        var probes: [WorkerSelfTest.Probe] = []
        let version = runChild(engine, ["-hide_banner", "-version"])
        probes.append(.init(name: "engine runs as the worker's child", expected: "exit 0", observed: "exit \(version.status)", pass: version.status == 0))

        let license = runChild(engine, ["-hide_banner", "-L"])
        let isGPL = license.output.contains("GNU General Public License")
        probes.append(.init(name: "engine -L", expected: "GPL", observed: isGPL ? "GNU General Public License" : "not GPL", pass: isGPL))

        let encoders = runChild(engine, ["-hide_banner", "-encoders"]).output.lowercased()
        let noChip = !encoders.contains("videotoolbox")
        probes.append(.init(name: "engine has no hardware video encoder", expected: "no VideoToolbox",
                            observed: noChip ? "no VideoToolbox" : "VideoToolbox encoder present", pass: noChip))

        let protocols = runChild(engine, ["-hide_banner", "-protocols"]).output
        let names = protocols.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") && !$0.hasPrefix("Supported") }
        let onlyLocal = Set(names) == ["file", "pipe"]
        probes.append(.init(name: "engine protocols", expected: "file, pipe only", observed: Set(names).sorted().joined(separator: ", "), pass: onlyLocal))

        let tcp = runChild(engine, ["-hide_banner", "-nostdin", "-i", "tcp://1.1.1.1:443"])
        let noProtocol = tcp.status != 0 && tcp.output.contains("Protocol not found")
        probes.append(.init(name: "engine opens tcp://1.1.1.1:443", expected: "no such protocol", observed: lastLine(tcp.output), pass: noProtocol))

        probes.append(contentsOf: kernelVerdict(engine))

        // A real file for the two write probes.
        let temp = FileManager.default.temporaryDirectory
        let wav = temp.appendingPathComponent(".halo-engine-probe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try? silentWAV().write(to: wav)
        func write(to path: String) -> (status: Int32, output: String) {
            runChild(engine, ["-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file,pipe", "-i", "file:" + wav.path,
                              "-c:a", "pcm_s16le", "-f", "wav", "-n", "file:" + path])
        }
        let outsidePath = "/private/tmp/.halo-engine-probe-\(UUID().uuidString).wav"
        let outside = write(to: outsidePath)
        let wroteOutside = FileManager.default.fileExists(atPath: outsidePath)
        if wroteOutside { unlink(outsidePath) }
        let denied = outside.status != 0 && !wroteOutside && (outside.output.contains("not permitted") || outside.output.contains("Permission denied"))
        probes.append(.init(name: "engine writes /private/tmp", expected: "denied", observed: lastLine(outside.output), pass: denied))

        let insidePath = temp.appendingPathComponent(".halo-engine-probe-\(UUID().uuidString).wav").path
        let inside = write(to: insidePath)
        let wroteInside = FileManager.default.fileExists(atPath: insidePath)
        if wroteInside { unlink(insidePath) }
        probes.append(.init(name: "engine writes own container temp", expected: "allowed", observed: "exit \(inside.status)", pass: inside.status == 0 && wroteInside))

        // The attempt itself. `-G 3`: give up after 3 s if the sandbox ever let it through.
        // `-v`: without it nc fails silently, and the probe needs the reason to tell a sandbox denial from a dead route.
        let nc = runChild(URL(fileURLWithPath: "/usr/bin/nc"), ["-v", "-z", "-G", "3", "1.1.1.1", "443"])
        let refused = nc.status != 0 && (nc.output.contains("not permitted") || nc.output.contains("Permission denied"))
        probes.append(.init(name: "worker's child tries TCP 1.1.1.1:443 (nc)", expected: "EPERM (denied by sandbox)", observed: lastLine(nc.output), pass: refused))
        return probes
    }

    /// Asks the kernel about the live engine process: is it sandboxed, and may it reach the network?
    /// `sandbox_check` is a private call, used only by this self-test. If a macOS update removes it, the probe says so.
    private static func kernelVerdict(_ engine: URL) -> [WorkerSelfTest.Probe] {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else {
            return [.init(name: "kernel's verdict on the engine", expected: "sandboxed", observed: "sandbox_check unavailable", pass: false)]
        }
        let check = unsafeBitCast(symbol, to: Check.self)
        // SANDBOX_CHECK_NO_REPORT: asking isn't an attempt, so don't log a violation.
        let noReport: Int32 = 0x4000_0000

        // Reads stdin, which stays open until we're done, so the process is alive to ask about.
        let process = Process()
        process.executableURL = engine
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "quiet", "-protocol_whitelist", "pipe", "-f", "wav", "-i", "pipe:0", "-f", "null", "-"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return [.init(name: "kernel's verdict on the engine", expected: "sandboxed", observed: "couldn't start: \(error.localizedDescription)", pass: false)]
        }
        defer {
            process.terminate()
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        // -nostdin only stops keyboard commands; pipe:0 is still read.
        usleep(200_000)
        let pid = process.processIdentifier
        let sandboxed = process.isRunning ? check(pid, nil, 0) : -1
        let network = process.isRunning ? check(pid, "network-outbound", noReport) : -1
        return [
            .init(name: "kernel: engine process is sandboxed", expected: "yes", observed: "sandbox_check(pid \(pid)) = \(sandboxed)", pass: sandboxed == 1),
            .init(name: "kernel: engine may use the network", expected: "denied", observed: "network-outbound = \(network == 1 ? "denied" : "\(network)")", pass: network == 1),
        ]
    }

    /// Runs a child with stdin closed, waits at most 10 s, and returns its status and what it printed.
    private static func runChild(_ url: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "couldn't start: \(error.localizedDescription)") }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(decoding: data.prefix(1 << 16), as: UTF8.self))
    }

    private static func lastLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "(no output)"
        // These land in a Markdown table.
        return String(line.prefix(120)).replacingOccurrences(of: "|", with: "/")
    }

    /// A tenth of a second of silence, the smallest real input the engine will accept.
    private static func silentWAV() -> Data {
        let rate: UInt32 = 8_000, samples = 800
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples * 2)
        data.append(Data("RIFF".utf8)); u32(36 + bytes); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(bytes); data.append(Data(count: Int(bytes)))
        return data
    }

    struct SocketResult: CustomStringConvertible {
        let errno: Int32?
        let detail: String
        var description: String { detail }
    }

    static func tcpConnect(_ ip: String, port: UInt16) -> SocketResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { let e = Darwin.errno; return SocketResult(errno: e, detail: "socket() failed: \(name(e))") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return SocketResult(errno: nil, detail: "CONNECTED") }
        var e = Darwin.errno
        if e == EINPROGRESS {
            // Wait up to 3 s for the outcome.
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 3000) > 0 {
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                if soError == 0 { return SocketResult(errno: nil, detail: "CONNECTED") }
                e = soError
            } else {
                return SocketResult(errno: nil, detail: "no answer in 3 s (connect was attempted)")
            }
        }
        return SocketResult(errno: e, detail: "connect() = -1, \(name(e))")
    }

    static func udpSend(_ ip: String, port: UInt16) -> SocketResult {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { let e = Darwin.errno; return SocketResult(errno: e, detail: "socket() failed: \(name(e))") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let byte: [UInt8] = [0]
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc >= 0 { return SocketResult(errno: nil, detail: "SENT \(rc) byte") }
        let e = Darwin.errno
        return SocketResult(errno: e, detail: "sendto() = -1, \(name(e))")
    }

    static func resolve(_ host: String) -> (ok: Bool, observed: String) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, "443", &hints, &result)
        if rc == 0 { freeaddrinfo(result); return (true, "RESOLVED") }
        return (false, "getaddrinfo = \(rc) (\(String(cString: gai_strerror(rc))))")
    }

    static func urlSessionProbe() async -> (ok: Bool, observed: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: URL(string: "https://example.com/")!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (true, "GOT HTTP \(status)")
        } catch {
            let ns = error as NSError
            return (false, "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
    }

    static func tryWrite(_ url: URL) -> (ok: Bool, observed: String) {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 {
            close(fd)
            unlink(url.path)
            return (true, "written (and removed)")
        }
        let e = Darwin.errno
        return (false, "open() = -1, \(name(e))")
    }

    static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func name(_ e: Int32) -> String {
        let names: [Int32: String] = [EPERM: "EPERM", EACCES: "EACCES", ECONNREFUSED: "ECONNREFUSED",
                                      ENETUNREACH: "ENETUNREACH", EHOSTUNREACH: "EHOSTUNREACH", ETIMEDOUT: "ETIMEDOUT"]
        return "\(names[e] ?? "errno \(e)") (\(String(cString: strerror(e))))"
    }
}
