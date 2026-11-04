#!/usr/bin/env bash
# Non-live harness: extracts finish_concurrent_recovery from the test and
# drives its acceptance/rejection branches with stubbed fail/spawn_task.
set -u
T=${1:?test path}
W=$(mktemp -d)
awk '/^finish_concurrent_recovery\(\)/,/^}/' "$T" > "$W/fn.sh"
run() { echo "error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" > "$W/lock.err"; echo "error: something else broke" > "$W/other.err"; ( fail(){ echo "FAIL: $1"; exit 1; }; spawn_task(){ echo "retry-called"; return "${RETRY_RC:-0}"; }; RECOVERY_PROJECT_DIR=/x; . "$W/fn.sh"; finish_concurrent_recovery "$@" && echo "ACCEPTED" ); }
printf 'herdr_pane_id=p1\n' > "$W/meta"; printf 'herdr_pane_id=p2\n' > "$W/meta2"
echo 'error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume' > "$W/lock.err"
echo 'error: something else broke' > "$W/other.err"
echo "== status 0 (winner)"; run id h 0 "$W/o" "$W/other.err" "$W/meta" p1
echo "== documented lock refusal, pane unchanged -> retry"; run id h 1 "$W/o" "$W/lock.err" "$W/meta" p1; cat "$W/o"
echo "== unrelated error must fail"; run id h 1 "$W/o" "$W/other.err" "$W/meta" p1
echo "== lock refusal but pane changed must fail"; run id h 1 "$W/o" "$W/lock.err" "$W/meta2" p1
echo "== lock refusal, retry also fails must fail"; RETRY_RC=1 run id h 1 "$W/o" "$W/lock.err" "$W/meta" p1
rm -rf "$W"
