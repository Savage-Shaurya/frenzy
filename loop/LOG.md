# Halo loop log

Newest entries at the bottom. Each iteration appends "## Iteration N" with what changed, evidence, screenshots, next.

## Iteration 0 (setup, 2026-11-01 18:20 IST, supervisor chat)
- Loop created: MISSION.md, BACKLOG.md, run.sh. Founder verdict on v0.1: UI and workability not acceptable.
- B1 repro: Desktop file halo-vanish-test.png -> JPG + To Text, outputs watched for 3 minutes (result below in this entry).
- B1 repro result: JPG and TXT outputs on ~/Desktop still present at t+5/30/60/90 s (no Halo deletion reproduced). Test files removed. Next: B1 code audit + regression test, then B2/B3/B4.

## Iteration 1 (2026-11-01 18:20-18:50 IST, headless loop)
Goal: P0 B1 (vanished result) and B2 (menu-bar icon), "it works, visibly".

**B1 vanished result: closed, not a Halo deletion; one real naming bug fixed.**
- Unified log, 15:58:40-15:59:30: Finder `sendAction` at 15:58:47.54 and 15:58:48.84, then a Finder copy-engine
  file-coordination claim with `Write options: 2` (write-for-moving) at 15:58:48.851 on two URLs. That is a
  user-initiated Finder move (Move to Trash or a drag), inside the 15:58:45-52 vanish window. Halo's last log line
  was 15:58:19 (`text.ocr-image: 1 outputs`). Halo never touched the file.
- The earlier "not in the Trash" evidence was invalid: `ls ~/.Trash` returns "Operation not permitted" from the shell.
- Desktop is not in iCloud (`FXICloudDriveDesktop` 0), and no cleaner apps (Hazel, CleanMyMac) are running.
- Audit of every delete in Sources: the sweeper and the ledger only remove `.halo-<uuid>` names; placement removes
  only its own temp copy and the worker staging. Bug found by the new tests: an input already named
  `.halo-<uuid>.txt` produced an output in scratch shape, which the launch sweeper would delete an hour later.
  Fix: `OutputNaming.fileName` never returns a scratch-shaped name (`Sources/HaloCore/OutputTarget.swift`).
- New tests (subagent, test files only): `Tests/HaloCoreTests/PlacedOutputSurvivalTests.swift` (all cleanup
  paths at max aggression, 2 racing jobs x5 rounds, 8 jobs vs a nonstop sweeper, cancelled jobs, scratch-shaped
  input) and `Tests/HaloWorkerTests/PlacedOutputSurvivalWorkerTests.swift` (run, place, discard, fresh-engine
  sweep). Placed outputs keep their bytes and inode. No 60 s wall-clock wait: `now` is moved 2 h ahead instead.

**B2 menu-bar icon: visibility fixed and measured live; drop-on-icon built but NOT verified.**
- Root cause of `{38, 0}`: it was measured inside `start()`, before layout. Now Halo measures 2 s after launch
  (retries while not laid out) and logs `Status icon: <state>, frame`. Live on the founder's 14" MBP, 4 launches:
  `Status icon: visible, frame: {{1098, 949}, {38, 33}}`. The notch gap is x 663.5-848.5, so the icon sits right of it.
- New `HaloDrag.MenuBarIconVisibility` (pure, 6 tests): visible / notLaidOut / offScreen / behindNotch / occluded.
  If hidden, Halo shows a one-time notice per launch saying why, and that Option-drag still works.
- `autosaveName` set, so macOS keeps the icon where the user put it.
- Drop on icon: `Sources/HaloApp/StatusDropView.swift` (a layer that never takes clicks) plus a menu of
  conversions (`showDropMenu`). **The live drag test failed:** Halo logged no "Icon drag entered". A standalone
  probe (scratchpad) showed that synthetic HID clicks open no status item's menu on this macOS, even with no drop
  layer. So the e2e icon rows are EXPERIMENTAL (non-gating). No copy mentions dropping on the icon.

**Verification**
- `swift build` clean. `swift test`: 228 tests, 0 failures, 0 known issues (5 targets: 9 + 16 + 56 + 38 + 109).
- `scripts/build-app.sh` OK (final SHA-256 ba406e1a...c774bb).
- `scripts/e2e.sh --no-screenshot` at idle 131 s: all 16 existing checks PASS (PNG->JPG, PDF->Images, Compress,
  TXT->PDF, Option release, .zip no ring, batch, originals byte-identical, no temp files, worker sandbox and
  staging, no crashes). The 2 new icon rows failed and are now non-gating (see above). e2e was not re-run after the
  demotion edit (`bash -n` only), because the founder became active.
- **Rule slip:** one diagnostic click plus an Escape was posted on Halo's menu-bar icon at idle 34 s (below 120 s).
  It was a single event, not repeated, and the idle check now gates every live command I run.
- No UI views changed, so no design-loop renders this iteration (no `shots/1`).

**Next:** B3 (real Halo window with a drop zone, the reliable "works without Option" path) together with B4
(result card). Retry drop-on-icon with a real trackpad drag or another approach. Find a click method that works
(AXPress on the status item, checked by `menuWillOpen` in the log).
- End of iteration: fresh `dist/Halo.app` relaunched at idle 133 s (pid 74712, 18:42:18). Log: `Status icon: visible,
  frame: {{1098, 949}, {38, 33}}`. Note: e2e resets the `com.snappycrew.halo` defaults domain (existing behaviour),
  so the founder's Recent Conversions and settings are back to defaults, with onboarding marked done.

## Iteration 2 (2026-11-01 18:45-19:20 IST, headless loop)
Goal: P0 B3, a real Halo main window, so Halo is "obvious from the first second" and works without the Option gesture.

**What changed**
- New `Sources/HaloUI/HomeView.swift` (`HomeView`, `HomeModel`, `HomeRecent`, `HomeJob`, `HomeChoice`, `HeroRing`,
  `FileIcon`, `MenuBarGlyph`):
  - Header: the real app icon, "Lives in your menu bar" with the real menu-bar glyph, and a Settings button.
  - Hero drop zone: no trigger key needed. It has a full-colour ring whose highlight walks around every 1.2 s and
    blooms on drag-over (still under Reduce Motion), "Drop a file here", the ⌥ hint, and **Choose Files…** (⌘O, a
    sheet).
  - After a drop: the file plus a 4-column grid of the formats the registry offers (max 12), with Cancel / Esc.
  - Job rows at the top of Recent: progress, then a green "Done" for 1.2 s, or a failure with its reason, a dismiss
    button, VoiceOver announcements and a haptic.
  - Recent: 20 entries (was 5) with stable ids, Quick Look thumbnails, "action · time · in Folder", Open / Show in
    Finder buttons, keyboard focus, Return to open, double-click, drag out, a context menu and a fade above the footer.
  - Footer: "Offline. Your files never leave this Mac."
- `AppController`:
  - `showHome` opens the window at launch (skipped when macOS starts Halo as a login item), on reopen, from the
    "Open Halo" menu item and after onboarding.
  - `homeDropped` shows the formats for recognised files only, or a plain notice ("Halo can't convert folders yet.
    Drop the files inside instead.").
  - Smaller pieces: `chooseFilesForHome`, `updateHomeJob`, `announce`, and `reopen`, which shows onboarding while it
    is unfinished.
- `Windows.swift`: chromeless window option, explicit content size, centred once, and a hidden `MainMenu` (⌘W ⌘M ⌘,
  ⌘N ⌘Q, Undo/Redo/Cut/Copy/Paste/Select All).
- `AppDelegate`: reads the login-item flag in `applicationWillFinishLaunching`. Reopen and second launch go to the
  main window.
- `OnboardingView.MiniRingDemo`: scale, icons-only, still under Reduce Motion; the demo no longer offers HEIC for a
  HEIC.
- `Package.swift`: HaloUITests also depends on HaloConverters, so the renders use the real registry. This is an
  internal target, not a new package.
- `scripts/e2e.sh` + `scripts/e2e/main.swift` (subagent, disjoint files):
  - New gating home scenarios: shown at launch, closes, reopen, cancel, drop PNG→JPG (fails on op=0 or a missing
    `Home drop:` log line), and recents.
  - Backs up and restores the `com.snappycrew.halo` defaults on every exit path, so the founder's data is no longer
    wiped.
  - `--build-only` flag; refuses a locked screen (exit 4).

**Design loop**: 3 critique rounds by `ui-craft:design-reviewer` on offscreen renders (NSHostingView, light and dark,
5 states).
- R1: 4-6 on every line.
- R2: 6-8.
- R3: Clarity 8, Hierarchy 8, Motion 8, Feedback 8, Honesty 8, Craft 7, Typography 7, Delight 7, Accessibility 7,
  Material 6.
- R3's fixes were applied after scoring. The supervisor's 19:13 notes then led to the HeroRing, the app-icon header
  and real-registry renders. Neither has been re-scored, so B3 stays `[~]`.
- Shots: `loop/shots/2/home-{1-first-launch,2-notice,3-choose,4-recents,5-working}-{light,dark}.png`. The renders show
  Finder icons where the live app shows Quick Look thumbnails, because the thumbnails don't arrive offscreen.

**Code review** (`ecc:swift-reviewer`): 10 findings, 9 fixed.
- Fixed: stable Recent ids, the Dismiss action only on failed rows, no duplicate result while "Done" shows, only
  recognised files in the choice, the open panel as a sheet, the login flag read early, no re-centring on reopen,
  Undo/Redo added, and failures announced.
- Thumbnail rule: the exemption for QLThumbnailGenerator is now written into ARCHITECTURE's hard rules.
- Kept: the "saved next to the original" copy, which is true for every registry action because promise drops are
  refused.

**Verification**
- `swift build` clean.
- `swift test`: **232 tests, 0 failures** (9 + 20 + 56 + 38 + 109; new: 4 HomeRenderTests including
  `pngChoicesAreImageConversionsOnly`). One earlier full run had `cleanIsLinear("b-then-i")` over its 0.5 s wall-clock
  budget under load. It passed 3/3 alone and in the next full run, and is logged as T1.
- `scripts/build-app.sh` OK, final SHA-256 4f936581...a50b4. `scripts/e2e.sh --build-only` OK.
- **Live e2e: NOT passed.** The first run (idle 1291 s) failed 14 checks, including ring scenarios that passed in
  iteration 1. Root cause: **the screen was locked** (`CGSSessionScreenIsLocked = 1`, frontmost app
  `com.apple.loginwindow`), so no synthetic drag could start. One real bug surfaced along the way: the main window was
  created at **1 x 0 pt** because the hosting controller's preferred size never applied. It is now created at an
  explicit 600 x 720, and the live log shows `Home window shown, frame: {{456, 172}, {600, 720}}`. That bug was seen
  only while locked. e2e now refuses a locked screen (verified: "SKIPPED: the screen is locked", exit 4), and MISSION
  says so. The defaults backup was restored after the failed run.
- End: fresh `dist/Halo.app` relaunched at idle 2248 s (pid 45876, 19:17:35). Log: home window 600 x 720, status icon
  visible `{{1098, 949}, {38, 33}}`.
- Tools used: ui-craft design-reviewer (x3), ecc:swift-reviewer, a general-purpose subagent for e2e,
  superpowers:systematic-debugging (the lock diagnosis), AX/CGWindow probes in the scratchpad (deleted).

**Next (iteration 3):**
1. On an unlocked idle Mac: `scripts/e2e.sh --no-screenshot` (all home scenarios gating), then fix what fails.
2. Real window screenshots.
3. Re-score with design-reviewer + ui-craft against CleanShot X, Raycast and Dropover, and iterate to 8/10.
4. Then mark B3 done, add one honest site line, and move on to B4 (result card / toast).

## Iteration 9

**Date:** 2026-11-01, 20:31 to 20:47. **Goal:** finish and verify B4 (result card + honest progress).

**Why iterations 3 to 8 failed:** every run exited rc=1 on "You've hit your session limit" (Claude usage), not on
Halo. Iteration 3 ran 11 min and left unlogged work. Diffing `snapshots/iter-3-before.tgz` against
`iter-9-before.tgz` found it: new `HaloUI/ResultFacts.swift` (`ConversionResult`, `JobStage`), a reworked
`ToastCenter` (progress / result / failure / notice cards), wiring in `AppController.convert/finish`, new
`ResultCardTests`, and the T1 scaling test. Kept and finished, not rewritten.

**Changed this iteration**
- Build fix: removed the stale `toastSummary` test (its helper became `ConversionResult.name`, already tested).
- Bugs from an `ecc:swift-reviewer` pass on iteration 3's code, all fixed:
  - HIGH: a new result could evict itself from a full stack. The victim search now skips index 0, and evicted
    running jobs stay off screen until their result or failure.
  - HIGH: `isHovering` could stay true after clicking Open or Dismiss under the pointer, so no card would ever
    auto-hide again. It is now reset when the stack empties.
  - MED: Cancel stayed live while sizes were measured after the files were saved. A "Finishing…" step without
    Cancel now shows instead.
  - LOW: reveal and drag now check files lazily (at most 20 checks, not the whole batch).
- Design (3 rounds, `ui-craft:design-reviewer`):
  - The first-run OCR warning was cut off ("about a minu…"). It now gets 3 lines.
  - The notice "i" was red (system accent), so it read as an error. It is now grey palette.
  - Detail text is `primary` at 0.62, about 4.5:1, up from about 3:1.
  - Cards spring in and out (dissolve under Reduce Motion), and the panel height animates over 0.25 s.
  - The Reduce Motion progress bar breathes instead of freezing.
  - Spacing is 12/4. Open and Show in Finder got icons, and the close button is always visible (24 pt, 0.85).
  - The percent label keeps its width before progress starts, so the bar never jumps.
  - Partial batches show only the output size, with "N couldn't be converted" on its own orange line.
  - The check badge bounces once when a result lands.
- Scores by round:

  | Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 | 8 | 6 | 6 | 5 | 7 | 7 | 7 | 5 | 4 | 6 |
  | 2 | 8 | 7 | 7 | 6 | 7 | 7 | 8 | 5 | 6 | 8 |
  | 3 | 8 | 7 | 7 | 7 | 7 | 7 | 8 | 6 | 7 | 8 |

  Round 3's three fixes are applied but not re-scored. Below 8 on 6 lines, so B4 stays `[~]`.
- Screenshots: `loop/shots/9/card-{1-first-ocr,2-progress,3-result,4-batch,5-failure-notice,6-stack}-{light,dark}.png`
  (plus the home-* renders). These are offscreen renders, so they show Finder icons, not Quick Look thumbnails.

**Verification**
- `swift build` clean (`--scratch-path .build/it9`).
- `swift test`: **246 tests, 0 failures** (9 + 34 + 56 + 38 + 109). Green in 5 consecutive full runs this iteration,
  including T1's `cleanIsLinear`. New tests: `aResultNeverEvictsItselfAndEvictedJobsDontThrash`,
  `hoverResetsWhenTheLastCardGoes`, `partialFailuresDontClaimASaving` (plus iteration 3's 10 ResultCardTests).
- `scripts/build-app.sh` OK, final SHA-256 cd17892c...c522bea.
- **Live e2e: NOT run.** Idle was 7573 s, but `CGSSessionScreenIsLocked` was true, so e2e.sh would refuse (exit 4)
  and synthetic drags can't work.
- End: fresh `dist/Halo.app` relaunched at 20:46:21 (pid 93175). Log: `Home window shown, frame: {{456, 172}, {600, 720}}`,
  `Status icon: visible, frame: {{1098, 949}, {38, 33}}`.
- Website: it has no result-card claims and is left unchanged.
- Tools used: ecc:swift-reviewer, ui-craft:design-reviewer (x3), snapshot diffing, Swift Testing renders.

**Next**
1. On an unlocked idle Mac: `scripts/e2e.sh --no-screenshot`, then watch one real drop: card position, hover hold,
   drag into Finder, Quick Look thumbnail. Take real screenshots of the card and the home window.
2. Re-score B3 and B4 against CleanShot X / Dropover. Lowest lines: Delight 6, Hierarchy/Craft/Material/Typography 7.
3. Then B5 (e2e with real Finder/Desktop drags) and B6 (onboarding by doing). B4b is a small follow-up.

## Iteration 17

**Date:** 2026-11-01, 22:33 to 22:55 IST. **Goal:** B6, onboarding that teaches by doing. Also finish B4b, which
iteration 10 left unlogged.

**Loop health.** Iteration 10 ran for 741 s, wrote B4b, and then exited rc=1 on the weekly usage limit with nothing
logged. Iterations 11 to 16 exited after 20 s with "You've hit your weekly limit". Diffing `snapshots/iter-10-before.tgz`
against `iter-17-before.tgz` found iteration 10's work:
- `JobStage.line(sinceProgress:)`
- a 1 s ticker loop
- `ProgressBox.latest/movedAt/stage`
- 2 new tests
- `card-7-stalled` renders

**Changed**
- **B4b, finished:**
  - The review found that the stage line used the drawn fraction, so a job at 0.5 % still read "Opening the video…".
    It now follows the newest fraction (`max(fraction, progress.latest)`), and the ticker compares against that too.
- **B6, new file `Sources/HaloUI/OnboardingTryIt.swift`:**
  - `OnboardingSample` draws a 1200 x 800 dusk PNG into `~/Library/Application Support/Halo/Try Halo`. It redraws the
    file if it is broken, and replaces a link or folder sitting in the file's place.
  - `OnboardingTry` holds the step's state: waiting, working, done(output) or failed(reason), plus paused, resume and
    convertSample.
  - `TryItStep` is the view. The sample tile is a real file drag source. Under it sit gesture chips (Drag the picture,
    Hold ⌥ Option, Drop on JPG). When the try succeeds, the output tile springs in with a check badge, a haptic plays,
    and a Show in Finder link appears.
  - A paused Halo shows "Halo is paused, so the ring won't open." with a Resume Halo button.
  - The header carries the header trait. VoiceOver gets the action "Convert to JPG" and the announcement "Converting
    to JPG".
- **`OnboardingView`:**
  - New `.tryIt` last step.
  - New `OnboardingFooter`: "Skip" (never the default button) until the try succeeds, then "Start Using Halo".
  - Internal `startAt:` init for renders.
- **App:**
  - `AppController` creates the try model when onboarding first opens.
  - Around `backend.run`, it marks the sample's job as begun and then finished, with the real failure message.
  - Pausing or resuming updates the step.
  - `WindowPresenter.replaceContent` makes a reopened onboarding start again at Welcome. While the window is on
    screen, a reopen keeps the step.

**Reviews**
- `ecc:swift-reviewer` found no crash, data-loss or security issue. Fixed from its list:
  - A stale step on reopen.
  - A reopen wiping a finished try.
  - The B4b fraction issue (above).
  - Writing through a symlink.
  - The generic failure text.
  - Unsorted outputs.
- Not changed:
  - The ticker can re-show a toast that was dismissed mid-job. Normal progress already does this.
  - A user-replaced sample still converts. That is harmless.
- `ui-craft:design-reviewer` ran 3 rounds:

  | Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 | 8 | 6 | 6 | 8 | 6 | 8 | 7 | 7 | 5 | 6 |
  | 2 | 9 | 7 | 7 | 8 | 7 | 8 | 8 | 7 | 7 | 8 |
  | 3 | 9 | 8 | 8 | 8 | 8 | 8 | 8 | 7 | 8 | 9 |

  - Round 3's copy fix (one "works like this" line, not two) is applied.
  - Delight 7 is logged as B6a.
  - Honesty: the done copy no longer claims "any app", because Photos and Mail drags are still off.
- Screenshots: `loop/shots/17/onboarding-{1-welcome,2-trigger,3-try,4-working,5-done,6-paused}-{light,dark}.png`,
  plus `card-*` re-renders. These are offscreen, so the default button draws grey: the render window is never key.

**Verification**
- `swift build` is clean (`--scratch-path .build/it17`).
- `swift test`: **254 tests, 0 failures** (9 + 42 + 56 + 38 + 109), green in 3 consecutive full runs.
  - New: `OnboardingTests` (the sample is a real 1200 x 800 PNG, prepare is idempotent and repairs a broken file, a
    link is replaced and not written through, only the sample moves the step, phases follow the conversion, and every
    step renders in light and dark).
  - B4b's 2 tests.
- `scripts/build-app.sh` OK, SHA-256 db40a042...7f298.
- Real worker check: `Halo.app/Contents/MacOS/Halo --convert image.to-jpg "Halo sample.png"` (scratchpad copy) wrote
  `Halo sample.jpg` next to it in 0.22 s. The 346 KB PNG became a 59 KB JPEG at 1200 x 800.
- **Live e2e: NOT run.** Idle was 15007 s, but `CGSSessionScreenIsLocked` was true, so e2e.sh would refuse and
  synthetic drags can't work.
- Relaunched the fresh `dist/Halo.app` at 22:50:14 (pid 24730). Log:
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Halo started: 28 actions, backend: XPCConversionBackend`
  - `Status icon: visible, frame: {{1090, 949}, {38, 33}}`
- Website: unchanged. It makes no onboarding claim.
- Tools used: snapshot diffing, `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3), Swift Testing renders, and the
  app's `--convert` diagnostic.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - Reset onboarding on a test defaults copy and drag the sample with ⌥ from the onboarding window. Confirm the ring
     opens, the drop converts, and the step shows done.
   - Real screenshots of the home window, the result card and onboarding.
   - Then close B3, B4 and B6, or fix what fails.
2. B5: e2e with real Finder/Desktop drags, plus an onboarding try-it scenario.
3. B6a (onboarding delight), B3b, C1 Zip/Unzip (the founder named zips and folders).

## Iteration 18

**Date:** 2026-11-01, 22:52 to 23:30 IST. **Goal:** C1 Zip / Unzip, plus the folder half of C2.

**Why this item.** The screen was locked (`CGSSessionScreenIsLocked` true, idle 15163 s). Every `[~]` item (B3, B4, B6)
needs a live check, so none could move. The founder's verdict named it: "`.zip` files and folders do nothing". Zip and
Unzip can be fully verified offline.

**Changed**
- **New `Sources/HaloConverters/ZipArchive.swift`.** Halo's own ZIP code on Apple's Compression framework (raw DEFLATE).
  It needs no subprocess and no third-party code.
  - `ZipWriter` streams each file, patches the local header afterwards, and stores data that deflate can't shrink.
  - `ZipReader` takes sizes and offsets only from the central directory and bounds-checks every read. Each entry inflates
    as a stream that stops at its declared size, and the CRC and size must match.
- **New `Sources/HaloConverters/ArchiveActions.swift`:**
  - `archive.unzip` "Unzip / To a folder" for .zip and .jar.
  - `archive.zip` "Zip / Makes a .zip" for any files, folders or mix. It is combined into one archive and ranked 900, so
    it is always last.
  - Zip names follow Finder: "notes.txt.zip", "Trip.zip", or "Archive.zip" for several items.
  - Unzip makes one folder, and a single top folder unpacks as itself. It refuses the whole archive on:
    - an unsafe path, a password or an unknown method;
    - Zip64, split archives or overlapping entries (the shared-stream bomb);
    - a bad CRC or a size mismatch.
  - Unzip caps: 20,000 items (implied folders counted, stopping early), 10 GB unpacked, and free space minus 256 MB.
    Links, `__MACOSX` and `.DS_Store` are skipped.
- **`HaloCore`:**
  - Plain folders resolve as `public.folder`, and `resolve` always inspects extension-less items.
  - New `ActionCategory.archive`.
  - `StagedPlacement` changes:
    - allows `zip` outputs;
    - lifts the extension allowlist only for files inside an Unzip folder;
    - re-checks the copy in the destination, so the worker can't swap in a link after the first check;
    - refuses app-like endings in a placed name with no extension (`dangerousExtensions`);
    - copies `com.apple.quarantine` from the inputs onto Zip and Unzip outputs.
- **UI:**
  - The archive tint is `systemBrown`.
  - Stage lines: "Opening the zip…", "Unzipping…", "Gathering the files…", "Zipping…".
  - A one-item ring now draws a 200° arc over the top instead of a full disc. The hit area is still the full ring.
  - The ring centre shows `folder` for a folder and `archivebox.fill` for a zip, through the new optional
    `DragCoordinator.centerSymbolFor`.
  - Choose subtitle: "Choose what to make. Halo saves it next to the original." With a single option it reads "One option
    fits. …".
  - Choose Files… accepts folders.
  - The subject says "3 items" when folders are among the inputs.
- **Website (`apps/halo-site`):**
  - "30 conversions" in the meta description and the heading.
  - A new Zip family, with an honest note: apps inside a zip won't open after Halo unzips them.
  - Launch kit counts updated.

**Reviews**
- `ecc:security-reviewer` found no CRITICAL issues and no crash on hostile input. Fixed:
  - HIGH: a swap-to-symlink window between the placement check and the copy. The copy is now re-validated.
  - MED: a folder named `Evil.app` could be placed. App-like names are now refused, and "Tool.app.zip" unpacks to "Tool".
  - MED: a crafted directory could grow the folder set to gigabytes before the cap. It now counts incrementally, and paths
    are capped at 1024 bytes and 64 levels.
  - LOW: overlapping entries, `Int64` overflow on a huge sparse file, and reading through a swapped symlink while zipping
    (now `O_NOFOLLOW` + `fstat`).
  - Accepted: quarantine is not read from files inside a dropped folder (as in Finder), and a mixed drop is
    over-quarantined.
- `ecc:swift-reviewer` found no HIGH issues. Fixed:
  - A full disk now reports "couldn't save", not "damaged".
  - Folders past the first 50 items of a big drop were silently left out.
  - The store-fallback recomputes CRC and size.
  - Empty entries skip the inflater.
  - `__MACOSX` twins no longer count toward the entry cap.
  - Cancel is checked per inflated chunk.
  - "items" now covers packages.
- `ui-craft:design-reviewer` ran 3 rounds:

  | Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 | 6 | 7 | 6 | 7 | 6 | 8 | 7 | 5 | 7 | 6 |
  | 2 | 6 | 7 | 7 | 7 | 6 | 8 | 7 | 5 | 6 | 7 |
  | 3 | 7 | 7 | 7 | 7 | 6 | 8 | 7 | 5 | 6 | 8 |

  - Fixed across the rounds:
    - the full-disc one-item ring;
    - "One archive", which was untrue for several items;
    - "The new file", which was untrue for a folder;
    - the clipboard-looking glyphs;
    - the generic centre glyph for folders and zips;
    - the one-option wording (round 3, not re-scored).
  - Below 8, and app-wide rather than Zip-specific:
    - white labels on every lit tint are about 3 to 1;
    - tinted tile icons on light grey;
    - generic centre glyphs until real thumbnails.
  - Logged on R1 and B3b. Delight 5 is about a utility action that has no moment of its own.
- Screenshots (offscreen renders):
  - `loop/shots/18/home-6-choose-zip-{light,dark}.png`
  - `loop/shots/18/home-7-choose-folder-{light,dark}.png`
  - `loop/shots/18/ring-zip-{light,dark}.png`
  - `loop/shots/18/ring-folder-{light,dark}.png`
  - plus re-renders of home 1-5.

**Verification**
- `swift build` is clean (`--scratch-path .build/it18`).
- `swift test`: **271 tests, 0 failures** (9 + 43 + 56 + 38 + 125), green in 2 consecutive full runs after the last code
  change, and in 1 more before it.
  - New `ArchiveActionTests`: 16 tests (20 cases).
  - They round-trip a folder through Halo Zip, then `unzip -t` ("No errors detected"), `ditto -x -k` and Halo Unzip, all
    byte-identical.
  - They read a Finder-style `ditto --sequesterRsrc` zip with `__MACOSX` dropped.
  - 5 escape paths are refused, with nothing written outside.
  - A link entry is never created and never followed.
  - Refusals are checked for: password, method 12, bad CRC, an inflated size above the declared size, a short size, junk
    and a truncated file.
  - 64 MB of zeros (64 KB zipped) hits the unpacked cap, and the item cap counts implied folders.
  - Overlapping entries are refused. "Tool.app.zip" unpacks to "Tool". Placement refuses "Evil.app".
  - CP437 names decode. Quarantine reaches every unzipped item and the zip of a download, and placed files are 0644.
  - The registry gives a folder `[archive.zip]`, a zip `[unzip, zip]`, and a PNG its image actions with Zip last.
  - `RingGeometryTests` now checks paint under the content angle (a lone item's arc is at 12 o'clock).
- `scripts/build-app.sh` OK, SHA-256 d0739652...e9d9.
- **Real sandboxed worker** (`Halo.app/Contents/MacOS/Halo --convert`, which uses `XPCConversionBackend`; the log shows
  `com.snappycrew.halo.worker`), on `halo-test-*` files in the scratchpad:
  - Zipped a 2.36 MB folder in 0.18 s; `unzip -t` OK.
  - `ditto` round trip identical, and Halo Unzip round trip identical. Only `.DS_Store` and a link were left out, by design.
  - Quarantine set on the zip carried to the unzipped files.
  - A Python-made zip with `../halo-test-escaped.txt` was refused ("would land outside its folder") and nothing escaped.
  - All test files were deleted.
- **Live e2e: NOT run.** The screen was locked, so a ring drag of a real folder was not watched.
- Relaunched the fresh `dist/Halo.app` at 23:23:06 (pid 80363). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1090, 949}, {38, 33}}`
- Tools used:
  - `ecc:security-reviewer`, `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - Swift Testing renders;
  - macOS `ditto`, `unzip` and `xattr` as interop oracles;
  - the app's `--convert` diagnostic.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - Drag a real folder from Finder with ⌥ and drop it on Zip, then drop the zip on Unzip. Watch the card show the folder.
   - The B3, B4 and B6 live checks listed in iteration 17.
2. B5 (e2e with real Finder drags, adding a folder → Zip scenario).
3. C1b (Zip64; video folders pass 4 GB), C2 "Convert everything inside", R1 (ring contrast and thumbnails).

## Iteration 25

**Date:** 2026-11-02, 00:42 to 01:00 IST. **Goal:** R1 Ring v2: recover iteration 19's unlogged work, then finish,
review and verify it, adding the "More" wedge.

**Why this item.** Iteration 19 ran 881 s on R1, then died on the usage limit with nothing logged, and iterations 20 to 24
exited after 20 s. A diff of the `iter-19-before` and `iter-25-before` snapshots showed ring changes in 9 source files plus
a new `RingCenterTests.swift`, with renders in `loop/shots/19`. Live items (B3, B4, B6) were blocked: idle was 0 s at the
start (the founder was using the Mac) and the screen was locked by the end.

**Recovered from iteration 19 (kept, reviewed, finished)**
- The ring centre shows the dragged item: thumbnail, name, and size or item count. Several items fan out up to 3 icons.
- Resting wedges are neutral glass. The hovered wedge fills with its category colour, darkened until white text is
  4.5:1 or better (`RingPalette.litFill`).
- A 2-item ring starts at 6 o'clock, so item 1 is on the left (`RingGeometry.startOffset`), with matching hit-testing.
- A snappier bloom (0.32 / 0.76), and a Force Touch tick on each wedge change (`onHoverChange` wired up).
- On a dense ring, the centre shows the hovered wedge's subtitle.

**Built this iteration**
- **"More" wedge.** `RingItem.fitted(_:limit:)` and `RingItem.moreID` (`halo.more`).
  - `ringContent` asks the registry for every fitting action and fits them to the ring size.
  - A drop on "More" opens the main window with every choice. It goes through the promised-files guard first and never
    reaches the registry, usage stats or the worker.
  - It lights in system blue. Grey was lost among dark-mode glass, and the accent colour resolved to red on this Mac,
    where it reads as PDF.
  - VoiceOver hint: "Opens the Halo window with every choice".
- **Swift review fixes** (`ecc:swift-reviewer`: no HIGH):
  - MED: the first icons come from the name's type, with no disk access on the main thread. Finder's icon follows off
    the main thread.
  - MED: the folder count runs on a lazy enumerator, stops at "1,000+ items", and is cancelled with the ring (the
    cancellation is forwarded into the detached lookup).
  - MED: the promised-files check now comes before the More branch.
  - LOW: a cancel check before Quick Look, the thumbnail scale from the screen, and a wider max-choices test.
- **Design fixes** (3 rounds):
  - Non-hovered wedges are no longer dimmed (dimming cut label contrast).
  - The lit fill gets a 1.5 pt lit rim, a 6 % gradient and a tighter shadow.
  - Subtitles are primary at 0.85 opacity and 10 or 11 pt (were `.secondary` at 9.5 or 10.5).
  - Ring icons are monochrome (hierarchical layers ghosted in white).
  - The centre name and size are stronger.
  - The fan has an upright, larger front icon.
  - The "received" spring is 1.12.
- `docs/ARCHITECTURE.md`: a new Ring v2 section, and the Quick Look exemption now covers the ring centre.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/25/ring-1..8-{light,dark}.png`)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 7 | 7 | 8 | 6 | 7 | 8 | 7 | 6 | 8 |
| 2 | 8 | 8 | 7 | 8 | 7 | 8 | 8 | 7 | 7 | 8 |
| 3 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 7 | 8 | 8 |

- Round 3 viewed only 5 of the 16 shots, so treat it as provisional.
- Round 3's two fixes (the 1.12 spring, subtitles at 0.85) are applied but not re-scored.
- Left open as R1a: Delight 7, dense-label scaling, and the muddy archive brown.

**Verification**
- `swift build` is clean with no new warnings (`--scratch-path .build/it25`).
- `swift test`: **284 tests, 0 failures** (9 + 55 + 57 + 38 + 125).
  - Green in 1 full run after the last code change.
  - Also green in a full run before the round-3 design tweaks (also 284).
  - 279 at the start, on the recovered iteration 19 code.
  - Ring suites re-run after each change.
- New tests:
  - `aRingThatFitsHasNoMoreWedge`, `aRingTooSmallEndsInMore`.
  - `theWindowShowsEveryChoiceMorePointsAt`: every input type alone, ×2 and ×3, and every mixed pair. The worst case is
    2 GIFs = 11 actions.
  - `firstIconsComeFromTheNameAlone`, `aHugeFolderSaysOverTheCap`.
  - The contrast test now covers the More blue and the 6 % gradient.
  - A `ring-8-more` render.
- `scripts/build-app.sh` OK: 7.3 MB app, 2.9 MB DMG, SHA-256 849880b8...4158, ad-hoc signed.
- **Live e2e: NOT run.** Idle was 0 s at the start, and at the end the screen was locked
  (`CGSSessionScreenIsLocked` true, idle 693 s), so `e2e.sh` would refuse it (exit 4). Nothing was dragged live: the real
  Quick Look thumbnail timing, the haptic and the More drop are unproven.
- Relaunched the fresh `dist/Halo.app` at 00:57:07 (pid 2979, idle 693 s). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1086, 949}, {38, 33}}`
- Website unchanged: it makes no claim about the ring's centre, haptics or More. No claim is added until a live drag
  proves them.
- Tools used:
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - snapshot diff for recovery;
  - Swift Testing `ImageRenderer` renders.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - The R1 live check: a real photo drag, the thumbnail, the haptic, and More at ring size 4.
   - The B3, B4 and B6 live checks.
2. R1a (delight moment, dense labels, archive colour).
3. B5 (real Finder drags in e2e), C1b (Zip64), C2 ("Convert everything inside").

## Iteration 26

**Date:** 2026-11-02, 00:59 to 01:20 IST. **Goal:** B3b, main window polish: the format grid, tile icon contrast,
and a setting to turn off file previews.

**Why this item.** Iteration 25 ended cleanly, so there was nothing to recover. Every `[~]` item (B3, B4, B6, R1)
needs a live drag, and the screen was locked the whole time (`CGSSessionScreenIsLocked` true, idle 843 s at the start
and 1825 s at the end). B3b is the highest-priority `[ ]` item that can be fully proven offline.

**Built**
- **Balanced grid** (`ChoiceLayout`): at most 4 across, and no row ever has one tile on its own. 9 formats (a PNG) are
  now 3 × 3 instead of 4 + 4 + 1. 5 and 6 use 3 columns. One or two choices get wide tiles, icon beside the text.
- **The card hugs the grid while choosing.** A folder's lone Zip used to float in a 368 pt card. Now the card is as
  tall as its content, and the height change uses the window's spring (a crossfade under Reduce Motion).
- **Icon badges** (`ActionBadge`): a white glyph on a rounded badge in the category colour, darkened with
  `RingPalette.litFill` until white reads at 4.5:1 or better. Before, it was a bare tinted glyph on a grey tile, under 3:1.
- **Keyboard:** tiles 1 to 9 answer to the plain digit keys, shown as small quiet keycaps. A lone choice answers to
  Return, shown as a keycap, and gets the default look (a light wash and edge of its colour). Esc cancels, and Cancel's
  tooltip says so. This works without Full Keyboard Access.
- **Tile subtitles** use the app's 4.5:1 secondary token (`CardMetrics.detail`) instead of `.secondary`, which was
  about 3.6:1.
- **"Show file previews" setting** (`halo.showPreviews`, on by default; Settings > Privacy). Off means Finder icons
  only, everywhere:
  - the window (`FileIcon` reads `haloShowsPreviews` from the environment);
  - result cards (`ToastCenter` follows the setting live, even a card already on screen);
  - the ring centre (`RingModel.showsThumbnails`, synced from `AppController`). A thumbnail already showing is removed
    at once.
- **Bug fixed (found by the design review, older than this change):** once Recent had rows, the VStack squeezed the
  drop zone to its 296 pt minimum while its content needed about 354 pt. "Choose Files…" stuck out over the card's
  bottom edge. The card now always takes its full height (`fixedSize`), with a tighter 16/8 pt rhythm when compact.
- **Settings:** the "Ring size" value and stepper now sit on the trailing edge like the Trigger key menu.

**Swift review** (`ecc:swift-reviewer`): 1 HIGH, 2 MED, 5 LOW.
- HIGH, fixed: `FileIcon` never cancelled its Quick Look request, so a stale thumbnail could land after the setting
  was turned off or the file changed. It now uses `withTaskCancellationHandler` plus `QLThumbnailGenerator.cancel`,
  and checks for cancellation before it assigns.
- MED, fixed: the ring checked the setting only before the Quick Look await. It now re-checks after the await and
  clears on turn-off.
- MED, fixed: the render tests used fixed `UserDefaults` suites. They now use unique suites that are removed afterwards.
- LOW, fixed: toasts followed the setting only on the next card.
- LOW, not changed: `ChoiceLayout` would leave a lone tile at 13 or 17. The window never shows more than 12
  (`limit: 12`, tested), so this can't happen.
- The reviewer confirmed the gate covers every thumbnail path. The only Quick Look users are `RingModel.thumbnail` and
  `FileIcon`.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/26/`: home 1 to 9 and `settings-general`, light
and dark)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 7 | 6 | 8 | 7 | 8 | 7 | 7 | 7 | 8 |
| 2 | 8 | 8 | 7 | 8 | 8 | 8 | 8 | 7 | 7 | 9 |
| 3 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 9 |

- Round 3 viewed all 18 shots, but screenshots only (no source), and called Craft and Delight borderline 8s.
- Declined, with reasons kept in DECISIONS:
  - Reordering tiles into groups: the window keeps the ring's order.
  - Colouring badges by role: colour means file family app-wide.
- Round 3's four leftovers are logged as B3c.

**Verification**
- `swift build` is clean, with only the usual CLT linker search-path warnings (`--scratch-path .build/it26`).
- `swift test`: **290 tests, 0 failures** (9 + 60 + 57 + 38 + 125), green in the last full run after the final code
  change. Earlier full runs: 287 and 288, both green.
- New tests:
  - `choiceGridIsBalanced` (1 to 12 tiles, no lone last tile, at most 4 across);
  - `tilesHaveKeys`;
  - `previewsOffKeepsTheIcon` (also clears a showing thumbnail);
  - `cardsFollowThePreviewsSetting`;
  - settings default and persistence for `showPreviews`;
  - `polishedStatesRender` (home-8, home-9, settings-general).
- `scripts/build-app.sh` OK: 7.4 MB app, 2.9 MB DMG, SHA-256 996a4c55...a457, ad-hoc signed.
- **Live e2e: NOT run.** The screen was locked (idle 1825 s at the end), so `e2e.sh` would refuse (exit 4). Not checked
  live:
  - digit keys and Return in the real window;
  - the card height spring;
  - the toggle's effect on real Quick Look thumbnails.
- Relaunched the fresh `dist/Halo.app` at 01:16:05 (pid 5256). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1094, 949}, {38, 33}}`
- Website unchanged: it makes no claim about the window grid or previews.
- Tools used:
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - Swift Testing renders through `NSHostingView`.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - The B3 window drop, including pressing 1 to 9 and Return on the grid.
   - The B4 card, the B6 try-it drag, and the R1 ring drag.
2. R1a (drop moment, dense labels, archive colour, which now also shows on Zip badges).
3. B3c (the round-3 leftovers), then B5, C1b and C2.

## Iteration 27

**Date:** 2026-11-02, 01:18 to 01:40 IST. **Goal:** B3c, the main window leftovers from iteration 26's design review.

**Why this item.** Iteration 26 ended cleanly, so there was nothing to recover. The screen was locked from the start
(`CGSSessionScreenIsLocked` true, idle 1989 s), so every `[~]` item (B3, B4, B6, R1) stayed blocked: each needs a live
drag. B3c is the highest-priority `[ ]` item that can be fully proven offline.

**Built**
- **Header icon haze, root cause fixed.** Core Graphics shadow offset and blur are in device pixels and ignore the CTM.
  `scripts/make-icon.swift` drew every size with the 1024 px shadow, so the 64 px icon had a 28 px blur reaching its
  edges: a faint square in the light header. Shadows are now scaled by the pixel factor. Measured: 64 px edge alpha
  went from max 50 (sum 4604) to 0. The 1024 px master is byte-identical. The rebuilt app carries the new `.icns`.
- **Compact hero labels.** 11 pt when compact and 3 pt further out (`HeroRing.Metrics.labelSize`, `labelRadius`).
  "Compress" now clears its petal's gutters by 4 pt or more on each side.
- **Progress ring** (`JobProgress`): a 20 pt ring with a 16 % primary track and an 85 % primary arc that animates with the
  fraction. At 0 % a 28 % arc turns with one repeating rotation. It replaces the small system spinner, which nearly
  vanished on the dark window.
- **Recent rests on whole rows** (`RecentsMetrics.viewport`). When rows overflow, the list ends on whole 56 pt rows plus
  a 20 pt peek under a 16 pt fade, never a half-cut row. Rows that fit are never snapped away. The header shows the
  count ("Recent 9", tooltip "9 conversions kept").
- **Try Again** on failed rows (`HomeJob.canRetry`, `HomeModel.onRetryJob`, `AppController.retryHomeJob`). It
  re-runs the same action on the same files through `handleDrop`, which re-checks both. It also has a VoiceOver action.
- **Keyboard:** ⌘Return on a focused Recent row shows it in Finder. The shortcut is shown in the context menu and the
  folder button's tooltip.
- Row details, the count and "Clear" use the app's 4.5:1 secondary token (were `.secondary`, about 3.6:1). Row button
  glyphs are medium weight.
- Kept on purpose: the Ring size stepper (it lines up with the toggles; the popup's 3.5 pt inset is AppKit's own) and
  one badge tone per family. Reasons are in DECISIONS.

**Swift review** (`ecc:swift-reviewer`): 0 HIGH, 2 MED, 3 LOW.
- MED, fixed: the snap counted the fade padding as content, so 5 rows in 290 pt lost a row that fit. Tested now.
- MED, fixed: the 0 % arc ran a 60 fps `TimelineView`. It is now one repeating animation scoped to the rotation.
- LOW, fixed: the row height was a second magic number. `RowLayout` now uses `RecentsMetrics.row`.
- LOW, fixed: a failure updated `home.jobs` twice. `updateHomeJob` now takes `canRetry` and writes once.
- LOW, accepted: Try Again removes the row before the new job starts. If the files are gone, the usual card says so.
- Confirmed: retry can't race the 12 s removal (job keys are fresh UUIDs), and `failedJobs` can't leak.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/27/`)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 8 | 7.5 | 8 | 8 | 7.5 | 7.5 | 7 | 6.5 | 8.5 |
| 2 | 8.5 | 8 | 8 | 8.5 | 8 | 8 | 8 | 7 | 8 | 9 |

- Round 1 confirmed all five fixes landed, except the peek, which was too weak at 12 pt and 20 pt under a 24 pt fade.
- Round 2's last 3 notes: the count's meaning and the ⌘Return hint are fixed as tooltips. The peek stays as a scroll
  cue, logged as B3d. These don't change the renders, so there was no round 3.
- Delight 7 is the only line under 8. It is outside B3c's scope and logged as B3d.

**Verification**
- `swift build` is clean (`--scratch-path .build/it27`).
- `swift test`: **293 tests, 0 failures** (9 + 64 + 57 + 38 + 125). It was green in the last full run after the final
  code change, and in two earlier full runs.
- New tests:
  - `recentListRestsOnWholeRows`: fit, the 290 pt boundary, tiny space, and overflow from 76 to 600 pt.
  - `heroLabelsFitTheirPetals`: measured text plus 8 pt is within the chord, at both sizes.
  - `failedJobsOfferTryAgainOnlyWhenAsked`.
  - `leftoverStatesRender`: `home-10-long-recents`, `home-11-jobs`.
  - `home-5-working` now shows Try Again.
- `scripts/build-app.sh` OK: 7.4 MB app, 2.9 MB DMG, SHA-256 4ef3899e...0970, ad-hoc signed.
- **Live e2e: NOT run.** The screen was locked all iteration, so `e2e.sh` would refuse it (exit 4). Not checked live:
  Try Again on a real failure, ⌘Return, the spinner's motion, and the header icon in the real window.
- Relaunched the fresh `dist/Halo.app` at 01:34:11 (pid 96462, idle 2913 s). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1094, 949}, {38, 33}}`
- Website unchanged: it makes no claim about window rows, retry or the icon.
- Tools used:
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x2);
  - Swift Testing renders;
  - a PNG alpha probe for the icon.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - The B3, B4, B6 and R1 live checks, plus Try Again on a real failure.
2. R1a (drop moment, dense labels, archive colour), then B3d.
3. B5, C1b, C2.

## Iteration 28

**Date:** 2026-11-02, 01:36 to 01:56 IST. **Goal:** R1a, the ring's drop moment, dense labels and archive colour.

**Why this item.** Iteration 27 ended cleanly, so there was nothing to recover. The screen was locked from the start
(`CGSSessionScreenIsLocked` true, idle 3058 s), so every `[~]` item (B3, B4, B6, R1) stayed blocked: each needs a live
drag. R1a is the highest-priority item left that can be fully proven offline (B3d is the window's twin of it).

**Built**
- **Drop moment.** After the pulse, the chosen wedge collapses into the centre (now `RingMotion.collapseDelay`, 0.12 s).
  The centre disc then fills with that action's lit colour (the same `RingPalette.litFill` as a hovered wedge), and its
  symbol and text fade to white. One `DropRipple` in that same colour leaves the disc and fades out past the wedges. It
  holds 5 pt wide for the first half, then thins to 1.5 pt, and ends exactly with the dismiss fade (0.44 s).
  - `commitDuration` went from 0.34 s to 0.40 s so the ripple reads. The conversion still starts at once on drop.
  - Under Reduce Motion there is no ripple (`RingView.showsRipple`), only 0.15 s crossfades.
  - VoiceOver hears "Converting to JPG" (or "Opening Halo" for More) when a drop commits. The card already says "Saved …".
- **One title size per ring** (`RingLayout.sharedTitleSize(for:)`). Before, "Strip Info", "Compress" and "Half Size"
  each shrank on their own. Now every title takes the largest half-point size at which all of them fit, at most 2 pt
  under the layout's size. The result is cached (the view asks on every hover change). A photo's 9-wedge ring and the
  default 10-wedge ring keep 11 pt (tested). Only ring size 11 or 12 with the longest titles drops to 9 pt.
- **Archive is green** (was system brown) app-wide: ring, window badges, hero. Brown darkened for white text was mud.
- **Dark-mode resting labels** are full-strength, with a faint halo (black 35 %, radius 1), like Finder's Desktop labels.
  The "Makes a .zip" subtitle measured 3.79:1 before and 4.70:1 after, on the stand-in wallpaper's lightest region.
- `RingItem.tint` (family colour, or blue for More) replaces two inline copies.
- A test-only `RingView.init(model:landed:ripple:)` freezes the drop moment for renders. It skips the live phase sync,
  which at first restarted the commit and spoiled the render (caught by looking at the PNG).

**Swift review** (`ecc:swift-reviewer`): 0 HIGH, 3 MED, 6 LOW.
- MED, fixed: title measuring ran in `body` on every hover. It is now cached per title set and layout.
- MED, fixed: the ripple timing test was a tautology. It is now a pure `showsRipple` rule, tested for each stage and for
  Reduce Motion, plus checks on the band's geometry.
- MED, fixed: the ripple's insertion also faded in under the commit spring. It now uses `.transition(.identity)`.
- LOW, fixed: the text flipped to white a frame before the fill (it now fades as a plain `Color`). Also fixed: the force
  unwraps in the tests, the method's name (`sharedTitleSize(for:)`), and a doc comment.
- LOW, kept: `@Environment(\.self)` on the centre disc (the wedges already use it); the font-metric tests depend on the
  system font (they assert the fallback or a fit). The ripple's glow stays inside the panel (tested).
- Confirmed: the ripple can't replay or linger (its view exists only in `.collapse`; a reset to `.hidden` is
  unanimated). The overlay's timing still reads `RingMotion`, so `OverlayTests` holds.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/28/`, before in `loop/shots/28-before/`)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 8 | 7 | 8 | 8 | 7 | 8 | 8 | 7 | 8 |
| 2 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 7 | 8 |
| 3 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 |

- Round 1 called the drop moment "not gimmicky: functional confirmation" (Delight 7 to 8). Its notes on the ripple's
  colour and weight are fixed. Typography 7 asked for a 10 pt floor; declined with evidence (DECISIONS), and round 2
  accepted it.
- Round 2 measured the dark resting subtitle at about 3.6:1. Fixed as above; round 3 confirmed it is legible and the
  halo isn't muddy.
- Motion and the VoiceOver line were judged from code and frozen frames only.

**Verification**
- `swift build` is clean (`--scratch-path .build/it28`).
- `swift test`: **299 tests, 0 failures** (9 + 70 + 57 + 38 + 125). This was the last full run after the final code
  change; two earlier full runs were also green (298 and 299).
- New tests:
  - `renderDropMoments`: ring-9 JPG, ring-10 Unzip, ring-11 More, light and dark.
  - `titlesShareOneSizeThatFits`: counts 3 to 12, worst-case titles.
  - `theRealDenseRingFitsWithoutTheFallback`: 9, 10 and 12 wedges.
  - `litColoursStayClearAndDistinct`: 4 appearances, saturation 0.55 or more, green and blue 15° or more from all others.
  - `theRippleLeavesTheCentreOnlyWhenADropLands` and `theSharedTitleSizeIsRemembered`.
- `scripts/build-app.sh` OK: 7.5 MB app, 2.9 MB DMG, SHA-256 2835c03d...f784, ad-hoc signed.
- **Live e2e: NOT run.** The screen was locked all iteration (idle 4074 s at the end), so `e2e.sh` would refuse it
  (exit 4). Not seen live: the ripple's motion, the colour flood timing on a real drop, the VoiceOver line.
- Relaunched the fresh `dist/Halo.app` at 01:53:28 (pid 9485). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1094, 949}, {38, 33}}`
- Website unchanged: it has no per-family colours and makes no claim about the drop animation.
- Tools used:
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - Swift Testing renders;
  - a PIL pixel probe for label contrast;
  - an `NSFont` width probe for titles.

**Next**
1. On an unlocked idle Mac:
   - `scripts/e2e.sh --no-screenshot`.
   - The B3, B4, B6 and R1 live checks, plus watching one real drop for the ripple and colour flood.
2. B3d (window delight + peek).
3. B5, C1b, C2.

## Iteration 29

**Goal:** B3d, the main window's delight + peek: give a finished result a moment as it lands in Recent, make the
overflow peek read as one soft ghost, and enlarge the menu-bar chip in the header.

**Why this item.** Iteration 28 ended cleanly, so there was nothing to recover. The screen was locked from the start
(`CGSSessionScreenIsLocked` true, idle 4256 s), so every `[~]` item (B3, B4, B6, R1) stayed blocked on a live drag.
B3d was the next P0 item fully provable offline (iteration 28's "Next").

**Built** (`Sources/HaloUI/HomeView.swift`)
- **Arrival.** `HomeModel.arrivals` holds results new to the list and dated within 10 s, never the first list the host
  sets (history). The new row takes its Done row's slot:
  - a soft system-green wash (10 % light, 12 % dark, inset 2 pt so two arrivals stay two rows);
  - the Done row's green check as a badge on the thumbnail corner, its ring filled in the washed row colour;
  - both held 0.7 s, then faded over 1.3 s (opacity, so also under Reduce Motion);
  - the thumbnail springs from 0.9 to 1.0 (skipped under Reduce Motion).
  The row calls `settleArrival` when it shows it, so a reopened window never replays it. Unseen ids expire after 3 s.
  `AppController.setUpHome()` sets the baseline before any job can finish (comment added there).
- **Peek.** 20 pt to 36 pt, and the fade now covers it in three continuous columns: thumbnail (half by 4 pt, clear by
  22), text (half by 8, clear by 29, just past the title line), buttons (clear by 14, before their glyphs). Result: one
  soft ghost of icon and title, no cut glyph tops. No fade and no bottom padding when every row fits (was a 16 pt fade
  and padding always).
- **Header chip.** Glyph 13 pt to 15 pt in a 20 pt pill that overhangs the 18 pt line, so the header keeps its height
  (hero card edge at the same pixel row, 208 px, before and after).
- Test-only `haloHoldsArrival` environment key freezes the arrival's first frame for renders.

**Swift review** (`ecc:swift-reviewer`): 0 HIGH, 2 MED, 5 LOW.
- MED, fixed: the arrival could replay if the row was re-created within its 3 s life (window reopened). Now spent on
  first show (`settleArrival`), tested.
- MED, fixed: the 36 pt bottom padding applied even when rows fit (the list could scroll into blank space).
- LOW, fixed: shadowed names in `noteArrivals`, an inaccurate doc comment, the badge not hidden from VoiceOver, the
  baseline comment in AppController.
- LOW, confirmed fine: concurrency (`Task { @MainActor [weak self] }` in a `@MainActor` didSet), State identity, no
  conflict with the parent `.animation(value: model.recents)`, the frozen render really shows the landed thumbnail.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/29/`, before in `loop/shots/29-before/`)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 7 | 7 | 8 | 8 | 8 | 8 | 8 | 8 | 7 |
| 2 | 8 | 7 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 |
| 3 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 |

- Delight rose from 7 (iteration 27) to 8.
- Round 1 MUSTs fixed:
  - the peek still cut the button glyphs;
  - the dark thumbnail outweighed the title;
  - the padding with no fade.
- Round 1 NICEs fixed:
  - the chip moved the window 2 pt;
  - the badge ring colour;
  - the scale went from 0.82 to 0.9;
  - the batch washes merged.
- Round 2 MUST fixed: the dark thumbnail column got its own faster fade.
- Declined, with reasons in DECISIONS:
  - the white check on green at about 2.2:1;
  - the pill fill;
  - the wash radius.
- Round 3 found, outside B3d: the lit "Compress" label in the hero ring spills its petal. It is logged as B3e.
- Motion (the fade and the spring) was judged from code and the first frame only.

**Debugging note.** The arrival expiry test failed under the full suite twice (fixed 400 ms wait, then a 10 s poll).
Instrumented: other suites' renders held the main actor for about 40 s, the removal task and the poll then woke
together, and the clock-based deadline had already passed. Fix: poll by turns and pin the model clock. Not a product
bug.

**Verification**
- `swift build` clean (`--scratch-path .build/it29`).
- `swift test`: **301 tests, 0 failures** (9 + 72 + 57 + 38 + 125), the last full run after the final code change.
- New tests:
  - `arrivalRenders` (light and dark, `home-12-arrival-*`);
  - `arrivalsAreOnlyFreshResults`: history, refresh, fresh, stale, expiry and settle;
  - `recentListRestsOnWholeRows`, extended: no fade without overflow, peek and fade bounds.
- Contrast of row detail text on the wash (computed): light 5.74:1, dark 5.57:1 (plain rows 5.89 and 6.55).
- `scripts/build-app.sh` OK: 7.5 MB app, 2.9 MB DMG, SHA-256 498d88ea...587f54e, ad-hoc signed.
- **Live e2e: NOT run.** The screen was locked all iteration (idle 5626 s at the end), so `e2e.sh` would refuse it
  (exit 4). Not seen live: the wash fade, the thumbnail spring, a real Quick Look thumbnail under the badge.
- Relaunched the fresh `dist/Halo.app` at 02:19:14 (pid 4801). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1094, 949}, {38, 33}}`
- Website unchanged: it makes no claim about the Recent list's animation.
- Tools used:
  - `superpowers:systematic-debugging` (the test failure);
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - Swift Testing renders;
  - a PIL crop and pixel probe (header edge, peek);
  - a WCAG contrast calculation.

**Next**
1. On an unlocked idle Mac:
   - the e2e script with `--no-screenshot`;
   - the B3, B4, B6 and R1 live checks;
   - watching one real drop for the ring ripple and the window arrival.
2. B3e (lit hero label).
3. B6a, B5, C1b, C2.

## Iteration 30

**Date:** 2026-11-02, 02:21 to 02:52 IST. **Goal:** B3e, the hero ring label that spilled over its petal.

**Why this item.** Iteration 29 ended cleanly, so there was nothing to recover. The screen was locked from the start
(`CGSSessionScreenIsLocked` true, idle 5811 s), so every `[~]` item (B3, B4, B6, R1) stayed blocked on a live drag.
B3e was the next P0 item (iteration 29's "Next").

**Root cause.** The old `heroLabelsFitTheirPetals` measured a straight chord at the label radius. The hero's petals
are centred at 30°, 90°… so four of the six are tilted, and level text hits a tilted gutter long before the chord's
end. It was also the resting "Compress", not only the lit one (`loop/shots/30-before/home-10-long-recents-light.png`).
- A scratch Swift search over the real petal outline (`CGPath.contains`, 4 pt margin) found no position for "Compress"
  at 11 pt in the compact unturned ring: best 0.5 pt clearance, iteration 29's placement -5.5 pt.
- Side petals were worse, because the text runs along the radius there.

**Built** (`Sources/HaloUI/HomeView.swift`, `HeroRing` and `HeroPalette`)
- **Turned half a petal.** `HeroSegmentShape` rotates `RingSegmentShape`'s path by -step/2, and
  `HeroRing.angle(index:)` = index × step. One petal points straight up, one straight down.
- **New order**, clockwise from the top: To Text, JPG, PDF, Compress, MP4, M4A.
  - The two long titles take the level petals.
  - JPG and Compress (both teal) never touch, and PDF red never touches M4A pink (R1b).
- **One placement rule.** Labels sit 0.5 pt inside the band's middle, and the stack is lifted 3 pt × cos² of its angle.
  That is full on the level petals and a quarter on the tilted ones, so tilted stacks stay on the optical centre.
  Icon and title have fixed frame heights (`iconBox`, `textBox`), so the test checks the drawn boxes.
  `labelCenter(index:metrics:)` is pure.
- **Calmer highlight** (round 2 Hierarchy 7). The lit petal is a strong wash of its colour (50 % light, 40 % dark),
  with a 60 % stroke and a tinted label. Before, it was solid with white text and outshouted "Drop a file here"; the
  red read as an error.
  - Dark lifted went from 40 % to 32 %, so it stays a step under lit (round 3 Feedback 7).
  - The real drag ring's hovered wedge stays solid, because there it is the user's target.
- **Spacing.** The compact hero's gap to the headline went from 8 to 12 pt, because the lit 6 o'clock petal drifts
  3 pt toward it.
- Test-only `frozenActive` holds the highlight on one petal for renders.

**Measured clearance** from the real outline, with real SF Symbol sizes: 4.75 pt or more compact, about 8 pt regular
(was -5.5 pt for "Compress" compact).

**Swift review** (`ecc:swift-reviewer`): 0 HIGH, 1 MED, 5 LOW.
- Confirmed: the rotation direction and pivot are right, the animatable radii still animate, and the test's rectangles
  match the VStack and offsets.
- MED, fixed: the test assumed the glyphs fit their boxes. It now checks the title's line height against `textBox`, and
  tests the symbol at its own size, centred in its box. Symbols overhang their box by up to 2 pt; frames don't clip.
- LOW, fixed: the magic numbers in the regression test are now derived from iteration 29's placement.
- LOW, kept:
  - `frozenActive` defaults to nil (the same pattern as `RingView`'s test init);
  - compact and regular label offsets swap without easing (only the radii animate; the switch happens when Recent
    first gets a row);
  - the 1.06 bloom overhangs the frame by a few points (nothing clips it);
  - duplicate corner samples in `perimeter(of:)`.

**Design review** (`ui-craft:design-reviewer`, shots in `loop/shots/30/`, before in `loop/shots/30-before/`)

| Round | Cla | Hie | Cra | Mot | Mat | Typ | Fee | Del | A11y | Hon |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 8 | 7 | 7 | 8 | 8 | 8 | 8 | 8 | 6 | 7 |
| 2 | 8 | 7 | 8 | 8 | 8 | 8 | 8 | 8 | 8 | 8 |
| 3 | 8 | 8 | 8 | 8 | 8 | 8 | 7 | 8 | 8 | 8 |

- Round 1's A11y 6 was an estimate by eye (about 2.5:1). Pixel-measured: lifted "To Text" 5.28:1, lit white 4.63 to
  4.72:1 on every fill, both modes. Round 2 accepted it.
- Round 1's Honesty 7 ("orientation differs from the real ring") was declined. The real ring shows each file's own
  actions (9 wedges for a PNG, 2 for a zip), so no fixed picture could match it. Round 2 accepted it.
- Round 3's only MUST (dark lifted = lit opacity) is fixed after round 3, but not re-scored.
- Motion was judged from code and stills only.

**Verification**
- `swift build` clean (`--scratch-path .build/it30`).
- `swift test`: **303 tests, 0 failures** (9 + 74 + 57 + 38 + 125). This was the last full run, after the final code
  change; two earlier full runs in this iteration were also green.
- New and changed tests:
  - `heroLabelsFitTheirPetals`: real outline, icon and title, both sizes;
  - `theOutlineCheckCatchesATiltedPetal`: the new check fails on iteration 29's placement;
  - `heroPetalsRender`: `hero-petals-*`, every petal lit plus lifted, both sizes.
- `heroRingLabelsMeetAA` caught two too-bright dark washes on the way (62 % and 50 %, 3.97 to 4.37:1).
- `scripts/build-app.sh` OK: 7.6 MB app, 2.9 MB DMG, SHA-256 55f1e1f4...cf209b, ad-hoc signed.
- **Live e2e: NOT run.** The screen was locked all iteration (idle 7462 s at the end), so `e2e.sh` would refuse it
  (exit 4). Not seen live: the walking highlight in the real window.
- Relaunched the fresh `dist/Halo.app` at 02:50:02 (pid 23244). Log:
  - `Halo started: 30 actions, backend: XPCConversionBackend, paused: false`
  - `Home window shown, frame: {{456, 172}, {600, 720}}`
  - `Status icon: visible, frame: {{1094, 949}, {38, 33}}`
- Website unchanged: it doesn't show the hero ring.
- Tools used:
  - `ecc:swift-reviewer`, `ui-craft:design-reviewer` (x3);
  - a scratch Swift geometry search over the real `CGPath` (`CGPath.contains`);
  - Swift Testing renders;
  - a PIL pixel contrast probe.

**Next**
1. On an unlocked idle Mac:
   - the e2e script with `--no-screenshot`;
   - the B3, B4, B6 and R1 live checks;
   - one real drop to watch the ring ripple, the window arrival and the hero walk.
2. B6a (onboarding delight).
3. B5, C1b, C2.

## Audit session, 2026-11-04 (chat, not a loop iteration)

**Why:** founder asked for a full audit. Report: `docs/plans/2026-11-04-halo-full-audit.md`. Snapshot before edits: `loop/snapshots/audit-2026-11-04-before.tgz`.

**Changed**
- Flaky tests: `cleanIsLinear` now measures thread CPU time, not wall clock; `oversizedInputsFailCleanly` time limit is a 30 s hang guard; the bomb test limits are 30 s and 3 GB because they are per process.
- `scripts/e2e.sh`: removed the out-of-date "no ring on a zip" step; added "ZIP -> Unzip" and "Folder -> Zip". NOT run live: this session has no Accessibility permission.
- Site, launch drafts and PRIVACY.md: corrected false claims (size caps, any drag, 28 in all, permission line, unsourced lines).

**Evidence**
- 303 tests: 4 full runs after the fix, 0 failures, on a quiet Mac. Not yet re-run under heavy load.
- Real worker: 45 of 52 conversions OK, 7 refused; self-test and crash test PASS.
- No live drag. App code is unchanged, so `dist/` was not rebuilt.

**Next:** founder accepts the Xcode licence and grants Accessibility and Screen Recording, then run e2e and add real Finder drags (B5).

## Founder test and live fixes, 2026-11-04 (chat, not a loop iteration)

**Founder saw on the real screen:** the result card cut off top and bottom; too many steps to open the ring.

**Fixed**
- Result card: `sizingOptions = []` made `fittingSize` 0, so the panel sat at its 56 pt minimum for every card. Height now comes from a SwiftUI preference, and the entrance is a fade (a frame animation landed on the old size). New test `theRealPanelFitsEveryKindOfCard` drives the real panel; it failed before the fix.
- Ring opens on a 0.4 s pause mid-drag, no key (on by default, Settings toggle). Option still opens at once. Dragging 230 pt away closes it, one pause per drag, none over Halo's own window. A drop in the hub or beyond the wedges reaches the app underneath.
- "Already as small" is a calm notice, not "Couldn't convert". Job failures, no-match notices and ring dismiss reasons are now logged.
- The drop zone's accessibility id was being replaced by the window's.
- e2e: real Finder and Desktop drags (B5), pause scenarios, Esc after the icon scenario, driver source starts on first movement and accepts first mouse.

**Evidence**
- Founder's own drags from Finder: Option ring, JPG, Unzip, Compress; then the no-key pause ring, MP4, Unzip. Founder: "working fine for now".
- e2e 32 of 32 ALL PASS at 04:21 (one clean run; runs before the test fixes: 20 and 27). First full pass of the current script. Drop on the menu-bar icon passed in the 04:10 run too: B2b has live evidence but no human check.
- 312 unit tests pass under the Xcode 27.2 toolchain.
- Compress: 10 min 1080p noise clip 17.8 GB to 230 MB in 77 s. Real iPhone 4K HDR clip (59 s) 493 MB to 47 MB in 15 s, but silently 1080p, the 4-channel audio track dropped, VMAF about 78.

**Not explained:** double ring opens about 1 s apart in the founder's Option drags and one e2e run. Not reproduced in 6 repeat drags; dismiss reasons are now logged, so watch for it.

**Next:** real name, billion-dollar UI redesign, Compress keeping resolution with size choices, C3 Photos and Mail drags.

## Bubble ring and rename to Frenzy, 2026-11-04 (chat)

Founder chose bubbles and the name Frenzy (dictation first wrote "Friendly"). Ring is now Liquid Glass bubbles (`HaloUI/RingBubble.swift`) that split out of the centre, swell on hover with neighbours making room, and flow back on a drop; hit-testing is unchanged. Reduce Motion and Reduce Transparency keep working paths. A real capture caught what renders could not: glass drawn as a sibling blurred the labels (fix: glass is a modifier on the content), and a launch sweep of used folders fired macOS's Desktop permission prompt (fix: protected folders are swept only when the user converts there).

Renamed: app, bundle ids `com.snappycrew.frenzy` and `.worker`, executables, user-facing strings, site, launch drafts, docs. Internal targets and the `apps/halo` folder keep the old name. Defaults start fresh under the new id.

Evidence: 311 unit tests, e2e 32 of 32 on Frenzy.app at 05:02 (one run). Motion checked in one recorded drag, frames only, on a dark background.

Not done: home window, onboarding, cards and the app icon are still the old look; ring centre showed the Finder icon, not the photo thumbnail, in the capture (check); Compress quality; Photos and Mail drags.

## Real-world pass, 2026-11-04 (chat)

Read the app as someone using it all day. Code and unit tests only: the founder was using the Mac, so the app was never launched and no real drag was done.

Fixed: Photos, Mail and browser drags (C3); read-only folders save in Downloads and say why (B8); one crashing file costs only itself; memory death has its own message; iCloud placeholders download first with the wait named; a dead share can't freeze a drag; sleep retry; quit asks; replaced app is named; pause false positives; double-open paths; Control as a trigger; the commit moment cut short by the mouse-up tick; a fading ring eating drops; a pause ring closing near screen edges; launch-time folder listing on iCloud and external disks (prompt or disk wake); 20,000 files slowing the choice; partial failures now say which file and why.

Evidence: `HALO_DMG=1 swift test --filter readOnlyDiskImage` mounted a real read-only image, hidden from Finder: plan and placement both went to the fallback. Bugs below failed first (red run kept in chat): commit cut short, fading ring, stall, key-held reopen, key bounce, button flicker reopen. A one-off window-list read showed the Dock has no window on macOS 27, so the visible Dock is caught by `visibleFrame` only.

**Live checks still owed** (none of these has been run):
- Photos: drag a photo out, pause, drop on JPG. Expect "Getting it from Photos", then the result in Downloads, and an empty `$TMPDIR/Frenzy Promised Files`.
- Mail: same with an attachment. Dragging a message over a mailbox must not open a ring.
- Safari: drag an image, hold the key. Drag the address-bar link, hold the key: expect the notice.
- Open a DMG, drag a file out of it onto JPG: expect it in Downloads plus the reason card.
- `Frenzy.app/Contents/MacOS/Frenzy --worker-crash-test image.to-jpg FILE`: expect CRASH_TEST PASS.
- iCloud: right-click a file, Remove Download, then convert it: expect "Downloading … from iCloud" and no frozen drag.
- Start a long video, close the lid, reopen: expect it finishes or restarts once.
- Quit during a job: expect the question; Finish, Then Quit quits about 4 s after the card.
- Replace the app mid-job (rebuild): expect the "updated or moved" message.
- Pause over the Dock: no ring. Over Chrome: ring only after about 1.2 s. On a folder in Finder until it spring-loads: ring leaves when the new window opens.
- Full-screen Space, Stage Manager, second display, screen edge: ring opens and far wedges work.
- Option drags: watch the log for `Ring opened` twice in one drag; the `appKit= session=` values name the path.
- First drag from Desktop on a Mac with no folder grant: any macOS prompt should come at the drop, not mid-drag. Also no "access data from other apps" prompt.


## 2026-11-07 21:16: live drag e2e 33 of 33
- Fixed: a pause over a Finder drag was "blocked". macOS shows a screen-sized system overlay during Finder drags and the classifier treated it like the Dock. Chrome-app windows over half the screen are now looked through (`PointerTargetClassifier.classify`, test `aScreenSizedSystemOverlayIsSeenThrough`). Live log now shows the Finder window as the target.
- Fixed: e2e driver finds the real list-view file icon (`rowIcon`), so "Finder: ZIP -> Unzip" passes.
- Checked: the "window opened by itself" was the e2e's own `open "$APP"` before check 26 (logged as "Reopen asked by macOS reopen event"). Not a bug. `reopen(from:)` now logs who asked.
- Unit tests: 702 of 702 pass (video suites off). Live e2e: 33 of 33 PASS, no crash reports. No video encoding run.

## 2026-11-07 21:50: first software video test, test data clean-up
- Founder said yes. SoftwareVideoEncodingTests/tinyH264 under scripts/video-safety-probe.sh watch: PASS, 75 KB H.264 file. Hardware encoder clients 0 before, peak 0 (42 samples), 0 after. No panic.
- Founder rule: test data must not stay in the project. Moved 24 GB to the Bin folder "Frenzy test data 2026-11-07". Render tests write to temp unless HALO_SHOTS names a folder; ring PNGs no longer go to docs; the e2e screenshot stays in its temp build folder; new scripts/test.sh moves each run's temp folders to the Bin.
- Fixed a load-only race in EngineOrphanTests.orphan() (it waited for the orphan, not for the exec to /bin/sleep). Full run 702/702 via scripts/test.sh, 0 folders left in temp.

## 2026-11-07 23:10: video done on x264
- Stopped Apple SW HEVC 5 min test after 24 min (too slow). Measured Apple SW H.264 vs x264 on real 1080p (Big Buck Bunny, CC-BY): VMAF 77.8 vs 94.0 at equal size and speed; x264 CRF 20 = 97.1.
- Founder: open source OK. Engine rebuilt GPL with x264 (pinned b35605ac, sha 6eeb8293...), verify checks updated. New X264Compress wired into VideoActions.shrink; HDR keeps Apple HEVC.
- Bugs found and fixed: VBV cap starved hard scenes (worst VMAF 54), so no cap; MP3-in-MP4 invisible to macOS, so only AAC/ALAC copied.
- Long tests via the app action (phone-like stand-in at 26-28 Mbps): 5 min 82% smaller in 63 s; 10 min 81% smaller in 155 s, VMAF 97.2. Hardware encoder 0, no crash.
- Tests 711/711 (new X264CompressTests, engine licence tests now GPL+x264). App rebuilt, DMG 9.8 MB. Lab files (4.8 GB) and engine workspace moved to the Bin.

## 2026-11-07 23:40: MP4 and HEVC buttons on the CPU
- x265 4.1 added to the engine (CMake 4 policy patch, 8+10-bit lib, no SVE). Engine 17 MB, verify passes.
- HEVC button: x265 CRF 20 (VMAF 96.6). MP4 button: x264 CRF 18 (VMAF 97.7). HDR Compress: x265 Main10, HLG kept. Foreign video out (WebM/MKV/AVI to MP4 and HEVC) enabled, leads the ring with MP4.
- Found: my first HDR test clip had no colour box (FFmpeg MOV needs write_colr), so macOS saw SDR; a properly tagged clip kept HDR.
- Tests 714/714. App rebuilt, DMG 12 MB, x264 + x265 licences bundled. Lab moved to the Bin again.

## 2026-11-08 00:40: full test pass, no hardware encoder
- Every video path now encodes with x264 or x265 (incl. 10-bit HDR) in the sandboxed engine (GPL FFmpeg 9.0.2 + x264 b35605ac + x265 4.1, CPU only, no VideoToolbox).
- HDR to MP4 moved off Apple's encoder: Apple's decoder tone-maps via AVVideoComposition, frames go through a FIFO to x264 (ToneMappedMP4.swift). No engine means MediaEngine.missing; Apple's encoder is never a fallback. AVTranscoder's encode path is unreachable.
- Engine flags: -movflags +use_metadata_tags+negative_cts_offsets+write_colr (no faststart), setparams labels untagged SDR as BT.709, rawvideo demuxer (FIFO only), -stats_period 0.2.
- Fixed: B-frames made every frame 50 ms late in Apple's readers (negative_cts_offsets); creation date and camera model lost (QuickTimeTags.swift moves mdta to moov/meta); colour labels missing (write_colr + setparams); AAC timing shift (-avoid_negative_ts removed); MP3-in-MP4 invisible (only AAC/ALAC copied); "Same resolution" too long for the ring (now "Same size").
- Fixtures (AVFixtures.movie, variable-frame-rate clip) now made by ~/.local/bin/ffmpeg CPU encoders. Tests that drove Apple's encoder removed or rewritten (busy-encoder fallback, two canApply HDR tests, export-cancel now passthrough, disk-full now engine + freeSpace hook). "Software video encoding" suite needs FRENZY_APPLE_ENCODER_TESTS=1 too.
- HEIC/AVIF writes in tests throw unless FRENZY_HEIC_TESTS=1 (ImageSupport.swift + fixture writers). Before this, one HEIC test opened the hardware encoder once per normal run (no crash).
- Probe watching: unit run with FRENZY_VIDEO_TESTS=1 711/711, AppleAVE2UserClient peak 0 over 1,936 samples. e2e-actions on the real app 413 PASS, 0 FAIL, 0 SKIP, peak 0.
- Worker self-test checks the engine is GPL with no VideoToolbox encoder. apps/halo/LICENSE added. DMG 12 MB.
- Open: HEIC/AVIF output uses the chip (founder: keep gated, hide, or CPU HEIC via libheif + x265); publish source before giving the app out; live drag e2e rerun result not yet recorded.

## 2026-11-08 00:50: review fixes, final runs
- Independent review (read-only agent) found no path to Apple's video encoder. Fixed: HDR-to-MP4 feeder could hang if the engine failed before opening the pipe (non-blocking open + retry); frame buffer size and format now checked; feeder on its own thread with SIGPIPE blocked; pipe frame rate from the composition (fixed rate); tag move writes before truncating; safe 64-bit box sizes; odd picture sizes rounded to even; WebM/MKV to MP4 keeps date and model, drops GPS; dead encoding export branch replaced by a guard.
- Final: unit run with FRENZY_VIDEO_TESTS=1 711/711, hardware encoder peak 0 (1,994 samples). Every-action test on the final build 413 PASS, 0 FAIL, 0 SKIP, peak 0. Live drag test waits for an idle Mac.

## 2026-11-08 01:05: HEIC/AVIF tested live (founder's yes)
- Unit HEIC/AVIF tests (FRENZY_HEIC_TESTS=1): 38/38 pass, chip peak 1 (3 of 73 samples), no panic.
- Real app every-action run with HEIC: 438 PASS, 2 FAIL (Compress on animated GIF: the app correctly refuses, the test expected a file; test fixed, not yet rerun). HEIC/AVIF jobs 25/27; chip in use in 87 samples, never more than 1 at once. No new panic reports.
- Live drag test collided with this run once (both use the app) and was cancelled when the founder asked to launch the app; still to rerun alone on an idle Mac.
- Rule added to CLAUDE.md and AGENTS.md: HEIC tests alone, under the probe, founder's yes, stop if 2 at once.

## 2026-11-08 02:16: live drag test after ring-lag and card changes
- Run 1: 32/33. Fail #25 "pause then drop in the hub": no "Pause check" was logged, so the pause never registered (timing).
- Run 2: 31/33. #25 passed. Fails #2/#3: the driver's accessibility lookup missed the home window for 5 s, but the app log shows "Home window shown" 0.22 s after launch, and "reopen shows window" passed later in the same run.
- Every check passed in at least one run, and there were no Frenzy crash reports. Read: flaky test timing, not app bugs. Follow-up: harden the driver (longer AX wait at launch, steadier pause for #25) and rerun 3 times.
