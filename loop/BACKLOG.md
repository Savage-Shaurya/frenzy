# Halo backlog

Status marks: `[ ]` todo · `[~]` in progress (say who/when) · `[x]` done (date, evidence in LOG) · `[-]` dropped (why).
Priority: P0 = broken or confusing for every user · P1 = core experience · P2 = breadth · P3 = later.
Re-prioritise honestly as you learn. Add new items at the right priority with a one-line "why".

## P0: it must work, visibly, for a first-time user
- [~] **B3. A real Halo window.** (iter 2, 2026-11-01: built and verified offline. The LIVE e2e has NOT passed yet:
      the screen was locked for the whole run.) Done: `HaloUI/HomeView.swift` has a drop zone that needs no trigger key,
      with a full-colour hero ring, Choose Files… (⌘O, as a sheet), a format grid from the real registry, live job rows
      (working / Done / failed + dismiss), and Recent (20 entries, Quick Look thumbnails, Open / Show in Finder,
      keyboard focus, drag out). It opens at launch (not as a login item), on reopen, from the menu and after
      onboarding. A hidden main menu gives ⌘W, ⌘Q and ⌘,. The e2e home scenarios are written. **Next:**
      `scripts/e2e.sh --no-screenshot` on an UNLOCKED idle Mac; fix what fails; take real window screenshots (Quick Look
      thumbnails don't render offscreen); re-score with design-reviewer + ui-craft against CleanShot X, Raycast and
      Dropover (supervisor: not done below 8/10); then one honest website line about the window.
- [~] **B4. Result card + honest progress.** (iter 3 built most of it, then the run died on the Claude session limit
      with nothing logged; iter 9, 2026-11-01, finished, fixed and verified it offline. LIVE check NOT done: screen locked.)
      Done: `HaloUI/ResultFacts.swift` (`ConversionResult`: measured before → after size, folder, failures; `JobStage`:
      plain stage lines, first-run OCR warning, "Still working" after 8 s at 0 %); `ToastCenter` cards: progress with
      input thumbnail + Cancel, a "Finishing…" step without Cancel, result with thumbnail, name, size, "Saved in …",
      partial failures in orange on their own line, Open / Show in Finder / Copy, drag out, double-click to open,
      auto-hide after 8 s held while hovered, at most 3 cards, neutral grey notices (B4a), spring insert/remove, one
      check bounce, Reduce Motion respected. Design: 3 rounds, last round Clarity 8, Hierarchy 7, Craft 7, Motion 7,
      Material 7, Typography 7, Feedback 8, Delight 6, Accessibility 7, Honesty 8; round-3 fixes applied, not
      re-scored. **Next:** watch a real drop on an unlocked Mac (card position, hover hold, drag into Finder, Quick Look
      thumbnail), take a real screenshot, re-score.
- [x] **B4b. Stage line for jobs that stall after starting.** (iter 10 wrote it and died on the usage limit unlogged;
      iter 17, 2026-11-01, reviewed, fixed and verified it.) `JobStage.line(sinceProgress:)` says "Still working on this
      step…" / "Still reading the text…" after 8 s without movement at any fraction, and the first-OCR "about a minute"
      promise stops after 75 s. A 1 s ticker re-checks; the line follows the newest fraction (`progress.latest`), even
      moves too small to redraw the bar. Tests: `aJobStalledPartwaySaysSo`, `theFirstRecognitionNeverOverstaysItsPromise`.
- [ ] **B4c. Keyboard path to the card (optional).** The card never takes focus by design; keyboard users use the
      main window. Consider a global shortcut that opens the newest result. Low priority.
- [~] **B7. Silent drags (audit 2026-11-04).** Built 2026-11-04 with C3: a ring for promises, a notice for bare links and unknown types. Live drags not run.
- [~] **B8. Read-only source folder (audit 2026-11-04).** Built 2026-11-04: checked before the work, saved in Downloads, card says why. Placement proven on a real read-only disk image; the whole app path not run.
- [~] **B9. Real-world robustness (2026-11-04).** One bad file no longer fails the rest; memory, replaced-app and sleep each have their own path; pause false positives; double open. Code and unit tests done. Needs the founder's live checks, listed in LOG. Unfixed: HomeView and the menu-bar icon take real files only, so a Photos drag there still does nothing (HaloUI, StatusDropView).
- [ ] **C6. Format gaps (audit 2026-11-04).** No WebM, MKV, AVI, OGG or Opus in; no MP3 or WebP out; no PDF to Word; no .tgz. Needs a decision on the Apple-frameworks-only rule.
- [x] **R5. No-key trigger (2026-11-04).** Pause mid-drag opens the ring. Shake is still an option if pause misfires in real use.
- [ ] **V1. Compress quality (2026-11-04).** Keeps neither 4K nor all audio tracks and says nothing. Keep resolution by default, tell the user what changed, add size choices and a preview of the result size.
- [ ] **D1. UI redesign (founder, 2026-11-04).** "It should have a billion-dollar kind of feel." One brand, real halo ring, popover over tall window. Judge live, with the founder.
- [x] **B5. e2e must use real Finder/Desktop drags.** (done 2026-11-04, LOG founder test.) (iter 2: e2e refuses a locked screen with exit 4, backs up
      and restores the founder's defaults, and fails on refused drops in the home scenarios.) Add scenarios that drag a `halo-test-*` file from the
      Desktop (via Finder's AX tree or `~/Desktop` icon positions) with Option, and verify the output exists
      60 s later. Make the e2e driver fail when the drop is refused (it reported PASS with op=0 once).
- [~] **B6. First-run onboarding that teaches by doing.** (iter 17, 2026-11-01: built and verified offline. LIVE drag
      NOT checked: screen locked.) Done: step 3 "Try it once" (`HaloUI/OnboardingTryIt.swift`): Halo draws
      `Halo sample.png` into `~/Library/Application Support/Halo/Try Halo`; the tile is a real file drag source
      (`FileDragArea`); a drop on the ring converts it through the normal job path and the step celebrates (output tile
      springs in, check badge, haptic, Show in Finder); "Skip" until success, then "Start Using Halo"; paused notice with
      Resume; VoiceOver action "Convert to JPG"; reopening onboarding from closed starts again at Welcome. Design: 3
      rounds, last Clarity 9, Hierarchy 8, Craft 8, Motion 8, Material 8, Typography 8, Feedback 8, Delight 7, A11y 8,
      Honesty 9. **Next:** on an unlocked Mac, drag the sample with Option from the onboarding window and confirm the
      ring opens (the drag starts inside Halo's own window: local monitor + 60 Hz poll should catch it, unproven live),
      the drop converts, the step flips to done; take a real screenshot. Then add an e2e scenario for it.
- [ ] **B6a. Onboarding delight (Delight 7).** Nothing marks the moment the ring opens; the waiting chips are static.
      Idea: light chip 2 when the trigger key is held during the sample drag, chip 3 when the ring is up (needs a
      summon callback from AppController). Also: repeat tries pile up "Halo sample 2.jpg"… in Try Halo; consider
      clearing old practice outputs (only Halo's own folder) when onboarding opens.

- [ ] **B2b. Drop files onto the menu-bar icon** (iter 1 built it, not verified). `StatusDropView` + `showDropMenu` exist,
      but a synthetic drag onto the icon never reached Halo ("Icon drag entered" not logged), and a synthetic click opens
      no status item's menu on this macOS (a bare probe item behaves the same). Next: test with a real drag the next time
      the founder is around, or try `button.window` registration with a window delegate (`NSStatusBarWindow`, delegate
      nil). Make e2e icon rows gating once a reliable method exists. Never claim the feature in copy before that.
- [ ] **B2c. e2e click check via AXPress** on the status item, verified by "Menu opened" (`menuWillOpen`) in Halo's log.
- [x] **T1. Flaky timing test.** (iter 3 wrote it, iter 9 verified: 4x input must cost under 6x the time, best of 3 runs; green in 5 full runs.) `DocumentHardeningTests.cleanIsLinear("b-then-i")` failed once against its 0.5 s
      wall-clock budget under full-suite load, and passes 3/3 alone. Compare the 1x vs 2x input time instead.
- [x] **B3b. Main window polish** (iter 26, 2026-11-02, LOG iteration 26). Balanced grid (no lone last tile, 9 = 3 × 3),
      the card hugs the grid while choosing, white-on-colour icon badges at 4.5:1 or better, digit keys 1 to 9 and Return
      pick tiles, 4.5:1 subtitles, "Show file previews" setting (window, cards and ring centre), and the "Choose Files…"
      overflow fixed. Design round 3: every line 8 or higher. Live keys and spring NOT watched (screen locked). Menu
      Recent thumbnails stay in R3.
- [x] **B3c. Window leftovers** (iter 27, 2026-11-02, LOG iteration 27). Icon generator scaled its shadows (small
      icons had a square haze); compact hero labels 11 pt and clear their petals by 4 pt or more (tested); a custom
      progress ring replaces the faint system spinner; Recent rests on whole rows with a peek and a count; failed rows
      get Try Again; ⌘Return reveals; row details at 4.5:1. Declined (DECISIONS): moving the native stepper, and badge
      tone variation. Design round 2: all 8 or higher except Delight 7. Live Try Again NOT watched (screen locked).
- [x] **B3d. Window delight + peek** (iter 29, 2026-11-02, LOG iteration 29). A result that just finished takes its
      Done row's slot with a soft green wash and the same check on its thumbnail (held 0.7 s, faded 1.3 s), the thumbnail
      springs in; spent once shown, never replayed on reopen. The peek is one soft ghost (36 pt, three-column fade, no
      cut glyphs); no fade when rows fit. Header chip glyph 15 pt, header height unchanged. Design round 3: every line 8.
      The fade and spring were NOT watched live (screen locked).
- [x] **B3e. Hero label spills its petal** (iter 30, 2026-11-02, LOG iteration 30). The test measured a straight chord,
      but four of six petals were tilted (resting "Compress" too). The hero is now turned half a petal, so the long titles
      take the level 12 and 6 o'clock petals. Petals are reordered so near colours never touch, and one placement rule is
      checked against the real petal outline (4.75 pt clearance or more). The lit petal is a calm wash instead of solid
      (Hierarchy). Design round 3: all 8 except Feedback 7, whose fix (dark lifted under lit) was applied, not re-scored.
      The walk was NOT watched live (screen locked).
- [ ] **B3f. Hero leftovers (iter 30 review, NICE).** Dark-mode centre disc nearly matches the panel (a faint rim
      would help); dark rest PDF and M4A are both muted maroon; the walk never pauses when the window isn't key (saves
      redraws); compact and regular label offsets swap without easing when Recent first gets a row. Low priority.
- [x] **B4a. Neutral notice style.** (iter 9: `showNotice` has its own grey info style.) The hidden-icon notice uses `showFailure` (failure styling); give ToastCenter an
      info style (fold into B4).

## P1: the hero experience
- [~] **R1. Ring v2 redesign.** (iter 19 built most of it and died on the usage limit unlogged; iter 25, 2026-11-02,
      recovered it from snapshots, reviewed, finished and verified offline. LIVE drag NOT watched: Mac in use, then locked.)
      Done: centre shows the dragged item (type icon at once with no disk access, then Finder's icon, size or folder
      count capped at "1,000+ items", then the Quick Look thumbnail, all off-main and cancellable; up to 3 icons fan out
      for several); resting wedges are neutral glass with monochrome label-coloured icons, no dimming; the hovered wedge
      fills with its category colour darkened to 4.5:1 or better for white text (tested in 4 appearances) with a lit rim;
      dense rings show the hovered wedge's subtitle in the centre; two choices read left to right; snappier bloom;
      Force Touch tick on each wedge change; **"More" wedge** (system blue, "N more in Halo") when actions exceed the
      ring size, which opens the window listing every choice (a test proves no drop fits more than 11). Design: 3
      rounds, last Clarity 8, Hierarchy 8, Craft 8, Motion 8, Material 8, Typography 8, Feedback 8, Delight 7, A11y 8,
      Honesty 8 (round 3 viewed 5 of 16 shots, so provisional). **Next:** on an unlocked idle Mac, drag a real photo
      with Option: confirm the thumbnail lands during the bloom, the haptic ticks, and a drop on "More" (set ring size 4)
      opens the window with the files' choices; take a real screenshot.
- [x] **R1a. Ring delight + dense polish** (iter 28, 2026-11-02, LOG iteration 28). Drop moment: the centre fills with
      the chosen colour and one ripple in that colour leaves it (none under Reduce Motion), and VoiceOver says
      "Converting to …". Titles share one size per ring (the default ring size keeps 11 pt). Archive is green app-wide
      (brown was mud). Dark resting labels reach 4.5:1 or better with a faint halo. Design round 3: every line 8.
      The ripple's motion was NOT watched live (screen locked).
- [ ] **R1b. Red and pink sit close when lit.** PDF red and audio pink are about 10° apart by hue (they differ in
      lightness). They rarely share a drop; if a mixed PDF + audio drop looks confusing live, move audio to a clearer hue.
- [ ] **R2. Ring placement.** Never covers the drag source awkwardly; edge-of-screen and multi-display aware;
      appears within 100 ms of the key press; stays responsive with no pointer movement
      (`wantsPeriodicDraggingUpdates` / entry handling, the e2e "no hover" miss).
- [ ] **R3. Recents shelf.** (iter 2: the main window keeps 20 entries with thumbnails, drag out and Clear. The menu
      still shows only icons.) Menu-bar menu and main window show the last 20 results with thumbnails; drag out;
      clear history; respects privacy (paths stored locally only).
- [ ] **R4. Settings redesign.** Native, minimal, grouped: trigger key with live test, ring size, sounds/haptics,
      where results go (next to original / Downloads / ask), launch at login, privacy note.

## P2: breadth
- [x] **C1. Zip / Unzip** (iter 18, 2026-11-01, LOG iteration 18). Own ZIP code on Compression in the worker; caps,
      unsafe-path / password / overlap / CRC refusals, quarantine kept, 16 tests + `ditto`/`unzip -t` interop, proven
      through the real sandboxed worker. Live ring drag of a folder NOT watched (screen locked).
- [ ] **C1b. Zip64.** Archives over 4 GB or 65,535 items are refused with a plain message. Add Zip64 read and write
      (video folders hit 4 GB fast). Also check free space on the destination volume, not only the worker's.
- [ ] **C1c. Unzip edge honesty.** Links are skipped silently and apps inside zips can't run (nothing placed is
      executable). Consider a card line ("2 links were left out") and an "Open in Archive Utility" hint for app zips.
- [~] **C2. Folders.** (iter 18: a dropped folder now resolves and gets Zip; "Choose Files…" accepts folders.) Still to
      do: "Convert everything inside to…" (images → JPG, etc.).
- [~] **C3. Photos / Mail drags.** (2026-11-04: built with unit tests using a fake source app; NOT tried with real Photos,
      Mail or Safari.) File promises with outputs in Downloads and the result card showing where. "Configurable" not done.
- [ ] **C4. More formats** where macOS can encode them: AVIF (check `CGImageDestinationCopyTypeIdentifiers`),
      ICNS / favicon set from an image, PDF → JPG pages, images → contact sheet PDF, video → frames.
- [ ] **C5. Clipboard.** "Paste to Halo": a menu item / shortcut that converts what's on the clipboard
      (e.g. screenshot → text, image → JPG file in Downloads).

## P3: other ways in
- [ ] **E1. Finder Quick Action / Services** "Convert with Halo".
- [ ] **E2. Shortcuts / App Intents** for every action.
- [ ] **E3. Universal (Intel) build check**, Developer ID + notarization path documented (founder must buy the ID).

## Done
(move items here with date and LOG reference)
- [x] **B1. Vanished result** (2026-11-01, LOG iteration 1). Not a Halo deletion: Finder logged a user move at
      15:58:48.85 inside the vanish window. Fixed the scratch-shaped output name bug; regression tests cover every
      cleanup path.
- [x] **B2. Menu-bar icon visibility** (2026-11-01, LOG iteration 1). `{38, 0}` was measured before layout; live it is
      `{{1098, 949}, {38, 33}}`, visible right of the notch. Halo now logs the real state and tells the user if macOS
      hides it. (Drop on icon split out as B2b.)
