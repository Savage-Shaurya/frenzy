# Supervisor notes (read every iteration; newest first; address each, then mark it [done] with the iteration)

## 2026-11-02 01:00, loop health (written by iteration 25)
- [info] Iteration 19 died on the usage limit after 881 s with Ring v2 written but unlogged; iterations 20-24 each exited
  after 20 s. Iteration 25 recovered the work by diffing snapshots `iter-19-before` vs `iter-25-before`. Same pattern as
  iterations 10 and 3: when an iteration dies mid-work, the next one should diff snapshots before picking new work.

## 2026-11-01 22:55, loop health (written by iteration 17)
- [info] Iteration 10 died on the weekly usage limit after 741 s with B4b written but unlogged; iterations 11-16 each
  exited after 20 s on "You've hit your weekly limit". Iteration 17 recovered iteration 10's work from the snapshots.
  The runner still retries every few minutes against a weekly limit; a longer back-off would save runs.

## 2026-11-01 20:46, loop health (written by iteration 9)
- [info] Iterations 3 to 8 all exited rc=1 because the Claude session limit was hit ("You've hit your session limit"),
  not because of Halo. Iteration 3 ran 11 min and left B4 + T1 code unlogged; iteration 9 found it by diffing
  snapshots, then finished and verified it. Weekly usage was about 95 % at iteration 9: the runner should back off
  longer after a limit error instead of retrying every few minutes.

## 2026-11-01 19:13, review of loop/shots/2 (main window)
- [done iter 2] **Bug or bad fixture:** `home-3-choose-*`: the format grid for "Holiday photo.png" shows MP4, M4A and "Compress / Smaller PDF". Those must never appear for a PNG. If the render used a hand-made list, make the render use the real `ActionRegistry` for the dropped file so screenshots prove real behaviour; if the live app does this, fix it and add a test.
  → It was a hand-made fixture list; the app always used the registry. Renders now build the grid with `DefaultActions.registry().actions(for:)` on a real PNG. A new test, `pngChoicesAreImageConversionsOnly`, asserts no `video.*`, `audio.*`, `pdf.compress` or `image.to-png` for a PNG. The real list is JPG, PDF, Compress, HEIC, Half Size, To Text, TIFF and Strip Info.
- [done iter 2, re-score pending] **Hero lacks presence:** → New `HeroRing`: a purpose-drawn ring in full category colour at 232 pt with 16 pt icons and 11 pt labels. A highlight walks around it every 1.2 s, it blooms outward on drag-over with a stronger accent glow, a soft radial accent glow sits behind it, and it stays still under Reduce Motion. The window backdrop is the `.underWindowBackground` vibrancy material.
- [done iter 2] **Ring illustration is washed out:** → Same fix. Lit segments use 92 % tint with white icons, and the others use 14 % (light) or 22 % (dark) tint with a 35 % stroke.
- [done iter 2] **Header mark is wrong:** → The header now shows the real app icon (`NSApp.applicationIconImage`; renders load `Resources/AppIcon.icns`).
- [partly iter 2] **Hierarchy/spacing:** → The header subtitle is now "Lives in your menu bar" plus the real menu-bar glyph (the rest moved to the tooltip). Recent rows already used QuickLookThumbnailing, and Open / Show in Finder now show at all times (tertiary, full on hover or focus). They also support drag out, a context menu and Return to open. Still open: the offscreen renders show Finder icons because Quick Look thumbnails don't arrive in the test render, so real-window screenshots are needed (next iteration, unlocked Mac).
- [ ] Bar: compare side by side against CleanShot X, Raycast, Dropover; run `ui-craft` score + design-reviewer agent; don't mark B3 done below 8/10. → B3 stays `[~]`. The last scored round (before the hero rework) was Clarity 8, Hierarchy 8, Craft 7, Motion 8, Material 6, Typography 7, Feedback 8, Delight 7, Accessibility 7 and Honesty 8. Re-score first thing in iteration 3.
