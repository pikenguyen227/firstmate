#!/usr/bin/env bash
# Times the real fm_pending_reply_tick over <n> retained resolved records plus
# one resolved record whose escalation close is still owed, then checks the
# owed close converged.
set -u
ROOT=$1; N=$2; LABEL=$3
. "$ROOT/tests/lib.sh"
home=$(fm_test_tmproot fm-tick-live); state="$home/state"; mkdir -p "$state"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_NOW=4850
for i in $(seq 1 "$N"); do
  c=$(fm_pending_reply_create "$home" "$state" "old$i" "req $i")
  fm_pending_reply_mark_delivered "$state" "$c"
  printf 'done [corr=%s]: reply\n' "$c" >> "$state/old$i.status"
  fm_pending_reply_try_resolve "$state" "$c" >/dev/null
done 2>/dev/null
owed=$(fm_pending_reply_create "$home" "$state" hibit "owed close")
fm_pending_reply_mark_delivered "$state" "$owed"
rec=$(fm_pending_reply_path "$state" "$owed")
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=owed close\n' "$owed" "$owed" >> "$state/hibit.status"
fm_pending_reply_set "$rec" escalated_epoch 4800
fm_pending_reply_set "$rec" resolved_epoch 4840
fm_pending_reply_set "$rec" resolved_via status
fm_pending_reply_set "$rec" phase resolved
echo "$LABEL: records=$(ls "$state/pending-replies" | wc -l | tr -d ' ') resolved=$(grep -l '^phase=resolved' "$state"/pending-replies/* | wc -l | tr -d ' ')"
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
fm_pending_reply_tick "$state"
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "$LABEL: one fm_pending_reply_tick took $(echo "$e - $s" | bc)s"
echo "$LABEL: owed record escalation_closed_epoch=$(fm_pending_reply_get "$rec" escalation_closed_epoch)"
echo "$LABEL: hibit.status tail:"; tail -2 "$state/hibit.status"
