#!/usr/bin/env bash
# fm-fresh-start.sh - automatic fresh starts for long-running agents.
#
# Usage:
#   fm-fresh-start.sh check                  watcher poll: one line when something is due, silent otherwise
#   fm-fresh-start.sh status [<mate-id>...]  print the current decision for this home and its second mates
#   fm-fresh-start.sh run <mate-id>...       re-decide, then fresh-start each named mate that is still due
#   fm-fresh-start.sh arm [--if-configured]  write and register state/fresh-start.check.sh
#   fm-fresh-start.sh disarm                 remove the check shim and its trust binding
#   fm-fresh-start.sh --help
#
# A second mate and the primary run for days and go through many compactions.
# A fresh start - a new agent that reads the home's where-I-left-off note and
# project map instead of re-scanning its repositories - is the reset. This
# script decides WHEN; it never performs the reset itself.
#
#   A second mate is fresh-started only through bin/fm-secondmate-restart.sh
#   --fresh-start, which asks the mate to persist its open work, rewrite its
#   where-I-left-off note, and correct its project map, and relaunches it only
#   after the mate's own correlated answer lands. Nothing here goes around that
#   gate.
#   The primary is never restarted: no verified harness mechanism lets a
#   running Claude primary clear its own conversation after persisting it, so
#   at the same triggers the primary is given one short suggestion to relay
#   (say /stow, then /clear), deduplicated by the cooldown.
#
# Triggers, each decided by the parent for its own second mates and by the
# primary for itself:
#
#   context  the agent's current context usage is at or over context_percent of
#            its model's window. Usage is the latest main-thread turn's input
#            tokens (input + cache creation + cache read) from the harness's own
#            session record; the window comes from config context_windows, then
#            the built-in table below. An unknown model, an unreadable record,
#            or a reading larger than the window makes this trigger unavailable
#            for that agent; it is never guessed.
#   idle     the agent has no in-flight work and its last turn ended at least
#            idle_minutes ago.
#   nightly  local time is inside the six hours after nightly_at, the agent has
#            no in-flight work and is between turns, and it has had no fresh
#            start since this night's nightly_at. An agent busy at nightly_at
#            is fresh-started at its next idle moment inside that span.
#
# Every trigger requires the agent to be between turns and to hold no in-flight
# work, and at most one fresh start (or primary suggestion) happens per
# cooldown_hours. The idle and nightly triggers also require at least two
# completed turns in the current session, so a mate that has done nothing since
# its own fresh start is not restarted again for being idle.
#
# In-flight work for a second mate: a live worker record in its home, an open
# decision on its own or its parent's status channel, an unacknowledged
# instruction in its steering inbox, a parent request still awaiting its reply,
# or undrained notifications in its home's wake queue. For the primary: a live
# worker (not a second mate) or an open decision on any of its status channels.
#
# Between turns is read from the harness's own session record, and only Claude
# has a verified reader: the main-thread record is settled when its last
# user/assistant/turn-end record is the turn-end marker (a system record with
# subtype turn_duration or stop_hook_summary). A mate on any other runtime, or a
# remote mate whose record lives on another host, is reported unavailable and
# never fresh-started automatically. The session is found through the home's
# own state/.lock-session sidecar (bin/fm-lock.sh), under CLAUDE_CONFIG_DIR or
# ~/.claude.
#
# check prints one line and only when firstmate should act, so it composes with
# the watcher's ordinary state-check contract: the named mates' run command, a
# suggestion to relay, or an invalid-config report. A mate already offered is
# offered again only after an hour, and only while still due. run is what the
# supervisor executes on that line, in the background because the persist gate
# can wait up to FM_SECONDMATE_PERSIST_WAIT; it re-decides every mate first so a
# mate that picked up work since the offer is left alone, records the attempt
# before restarting so the cooldown holds even if the restart fails, and
# appends one sparse note line per attempt to that mate's status channel in
# this home as the home's own bookkeeping, so it does not wake anyone.
#
# Configuration: config/fresh-start.json (docs/configuration.md owns the
# schema). No file means the feature is off. arm --if-configured, which session
# start runs, arms the check when the file exists and disarms it otherwise.
#
# Records (state/fresh-start/): <id>.attempt holds "<epoch> <trigger> <outcome>"
# for a mate's last automatic fresh start, <id>.offered the epoch of its last
# offer, primary.suggested the epoch of the primary's last suggestion, and
# .config-error the last invalid-config report. All are safe to delete; doing so
# only forgets a cooldown.
#
# Environment knobs (tests and operators):
#   FM_FRESH_START_NOW          epoch seconds to decide at (default: now)
#   FM_FRESH_START_RESTART_BIN  restart command (default: bin/fm-secondmate-restart.sh)
#   CLAUDE_CONFIG_DIR           Claude's config root (default: ~/.claude)
#
# Exit status: 0 success; 1 unusable state, config, or failed run; 2 invalid use.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_EXPLICIT=${FM_HOME:-}
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fresh-start.json"
RECORD_DIR="$STATE/fresh-start"
CHECK_ID='fresh-start'
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
RESTART_BIN="${FM_FRESH_START_RESTART_BIN:-$SCRIPT_DIR/fm-secondmate-restart.sh}"
NIGHT_SPAN=21600
OFFER_RETRY=3600
MIN_TURNS=2

usage() {
  sed -n '2,91{s/^# \{0,1\}//;p;}' "$0"
}

die() { printf 'fm-fresh-start: %s\n' "$1" >&2; exit "${2:-1}"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

NOW=${FM_FRESH_START_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) die "FM_FRESH_START_NOW must be epoch seconds: $NOW" 2 ;; esac

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v perl >/dev/null 2>&1 || die "perl is required"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# --- configuration -----------------------------------------------------------

CFG_ENABLED=
CFG_IDLE_SECS=
CFG_CONTEXT_PCT=
CFG_NIGHTLY=
CFG_COOLDOWN_SECS=
CFG_WINDOWS=
CFG_PROBLEM=

# 0 loaded, 1 absent (feature off), 2 invalid (CFG_PROBLEM says why).
config_load() {
  local out
  [ -e "$CONFIG_FILE" ] || return 1
  if ! out=$(jq -r '
    def int_in($k; $lo; $hi; $def):
      if has($k) | not then $def
      elif .[$k] == null then "off"
      elif (.[$k] | type) == "number" and .[$k] == (.[$k] | floor) and .[$k] >= $lo and .[$k] <= $hi then .[$k] | tostring
      else error("\($k) must be a whole number from \($lo) to \($hi), or null to turn that trigger off")
      end;
    if type != "object" then error("the file must hold one JSON object") else . end
    | (keys - ["enabled","idle_minutes","context_percent","nightly_at","cooldown_hours","context_windows"]) as $extra
    | if ($extra | length) > 0 then error("unknown key \($extra[0])") else . end
    | (if has("enabled") | not then true
       elif (.enabled | type) == "boolean" then .enabled
       else error("enabled must be true or false") end) as $enabled
    | (if has("nightly_at") | not then "03:00"
       elif .nightly_at == null then "off"
       elif (.nightly_at | type) == "string" and (.nightly_at | test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) then .nightly_at
       else error("nightly_at must be local time as HH:MM, or null to turn nightly off") end) as $nightly
    | (if has("cooldown_hours") | not then 6
       elif (.cooldown_hours | type) == "number" and .cooldown_hours == (.cooldown_hours | floor) and .cooldown_hours >= 1 and .cooldown_hours <= 168 then .cooldown_hours
       else error("cooldown_hours must be a whole number from 1 to 168") end) as $cooldown
    | (if has("context_windows") | not then {}
       elif (.context_windows | type) == "object"
         and ([.context_windows[] | (type == "number" and . == floor and . >= 1000)] | all) then .context_windows
       else error("context_windows must map model ids to whole token counts of at least 1000") end) as $windows
    | [ ($enabled | tostring),
        int_in("idle_minutes"; 5; 10080; 120),
        int_in("context_percent"; 10; 99; 70),
        $nightly,
        ($cooldown | tostring),
        ([$windows | to_entries[] | "\(.key)=\(.value)"] | join(" "))
      ] | @tsv' "$CONFIG_FILE" 2>&1); then
    CFG_PROBLEM=$(printf '%s\n' "$out" | sed -n '1{s/^jq: error ([^)]*): //;s/^jq: error: //;p;}')
    [ -n "$CFG_PROBLEM" ] || CFG_PROBLEM="it could not be read"
    return 2
  fi
  IFS=$'\t' read -r CFG_ENABLED CFG_IDLE_SECS CFG_CONTEXT_PCT CFG_NIGHTLY CFG_COOLDOWN_SECS CFG_WINDOWS <<EOF
$out
EOF
  [ "$CFG_IDLE_SECS" = off ] || CFG_IDLE_SECS=$((CFG_IDLE_SECS * 60))
  CFG_COOLDOWN_SECS=$((CFG_COOLDOWN_SECS * 3600))
  return 0
}

# --- records -------------------------------------------------------------------

record_read() {  # <file> -> first line, or nothing
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  head -n 1 "$1" 2>/dev/null || true
}

record_write() {  # <file> <line>
  local tmp
  mkdir -p "$RECORD_DIR" || return 1
  tmp=$(mktemp "$RECORD_DIR/.record.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$1"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

epoch_field() {  # <line> -> leading epoch, or nothing
  local e=${1%% *}
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$e"
}

# --- small formatting helpers -------------------------------------------------

span() {  # <seconds> -> "2h 5m" / "7m"
  local s=$1 h m
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

# The most recent local nightly_at at or before NOW, as epoch seconds.
nightly_open() {  # <HH:MM>
  perl -MPOSIX -e '
    my ($now, $h, $m) = @ARGV;
    my @t = localtime($now);
    my $o = mktime(0, $m, $h, $t[3], $t[4], $t[5], 0, 0, -1);
    $o = mktime(0, $m, $h, $t[3] - 1, $t[4], $t[5], 0, 0, -1) if $o > $now;
    print $o;' "$NOW" "${1%%:*}" "${1##*:}"
}

# --- Claude session record -----------------------------------------------------

# Published by session_read.
S_STATE=
S_TURNS=
S_SETTLED=
S_TOKENS=
S_MODEL=
S_PROBLEM=

# Read the Claude session owning the lock of one home. <cwd> is the path Claude
# was started in, which names its project directory; the session id is looked
# up across every project directory when that guess misses.
session_read() {  # <state-dir> <cwd>
  local sd=$1 cwd=$2 sid slug file out
  S_STATE=; S_TURNS=; S_SETTLED=; S_TOKENS=; S_MODEL=; S_PROBLEM=
  if [ ! -f "$sd/.lock-session" ] || [ -L "$sd/.lock-session" ]; then
    S_PROBLEM="no Claude session is recorded for its home"
    return 1
  fi
  sid=$(head -n 1 "$sd/.lock-session" 2>/dev/null)
  case "$sid" in ''|*[!A-Za-z0-9-]*) S_PROBLEM="its recorded Claude session id is unreadable"; return 1 ;; esac
  slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  file="$CLAUDE_DIR/projects/$slug/$sid.jsonl"
  if [ ! -f "$file" ]; then
    file=
    for f in "$CLAUDE_DIR"/projects/*/"$sid".jsonl; do
      [ -f "$f" ] && { file=$f; break; }
    done
  fi
  if [ -z "$file" ]; then
    S_PROBLEM="its Claude session record was not found"
    return 1
  fi
  if ! out=$(jq -n -r '
      def usage_tokens: (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0);
      reduce (inputs | select(type == "object" and .isSidechain != true)) as $r
        ({state: "none", turns: 0, settled: null, tokens: null, model: null};
         if $r.type == "system" and ($r.subtype == "turn_duration" or $r.subtype == "stop_hook_summary") then
           (if $r.subtype == "turn_duration" then .turns += 1 else . end)
           | .state = "settled"
           | .settled = (try ($r.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null)
         elif $r.type == "user" or $r.type == "assistant" then
           .state = "open"
           | if $r.type == "assistant" and ($r.message.usage | type) == "object" then
               .tokens = ($r.message.usage | usage_tokens) | .model = $r.message.model
             else . end
         else . end)
      | [.state, .turns, (.settled // "-"), (.tokens // "-"), (.model // "-")] | @tsv' "$file" 2>/dev/null); then
    S_PROBLEM="its Claude session record could not be read"
    return 1
  fi
  IFS=$'\t' read -r S_STATE S_TURNS S_SETTLED S_TOKENS S_MODEL <<EOF
$out
EOF
  [ "$S_SETTLED" != - ] || S_SETTLED=
  [ "$S_TOKENS" != - ] || S_TOKENS=
  [ "$S_MODEL" != - ] || S_MODEL=
  return 0
}

# Context window for a model id, or nothing. config context_windows wins; the
# built-in table carries the current published windows. A date suffix and a
# Claude Code "[1m]" selector are ignored for the lookup.
model_window() {  # <model-id>
  local model=$1 entry base
  for entry in $CFG_WINDOWS; do
    [ "${entry%%=*}" = "$model" ] && { printf '%s' "${entry#*=}"; return 0; }
  done
  base=${model%\[1m\]}
  case "$base" in
    *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) base=${base%-*} ;;
  esac
  for entry in $CFG_WINDOWS; do
    [ "${entry%%=*}" = "$base" ] && { printf '%s' "${entry#*=}"; return 0; }
  done
  case "$base" in
    claude-fable-5-1|claude-mythos-5-1|claude-fable-5|claude-mythos-5|claude-opus-5-5|claude-opus-5|\
    claude-opus-4-8|claude-opus-4-7|claude-opus-4-6|claude-sonnet-5|claude-sonnet-4-6)
      printf '1000000' ;;
    claude-haiku-4-5) printf '200000' ;;
  esac
}

# Sets EV_PCT, or leaves it empty with EV_CONTEXT_NOTE saying why.
EV_PCT=
EV_CONTEXT_NOTE=
context_measure() {
  local window
  EV_PCT=; EV_CONTEXT_NOTE=
  if [ -z "$S_TOKENS" ] || [ -z "$S_MODEL" ]; then
    EV_CONTEXT_NOTE="context unmeasured: no turn usage recorded yet"
    return
  fi
  window=$(model_window "$S_MODEL")
  if [ -z "$window" ]; then
    EV_CONTEXT_NOTE="context unmeasured: no known window for $S_MODEL"
    return
  fi
  if [ "$S_TOKENS" -gt "$window" ]; then
    EV_CONTEXT_NOTE="context unmeasured: $S_TOKENS tokens exceeds the $window window on record for $S_MODEL"
    return
  fi
  EV_PCT=$((S_TOKENS * 100 / window))
}

# --- in-flight work --------------------------------------------------------------

open_decision_in() {  # <status-file>...
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -n "$(status_open_decisions "$f")" ] && return 0
  done
  return 1
}

pending_reply_open() {  # <task-id>
  local id=$1 rec task resolved
  for rec in "$STATE"/pending-replies/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    task=$(sed -n 's/^task_id=//p' "$rec" | head -n 1)
    [ "$task" = "$id" ] || continue
    resolved=$(sed -n 's/^resolved_epoch=//p' "$rec" | head -n 1)
    [ -n "$resolved" ] || return 0
  done
  return 1
}

# One reason a mate is holding work, or nothing.
mate_in_flight() {  # <id> <home>
  local id=$1 home=$2 n=0 f
  for f in "$home"/state/*.meta; do [ -f "$f" ] && n=$((n + 1)); done
  [ "$n" -eq 0 ] || { printf '%d live worker(s)' "$n"; return; }
  for f in "$STATE/$id.inbox"/*.msg; do
    [ -f "$f" ] && { printf 'an unacknowledged instruction in its inbox'; return; }
  done
  pending_reply_open "$id" && { printf 'a request still awaiting its reply'; return; }
  open_decision_in "$STATE/$id.status" "$home"/state/*.status && { printf 'an open decision'; return; }
  [ -s "$home/state/.wake-queue" ] && { printf 'undrained notifications'; return; }
  return 0
}

primary_in_flight() {
  local n=0 f kind
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    kind=$(fm_meta_get "$f" kind)
    [ "$kind" = secondmate ] || n=$((n + 1))
  done
  [ "$n" -eq 0 ] || { printf '%d live worker(s)' "$n"; return; }
  open_decision_in "$STATE"/*.status && { printf 'an open decision'; return; }
  return 0
}

# --- the decision ------------------------------------------------------------------

# verdict: due | wait | busy | unavailable
EV_VERDICT=
EV_TRIGGER=
EV_DETAIL=

verdict() { EV_VERDICT=$1; EV_TRIGGER=$2; EV_DETAIL=$3; }

pct_note() {
  if [ -n "$EV_PCT" ]; then printf 'context %d%%' "$EV_PCT"; else printf '%s' "$EV_CONTEXT_NOTE"; fi
}

# Shared trigger arithmetic once an agent is known to be between turns with no
# in-flight work. <last> is the epoch of its last fresh start or suggestion.
decide_triggers() {  # <last>
  local last=$1 open idle_for
  if [ -n "$EV_PCT" ] && [ "$CFG_CONTEXT_PCT" != off ] && [ "$EV_PCT" -ge "$CFG_CONTEXT_PCT" ]; then
    verdict due context "context ${EV_PCT}% is at or over ${CFG_CONTEXT_PCT}%"
    return
  fi
  if [ -n "$S_TURNS" ] && [ "$S_TURNS" -lt "$MIN_TURNS" ]; then
    verdict wait - "no work since its session started; $(pct_note)"
    return
  fi
  if [ "$CFG_NIGHTLY" != off ]; then
    open=$(nightly_open "$CFG_NIGHTLY")
    if [ "$NOW" -lt $((open + NIGHT_SPAN)) ] && { [ -z "$last" ] || [ "$last" -lt "$open" ]; }; then
      verdict due nightly "nightly at $CFG_NIGHTLY; $(pct_note)"
      return
    fi
  fi
  if [ "$CFG_IDLE_SECS" != off ] && [ -n "$S_SETTLED" ]; then
    idle_for=$((NOW - S_SETTLED))
    if [ "$idle_for" -ge "$CFG_IDLE_SECS" ]; then
      verdict due idle "idle $(span "$idle_for"); $(pct_note)"
      return
    fi
    verdict wait - "idle $(span "$idle_for") of $(span "$CFG_IDLE_SECS"); $(pct_note)"
    return
  fi
  verdict wait - "$(pct_note)"
}

cooldown_left() {  # <last> -> seconds left, or nothing
  local last=$1
  [ -n "$last" ] || return 0
  [ $((NOW - last)) -lt "$CFG_COOLDOWN_SECS" ] || return 0
  printf '%s' $((CFG_COOLDOWN_SECS - (NOW - last)))
}

evaluate_mate() {  # <id>
  local id=$1 meta home harness last left why
  meta="$STATE/$id.meta"
  EV_PCT=; EV_CONTEXT_NOTE=
  if [ ! -f "$meta" ] || [ "$(fm_meta_get "$meta" kind)" != secondmate ]; then
    verdict unavailable - "no second mate record for it in this home"; return
  fi
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    verdict unavailable - "remote second mate: its session record is on another host"; return
  fi
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
  if [ -z "$home" ] || [ ! -d "$home/state" ]; then
    verdict unavailable - "its home state is not readable"; return
  fi
  last=$(epoch_field "$(record_read "$RECORD_DIR/$id.attempt")")
  left=$(cooldown_left "$last")
  if [ -n "$left" ]; then
    verdict wait - "cooldown: last fresh start $(span $((NOW - last))) ago, $(span "$left") left"; return
  fi
  why=$(mate_in_flight "$id" "$home")
  if [ -n "$why" ]; then
    verdict busy - "$why"; return
  fi
  harness=$(fm_meta_get "$meta" harness)
  case "$harness" in
    claude|claude-*) ;;
    *) verdict unavailable - "no verified session reader for its runtime (${harness:-none})"; return ;;
  esac
  if ! session_read "$home/state" "$home"; then
    verdict unavailable - "$S_PROBLEM"; return
  fi
  if [ "$S_STATE" != settled ]; then
    verdict busy - "mid-turn"; return
  fi
  context_measure
  decide_triggers "$last"
}

evaluate_primary() {
  local last left why cwd
  EV_PCT=; EV_CONTEXT_NOTE=
  last=$(epoch_field "$(record_read "$RECORD_DIR/primary.suggested")")
  left=$(cooldown_left "$last")
  if [ -n "$left" ]; then
    verdict wait - "cooldown: last suggestion $(span $((NOW - last))) ago, $(span "$left") left"; return
  fi
  why=$(primary_in_flight)
  if [ -n "$why" ]; then
    verdict busy - "$why"; return
  fi
  cwd=$(cd "$FM_HOME" 2>/dev/null && pwd) || cwd=$FM_HOME
  if session_read "$STATE" "$cwd"; then
    if [ "$S_STATE" != settled ]; then
      # The primary running this check is itself mid-turn whenever it reads
      # its own status by hand; the watcher polls between its turns.
      verdict busy - "mid-turn"; return
    fi
    context_measure
  else
    # No verified session reader: only the nightly trigger can be decided.
    S_TURNS=; S_SETTLED=
    EV_CONTEXT_NOTE="context unmeasured: $S_PROBLEM"
  fi
  decide_triggers "$last"
}

# --- commands --------------------------------------------------------------------

mate_ids() {
  local f
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    [ "$(fm_meta_get "$f" kind)" = secondmate ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.meta}"
  done
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac
}

require_config() {
  local rc=0
  config_load || rc=$?
  case "$rc" in
    1) printf 'fresh-start: off (no %s)\n' "$CONFIG_FILE"; exit 0 ;;
    2) die "config $CONFIG_FILE is invalid: $CFG_PROBLEM" ;;
  esac
  if [ "$CFG_ENABLED" != true ]; then
    printf 'fresh-start: off (enabled is false)\n'
    exit 0
  fi
}

cmd_status() {
  local id ids=()
  require_config
  if [ "$#" -gt 0 ]; then
    for id in "$@"; do valid_id "$id" || die "invalid second mate id: $id" 2; ids+=("$id"); done
  else
    evaluate_primary
    printf 'primary: %s %s: %s\n' "$EV_VERDICT" "$EV_TRIGGER" "$EV_DETAIL"
    while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done <<EOF
$(mate_ids)
EOF
  fi
  for id in ${ids[@]+"${ids[@]}"}; do
    evaluate_mate "$id"
    printf '%s: %s %s: %s\n' "$id" "$EV_VERDICT" "$EV_TRIGGER" "$EV_DETAIL"
  done
}

cmd_check() {
  local rc=0 id offered due_ids='' due_text='' line='' home prior
  config_load || rc=$?
  case "$rc" in
    1) return 0 ;;
    2)
      line="fresh-start: config/fresh-start.json is invalid ($CFG_PROBLEM); automatic fresh starts are off until it is fixed"
      prior=$(record_read "$RECORD_DIR/.config-error")
      [ "$prior" = "$line" ] && return 0
      record_write "$RECORD_DIR/.config-error" "$line" || true
      printf '%s\n' "$line"
      return 0
      ;;
  esac
  rm -f -- "$RECORD_DIR/.config-error"
  [ "$CFG_ENABLED" = true ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    evaluate_mate "$id"
    [ "$EV_VERDICT" = due ] || continue
    offered=$(epoch_field "$(record_read "$RECORD_DIR/$id.offered")")
    if [ -n "$offered" ] && [ $((NOW - offered)) -lt "$OFFER_RETRY" ]; then
      continue
    fi
    record_write "$RECORD_DIR/$id.offered" "$NOW" || return 1
    due_ids="$due_ids $id"
    due_text="${due_text:+$due_text, }$id ($EV_DETAIL)"
  done <<EOF
$(mate_ids)
EOF
  if [ -n "$due_ids" ]; then
    home=$(cd "$FM_HOME" 2>/dev/null && pwd) || home=$FM_HOME
    line="fresh start due for second mate $due_text: run FM_HOME=$(printf '%q' "$home") $(printf '%q' "$SCRIPT_DIR/fm-fresh-start.sh") run$due_ids in the background; it reports each outcome on that mate's status channel"
  fi
  evaluate_primary
  if [ "$EV_VERDICT" = due ]; then
    record_write "$RECORD_DIR/primary.suggested" "$NOW $EV_TRIGGER" || return 1
    if [ -n "$EV_PCT" ]; then
      prior="my context is at ${EV_PCT}%"
    else
      prior="my context usage cannot be measured"
    fi
    line="${line:+$line; }fresh-start suggestion ($EV_TRIGGER): $prior; say /stow then /clear when convenient"
  fi
  [ -z "$line" ] || printf '%s\n' "$line"
}

cmd_run() {
  local id due=() trig=() detail=() out rc i outcome note append_rc failed=0
  [ -n "$FM_HOME_EXPLICIT" ] || die "FM_HOME is not set; run refuses to act on an implied home"
  [ "$#" -gt 0 ] || die "run needs at least one second mate id" 2
  for id in "$@"; do valid_id "$id" || die "invalid second mate id: $id" 2; done
  require_config
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$RECORD_DIR" || die "cannot create $RECORD_DIR"
  if ! fm_lock_try_acquire "$RECORD_DIR/.run.lock"; then
    printf 'fresh-start: another fresh start is already running (pid %s)\n' "${FM_LOCK_HELD_PID:-unknown}"
    exit 0
  fi
  trap 'fm_lock_release "$RECORD_DIR/.run.lock"' EXIT
  for id in "$@"; do
    evaluate_mate "$id"
    if [ "$EV_VERDICT" != due ]; then
      printf 'not started: %s: %s %s\n' "$id" "$EV_VERDICT" "$EV_DETAIL"
      continue
    fi
    record_write "$RECORD_DIR/$id.attempt" "$NOW $EV_TRIGGER started" || die "cannot record the attempt for $id"
    due+=("$id"); trig+=("$EV_TRIGGER"); detail+=("$EV_DETAIL")
  done
  [ "${#due[@]}" -gt 0 ] || return 0
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$RESTART_BIN" --fresh-start "${due[@]}" 2>&1) || rc=$?
  printf '%s\n' "$out"
  i=0
  while [ "$i" -lt "${#due[@]}" ]; do
    id=${due[$i]}
    outcome=$(printf '%s\n' "$out" | grep -E "^(restarted|skipped|unreached|nudged): $id([: ]|\$)" | head -n 1)
    case "$outcome" in
      restarted:*) note="restarted" ;;
      '') note="not done: the restart reported nothing for it (exit $rc)"; outcome="unknown" ;;
      *) note="not done: ${outcome#*: "$id": }" ;;
    esac
    record_write "$RECORD_DIR/$id.attempt" "$NOW ${trig[$i]} ${outcome%%:*}" || failed=1
    append_rc=0
    fm_wake_status_append_self_announced "$STATE" "$STATE/$id.status" \
      "note: automatic fresh start (${detail[$i]}): $note" || append_rc=$?
    [ "$append_rc" -ne 2 ] || { printf 'fresh-start: could not append the outcome to %s\n' "$STATE/$id.status" >&2; failed=1; }
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] || return 1
  return 0
}

shim_content() {
  local home
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fresh-start.sh - automatic fresh-start poll shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fresh-start.sh") check"
}

cmd_disarm() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || die "could not remove state/$CHECK_ID.check.sh"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_arm() {
  local want staged rc=0
  if [ "${1:-}" = --if-configured ]; then
    if [ ! -e "$CONFIG_FILE" ]; then
      [ -e "$STATE/$CHECK_ID.check.sh" ] || [ -e "$STATE/$CHECK_ID.check-trust" ] || return 0
      cmd_disarm >/dev/null
      return 0
    fi
  elif [ -n "${1:-}" ]; then
    die "unknown arm option: $1" 2
  fi
  config_load || rc=$?
  [ "$rc" -ne 1 ] || die "no config at $CONFIG_FILE; automatic fresh starts are off"
  # An invalid file is still armed: the check itself reports the problem once.
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  want=$(shim_content) || die "cannot resolve FM_HOME $FM_HOME"
  if [ -f "$STATE/$CHECK_ID.check.sh" ] && [ "$(cat "$STATE/$CHECK_ID.check.sh")" = "$want" ] \
    && FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null 2>&1; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  staged=$(umask 077; mktemp "$STATE/.fresh-start-check.XXXXXX") || die "cannot stage the check shim"
  if ! { printf '%s\n' "$want" > "$staged" && chmod 700 "$staged" \
    && mv -f -- "$staged" "$STATE/$CHECK_ID.check.sh"; }; then
    rm -f -- "$staged"
    die "cannot write state/$CHECK_ID.check.sh"
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    cmd_disarm >/dev/null 2>&1 || true
    die "could not register state/$CHECK_ID.check.sh"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action=$1
shift
case "$action" in
  check) [ "$#" -eq 0 ] || die "check takes no arguments" 2; cmd_check ;;
  status) cmd_status "$@" ;;
  run) cmd_run "$@" ;;
  arm) [ "$#" -le 1 ] || die "arm takes at most one option" 2; cmd_arm "$@" ;;
  disarm) [ "$#" -eq 0 ] || die "disarm takes no arguments" 2; cmd_disarm ;;
  *) usage >&2; exit 2 ;;
esac
