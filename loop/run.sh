#!/bin/bash
# Halo autonomous loop. Each iteration runs a fresh headless Claude Code session that follows loop/MISSION.md,
# works the top of loop/BACKLOG.md, verifies, and records results. Survives the chat session ending.
#
#   loop/run.sh                start (refuses if already running)
#   touch loop/PAUSE           pause before the next iteration (rm to resume)
#   touch loop/STOP            stop after the current iteration
#   tail -f loop/runner.log    watch
set -u
HALO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HALO/../.." && pwd)"
LOOP="$HALO/loop"
MODEL="${HALO_LOOP_MODEL:-claude-opus-5-5}"
MAX_ITER="${HALO_LOOP_MAX:-200}"
ITER_TIMEOUT=$((3 * 3600))       # watchdog per iteration
LIMIT_SLEEP=900                  # wait when the account limit is hit
mkdir -p "$LOOP/runs" "$LOOP/snapshots" "$LOOP/shots"

say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOOP/runner.log"; }

# Single instance.
PIDFILE="$LOOP/runner.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "loop already running (pid $(cat "$PIDFILE"))"; exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; say "runner exiting"' EXIT

# Keep the Mac awake while the loop runs (idle sleep only; the display may sleep).
caffeinate -i -w $$ &

iter=$(ls "$LOOP/runs" 2>/dev/null | sed -n 's/^iter-\([0-9]*\)\.log$/\1/p' | sort -n | tail -1)
iter=${iter:-0}
fails=0
say "runner started (pid $$, model $MODEL, next iteration $((iter + 1)))"

while (( iter < MAX_ITER )); do
  [[ -f "$LOOP/STOP" ]] && { say "STOP file found"; break; }
  while [[ -f "$LOOP/PAUSE" ]]; do sleep 30; done

  iter=$((iter + 1))
  RUNLOG="$LOOP/runs/iter-$iter.log"

  # Safety snapshot of the source tree before the iteration touches it (keep the last 15).
  tar -czf "$LOOP/snapshots/iter-$iter-before.tgz" -C "$HALO" \
      Package.swift Sources Tests scripts Resources docs README.md loop/BACKLOG.md loop/DECISIONS.md 2>/dev/null
  ls -1t "$LOOP/snapshots"/*.tgz 2>/dev/null | tail -n +16 | xargs rm -f 2>/dev/null

  PROMPT="You are iteration $iter of the Halo autonomous build loop, running headless with no human available.
Working directory: $ROOT. The product lives in apps/halo (website: apps/halo-site).
Read apps/halo/loop/MISSION.md now and follow it exactly: it has the goal, the founder's verdict, hard rules,
the per-iteration process, verification gates and the design rubric. Then work the backlog in
apps/halo/loop/BACKLOG.md. Ship one coherent, fully verified improvement this iteration (use parallel subagents
with disjoint file ownership when it helps), record evidence in apps/halo/loop/LOG.md under the heading
'## Iteration $iter', update the backlog and docs/STATE.md, then finish with a 5-line summary.
Never ask questions; decide and record decisions in apps/halo/loop/DECISIONS.md."

  say "iteration $iter: start"
  start=$(date +%s)
  ( cd "$ROOT" && claude -p "$PROMPT" --model "$MODEL" --permission-mode bypassPermissions \
        --output-format text > "$RUNLOG" 2>&1 ) &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    sleep 20
    if (( $(date +%s) - start > ITER_TIMEOUT )); then
      say "iteration $iter: watchdog timeout, killing"; pkill -P "$cpid" 2>/dev/null; kill "$cpid" 2>/dev/null
    fi
  done
  wait "$cpid"; rc=$?
  dur=$(( $(date +%s) - start ))

  if grep -qiE "usage limit|rate limit|limit reached|hit your limit|limit will reset|resets at|overloaded" "$RUNLOG" && (( dur < 600 )); then
    say "iteration $iter: account limit or overload after ${dur}s, sleeping ${LIMIT_SLEEP}s and retrying"
    mv "$RUNLOG" "$LOOP/runs/limited-$(date +%s).log"; iter=$((iter - 1))
    sleep "$LIMIT_SLEEP"; continue
  fi

  if (( rc != 0 )) || (( dur < 60 )); then
    fails=$((fails + 1))
    say "iteration $iter: rc=$rc after ${dur}s (consecutive failures: $fails)"
    sleep $(( fails > 5 ? 1800 : 120 * fails ))
  else
    fails=0
    say "iteration $iter: done in $((dur / 60)) min; $(tail -5 "$RUNLOG" | tr '\n' ' ' | cut -c1-300)"
    sleep 30
  fi
done
say "runner finished at iteration $iter"
