#!/usr/bin/env bash
# Live driver: real bin/fm-watch.sh from <root>, default FM_POLL/FM_SIGNAL_GRACE,
# isolated state seeded with <n> retained resolved pending-reply records (their
# old status logs removed so only the tick cost remains). A scout worker then
# finishes: appends done: and touches turn-ended <gap>s later. Reports the
# seconds until the watcher surfaces the wake, plus the durable queue row.
set -u
ROOT=$1; N=$2; GAP=$3; LABEL=$4
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-latency2)
dir=$(make_case "$LABEL"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
( . "$ROOT/bin/fm-pending-reply-lib.sh"
  export FM_PENDING_REPLY_NOW=4850
  for i in $(seq 1 "$N"); do
    c=$(fm_pending_reply_create "$dir" "$state" "old$i" "old request $i")
    fm_pending_reply_mark_delivered "$state" "$c"
    printf 'done [corr=%s]: reply\n' "$c" >> "$state/old$i.status"
    fm_pending_reply_try_resolve "$state" "$c" >/dev/null
  done ) 2>/dev/null
rm -f "$state"/old*.status
resolved=$(grep -l '^phase=resolved' "$state"/pending-replies/* 2>/dev/null | wc -l | tr -d ' ')
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>>"$dir/watch.err" &
pid=$!
sleep 20
kill -0 $pid 2>/dev/null || { echo "$LABEL: watcher exited before worker finished: $(head -c 300 "$out")"; exit 1; }
echo "$LABEL: resolved_history=$resolved; watcher armed and quiet for 20s"
t0=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
printf 'done: scout report ready\n' >> "$state/scout.status"
if [ "$GAP" = none ]; then :; else sleep "$GAP"; touch "$state/scout.turn-ended"; fi; echo "$LABEL: worker appended done: at t=0, turn-ended at t=$GAP"
i=0; while kill -0 $pid 2>/dev/null && [ $i -lt 1800 ]; do sleep 0.1; i=$((i+1)); done
t1=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
kill $pid 2>/dev/null
echo "$LABEL: watcher surfaced wake after $(echo "$t1 - $t0" | bc)s"
echo "--- watcher stdout ---"; sed "s#$state#<state>#g" "$out"
echo "--- durable wake queue ---"; FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | sed "s#$state#<state>#g" | cut -c1-200
