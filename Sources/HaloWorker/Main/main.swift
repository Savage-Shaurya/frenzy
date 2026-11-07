import Foundation
import HaloCore
import HaloConverters
import HaloWorkerKit

// Halo's conversion worker: an XPC service inside Halo.app, signed with the App Sandbox and no network entitlement.
// Every file Halo converts is parsed here, never in the app, so a parser bug or a decompression bomb can at worst
// crash this process. See docs/ARCHITECTURE.md ("Sandboxed worker").

// Leftovers of a worker that died mid-job: engines still running without it (killed only when launchd adopted them),
// and scratch folders older versions kept in the temporary folder (once 10 minutes old).
EngineOrphans.killOrphansOfThisWorker()
ConverterScratch.sweep()
SandboxProbe.extraProbes = { OrphanProbe.run() }

// Usage counts live in the app; the worker's registry only needs the actions.
let engine = WorkerEngine(registry: DefaultActions.registry(usage: MemoryUsageStore()),
                          stagingRoot: WorkerEngine.defaultStagingRoot)
let delegate = WorkerListenerDelegate(engine: engine)
MemoryWatchdog.start(stagingRoot: WorkerEngine.defaultStagingRoot)

let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume() // Never returns; runs the main run loop (RunLoopType NSRunLoop in Info.plist) for WebKit/TextKit.
