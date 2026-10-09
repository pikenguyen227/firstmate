#!/usr/bin/env bash
# Token-free live guard for the Claude session registry that
# fm_session_lock_owner_reclaimable in bin/fm-session-lock-lib.sh reads to decide
# whether a live front-end runs no conversation at all.
#
# The registry is Claude Code's own surface (<CLAUDE_CONFIG_DIR or
# ~/.claude>/sessions/<pid>.json), so it is proven here against the installed
# harness rather than a fixture: the guard must run inside a real Claude session,
# whose own record must name the session's current id, and the real library
# verdict is then driven against another live Claude process whose record names
# a conversation, in a scratch home: never reclaimable, whether the lock records
# that process's current conversation or one no live record names (the shape of
# a healthy owner between its own /clear and its SessionStart re-key). The
# registry is only read; no live home or lock is touched.
# A failure names the Claude version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_REGISTRY_LIVE claude jq

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
REGISTRY="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
LIB="$ROOT/bin/fm-session-lock-lib.sh"

if [ -z "${CLAUDE_PID:-}" ] || [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  [ "${FM_CLAUDE_REGISTRY_LIVE:-${FM_LIVE:-}}" != 1 ] \
    || fail "claude $CLAUDE_VERSION: FM_CLAUDE_REGISTRY_LIVE=1 needs a run inside a Claude session (no CLAUDE_PID)"
  printf 'skip: live: not running inside a Claude session\n'
  exit 0
fi

own="$REGISTRY/$CLAUDE_PID.json"
[ -f "$own" ] || fail "claude $CLAUDE_VERSION: no session registry record for this session's model loop at $own"
own_id=$(jq -r '.sessionId // empty' "$own") || fail "claude $CLAUDE_VERSION: this session's registry record is not JSON"
own_pid=$(jq -r '.pid // empty' "$own")
[ "$own_pid" = "$CLAUDE_PID" ] || fail "claude $CLAUDE_VERSION: the registry record at $own names pid '$own_pid'"
[ "$own_id" = "$CLAUDE_CODE_SESSION_ID" ] \
  || fail "claude $CLAUDE_VERSION: the registry names session '$own_id' for this process, not its current id '$CLAUDE_CODE_SESSION_ID'"
pass "claude $CLAUDE_VERSION: the session registry names this session's model loop and its current id"

LAB=$(fm_test_tmproot fm-session-lock-registry-live)
other=
other_id=
for record in "$REGISTRY"/*.json; do
  [ -f "$record" ] || continue
  pid=$(jq -r '.pid // empty' "$record" 2>/dev/null) || continue
  sid=$(jq -r '.sessionId // empty' "$record" 2>/dev/null) || continue
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  [ "$pid" != "$CLAUDE_PID" ] && [ -n "$sid" ] || continue
  # shellcheck disable=SC2016 # expanded by the child shell
  if bash -c '. "$1" && fm_harness_pid_alive "$2" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] \
      && ! fm_harness_ancestry_pids | grep -qx "$2"' _ "$LIB" "$pid"; then
    other=$pid
    other_id=$sid
    break
  fi
done
if [ -z "$other" ]; then
  printf 'skip: live: no second live Claude process to judge the reclaim verdict against\n'
  exit 0
fi

state="$LAB/state"
mkdir -p "$state"
printf '%s\n' "$other" > "$state/.lock"
verdict() {
  # shellcheck disable=SC2016 # expanded by the child shell
  bash -c '. "$1" && fm_session_lock_owner_reclaimable "$2"' _ "$LIB" "$state"
}
printf 'fm-live-guard-absent-%s\n' "$$" > "$state/.lock-session"
if verdict; then
  fail "claude $CLAUDE_VERSION: live pid $other runs conversation '$other_id', yet a lock recording another conversation was reclaimable"
fi
printf '%s\n' "$other_id" > "$state/.lock-session"
if verdict; then
  fail "claude $CLAUDE_VERSION: live pid $other still runs the recorded conversation '$other_id', yet its lock was reclaimable"
fi
pass "claude $CLAUDE_VERSION: the reclaim verdict keeps live pid $other, which runs a conversation, on the real registry"
