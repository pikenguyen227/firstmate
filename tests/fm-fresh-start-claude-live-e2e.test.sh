#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for bin/fm-fresh-start.sh's session
# reader: the between-turns verdict, the latest turn's context usage, and the
# model id it measures against are all read from Claude Code's own session
# record, so they are proven here against the real installed harness.
#
# One short print-mode turn runs on a pinned session id in an isolated lab
# directory. The reader must then find that record through the home's
# .lock-session sidecar, read it as settled (print mode closes a turn with the
# stop_hook_summary marker; interactive mode also writes turn_duration, which
# docs/verification/runtime-backends.md records), and measure a non-zero
# context percentage against a model window it knows. A failure names the
# Claude version. Claude keeps its existing managed authentication; the lab's
# session record is removed afterwards and no live home is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

FRESH="$ROOT/bin/fm-fresh-start.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-fresh-start-live)
HOME_DIR="$LAB/home"
SID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || SID=
[ -n "$SID" ] || SID=$(perl -e 'printf "%08x-%04x-4%03x-a%03x-%012x", rand(2**32), rand(2**16), rand(2**12), rand(2**12), rand(2**48)')
CLAUDE_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

cleanup_record() {
  rm -f -- "$CLAUDE_ROOT"/projects/*/"$SID".jsonl
}
trap 'cleanup_record; fm_test_cleanup' EXIT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf '{"context_percent": 99, "idle_minutes": null, "nightly_at": null}\n' > "$HOME_DIR/config/fresh-start.json"

(cd "$HOME_DIR" && claude -p --model haiku --session-id "$SID" "Reply with the single word OK." >/dev/null 2>&1) \
  || fail "claude $CLAUDE_VERSION: the print-mode turn did not complete"
printf '%s\n' "$SID" > "$HOME_DIR/state/.lock-session"

out=$(FM_HOME="$HOME_DIR" "$FRESH" status 2>&1) || fail "claude $CLAUDE_VERSION: status failed: $out"
case "$out" in
  *"primary: busy -: mid-turn"*)
    fail "claude $CLAUDE_VERSION: a finished turn read as mid-turn; the turn-end marker changed: $out" ;;
  *"context unmeasured"*|*"record was not found"*|*"could not be read"*)
    fail "claude $CLAUDE_VERSION: the session record was not measured: $out" ;;
esac
pct=$(printf '%s\n' "$out" | sed -n 's/.*context \([0-9][0-9]*\)%.*/\1/p' | head -n 1)
[ -n "$pct" ] && [ "$pct" -ge 1 ] \
  || fail "claude $CLAUDE_VERSION: no positive context reading in: $out"
pass "claude $CLAUDE_VERSION: the session record reads settled with context ${pct}%"
