#!/usr/bin/env bash
# Replay the reported incident against the real bin/fm-watch.sh with the real clock,
# scaled: FM_SECONDMATE_PARKED_GATE_SECS=4. Only fm-crew-state.sh is replaced by a
# stub printing a run-step parked line (a real parked no-mistakes run cannot be
# created inside a gate). The watcher is relaunched after each wake, as a primary does.
# usage: replay-parked-gate.sh <worktree> <watch-script> <scenario> <seconds>
set -u
WT=$1 WATCH=$2 SCEN=$3 DUR=$4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/root" "$LAB/crew"
cp -R "$WT/bin" "$LAB/root/bin"; cp "$WATCH" "$LAB/root/bin/fm-watch.sh"
cat > "$LAB/root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "${FM_FAKE_CREW_DIR:?}/$1" 2>/dev/null || echo 'state: unknown · source: none · no record'
SH
chmod +x "$LAB/root/bin/fm-crew-state.sh"
SUB="$LAB/mate-home"; mkdir -p "$SUB/state" "$SUB/data"
printf 'mate\n' > "$SUB/.fm-secondmate-home"; printf '# Firstmate\n' > "$SUB/AGENTS.md"
printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' "$SUB" > "$LAB/state/mate.meta"
printf 'window=x:y\nkind=ship\nharness=claude\nbackend=tmux\n' > "$SUB/state/job.meta"
printf 'state: parked · source: run-step · parked at ci: 2 finding(s) · ask-user: authority decision · run: r1\n' > "$LAB/crew/job"
case "$SCEN" in
  unescalated) : ;;
  escalated) printf 'needs-decision [at=1] [key=nm-r1-ci]: ask-user relayed to captain\n' > "$SUB/state/job.status" ;;
  unrelated) printf 'needs-decision [at=1] [key=scope-q]: which scope\nneeds-decision [at=2] [key=nm-r0-ci]: earlier run\n' > "$SUB/state/job.status" ;;
  late) : ;;
esac
start=$(date +%s); alerts=0; escalated_late=''
echo "scenario=$SCEN watcher=$(basename "$WATCH") threshold=4s duration=${DUR}s"
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  if [ "$SCEN" = late ] && [ "$alerts" -ge 1 ] && [ -z "$escalated_late" ]; then
    printf 'needs-decision [at=1] [key=nm-r1-ci]: relayed after first alert\n' > "$SUB/state/job.status"; escalated_late=1
    echo "t=$(( $(date +%s) - start ))s worker escalates nm-r1-ci after the first alert"
  fi
  out=$(FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/root" FM_STATE_OVERRIDE="$LAB/state" FM_FAKE_CREW_DIR="$LAB/crew" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' FM_SECONDMATE_PARKED_GATE_SECS=4 FM_SECONDMATE_PARKED_GATE_POLL_SECS=1 \
    FM_SECONDMATE_WAKE_STALL_SECS=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 perl -e 'alarm 3; exec @ARGV' "$LAB/root/bin/fm-watch.sh" 2>/dev/null)
  rm -rf -- "$LAB/state/.watch.lock" "$LAB/state/.watcher-down"
  if printf '%s' "$out" | grep -q 'secondmate worker parked'; then
    alerts=$((alerts+1)); echo "t=$(( $(date +%s) - start ))s WAKE: $(printf '%s' "$out" | grep -o 'check: secondmate worker parked.*' | head -1)"
    : > "$LAB/state/.wake-queue"
  fi
done
echo "marker: $(cat "$LAB/state/.secondmate-parked-gate-mate--job" 2>/dev/null)"
echo "TOTAL parent wakes for scenario=$SCEN: $alerts"
rm -rf "$LAB"
