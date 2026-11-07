# Releasing Frenzy

Frenzy ships as `Frenzy.app` inside `Frenzy-<version>.dmg`. Everything is built with SwiftPM and the Command Line Tools;
no Xcode project is needed.

## Quick reference

| Goal | Command |
|---|---|
| Local test build, launch it | `scripts/run-dev.sh` (add `--logs` to stream Frenzy's logs) |
| Tester build (ad-hoc signed DMG) | `scripts/build-app.sh --universal` |
| Public release (signed + notarized) | `scripts/build-app.sh --universal --sign "Developer ID Application: Snappy Crew (TEAMID)" --notarize halo-notary` |
| Regenerate the app icon | `swift scripts/make-icon.swift` |
| Prove the worker sandbox applies | `dist/Frenzy.app/Contents/MacOS/Frenzy --worker-self-test` |

Outputs land in `dist/`: `Frenzy.app`, `Frenzy-<version>.dmg`, `build-log.txt`, `spctl-app.txt` (the Gatekeeper verdict).

## What the build script does

1. `swift build -c release --scratch-path .build/release --arch arm64 --product Frenzy`, then the same for
   `--product HaloWorker` (or `--arch arm64 --arch x86_64` with `--universal`).
2. Assembles `dist/Frenzy.app`: `Contents/MacOS/Frenzy`, `Contents/Info.plist` (from `Resources/Info.plist`, with the
   version and build number written in), `Contents/Resources/AppIcon.icns`, `Contents/PkgInfo`, and the sandboxed
   conversion worker `Contents/XPCServices/com.snappycrew.halo.worker.xpc` (`Contents/MacOS/HaloWorker` +
   `Contents/Info.plist` from `Resources/Worker-Info.plist`).
3. Signs inside-out with the hardened runtime. First the worker, with its sandbox entitlements:
   `codesign --force --options runtime --entitlements Resources/HaloWorker.entitlements --identifier com.snappycrew.halo.worker --sign <identity> …/com.snappycrew.halo.worker.xpc`,
   then the app around it: `codesign --force --options runtime --entitlements Resources/Frenzy.entitlements --sign <identity> dist/Frenzy.app`.
   The default identity is `-` (ad-hoc). (No `--deep`: each bundle is signed with its own entitlements.)
4. Verifies with `codesign --verify --deep --strict`, prints both entitlement sets, **fails the build if the worker
   lost `com.apple.security.app-sandbox` or gained any `com.apple.security.network.*` key**, and records the `spctl`
   verdict.
5. With `--notarize`: zips the app, `xcrun notarytool submit --wait`, `xcrun stapler staple` on the app.
6. Builds the DMG with `hdiutil` (the app plus an `/Applications` shortcut), then with a real identity signs the DMG,
   notarizes it and staples it too.

### Universal binary

`swift build --arch arm64 --arch x86_64` works with the Command Line Tools alone on this machine (Swift 6.4); it
produces one fat binary with both slices, each with a minimum of macOS 14.0. It prints a harmless warning that "x86_64
is deprecated for your deployment target (macOS 27.0)"; the real deployment target in the binary is 14.0
(`vtool -show-build`). A universal release build takes about 4 minutes on an M-series Mac versus about 2 for arm64.
Use `--universal` for anything that leaves your Mac, so Intel owners can run it.

## Release checklist

1. Bump `CFBundleShortVersionString` (for example `0.2.0`) and `CFBundleVersion` (always increase it: 1, 2, 3...)
   in `Resources/Info.plist`, or pass `--version` and `--build` (the script writes them into the worker too).
2. Run the tests: `swift test --scratch-path .build/test`.
3. Build: `scripts/build-app.sh --universal` (testers) or with `--sign` and `--notarize` (public).
4. Check the script's output:
   - `codesign --verify` says "valid on disk" and "satisfies its Designated Requirement".
   - App entitlements: an empty dict.
   - Worker entitlements: `com.apple.security.app-sandbox` true, `com.apple.security.temporary-exception.files.absolute-path.read-only` = `/`, nothing else.
   - `lipo -archs` on both `Contents/MacOS/Frenzy` and the worker's `Contents/MacOS/HaloWorker` shows `x86_64 arm64`.
   - For public builds: `spctl` says `accepted, source=Notarized Developer ID`, and `stapler validate` worked.
5. Sandbox check: `dist/Frenzy.app/Contents/MacOS/Frenzy --worker-self-test` ends with `WORKER_SELF_TEST PASS` (every
   network probe `EPERM` or failed lookup, writes outside the container `EPERM`). Do this on **every** signed build:
   it is the proof the sandbox applies with that signature.
6. Crash check: make a large text file and run
   `dist/Frenzy.app/Contents/MacOS/Frenzy --worker-crash-test document.to-pdf big.txt` → `CRASH_TEST PASS` (the worker
   is killed mid-job, the job fails cleanly, a fresh sandboxed worker answers).
7. Offline check: `nm -u dist/Frenzy.app/Contents/MacOS/Frenzy | grep -iE "urlsession|nwconnection|nw_|socket|getaddrinfo"`
   prints nothing. (The worker binary imports socket calls for its self-test only.)
8. End to end: `scripts/e2e.sh --no-screenshot` (needs Accessibility for the terminal). It includes the self-test and
   checks that conversions ran in the `HaloWorker` process and its staging folder is empty afterwards.
9. Smoke test on a clean user account (or a second Mac): open the DMG, drag Frenzy to Applications, launch, see the
   menu-bar ring, finish onboarding, convert a HEIC to JPG, a PDF to images, and a video to audio. Toggle Launch at
   login and confirm it shows in System Settings > General > Login Items.
10. Upload `Frenzy-<version>.dmg` and publish its SHA-256 (printed by the script) next to the download link.

## Signing and notarization (public releases)

Ad-hoc builds run fine on the Mac that built them, but Gatekeeper blocks them on other Macs. To ship to the public
without warnings, Frenzy must be signed with a **Developer ID Application** certificate and **notarized** by Apple.

**Requirement: an Apple Developer Program membership, $99 per year** (developer.apple.com/programs). A free Apple ID
can't create Developer ID certificates. This Mac has no signing identity today, so the steps below are untested here;
they follow Apple's documented flow.

One-time setup:

1. Enroll in the Apple Developer Program (as Snappy Crew; an organization needs a D-U-N-S number).
2. Create the certificate: developer.apple.com > Certificates > "+" > **Developer ID Application**. Without Xcode,
   make the signing request with Keychain Access (Certificate Assistant > Request a Certificate From a Certificate
   Authority), upload it, download the `.cer` and double-click it to install. Check it:
   ```sh
   security find-identity -v -p codesigning
   # 1) ABCDEF... "Developer ID Application: Snappy Crew (TEAMID)"
   ```
3. Create an app-specific password at account.apple.com > Sign-In and Security > App-Specific Passwords.
4. Store notary credentials in the keychain under a profile name:
   ```sh
   xcrun notarytool store-credentials halo-notary --apple-id you@example.com --team-id TEAMID
   # paste the app-specific password when asked
   ```
   (An App Store Connect API key also works: `--key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>`.)

Every release:

```sh
scripts/build-app.sh --universal \
  --sign "Developer ID Application: Snappy Crew (TEAMID)" \
  --notarize halo-notary
```

The script signs with `--timestamp` (required for notarization), submits the zipped app with
`xcrun notarytool submit --wait`, staples the ticket to the app, builds the DMG, signs it, notarizes and staples the
DMG as well. Stapling both means Gatekeeper can approve Frenzy even when the Mac is offline. If Apple rejects a
submission, the script prints `xcrun notarytool log <id>` with the reasons.

For Developer ID builds, also tighten the worker's client check in `Sources/HaloCore/WorkerProtocol.swift`
(`HaloWorkerService.clientRequirement`) to
`anchor apple generic and certificate leaf[subject.OU] = "TEAMID" and identifier "com.snappycrew.halo"`, so only
your signed app can connect. The ad-hoc default pins the identifier only (bundled XPC services are private to their
app anyway). The XPC worker under a Developer ID signature is untested here: run `--worker-self-test` on the first one.

`notarytool` and `stapler` ship with the Command Line Tools (`xcrun --find notarytool`), so no Xcode is needed.

## Gatekeeper and ad-hoc builds (testers)

An ad-hoc signature (`codesign -s -`) proves the app wasn't modified, but it carries no developer identity and isn't
notarized. On this Mac `spctl --assess` reports `rejected` for it, which is expected. Apps built locally don't carry
the quarantine flag, so they open normally on the Mac that built them.

On another Mac, a downloaded ad-hoc build is quarantined and macOS says Frenzy "can't be opened" or "Apple could not
verify Frenzy is free of malware". Testers can open it like this:

1. Open the DMG and drag Frenzy to Applications.
2. Double-click Frenzy once and dismiss the warning.
3. Open **System Settings > Privacy & Security**, scroll down to the message about Frenzy, click **Open Anyway**, and
   confirm with your password or Touch ID. (On macOS 15 and later the old right-click > Open shortcut no longer
   bypasses the warning; Open Anyway in System Settings is the supported path.)

Technical testers can instead clear the quarantine flag: `xattr -dr com.apple.quarantine /Applications/Frenzy.app`.

Only do this for builds you received directly from the Frenzy team.

## Sandbox decision

Frenzy is split in two processes:

| | `Frenzy.app` (menu bar) | `com.snappycrew.halo.worker.xpc` (inside the app) |
|---|---|---|
| App Sandbox | no | **yes** |
| Network entitlement | none (not enforced: the app isn't sandboxed) | none (**enforced** by the sandbox) |
| Hardened runtime | yes, no exceptions | yes, no exceptions |
| Parses file contents | never | always |
| Writes | the final file next to the original | only its container |

Why the app itself isn't sandboxed:

- Frenzy writes the converted file **next to the original**, in whatever folder that is. A sandboxed app may only write
  where the user granted access, normally through an open or save panel. A drag that ends on Frenzy's ring panel grants
  read access to the dragged files at best, never write access to their folder.
- Frenzy notices drags system-wide (it reads the drag pasteboard and the trigger key while another app owns the drag),
  which relies on global event monitoring the sandbox isn't designed for.

Why there is a worker: parsers of untrusted files (ImageIO, PDFKit, AVFoundation, WebKit-backed HTML import, Vision)
are where bugs live. In the worker, a bug can't reach the network (the kernel returns `EPERM`, see
`docs/PRIVACY.md`), can't write outside the container, and a crash or memory blow-up only ends the worker; the app
reports a friendly failure and the next job gets a fresh worker. The app validates everything the worker returns
before placing it (see `docs/ARCHITECTURE.md`, "Sandboxed worker").

The worker has read-only access to `/` (`com.apple.security.temporary-exception.files.absolute-path.read-only`), so it
can open dropped files wherever they are. Temporary-exception entitlements are fine for Developer ID distribution;
the Mac App Store would not accept them (nor the unsandboxed app), and an App Store build is out of scope for V0.

XPC with ad-hoc signing works on this Mac (macOS 27.0.1): the bundled service launches, the sandbox applies
(`APP_SANDBOX_CONTAINER_ID=com.snappycrew.halo.worker`), and the app can read the worker's container to collect
results without any prompt. No helper-subprocess fallback was needed.

## Launch at login

Uses `SMAppService.mainApp` (macOS 13+). It only works when Frenzy runs from `Frenzy.app` with its bundle identifier; a
`swift run` build shows the option greyed out. For a reliable registration, run Frenzy from `/Applications`. If the
user turns Frenzy off in System Settings > Login Items, the status becomes "requires approval" and Frenzy opens that
settings page when the user turns it back on.

## Known limits of CLT-only builds

- No asset catalog compiler: the icon is a plain `AppIcon.icns` (made by `scripts/make-icon.swift`) referenced by
  `CFBundleIconFile`.
- The SwiftUI macro plugin (`SwiftUIMacros`) isn't in the Command Line Tools, so `@State` and `@Entry` macros fail
  to build against the macOS 27 SDK. HaloUI uses `State(initialValue:)` structs and `ObservableObject` instead. Keep
  it that way unless the team moves to full Xcode.
