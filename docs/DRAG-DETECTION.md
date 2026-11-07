# Drag detection and the ring overlay (HaloDrag)

How Halo notices "a file drag is in progress and the trigger key is held" anywhere on the system, and how the ring
accepts the drop, with **no Accessibility, Input Monitoring or Screen Recording permission**.

## Approach

| Signal | API | Permission | Cost |
|---|---|---|---|
| A mouse press or drag started | `NSEvent.addGlobalMonitorForEvents([.leftMouseDown, .leftMouseDragged, .leftMouseUp])` (+ a local monitor for Halo's own windows) | none (only key events need it) | event-driven, zero when idle |
| Button still down | `NSEvent.pressedMouseButtons & 1` | none | polled |
| Trigger key held | `NSEvent.modifierFlags` OR `CGEventSource.flagsState(.combinedSessionState)`: either counts, so one stale read can't close the ring | none | polled |
| A drag began (and its contents) | `NSPasteboard(name: .drag).changeCount`, then `readObjects(forClasses: [NSURL], options: [.urlReadingFileURLsOnly: true])` | none, no paste prompt (`accessBehavior` is `.alwaysAllow` (2) for the drag pasteboard on macOS 27) | changeCount polled; contents read once per change |
| Cursor | `NSEvent.mouseLocation` | none | on summon |

State machine (`DragTriggerMonitor`):

1. **Idle**: no timer. Only the mouse monitors are installed.
2. **left mouse down** → **armed**. Record `baseline = drag pasteboard changeCount` and start a 60 Hz timer
   (`.common` run-loop modes, 25 % tolerance so wake-ups can coalesce). It runs only while the button is down.
3. Each tick (and each `leftMouseDragged`): if the button reads up twice running, or a mouse-up event came → end the session
   (dismiss if summoned, stop the timer). One reading proves nothing in a background app.
   If `changeCount != baseline`, a drag wrote the pasteboard after this press: read it once per change count.
   Finder's `file:///.file/id=…` reference URLs are resolved to path URLs.
4. A file drag is live AND the trigger is held AND not already summoned → `onSummon(urls, NSEvent.mouseLocation)`.
5. While summoned: if the trigger is released for longer than `releaseGracePeriod` (0.3 s), dismiss
   (`.triggerReleased`), unless the pointer is on a wedge (`holdsOpen`): letting go a moment before the mouse must not drop the
   file on what's underneath. A late tick (0.25 s or more) restarts the grace instead of spending it. Mouse up → dismiss
   (`.dragEnded`).
6. **Reopening in one drag:** after the ring closes, the key must be seen up at least `reopenCooldown` (0.6 s) later before it
   can open again, so a relaxed finger or a bad read doesn't bloom it twice. A session that ends with a ring up and resumes
   within 1.5 s is the same drag and stays closed. Logs: `Ring opened: key|pause` and `Ring dismissed: <reason>`, both with how
   each source read the keys (`appKit=… session=…`), so a live log says which path a double open took.

**Stale pasteboards:** the drag pasteboard keeps the last drag's contents forever. Because the baseline is taken at
mouse-down, old contents, or a pasteboard written while no button is down, never count as a drag. Window drags and
text selections don't write the drag pasteboard, and non-file drags (text, web images) carry no file URLs, so neither
summons the ring. If the mouse-down was missed and the first event seen is a `leftMouseDragged`, the baseline falls
back to the change count recorded when the previous press ended.

**Why not `flagsChanged`/`keyDown` monitors:** global monitors for key-related events need Accessibility. They
*install* without any error even with zero permissions (tested: `addGlobalMonitorForEvents(.keyDown)` returns non-nil
and then delivers nothing). So a successful install proves nothing. Polling `NSEvent.modifierFlags` during the drag is
permission-free and simpler.

**A pause isn't always a request (`hasPaused`).** Blocked outright: the Dock strip and menu bar (outside `visibleFrame`), and
Dock, Stage Manager and Control Center windows. Over ANOTHER app's window it takes `otherAppPauseDuration` (1.2 s): hesitating
over a browser's drop zone usually means "about to drop here". Over the source app, the Desktop or Frenzy: the normal 0.4 s.
`CGWindowListCopyWindowInfo` gives owner, layer and bounds with no permission; it's read once per still spell, never per tick,
and layers of 100 or more are seen through (the drag image is at 500). Spring-loading: a new window under a still pointer closes
the pause ring (`.underlyingChanged`), checked 4 times a second. **Limits:** without Accessibility nothing can see that the
pointer is on a folder, so the ring can still open first when hovering one; a folder that opens in the same window goes
unnoticed (the ring's hub lets the drag through and it closes on leaving). On macOS 27 the Dock has no window in the list, so a
visible Dock is caught by `visibleFrame` but an auto-hidden one isn't. A pause ring measures "left" from the ring's centre as
well as from where it opened, or at a screen edge, where the ring is pushed away, far wedges closed it on the way there.

## Evidence (macOS 27.0.1, arm64)

| Check | Result |
|---|---|
| `scripts/drag-harness.sh --zero-permission`: the monitor and ring run as their own `.app` launched with `open` (own TCC identity). Its log shows `AX=false listen=false post=false`. The terminal process posts a real CGEvent drag of a temp file from its own window, holding Option | **PASS**: the monitor fired `SUMMON` with the right path. The ring panel got `draggingEntered`/`Updated` (hover segment 0) and then `performDragOperation` (`DROP image.to-jpg [path]`) from a drag owned by *another process*. `DISMISS dragEnded` followed |
| `scripts/drag-harness.sh --auto` (same process) | PASS: summon, hover, drop |
| `scripts/drag-harness.sh --auto --release`: Option released mid-drag | PASS: `DISMISS triggerReleased` about 0.2 s after release (grace period), no drop |
| A window ordered in under an in-progress drag | Works: the panel appears at the cursor mid-drag and receives `draggingEntered` on the next mouse movement. No workaround needed. If the cursor doesn't move, nothing is sent, but the cursor starts in the centre, which rejects drops anyway |
| `HALO_LIVE=1 swift test … --filter LiveOverlayTests` | Panel at window level 102, never key, Halo never active, frontmost app unchanged; clamped inside `visibleFrame` on every display; the drag pasteboard reads without a prompt |

Synthetic events (`--auto`) need Accessibility for whatever runs the script (`CGPreflightPostEventAccess`). Without
it the harness exits 2 with that message. Manual mode (`scripts/drag-harness.sh`, drag something yourself while
holding Option) needs nothing. Note: while the Mac is locked, `CGWindowListCopyWindowInfo` bounds are scaled (about
0.9) by the lock-screen effect. The live test detects the `loginwindow` shield and only compares shape then.

## Overlay panel (`RingOverlayController`)

| Setting | Why |
|---|---|
| `NSPanel` with `[.borderless, .nonactivatingPanel]` at init; `RingPanel` returns false for `canBecomeKey/Main`; shown with `orderFrontRegardless()` | Never activates Halo or steals focus from the source app (verified live) |
| Level `popUpMenu + 1` = **102** | Above the menu bar (24), status items (25) and pop-up menus (101). **Below the drag image (`kCGDraggingWindowLevel` = 500)**, so the dragged file's icon stays on top of the ring. `.screenSaver` (1000) would hide the drag image under the ring |
| `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | Appears on every Space, over full-screen apps; stays put in Mission Control; skipped by Cmd-` |
| `isOpaque = false`, `.clear` background, `hasShadow = false`, `animationBehavior = .none`, `hidesOnDeactivate = false` | No shadow halo around the transparent square; no system zoom animation; Halo is never active, so it must not hide on deactivate |
| `ignoresMouseEvents = false` (explicit) plus a 2/255-alpha disc drawn by the drop view | The whole ring area is a drag destination even where RingView draws nothing |
| `RingDropTargetView` above the `NSHostingView` | Always the hit-test winner, so SwiftUI never intercepts the drag. Registered for `.fileURL` + `NSFilePromiseReceiver.readableDraggedTypes` |
| Frame | `OverlayGeometry.panelFrame`: centred on the cursor, clamped to the `visibleFrame` of the screen containing it (half-open rects so display seams are unambiguous; nearest screen as fallback), origin snapped to the backing pixel grid |

Drop handling: `draggingEntered/Updated` converts `draggingLocation` to the drop view (y up), flips to top-left
coordinates and calls `RingGeometry.index`. A segment returns `.copy` and sets `model.hoveredIndex`. The centre and
the corners beyond `outerRadius + slop` return `[]` (the file springs back). `performDragOperation` reads the URLs,
sets `.committing(id)`, calls `onDrop` on the next main-loop turn (so the source's drag loop finishes promptly), and
then runs `.dismissing` → `.hidden`. While `.dismissing`, drops are refused.

Phase timing (`RingOverlayTiming.standard`) is taken from HaloUI's `RingMotion`: `.presenting` → `.shown` after
`presentDuration`, `.committing` → `.dismissing` after `commitDuration` (0.34 s), then `.hidden` after
`dismissDuration` (0.16 s). Drops are accepted during `.presenting` too. With Reduce Motion on
(`NSWorkspace.accessibilityDisplayShouldReduceMotion`), `.reducedMotion` is used: present 0, commit 0.15, dismiss 0.15.

`DragCoordinator`: when the poll sees the button come up while the cursor is over the ring, it waits up to
`dropGracePeriod` (0.5 s) for `performDragOperation` before dismissing. In practice the drop arrived about 8 ms
before the poll noticed the button release.

## File promises (Mail, Photos, some browsers)

On by default since 2026-11-04 (`Integration.makeMonitor`), **not verified with a real drag**. Promise-only drags carry
`com.apple.NSFilePromiseItemMetaData` and promised types but no URL until a destination accepts the drop. The monitor summons with
`[]` URLs; `onSummonPayload` and `DragCoordinator.promisedItemsFor` get the types. On drop, `receivePromisedFiles(atDestination:)`
writes into `promiseDestination/<uuid>/`. See ARCHITECTURE.md for where outputs go. Older promises name extensions, not types;
`normalisedType` handles both. `dropOperation` answers with what the source still allows: Control narrows a Finder drag to "link",
and answering `.copy` then made AppKit refuse every drop. It never answers `.move`.

## Hardening notes and known edge cases

- **Secure input** (password fields, some terminals): only key-event monitors are blocked. Mouse monitors,
  `modifierFlags`, `pressedMouseButtons` and the pasteboard keep working. A missed mouse-down falls back to arming
  on `leftMouseDragged`.
- **Sandbox**: Halo is not sandboxed. A sandboxed build could still read the drag pasteboard, but it would have no
  access to the files until the actual drop (the drop grants a sandbox extension). Conversions only use URLs from
  `performDragOperation`, so that path stays correct.
- **Stage Manager / Mission Control / full-screen**: covered by the level and collection behaviour above. Not
  exercised live in those modes (no human to switch Spaces); expected to work by the documented behaviours.
- **External displays / Retina**: geometry is unit-tested with side-by-side, stacked and negative-origin screens and
  1x/2x pixel snapping. Live: clamped correctly on the one built-in display present.
- **Option semantics in the source**: holding Option during a Finder drag means "copy". The ring returns `.copy`,
  so nothing conflicts. Drops elsewhere behave as usual.
- **Trackpad drag lock / three-finger drag**: these synthesize left-button state, so they should work. Not verified.
- **Drags that don't write the drag pasteboard** (rare custom drag loops) are invisible to Halo by design.
- **Drop in a ring corner**: the panel is square, so drops in the corner areas outside the ring are refused and spring
  back instead of reaching the window underneath (a small area).
- **Battery**: no timer while idle. 60 Hz only while the left button is down; the drag pasteboard is read once per drag.

## Running

```
swift test -j 4 --scratch-path .build/drag --filter HaloDragTests \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
HALO_LIVE=1 swift test …same flags… --filter LiveOverlayTests   # shows an invisible panel briefly
scripts/drag-harness.sh                    # manual, no permissions
scripts/drag-harness.sh --auto [--release] # needs Accessibility for the terminal
scripts/drag-harness.sh --zero-permission  # monitor as its own unprivileged .app; terminal posts events
```
