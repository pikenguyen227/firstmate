#!/usr/bin/env bash
# Live drive: real Stop hook -> real fm-watch-arm.sh -> real fm-watch.sh in a
# disposable marked lab home. Old Claude primary arms, then dies abruptly while
# its watcher survives; a check wake is queued; a new Claude primary's Stop hook
# fires. Usage: inherited-watcher-live.sh <source-root> <label> [mode]
# mode: ended (default) | live-owner | spoof
set -u
SRC=$1; LABEL=$2; MODE=${3:-ended}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 9; }
git init -q "$LAB" && git -C "$LAB" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
cp -R "$SRC/bin" "$LAB/bin"
: > "$LAB/state/task.meta"
FAKEBIN="$LAB/.fakebin"; mkdir -p "$FAKEBIN" "$LAB/.userhome"
ln -s /bin/bash "$FAKEBIN/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"; chmod +x "$FAKEBIN/tmux"
export HOME="$LAB/.userhome" PATH="$FAKEBIN:$PATH" FM_HOME="$LAB"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=20
if [ "${DEFAULT_ENV:-0}" = 1 ]; then unset FM_POLL FM_SIGNAL_GRACE FM_CHECK_INTERVAL FM_HEARTBEAT FM_ARM_CONFIRM_TIMEOUT; log0="production default watcher timings"; else log0="fast test timings (FM_POLL=1)"; fi
ST="$LAB/state"
[ "$MODE" = live-owner ] && export KEEP_ALIVE=1
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
log "lab home: $LAB  source: $LABEL  mode: $MODE  timings: $log0"

# --- old Claude primary: hold the session lock, fire its Stop hook ------------
printf '{"session_id":"sess-old","stop_hook_active":false}\n' | \
  claude -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/old-hook.out" 2>&1; echo "RC=$?" >> "$FM_HOME/old-hook.out"; if [ "${KEEP_ALIVE:-0}" = 1 ]; then sleep 300; fi' &
OLD_CLAUDE=$!
for _ in $(seq 1 100); do [ -e "$ST/.last-watcher-beat" ] && [ -n "$(cat "$ST/.watch.lock/pid" 2>/dev/null)" ] && break; sleep 0.2; done
OLD_WATCHER=$(cat "$ST/.watch.lock/pid" 2>/dev/null)
OLD_LOCKDIR=$(readlink "$ST/.watch.lock")
log "old primary pid=$OLD_CLAUDE armed watcher pid=$OLD_WATCHER lockdir=$(basename "$OLD_LOCKDIR")"
log "watcher lock owner record (claude-owner): $(tr '\n' ' ' < "$OLD_LOCKDIR/claude-owner" 2>/dev/null || echo '<absent>')"

if [ "$MODE" = live-owner ]; then
  # Interrupt only the old hook/arm chain; the original primary process stays.
  CHAIN=$(pgrep -P "$OLD_CLAUDE"; for c in $(pgrep -P "$OLD_CLAUDE"); do pgrep -P "$c"; done)
  for p in $CHAIN; do
    [ "$p" = "$OLD_WATCHER" ] && continue
    if [ "${ARM_SURVIVES:-0}" = 1 ] && ps -o command= -p "$p" | grep -q fm-watch-arm.sh; then log "old arm pid=$p left running with its watcher"; continue; fi
    kill -KILL "$p" 2>/dev/null
  done
  sleep 1
  log "original primary STILL ALIVE (pid=$OLD_CLAUDE: $(kill -0 "$OLD_CLAUDE" 2>/dev/null && echo alive || echo dead)); its hook/arm interrupted; watcher pid=$OLD_WATCHER alive: $(kill -0 "$OLD_WATCHER" 2>/dev/null && echo yes || echo no)"
else
  # Abrupt end of the primary session (lab teardown / sleep): kill the claude
  # process and its hook/arm chain, but not the watcher.
  CHAIN=$(pgrep -P "$OLD_CLAUDE"; for c in $(pgrep -P "$OLD_CLAUDE"); do pgrep -P "$c"; done)
  for p in $CHAIN; do
    [ "$p" = "$OLD_WATCHER" ] && continue
    if [ "${ARM_SURVIVES:-0}" = 1 ] && ps -o command= -p "$p" | grep -q fm-watch-arm.sh; then log "old arm pid=$p left running (orphaned with its watcher)"; continue; fi
    kill -KILL "$p" 2>/dev/null
  done
  kill -KILL "$OLD_CLAUDE" 2>/dev/null; wait "$OLD_CLAUDE" 2>/dev/null
  sleep 1
  kill -0 "$OLD_WATCHER" 2>/dev/null && log "old primary ended; inherited watcher pid=$OLD_WATCHER SURVIVES" || log "old watcher died too (setup did not reproduce)"
fi

# --- queue a check wake -------------------------------------------------------
[ "$MODE" = live-owner ] || bash -c '. "$1"; fm_wake_append check inherited-check "check: inherited primary queued check"' _ "$LAB/bin/fm-wake-lib.sh"
log ".wake-queue now: $(tr '\n' '|' < "$ST/.wake-queue")"

# --- new Claude primary fires its Stop hook -----------------------------------
if [ "$MODE" = live-owner ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$OLD_WATCHER" 2>/dev/null || break; sleep 0.3; done
  log "pre-arm: original primary $OLD_CLAUDE alive=$(kill -0 "$OLD_CLAUDE" 2>/dev/null && echo yes || echo no); inherited watcher $OLD_WATCHER alive=$(kill -0 "$OLD_WATCHER" 2>/dev/null && echo yes || echo no)"
  sleep 300 & NEWP=$!
  printf '%s\n' "$NEWP" > "$ST/.lock"
  NEW_ID=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LAB/bin/fm-wake-lib.sh" "$NEWP")
  FM_WATCH_CLAUDE_OWNER_PID=$NEWP FM_WATCH_CLAUDE_OWNER_IDENTITY="$NEW_ID" FM_ARM_ATTACH_POLL=0.2 \
    "$LAB/bin/fm-watch-arm.sh" > "$LAB/live-arm.out" 2>&1 &
  LARM=$!
  sleep 3
  log "--- new lock-owner's arm output after 3s ---"; cat "$LAB/live-arm.out"
  log "inherited watcher $OLD_WATCHER alive=$(kill -0 "$OLD_WATCHER" 2>/dev/null && echo yes || echo no); lock pid now $(cat "$ST/.watch.lock/pid" 2>/dev/null)"
  for _ in $(seq 1 ${WAIT_SECS:-40}); do kill -0 "$LARM" 2>/dev/null || break; sleep 1; done
  log "--- arm output at end (arm alive=$(kill -0 "$LARM" 2>/dev/null && echo yes || echo no)) ---"; cat "$LAB/live-arm.out"
  log "--- watch-cycle-exits.log ---"; cat "$ST/.watch-cycle-exits.log" 2>/dev/null
  kill -TERM "$LARM" "$NEWP" "$OLD_CLAUDE" 2>/dev/null
  for p in $(pgrep -f "$LAB"); do kill -KILL "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$LAB"
  log "lab removed; leftover lab processes: $(pgrep -f "$LAB" | wc -l | tr -d ' ')"
  exit 0
fi
if [ "$MODE" = arm-spoof ]; then
  # Adversarial: a caller that does NOT hold state/.lock claims to be a Claude
  # owner and arms directly; the recorded owner has ended, but the takeover
  # must still be refused and the arm must attach to the existing watcher.
  sleep 300 & IMPOSTOR=$!
  IMP_ID=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LAB/bin/fm-wake-lib.sh" "$IMPOSTOR")
  log "impostor pid=$IMPOSTOR (session .lock still names $(cat "$ST/.lock"))"
  FM_WATCH_CLAUDE_OWNER_PID=$IMPOSTOR FM_WATCH_CLAUDE_OWNER_IDENTITY="$IMP_ID" FM_ARM_ATTACH_POLL=0.2 \
    "$LAB/bin/fm-watch-arm.sh" > "$LAB/spoof-arm.out" 2>&1 &
  SPOOF_ARM=$!
  sleep 8
  log "--- spoof arm output ---"; cat "$LAB/spoof-arm.out"
  log "old watcher pid=$OLD_WATCHER alive? $(kill -0 "$OLD_WATCHER" 2>/dev/null && echo yes || echo no); lock pid now $(cat "$ST/.watch.lock/pid" 2>/dev/null)"
  kill -TERM "$SPOOF_ARM" "$IMPOSTOR" 2>/dev/null
  for p in $(pgrep -f "$LAB"); do kill -KILL "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$LAB"
  log "lab removed; leftover lab processes: $(pgrep -f "$LAB" | wc -l | tr -d ' ')"
  exit 0
fi
SPOOF_ENV=""
[ "$MODE" = spoof ] && SPOOF_ENV="FM_WATCH_CLAUDE_OWNER_PID=1 FM_WATCH_CLAUDE_OWNER_IDENTITY=spoofed"
printf '{"session_id":"sess-new","stop_hook_active":false}\n' | \
  env $SPOOF_ENV claude -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/new-hook.out" 2>&1; echo "RC=$?" >> "$FM_HOME/new-hook.out"' &
NEW_CLAUDE=$!
log "new primary pid=$NEW_CLAUDE fired Stop hook"
for i in $(seq 1 ${WAIT_SECS:-60}); do kill -0 "$NEW_CLAUDE" 2>/dev/null || break; sleep 1; done
if kill -0 "$NEW_CLAUDE" 2>/dev/null; then
  log "new primary's Stop hook STILL PARKED after ${WAIT_SECS:-60}s (no wake delivered)"
  log "arm processes: $(pgrep -fl fm-watch-arm.sh | grep -F "$LAB" | tr '\n' ';')"
else
  log "new primary's Stop hook finished"
fi
log "--- new-hook.out ---"; cat "$LAB/new-hook.out" 2>/dev/null
log "--- old watcher pid=$OLD_WATCHER alive? $(kill -0 "$OLD_WATCHER" 2>/dev/null && echo yes || echo no)"
log "--- current watcher lock pid: $(cat "$ST/.watch.lock/pid" 2>/dev/null || echo none)"
log "--- old lockdir $(basename "$OLD_LOCKDIR") exists? $([ -e "$OLD_LOCKDIR" ] && echo "yes: $(ls -A "$OLD_LOCKDIR" | tr '\n' ' ')" || echo no)"
log "--- leftover .watch.lock.owner.* dirs: $(ls -d "$ST"/.watch.lock.owner.* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
log "--- autoarm outcome records ---"; grep -h . "$ST"/.claude-autoarm* 2>/dev/null | tail -5
log "--- watch-cycle-exits.log ---"; tail -5 "$ST/.watch-cycle-exits.log" 2>/dev/null
# --- teardown ---------------------------------------------------------------
for p in $(pgrep -f "$LAB"); do kill -TERM "$p" 2>/dev/null; done
kill -TERM "$NEW_CLAUDE" "$OLD_CLAUDE" 2>/dev/null; sleep 1
for p in $(pgrep -f "$LAB"); do kill -KILL "$p" 2>/dev/null; done
wait 2>/dev/null
rm -rf "$LAB"
log "lab removed; leftover lab processes: $(pgrep -f "$LAB" | wc -l | tr -d ' ')"
