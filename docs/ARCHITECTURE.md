# Halo architecture

Halo is a free, offline macOS menu-bar app: start dragging any file, hold the trigger key (default Option), a ring of
conversions blooms at the cursor, drop on one, and the converted file appears next to the original.

## Modules (SwiftPM, Swift 6 language mode, macOS 14+)
| Target | Owns | May import |
|---|---|---|
| `HaloCore` | `ConversionAction`, `Converter`, `ConversionJob`, `OutputTarget` (atomic, never-overwrite outputs; direct or staged), `ActionRegistry` (+ usage ranking), `ConversionRunner` (batch, cancellation, cleanup), `ConcurrencyLimiter`, `ConversionBackend` + `InProcessBackend`, `StagedPlacement`, the worker wire format and `@objc` protocols (`WorkerProtocol.swift`), `TempSweeper` + `UsedFolders`, `TriggerKey` | Foundation, UniformTypeIdentifiers |
| `HaloConverters` | Every conversion, one file per family: `ImageActions`, `PDFActions`, `TextActions` (OCR), `VideoActions`, `AudioActions`, `DocumentActions`, `ArchiveActions` (Zip / Unzip on Halo's own `ZipArchive.swift`: classic ZIP, raw DEFLATE via Compression, no Zip64). `DefaultActions.all()` concatenates them | HaloCore + Apple frameworks only |
| `HaloWorkerKit` (`Sources/HaloWorker/Kit`) | `WorkerEngine` (runs jobs staged, cancel, discard, staging sweep), `WorkerListenerDelegate` (XPC), `SandboxProbe` (self-test), `MemoryWatchdog` | HaloCore, Foundation |
| `HaloWorker` (`Sources/HaloWorker/Main`) | The XPC service executable: registry + engine + listener | HaloCore, HaloConverters, HaloWorkerKit |
| `HaloUI` | `RingView`, `RingModel`, `RingGeometry`, `RingMetrics`, `ToastCenter` (per-job cards, `JobToastPresenting`), `HaloSettings`, `SettingsView`, `OnboardingView`, `HomeView` + `HomeModel` (main window) | HaloCore, SwiftUI, AppKit, QuickLookThumbnailing |
| `HaloDrag` | `DragTriggerMonitor` (system-wide drag + trigger key), `RingOverlayController` (floating non-activating panel hosting `RingView`, accepts drops, hit-tests with `RingGeometry`) | HaloCore, HaloUI, AppKit |
| `HaloApp` | `main.swift`, `AppDelegate`, `AppController` (jobs), `XPCConversionBackend`, `CommandLineTools` (diagnostics), menu-bar item, launch at login | everything except HaloWorkerKit |

## Sandboxed worker (process isolation)

```
Halo.app (unsandboxed, no network code, never parses file contents)
  AppController.startJob ──► XPCConversionBackend.run(actionID, inputs)
        │   NSXPCConnection(serviceName: "com.snappycrew.halo.worker")
        │   run(WorkerRequest JSON) ─────────────────────────────►  HaloWorker (App Sandbox, no network)
        │   ◄─ progress(jobID, fraction)  (reverse proxy, ordered)    WorkerEngine.run
        │   cancel(jobID) ───────────────────────────────────────►    ConversionRunner (staged mode)
        │   ◄─ reply(WorkerReply JSON: staged outputs + failures)     outputs in <container>/tmp/HaloStaging/<jobID>/
        ▼
  StagedPlacement.place: validate, copy into <dest>/.halo-<uuid>[.ext], chmod 644/755,
  exclusive atomic rename to a free name ("photo.jpg", "photo 2.jpg")  ──► discardStaging(jobID)
```

- Packaging: `Halo.app/Contents/XPCServices/com.snappycrew.halo.worker.xpc` (`Resources/Worker-Info.plist`:
  `CFBundlePackageType XPC!`, `XPCService` = `ServiceType Application`, `RunLoopType NSRunLoop` so WebKit/TextKit
  HTML import has a main run loop). Signed first, ad-hoc or Developer ID, hardened runtime, with
  `Resources/HaloWorker.entitlements`: `com.apple.security.app-sandbox`, read-only exception for `/`, nothing else.
  Then the app is signed around it.
- The worker accepts only connections whose code signature matches `identifier "com.snappycrew.halo"`.
- **Staged mode** (`ConversionJob(stagingRoot:)`): every `makeOutput*` target gets its temp file under the staging
  root; `commit()` moves it to a staged name there and records the intended `directory`, `baseName`, `suffix`,
  `pathExtension` and `isFolder` (`StagedOutput`). Targets created inside a staged folder (pages of a Split) are
  committed in place and travel with the folder. The worker never writes next to the original (it can't: sandbox).
- **Placement trusts nothing from the worker:** the staged path must be inside the worker container's
  `tmp/HaloStaging/<jobID>`, the destination must be the folder of a dropped file, names may not contain `/`, the
  extension must be in `StagedPlacement.allowedExtensions`, folder outputs may only contain plain files and folders
  (no symlinks), and permissions are normalised so nothing is executable.
- **Crashes:** all jobs share one worker, so a death fails them all at once and nobody can say which file did it.
  `WorkerRecovery` (HaloCore, no XPC, tested with a fake worker) sorts it out: a job alone with one file IS the cause and
  fails at once; anything else runs again, once, alone, a batch one file at a time. What dies alone is the cause, the rest
  finish, and a batch that only ran out of memory in parallel completes. `WorkerGate` keeps a retry alone (new drops wait).
  The next message relaunches the worker (launchd may delay that by several seconds right after a crash).
- **Why it died:** `WorkerDeath`. `MemoryWatchdog` exits the worker if its footprint passes `min(12 GB, max(2 GB, RAM / 2))`,
  and first leaves an empty `tmp/HaloStaging/.memory-limit`; the app reads only that file's date (`WorkerExitNote`), so a
  memory death gets a memory message, not "may be damaged". `AppBundleStamp` notices the app being replaced, moved or
  deleted while running. An invalidated connection only fails jobs on THAT connection, as `connectionLost` (retried).
- **Saving:** `SavePolicy` (HaloCore). `startJob` works out a `Plan` off the main thread before any work, using a real
  write (permission bits lie on shares). Outputs go next to the original, or to Downloads when that folder can't take them
  or must not (`neverSaveIn`: the promised-files inbox, the Trash). `StagedPlacement` falls back the same way at the last
  moment, and reports `ConversionOutcome.redirected`, so a card can say why. With nowhere at all to save, nothing starts.
- **Cancellation:** cancelling the job's Task sends `cancel(jobID)`; the worker cancels the runner task. If no reply
  arrives within 8 s the app invalidates the connection; the worker then cancels that connection's jobs and exits
  if they still haven't stopped 5 s later.
- `InProcessBackend` runs the same code without IPC (`staged: true` reproduces the worker pipeline exactly); tests
  use it, and unbundled `swift run` builds fall back to it (logged). `Halo.app` always uses the worker.
- Diagnostics (run the binary inside the bundle): `--worker-self-test` (sandbox probes), `--worker-crash-test
  <action> FILE` (SIGKILL the worker mid-job, check recovery), `--convert <action> FILE…`.

## App behaviour worth knowing
- **Main window** (`HaloUI.HomeView`, filled by `AppController` through `HomeModel`): drop zone (no trigger key needed)
  with the hero ring (`HeroRing`, an illustration: six petals turned half a petal from the real ring so the long
  titles take the level 12 and 6 o'clock petals; `heroLabelsFitTheirPetals` checks every icon and title against the
  real petal outline with a 4 pt margin), plus "Choose Files…" (⌘O), a balanced grid of the formats that fit (`registry.actions(limit: 12)`, `ChoiceLayout`: up
  to 4 across, no lone last tile, wide tiles for 1 or 2; digit keys 1 to 9 pick a tile, Return picks a lone one; the
  card hugs the grid while choosing), live job rows
  (working with a `JobProgress` ring, Done for 1.2 s while Recent holds back that result, failed with reason + Try
  Again + dismiss, removed 12 s later; Try Again re-runs the same action on the same files through `handleDrop`),
  Recent (last 20, count in the header, stable ids, Quick Look thumbnails, rests on whole 56 pt rows plus a 36 pt peek
  that fades as one ghost in three columns: thumbnail, text, buttons (`RecentsMetrics`; no fade or bottom padding when
  every row fits), Open / Show in Finder on hover or keyboard focus, Return opens, ⌘Return reveals, drag out, context
  menu). A result that turns up while Halo runs (`HomeModel.arrivals`: not in the first list the host sets, dated
  within 10 s) takes its Done row's slot with a soft green wash and the same green check on its thumbnail, held 0.7 s
  then faded over 1.3 s (opacity, so also under Reduce Motion); the thumbnail springs from 0.9 (not under Reduce
  Motion). The row calls `settleArrival` when it shows it, so a reopened window never replays it; unseen ids expire
  after 3 s (`HomeArrival`). Shown at launch unless macOS
  opened Halo as a login item (`keyAELaunchedAsLogInItem` in the launch Apple event), on every reopen (Finder,
  Spotlight, a second launch via `SingleInstance`), from the menu ("Open Halo") and after onboarding. Drops on the window
  work while paused. The window gets an explicit content size (`HomeMetrics.size`): relying on the hosting controller's
  preferred size left it 1 x 0 pt once (found with the screen locked). Logs `Home window shown, frame: …` and
  `Home drop: n dropped, m recognised, k actions` (e2e evidence). AX ids: `halo.home`, `halo.home.dropzone`,
  `halo.home.choose`, `halo.home.cancel`, `halo.home.action.<id>`, `halo.home.job`, `halo.home.recent.<i>`.
- **Onboarding** (`HaloUI.OnboardingView`): Welcome, trigger key, then "Try it once" (`OnboardingTryIt.swift`). Halo
  draws `Halo sample.png` into `~/Library/Application Support/Halo/Try Halo` (never the user's folders). The tile is a
  `FileDragArea` drag source, so the drag starts in Halo's own window and the local event monitor picks it up. A drop on
  the ring runs the normal job; `AppController.convert` reports jobs whose only input is the sample to `OnboardingTry`
  (working / done / failed). Logs `Onboarding try: n outputs`. Reopened from closed, it starts over at Welcome.
- **Thumbnails** come from `QLThumbnailGenerator` (Quick Look renders them out of process), with Finder's icon as the
  fallback. The app itself still never parses file contents. "Show file previews" (`HaloSettings.showPreviews`, default
  on) turns them off everywhere: `FileIcon` reads `\.haloShowsPreviews` (set by `HomeView` and by `ToastView` from
  `ToastModel.showsPreviews`, which `ToastCenter` keeps in sync), and `RingModel.showsThumbnails` (synced by
  `AppController`). Requests are cancelled with their task, so a late thumbnail never lands.
- **Main menu:** never visible (accessory app) but installed so ⌘W, ⌘M, ⌘, ⌘N (Open Halo), ⌘Q and the Edit (incl. Undo/Redo)
  shortcuts work while a Halo window is key.
- **Jobs** are tracked Tasks (`AppController.jobs`). The progress toast has Cancel. Quit and logout use
  `applicationShouldTerminate → .terminateLater`: cancel all jobs, wait (max 10 s) for their cleanup, then reply.
  While any job runs, the app holds `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled])`.
- **Concurrency:** `ConcurrencyLimiter.shared` (capacity `max(2, cores / 2)`) bounds work across every drop in the
  process; video, `pdf.to-images`, `pdf.to-text` and images over 40 MB take 2 slots. Per-drop `maxConcurrent` still
  applies. In the app, the worker is one process for all drops, so the bound is global.
- **Progress** goes worker → `ProgressSink` → `AsyncStream` (newest-value buffer) consumed on the main actor; values
  are clamped to be monotonic and the stream finishes before the result is shown, so no stale update can replace a
  result. `ProgressTracker` reports under its lock, so totals are strictly increasing.
- **Toasts** are per job (`JobToastPresenting`): one card per job, up to 3 stacked; a job's success never gets wiped
  by another job's progress. Reveal selects at most 20 files. The panel can't become key or main, and it's shown with
  `orderFrontRegardless`, so it never takes focus.
- **Menu-bar icon:** 2 s after launch `AppController` classifies the button's real frame with
  `HaloDrag.MenuBarIconVisibility` (visible / behind the notch / off screen / occluded), logs `Status icon: …`, and shows
  a one-time notice if macOS hid it. `menuWillOpen` logs `Menu opened` (e2e evidence; AX reads also trigger
  `menuNeedsUpdate`, so that one proves nothing). `StatusDropView` (hitTest nil, never takes clicks) is the
  drop-on-icon layer; unverified as of iteration 1, so no copy mentions it.
- **Usage** is recorded only when a conversion produced at least one output (the runner no longer records).
- **Outputs:** a folder output ("report pages") counts as one output in outcomes, toasts and Recent Conversions.
  Recent Conversions keeps 20 entries with at most 20 paths each (plus the total count); the menu lists the newest 10.
- **Long names:** `OutputNaming.fileName` shortens the base, on grapheme-cluster boundaries, so the final name fits
  255 UTF-8 bytes including suffix, index and extension.
- **Leftovers:** `UsedFolders` remembers (max 200) folders Halo wrote into; at launch `TempSweeper` lists each once and
  removes only `.halo-<uuid>[.ext][.sb-…]` entries older than 1 hour. The worker sweeps its staging the same way.
  `OutputLedger.discardUncommitted` lists each folder once per job (not once per target) for scratch siblings.
- **Ring v2** (R1, iterations 19 and 25): resting wedges are neutral glass with label-coloured icons and text; the
  hovered wedge fills with its category colour darkened until white text is 4.5:1 or better (`RingPalette.litFill`).
  The centre shows the dragged item: Finder's icon at once, then its Quick Look thumbnail, its size or a folder's
  visible item count (worked out off the main thread); several items fan out up to 3 icons. On a dense ring
  (subtitles hidden) the centre shows the hovered wedge's subtitle. Two choices start at 6 o'clock so the first is on
  the left (`RingGeometry.startOffset`). A Force Touch trackpad ticks on each wedge change. When more actions fit than
  the ring size allows, the last wedge is "More" (`RingItem.moreID`, `halo.more`, never a conversion): a drop on it
  opens the main window with every choice. No drop fits more than 11 actions, so the window's 12 tiles always hold them.
- **Drop moment** (R1a, iteration 28): `.committing` pulses the chosen wedge, collapses it into the centre after
  `RingMotion.collapseDelay` (0.12 s), then the centre disc fills with the same lit colour (white symbol and text) and
  one `DropRipple` leaves it, ending with the dismiss fade (`commitDuration` 0.40 s + `dismissDuration` 0.16 s).
  Reduce Motion: no ripple (`RingView.showsRipple`), 0.15 s crossfades. VoiceOver hears "Converting to <action>"
  ("Opening Halo" for More). Titles on one ring share one size (`RingLayout.sharedTitleSize(for:)`, cached, at most
  2 pt under the layout's size); at the default ring size of 10 every real title keeps full size. Family colours: image
  teal, PDF red, video purple, audio pink, document indigo, text orange, archive green (was brown, which went muddy when
  darkened), More blue.
- **Big selections:** the ring inspects at most 50 files on disk (`InputFile.resolve`), the rest by extension only.
  At drop time, types are resolved off the main thread.
- **Zip / Unzip** (`archive.zip`, `archive.unzip`, iteration 18). Plain folders resolve as `public.folder` (`InputFile(url:)`;
  `resolve` always inspects extension-less items), and Zip takes any item (`.item`, combined, rank 900, so it is last on
  every ring). Zip names like Finder ("name.ext.zip", several = "Archive.zip"), leaves out links, `.DS_Store` and special
  files, and stores already-compressed formats. Unzip makes one folder (a single top folder unpacks as itself) and
  refuses the whole archive on an unsafe path (absolute, `..`, over 1024 bytes or 64 levels), a password, an unknown
  method, Zip64, split archives, overlapping entries, a bad CRC or a size mismatch. Caps: 20,000 items, 10 GB unpacked,
  free space minus 256 MB. Links and `__MACOSX` are skipped. Placement lifts the extension allowlist for files
  inside an Unzip folder only (`StagedPlacement.extractionActions`), re-checks the copy in the destination (the worker
  can't swap in a link), refuses app-like endings in a folder's name (`dangerousExtensions`), and copies the inputs'
  `com.apple.quarantine` onto Zip and Unzip outputs. Placed files stay non-executable, so apps inside a zip won't run
  after Halo unzips them (said on the website).
- **File promises** (Photos, Mail, browsers). The ring opens for promised types: `PromisedChoices` asks the registry using
  placeholder inputs, leaves Zip-only results out (else a Mail message hovering over a mailbox gets a ring), and unknown
  types get no guess. The source app writes into `PromiseInbox` (`$TMPDIR/Frenzy Promised Files/<uuid>`) after the drop;
  `onPromiseDelivery` drives a card with Cancel, with a 5 minute limit, because a source can take a while or never answer.
  What arrives is matched against the choice again (a Live Photo is a picture and a movie). Outputs go to Downloads and
  the card says so. Copies are removed when the job ends, at quit, and at launch if a crash left any. Raw image bytes on
  the pasteboard (key only: rich-text drags carry them too) are written unparsed to the inbox. A bare web link gets one
  notice when the key is pressed: Frenzy never fetches anything. A browser fulfilling its own promise may fetch, in its
  own process. **Not verified with a real drag.** The window and the menu-bar icon still take real files only.
- **Cloud placeholders:** at summon the disk gets `InputFile.resolveWithin` 80 ms, then types come from names, so a slow or
  dead share can't freeze a drag. Before converting, `CloudDownloads.fetch` (dataless check via `st_flags`) asks macOS for
  placeholders and waits, with the wait named on the card. Only top-level items; a folder's contents download as read.
- **Sleep and quit:** `NSWorkspace.didWakeNotification` counts wakes; a job that failed with nothing to show across a sleep
  runs once more (`WakeRetry`). The worker holds its own `beginActivity` so App Nap can't throttle it. Quit from the menu or
  ⌘Q with jobs running asks: Finish, Then Quit / Quit Now / Keep Open. Logout and shutdown skip the question.

## Hard rules
- **Offline only.** No `URLSession`, no network APIs, no analytics, no update checks in V0. Never modify an input
  file. (The only socket/URLSession code is the worker's `SandboxProbe`, which must fail.)
- **Parse untrusted files only in the worker.** The app may read names, types and sizes, never contents. One
  exemption: `QLThumbnailGenerator` thumbnails in the main window and the ring's centre. macOS's own Quick Look
  generators render them out of process, and the app receives only an image.
- **Write outputs only through `job.makeOutput(...)` / `job.makeOutputFolder(...)`** → write `temporaryURL` →
  `commit()`. Never create files or folders next to the input with `FileManager` directly: in the worker that is
  denied by the sandbox and the conversion fails. Scratch files go in `FileManager.default.temporaryDirectory`.
- A new output extension must be added to `StagedPlacement.allowedExtensions`, or the app refuses to save it.
- **Apple frameworks only** in V0 (ImageIO, Core Image, PDFKit, AVFoundation, Vision, AppKit text system). No bundled binaries, no GPL code, no SwiftPM dependencies without sign-off.
- Names never overwrite ("photo 2.jpg"); final renames use `renamex_np(RENAME_EXCL)`.
- ActionIDs are permanent (persisted usage stats): `family.verb-or-format`, e.g. `image.to-jpg`, `pdf.compress`.
- Swift Testing (`import Testing`), not XCTest (no full Xcode here). Tests generate their own fixtures at runtime; no binary fixtures committed.
- Build with your own scratch dir when working in parallel: `swift build --scratch-path .build/<you>`; `swift test --scratch-path .build/<you> --filter <YourTests>`. Never `rm -rf .build` (other agents use it).
- Public contracts in `Sources/HaloUI/RingContract.swift`, `Sources/HaloDrag/DragContract.swift` and HaloCore's
  converter-facing API (`Converter`, `ConversionJob.makeOutput*`, `OutputTarget.temporaryURL/commit()`,
  `ConversionAction`, `ActionRegistry`) are shared: don't change signatures without coordinating; you may add.
- If `swift test` fails with "plugin for module 'TestingMacros' not found" (stale/parallel scratch dirs), add:
  `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
