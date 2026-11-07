#!/usr/bin/env bash
# End-to-end test of the real dist/Frenzy.app: synthesized cross-process file drags with Option held, a drop on the
# right ring segment (found through Halo's accessibility tree), and checks on the files that appear.
#
#   scripts/e2e.sh                 run everything (needs Accessibility for the terminal, to post events)
#   scripts/e2e.sh --keep          keep the temp fixture folder for inspection
#   scripts/e2e.sh --no-screenshot skip the ring screenshot (kept in the temp build folder)
#   scripts/e2e.sh --build-only    build the driver and exit 0 (no launch, no events, defaults untouched)
#
# Backs up the com.snappycrew.frenzy defaults domain to $BUILD/defaults-backup.plist, resets it, marks onboarding
# complete, launches Halo, and quits it at the end. The backup is restored on every exit path (pass, fail, Ctrl-C);
# if a run was killed before restoring, the next run restores that backup first instead of overwriting it.
#
# Order (B3 home window): the home window opens centred at launch, over the point where the ring scenarios summon
# the ring. So it is checked, then closed with AXCloseButton; the ring and icon scenarios run with it closed; then
# `open "$APP"` re-opens it and the home drop / cancel / recents scenarios run last.
# Builds the driver (scripts/e2e/main.swift) straight from the module sources into $TMPDIR/halo-e2e-build, like
# scripts/drag-harness.sh. Does not touch Package.swift or .build.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Frenzy.app"
DOMAIN=com.snappycrew.frenzy
KEEP=0; SHOT=1; BUILD_ONLY=0
for a in "$@"; do case "$a" in --keep) KEEP=1;; --no-screenshot) SHOT=0;; --build-only) BUILD_ONLY=1;; esac; done

BUILD="${TMPDIR:-/tmp}/halo-e2e-build"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/halo-e2e.XXXXXX")"
DRIVER="$BUILD/e2e-driver"
LOG="$BUILD/e2e-last.log"; mkdir -p "$BUILD"; [[ $BUILD_ONLY == 1 ]] || : > "$LOG"   # keep the last live log
RESULTS=()
FAILS=0

record() { # name status detail   (status EXPERIMENTAL-* is reported but never fails the run)
  RESULTS+=("$1|$2|$3")
  [[ "$2" == PASS || "$2" == EXPERIMENTAL* ]] || FAILS=$((FAILS + 1))
  printf '%-4s %s  (%s)\n' "$2" "$1" "$3"
}

quit_halo() {
  osascript -e "tell application id \"$DOMAIN\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x Frenzy >/dev/null || return 0; sleep 0.25; done
  pkill -x Frenzy 2>/dev/null || true; sleep 0.5
}

halo_pid() { pgrep -x Frenzy | head -1; }

# ---------------------------------------------------------------- build the driver
echo "building e2e driver into $BUILD ..."
mkdir -p "$BUILD"
SDK="$(xcrun --show-sdk-path)"
COMMON=(-sdk "$SDK" -target arm64-apple-macos14.0 -Onone -I "$BUILD" -L "$BUILD"
        -plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins)
build_lib() {
  local name="$1"; shift
  swiftc "${COMMON[@]}" -swift-version 6 -parse-as-library -enable-upcoming-feature ExistentialAny \
    -module-name "$name" -emit-module -emit-module-path "$BUILD/$name.swiftmodule" \
    -emit-library -static -o "$BUILD/lib$name.a" "$@"
}
build_lib HaloCore "$ROOT"/Sources/HaloCore/*.swift || exit 3
build_lib HaloConverters "$ROOT"/Sources/HaloConverters/*.swift || exit 3
build_lib HaloUI "$ROOT"/Sources/HaloUI/*.swift || exit 3
build_lib HaloDrag "$ROOT"/Sources/HaloDrag/*.swift || exit 3
swiftc "${COMMON[@]}" -swift-version 5 -lHaloCore -lHaloConverters -lHaloUI -lHaloDrag \
  -o "$DRIVER" "$ROOT/scripts/e2e/main.swift" || exit 3
if [[ $BUILD_ONLY == 1 ]]; then echo "driver built: $DRIVER"; rm -rf "$WORK"; exit 0; fi

# A locked screen (loginwindow frontmost) accepts no synthetic drags and hides windows from accessibility, so every
# scenario would fail for a reason that has nothing to do with Halo. Refuse to run instead (exit 4 = skipped).
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
  echo "SKIPPED: the screen is locked. Unlock the Mac and run again."; rm -rf "$WORK"; exit 4
fi

echo "permissions: $("$DRIVER" perms)"

# ---------------------------------------------------------------- 0. back up the founder's defaults
# The run needs clean defaults, but the domain holds the founder's Recent Conversions and settings. PENDING exists
# while a backup still has to be restored; it holds 1 (domain existed, import the plist) or 0 (delete the domain).
DEFAULTS_BACKUP="$BUILD/defaults-backup.plist"
PENDING="$BUILD/defaults-backup.pending"
RESTORE_ARMED=0
restore_defaults() {
  # Never leave test files on the founder's Desktop, even when the run stops early: the folder goes to the Bin.
  if [[ -n "${DESK:-}" && -d "$DESK" ]]; then mv "$DESK" "$HOME/.Trash/" 2>/dev/null && echo "test data: moved $(basename "$DESK") to the Bin"; fi
  [[ $RESTORE_ARMED == 1 ]] || return 0
  RESTORE_ARMED=0
  quit_halo   # a running Halo would write its in-memory settings back over the restore
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  if [[ "$(cat "$PENDING" 2>/dev/null)" == 1 ]]; then
    if defaults import "$DOMAIN" "$DEFAULTS_BACKUP"; then echo "defaults: restored $DOMAIN from $DEFAULTS_BACKUP"
    else echo "WARNING defaults: could not restore $DOMAIN; backup kept at $DEFAULTS_BACKUP" >&2; return 1; fi
  else
    echo "defaults: $DOMAIN did not exist before the run; removed it again"
  fi
  rm -f "$PENDING"
}
[[ -d "$APP" ]] || { echo "missing $APP (run scripts/build-app.sh)"; exit 3; }
quit_halo   # first, so the founder's running Halo flushes its settings before the export
if [[ -f "$PENDING" ]]; then
  echo "defaults: a previous run did not restore its backup; restoring it before backing up again"
  RESTORE_ARMED=1; restore_defaults || exit 3
fi
if defaults read "$DOMAIN" >/dev/null 2>&1; then
  defaults export "$DOMAIN" "$DEFAULTS_BACKUP" || { echo "could not back up $DOMAIN; not touching it"; exit 3; }
  echo 1 > "$PENDING"
else
  echo 0 > "$PENDING"
fi
RESTORE_ARMED=1
trap restore_defaults EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # make sure the EXIT trap runs

# ---------------------------------------------------------------- 1. clean launch
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
defaults write "$DOMAIN" halo.hasCompletedOnboarding -bool true   # HaloSettings.Key.hasCompletedOnboarding
defaults write "$DOMAIN" halo.opensOnPause -bool false            # the key scenarios first; section 7 turns pause on
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASHES_BEFORE="$(ls "$CRASH_DIR" 2>/dev/null | grep -i '^Frenzy' | sort)"
T_LAUNCH="$(date '+%Y-%m-%d %H:%M:%S')"
open -n "$APP"
for _ in $(seq 1 40); do [[ -n "$(halo_pid)" ]] && break; sleep 0.25; done
PID="$(halo_pid)"
if [[ -z "$PID" ]]; then record "launch dist/Frenzy.app" FAIL "not running after 10 s"; exit 1; fi
sleep 1.5   # status item + monitors installed
record "launch dist/Frenzy.app (clean defaults, onboarding pre-marked)" PASS "pid $PID"

# Halo's unified log since a timestamp (`--info` too, in case a line is logged at info level).
halo_log_since() { /usr/bin/log show --start "$1" --info --style compact --predicate 'subsystem == "com.snappycrew.frenzy"' 2>/dev/null; }
wait_log() { # start pattern seconds: Halo logged pattern since start (the log store lags by a second or so)
  for _ in $(seq 1 "$3"); do halo_log_since "$1" | grep -q "$2" && return 0; sleep 1; done
  return 1
}
last_result() { grep '^RESULT' "$LOG" | tail -1 | cut -d' ' -f2-; }
last_key() { awk -v k="$1" '$1==k {sub(k" ",""); v=$0} END {print v}' "$LOG"; }

# ---------------------------------------------------------------- 1a. home window at launch (B3)
echo "===== home window shown at launch" >> "$LOG"
if ! "$DRIVER" home-window --timeout 5 >> "$LOG" 2>&1; then
  record "home window shown at launch" FAIL "$(last_result)"
elif ! wait_log "$T_LAUNCH" "Home window shown" 5; then
  record "home window shown at launch" FAIL "window on screen but no 'Home window shown' in Halo's log"
else
  record "home window shown at launch" PASS "$(last_key HOMEWIN)"
fi
# Closed for the ring scenarios: centred, it sits under the ring's summon point and the ring screenshot.
echo "===== close home window" >> "$LOG"
if "$DRIVER" home-close >> "$LOG" 2>&1; then record "home window closes (AXCloseButton)" PASS "closed before the ring scenarios"
else record "home window closes (AXCloseButton)" FAIL "$(last_result)"; fi

# ---------------------------------------------------------------- 1b. sandboxed worker
# The worker's own probe: network and writes outside its container must be denied by the sandbox.
SELFTEST="$("$APP/Contents/MacOS/Frenzy" --worker-self-test 2>&1)"
echo "$SELFTEST" >> "$LOG"
if grep -q "WORKER_SELF_TEST PASS" <<<"$SELFTEST"; then
  record "worker sandbox self-test (network + outside writes denied)" PASS "$(grep -c '| PASS |' <<<"$SELFTEST") probes pass, container $(grep 'sandbox container' <<<"$SELFTEST" | cut -d: -f2 | tr -d ' ')"
else
  record "worker sandbox self-test (network + outside writes denied)" FAIL "$(grep -E 'FAIL|ERROR' <<<"$SELFTEST" | head -3 | tr '\n' ' ')"
fi
WENT="$(codesign -d --entitlements :- "$APP/Contents/XPCServices/com.snappycrew.frenzy.worker.xpc" 2>/dev/null)"
if grep -q app-sandbox <<<"$WENT" && ! grep -q "security.network" <<<"$WENT"; then
  record "worker entitlements: sandbox on, no network" PASS "com.apple.security.app-sandbox"
else
  record "worker entitlements: sandbox on, no network" FAIL "$WENT"
fi
STAGING="$HOME/Library/Containers/com.snappycrew.frenzy.worker/Data/tmp/HaloStaging"

# ---------------------------------------------------------------- 2. fixtures
"$DRIVER" fixtures "$WORK/f" >/dev/null || { record fixtures FAIL "driver"; exit 1; }
F="$WORK/f"
printf 'zip me\n' > "$WORK/inner.txt"
ditto -c -k "$WORK/inner.txt" "$F/zip/archive.zip"; rm -f "$WORK/inner.txt"
mkdir -p "$F/folder/thing"; printf 'in a folder\n' > "$F/folder/thing/inside.txt"
# Real Finder sources (B5): the file's own icon is dragged out of a Finder window, as a person would.
mkdir -p "$F/finder" "$F/finderzip" "$F/pause" "$F/pausefinder" "$F/pausethrough" "$F/pausehome"
cp "$F/png/photo.png" "$F/pause/pause-photo.png"
cp "$F/png/photo.png" "$F/pausefinder/pausefinder-photo.png"
cp "$F/png/photo.png" "$F/pausethrough/through-photo.png"
cp "$F/png/photo.png" "$F/pausehome/home-pause-photo.png"
cp "$F/png/photo.png" "$F/finder/finder-photo.png"
cp "$F/zip/archive.zip" "$F/finderzip/finder-archive.zip"
# ~/Desktop is privacy-protected, which temp folders aren't. Removed again at the end.
DESK="$HOME/Desktop/halo-test-e2e-$$"
mkdir -p "$DESK"; cp "$F/png/photo.png" "$DESK/desktop-photo.png"
# Snapshot every original's hash.
HASHES="$WORK/hashes.txt"
(cd "$F" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$HASHES"

listing() { (cd "$1" && find . -mindepth 1 | sed 's|^\./||' | sort | tr '\n' ' '); }
wait_for() { # timeout path...
  local t="$1"; shift
  for _ in $(seq 1 $((t * 4))); do
    local ok=1; for p in "$@"; do [[ -e "$p" ]] || ok=0; done
    [[ $ok == 1 ]] && return 0; sleep 0.25
  done
  return 1
}
no_temp() { [[ -z "$(find "$1" -name '.halo-*' 2>/dev/null)" ]]; }
alive() { [[ "$(halo_pid)" == "$PID" ]]; }

drag() { # name args... ; prints driver output to log, returns exit code
  local name="$1"; shift
  local attempt rc start
  for attempt in 1 2; do
    echo "===== $name: drag $* (attempt $attempt)" >> "$LOG"
    start=$(wc -l < "$LOG")
    "$DRIVER" drag "$@" >> "$LOG" 2>&1
    rc=$?
    sleep 0.5
    # Retry only when the DRIVER's own drag never started (its source window missed the synthetic mouseDown,
    # seen on the first drag after launch). Halo never saw a drag then, so this can't hide a Halo failure.
    if tail -n +"$((start + 1))" "$LOG" | grep -q "source: mouseDown"; then break; fi
    echo "NOTE driver drag never started; retrying once" >> "$LOG"
  done
  return $rc
}
verify_jpeg() { "$DRIVER" verify-image "$1" public.jpeg; }
verify_png()  { "$DRIVER" verify-image "$1" public.png; }
verify_pdf1() { "$DRIVER" verify-pdf "$1" 1; }
verify_pdf2() { "$DRIVER" verify-pdf "$1" 2; }
verify_text() { [[ -s "$1" ]] && echo "TEXT OK $1"; }
verify_zip()  { /usr/bin/unzip -tq "$1"; }

# One conversion: name, dir, ring title, verify function, expected outputs (relative to dir)...
scenario() {
  local name="$1" dir="$2" title="$3" verify="$4"; shift 4
  local inputs=(); for f in "$dir"/*; do inputs+=("$f"); done
  local extra=()
  if [[ "$name" == "PNG -> JPG" && $SHOT == 1 ]]; then extra=(--screenshot "$BUILD/ring-live.png"); fi
  if [[ -n "${ICON_EXTRA+x}" ]]; then extra+=("${ICON_EXTRA[@]}"); fi
  if ! drag "$name" --target "$title" ${extra[@]+"${extra[@]}"} "${inputs[@]}"; then
    record "$name" FAIL "drag: $(last_result)"; return
  fi
  local paths=(); for e in "$@"; do paths+=("$dir/$e"); done
  if ! wait_for 20 "${paths[@]}"; then
    record "$name" FAIL "no output after 20 s; folder: $(listing "$dir")"; return
  fi
  sleep 0.5
  local v
  for e in "$@"; do
    if ! v="$($verify "$dir/$e" 2>&1)"; then record "$name" FAIL "invalid output $e: $v"; return; fi
    echo "$v" >> "$LOG"
  done
  no_temp "$dir" || { record "$name" FAIL ".halo-* temp file left: $(listing "$dir")"; return; }
  alive || { record "$name" FAIL "Halo not running afterwards"; return; }
  record "$name" PASS "$(last_key TARGET | sed 's/ at=.*//') -> $*"
}

# Drags that must NOT convert: name, dir, driver flag.
no_output_scenario() {
  local name="$1" dir="$2" flag="$3"
  local before; before="$(listing "$dir")"
  local inputs=(); for f in "$dir"/*; do inputs+=("$f"); done
  if ! drag "$name" "$flag" "${inputs[@]}"; then record "$name" FAIL "$(last_result)"; return; fi
  sleep 2
  [[ "$(listing "$dir")" == "$before" ]] || { record "$name" FAIL "folder changed: $(listing "$dir")"; return; }
  alive || { record "$name" FAIL "Halo not running afterwards"; return; }
  record "$name" PASS "$(last_result | sed 's/^PASS //'); $(last_key SESSION); no new files"
}

# ---------------------------------------------------------------- 3/4. conversions
scenario "PNG -> JPG"               "$F/png"   JPG      verify_jpeg "photo.jpg"
scenario "PDF -> Images"            "$F/pdf"   Images   verify_png  "doc pages/doc page 1.png" "doc pages/doc page 2.png"
scenario "PDF -> Compress"          "$F/pdfc"  Compress verify_pdf2 "doc (compressed).pdf"
scenario "TXT -> PDF"               "$F/txt"   PDF      verify_pdf1 "notes.pdf"
# ---------------------------------------------------------------- 5. edge cases
no_output_scenario "Option released before drop" "$F/release" --release-option
# Zip and Unzip shipped in iteration 18: a zip and a folder now get a ring. (Zip fits every file, so no plain file
# type is left that should show no ring; --expect-no-ring stays in the driver for a future case.)
scenario "ZIP -> Unzip"             "$F/zip"    Unzip    verify_text "archive/inner.txt"
scenario "Folder -> Zip"            "$F/folder" Zip      verify_zip  "thing.zip"
# ---------------------------------------------------------------- 5b. real Finder drags (B5)
ICON_EXTRA=(--from-finder)
scenario "Finder: PNG -> JPG"       "$F/finder"    JPG    verify_jpeg "finder-photo.jpg"
scenario "Finder: ZIP -> Unzip"     "$F/finderzip" Unzip  verify_text "finder-archive/inner.txt"
scenario "Desktop folder: PNG -> JPG" "$DESK"      JPG    verify_jpeg "desktop-photo.jpg"
unset ICON_EXTRA
"$DRIVER" finder-close finder >> "$LOG" 2>&1
"$DRIVER" finder-close finderzip >> "$LOG" 2>&1
"$DRIVER" finder-close "$(basename "$DESK")" >> "$LOG" 2>&1
rm -f "$DESK/desktop-photo.png" "$DESK/desktop-photo.jpg"; rmdir "$DESK"
scenario "Batch 3 PNG -> 3 JPG"     "$F/batch" JPG      verify_jpeg "a.jpg" "b.jpg" "c.jpg"
# ---------------------------------------------------------------- 6. menu-bar icon (EXPERIMENTAL, non-gating)
# 1 Nov 2026: on this macOS a synthetic HID click does not open ANY status item's menu (a bare probe item with no
# drop layer behaves the same), and no synthetic drag onto a status item has reached the app yet. These rows report
# what happened without failing the run until a reliable method exists (see loop/LOG.md, iteration 1).
icon_record() { if [[ "$2" == PASS ]]; then record "$1" PASS "$3"; else record "$1" "EXPERIMENTAL-FAIL" "$3"; fi; }
# A real click still opens Halo's menu (the drop layer over the button must pass clicks through).
echo "===== Click menu-bar icon" >> "$LOG"
T_CLICK="$(date '+%Y-%m-%d %H:%M:%S')"; sleep 1
if ! "$DRIVER" click-icon >> "$LOG" 2>&1; then icon_record "Click menu-bar icon" FAIL "$(last_result)"
elif halo_log_since "$T_CLICK" | grep -q "Menu opened"; then icon_record "Click menu-bar icon" PASS "Halo logged Menu opened"
else icon_record "Click menu-bar icon" FAIL "no Menu opened in Halo's log"; fi
# Drop on the icon without Option, choose JPG from the menu that opens.
ICON_EXTRA=(--to-icon)
T_ICON="$(date '+%Y-%m-%d %H:%M:%S')"; sleep 1
FAILS_BEFORE=$FAILS
scenario "PNG on menu-bar icon -> JPG" "$F/icon" JPG verify_jpeg "photo.jpg"
if (( FAILS > FAILS_BEFORE )); then # demote to experimental
  FAILS=$FAILS_BEFORE; last="${RESULTS[${#RESULTS[@]}-1]}"; RESULTS[${#RESULTS[@]}-1]="${last/|FAIL|/|EXPERIMENTAL-FAIL|}"
fi
unset ICON_EXTRA
"$DRIVER" escape >> "$LOG" 2>&1
echo "icon drop, Halo log: $(halo_log_since "$T_ICON" | grep -oE 'Icon (drag entered|drop:.*)' | tr '\n' ';')" >> "$LOG"

# ---------------------------------------------------------------- 6b. home window (B3), last: needs it open again
# d. Re-opening a running Halo (`open` without -n sends a reopen) must bring the window back.
echo "===== reopen shows window" >> "$LOG"
open "$APP"
if ! "$DRIVER" home-window --timeout 5 >> "$LOG" 2>&1; then
  record "reopen shows window" FAIL "$(last_result)"
else
  SHOWN=0
  for _ in 1 2 3 4 5; do SHOWN="$(halo_log_since "$T_LAUNCH" | grep -c 'Home window shown')"; (( SHOWN >= 2 )) && break; sleep 1; done
  if (( SHOWN >= 2 )); then record "reopen shows window" PASS "window back; 'Home window shown' logged $SHOWN times since launch"
  else record "reopen shows window" FAIL "window back but 'Home window shown' logged $SHOWN times since launch (want 2)"; fi
fi

# Plain drag (no Option) of every file in dir onto halo.home.dropzone. Sets HOME_DROP (Halo's log line) or HOME_ERR.
home_drop() { # name dir
  local t inputs=(); for f in "$2"/*; do inputs+=("$f"); done
  t="$(date '+%Y-%m-%d %H:%M:%S')"; sleep 1
  HOME_DROP=""; HOME_ERR=""
  if ! drag "$1" --to-home "${inputs[@]}"; then HOME_ERR="drag: $(last_result)"; return 1; fi
  if ! wait_log "$t" "Home drop:" 5; then HOME_ERR="drag ended $(last_key SESSION) but Halo logged no 'Home drop:'"; return 1; fi
  HOME_DROP="$(halo_log_since "$t" | grep -o 'Home drop:.*' | tail -1)"
}
home_el() { echo "===== home-element $*" >> "$LOG"; "$DRIVER" home-element "$@" >> "$LOG" 2>&1; }

# c. Cancel first: the contract guarantees it returns to the drop zone, which the next drop needs.
home_cancel() {
  local name="home cancel" dir="$F/homecancel" before; before="$(listing "$dir")"
  home_drop "$name" "$dir" || { record "$name" FAIL "$HOME_ERR"; return; }
  home_el 'halo.home.action.*' --timeout 5 || { record "$name" FAIL "no action buttons after the drop: $(last_result)"; return; }
  home_el halo.home.cancel --timeout 3 --press || { record "$name" FAIL "Cancel: $(last_result)"; return; }
  home_el 'halo.home.action.*' --absent --timeout 3 || { record "$name" FAIL "action buttons still shown after Cancel"; return; }
  home_el halo.home.dropzone --timeout 3 || { record "$name" FAIL "drop zone not back after Cancel: $(last_result)"; return; }
  sleep 1
  [[ "$(listing "$dir")" == "$before" ]] || { record "$name" FAIL "folder changed: $(listing "$dir")"; return; }
  record "$name" PASS "$HOME_DROP; Cancel removed the action buttons, drop zone back, no new files"
}
home_cancel

# b. Drop, press the JPG button, the JPG lands next to the original.
HOME_JPG_OK=0
home_convert() {
  local name="home drop PNG -> JPG" dir="$F/home" out="$F/home/home-photo.jpg" v t
  t="$(date '+%Y-%m-%d %H:%M:%S')"
  home_drop "$name" "$dir" || { record "$name" FAIL "$HOME_ERR"; return; }
  home_el halo.home.action.image.to-jpg --timeout 5 --press || { record "$name" FAIL "JPG button: $(last_result)"; return; }
  wait_for 20 "$out" || { record "$name" FAIL "no output after 20 s; folder: $(listing "$dir")"; return; }
  sleep 0.5
  v="$(verify_jpeg "$out" 2>&1)" || { record "$name" FAIL "invalid output: $v"; return; }
  echo "$v" >> "$LOG"
  no_temp "$dir" || { record "$name" FAIL ".halo-* temp file left: $(listing "$dir")"; return; }
  alive || { record "$name" FAIL "Halo not running afterwards"; return; }
  HOME_JPG_OK=1
  local job; job="$(halo_log_since "$t" | grep -o 'image.to-jpg: [0-9]* outputs, [0-9]* failures' | tail -1)"
  record "$name" PASS "$HOME_DROP; pressed $(last_key PRESSED | cut -d' ' -f1); ${job:-job line not in log}; -> home-photo.jpg"
}
home_convert

# e. The result is listed in the window's recents, newest first.
if [[ $HOME_JPG_OK == 0 ]]; then
  record "recents lists result" FAIL "needs 'home drop PNG -> JPG' to pass first"
elif home_el halo.home.recent.0 --timeout 5 --expect-label home-photo.jpg; then
  record "recents lists result" PASS "halo.home.recent.0: $(last_key LABEL)"
else
  record "recents lists result" FAIL "$(last_result)"
fi

# ---------------------------------------------------------------- 7. ring opens on a pause, no key
quit_halo
# Quitting waits for jobs to settle (terminateLater): never launch while the old copy, with pause off, still runs.
for _ in $(seq 1 60); do [[ -z "$(halo_pid)" ]] && break; sleep 0.25; done
defaults write "$DOMAIN" halo.opensOnPause -bool true
T_LAUNCH="$(date '+%Y-%m-%d %H:%M:%S')"
open -n "$APP"
for _ in $(seq 1 40); do [[ -n "$(halo_pid)" ]] && break; sleep 0.25; done
PID="$(halo_pid)"
wait_log "$T_LAUNCH" "started:" 10 || echo "NOTE relaunched app logged no start line" >> "$LOG"
sleep 2
"$DRIVER" home-close --timeout 5 >> "$LOG" 2>&1
ICON_EXTRA=(--pause)
scenario "Pause: PNG -> JPG"        "$F/pause"       JPG  verify_jpeg "pause-photo.jpg"
ICON_EXTRA=(--pause --from-finder)
scenario "Pause, Finder: PNG -> JPG" "$F/pausefinder" JPG verify_jpeg "pausefinder-photo.jpg"
unset ICON_EXTRA
"$DRIVER" finder-close pausefinder >> "$LOG" 2>&1
no_output_scenario "Pause then drop in the hub reaches the app" "$F/pausethrough" --pause-through
open "$APP"; "$DRIVER" home-window --timeout 5 >> "$LOG" 2>&1
PH_BEFORE="$(listing "$F/pausehome")"
if drag "Pause over Halo's window: no ring" --to-home "$F/pausehome/home-pause-photo.png"; then
  record "Pause over Halo's window: no ring" PASS "$(last_result | sed 's/^PASS //')"
else
  record "Pause over Halo's window: no ring" FAIL "$(last_result)"
fi

# ---------------------------------------------------------------- global checks
if (cd "$F" && shasum -a 256 -c "$HASHES" >/dev/null 2>&1); then
  record "originals byte-identical" PASS "$(wc -l < "$HASHES" | tr -d ' ') files"
else
  record "originals byte-identical" FAIL "$(cd "$F" && shasum -a 256 -c "$HASHES" 2>&1 | grep -v ': OK' | tr '\n' ' ')"
fi
TEMPS="$(find "$F" -name '.halo-*')"
[[ -z "$TEMPS" ]] && record "no .halo-* temp files anywhere" PASS "searched $F" || record "no .halo-* temp files anywhere" FAIL "$TEMPS"
alive && record "Halo still running (same pid)" PASS "pid $PID" || record "Halo still running (same pid)" FAIL "pid now '$(halo_pid)'"
# Conversions ran in the worker (a separate process launched by launchd), not in Halo.
WPID="$(pgrep -x FrenzyWorker | head -1)"
if [[ -n "$WPID" && "$WPID" != "$PID" ]]; then
  record "conversions ran in the sandboxed worker" PASS "HaloWorker pid $WPID (ppid $(ps -o ppid= -p "$WPID" | tr -d ' ')), Halo pid $PID"
else
  record "conversions ran in the sandboxed worker" FAIL "no HaloWorker process"
fi
LEFT="$(find "$STAGING" -mindepth 1 -maxdepth 1 2>/dev/null)"
[[ -z "$LEFT" ]] && record "worker staging emptied after placement" PASS "$STAGING" || record "worker staging emptied after placement" FAIL "$LEFT"
CRASHES_AFTER="$(ls "$CRASH_DIR" 2>/dev/null | grep -i '^Frenzy' | sort)"
NEW_CRASHES="$(comm -13 <(echo "$CRASHES_BEFORE") <(echo "$CRASHES_AFTER") | grep -v '^$')"
[[ -z "$NEW_CRASHES" ]] && record "no new Halo crash reports" PASS "$CRASH_DIR" || record "no new Halo crash reports" FAIL "$NEW_CRASHES"
if [[ $SHOT == 1 ]]; then
  if [[ -s "$BUILD/ring-live.png" ]] && "$DRIVER" verify-image "$BUILD/ring-live.png" public.png >/dev/null; then
    record "screenshot ring-live.png" PASS "$(grep '^SCREENSHOT' "$LOG" | head -1 | cut -d' ' -f2)"
  else
    record "screenshot ring-live.png" FAIL "screencapture blocked or failed: $(grep '^SCREENSHOT' "$LOG" | head -1)"
  fi
fi

# ---------------------------------------------------------------- 6. report + quit
quit_halo
echo
echo "| # | Check | Result | Detail |"
echo "|---|---|---|---|"
n=0
for r in "${RESULTS[@]}"; do
  n=$((n + 1)); IFS='|' read -r name status detail <<< "$r"
  echo "| $n | $name | $status | $detail |"
done
echo
echo "driver log: $LOG"
if [[ $KEEP == 0 && $FAILS == 0 ]]; then rm -rf "$WORK"; echo "(temp folder removed; --keep to keep it)"; fi
[[ $FAILS == 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
