#!/usr/bin/env bash
# Builds dist/Frenzy.app and dist/Frenzy-<version>.dmg.
#
#   scripts/build-app.sh                          arm64, ad-hoc signed (local testing, testers)
#   scripts/build-app.sh --universal              arm64 + x86_64 in one binary
#   scripts/build-app.sh --sign "Developer ID Application: Snappy Crew (TEAMID)" --notarize halo-notary
#
# Options:
#   --universal            Build arm64 and x86_64 and merge them (Apple silicon and Intel Macs).
#   --sign IDENTITY        Code-signing identity. Default "-" (ad-hoc). Use a "Developer ID Application" identity
#                          for public releases.
#   --notarize PROFILE     After signing, notarize with `xcrun notarytool` using a keychain profile created by
#                          `xcrun notarytool store-credentials PROFILE ...`, then staple the app and the DMG.
#                          Requires --sign with a Developer ID identity.
#   --version X.Y.Z        Override CFBundleShortVersionString (default: from Resources/Info.plist).
#   --build N              Override CFBundleVersion (default: from Resources/Info.plist).
#   --skip-dmg             Stop after the signed .app.
#   --dist DIR             Write the app, DMG and logs here instead of dist/ (so it can't disturb a run using dist/).
#   --scratch DIR          SwiftPM scratch path (default .build/release).
#   -h, --help             Show this help.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="-"
NOTARY_PROFILE=""
UNIVERSAL=0
SKIP_DMG=0
VERSION=""
BUILD_NUMBER=""
DIST_OVERRIDE=""
SCRATCH_OVERRIDE=""
# Two compile jobs by default: this Mac must stay responsive while it builds (FRENZY_BUILD_JOBS to change).
BUILD_JOBS="${FRENZY_BUILD_JOBS:-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1; shift ;;
    --sign) IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
    --notarize) NOTARY_PROFILE="${2:?--notarize needs a keychain profile name}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --build) BUILD_NUMBER="${2:?}"; shift 2 ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    --dist) DIST_OVERRIDE="${2:?--dist needs a folder}"; shift 2 ;;
    --scratch) SCRATCH_OVERRIDE="${2:?--scratch needs a folder}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done

if [[ -n "$NOTARY_PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "error: --notarize needs --sign with a Developer ID Application identity (ad-hoc builds can't be notarized)." >&2
  exit 64
fi

PLIST_SRC="Resources/Info.plist"
ENTITLEMENTS="Resources/Halo.entitlements"
WORKER_PLIST_SRC="Resources/Worker-Info.plist"
WORKER_ENTITLEMENTS="Resources/HaloWorker.entitlements"
WORKER_ID="com.snappycrew.frenzy.worker"
ENGINE_ENTITLEMENTS="Resources/MediaEngine.entitlements"
ENGINE_ID="com.snappycrew.frenzy.media-engine"
ENGINE_SOURCE="$ROOT/vendor/build/arm64/bin/frenzy-media-engine"
ENGINE_LICENSES="$ROOT/vendor/build/arm64/licenses"
ICON="Resources/AppIcon.icns"
PB=/usr/libexec/PlistBuddy
[[ -n "$VERSION" ]] || VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST_SRC")"
[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$($PB -c 'Print :CFBundleVersion' "$PLIST_SRC")"

DIST="${DIST_OVERRIDE:-$ROOT/dist}"
mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd)"
APP="$DIST/Frenzy.app"
DMG="$DIST/Frenzy-$VERSION.dmg"
SCRATCH="${SCRATCH_OVERRIDE:-.build/release}"
LOG="$DIST/build-log.txt"
: > "$LOG"

step() { printf '\n==> %s\n' "$*"; }

# ── 0. Media engine ──────────────────────────────────────────────────────────────────────────────────────────
# Does nothing when vendor/build is up to date; otherwise builds it from vendor/sources (a few minutes).
"$ROOT/scripts/build-media-engine.sh"
"$ROOT/scripts/build-media-engine.sh" --check | tee -a "$LOG"

# ── 1. Compile ───────────────────────────────────────────────────────────────────────────────────────────────
if [[ "$UNIVERSAL" == 1 ]]; then
  echo "warning: the media engine is arm64 only. On an Intel Mac, formats that need it say so instead of converting." >&2
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  step "Building Frenzy $VERSION ($BUILD_NUMBER), release, universal (arm64 + x86_64)"
else
  ARCH_FLAGS=(--arch arm64)
  step "Building Frenzy $VERSION ($BUILD_NUMBER), release, arm64"
fi
set +e
for product in Halo HaloWorker; do
  swift build -c release -j "$BUILD_JOBS" --scratch-path "$SCRATCH" "${ARCH_FLAGS[@]}" --product "$product" 2>&1 | tee -a "$LOG" \
    | grep -E "error:|Build complete|Compiling .*(HaloApp|HaloWorker)"
  BUILD_STATUS="${PIPESTATUS[0]}"
  [[ "$BUILD_STATUS" == 0 ]] || break
done
set -e
[[ "$BUILD_STATUS" == 0 ]] || { echo "error: swift build failed (exit $BUILD_STATUS), see $LOG" >&2; exit 1; }
BIN_DIR="$(swift build -c release -j "$BUILD_JOBS" --scratch-path "$SCRATCH" "${ARCH_FLAGS[@]}" --show-bin-path)"
EXE="$BIN_DIR/Halo"
WORKER_EXE="$BIN_DIR/HaloWorker"
[[ -x "$EXE" ]] || { echo "error: no executable at $EXE" >&2; exit 1; }
[[ -x "$WORKER_EXE" ]] || { echo "error: no worker executable at $WORKER_EXE" >&2; exit 1; }
echo "Binary: $EXE ($(lipo -archs "$EXE"))"
echo "Worker: $WORKER_EXE ($(lipo -archs "$WORKER_EXE"))"

# ── 2. Assemble the bundle ───────────────────────────────────────────────────────────────────────────────────
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/Frenzy"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (none today). They belong in Contents/Resources so the bundle seals cleanly.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  echo "Copying resource bundle $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The sandboxed conversion worker: Contents/XPCServices/com.snappycrew.frenzy.worker.xpc
XPC="$APP/Contents/XPCServices/$WORKER_ID.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$WORKER_EXE" "$XPC/Contents/MacOS/FrenzyWorker"
cp "$WORKER_PLIST_SRC" "$XPC/Contents/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$XPC/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$XPC/Contents/Info.plist"
plutil -lint "$XPC/Contents/Info.plist" >/dev/null

# The media engine lives in the worker's bundle, so it starts as the worker's child and stays in its sandbox.
mkdir -p "$XPC/Contents/Helpers"
cp "$ENGINE_SOURCE" "$XPC/Contents/Helpers/frenzy-media-engine"
chmod 755 "$XPC/Contents/Helpers/frenzy-media-engine"

# What LGPL and BSD ask for: the notice and the licence texts, inside the app.
cp Resources/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ENGINE_LICENSES"/* "$APP/Contents/Resources/Licenses/"
cp "$ROOT/vendor/configure-line.txt" "$APP/Contents/Resources/Licenses/FFmpeg-configure-line.txt"

# ── 3. Sign ──────────────────────────────────────────────────────────────────────────────────────────────────
if [[ "$IDENTITY" == "-" ]]; then
  step "Signing ad-hoc with hardened runtime"
  TIMESTAMP=(--timestamp=none)
else
  step "Signing with \"$IDENTITY\" and hardened runtime"
  TIMESTAMP=(--timestamp) # Secure timestamp is required for notarization.
fi
# Inside-out: the engine first, then the worker (sandboxed, no network), then the app, whose signature seals the signed worker.
# The engine's entitlements are app-sandbox + inherit: it takes on its parent's sandbox and can't run outside one.
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements "$ENGINE_ENTITLEMENTS" \
  --identifier "$ENGINE_ID" --sign "$IDENTITY" "$XPC/Contents/Helpers/frenzy-media-engine"
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements "$WORKER_ENTITLEMENTS" \
  --identifier "$WORKER_ID" --sign "$IDENTITY" "$XPC"
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee -a "$LOG"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Runtime)" | tee -a "$LOG" || true
echo "App entitlements:"
codesign -d --entitlements :- "$APP" 2>/dev/null | tee -a "$LOG" || true
echo
echo "Worker entitlements ($WORKER_ID.xpc):"
codesign -d --entitlements :- "$XPC" 2>/dev/null | tee -a "$LOG" || true
echo
# Fail the build if the worker lost its sandbox or gained the network.
WORKER_ENT="$(codesign -d --entitlements :- "$XPC" 2>/dev/null || true)"
grep -q "com.apple.security.app-sandbox" <<<"$WORKER_ENT" || { echo "error: worker is not sandboxed" >&2; exit 1; }
if grep -q "com.apple.security.network" <<<"$WORKER_ENT"; then echo "error: worker has a network entitlement" >&2; exit 1; fi
# The same for the engine: it must inherit the sandbox and have nothing else.
ENGINE_ENT="$(codesign -d --entitlements :- "$XPC/Contents/Helpers/frenzy-media-engine" 2>/dev/null || true)"
echo "Media engine entitlements:"
echo "$ENGINE_ENT" | tee -a "$LOG"
echo
grep -q "com.apple.security.app-sandbox" <<<"$ENGINE_ENT" || { echo "error: engine is not sandboxed" >&2; exit 1; }
grep -q "com.apple.security.inherit" <<<"$ENGINE_ENT" || { echo "error: engine doesn't inherit the worker's sandbox" >&2; exit 1; }
if grep -q "com.apple.security.network" <<<"$ENGINE_ENT"; then echo "error: engine has a network entitlement" >&2; exit 1; fi
echo "Gatekeeper (spctl). Expected to be rejected unless signed with Developer ID and notarized:"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$DIST/spctl-app.txt" | tee -a "$LOG" || true

# ── 4. Notarize the app (optional) ───────────────────────────────────────────────────────────────────────────
notarize() { # $1 = file to submit (.zip or .dmg)
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m 2>&1 | tee -a "$LOG" | tee "$DIST/notary-last.txt"
  if ! grep -q "status: Accepted" "$DIST/notary-last.txt"; then
    local id
    id="$(awk '/^  id:/ {print $2; exit}' "$DIST/notary-last.txt")"
    echo "error: notarization was not accepted. Details:" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi
}

if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing Frenzy.app (profile: $NOTARY_PROFILE)"
  ZIP="$DIST/Frenzy-$VERSION-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$DIST/spctl-app.txt"
fi

# ── 5. Disk image ────────────────────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_DMG" == 0 ]]; then
  step "Creating $DMG"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/halo-dmg.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  ditto "$APP" "$STAGE/Frenzy.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Frenzy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" 2>&1 | tee -a "$LOG"
  hdiutil verify "$DMG" 2>&1 | tail -1 | tee -a "$LOG"

  if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
  fi
  if [[ -n "$NOTARY_PROFILE" ]]; then
    step "Notarizing $(basename "$DMG")"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 | tee "$DIST/spctl-dmg.txt"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────────────────────────────────────
step "Done"
echo "App:     $APP  ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/Frenzy"))"
if [[ "$SKIP_DMG" == 0 ]]; then
  echo "DMG:     $DMG  ($(du -h "$DMG" | cut -f1))"
  echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi
echo "Signed:  $([[ "$IDENTITY" == "-" ]] && echo "ad-hoc (testers use System Settings > Privacy & Security > Open Anyway, see docs/RELEASE.md)" || echo "$IDENTITY")"
echo "Notarized: $([[ -n "$NOTARY_PROFILE" ]] && echo yes || echo no)"
echo "Log:     $LOG"
