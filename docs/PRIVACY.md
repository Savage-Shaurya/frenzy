# Frenzy privacy

Short version: **Frenzy converts your files on your Mac. It has no networking code, and the part that reads your
files runs in a sandbox where macOS refuses every network connection and DNS lookup.** "No network" here means
exactly that: no sockets and no DNS from the worker. It does not mean the worker can do nothing else; see
[What the sandbox does not stop](#what-the-sandbox-does-not-stop).

## What Frenzy does with your files

- **While you drag anything**, Frenzy's drag monitor reads the list of file URLs on the system drag pasteboard (only
  file URLs: never text, images or other contents) so it knows whether a file drag is in progress. It does this on
  every drag, whether or not you hold the trigger key; nothing is stored. When you hold the trigger key, it looks
  at those files' names and types to decide which conversions to offer.
- When you drop on a choice, the file is read and converted by **Frenzy's worker**, a separate process with the App
  Sandbox on (see below), using Apple's built-in frameworks (ImageIO, Core Image, PDFKit, AVFoundation, Vision,
  the AppKit text system). The worker writes the result into its own sandbox folder; the Frenzy app then moves it
  next to the original under a free name. If that folder can't be written (a disk image, a share), or the file came
  from another app, the result goes to your Downloads folder and the card says so.
- Files dragged from Photos, Mail or a browser are handed over by that app into a private temporary folder, and
  deleted when the conversion ends. Frenzy itself never downloads anything. A browser may fetch the file itself to
  hand it over, and macOS may download an iCloud placeholder when you convert it.
- Frenzy never changes, moves or deletes the original file. New files get a fresh name, so nothing is overwritten.
- Text recognition (OCR) uses Apple's on-device Vision framework. Nothing is uploaded for it.
- **Photo metadata:** format conversions (for example HEIC to JPG) keep the photo's metadata, including where it was
  taken. **Compress** and **Half Size** make files for sharing, so they remove the location (GPS and place fields)
  and keep the rest. **Strip Info** removes all metadata.

## The sandboxed worker

| | Frenzy app (menu bar) | Frenzy worker (`com.snappycrew.frenzy.worker.xpc`, inside Frenzy.app) |
|---|---|---|
| Job | Drag detection, the ring, notices, settings, placing finished files | Opens and converts every file you drop |
| Reads file contents | No (names, types and sizes only) | Yes |
| App Sandbox | No (it must write next to files in any folder) | **Yes** |
| Network | No networking code; **not** blocked by the OS | **No sockets, no DNS: refused by the OS** (no network entitlement) |
| Open a link or an app | Yes (it is an ordinary app) | **Not blocked by the OS** (allowed to every sandboxed app); Frenzy's code never does it |
| Can write | Anywhere you can | Only its own container, `~/Library/Containers/com.snappycrew.frenzy.worker` |
| Can read | Anywhere you can | Anywhere you can (read-only), so it can open the files you drop |

Why this matters: parsing files is where bugs live. If a malformed file ever triggered a bug in an image, PDF, video
or document parser, that code runs inside the worker, which cannot connect anywhere and cannot write outside its
own folder. A file that makes the parser crash or use huge amounts of memory (a "decompression bomb") takes down only
the worker; Frenzy shows "Frenzy's converter stopped while reading this file, so nothing was saved" and starts a fresh
worker for the next job. The worker also stops itself if its memory use passes about half of your Mac's memory
(at most 12 GB).

The app treats the worker's answers as untrusted too: it only accepts results from inside the worker's own folder,
only saves into the folder of a file you dropped, only with ordinary document and media extensions (never `.app` or
`.command`), never follows symbolic links inside output folders, and saves nothing as executable.

## What the sandbox does not stop

The worker sandbox is the App Sandbox every Mac App Store app runs in, with no network entitlement. Measured inside the
worker (see the self-test below), it **refuses**: TCP and UDP sockets (even to this Mac), DNS lookups (including a
direct connection to the system resolver), web requests, and writing anywhere outside its own folder. The media engine
it starts gets the same sandbox.

It **does not stop** these, for any sandboxed app, and a process already inside the App Sandbox cannot add a stricter
sandbox to itself (tested: macOS answers "Operation not permitted"):

- **Reading.** The worker can read any file you can, except folders macOS protects separately (Mail, Messages,
  Safari and the like need Full Disk Access, which Frenzy never asks for). It needs this because it opens the files
  you drop, wherever they are. Narrowing it would mean the app handing each dropped file to the worker as an open
  file instead of a path; most of Apple's converters (Quick Look, PDFKit, AVFoundation, the text system) want a path,
  so that is a larger change and is not done yet.
- **Asking macOS to open a link or an app.** Sandboxed apps may ask LaunchServices to open a web address in your
  browser or to open an app. A worker taken over by a malicious file could use this to open a link that carries data
  in its address. It would be visible (your browser comes to the front), and Frenzy's own code never opens anything.
- **The clipboard.** Sandboxed apps may read and write the pasteboard. Frenzy's worker never does.
- **Not audited:** every other system service the App Sandbox lets an app talk to (for example Apple Events to apps
  that accept them) has not been checked one by one against a fully compromised worker.

So the honest promise is: Frenzy itself never sends your files anywhere, and the process that reads them cannot open
a network connection. The defence against a hostile file is mostly that Frenzy refuses risky input before parsing it
(for example SVG files that point at other files, below) and that the parsers run in that sandbox.

**SVG files.** macOS's SVG renderer really does draw pictures from other files on your Mac into the result if the SVG
names them (measured on macOS 27). Frenzy therefore opens an SVG only if it is UTF-8, has no DOCTYPE (the standard
SVG 1.0 / 1.1 one is removed before parsing) and no entities, and every link in it points inside the file (`#name`)
or is an embedded picture (`data:image/...`, not another SVG). Anything else is refused with a plain message.

## What Frenzy does not do

- No network connections of any kind in Frenzy's code. No uploads, no cloud conversion, no update checks, no crash
  reporting.
- No analytics, telemetry, tracking or advertising IDs.
- No accounts and no sign-in.
- No reading of what you type. Frenzy only checks whether the trigger key is held while a drag is in progress.

## What Frenzy stores, and where

In Frenzy's preferences on this Mac (`~/Library/Preferences/com.snappycrew.frenzy.plist`):

- Your settings (trigger key, ring size, toasts, sounds, reveal in Finder, launch at login).
- How many times you used each conversion, so your favourites come first on the ring. Only counts per conversion
  type (for example "image.to-jpg: 12"), never file names. A use counts only when the conversion produced a file.
- Recent Conversions: the last 20 conversions, with up to 20 output paths each. Use **Clear Recent** in the menu to
  remove them.
- A practice picture, `Frenzy sample.png`, and its outputs in `~/Library/Application Support/Frenzy/Try Frenzy`, created by the onboarding step.
- File previews come from macOS Quick Look, which draws them on this Mac. Turn them off with **Show file previews** in Settings.
- The folders Frenzy saved into recently (up to 200 paths), so that at launch it can remove its own leftover temporary
  files (hidden `.halo-<id>` names, older than an hour) after a crash or power cut. Frenzy only looks in those folders,
  never anywhere else on the disk.

Also on this Mac:

- An empty lock file in `~/Library/Caches/com.snappycrew.frenzy/` so only one copy runs at a time.
- The worker's sandbox container, `~/Library/Containers/com.snappycrew.frenzy.worker/`. Files sit there only while a
  conversion runs; Frenzy deletes them after saving the result. Working copies some conversions need (the picture a
  WebP is made from, the pieces of an EPUB) sit in the same per-conversion folder. If the worker dies mid-job, the
  next worker clears those folders once they are an hour old, and stops any media engine the dead worker left
  running. It also keeps a small list of running engine process ids there (`tmp/frenzy-engine-pids`), for that.

To remove everything: quit Frenzy, delete the app, then delete the three locations above.

## Permissions

Frenzy asks for no special permissions. It does not need Accessibility, Input Monitoring, Screen Recording, Full Disk
Access, Contacts, Photos, Camera, Microphone or Location. If you convert files in protected folders such as
Desktop, Documents or Downloads, macOS may ask once whether Frenzy may access that folder. If you turn on **Launch at
login**, macOS lists Frenzy under System Settings > General > Login Items, where you can switch it off at any time.

## How we check this

You don't have to take our word for it. Each release is checked like this, and you can repeat the checks:

1. **The worker is sandboxed with no network entitlement.**
   ```sh
   codesign -d --entitlements :- /Applications/Frenzy.app/Contents/XPCServices/com.snappycrew.frenzy.worker.xpc
   ```
   shows `com.apple.security.app-sandbox` = true, a read-only file exception for `/` (see "Reading" above), and no
   `com.apple.security.network.*` key. (The app's own entitlements are empty, but the app is not sandboxed, so an
   empty list there proves nothing about networking. That's why the file parsing moved into the worker.)
2. **The sandbox actually applies.** Run the worker's self-test, which tries to reach the network and write outside
   its folder from inside the worker:
   ```sh
   /Applications/Frenzy.app/Contents/MacOS/Frenzy --worker-self-test
   ```
   Result on macOS 27 (arm64, ad-hoc signed build, 7 Nov 2026):

   | Probe (from inside the worker) | Observed |
   |---|---|
   | TCP connect 127.0.0.1:9 | `EPERM (Operation not permitted)` |
   | TCP connect 1.1.1.1:443 | `EPERM (Operation not permitted)` |
   | UDP sendto 8.8.8.8:53 | `EPERM (Operation not permitted)` |
   | DNS lookup example.com | `getaddrinfo = 8 (nodename nor servname provided, or not known)` |
   | Connect to the DNS resolver's socket | `EPERM (Operation not permitted)` |
   | URLSession GET https://example.com | `NSURLErrorDomain -1003` (host not found) |
   | May ask macOS to open a link or app (`lsopen`) | **allowed** (App Sandbox limit, above) |
   | Reach LaunchServices | **allowed** (App Sandbox limit, above) |
   | Reach the pasteboard server | **allowed** (App Sandbox limit, above) |
   | Write to your real home folder | `EPERM` |
   | Write to /private/tmp | `EPERM` |
   | Write to its own container | allowed |
   | Read /etc/hosts | allowed |
   | Media engine: sandboxed, network denied, can't write /private/tmp, TCP from a child refused | all as expected |
   | Media engine left running by a dead worker is found and stopped | stopped |

   The "allowed" rows are reported, not hidden: a probe passes when macOS answers the way this page says.
   It also reports `sandbox container: com.snappycrew.frenzy.worker`. For comparison, the same loopback connect from
   an unsandboxed process gets `ECONNREFUSED` (nothing listening), not `EPERM`: the denial comes from the sandbox.
3. **No networking code in Frenzy.** The source has no `URLSession`, `Network.framework`, sockets or analytics SDKs
   outside the worker's self-test, and it has no third-party dependencies:
   ```sh
   nm -u /Applications/Frenzy.app/Contents/MacOS/Frenzy | grep -iE "urlsession|nwconnection|nw_|socket|getaddrinfo"
   ```
   prints nothing for the app. (The worker binary does import socket calls, for the self-test probes above, and the
   sandbox denies them.)
4. **Watch it run.** Use a network monitor such as Little Snitch or LuLu, or `nettop -p Frenzy -p HaloWorker`, while
   converting files.
5. **Read the code.** `docs/ARCHITECTURE.md` describes the worker and its rules.

## What is not verified yet

Being precise about the limits:

- **The Frenzy app itself is not sandboxed.** Nothing at the OS level stops it from using the network; it doesn't
  because it has no networking code and never parses file contents. Apple frameworks it uses (AppKit, for example
  Finder icons in the menu) contain networking code of their own for features Frenzy doesn't call.
- **Developer ID builds.** The evidence above is from an ad-hoc signed build. A Developer ID signed, notarized build
  should behave the same (the sandbox comes from the entitlements, not the certificate) but hasn't been tested,
  because no Developer ID certificate is available yet. Rerun `--worker-self-test` on every release build.
- **Reading, links, clipboard.** See [What the sandbox does not stop](#what-the-sandbox-does-not-stop). The worker
  can read any file you can and can't send it over the network itself, but the App Sandbox still lets it ask macOS
  to open a link or app and use the clipboard.
- **The memory limit.** The worker's memory watchdog and the crash recovery were tested by killing the worker in
  the middle of a job (`Frenzy --worker-crash-test`), not with a real decompression bomb: the converters already
  refuse oversized images (over 250 megapixels) before decoding them.
- **Kernel logs.** macOS on this machine did not show sandbox "deny" lines in the unified log, so the evidence is
  the probe results above rather than kernel log entries.

## Changes

If a future version ever needs the network (for example an optional update check), it will be off by default, it
will be described here first, and it will ask you before doing anything.

Questions: contact Snappy Crew.
