import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloCore

private func tempDir(_ label: String = "rw") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func file(_ name: String, in dir: URL, _ text: String = "x") throws -> InputFile {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return try #require(InputFile(url: url))
}

private func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// Staged output prepared the way the worker leaves it.
private func staged(for input: InputFile, in root: URL, ext: String = "txt") throws -> StagedOutput {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let base = input.url.deletingPathExtension().lastPathComponent
    let path = folder.appendingPathComponent("\(base).\(ext)")
    try Data("out".utf8).write(to: path)
    return StagedOutput(stagedPath: path.path, directory: input.url.deletingLastPathComponent().path, baseName: base,
                        suffix: nil, pathExtension: ext, isFolder: false)
}

private func outcome(_ item: StagedOutput) -> ConversionOutcome {
    ConversionOutcome(actionID: "t.out", outputs: [URL(fileURLWithPath: item.stagedPath)], staged: [item], failures: [], duration: .zero)
}

@Suite struct SaveFallbackTests {
    /// The real complaint: the work is done, then "Couldn't save". Now the file lands in the fallback and says so.
    @Test func readOnlyFolderFallsBackInsteadOfLosingTheWork() throws {
        let source = try tempDir(), root = try tempDir(), downloads = try tempDir()
        let input = try file("photo.heic", in: source)
        let item = try staged(for: input, in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }

        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [input],
                                     savePolicy: SavePolicy(fallbackFolder: downloads)).place(outcome(item))
        #expect(placed.failures.isEmpty)
        #expect(placed.outputs == [downloads.appendingPathComponent("photo.txt")])
        #expect(placed.redirected == placed.outputs)
        #expect(try names(source) == ["photo.heic"], "nothing added beside the original")
        #expect(try names(downloads) == ["photo.txt"], "no scratch files left")
    }

    @Test func withNoFallbackItStillFailsWithAPlainMessage() throws {
        let source = try tempDir(), root = try tempDir()
        let input = try file("photo.heic", in: source)
        let item = try staged(for: input, in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }
        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [input]).place(outcome(item))
        #expect(placed.outputs.isEmpty)
        #expect(placed.failures.first?.message.contains("read-only") == true)
    }

    @Test func aWritableFolderIsLeftAlone() throws {
        let source = try tempDir(), root = try tempDir(), downloads = try tempDir()
        let input = try file("photo.heic", in: source)
        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [input], savePolicy: SavePolicy(fallbackFolder: downloads))
            .place(outcome(try staged(for: input, in: root)))
        #expect(placed.outputs == [source.appendingPathComponent("photo.txt")])
        #expect(placed.redirected.isEmpty)
        #expect(try names(downloads).isEmpty)
    }

    /// Files from another app sit in a temp folder, and a file from the Trash sits in the Trash. Neither is a place to
    /// save a result the user wants to find.
    @Test func outputsNeverLandInTheInboxOrTheTrash() throws {
        let home = try tempDir(), root = try tempDir(), downloads = try tempDir()
        let inbox = PromiseInbox(root: home.appendingPathComponent("inbox"))
        let drop = try inbox.makeDropFolder()
        let promised = try file("IMG_1.heic", in: drop)
        var policy = SavePolicy.standard(inbox: inbox.root, home: home)
        policy.fallbackFolder = downloads
        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [promised], savePolicy: policy)
            .place(outcome(try staged(for: promised, in: root)))
        #expect(placed.outputs == [downloads.appendingPathComponent("IMG_1.txt")])
        #expect(placed.redirected == placed.outputs)

        let trash = home.appendingPathComponent(".Trash/old")
        #expect(policy.mustRedirect(trash))
        #expect(policy.mustRedirect(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501")))
        #expect(!policy.mustRedirect(home.appendingPathComponent("Pictures")))
    }

    /// A worker can't use the fallback to write somewhere else: the destination check still comes first.
    @Test func theFallbackDoesNotLoosenTheDestinationCheck() throws {
        let source = try tempDir(), root = try tempDir(), downloads = try tempDir(), elsewhere = try tempDir()
        let input = try file("photo.heic", in: source)
        let good = try staged(for: input, in: root)
        let bad = StagedOutput(stagedPath: good.stagedPath, directory: elsewhere.path, baseName: "x", suffix: nil, pathExtension: "txt", isFolder: false)
        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [input], savePolicy: SavePolicy(fallbackFolder: downloads)).place(outcome(bad))
        #expect(placed.outputs.isEmpty)
        #expect(try names(downloads).isEmpty && names(elsewhere).isEmpty)
    }

    @Test func thePlanChecksBeforeAnyWork() throws {
        let good = try tempDir(), bad = try tempDir(), downloads = try tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path) }
        let policy = SavePolicy(fallbackFolder: downloads)
        #expect(policy.plan(forFolders: [good]) == .nextToOriginals)
        #expect(policy.plan(forFolders: [good, bad]) == .fallback(folder: downloads, blocked: [bad]))
        #expect(SavePolicy.nextToOriginalsOnly.plan(forFolders: [bad]) == .nowhere(blocked: [bad]))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path) }
        #expect(policy.plan(forFolders: [bad]) == .nowhere(blocked: [bad]), "nowhere to save: stop before converting")
        #expect(try names(good).isEmpty, "the write check leaves nothing behind")
    }

    @Test func aSlowFolderIsOnlyCheckedOnce() {
        var checks = 0
        let folder = URL(fileURLWithPath: "/tmp/one")
        _ = SavePolicy(fallbackFolder: nil).plan(forFolders: Array(repeating: folder, count: 500)) { _ in checks += 1; return true }
        #expect(checks == 1)
    }

    /// `HALO_DMG=1 swift test --filter readOnlyDiskImage`. Mounts a real read-only image, hidden from Finder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HALO_DMG"] == "1"))
    func readOnlyDiskImage() throws {
        let work = try tempDir("dmg"), content = try tempDir("dmgsrc"), root = try tempDir(), downloads = try tempDir()
        _ = try file("photo.txt", in: content)
        let dmg = work.appendingPathComponent("t.dmg"), mount = work.appendingPathComponent("mnt")
        func tool(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "hdiutil \(args[0])")
        }
        try tool(["create", "-quiet", "-srcfolder", content.path, "-format", "UDZO", dmg.path])
        try tool(["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        defer { try? tool(["detach", "-quiet", mount.path]) }

        let input = try #require(InputFile(url: mount.appendingPathComponent("photo.txt")))
        let policy = SavePolicy(fallbackFolder: downloads)
        #expect(policy.plan(forFolders: [mount]) == .fallback(folder: downloads, blocked: [mount]))
        let placed = StagedPlacement(allowedStagingRoot: root, inputs: [input], savePolicy: policy)
            .place(outcome(try staged(for: input, in: root)))
        #expect(placed.redirected.count == 1)
        #expect(try names(downloads) == ["photo.txt"])
    }
}

@Suite struct PrivacyFolderTests {
    /// Listing any of these at launch makes macOS ask for permission out of nowhere, or wakes a disk.
    @Test func coversEveryPlaceThatPromptsOrStalls() {
        let home = URL(fileURLWithPath: "/Users/x")
        for path in ["/Users/x/Desktop", "/Users/x/Documents/a", "/Users/x/Downloads/b/c", "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/d",
                     "/Users/x/Library/CloudStorage/Dropbox/e", "/Volumes/NAS/f"] {
            #expect(PrivacyFolders.isProtected(URL(fileURLWithPath: path), home: home), "\(path)")
        }
        for path in ["/Users/x/Pictures", "/Users/x/DesktopArchive", "/tmp/a"] {
            #expect(!PrivacyFolders.isProtected(URL(fileURLWithPath: path), home: home), "\(path)")
        }
    }
}

// MARK: - Worker recovery

/// Stands in for the worker process: everything in flight dies together when a poison file is reached.
private actor FakeWorker {
    private var inFlight: [UUID: CheckedContinuation<WorkerAttemptResult, Never>] = [:]
    private(set) var attempts: [[String]] = []
    private(set) var maxTogether = 0
    private var togetherDuringRetry: [Int] = []
    let poison: Set<String>
    let death: WorkerDeath
    /// Files that die only when they aren't alone (a parallel batch that ran out of memory).
    let diesInCompany: Set<String>

    init(poison: Set<String> = [], death: WorkerDeath = .crashed, diesInCompany: Set<String> = []) {
        self.poison = poison
        self.death = death
        self.diesInCompany = diesInCompany
    }

    func attempt(_ inputs: [InputFile], action: ActionID) async -> WorkerAttemptResult {
        let names = inputs.map { $0.url.lastPathComponent }
        attempts.append(names)
        let id = UUID()
        return await withCheckedContinuation { c in
            inFlight[id] = c
            maxTogether = max(maxTogether, inFlight.count)
            let dies = names.contains(where: poison.contains) || (names.count > 1 && names.contains(where: diesInCompany.contains))
            Task {
                // A crash comes first, so whatever is in flight beside it really is caught by it.
                try? await Task.sleep(for: .milliseconds(dies ? 15 : 45))
                await self.finish(id, inputs: inputs, action: action, dies: dies)
            }
        }
    }

    private func finish(_ id: UUID, inputs: [InputFile], action: ActionID, dies: Bool) {
        if dies {
            let all = inFlight
            inFlight = [:]
            all.values.forEach { $0.resume(returning: .died(death)) }
            return
        }
        guard let c = inFlight.removeValue(forKey: id) else { return }
        c.resume(returning: .finished(ConversionOutcome(actionID: action, outputs: inputs.map { $0.url.appendingPathExtension("out") },
                                                        failures: [], duration: .milliseconds(1))))
    }

    func count(of name: String) -> Int { attempts.filter { $0.contains(name) }.count }
}

private func inputs(_ names: String...) -> [InputFile] {
    names.map { InputFile(url: URL(fileURLWithPath: "/tmp/\($0)"), type: .plainText) }
}

private func runOn(_ worker: FakeWorker, _ recovery: WorkerRecovery, _ files: [InputFile], canSplit: Bool = true,
                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConversionOutcome {
    await recovery.run("t.x", on: files, canSplit: canSplit, progress: progress) { part, _ in
        await worker.attempt(part, action: "t.x")
    }
}

@Suite struct WorkerRecoveryTests {
    /// The bug: one bad file failed every job in flight, each blamed as "may be damaged".
    @Test func anInnocentJobRetriesAndOnlyTheCauseFails() async {
        let worker = FakeWorker(poison: ["bad.heic"])
        let recovery = WorkerRecovery()
        async let good = runOn(worker, recovery, inputs("good.heic"))
        async let bad = runOn(worker, recovery, inputs("bad.heic"))
        let (a, b) = await (good, bad)
        #expect(a.failures.isEmpty && a.outputs.count == 1, "innocent job recovered")
        #expect(b.outputs.isEmpty)
        #expect(b.failures.first?.message == WorkerFailureText.crash)
        #expect(await worker.count(of: "good.heic") == 2)
        #expect(await worker.count(of: "bad.heic") == 2, "one retry, then it's the cause")
    }

    /// Alone with one file, there's nobody else to blame: running a 20-minute crash twice helps nobody.
    @Test func aJobAloneWithOneFileFailsAtOnce() async {
        let worker = FakeWorker(poison: ["bad.heic"])
        let result = await runOn(worker, WorkerRecovery(), inputs("bad.heic"))
        #expect(result.failures.first?.message == WorkerFailureText.crash)
        #expect(await worker.attempts.count == 1)
    }

    /// One bad file in a batch of many used to lose the whole batch.
    @Test func aBatchKeepsEverythingButTheBadFile() async {
        let worker = FakeWorker(poison: ["bad.jpg"])
        let result = await runOn(worker, WorkerRecovery(), inputs("a.jpg", "bad.jpg", "c.jpg"))
        #expect(result.outputs.count == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.input?.lastPathComponent == "bad.jpg")
        #expect(result.failures.first?.message.contains("bad.jpg") == true, "says which one")
    }

    @Test func retriesRunOneAtATime() async {
        let worker = FakeWorker(poison: ["bad.jpg"])
        _ = await runOn(worker, WorkerRecovery(), inputs("a.jpg", "bad.jpg", "c.jpg", "d.jpg"))
        // The batch attempt is one job; every retry after it has to have been alone.
        #expect(await worker.maxTogether == 1)
        #expect(await worker.attempts.count == 5)
    }

    @Test func aNewJobNeverJoinsARetry() async {
        let worker = FakeWorker(poison: ["bad.jpg"])
        let recovery = WorkerRecovery()
        async let batch = runOn(worker, recovery, inputs("a.jpg", "bad.jpg", "c.jpg"))
        try? await Task.sleep(for: .milliseconds(50)) // the batch has died; its retries are under way
        async let late = runOn(worker, recovery, inputs("late.jpg"))
        let (first, second) = await (batch, late)
        #expect(first.outputs.count == 2)
        #expect(second.failures.isEmpty, "a retry's crash is never blamed on a bystander")
    }

    /// A memory death has nothing to do with damage.
    @Test func aMemoryDeathSaysMemory() async {
        let worker = FakeWorker(poison: ["huge.tif"], death: .memoryLimit)
        let result = await runOn(worker, WorkerRecovery(), inputs("huge.tif"))
        let message = result.failures.first?.message ?? ""
        #expect(message == WorkerFailureText.memory)
        #expect(message.contains("memory") && !message.contains("damaged"))
    }

    /// Ten big images in parallel ran out of memory; each alone is fine. Nobody should be told their file is too big.
    @Test func aBatchThatOnlyDiedOfParallelMemoryUseFinishes() async {
        let worker = FakeWorker(death: .memoryLimit, diesInCompany: ["big1.tif"])
        let result = await runOn(worker, WorkerRecovery(), inputs("big1.tif", "big2.tif", "big3.tif"))
        #expect(result.outputs.count == 3 && result.failures.isEmpty)
    }

    /// Merge can't be split: it retries whole, and a crash blames the set.
    @Test func aCombinedJobRetriesWhole() async {
        let worker = FakeWorker(poison: ["a.pdf"])
        let recovery = WorkerRecovery()
        async let company = runOn(worker, recovery, inputs("other.pdf"))
        async let merged = runOn(worker, recovery, inputs("a.pdf", "b.pdf"), canSplit: false)
        let (_, result) = await (company, merged)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.input == nil)
        #expect(await worker.attempts.filter { $0 == ["a.pdf", "b.pdf"] }.count == 2)
    }

    /// The connection dropped (the worker restarted under it): nothing suggests the file, so it gets another go.
    @Test func aLostConnectionRetriesEvenAlone() async {
        let lost = LostOnce()
        let result = await WorkerRecovery().run("t.x", on: inputs("a.txt"), canSplit: true, progress: { _ in }) { part, _ in
            await lost.attempt(part)
        }
        #expect(result.failures.isEmpty && result.outputs.count == 1)
        #expect(await lost.tries == 2)
    }

    /// The app was replaced on disk: a retry can't reach the worker, and the file isn't to blame.
    @Test func aReplacedAppSaysSoAndDoesNotRetry() async {
        let worker = FakeWorker(poison: ["a.txt", "b.txt"], death: .appReplaced)
        let result = await runOn(worker, WorkerRecovery(), inputs("a.txt", "b.txt"))
        #expect(result.failures.first?.message == WorkerFailureText.replaced)
        #expect(!(result.failures.first?.message.contains("damaged") ?? true))
        #expect(await worker.attempts.count == 1)
    }

    @Test func cancellingDuringARetryStops() async {
        let worker = FakeWorker(poison: ["a.txt"])
        let task = Task { await runOn(worker, WorkerRecovery(), inputs("a.txt", "b.txt", "c.txt", "d.txt", "e.txt")) }
        try? await Task.sleep(for: .milliseconds(45))
        task.cancel()
        _ = await task.value
        #expect(await worker.attempts.count < 6, "the remaining files didn't run")
    }

    /// Files saved before the cancel stay saved; the ones that never ran aren't reported as failures.
    @Test func aCancelMidRetryIsNotAFailure() async {
        let ran = Seen()
        let task = Task {
            await WorkerRecovery().run("t.x", on: inputs("a", "b", "c"), canSplit: true, progress: { _ in }) { part, _ in
                ran.add(Double(part.count))
                if part.count == 3 { return .died(.crashed) }
                if part[0].url.lastPathComponent == "a" {
                    return .finished(ConversionOutcome(actionID: "t.x", outputs: [part[0].url], failures: [], duration: .zero))
                }
                try? await Task.sleep(for: .seconds(30))
                return .finished(.failed("t.x", ConversionError.cancelled.errorDescription ?? ""))
            }
        }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        let result = await task.value
        #expect(result.outputs.count == 1)
        #expect(result.failures.isEmpty)
    }

    @Test func progressNeverGoesBackwardsThroughARetry() async {
        let seen = Seen()
        let result = await WorkerRecovery().run("t.x", on: inputs("a", "b", "c", "d"), canSplit: true, progress: { seen.add($0) }) { part, report in
            report(part.count == 4 ? 0.6 : 0.5)
            return part.count == 4 ? .died(.crashed)
                : .finished(ConversionOutcome(actionID: "t.x", outputs: [part[0].url], failures: [], duration: .zero))
        }
        #expect(result.outputs.count == 4)
        let values = seen.values
        #expect(values == values.sorted())
        #expect(values.first == 0.6)
    }

    @Test func messagesAreWrittenForPeople() {
        for death in [WorkerDeath.crashed, .memoryLimit, .connectionLost, .appReplaced] {
            for name in [nil, "photo.heic"] {
                let text = WorkerFailureText.message(for: death, name: name)
                #expect(!text.contains("worker") && !text.contains("XPC") && !text.contains("—"))
            }
        }
    }
}

private actor LostOnce {
    private(set) var tries = 0
    func attempt(_ part: [InputFile]) -> WorkerAttemptResult {
        tries += 1
        return tries == 1 ? .died(.connectionLost)
            : .finished(ConversionOutcome(actionID: "t.x", outputs: [part[0].url], failures: [], duration: .zero))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

@Suite struct WorkerExitNoteTests {
    @Test func theMarkerOnlyCountsForJobsItCouldHaveKilled() throws {
        let root = try tempDir()
        #expect(!WorkerExitNote.memoryLimitHit(since: Date(), stagingRoot: root), "no marker, no memory death")
        WorkerExitNote.writeMemoryMarker(inStagingRoot: root)
        #expect(WorkerExitNote.memoryLimitHit(since: Date(), stagingRoot: root))
        #expect(!WorkerExitNote.memoryLimitHit(since: Date().addingTimeInterval(60), stagingRoot: root), "an old marker can't explain a later crash")
    }

    @Test func theStagingSweepLeavesTheMarkerAlone() throws {
        let root = try tempDir()
        WorkerExitNote.writeMemoryMarker(inStagingRoot: root)
        TempSweeper.sweepStaging(root, maxAge: -1)
        #expect(FileManager.default.fileExists(atPath: WorkerExitNote.memoryMarker(inStagingRoot: root).path))
    }
}

@Suite struct AppBundleStampTests {
    private func makeBundle(in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("Frenzy.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    @Test func noticesAReplacedOrMissingApp() throws {
        let bundle = try makeBundle(in: try tempDir())
        let stamp = try #require(AppBundleStamp(bundle: bundle))
        #expect(stamp.isUnchanged)
        // How a rebuild or an update looks: the same path with new files.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: plist)
        try Data("<plist/>".utf8).write(to: plist)
        #expect(!stamp.isUnchanged)
        try FileManager.default.removeItem(at: bundle)
        #expect(!stamp.isUnchanged, "moved or deleted")
    }

    @Test func aBuildThatIsntABundleIsNeverReplaced() throws {
        #expect(AppBundleStamp(bundle: try tempDir()) == nil)
    }
}

// MARK: - Cloud placeholders

private final class FakeCloud: CloudFileProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [URL: CloudFileState]
    private var started: [URL] = []
    private var pollsLeft: Int
    private var then: CloudFileState
    var canStart = true

    init(_ states: [URL: CloudFileState], pollsUntilDone: Int = 2, then: CloudFileState = .local) {
        self.states = states
        self.pollsLeft = pollsUntilDone
        self.then = then
    }

    func state(of url: URL) -> CloudFileState {
        lock.withLock {
            let current = states[url] ?? .local
            guard current != .local, started.contains(url) else { return current }
            pollsLeft -= 1
            if pollsLeft <= 0 { states[url] = then; return then }
            return .downloading
        }
    }

    func startDownload(of url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return canStart
    }

    var startedURLs: [URL] { lock.withLock { started } }
}

@Suite struct CloudDownloadTests {
    private let a = URL(fileURLWithPath: "/tmp/a.mov"), b = URL(fileURLWithPath: "/tmp/b.mov")

    @Test func localFilesAreNotTouched() async {
        let cloud = FakeCloud([:])
        #expect(await CloudDownloads.fetch([a, b], probe: cloud, poll: .milliseconds(1)) == .ready)
        #expect(cloud.startedURLs.isEmpty)
    }

    @Test func waitsForAPlaceholderAndCountsHonestly() async {
        let cloud = FakeCloud([a: .placeholder], pollsUntilDone: 3)
        let seen = Pairs()
        let result = await CloudDownloads.fetch([a, b], probe: cloud, poll: .milliseconds(1)) { waiting, total in seen.add(waiting, total) }
        #expect(result == .ready)
        #expect(cloud.startedURLs == [a], "only what's missing")
        #expect(seen.values.allSatisfy { $0 == (1, 1) })
        #expect(!seen.values.isEmpty)
    }

    @Test func aFailedDownloadStopsWithItsReason() async {
        let cloud = FakeCloud([a: .placeholder], pollsUntilDone: 1, then: .failed("The Internet connection appears to be offline."))
        let result = await CloudDownloads.fetch([a], probe: cloud, poll: .milliseconds(1))
        guard case .failed(let url, let message) = result else { Issue.record("expected failure"); return }
        #expect(url == a)
        #expect(message.contains("a.mov") && message.contains("offline"))
    }

    /// Offline, macOS may never start: it mustn't sit on "Downloading…" forever.
    @Test func aDownloadThatNeverStartsGivesUp() async {
        let cloud = StuckCloud()
        let result = await CloudDownloads.fetch([a], probe: cloud, poll: .milliseconds(1), stallLimit: .milliseconds(20))
        guard case .failed(_, let message) = result else { Issue.record("expected failure"); return }
        #expect(message.contains("internet"))
    }

    /// A big file taking ages is fine, as long as it's really moving.
    @Test func aDownloadThatIsRunningIsNotTimedOut() async {
        let cloud = FakeCloud([a: .placeholder], pollsUntilDone: 40)
        #expect(await CloudDownloads.fetch([a], probe: cloud, poll: .milliseconds(2), stallLimit: .milliseconds(10)) == .ready)
    }

    @Test func aProviderThatCantBeAskedIsLeftForTheReadToFetch() async {
        let cloud = FakeCloud([a: .placeholder])
        cloud.canStart = false
        #expect(await CloudDownloads.fetch([a], probe: cloud, poll: .milliseconds(1)) == .ready)
    }

    @Test func cancelStopsTheWait() async {
        let task = Task { await CloudDownloads.fetch([a], probe: StuckCloud(), poll: .milliseconds(5), stallLimit: .seconds(60)) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    /// The real probe on a real, ordinary file: not a placeholder, and asking cost nothing.
    @Test func theSystemProbeSeesAnOrdinaryFileAsLocal() throws {
        let f = try file("plain.txt", in: try tempDir())
        #expect(SystemCloudProbe().state(of: f.url) == .local)
        #expect(SystemCloudProbe().state(of: URL(fileURLWithPath: "/no/such/file")) == .local, "a missing file is the worker's to report")
    }

    @Test func namesICloudOnlyWhenItIsICloud() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(CloudDownloads.isInICloudDrive(URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/a.mov"), home: home))
        #expect(!CloudDownloads.isInICloudDrive(URL(fileURLWithPath: "/Users/x/Library/CloudStorage/Dropbox/a.mov"), home: home))
    }
}

private struct StuckCloud: CloudFileProbing {
    func state(of url: URL) -> CloudFileState { .placeholder }
    func startDownload(of url: URL) -> Bool { true }
}

private final class Pairs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int, Int)] = []
    func add(_ a: Int, _ b: Int) { lock.withLock { stored.append((a, b)) } }
    var values: [(Int, Int)] { lock.withLock { stored } }
}

// MARK: - Summon on a slow disk, many files

@Suite struct SummonSpeedTests {
    /// The bug: up to 50 disk checks on the main thread while the user is mid-drag. On a share that's gone, a hang.
    @Test func aStuckDiskCanNotFreezeTheDrag() {
        let urls = [URL(fileURLWithPath: "/Volumes/gone/a.png"), URL(fileURLWithPath: "/Volumes/gone/Folder/"), URL(fileURLWithPath: "/Volumes/gone/noext")]
        let started = Date()
        // Its own gate: the check it leaves stuck for 5 s mustn't hold up the other tests.
        let result = InputFile.resolveWithin(0.05, urls, gate: ResolveGate(label: "test.stuck")) { _, _ in
            Thread.sleep(forTimeInterval: 5)
            return []
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(result.map(\.type) == [.png, .folder], "known from the names alone; the unknown one waits for the real check")
    }

    @Test func aHealthyDiskStillGivesRealTypes() throws {
        let dir = try tempDir()
        let f = try file("a.png", in: dir)
        // No extension and no trailing slash: only the disk knows it's a folder.
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = URL(fileURLWithPath: folder.path)
        #expect(!plain.hasDirectoryPath || plain.pathExtension.isEmpty)
        let result = InputFile.resolveWithin(2, [f.url, plain])
        #expect(result.map(\.type) == [.png, .folder])
    }

    @Test func namesWorkWithoutTouchingTheDisk() {
        #expect(InputFile(nameOf: URL(fileURLWithPath: "/none/PHOTO.JPG"))?.type == .jpeg, "any case")
        #expect(InputFile(nameOf: URL(fileURLWithPath: "/none/f/", isDirectory: true))?.type == .folder)
        #expect(InputFile(nameOf: URL(fileURLWithPath: "/none/noext")) == nil)
    }

    /// Select All in a big folder, then drag. The answer must take a blink, not a beat.
    @Test func manyFilesDoNotSlowTheChoice() {
        let action = { (id: ActionID, types: [UTType]) in
            ConversionAction(id: id, title: "\(id)", symbolName: "doc", category: .image, inputTypes: types, converter: ClosureConverter { _ in [] })
        }
        let actions = (0..<60).map { action(ActionID(rawValue: "t.\($0)"), [.jpeg, .png, .heic, .image]) }
        let registry = ActionRegistry(actions: actions, usage: MemoryUsageStore())
        let many = (0..<20_000).map { InputFile(url: URL(fileURLWithPath: "/tmp/\($0).jpg"), type: .jpeg) }
        let started = Date()
        let fitting = registry.actions(for: many)
        #expect(fitting.count == 12)
        #expect(Date().timeIntervalSince(started) < 0.5, "took \(Date().timeIntervalSince(started)) s")
    }

    @Test func acceptsStillChecksEveryTypeAndTheCount() {
        let merge = ConversionAction(id: "t.merge", title: "Merge", symbolName: "doc", category: .pdf, inputTypes: [.pdf],
                                     cardinality: .combined(min: 2), converter: ClosureConverter { _ in [] })
        let pdf = InputFile(url: URL(fileURLWithPath: "/a.pdf"), type: .pdf), png = InputFile(url: URL(fileURLWithPath: "/a.png"), type: .png)
        #expect(!merge.accepts([pdf]))
        #expect(merge.accepts([pdf, pdf]))
        #expect(!merge.accepts([pdf, png]))
        #expect(!merge.accepts([]))
    }
}

// MARK: - Promised files

@Suite struct PromiseInboxTests {
    @Test func aDropGetsItsOwnFolderAndIsRemovedAfter() throws {
        let inbox = PromiseInbox(root: try tempDir().appendingPathComponent("inbox"))
        let drop = try inbox.makeDropFolder()
        let f = try file("IMG_1.heic", in: drop)
        #expect(inbox.contains(f.url))
        inbox.remove(dropsHolding: [f.url])
        #expect(!FileManager.default.fileExists(atPath: drop.path), "nothing left behind")
    }

    /// $TMPDIR is "/var/folders/..." but real paths are "/private/var/folders/...". Both must match, with no disk access.
    @Test func recognisesBothSpellingsOfTheTempFolder() {
        let inbox = PromiseInbox(root: URL(fileURLWithPath: "/var/folders/ab/T/Frenzy Promised Files"))
        #expect(inbox.contains(URL(fileURLWithPath: "/var/folders/ab/T/Frenzy Promised Files/X/a.jpg")))
        #expect(inbox.contains(URL(fileURLWithPath: "/private/var/folders/ab/T/Frenzy Promised Files/X/a.jpg")))
        #expect(!inbox.contains(URL(fileURLWithPath: "/var/folders/ab/T/Frenzy Promised Files Extra/a.jpg")))
        #expect(!inbox.contains(URL(fileURLWithPath: "/var/folders/ab/T/Frenzy Promised Files")), "the root itself is no drop")
        let private_ = PromiseInbox(root: URL(fileURLWithPath: "/private/var/folders/ab/T/In"))
        #expect(private_.contains(URL(fileURLWithPath: "/var/folders/ab/T/In/X/a.jpg")))
    }

    /// The one rule that must not break: this deletes folders. It may only ever delete its own.
    @Test func nothingOutsideTheInboxCanBeRemoved() throws {
        let outside = try tempDir()
        let mine = try file("mine.txt", in: outside)
        let inbox = PromiseInbox(root: try tempDir())
        #expect(!inbox.contains(mine.url))
        inbox.remove(dropsHolding: [mine.url, outside])
        inbox.remove(dropFolder: outside)
        #expect(FileManager.default.fileExists(atPath: mine.url.path))
        // Inside the inbox but not a drop folder: left alone too.
        let keep = inbox.root.appendingPathComponent("not-a-drop")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        inbox.remove(dropFolder: keep)
        inbox.removeAll()
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func aCrashesLeftoversGoAtTheNextLaunchButNotLiveOnes() throws {
        let inbox = PromiseInbox(root: try tempDir().appendingPathComponent("inbox"))
        let old = try inbox.makeDropFolder(), fresh = try inbox.makeDropFolder()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        inbox.sweep()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        inbox.removeAll()
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func imageBytesBecomeAFileWithTheRightEnding() throws {
        let inbox = PromiseInbox(root: try tempDir())
        let url = try inbox.save(imageData: Data([1, 2, 3]), typeIdentifier: "public.jpeg")
        #expect(inbox.contains(url))
        #expect(url.lastPathComponent == "Dragged image.jpeg")
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]), "written as it came, never parsed")
    }
}

@Suite struct PromisedChoicesTests {
    private func registry() -> ActionRegistry {
        func action(_ id: ActionID, _ types: [UTType], _ cardinality: InputCardinality = .each) -> ConversionAction {
            ConversionAction(id: id, title: "\(id)", symbolName: "doc", category: .image, inputTypes: types, cardinality: cardinality,
                             converter: ClosureConverter { _ in [] })
        }
        return ActionRegistry(actions: [action("image.to-jpg", [.image]), action("pdf.compress", [.pdf]),
                                        action("pdf.merge", [.pdf], .combined(min: 2)), action("archive.zip", [.item], .combined(min: 1))],
                              usage: MemoryUsageStore())
    }

    @Test func aPromisedPhotoGetsImageChoices() {
        let ids = PromisedChoices.actions(forTypes: ["public.heic"], registry: registry()).map(\.id)
        #expect(ids.contains("image.to-jpg"))
    }

    @Test func severalPromisedFilesReachCombinedActions() {
        let ids = PromisedChoices.actions(forTypes: ["com.adobe.pdf", "com.adobe.pdf"], registry: registry()).map(\.id)
        #expect(ids.contains("pdf.merge"))
    }

    /// Zip fits anything, so a Mail message or an unknown type would get a ring with nothing useful on it, on every pause.
    @Test func zipAloneIsNoReasonToOpenARing() {
        #expect(PromisedChoices.actions(forTypes: ["com.apple.mail.email"], registry: registry()).isEmpty)
        #expect(PromisedChoices.actions(forTypes: ["public.data"], registry: registry()).isEmpty)
        #expect(PromisedChoices.actions(forTypes: ["dyn.abc123"], registry: registry()).isEmpty)
        #expect(PromisedChoices.actions(forTypes: [], registry: registry()).isEmpty)
    }

    @Test func aMixWithAnUnknownOfferNothingRatherThanGuess() {
        #expect(PromisedChoices.actions(forTypes: ["public.jpeg", "public.data"], registry: registry()).isEmpty)
    }

    @Test func subjectsReadNaturally() {
        #expect(PromisedChoices.subject(forTypes: ["public.jpeg"]) == "1 image")
        #expect(PromisedChoices.subject(forTypes: ["public.jpeg", "public.heic"]) == "2 images")
        #expect(PromisedChoices.subject(forTypes: ["com.apple.quicktime-movie"]) == "1 video")
        #expect(PromisedChoices.subject(forTypes: ["public.jpeg", "com.adobe.pdf"]) == "2 files")
    }

    /// Live Photos promise one thing and deliver a picture and a movie.
    @Test func whatArrivedIsMatchedAgainstTheChoice() {
        let reg = registry()
        let jpg = reg.action("image.to-jpg")!
        let heic = InputFile(url: URL(fileURLWithPath: "/t/a.heic"), type: .heic)
        let mov = InputFile(url: URL(fileURLWithPath: "/t/a.mov"), type: .quickTimeMovie)
        let fit = PromisedChoices.fitting(jpg, inputs: [heic, mov])
        #expect(fit.kept == [heic] && fit.leftOut == 1)
        let none = PromisedChoices.fitting(jpg, inputs: [mov])
        #expect(none.kept.isEmpty && none.leftOut == 1)
        let all = PromisedChoices.fitting(jpg, inputs: [heic])
        #expect(all.kept == [heic] && all.leftOut == 0)
    }
}

@Suite struct FailureTextTests {
    @Test func aBlockedFolderPointsAtTheSetting() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop/a.jpg")
        #expect(FailureText.explain("Couldn't read a.jpg.", input: desktop).contains("Privacy & Security"))
        #expect(FailureText.explain("Couldn't read a.jpg.", input: URL(fileURLWithPath: "/tmp/a.jpg")) == "Couldn't read a.jpg.")
        #expect(FailureText.explain("Nope.", input: desktop) == "Nope.")
    }

    @Test func aPartialFailureSaysWhichFileAndWhy() throws {
        let url = URL(fileURLWithPath: "/tmp/bad.jpg")
        let one = try #require(FailureText.partialFailure([.init(input: url, message: "It's broken.")]))
        #expect(one.title == "1 file couldn't be converted")
        #expect(one.message == "bad.jpg: It's broken.")
        let named = try #require(FailureText.partialFailure([.init(input: url, message: "Couldn't read bad.jpg.")]))
        #expect(named.message == "Couldn't read bad.jpg.", "no repeat of the name")
        let two = try #require(FailureText.partialFailure([.init(input: url, message: "x"), .init(input: nil, message: "y")]))
        #expect(two.title == "2 files couldn't be converted")
        #expect(FailureText.partialFailure([]) == nil)
    }

    @Test func theFallbackNoticeNamesBothFolders() {
        let notice = FailureText.redirectNotice(fallbackName: "Downloads", blocked: ["Installer"], inputCount: 1)
        #expect(notice.title == "Saved in Downloads")
        #expect(notice.message.contains("\"Installer\"") && notice.message.contains("The new file is in Downloads"))
        #expect(FailureText.redirectNotice(fallbackName: "Downloads", blocked: ["a", "b"], inputCount: 2).message.contains("the original folders"))
    }

    @Test func noneOfItUsesEmDashes() {
        let all = [WorkerFailureText.crash, WorkerFailureText.memory, WorkerFailureText.replaced, WorkerFailureText.lost,
                   FailureText.nowhereToSave(fallbackName: "Downloads"), ConversionError.folderNotWritable(URL(fileURLWithPath: "/a")).errorDescription ?? ""]
        #expect(all.allSatisfy { !$0.contains("—") })
    }
}

@Suite struct WakeRetryTests {
    private let failed = ConversionOutcome(actionID: "t", outputs: [], failures: [.init(input: nil, message: "The operation stopped.")], duration: .zero)

    @Test func retriesOnlyWhatSleepCouldHaveBroken() {
        #expect(WakeRetry.shouldRetry(failed, cancelled: false, sleptDuringJob: true))
        #expect(!WakeRetry.shouldRetry(failed, cancelled: false, sleptDuringJob: false), "no sleep, no excuse")
        #expect(!WakeRetry.shouldRetry(failed, cancelled: true, sleptDuringJob: true))
        let done = ConversionOutcome(actionID: "t", outputs: [URL(fileURLWithPath: "/a")], failures: [], duration: .zero)
        #expect(!WakeRetry.shouldRetry(done, cancelled: false, sleptDuringJob: true), "it worked")
        let userCancel = ConversionOutcome(actionID: "t", outputs: [], failures: [.init(input: nil, message: "Cancelled.")], duration: .zero)
        #expect(!WakeRetry.shouldRetry(userCancel, cancelled: false, sleptDuringJob: true))
    }
}
