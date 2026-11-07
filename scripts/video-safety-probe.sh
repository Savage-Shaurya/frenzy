#!/usr/bin/env bash
# Proves whether a command opened the Apple Video Encoder (AVE). Read-only: it only reads the IORegistry and the log.
# It never encodes, decodes or opens the encoder itself.
#
#   scripts/video-safety-probe.sh check                 one reading: AVE user clients now, encoder services, who holds AVE
#   scripts/video-safety-probe.sh watch -- <command…>   baseline, then <command> with a 0.1 s ioreg loop and a log stream
#                                                       around it, then a verdict
#
# The count is the IOKit class instance count of AppleAVE2UserClient (one per open hardware encode session, any process),
# the same number `ioreg -l -w0 -d2 | grep -o '"AppleAVE2UserClient"=[0-9]*'` prints.
#
# Exit codes (watch): 0 = AVE count stayed at 0 before, during and after. 3 = it rose: the command used hardware.
#                     4 = it wasn't 0 before starting (another app holds AVE): the command was NOT run.
#                     5 = the count couldn't be read: the command was NOT run. Otherwise the command's own failure code.
#
# If the count rises during a run that should be software: do NOT kill -9 anything (tearing a client down mid-encode
# preceded two of the panics). Let it finish, then fix the code. See docs/VIDEO-SAFETY.md and docs/VIDEO-SOFTWARE-PATH.md.
set -uo pipefail

ave_count() { # prints the number, or nothing when it can't be read
  ioreg -l -w0 -d2 2>/dev/null | grep -o '"AppleAVE2UserClient"=[0-9]*' | head -1 | cut -d= -f2
}

holders() { # which processes created AVE user clients (IOUserClientCreator under AppleAVE2Driver)
  ioreg -r -c AppleAVE2Driver -l -w0 2>/dev/null | grep -o '"IOUserClientCreator" = "[^"]*"' | sort | uniq -c
}

check() {
  local n; n="$(ave_count)"
  echo "AppleAVE2UserClient = ${n:-unreadable}"
  echo "VTEncoderXPCService processes: $(pgrep -l VTEncoderXPCService | tr '\n' ' ')"
  local h; h="$(holders)"
  [[ -n "$h" ]] && { echo "AVE held by:"; echo "$h"; }
  [[ -n "$n" ]] || return 5
  [[ "$n" == 0 ]] || return 4
}

watch_cmd() {
  [[ "${1:-}" == "--" ]] && shift
  (( $# > 0 )) || { echo "usage: $0 watch -- <command…>" >&2; exit 64; }
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/frenzy-ave-probe.XXXXXX")"
  echo "==> Before"
  check; local pre=$?
  if (( pre == 5 )); then echo "STOP: AVE count unreadable, not running the command." >&2; exit 5; fi
  if (( pre == 4 )); then echo "STOP: another process holds AVE. Quit Chrome, FaceTime, OBS, screen recording, then retry." >&2; exit 4; fi

  # Sampler: one line per 0.1 s, "time count".
  ( while :; do printf '%s %s\n' "$(date +%T)" "$(ave_count)"; sleep 0.1; done ) > "$dir/samples.txt" &
  local sampler=$!
  log stream --style compact --level debug \
    --predicate 'process == "VTEncoderXPCService" OR subsystem == "com.apple.videotoolbox" OR sender BEGINSWITH "AppleAVE" OR eventMessage CONTAINS[c] "AppleAVE"' \
    > "$dir/log.txt" 2>&1 &
  local logger=$!
  sleep 1 # let both start before the command

  echo "==> Running: $*"
  "$@"; local status=$?

  sleep 1 # catch a session that closes late
  kill "$sampler" "$logger" 2>/dev/null; wait "$sampler" "$logger" 2>/dev/null

  echo "==> After"
  check; local post=$?
  local peak; peak="$(awk '$2 != "" { if ($2 > m) m = $2 } END { print m + 0 }' "$dir/samples.txt")"
  local unread; unread="$(awk '$2 == "" { u++ } END { print u + 0 }' "$dir/samples.txt")"
  (( post == 4 && peak == 0 )) && peak=1 # still held after the run counts too
  echo "Samples: $(wc -l < "$dir/samples.txt" | xargs), unreadable: $unread, peak AppleAVE2UserClient: $peak"
  local hits; hits="$(grep -v 'Filtering the log data' "$dir/log.txt" | grep -iE 'AppleAVE|[.]ave[.]|AVE_|hardware' || true)"
  echo "Log lines mentioning AVE or hardware: $(printf '%s' "$hits" | grep -c . || true) (full log: $dir/log.txt)"
  [[ -n "$hits" ]] && printf '%s\n' "$hits" | head -20
  if (( unread > 0 )); then echo "VERDICT: UNPROVEN ($unread samples unreadable)."; exit 5; fi
  echo "Command exit code: $status. Files: $dir"
  if (( peak > 0 )); then echo "VERDICT: HARDWARE ENCODER WAS OPENED (peak $peak)."; exit 3; fi
  echo "VERDICT: AVE stayed at 0 for the whole run."
  exit "$status"
}

case "${1:-}" in
  check) check; exit $? ;;
  watch) shift; watch_cmd "$@" ;;
  *) sed -n '2,20p' "$0"; exit 64 ;;
esac
