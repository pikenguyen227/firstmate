#!/usr/bin/env bash
# drive.sh <bin-dir> <label>
set -u
BIN=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
echo "=== [$LABEL] lab=$LAB"
echo "--- arm watcher under TZ=Asia/Ho_Chi_Minh (GMT+7)"
run TZ=Asia/Ho_Chi_Minh "$BIN/fm-watch-arm.sh" > "$LAB/arm1.out" 2>&1 &
ARM=$!
for i in $(seq 1 40); do grep -q 'watcher:' "$LAB/arm1.out" 2>/dev/null && break; sleep 0.5; done
cat "$LAB/arm1.out"
WPID=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
echo "lock pid=$WPID"
echo "lock pid-identity: $(cat "$LAB/state/.watch.lock/pid-identity")"
echo "ps lstart under GMT+7: $(TZ=Asia/Ho_Chi_Minh ps -p "$WPID" -o lstart=)"
echo "ps lstart under KST  : $(TZ=Asia/Seoul ps -p "$WPID" -o lstart=)"
echo "--- under TZ=Asia/Seoul (KST): re-arm (expect attach to live watcher)"
run TZ=Asia/Seoul "$BIN/fm-watch-arm.sh" > "$LAB/arm2.out" 2>&1 &
ARM2=$!
for i in $(seq 1 30); do grep -q 'watcher:' "$LAB/arm2.out" 2>/dev/null && break; sleep 0.5; done
cat "$LAB/arm2.out"; kill "$ARM2" 2>/dev/null
echo "--- under TZ=Asia/Seoul: lock-matches-pid via lock library"
run TZ=Asia/Seoul bash -c '. "$1/fm-wake-lib.sh"; fm_watcher_lock_matches_pid "$2/state" "$1/fm-watch.sh" "$3" "$2" && echo "MATCH: live watcher recognised" || echo "NO MATCH: live watcher NOT recognised"' _ "$BIN" "$LAB" "$WPID"
echo "--- under TZ=Asia/Seoul: fm-guard.sh"
run TZ=Asia/Seoul "$BIN/fm-guard.sh" 2>&1 | head -15
echo "(guard exit: ${PIPESTATUS[0]})"
echo "--- teardown"
kill "$WPID" "$ARM" 2>/dev/null; pkill -P "$ARM" 2>/dev/null; sleep 1
pgrep -f "$LAB" >/dev/null && pkill -f "$LAB"
wait 2>/dev/null
rm -rf "$LAB"; echo "lab removed"
