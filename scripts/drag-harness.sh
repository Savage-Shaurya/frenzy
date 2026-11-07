#!/usr/bin/env bash
# Builds and runs the HaloDrag live harness (scripts/drag-harness/main.swift) straight from the module sources,
# so it doesn't touch Package.swift or any shared build directory.
#
#   scripts/drag-harness.sh            manual: drag any file, hold Option, watch the log (60 s, no permissions)
#   scripts/drag-harness.sh 120        manual for 120 s
#   scripts/drag-harness.sh --auto     synthesized CGEvent drag + PASS/FAIL checks (needs Accessibility for the terminal)
#   scripts/drag-harness.sh --auto --release   same, but Option is released mid-drag (expects a dismiss, no drop)
#   scripts/drag-harness.sh --zero-permission  monitor runs as its own .app (own TCC identity, no grants) while this
#                                      terminal only posts the events: proves detection needs no permission
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/halo-drag-harness"
mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"
PLUGINS=(-plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins)
COMMON=(-sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 6 -Onone -I "$OUT" -L "$OUT" "${PLUGINS[@]}")

build_lib() { # name, sources...
  local name="$1"; shift
  swiftc "${COMMON[@]}" -parse-as-library -enable-upcoming-feature ExistentialAny \
    -module-name "$name" -emit-module -emit-module-path "$OUT/$name.swiftmodule" \
    -emit-library -static -o "$OUT/lib$name.a" "$@"
}

echo "building harness into ${OUT}..."
build_lib HaloCore "$ROOT"/Sources/HaloCore/*.swift
build_lib HaloUI "$ROOT"/Sources/HaloUI/*.swift
build_lib HaloDrag "$ROOT"/Sources/HaloDrag/*.swift
swiftc "${COMMON[@]}" -lHaloCore -lHaloUI -lHaloDrag -o "$OUT/drag-harness" "$ROOT/scripts/drag-harness/main.swift"
if [[ "${1:-}" == "--zero-permission" ]]; then
  APP="$OUT/HaloDragHarness.app"; LOG="$OUT/zero-permission.log"
  mkdir -p "$APP/Contents/MacOS"
  cp "$OUT/drag-harness" "$APP/Contents/MacOS/HaloDragHarness"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.halo.drag-harness</string>
<key>CFBundleExecutable</key><string>HaloDragHarness</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/></dict></plist>
PLIST
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  rm -f "$LOG"
  # `open` makes the harness its own responsible process, so it does NOT inherit the terminal's permissions.
  open -n "$APP" --stdout "$LOG" --stderr "$LOG" --args 12
  sleep 2
  "$OUT/drag-harness" --post-only 8
  sleep 1
  echo "----- monitor process log ($LOG) -----"; cat "$LOG"
  grep -q "AX=false listen=false post=false" "$LOG" && grep -q "SUMMON" "$LOG" && grep -q "DROP" "$LOG" \
    && echo "PASS zero-permission: summon + drop with no Accessibility/Input Monitoring" \
    || { echo "FAIL zero-permission (see log)"; exit 1; }
  exit 0
fi
exec "$OUT/drag-harness" "$@"
