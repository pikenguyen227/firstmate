#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh [--fresh-start] <secondmate-id>... [--help]
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale - and
#      to rewrite its where-I-left-off note, which the fresh agent reads first.
#      That is the /stow skill's "Open-record persistence" and "Where-I-left-off
#      note" contracts and nothing else from it: no memory, learnings, or
#      captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel. The gate is that answer, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart without the answer. A timeout
#      deliberately leaves that unanswered expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#
# Restarts run ONE AT A TIME, in argument order among the mates whose answers
# have landed, while the gate keeps collecting the others' answers. A batch is
# therefore never more than one mate down at once, and no two replacement
# launches contend for one session. Each relaunch holds that mate's
# endpoint-liveness lock (bin/fm-control.sh owns it locally, and
# bin/fm-remote-secondmate-relaunch.sh for a remote route), so the watcher's
# dead-secondmate recovery cannot mistake the deliberately stopped agent for a
# dead one and race its own launch against the restart.
#
# A mate whose persist answer did not arrive or whose runtime cannot prove a
# restart gets the ordinary re-read nudge, and is reported as a nudge - never as
# a clean reload - only when a probe proves its agent is running; otherwise it
# is unreached, with the message still queued for its next agent. A failed
# relaunch is classified from the control plane's own transaction rows (the
# local journal, or the phase the host's relaunch reports) and a fresh endpoint
# probe, never from whatever its output printed first. bin/fm-control.sh runs
# the launch owner's validation before it stops anything, so a predictable
# refusal leaves the old agent running and is reported as a nudge. A mate whose
# agent is gone is retried once through the guarded secondmate respawn, under
# its liveness lock, and is reported restarted only when a replacement is then
# proven running. A mate still left with no agent is reported DOWN with the
# command that recovers it, and the batch stops there: every mate not yet
# restarted keeps its old agent and gets the re-read message instead.
#
# Placement changes the transport and nothing else. A local mate is restarted
# with bin/fm-control.sh <id> relaunch, which republishes this home's own
# metadata directly; a remote mate is restarted with
# bin/fm-remote-secondmate-relaunch.sh, which runs that same command on its
# host over bin/fm-on.sh and then republishes this primary's own route
# metadata from the identity the host confirmed, since the host-local verb can
# only rewrite its own endpoint record. The restart decision, the profile, the
# request text, the bound, the failure vocabulary, and this report are all
# computed here in the primary and are identical for both.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# --fresh-start is the automatic fresh start's use of this same pass
# (bin/fm-fresh-start.sh owns when that happens). The gate, the restart, and the
# report are unchanged; only two things differ. The persist request says why and
# also asks for the project map the fresh agent reads, and a mate this pass will
# not restart is reported `skipped:` and left alone, because the re-read nudge
# is an update remedy with nothing to offer a mate that simply keeps its
# conversation.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
#   FM_CONTROL_LIVENESS_WAIT    wait for another recovery of a down mate before
#                               its retry (180)
#   FM_SECONDMATE_LIVENESS_TIMEOUT  bound on that retry's launch (120)
#
# Exit status: 0 every named mate restarted; 3 at least one was nudged, skipped, or left
# unreached and every mate was still accounted for; 1 the input itself is
# unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,100{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
RETRY_LOCK_WAIT=${FM_CONTROL_LIVENESS_WAIT:-180}
RETRY_TIMEOUT=${FM_SECONDMATE_LIVENESS_TIMEOUT:-120}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac
case "$RETRY_LOCK_WAIT" in ''|*[!0-9]*|0) echo "error: FM_CONTROL_LIVENESS_WAIT must be a positive integer: $RETRY_LOCK_WAIT" >&2; exit 2 ;; esac
case "$RETRY_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_LIVENESS_TIMEOUT must be a positive integer: $RETRY_TIMEOUT" >&2; exit 2 ;; esac

IDS=()
FRESH_START=0
PERSIST_REQUEST=$FM_SECONDMATE_PERSIST_REQUEST
for arg in "$@"; do
  case "$arg" in
    --fresh-start)
      FRESH_START=1
      PERSIST_REQUEST=$FM_SECONDMATE_FRESH_START_REQUEST
      continue
      ;;
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
PLACEMENT=()
HOST=()
HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()

restarted_count=0
nudged_count=0
skipped_count=0
unreached_count=0

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# A mate's endpoint as one read, left in MATE_STATE: alive, down (no agent is
# running), or unknown. The shared liveness probe owns placement - a remote
# route is read on its own host - and a mate with no durable record reads
# unknown. The raw verdict is left in MATE_STATE_RAW for the report.
mate_state() {  # <id>
  MATE_STATE=unknown
  MATE_STATE_RAW=unknown
  [ -f "$STATE/$1.meta" ] || return 0
  fm_secondmate_liveness_probe "$STATE/$1.meta" "$1" poll
  MATE_STATE_RAW=$FM_SM_LIVE_STATE
  case "$FM_SM_LIVE_STATUS" in
    alive) MATE_STATE=alive ;;
    relaunchable) MATE_STATE=down ;;
  esac
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more,
# and it is reported only for a mate whose agent a probe proves is running: a
# queued message reaches no one while the agent is down, so an unconfirmed or
# down mate is unreached, with the message still queued for its next agent.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out state raw sent=1
  if [ "$FRESH_START" -eq 1 ]; then
    skipped_count=$((skipped_count + 1))
    printf 'skipped: %s: %s\n' "$id" "$reason"
    return
  fi
  mate_state "$id"
  state=$MATE_STATE
  raw=$MATE_STATE_RAW
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1) || sent=0
  if [ "$state" = alive ] && [ "$sent" -eq 1 ]; then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  elif [ "$sent" -eq 0 ]; then
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  else
    unreached_count=$((unreached_count + 1))
    printf "unreached: %s: %s; its agent could not be confirmed running (its endpoint reads '%s'), so the queued re-read message reaches no one yet\n" \
      "$id" "$reason" "$raw"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

# The line a failed control command's output most usefully reports: its last
# "error:" line, which is where the control plane's rollback states what it
# left behind, else its first line that carries anything.
final_reported_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | awk '/^error: / { l = $0 } END { print l }')
  if [ -n "$line" ]; then
    first_reported_line "$line"
  else
    first_reported_line "$1"
  fi
}

# A fingerprint of a local mate's relaunch transaction record, so a refusal that
# never opened a new transaction is told apart from one that did.
journal_print() {  # <id>
  { cksum < "$STATE/$1.control-relaunch"; } 2>/dev/null || printf 'none\n'
}

journal_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$STATE/$1.control-relaunch" 2>/dev/null | tail -1
}

report_restarted() {  # <array-index> <control-output> [note]
  local i=$1 ran_on
  ran_on=$(printf '%s\n' "$2" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
  [ -n "$ran_on" ] || ran_on=$(fm_meta_get "$STATE/${IDS[$i]}.meta" harness 2>/dev/null || true)
  [ -n "$ran_on" ] || ran_on=${HARNESS[i]}
  if [ "${PLACEMENT[i]}" = remote ]; then
    printf 'restarted: %s on %s (%s)%s\n' "${IDS[$i]}" "${HOST[i]}" "$ran_on" "${3:+; $3}"
  else
    printf 'restarted: %s (%s)%s\n' "${IDS[$i]}" "$ran_on" "${3:+; $3}"
  fi
}

# The one command that brings a mate with no agent back: the guarded secondmate
# respawn, which re-resolves the mate's placement and endpoint itself.
recovery_command() {  # <id>
  printf "FM_HOME='%s' '%s/fm-spawn.sh' %s --secondmate" "$FM_HOME" "$SCRIPT_DIR" "$1"
}

# A mate left with no agent: say so, name the command that recovers it, and mark
# the batch so no further mate is stopped.
report_down() {  # <array-index> <reason>
  local id=${IDS[$1]}
  : > "$RESULT_DIR/$1.down"
  report_unreached "$id" "DOWN - no agent is running: its previous agent was stopped and its replacement could not be launched, even on a retry: $2; recover it with: $(recovery_command "$id")"
}

# One retry for a mate whose old agent is gone. A remote mate goes back through
# its host-local relaunch, which takes the mate's liveness lock itself; a local
# one goes through the same guarded respawn the watcher's recovery uses, under
# that lock, so the watcher cannot act on the mate between this probe and this
# launch. The state after the attempt is left in MATE_STATE, and a failed
# launch's own words in RETRY_REASON.
retry_down_mate() {  # <array-index>
  local i=$1 id lock_rc=0 out
  id=${IDS[$i]}
  RETRY_REASON=
  if [ "${PLACEMENT[i]}" = remote ]; then
    out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-remote-secondmate-relaunch.sh" \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" < /dev/null 2>&1) \
      || RETRY_REASON=$(final_reported_line "$out")
    mate_state "$id"
    return 0
  fi
  fm_secondmate_liveness_lock_wait "$id" "$RETRY_LOCK_WAIT" || lock_rc=$?
  if [ "$lock_rc" -ne 0 ]; then
    RETRY_REASON="another recovery of $id held its endpoint for ${RETRY_LOCK_WAIT}s"
    mate_state "$id"
    return 0
  fi
  mate_state "$id"
  if [ "$MATE_STATE" = down ]; then
    fm_secondmate_liveness_relaunch "$STATE/$id.meta" "$id" "$RETRY_TIMEOUT" >/dev/null 2>&1 \
      || RETRY_REASON=$(final_reported_line "$FM_SM_LIVE_OUT")
    mate_state "$id"
  fi
  fm_secondmate_liveness_unlock "$id"
}

# Settle a failed relaunch into an outcome that matches the mate's real state.
# <phase> and <rollback> are the control plane's own transaction rows for this
# attempt: "untouched" when it refused before opening one, empty when unknown.
settle_failure() {  # <array-index> <phase> <rollback> <control-output>
  local i=$1 phase=$2 rollback=$3 out=$4 id reason state stopped=0
  id=${IDS[$i]}
  reason=$(final_reported_line "$out")
  [ -n "$reason" ] || reason="the restart failed without a reported reason"
  case "$phase:$rollback" in
    untouched:*|failed:checkpoint:*|failed:noted:*|failed:stopping:instructions-restored-agent-alive)
      fall_back_to_nudge "$id" "its restart was refused before its agent was touched, so it is still running its previous agent: $reason"
      return
      ;;
    failed:exited:*|failed:launching:*|failed:stopping:prior-record-kept-agent-dead) stopped=1 ;;
  esac
  mate_state "$id"
  state=$MATE_STATE
  if [ "$state" = down ]; then
    # Nothing is running, so a launch cannot duplicate an agent.
    stopped=1
    retry_down_mate "$i"
    state=$MATE_STATE
    [ -z "$RETRY_REASON" ] || reason="$reason; the retry: $RETRY_REASON"
  fi
  case "$state:$stopped" in
    alive:1) report_restarted "$i" "" ;;
    down:*) report_down "$i" "$reason" ;;
    alive:0) report_unreached "$id" "an agent is running, but whether its restart replaced it cannot be confirmed: $reason" ;;
    *) report_unreached "$id" "the restart outcome is unknown (its endpoint reads '$MATE_STATE_RAW'): $reason" ;;
  esac
}

restart_mate() {  # <array-index>
  local i=$1 id out rc before phase rollback
  id=${IDS[$i]}
  rc=0
  if [ "${PLACEMENT[i]}" = remote ]; then
    out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-remote-secondmate-relaunch.sh" \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" < /dev/null 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      report_restarted "$i" "$out"
      return
    fi
    # The host relaunched and confirmed its route, but this home's copy of the
    # route could not be republished: the replacement is running.
    if printf '%s\n' "$out" | grep -q "^relaunched $id " \
      && printf '%s\n' "$out" | grep -q '^schema=fm-remote-secondmate-control.v1$' \
      && mate_state "$id" && [ "$MATE_STATE" = alive ]; then
      report_restarted "$i" "$out" "this home's route record could not be updated: $(final_reported_line "$out")"
      return
    fi
    phase=$(printf '%s\n' "$out" | sed -n 's/^relaunch_phase=//p' | tail -1)
    rollback=$(printf '%s\n' "$out" | sed -n 's/^relaunch_rollback=//p' | tail -1)
  else
    before=$(journal_print "$id")
    out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-control.sh" "$id" relaunch 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      report_restarted "$i" "$out"
      return
    fi
    phase=untouched
    rollback=
    if [ "$(journal_print "$id")" != "$before" ]; then
      phase=$(journal_field "$id" phase)
      rollback=$(journal_field "$id" rollback)
    fi
  fi
  settle_failure "$i" "$phase" "$rollback" "$out"
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      skipped:*) skipped_count=$((skipped_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    [ ! -e "$RESULT_DIR/$i.down" ] || [ -n "$HALTED_BY" ] || HALTED_BY=${IDS[$i]}
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# After a mate is left with no agent, stop the batch: every mate still waiting
# for its answer or its turn keeps its old agent and gets the re-read message.
# A still-pending persist expectation stays open for the ordinary recovery
# ladder, exactly as a timeout leaves it.
halt_remaining() {
  local i
  [ -n "$HALTED_BY" ] || return 0
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    case "${PLAN[i]}" in
      ready) ready_count=$((ready_count - 1)) ;;
      persisted-pending) pending_count=$((pending_count - 1)) ;;
      *) i=$((i + 1)); continue ;;
    esac
    fall_back_to_nudge "${IDS[$i]}" \
      "it was not restarted because the batch stopped after $HALTED_BY was left with no agent running"
    PLAN[i]="done"
    i=$((i + 1))
  done
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$FM_SECONDMATE_RESTART_PLACEMENT
  HOST[i]=$FM_SECONDMATE_RESTART_HOST
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  if [ "${PLACEMENT[i]}" = remote ]; then
    # A local relaunch re-resolves this home's durable secondmate pin on its own,
    # which is the one owner of that resolution. A remote one cannot: it runs in
    # a home whose config/secondmate-harness is deliberately NOT inherited, so
    # the file on that host belongs to a different home and re-resolving there
    # would silently move the mate onto another runtime. Resolve the pin here and
    # pass it explicitly, so both placements land on the same decision.
    HARNESS[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    [ -n "${HARNESS[i]}" ] || HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
    MODEL[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    EFFORT[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "${EFFORT[i]}" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *) EFFORT[i]="" ;;
    esac
    if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
      REASON[i]="the configured Ultra profile does not select native Codex through Pi"
      i=$((i + 1))
      continue
    fi
  fi

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
ready_count=0
HALTED_BY=
restart_active_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

# Start the first confirmed mate, in argument order, when no restart is running.
launch_next_ready() {
  local i
  [ "$restart_active_count" -eq 0 ] || return 0
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = ready ]; then
      ready_count=$((ready_count - 1))
      launch_restart "$i"
      return 0
    fi
    i=$((i + 1))
  done
}

while [ "$((pending_count + ready_count + restart_active_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = persisted-pending ] \
      && fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
      pending_count=$((pending_count - 1))
      PLAN[i]=ready
      ready_count=$((ready_count + 1))
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
        pending_count=$((pending_count - 1))
        PLAN[i]=ready
        ready_count=$((ready_count + 1))
      else
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not confirm within ${PERSIST_WAIT}s that its open work is written down, so its conversation was not spent"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  harvest_restarts
  halt_remaining
  launch_next_ready
  [ "$((pending_count + ready_count + restart_active_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

if [ "$FRESH_START" -eq 1 ]; then
  printf 'summary: %d of %d restarted, %d skipped, %d unreached\n' \
    "$restarted_count" "${#IDS[@]}" "$skipped_count" "$unreached_count"
else
  printf 'summary: %d of %d restarted, %d nudged, %d unreached\n' \
    "$restarted_count" "${#IDS[@]}" "$nudged_count" "$unreached_count"
fi
[ "$((nudged_count + skipped_count + unreached_count))" -eq 0 ] || exit 3
exit 0
