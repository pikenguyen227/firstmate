#!/usr/bin/env bash
# fm-step-up.sh - the automatic one-tier model step-up after a real worker
# failure: decide it, record it, and relaunch the same task one tier up.
#
# Usage:
#   fm-step-up.sh <task-id> plan  --trigger <failed|blocked|test-failure> --cause <text>
#                                 [--from-tier <tier>] [--autonomy <full|balanced|lean>]
#   fm-step-up.sh <task-id> apply --trigger <failed|blocked|test-failure> --cause <text>
#                                 [--from-tier <tier>] [--autonomy <full|balanced|lean>]
#                                 [--harness <h> [--model <m>] [--effort <e>]]
#                                 [--captain-approved]
#   fm-step-up.sh <task-id> test-failure --cause <text>
#
# The stuck-crewmate-recovery skill owns WHEN firstmate reaches for this and
# the judgment calls a script cannot make (whether a blocker is the worker's
# capability, whether stuck-crewmate recovery already failed to clear it).
# docs/configuration.md "Automatic one-tier step-up" owns the operator
# contract. This script owns every deterministic gate, so a step that breaks
# the rule cannot happen however the caller reasons:
#
#   trigger       failed        the task's latest status event is failed:
#                 blocked       the task has an open blocked: record and no
#                               open needs-decision:
#                 test-failure  `test-failure` has recorded at least two
#                               Test-step failures for this task
#   external      the cause text, or the triggering status note, naming an
#                 external system (CI, Azure, a vendor or outage, disk, the
#                 daemon, quota or rate limits, credentials or login, network)
#                 is never stepped; it errs wide, and a false match only costs
#                 the ordinary recovery path
#   one step      a task whose status log already holds a step record is
#                 never stepped again
#   tiers         the ladder is the dispatch rules whose `strategy` slot is
#                 check, light, standard, or hard, in that order, skipping a
#                 rung the home does not configure; the task's current tier is
#                 the one rung (or research) whose profiles contain the
#                 recorded harness, model, and effort, or --from-tier when that
#                 rung contains it; research and hard are never stepped
#   validation    a no-mistakes ship whose branch already has a concluded
#                 validation run is never stepped, because finishing it would
#                 need a second run; a live run stays with the task and the
#                 replacement is told to reattach to it, never to start another
#   posture       automatic only when the home's (or, in a second mate, the
#                 routed --autonomy) strategy template says
#                 autonomy.step_up=automatic; otherwise apply needs
#                 --captain-approved
#   profile       apply relaunches only on a profile of the next tier; a tier
#                 with several profiles needs the caller's quota-array-dispatch
#                 choice passed as --harness/--model/--effort
#
# plan is read-only. It prints a step-up: block and exits 0 when a step
# applies, or 1 with the reason when none does. apply runs the same plan,
# appends the step record to the task's status log (a `resolved` line per open
# blocked key, else `working`), then relaunches through
# bin/fm-control.sh <id> relaunch with the chosen profile and a note naming the
# cause, the tiers, the validation custody rule, and that the final status
# must name the tier the task finished on. The record is written before the
# relaunch so the one-step cap holds even when the relaunch fails; that
# failure appends `blocked [key=step-up]` and exits 3. test-failure appends one
# `working` record per observed Test-step failure and prints the count.
# Status appends are self-announced, so firstmate's own records never wake it.
#
# Exit codes: 0 step planned or applied (or failure recorded), 1 no step or
# refused, 2 usage or configuration error, 3 recorded but the relaunch failed.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_STEP_UP_CONTROL_BIN (the relaunch command, default bin/fm-control.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

[ -n "${FM_HOME:-}" ] || die "FM_HOME is not set; fm-step-up refuses to guess a firstmate home"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONTROL_BIN="${FM_STEP_UP_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
LADDER="check light standard hard"
STEP_PREFIX='stepped up from '
TEST_PREFIX='test-step failure '

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

case "${1:-}" in -h|--help|'') usage; exit 2 ;; esac
ID=$1; VERB=${2:-}
shift; [ "$#" -eq 0 ] || shift
case "$ID" in *[!A-Za-z0-9._-]*|.*) die "invalid task id: $ID" ;; esac
case "$VERB" in plan|apply|test-failure) ;; *) die "verb must be plan, apply, or test-failure" ;; esac

TRIGGER='' CAUSE='' FROM_TIER='' AUTONOMY_ARG='' APPROVED=0
PICK_H='' PICK_M='' PICK_E='' PICKED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trigger|--cause|--from-tier|--autonomy|--harness|--model|--effort)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --trigger) TRIGGER=$2 ;;
        --cause) CAUSE=$2 ;;
        --from-tier) FROM_TIER=$2 ;;
        --autonomy) AUTONOMY_ARG=$2 ;;
        --harness) PICK_H=$2; PICKED=1 ;;
        --model) PICK_M=$2; PICKED=1 ;;
        --effort) PICK_E=$2; PICKED=1 ;;
      esac
      shift 2 ;;
    --captain-approved) APPROVED=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

CAUSE=$(printf '%s' "$CAUSE" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
[ -n "$CAUSE" ] || die "--cause is required: the step record and relaunch note must name it"
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
[ -f "$META" ] && [ ! -L "$META" ] || die "no task record for $ID in this home"
meta() { sed -n "s/^$1=//p" "$META" | tail -1; }
KIND=$(meta kind)
case "$KIND" in ship|scout) ;; *) die "$ID is a ${KIND:-unknown} task; only a ship or scout is stepped" ;; esac

# Append status lines as firstmate's own self-announced records.
append_status() {
  local rc=0
  fm_wake_status_append_self_announced "$STATE" "$STATUS" "$@" || rc=$?
  [ "$rc" -ne 2 ] || { printf 'error: could not append to %s\n' "$STATUS" >&2; return 1; }
}

# One status line with its note capped so the stamp still fits.
capped_line() {  # <line>
  fm_cap_line_var "$1" "$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))"
  printf '%s' "$FM_LINE_CAP_LINE"
}

# Count status records whose note starts with <prefix>.
count_records() {  # <prefix>
  local line n=0
  [ -f "$STATUS" ] || { echo 0; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$(status_line_note "$line")" in "$1"*) n=$((n + 1)) ;; esac
  done < "$STATUS"
  echo "$n"
}

if [ "$VERB" = test-failure ]; then
  [ -z "$TRIGGER$FROM_TIER$AUTONOMY_ARG" ] && [ "$PICKED$APPROVED" = 00 ] \
    || die "test-failure takes only --cause"
  n=$(( $(count_records "$TEST_PREFIX") + 1 ))
  append_status "$(capped_line "working: ${TEST_PREFIX}$n recorded: $CAUSE")" || exit 2
  printf 'recorded test-step failure %s for %s\n' "$n" "$ID"
  exit 0
fi

case "$TRIGGER" in failed|blocked|test-failure) ;; *) die "--trigger must be failed, blocked, or test-failure" ;; esac
[ -z "$AUTONOMY_ARG" ] || case "$AUTONOMY_ARG" in full|balanced|lean) ;; *) die "--autonomy must be full, balanced, or lean" ;; esac
if [ "$VERB" = plan ] && [ "$PICKED$APPROVED" != 00 ]; then
  die "--harness, --model, --effort, and --captain-approved apply to apply only"
fi
[ -z "$PICK_M$PICK_E" ] || [ -n "$PICK_H" ] || die "--model and --effort need --harness"
command -v jq >/dev/null 2>&1 || die "jq required"

# ---- posture --------------------------------------------------------------------
LEVEL=$(sed -n 's/^autonomy=//p' "$CONFIG/strategy" 2>/dev/null | tail -1)
if [ -n "$AUTONOMY_ARG" ]; then
  [ -z "$LEVEL" ] || [ "$LEVEL" = "$AUTONOMY_ARG" ] || die "--autonomy $AUTONOMY_ARG contradicts this home's autonomy=$LEVEL"
  LEVEL=$AUTONOMY_ARG
fi
POSTURE=ask
if [ -n "$LEVEL" ] && [ -f "$FM_ROOT/bin/strategies/$LEVEL.json" ]; then
  [ "$(jq -r '.autonomy.step_up // "ask"' "$FM_ROOT/bin/strategies/$LEVEL.json")" != automatic ] || POSTURE=automatic
fi

no_step() {
  printf 'step-up:\n  task: %s\n  verdict: no-step\n  reason: %s\n' "$ID" "$1"
  exit 1
}

# Words that name a system outside the worker's control. Errs wide.
EXTERNAL_RE='(^|[^a-z])(ci|azure|outage|vendor|overloaded|server error|disk|no space|daemon|quota|rate[ -]?limit(ed|s)?|credentials?|login|logged out|unauthori[sz]ed|network|dns)([^a-z]|$)'
external_hit() {  # <text>
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | grep -Eq -- "$EXTERNAL_RE"
}

# ---- one step per task ----------------------------------------------------------
[ "$(count_records "$STEP_PREFIX")" -eq 0 ] || no_step "already stepped up once; report a further failure to the captain with the evidence"

# ---- trigger --------------------------------------------------------------------
TRIGGER_NOTE='' BLOCKED_KEYS=''
case "$TRIGGER" in
  failed)
    last=$(last_status_line "$STATUS")
    [ "$(status_line_verb "$last")" = failed ] || no_step "the latest status event is not failed:"
    TRIGGER_NOTE=$(status_line_note "$last")
    ;;
  blocked)
    open=$(status_open_decisions "$STATUS")
    while IFS=$'\t' read -r key verb note; do
      case "$verb" in
        needs-decision) no_step "decision '$key' is open; settle it before any step-up" ;;
        blocked) BLOCKED_KEYS="$BLOCKED_KEYS${BLOCKED_KEYS:+ }$key"; TRIGGER_NOTE="$TRIGGER_NOTE${TRIGGER_NOTE:+ / }$note" ;;
      esac
    done <<EOF
$open
EOF
    [ -n "$BLOCKED_KEYS" ] || no_step "no open blocked: record"
    ;;
  test-failure)
    tests=$(count_records "$TEST_PREFIX")
    [ "$tests" -ge 2 ] || no_step "only $tests Test-step failure(s) recorded; the second one triggers the step"
    ;;
esac
if external_hit "$CAUSE" || external_hit "$TRIGGER_NOTE"; then
  no_step "the cause names an external system, which a stronger model cannot fix"
fi

# ---- tiers ----------------------------------------------------------------------
RULES="$CONFIG/crew-dispatch.json"
[ -f "$RULES" ] || no_step "no dispatch profiles configured, so there is no tier ladder"
jq -e 'type == "object"' "$RULES" >/dev/null 2>&1 || die "malformed $RULES"
HARNESS=$(meta harness); MODEL=$(meta model); EFFORT=$(meta effort)
norm() { case "$1" in ''|-|default) printf '' ;; *) printf '%s' "$1" ;; esac; }
MODEL=$(norm "$MODEL"); EFFORT=$(norm "$EFFORT")

# Profiles of the first rule in slot <tier>, one "harness<TAB>model<TAB>effort" per line.
tier_profiles() {  # <tier>
  jq -r --arg t "$1" '
    [(.rules // [])[] | select(.strategy == $t)] | first // empty
    | (if (.use | type) == "array" then .use else [.use] end)[]
    | [.harness, (.model // ""), (.effort // "")] | @tsv' "$RULES"
}
tier_has_profile() {  # <tier> <harness> <model> <effort>
  tier_profiles "$1" | grep -Fxq -- "$2"$'\t'"$3"$'\t'"$4"
}
profile_text() { printf '%s%s%s' "$1" "${2:+ $2}" "${3:+ $3}"; }

CURRENT_PROFILE=$(profile_text "$HARNESS" "$MODEL" "$EFFORT")
if [ -n "$FROM_TIER" ]; then
  case " $LADDER research " in *" $FROM_TIER "*) ;; *) die "--from-tier must be one of: $LADDER research" ;; esac
  tier_has_profile "$FROM_TIER" "$HARNESS" "$MODEL" "$EFFORT" \
    || no_step "the task runs $CURRENT_PROFILE, which is not a $FROM_TIER profile"
  FROM=$FROM_TIER
else
  matches=''
  for t in $LADDER research; do
    tier_has_profile "$t" "$HARNESS" "$MODEL" "$EFFORT" && matches="$matches${matches:+ }$t"
  done
  case "$matches" in
    *research*) FROM=research ;;
    '') no_step "the task runs $CURRENT_PROFILE, which matches no tier; pass --from-tier when firstmate knows it" ;;
    *' '*) no_step "the task runs $CURRENT_PROFILE, which matches tiers '$matches'; pass --from-tier" ;;
    *) FROM=$matches ;;
  esac
fi
[ "$FROM" != research ] || no_step "a research scout is never stepped up"
[ "$FROM" != hard ] || no_step "the hard tier is the top of the ladder; take the failure to the captain with the evidence"
TO='' seen=0
for t in $LADDER; do
  if [ "$seen" = 1 ] && [ -n "$(tier_profiles "$t")" ]; then TO=$t; break; fi
  [ "$t" = "$FROM" ] && seen=1
done
[ -n "$TO" ] || no_step "no tier above $FROM is configured; take the failure to the captain with the evidence"
CANDIDATES=$(tier_profiles "$TO")

# ---- validation custody ---------------------------------------------------------
MODE=$(meta mode)
VALIDATION=none
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  WT=$(meta worktree); BRANCH=$(meta branch)
  [ -d "$WT" ] && [ -n "$BRANCH" ] || no_step "cannot read the task's local copy or branch to prove its validation state"
  overview=$(fm_nm_run "$WT" 10 axi)
  sel=$(fm_nm_select_run "$BRANCH" "$overview" "$WT")
  case "$sel" in
    absent) VALIDATION=none ;;
    selected\|*)
      IFS='|' read -r _ run_id run_status _ <<<"$sel"
      case "$(fm_nm_run_status_class "$run_status")" in
        live) VALIDATION="active $run_id" ;;
        *) no_step "validation run $run_id already $run_status; finishing after a step would need a second validation run" ;;
      esac ;;
    *) no_step "cannot prove the task's validation state (${sel:-no answer})" ;;
  esac
fi

print_plan() {
  printf 'step-up:\n  task: %s\n  verdict: step\n  trigger: %s\n  cause: %s\n' "$ID" "$TRIGGER" "$CAUSE"
  printf '  from: %s (%s)\n  to: %s\n' "$FROM" "$CURRENT_PROFILE" "$TO"
  while IFS=$'\t' read -r h m e; do
    printf '  candidate: --harness %s%s%s\n' "$h" "${m:+ --model $m}" "${e:+ --effort $e}"
  done <<<"$CANDIDATES"
  printf '  validation: %s\n  posture: %s%s\n' "$VALIDATION" "$POSTURE" "${LEVEL:+ (autonomy $LEVEL)}"
}

if [ "$VERB" = plan ]; then
  print_plan
  exit 0
fi

# ---- apply ----------------------------------------------------------------------
[ "$POSTURE" = automatic ] || [ "$APPROVED" = 1 ] \
  || no_step "autonomy ${LEVEL:-unset} does not step automatically; ask the captain, then pass --captain-approved"
if [ "$PICKED" = 1 ]; then
  printf '%s\n' "$CANDIDATES" | grep -Fxq -- "$PICK_H"$'\t'"$PICK_M"$'\t'"$PICK_E" \
    || no_step "$(profile_text "$PICK_H" "$PICK_M" "$PICK_E") is not a $TO profile"
elif [ "$(printf '%s\n' "$CANDIDATES" | wc -l | tr -d ' ')" -eq 1 ]; then
  IFS=$'\t' read -r PICK_H PICK_M PICK_E <<<"$CANDIDATES"
else
  no_step "the $TO tier has several profiles; resolve them through quota-array-dispatch and pass the eligible one as --harness/--model/--effort"
fi
TARGET_PROFILE=$(profile_text "$PICK_H" "$PICK_M" "$PICK_E")

case "$TRIGGER" in
  failed) WHY="a terminal failure" ;;
  blocked) WHY="a blocker recovery could not clear" ;;
  test-failure) WHY="a second Test-step failure" ;;
esac
record="${STEP_PREFIX}$FROM to $TO ($TARGET_PROFILE) after $WHY: $CAUSE"
lines=()
if [ "$TRIGGER" = blocked ]; then
  for k in $BLOCKED_KEYS; do lines+=("$(capped_line "resolved [key=$k]: $record")"); done
else
  lines+=("$(capped_line "working: $record")")
fi

case "$VALIDATION" in
  active*) custody="A validation run already owns this branch: reattach with \`no-mistakes axi run\` (no flags) and keep driving it; never start a second validation run, abort it, or hand-edit while it is active." ;;
  *) custody="Validate exactly once when the work is ready, as your instructions say; there is no second validation run." ;;
esac
NOTE="Automatic one-tier step-up: you replace the $FROM-tier worker ($CURRENT_PROFILE) as the $TO tier ($TARGET_PROFILE) after $WHY: $CAUSE
Continue the same task in this same local copy and branch; earlier commits and uncommitted changes are preserved.
$custody
Name the tier you finished on in your final done: or failed: status line, for example \"(tier: $TO, stepped up from $FROM)\".
There is no further automatic step: report another failure or blocker plainly."

append_status "${lines[@]}" || exit 2
relaunch=("$CONTROL_BIN" "$ID" relaunch --harness "$PICK_H" --model "${PICK_M:-default}" --effort "${PICK_E:-default}" --note "$NOTE")
if ! out=$(FM_HOME=$FM_HOME "${relaunch[@]}" 2>&1); then
  printf '%s\n' "$out" >&2
  append_status "$(capped_line "blocked [key=step-up]: step-up relaunch to $TO ($TARGET_PROFILE) failed; the step is used, so take it to the captain with the evidence")" || true
  echo "error: the step-up was recorded but the relaunch failed; see the output above" >&2
  exit 3
fi
[ -z "$out" ] || printf '%s\n' "$out"
printf 'stepped-up %s %s -> %s (%s)\n' "$ID" "$FROM" "$TO" "$TARGET_PROFILE"
