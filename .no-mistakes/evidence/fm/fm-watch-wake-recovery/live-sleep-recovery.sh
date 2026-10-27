#!/usr/bin/env bash
# Live driver: real bin/fm-watch.sh / fm-watch-arm.sh holders in a disposable
# lab FM_HOME. "Sleep" is simulated by SIGSTOPping the real holder and
# backdating its beacon into the 300-899s window (the 2026-10-26 refusal window).
# Usage: live-sleep-recovery.sh <bin-dir> <scenario> <log>
set -u
BIN=$1; SC=$2; LOG=$3
WT=/Users/pike/.no-mistakes/worktrees/81f2a0639ef5/01M5XH2KTS9NJK0H6W3HFD28B4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ST="$LAB/state"
exec > >(tee "$LOG") 2>&1
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 "$@"; }
backdate() {  # seconds
  local ts; ts=$(date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S); touch -t "$ts" "$ST/.last-watcher-beat"
  say "beacon backdated: age now $(( $(date +%s) - $(stat -f %m "$ST/.last-watcher-beat") ))s"
}
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" | cut -c1)" != Z ]; }
waitlock() { local i=0; while [ $i -lt 100 ]; do [ -s "$ST/.watch.lock/pid" ] && [ -e "$ST/.last-watcher-beat" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
cleanup() { for p in ${A:-} ${B:-}; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; sleep 1; pkill -f "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
say "bin=$BIN scenario=$SC lab=$LAB"

holder_poll=5; [ "$SC" = stalled ] && holder_poll=600
run FM_POLL=$holder_poll "$BIN/fm-watch.sh" > "$LAB/A.out" 2> "$LAB/A.err" &
A=$!
waitlock || { say "holder never took lock"; cat "$LAB/A.err"; exit 1; }
A=$(cat "$ST/.watch.lock/pid")   # the real watcher process (the & wrapper is a subshell)
ps -o pid=,stat=,command= -p "$A"
say "holder A pid=$A (real fm-watch.sh, FM_POLL=$holder_poll) lock=$(cat "$ST/.watch.lock/pid")"

case "$SC" in
  resumed|arm-resumed)
    kill -STOP "$A"; say "SIGSTOP holder A (machine asleep)"
    backdate 600 ;;
  stalled)
    backdate 600 ;;
  reused)
    kill -STOP "$A"
    sleep 300 & R=$!
    printf '%s\n' "$R" > "$ST/.watch.lock/pid"   # lock pid now names an unrelated live process (pid reuse)
    say "lock pid rewritten to unrelated live pid $R (sleep), recorded identity unchanged"
    backdate 600 ;;
esac

t0=$(date +%s)
if [ "$SC" = arm-resumed ]; then
  run FM_POLL=5 FM_WATCHER_STALE_OBSERVE=20 FM_ARM_CONFIRM_TIMEOUT=2 "$BIN/fm-watch-arm.sh" > "$LAB/B.out" 2> "$LAB/B.err" &
else
  run FM_POLL=5 FM_WATCHER_STALE_OBSERVE=${OBS:-10} "$BIN/fm-watch.sh" > "$LAB/B.out" 2> "$LAB/B.err" &
fi
B=$!
say "re-arm B pid=$B started"
if [ "$SC" = resumed ] || [ "$SC" = arm-resumed ]; then
  sleep 4
  kill -CONT "$A"; say "SIGCONT holder A (machine woke) at +$(( $(date +%s) - t0 ))s"
fi
i=0; while [ $i -lt 400 ] && alive "$B"; do
  [ "$SC" = stalled ] && [ "$(cat "$ST/.watch.lock/pid" 2>/dev/null)" = "$B" ] && grep -q 'replaced stalled' "$LAB/B.out" && break
  [ "$SC" = arm-resumed ] && grep -q 'attached pid=' "$LAB/B.out" && break
  sleep 0.1; i=$((i+1)); done
sleep 0.5
if alive "$B"; then say "B still running after +$(( $(date +%s) - t0 ))s"; else wait "$B"; say "B exited rc=$? after +$(( $(date +%s) - t0 ))s"; fi
say "--- B stdout"; cat "$LAB/B.out"; say "--- B stderr"; cat "$LAB/B.err"
say "holder A alive: $(alive "$A" && echo yes || echo no)"
say "lock pid now: $(cat "$ST/.watch.lock/pid" 2>/dev/null || echo none)"
[ -n "${R:-}" ] && { say "unrelated pid $R alive: $(alive "$R" && echo yes || echo no)"; kill "$R"; }
say "fm-watch.sh processes running from $BIN:"; pgrep -f "^bash $BIN/fm-watch.sh" | while read -r p; do ps -o pid=,stat=,command= -p "$p"; done
[ -f "$ST/.watch-cycle-exits.log" ] && { say "--- cycle ledger reasons"; awk -F'\t' '{print}' "$ST/.watch-cycle-exits.log" | grep -oE '(stale-holder-resumed|stalled-holder-replaced|unexpected-clean-exit)[^	]*' ; }
