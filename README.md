# Frenzy

Frenzy is a free, offline menu-bar app for macOS that converts files where they are.

1. Start dragging a file.
2. Hold **Option** (⌥). A ring of conversions appears at the cursor.
3. Drop the file on a choice. The converted file appears next to the original, and a small notice confirms it.

HEIC to JPG, PDF to images, video to audio, compress a PDF, pull text out of a screenshot, and more. Everything
runs on your Mac with Apple's built-in frameworks. No uploads, no accounts, no tracking. Your files are opened only
by Frenzy's worker, a separate process in the macOS App Sandbox with no network access, so even a damaged or hostile
file can't reach the internet through Frenzy or write anywhere but the worker's own folder. See
[docs/PRIVACY.md](docs/PRIVACY.md).

Requires macOS 14 Sonoma or later. Runs natively on Apple silicon and Intel (universal builds).

## Using Frenzy

- The ring icon in the menu bar holds everything: Pause / Resume, Recent Conversions (click one to show it in
  Finder), Open at Login, Settings, the welcome guide, About, and Quit.
- Settings lets you pick the trigger key (Option, Shift, Control or fn), how many choices the ring shows, whether
  to show notices and play sounds, and whether to reveal new files in Finder.
- If no conversion fits the file you're dragging, no ring appears (it would only get in the way of your drop) and a
  short notice says why.
- Originals are never changed. New files never overwrite anything: "photo.jpg", then "photo 2.jpg".
- A conversion in progress shows a notice with **Cancel**. Quitting (or logging out) while converting cancels the
  work and cleans up first, so no half-written files are left behind.

## Build

You need the Xcode Command Line Tools (Swift 6) on macOS 14 or later. Full Xcode is not required.

```sh
cd apps/halo
swift build --scratch-path .build/app          # debug build of everything
scripts/run-dev.sh                             # build dist/Frenzy.app and launch it
scripts/build-app.sh --universal               # dist/Frenzy.app + dist/Frenzy-0.1.0.dmg (ad-hoc signed)
```

Run Frenzy from `dist/Frenzy.app` (that is what `run-dev.sh` does) rather than `swift run`, so it behaves like the real
app: no Dock icon, its own icon, launch at login, and above all conversions in the sandboxed worker. A `swift run`
build has no bundled worker and converts in-process (it logs a warning).

Release signing, notarization and the Gatekeeper notes for testers are in [docs/RELEASE.md](docs/RELEASE.md).

## Test

```sh
swift test --scratch-path .build/test
swift test --scratch-path .build/test --filter HaloCoreTests     # one module
scripts/e2e.sh --no-screenshot                                   # real app, real drags (needs Accessibility for the terminal)
```

Tests use Swift Testing and generate their own sample files at run time.

## Project layout

| Path | What it is |
|---|---|
| `Sources/HaloCore` | Actions, registry, conversion runner, safe output naming and placement, the worker protocol. No UI. |
| `Sources/HaloConverters` | Every conversion, one file per family (images, PDF, video, audio, documents, text). |
| `Sources/HaloUI` | The ring, notices, Settings and welcome screens (SwiftUI). |
| `Sources/HaloDrag` | System-wide drag detection and the floating ring panel. |
| `Sources/HaloWorker` | The sandboxed conversion worker (XPC service): `Kit/` (engine, listener, sandbox self-test) and `Main/`. |
| `Sources/HaloApp` | The menu-bar app: wiring (`AppController`), the worker client (`XPCBackend.swift`), launch at login, windows. `Integration.swift` is the one place that picks concrete types. |
| `Resources` | `Info.plist`, `Frenzy.entitlements`, `Worker-Info.plist`, `HaloWorker.entitlements`, `AppIcon.icns`, `AppIcon-1024.png` |
| `scripts` | `build-app.sh`, `run-dev.sh`, `e2e.sh`, `make-icon.swift` |

How the pieces fit together, and the project's hard rules, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License and credits

© 2026 Snappy Crew. Frenzy is free to use.
