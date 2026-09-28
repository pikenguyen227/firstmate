#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh from <root> against an isolated
# state dir with DEFAULT FM_POLL/FM_SIGNAL_GRACE, seeded with <n> retained resolved
# pending-reply records, then plays a worker finishing its turn (append done:
# status line, then touch turn-ended <gap> seconds later). Prints how long until
# the watcher surfaces the wake.
set -u
ROOT=$1; N=$2; GAP=$3; LABEL=$4
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-latency-live)
dir=$(make_case "$LABEL"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
# Seed retained resolved pending-reply history via the production library.
( . "$ROOT/bin/fm-pending-reply-lib.sh"
  export FM_PENDING_REPLY_NOW=4850
  for i in $(seq 1 "$N"); do
    c=$(fm_pending_reply_create "$dir" "$state" "old$i" "old request $i")
    fm_pending_reply_mark_delivered "$state" "$c"
    printf 'done [corr=%s]: reply\n' "$c" >> "$state/old$i.status"
    fm_pending_reply_try_resolve "$state" "$c" >/dev/null
  done ) 2>/dev/null
resolved=$(grep -l '^phase=resolved' "$state"/pending-replies/* 2>/dev/null | wc -l | tr -d ' ')
# Prime prior turn so the pre-existing statuses/markers don't fire.
: > "$state/scout.turn-ended"; printf 'working: scouting\n' > "$state/scout.status"
start_watch() {
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>>"$dir/watch.err" &
  pid=$!
}
ack() {  # drain + ack like firstmate does before re-arming
  local err="$state/.drain.err" seq gen
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
# Adopt the existing logs as already seen, exactly as a long-running home has
# them: every old status via the product's fm_wake_status_mark_current, and
# the scout's previous-turn turn-end marker via its stat signature.
set_mtime() { touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" "$2"; }
set_mtime "$(( $(date +%s) - 300 ))" "$state/scout.turn-ended"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shift; st=$1; shift; for f in "$@"; do fm_wake_status_mark_current "$st" "$f" || echo "mark failed $f"; done' _ \
  "$ROOT/bin/fm-wake-lib.sh" "$state" "$state"/*.status
printf '%s' "$(stat -f '%z:%Fm' "$state/scout.turn-ended")" > "$state/.seen-scout_turn-ended"
start_watch
w=0; while kill -0 $pid 2>/dev/null && [ $w -lt 900 ]; do sleep 0.1; w=$((w+1)); done
kill -0 $pid 2>/dev/null || { echo "$LABEL: armed watcher woke on adopted history (harness priming failed): $(head -c 300 "$out")"; exit 1; }
echo "$LABEL: armed watcher quiet for 90s over adopted history"
t0=$(date +%s); echo "$LABEL: resolved_history=$resolved worker appends done: at t=0"
printf 'done: scout report ready\n' >> "$state/scout.status"
sleep "$GAP"; touch "$state/scout.turn-ended"; echo "$LABEL: turn-ended touched at t=$GAP"
last=""; i=0; while kill -0 $pid 2>/dev/null && [ $i -lt 1200 ]; do b=$(stat -f %m "$state/.last-watcher-beat" 2>/dev/null); [ "$b" != "$last" ] && [ -n "$b" ] && { echo "$LABEL: poll cycle began at t=$((b-t0))"; last=$b; }; sleep 0.1; i=$((i+1)); done
t1=$(date +%s)
kill $pid 2>/dev/null
echo "$LABEL: watcher surfaced wake after $((t1-t0))s"
echo "--- watcher stdout ---"; cat "$out"
echo "--- durable wake queue (new rows) ---"; FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | sed "s#$state#<state>#g" | cut -c1-220
