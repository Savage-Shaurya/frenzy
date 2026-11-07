import Foundation
import Testing
import HaloCore
@testable import HaloWorkerKit

@Suite struct MemoryWatchdogTests {
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The app can only tell a memory death from a crash through this note, so it must exist before the process ends.
    @Test func leavesItsNoteBeforeEnding() throws {
        let staging = try root()
        var markerExistedAtExit = false
        var exits = 0
        MemoryWatchdog.check(footprint: 10, limit: 5, stagingRoot: staging) {
            exits += 1
            markerExistedAtExit = FileManager.default.fileExists(atPath: WorkerExitNote.memoryMarker(inStagingRoot: staging).path)
        }
        #expect(exits == 1)
        #expect(markerExistedAtExit)
        #expect(WorkerExitNote.memoryLimitHit(since: Date(), stagingRoot: staging))
    }

    @Test func underTheLimitNothingHappens() throws {
        let staging = try root()
        var exited = false
        MemoryWatchdog.check(footprint: 5, limit: 5, stagingRoot: staging) { exited = true }
        MemoryWatchdog.check(footprint: nil, limit: 5, stagingRoot: staging) { exited = true }
        #expect(!exited)
        #expect(!FileManager.default.fileExists(atPath: WorkerExitNote.memoryMarker(inStagingRoot: staging).path))
    }

    /// The worker sweeps its staging folder when it starts; the note must survive that, or the app reads nothing.
    @Test func aRestartingWorkerKeepsTheNote() async throws {
        let staging = try root()
        WorkerExitNote.writeMemoryMarker(inStagingRoot: staging)
        let registry = ActionRegistry(actions: [], usage: MemoryUsageStore())
        _ = WorkerEngine(registry: registry, stagingRoot: staging)
        #expect(FileManager.default.fileExists(atPath: WorkerExitNote.memoryMarker(inStagingRoot: staging).path))
    }

    @Test func theNoteIsWrittenInsideTheFolderTheAppReads() {
        // The app reads <container>/tmp/HaloStaging; the worker writes <its temp dir>/HaloStaging.
        #expect(WorkerEngine.defaultStagingRoot.lastPathComponent == HaloWorkerService.stagingFolderName)
    }
}
