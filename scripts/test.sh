#!/usr/bin/env bash
# Runs the unit tests, then moves every temp folder the run created (test images, PDFs, archives, staging, renders)
# to the Bin, so nothing is left in temp or in the project. The founder asked for this on 7 Nov 2026.
#
#   scripts/test.sh                      all non-video tests (-j 2, one at a time)
#   scripts/test.sh --filter Ring        any extra arguments go to `swift test`
#   KEEP_TEST_DATA=1 scripts/test.sh     leave the run's temp folders in place to look at them
#
# Video encoding tests stay off unless FRENZY_VIDEO_TESTS=1 (see CLAUDE.md "Mac safety"). Foundation ignores TMPDIR on
# macOS, so this compares the temp folder before and after instead of giving the run its own one.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp/}")"; TMP="${TMP%/}"
is_test_data() { # names the tests and the worker create; build folders (*-build) are caches, not test data
  case "$1" in
    *-build|*.lock|_Users_*) return 1;;
    halo-*|Halo*|frenzy-*|Frenzy*) return 0;;
    *) return 1;;
  esac
}

BEFORE_LIST="$(ls -1 "$TMP")"

swift test -j 2 --no-parallel "$@"
CODE=$?

moved=0
if [[ "${KEEP_TEST_DATA:-0}" != 1 ]]; then
  BIN="$HOME/.Trash/Frenzy test run $(date '+%Y-%m-%d %H.%M.%S')"
  while IFS= read -r name; do
    [[ -n "$name" ]] && is_test_data "$name" || continue
    grep -qxF -- "$name" <<< "$BEFORE_LIST" && continue
    mkdir -p "$BIN" && mv -- "$TMP/$name" "$BIN/" && moved=$((moved + 1))
  done < <(ls -1 "$TMP")
  if (( moved > 0 )); then echo "test data: moved $moved temp folder(s) to the Bin ($(basename "$BIN"))"
  else echo "test data: nothing left behind"; fi
fi
exit $CODE
