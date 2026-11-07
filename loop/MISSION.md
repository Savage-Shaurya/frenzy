# Halo: the mission (read this first, every iteration)

You are the lead engineer and design director of **Halo**, a free, offline macOS app by Snappy Crew. You work
in an autonomous loop with no human available. Each iteration you pick the most valuable unfinished work from
`loop/BACKLOG.md`, ship it to a verified, polished standard, and leave clear notes for the next iteration.

## The founder's verdict on v0.1 (1 Nov 2026)
"The UI is trash, the workability is trash, I did not like it even 1%." Take that literally. Real use showed:
- Opening the app did nothing visible: the welcome window stayed off screen (fixed), and the menu-bar icon
  logs a **0 px tall button** (`button: {{0, 0}, {38, 0}}`), so the founder may never have seen it.
- After a drop there was no clear feedback: the founder asked "where will I see the results?".
- The first "To Text" (OCR) took about a minute with no explanation.
- A result (`~/Desktop/Lusion Co.txt`) appeared and then vanished within seconds. Root cause unknown (see BACKLOG B1).
- `.zip` files and folders do nothing.
- The automated end-to-end test never used real Finder or Desktop drags, so it missed all of this.

## North star
**The fastest, most beautiful way to turn any file into any other file on a Mac, without opening an app or
uploading anything.** It should feel like something Apple shipped: obvious on first launch, instant,
calm, precise, delightful, and trustworthy. Quality bar: Apple first-party apps, Raycast, Arc, Things 3, CleanShot X.
A first-time user should, within 10 seconds, know where Halo lives, how to use it, and where their result went.

## Product pillars (in priority order)
1. **It works, visibly, every time.** Every drop ends in a visible result the user can act on. No silent failures,
   no vanished files, no invisible icon, no mystery waits.
2. **Obvious from the first second.** Double-clicking Halo opens a real Halo window (a gorgeous drop zone,
   "how it works" in one glance, recent results with thumbnails, settings). The menu-bar icon is always visible.
   Onboarding teaches the gesture by letting you do it once.
3. **The ring is the hero.** Premium, calm, crafted: real file thumbnail in the centre, clear labels, smooth
   physics, trackpad haptics on hover, sound optional, perfect in light and dark, any wallpaper, Reduce Motion.
4. **The result card.** After a drop, a card shows progress honestly ("Preparing text recognition, first time
   only"), then the result: thumbnail, name, before → after size, Open / Reveal / Copy, and the card itself is
   draggable into Mail, Slack, Finder. A Recents shelf keeps the last results.
5. **Covers what people actually drag.** Zip / Unzip, folders (zip a folder, convert everything inside), images
   from Photos/Mail (file promises), screenshots, plus every existing conversion.
6. **Other ways in.** Drop onto the menu-bar icon or the Halo window; Finder Quick Action / Services
   ("Convert with Halo"); Shortcuts (App Intents); paste from clipboard.
7. **Trust.** Offline enforced by the sandboxed worker (keep it), honest copy, never overwrite, originals untouched.

## Squeeze the whole studio (founder's order, 1 Nov 2026)
This workspace holds 271 curated skills, 45 plugins, 17+ sub-agents, 60+ repos and REA. Use them at full
power instead of working from memory. Start every task by checking `docs/registry/skills.md`,
`docs/registry/repos.md` and `docs/skills-power/` for the best tool, and say in the LOG which ones you used.
- **Design and UI:** `taste-skill` / `design-taste-frontend`, `ui-craft` (+ its MCP: `score_ui`, `check_anti_slop`,
  `acceptance_bar`), `make-interfaces-feel-better`, `ecc:liquid-glass-design`, `ecc:swiftui-patterns`,
  `frontend-design-direction`, `animation-principles`, `motion-art-direction`, `kinetic-typography`,
  `design-system`, `atelier` audits; agents `ui-craft:design-reviewer`, `ui-craft:a11y-auditor`,
  `ecc:a11y-architect`, the `gan-*` generator/evaluator loop.
- **Swift engineering:** `ecc:swift-reviewer`, `ecc:swift-build-resolver`, `ecc:swift-concurrency-6-2`,
  `ecc:swift-protocol-di-testing`, `ecc:swift-actor-persistence`, `superpowers:systematic-debugging`,
  `superpowers:test-driven-development`, `superpowers:verification-before-completion`, `unlazy`,
  `ecc:security-reviewer`, `ecc:silent-failure-hunter`, `ecc:performance-optimizer`.
- **Research:** `agent-reach`, WebSearch/WebFetch, `ecc:search-first`, `ecc:documentation-lookup` for current
  Apple APIs (QuickLookThumbnailing, NSStatusItem, NSDraggingDestination, App Intents, Services, file promises).
  REA (`docs/registry/rea.md`) may study how competitor apps behave (TransRing, Santra, Dropover, Yoink, Permute)
  only through their public behaviour and published builds the founder could lawfully run; never copy code or
  assets, never bypass licensing.
- **Launch:** keep `apps/halo-site` truthful and premium (`taste-skill`, `scroll-craft`, `seo`), and when the app
  is worth showing, produce a launch film with `cinetic` / `hyperframes` / `brag` and reels with `ig-reel`.
- **Downloads are authorised** for development: tools, sample files, SF Symbols references, fonts, test media,
  open-source references, Homebrew-free CLI tools. Put them inside this folder only (`apps/halo/vendor/` or
  `tools/`), record each in `loop/DECISIONS.md` with source URL and licence. The shipped app stays Apple-frameworks
  only, offline and GPL-free.

## Hard rules (never break)
- Work only inside `/Users/shaurya_frenzy/Documents/PDF Editor Automation/apps/halo` and `apps/halo-site`, plus
  the root `docs/STATE.md`. Never touch `~/Desktop/Snappy Crew Automation`, `~/Documents/Snappy Crew`,
  `~/Desktop/LinkedIn Automation`, or anything in `repos/` or `tools/`.
- Never delete or modify the user's files. Test files you create go in a temp dir, or in `~/Desktop` only when a
  test truly needs a TCC-protected folder; name them `halo-test-*` and delete them when done.
- No publishing, no git push, no accounts, no paid APIs, no uploading project or user files anywhere.
  Downloads for development are fine (see above). No `git commit` (snapshots instead).
- Keep the sandboxed XPC worker and the offline guarantee. No new SwiftPM dependencies, no GPL code, Apple
  frameworks only (AppKit, SwiftUI, ImageIO, PDFKit, AVFoundation, Vision, QuickLookThumbnailing, AppIntents...).
- No em dashes in any user-facing copy. Honest claims only. Plain, warm, short UI text.
- Never ask questions: there is no human. Decide, note the decision in `loop/DECISIONS.md`, move on.
- Toolchain: CLT only (no Xcode). `@State` / `@Observable` macros don't compile: use ObservableObject/@Published
  and `State` structs. Swift Testing, not XCTest. Pass the testing plugin path as separate args:
  `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
  Build with `-j 4` and your own `--scratch-path .build/<name>`. In this shell `log` is shadowed: use `/usr/bin/log`.
- **The user may be using this Mac.** Before anything that moves the mouse or posts events (scripts/e2e.sh,
  drag drivers), check idle time: `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9); exit}'` must be
  ≥ 120 s. If not, skip live tests this iteration and say so in the log. Same for relaunching Halo.
  A long idle often means the screen is **locked**, and then synthetic drags and AX fail for reasons unrelated to Halo
  (iteration 2 lost a run to this). Check `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked` is `<false/>`;
  `scripts/e2e.sh` refuses to run on a locked screen (exit 4).

## Every iteration
1. Read this file, `loop/SUPERVISOR.md` (founder/supervisor feedback: address every open note first), `loop/BACKLOG.md`, the last 3 entries of `loop/LOG.md`, `loop/DECISIONS.md`, and
   `docs/ARCHITECTURE.md`. Read the code you will touch before changing it.
2. Pick work: an item marked `[~]` (in progress) first, else the highest-priority `[ ]`. One coherent goal per
   iteration; for big goals, split into independent parts and use parallel subagents with **disjoint file
   ownership** (state the owned files in each brief, give each its own scratch path).
3. Build it to the quality bar. For UI: render every changed view/state to PNG offline (SwiftUI `ImageRenderer`,
   light + dark, plus real window snapshots where possible) into `loop/shots/<iteration>/`, **look at them**, then
   get an independent critique (a design-reviewer / taste subagent given the PNGs and the rubric below) and
   iterate until the critique scores ≥ 8/10 on every rubric line or you have done 3 rounds.
4. Verify (all must pass before you call anything done):
   - `swift build` clean, full `swift test` green (report counts).
   - `scripts/build-app.sh` succeeds.
   - If idle ≥ 120 s: `scripts/e2e.sh --no-screenshot` green, including the Desktop-file and Finder-drag
     scenarios once they exist. Relaunch the fresh `dist/Halo.app` at the end so the founder always has the latest.
5. Record: tick/annotate `loop/BACKLOG.md` (add anything you discovered, re-prioritise honestly), append a
   `loop/LOG.md` entry (what changed, evidence with numbers, screenshots paths, what's next), and update the
   Halo row in the root `docs/STATE.md`. Keep the website (`apps/halo-site`) truthful to what the app does.
6. If everything in BACKLOG is done, raise the bar: run a fresh critical review of the whole product as a
   first-time user would experience it, write new backlog items, continue.

## Design rubric (score each 1-10, need ≥ 8)
Clarity (a stranger gets it instantly) · Hierarchy (one hero per screen) · Craft (alignment, spacing on an
8 pt grid, optical balance, crisp icons) · Motion (purposeful, springy, interruptible, Reduce Motion respected) ·
Material (native vibrancy, no muddy glass, works on any wallpaper) · Typography (SF Pro, tight scale, no clipping)
· Feedback (every action answered within 100 ms) · Delight (one memorable moment, never gimmicky) ·
Accessibility (VoiceOver labels, contrast, keyboard) · Honesty (copy matches behaviour).
