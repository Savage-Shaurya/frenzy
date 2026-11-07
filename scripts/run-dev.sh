#!/usr/bin/env bash
# Builds dist/Frenzy.app (ad-hoc signed, no DMG), quits any running Halo, and launches the fresh build.
#
#   scripts/run-dev.sh            build and launch
#   scripts/run-dev.sh --logs     also stream Halo's log messages until Ctrl-C
#
# Runs from the .app bundle (not `swift run`) so LSUIElement, the icon and launch at login behave like a release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STREAM_LOGS=0
BUILD_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --logs) STREAM_LOGS=1 ;;
    *) BUILD_ARGS+=("$arg") ;;
  esac
done

"$ROOT/scripts/build-app.sh" --skip-dmg ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

if pgrep -x Frenzy >/dev/null; then
  echo "Quitting the running Frenzy"
  osascript -e 'quit app "Frenzy"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Frenzy >/dev/null || break; sleep 0.3; done
  pkill -x Frenzy 2>/dev/null || true
fi

open "$ROOT/dist/Frenzy.app"
echo "Frenzy launched. Look for the ring icon in the menu bar."

if [[ "$STREAM_LOGS" == 1 ]]; then
  log stream --style compact --level info --predicate 'subsystem == "com.snappycrew.frenzy"'
fi
