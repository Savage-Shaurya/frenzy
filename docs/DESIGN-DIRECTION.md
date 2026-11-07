# Frenzy design direction (2026-11-04)

Founder: the live bubble ring is good ("that UI is kind of good"). Everything else must match it. The bar: Apple-level, smooth, and simple enough to need no explaining.

## Principles
1. One idea everywhere: glass bubbles around your file. If a screen shows choices, they are bubbles, using `BubbleCluster` and `RingBubbleView` from `Sources/HaloUI/RingBubble.swift`. No wedges, candy petals, or grids of tiles.
2. Liquid Glass: `LiquidGlassBackground` as a modifier on content, `frenzyPrimaryButton()` for the one main action per screen, `frenzySecondaryButton()` for others. Never draw glass as a sibling under content (it blurs the content).
3. One brand colour, `FrenzyPalette.accent`. Family colours appear only on a hovered or chosen bubble. No pink step badges, red progress bars, or grey-on-grey.
4. Few words. One headline, at most one short line under it. Say it the way a person would. No em dashes, no "simply", "just", "easy", "successfully". Sentence case.
5. Calm hierarchy: one hero per screen, 8 pt spacing grid, generous space, SF system font, no boxes inside boxes.
6. Motion means something: spring, interruptible, from `RingMotion`. Reduce Motion, Reduce Transparency and Increase Contrast must keep working, and text must reach 4.5:1.
7. Honest: copy matches behaviour. The ring opens when you pause mid-drag, from Finder or the Desktop. Photos and Mail drags do not work yet, so don't imply they do.

## Technical
- Swift Testing, SwiftPM. Xcode 27.2 is selected, so `@State` works, but match the file you are in. Min OS is macOS 14: gate new APIs with `#available`.
- Keep accessibility identifiers (`halo.home.*`), which `scripts/e2e.sh` depends on, and behaviours like keyboard shortcuts.
- App name is Frenzy; internal target names stay Halo*.

## Lusion and taste benchmark (study, 2026-11-04)

Sources: Lusion values were read live in the founder's Chrome and relayed to this study. Sound, project pages, the open menu and cursor effects were not observed. Other values come from `.claude/skills/taste-skill`, `make-interfaces-feel-better`, `motion-art-direction` and `repos/tastecode/apps/web/src`. Rejected for this app: the `soft-skill` double bezels, eyebrow pills and system font ban, which fight principle 5 and the native look.

What transfers from Lusion: almost monochrome colour plus one saturated hue, regular weight at large size, a big gap between type sizes, very few things on screen, one lit object as the hero. Numbers marked "start" need checking in a real capture.

1. **Five text sizes only.** 40 display, 17 lead, 13 body, 12 bubble label, 11 meta. HaloUI uses 13 sizes today (10 to 44). Raise the 10 pt ring label floor to 11.
2. **Large type is not bold.** `.font(.system(size: 40, weight: .regular))` with `.kerning(-0.8)` (-0.02em), two lines at most, replacing onboarding's 30 semibold. Lead line: 17 regular, `.kerning(-0.2)`, secondary ink. Bubble labels stay semibold.
3. **Opaque neutrals, no extra greys.** Dark: ground `#101012`, surface `#1A1A1D`, raised `#222225`, ink `#EDEDED`, secondary `#A3A3A3`, tertiary `#8A8A8A`. Light: ground `#F2F2F5`, surface `#E8E8EC`, raised `#FFFFFF`, ink `#17171A`, secondary `#55555C`, tertiary `#66666D`. Tertiary clears 4.5:1 on every surface listed.
4. **One accent at full strength.** `FrenzyPalette.accent` at 100% alpha, under 5% of a screen, on the primary action and drop highlight only. Delete the `RadialGradient` in `FrenzyBackdrop`: a 30% violet glow over grey reads as dirty, and violet glows are a listed generated-UI tell. Keeping violet is a brand choice, so it must look deliberate.
5. **Give the glass an edge to bend.** Glass on a flat ground is a grey disc. Home and onboarding put one flat accent disc behind the hero: 184 pt across, centred on the cluster, no blur, no gradient. Its edge runs behind the bubbles (orbit 116, diameter 92). Hide it under Reduce Transparency and Increase Contrast. Start value.
6. **Ring springs.** `bubbleBloom` stays `response 0.42, damping 0.68`: the only overshoot in the app. `bubbleHover` goes from `0.26 / 0.66` to `0.20 / 0.82`, hover scale from 1.16 to 1.12, outward push from 10 to 8 pt, because it runs many times per drag. Keep the 20 ms stagger and 160 ms dismiss.
7. **Window motion.** Enter: `.timingCurve(0.16, 1, 0.3, 1, duration: 0.30)`. Exit: `.timingCurve(0.4, 0, 0.1, 1, duration: 0.16)`. Popovers: open 180 ms, close 120 ms, 4 pt travel, scale 0.97. Press: scale 0.97, 140 ms, on every control. Keyboard selection changes: no animation.
8. **Results are thrown, then caught.** The new file's thumbnail flies on an arc to its card or Recent row: `lift = min(140, distance * 0.3)`, `.timingCurve(0.32, 0.72, 0, 1, duration: 0.5)`. The receiver gives: scale 1, 1.07, 0.985, 1 at 0, 28, 62, 100% of 520 ms, with one ring spreading over 700 ms.
9. **Reduce Motion keeps feedback.** Opacity and colour still change, over 100 to 150 ms, and nothing travels or scales. The reduced state is always the finished state. Never set everything to zero duration.
10. **Nothing moves at rest.** No idle loops, breathing or shimmer. Any shader clock stops when its move ends (500 ms at most), and the overlay then draws no new frames. Hold at least 0.3 s of stillness after a move.
11. **Tone, not boxes.** Separate surfaces by one tone step, not outlined boxes or grey shadows. Circles for choices, 20 pt radius for cards, 8 pt for thumbnails. Nested corners: outer = inner + padding. Thumbnails get a 1 pt inset outline: white 10% on dark, black 10% on light.
12. **Few things, big gaps.** At rest a screen has one hero, one line, one action, plus the footer. Spacing steps are 8, 16, 32, 64, with at least 32 between hero and headline. Hit targets are at least 40 pt (the settings gear is 28). Use `.monospacedDigit()` for sizes and counts.
13. **Labels must survive any desktop.** Regular glass lets page text show through bubble labels (seen in the ring capture). Inside each bubble's content, under the label, add `Circle().fill(.black.opacity(0.28))` in dark and `.white.opacity(0.35)` in light. Start values: measure 4.5:1 over a busy page. Cut the centre to a file preview and a one-line name.
14. **The file colours the glass (signature).** From `centerThumbnail`, off the main thread, downsample to 32 x 32, quantise in Lab, keep up to 3 colours ranked by area x chroma. Below about C* 12 (white PDFs, greys), or with several files, use the family tint. Colour never delays the bloom: it blends in over 240 ms when the thumbnail lands. At rest it fills the outer 30% of each bubble at 35% alpha, leaving the middle clear for the label. On bloom it wipes outward over 420 ms from the side facing the file. On hover it floods the bubble through `RingPalette.litFill` so white text keeps 4.5:1. On a drop it flows back into the centre. Build it as `colorEffect` on a `Circle` inside the bubble's content, not on the glass itself. Reduce Motion: the finished rim appears by `RingMotion.crossfade` and hover flood is a crossfade. Reduce Transparency: flat lit fill on an opaque surface, no shader. Increase Contrast: no rim. This changes principle 3 and needs the founder's yes. Not yet prototyped. There are no `.metal` files and no Metal step in `scripts/build-app.sh`, so check how SwiftPM ships the shader library first.
15. **Do not copy into the app.** Load counters, anything driven by scroll, 3D objects, ribbons, word-by-word text reveals, mono or tiny uppercase labels, crosshair ticks, fixed header pills, custom fonts. Frenzy is used in seconds while a drag is held, so the ring must be ready at once and SF stays.
