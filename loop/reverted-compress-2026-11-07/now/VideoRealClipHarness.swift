import AVFoundation
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers

/// Runs conversions on real footage and logs what happened. Off unless `HALO_REAL_JOBS` points at a job list, so normal
/// test runs never touch it. One job per line: `action|file` (`action` is an action ID) or
/// `plan:<compress|smaller>:q=0.6[:cap=0.8][:long=1920:short=1080]|file|out`, plus optional `|cancel=<seconds>`.
/// Results are appended to `HALO_REAL_LOG` as JSON lines: time, sizes, peak memory, progress smoothness.
@Suite("Video real clips", .enabled(if: ProcessInfo.processInfo.environment["HALO_REAL_JOBS"] != nil), .serialized)
struct VideoRealClipHarness {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Double = -1, lastAt = Date(), maxGap = 0.0, count = 0, backwards = 0, firstAt: Date?, finishStart: Date?
        private let start = Date()
        func record(_ value: Double) {
            lock.withLock {
                let now = Date()
                if count > 0 { maxGap = max(maxGap, now.timeIntervalSince(lastAt)) }
                if value < last { backwards += 1 }
                if firstAt == nil { firstAt = now }
                if value >= 0.979, finishStart == nil { finishStart = now }
                last = value; lastAt = now; count += 1
            }
        }
        var summary: [String: Any] {
            lock.withLock {
                ["updates": count, "max_gap_s": maxGap, "backwards": backwards, "last": last,
                 "first_after_s": firstAt?.timeIntervalSince(start) ?? -1,
                 "finishing_s": finishStart.map { lastAt.timeIntervalSince($0) } ?? -1]
            }
        }
    }

    final class MemoryPeak: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var timer: (any DispatchSourceTimer)?
        func start() {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now(), repeating: 0.25)
            t.setEventHandler { [self] in
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let kr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
                }
                if kr == KERN_SUCCESS { lock.withLock { peak = max(peak, info.phys_footprint) } }
            }
            t.resume()
            timer = t
        }
        func stop() -> UInt64 {
            timer?.cancel()
            return lock.withLock { peak }
        }
    }

    @Test func runJobs() async throws {
        let env = ProcessInfo.processInfo.environment
        let jobs = try String(contentsOfFile: env["HALO_REAL_JOBS"]!, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        let logURL = URL(fileURLWithPath: env["HALO_REAL_LOG"] ?? "/dev/stdout")
        for job in jobs {
            let parts = job.split(separator: "|").map(String.init)
            let file = URL(fileURLWithPath: parts[1])
            let recorder = Recorder(), memory = MemoryPeak()
            let cancelAfter = parts.last.flatMap { $0.hasPrefix("cancel=") ? Double($0.dropFirst(7)) : nil }
            var row: [String: Any] = ["job": parts[0], "file": file.lastPathComponent, "before": AVSupport.fileSize(file)]
            memory.start()
            let start = Date()
            let work: Task<[String: String], Never>
            if parts[0].hasPrefix("plan:") {
                let out = URL(fileURLWithPath: parts[2])
                try? FileManager.default.removeItem(at: out)
                let plan = Self.plan(parts[0])
                work = Task {
                    do {
                        let media = try await AVSupport.open(file, requireVideo: true)
                        let prepared = try await AVTranscoder.prepare(media, plan: plan)
                        var target = out
                        if prepared.pathExtension != out.pathExtension { target = out.deletingPathExtension().appendingPathExtension(prepared.pathExtension) }
                        try? FileManager.default.removeItem(at: target)
                        try await AVTranscoder.transcode(prepared, to: target, progress: { recorder.record($0) })
                        return ["out": target.path, "after": "\(AVSupport.fileSize(target))"]
                    } catch {
                        return ["error": "\(error)"]
                    }
                }
            } else {
                let id = ActionID(rawValue: parts[0])
                work = Task {
                    let input = InputFile(url: file)!
                    let outcome = await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1).run(id, on: [input], progress: { recorder.record($0) })
                    var r = ["failures": outcome.failures.map(\.message).joined(separator: "; ")]
                    if let out = outcome.outputs.first { r["out"] = out.path; r["after"] = "\(AVSupport.fileSize(out))" }
                    return r
                }
            }
            var cancelledAt: Date?
            if let cancelAfter {
                try await Task.sleep(for: .seconds(cancelAfter))
                cancelledAt = Date()
                work.cancel()
            }
            let result = await work.value
            let elapsed = Date().timeIntervalSince(start)
            row["seconds"] = elapsed
            if let cancelledAt { row["cancel_took_s"] = Date().timeIntervalSince(cancelledAt) }
            row["peak_mem_mb"] = memory.stop() / (1 << 20)
            row["progress"] = recorder.summary
            row.merge(result) { $1 }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try data.write(to: logURL)
            }
        }
    }

    private static func plan(_ text: String) -> AVTranscoder.Plan {
        let fields = text.split(separator: ":").map(String.init)
        var plan = fields[1] == "smaller" ? AVTranscoder.Plan.smaller : AVTranscoder.Plan.compress
        for field in fields.dropFirst(2) {
            let kv = field.split(separator: "=").map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            switch kv[0] {
            case "q": plan.quality8 = v; plan.quality10 = v
            case "cap": plan.maxFractionOfSource = v
            case "long": plan.maxLongEdge = CGFloat(v)
            case "short": plan.maxShortEdge = CGFloat(v)
            default: break
            }
        }
        return plan
    }
}
