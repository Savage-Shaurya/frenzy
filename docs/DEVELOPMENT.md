# Developing Frenzy

For people building Frenzy from source. Users: see the [README](../README.md).

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
| `scripts` | `build-app.sh`, `run-dev.sh`, `e2e.sh`, `make-app-icon.py` |

How the pieces fit together, and the project's hard rules, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License and credits

© 2026 Snappy Crew. Frenzy is free to use.
