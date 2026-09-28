#!/usr/bin/env bash
# Select a token strategy (full, balanced, or lean) for this firstmate home.
# Usage: fm-strategy.sh list
#        fm-strategy.sh show [<mode>] [--providers <set>]
#        fm-strategy.sh set <mode> [--providers <set>] [--dry-run] [--yes]
#        fm-strategy.sh status
#
# A strategy is a named bundle of settings Firstmate already has. Each mode is a
# tracked template in bin/strategies/<mode>.json; set renders it into this home's
# own gitignored config and records the selection in config/strategy. The
# operator contract (what each mode contains, the safety floor, and what stays
# manual) is owned by docs/configuration.md "Token strategies"; this header owns
# the mechanics.
#
# Provider set: <set> is claude, codex, or claude,codex - the subscriptions this
# home can actually use. Without --providers, set and show reuse the provider set
# recorded in config/strategy, else detect it from the claude and codex
# executables on PATH. Every rendered route names an explicit harness, model,
# and effort from that set only; a profile for a provider outside it is dropped,
# and a rule left with no profile (the other provider's requested-worker or
# requested-model rule) is dropped with it.
#
# Files set writes, each atomically (temp file in config/ then rename, with the
# earlier renames restored if a later one fails):
#   config/crew-dispatch.json  worker routing. Rules the strategy manages carry a
#                              "strategy" key naming their slot; an existing rule
#                              with that key or with a template rule's exact
#                              "when" text is replaced by the template rule while
#                              its other keys (approval, floor, notes) are kept.
#                              Every other existing rule is kept after the managed
#                              ones, and unknown top-level keys are kept. The
#                              top-level default is replaced.
#   config/secondmate-harness  "<harness> <model> <effort>" for new second mates:
#                              the Claude pin when claude is in the provider set,
#                              else the Codex pin; comment lines are kept.
#   config/strategy            mode= and providers= lines (not inherited).
# set prints a unified diff of every file first. It writes only with --yes, or
# after a y answer when stdin is a terminal; --dry-run prints the diff and stops.
# After a write that changed config/crew-dispatch.json it runs
# bin/fm-config-push.sh so live second mates inherit the new routing; a failed
# push exits 1 and names bin/fm-config-push.sh to rerun. set refuses in a
# second mate home, whose routing is inherited from its primary.
#
# Settings that live outside this home - the primary coordinator's launch flags
# and the no-mistakes pipeline's agent_config - are printed as the exact value
# to apply by hand; this script never edits the user's global Claude, Codex, or
# no-mistakes settings, any launcher, hook trust, or permissions.
#
# status prints the selected mode and provider set, drift of each managed file
# from what that mode renders today, custom rules whose routes do not name an
# explicit model and effort, recorded second mates a mode without second mates
# leaves running, and the manual settings above.
#
# FM_STRATEGY_PUSH_BIN replaces bin/fm-config-push.sh; tests use it to observe
# and fail the push without live second mates.
#
# Exit: 0 success, 1 refused or failed, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TEMPLATES="$SCRIPT_DIR/strategies"
MODES="full balanced lean"

# shellcheck source=bin/fm-codex-launch-lib.sh
. "$SCRIPT_DIR/fm-codex-launch-lib.sh"

DISPATCH="$CONFIG/crew-dispatch.json"
SM_HARNESS="$CONFIG/secondmate-harness"
SELECTION="$CONFIG/strategy"

usage() {
  cat <<'EOF'
Usage: fm-strategy.sh list
       fm-strategy.sh show [<mode>] [--providers claude|codex|claude,codex]
       fm-strategy.sh set <mode> [--providers claude|codex|claude,codex] [--dry-run] [--yes]
       fm-strategy.sh status

Modes: full, balanced, lean. See docs/configuration.md "Token strategies".
EOF
}

die() { echo "fm-strategy: $*" >&2; exit 1; }
usage_die() { echo "fm-strategy: $*" >&2; usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

valid_mode() {
  case " $MODES " in *" $1 "*) return 0 ;; esac
  return 1
}

template() { printf '%s/%s.json' "$TEMPLATES" "$1"; }

# Read one key=value line from config/strategy.
selection_get() {
  [ -f "$SELECTION" ] || return 0
  sed -n "s/^$1=//p" "$SELECTION" | head -n 1
}

# Normalize a provider list to the canonical "claude", "codex", or
# "claude,codex"; fail on anything else.
normalize_providers() {
  local raw=$1 item has_claude=0 has_codex=0 out=
  local -a items=()
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    item=${item//[[:space:]]/}
    case "$item" in
      claude) has_claude=1 ;;
      codex) has_codex=1 ;;
      '') ;;
      *) return 1 ;;
    esac
  done
  [ "$has_claude" -eq 1 ] && out=claude
  if [ "$has_codex" -eq 1 ]; then
    out=${out:+$out,}codex
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

detect_providers() {
  local out=
  command -v claude >/dev/null 2>&1 && out=claude
  if command -v codex >/dev/null 2>&1; then
    out=${out:+$out,}codex
  fi
  printf '%s\n' "$out"
}

# resolve_providers <explicit-or-empty>: sets PROVIDERS and PROVIDERS_SOURCE.
resolve_providers() {
  local explicit=$1 recorded
  if [ -n "$explicit" ]; then
    PROVIDERS=$(normalize_providers "$explicit") \
      || usage_die "--providers must be claude, codex, or claude,codex (got '$explicit')"
    PROVIDERS_SOURCE=declared
    return 0
  fi
  recorded=$(selection_get providers)
  if [ -n "$recorded" ] && PROVIDERS=$(normalize_providers "$recorded"); then
    PROVIDERS_SOURCE="recorded in config/strategy"
    return 0
  fi
  PROVIDERS=$(detect_providers)
  [ -n "$PROVIDERS" ] \
    || die "no claude or codex executable found on PATH; pass --providers claude, codex, or claude,codex"
  PROVIDERS_SOURCE="detected on PATH"
}

providers_json() {
  jq -cn --arg p "$1" '$p | split(",")'
}

# Every "when" text any template manages, mapped to its slot, so a rule written
# before the strategy markers existed is still recognized.
known_whens_json() {
  local m
  for m in $MODES; do jq -c '[.dispatch.rules[] | {key: .when, value: .strategy}]' "$(template "$m")"; done \
    | jq -cs 'add | from_entries'
}

# render_dispatch <mode> <providers> <current-file-or-empty>: print the new
# config/crew-dispatch.json.
render_dispatch() {
  local mode=$1 providers=$2 current=$3 cur_json
  if [ -n "$current" ] && [ -f "$current" ]; then
    cur_json=$(jq -c . "$current" 2>/dev/null) || die "config/crew-dispatch.json is not valid JSON; fix or remove it before selecting a strategy"
    [ "$(jq -r 'type' <<<"$cur_json")" = object ] || die "config/crew-dispatch.json is not a JSON object; fix or remove it before selecting a strategy"
  else
    cur_json=null
  fi
  jq --argjson cur "$cur_json" \
    --argjson providers "$(providers_json "$providers")" \
    --argjson whens "$(known_whens_json)" '
    def keep($list): [$list[] | select(.harness as $h | $providers | index($h))];
    def filter_use($u):
      if ($u | type) == "array" then keep($u)
      else (keep([$u]) | if length == 1 then .[0] else [] end)
      end;
    def slot($r): ($r.strategy // $whens[$r.when // ""] // null);
    ($cur // {}) as $c
    | ($c.rules // []) as $old
    | [.dispatch.rules[]
        | .use = filter_use(.use)
        | select(.use != [])] as $tpl
    | [$tpl[] | . as $t
        | ([$old[] | select(slot(.) == $t.strategy)] | first // {}) as $prior
        | ($prior + $t)] as $managed
    | [$old[] | select(slot(.) == null)] as $custom
    | $c + {rules: ($managed + $custom), default: filter_use(.dispatch.default)}
  ' "$(template "$mode")"
}

# The harness a new second mate launches on: Claude when available.
mate_harness() {
  case ",$1," in *,claude,*) echo claude ;; *) echo codex ;; esac
}

render_secondmate_harness() {
  local mode=$1 providers=$2 h
  h=$(mate_harness "$providers")
  if [ -f "$SM_HARNESS" ]; then
    grep -E '^[[:space:]]*(#|$)' "$SM_HARNESS" || true
  fi
  jq -r --arg h "$h" '"\($h) \(.secondmates[$h].model) \(.secondmates[$h].effort)"' "$(template "$mode")"
}

render_selection() {
  printf '# Token strategy for this home, written by bin/fm-strategy.sh; see docs/configuration.md "Token strategies".\n'
  printf 'mode=%s\nproviders=%s\n' "$1" "$2"
}

# print_resolved <mode> <providers>: the per-role result.
print_resolved() {
  local mode=$1 providers=$2 tpl dispatch p mate_h
  tpl=$(template "$mode")
  dispatch=$(render_dispatch "$mode" "$providers" "$DISPATCH")
  printf 'strategy: %s (providers: %s, %s)\n' "$mode" "$providers" "$PROVIDERS_SOURCE"
  printf '  %s\n' "$(jq -r .summary "$tpl")"
  echo "primary coordinator (set where you start the primary; this tool never edits launchers or global settings):"
  for p in ${providers//,/ }; do
    case "$p" in
      claude)
        jq -r '.coordinator.claude | "  claude: \(.model) effort \(.effort)\n    start with: claude --model \(.model) --effort \(.effort)"' "$tpl"
        ;;
      codex)
        jq -r --arg doc "$FM_CODEX_PROJECT_DOC_MAX_BYTES" '.coordinator.codex | "  codex: \(.model) effort \(.effort)\n    start with: codex -m \(.model) -c model_reasoning_effort=\"\(.effort)\" -c project_doc_max_bytes=\($doc)"' "$tpl"
        ;;
    esac
  done
  mate_h=$(mate_harness "$providers")
  if [ "$(jq -r .secondmates.allowed "$tpl")" = true ]; then
    printf 'second mates: allowed; new ones launch as %s (config/secondmate-harness)\n' \
      "$(jq -r --arg h "$mate_h" '.secondmates[$h] | "\($h) \(.model) \(.effort)"' "$tpl")"
  else
    printf 'second mates: off by default; create one only when the captain asks, and running ones are not retired; one that is created launches as %s (config/secondmate-harness)\n' \
      "$(jq -r --arg h "$mate_h" '.secondmates[$h] | "\($h) \(.model) \(.effort)"' "$tpl")"
  fi
  echo "worker tiers (config/crew-dispatch.json, one line per candidate):"
  jq -r '
    def profiles($u): if ($u | type) == "array" then $u else [$u] end;
    def slotname($r): ($r.strategy // "custom");
    def txt($p): "\($p.harness) \($p.model // "(harness default model)") \($p.effort // "(harness default effort)")";
    (.rules // [])[] as $r | profiles($r.use)[] | "  \(slotname($r)): \(txt(.))",
    (profiles(.default // [])[] | "  default: \(txt(.))")
  ' <<<"$dispatch"
  echo "validation (no-mistakes agent_config in ~/.no-mistakes/config.yaml; apply by hand):"
  echo "  agent_config:"
  for p in ${providers//,/ }; do
    jq -r --arg p "$p" '.validation[$p] | "    \($p):\n      model: \(.model)\n      effort: \(.effort)"' "$tpl"
  done
  case "$(jq -r .present_mode "$tpl")" in
    quiet) echo "while the captain is present: /quiet recommended (routine notifications are handled without a coordinator turn; captain-relevant events still arrive)" ;;
    *) echo "while the captain is present: normal supervision" ;;
  esac
  echo "unchanged by every mode: delivery mode, yolo and merge authority, ask-user authority, escalation, which events wake the coordinator, permissions, hook trust, AGENTS.md boundaries, native context compaction, and claude-mem"
}

cmd_list() {
  local selected m marker
  selected=$(selection_get mode)
  for m in $MODES; do
    marker=
    [ "$m" = "$selected" ] && marker=' (selected)'
    printf '%-9s %s%s\n' "$m" "$(jq -r .summary "$(template "$m")")" "$marker"
  done
}

parse_mode_flags() {
  # Sets MODE_ARG, PROVIDERS_ARG, DRY_RUN, ASSUME_YES from "$@".
  MODE_ARG=
  PROVIDERS_ARG=
  DRY_RUN=0
  ASSUME_YES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --providers) [ "$#" -ge 2 ] || usage_die "--providers needs a value"; PROVIDERS_ARG=$2; shift ;;
      --providers=*) PROVIDERS_ARG=${1#--providers=} ;;
      --dry-run) DRY_RUN=1 ;;
      --yes | -y) ASSUME_YES=1 ;;
      -*) usage_die "unknown flag $1" ;;
      *)
        [ -z "$MODE_ARG" ] || usage_die "only one mode may be named"
        MODE_ARG=$1
        ;;
    esac
    shift
  done
  [ -z "$MODE_ARG" ] || valid_mode "$MODE_ARG" || usage_die "unknown mode '$MODE_ARG' (choose full, balanced, or lean)"
}

cmd_show() {
  parse_mode_flags "$@"
  [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] || usage_die "show takes only a mode and --providers"
  [ -n "$MODE_ARG" ] || MODE_ARG=$(selection_get mode)
  [ -n "$MODE_ARG" ] || usage_die "no strategy selected yet; name a mode (full, balanced, or lean)"
  valid_mode "$MODE_ARG" || die "config/strategy names unknown mode '$MODE_ARG'"
  resolve_providers "$PROVIDERS_ARG"
  print_resolved "$MODE_ARG" "$PROVIDERS"
}

# Refuse to replace anything but an absent file or a regular, single-linked one.
check_target() {
  local f=$1
  [ ! -e "$f" ] && [ ! -L "$f" ] && return 0
  [ -f "$f" ] && [ ! -L "$f" ] || die "${f#"$FM_HOME"/} is not a regular file; refusing to replace it"
}

# Permission bits of a file, GNU stat first because BSD's -f means something else there.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

show_diff() {  # <label> <current-file> <new-file>
  local label=$1 cur=$2 new=$3 from=$2
  [ -f "$cur" ] || from=/dev/null
  diff -u -L "a/$label" -L "b/$label" "$from" "$new"
}

cmd_set() {
  local mode tmpdir changed=() f base new answer dispatch_changed=0 i push_out
  parse_mode_flags "$@"
  mode=$MODE_ARG
  [ -n "$mode" ] || usage_die "set needs a mode (full, balanced, or lean)"
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    die "this is a second mate home, which inherits its routing from the primary; select a strategy in the primary home"
  fi
  resolve_providers "$PROVIDERS_ARG"
  mkdir -p "$CONFIG" || die "cannot create $CONFIG"
  for f in "$DISPATCH" "$SM_HARNESS" "$SELECTION"; do check_target "$f"; done

  tmpdir=$(mktemp -d "$CONFIG/.fm-strategy.XXXXXX") || die "cannot create a temporary directory in $CONFIG"
  # shellcheck disable=SC2064 # Expand now: the path is fixed for this run.
  trap "rm -rf '$tmpdir'" EXIT
  render_dispatch "$mode" "$PROVIDERS" "$DISPATCH" > "$tmpdir/crew-dispatch.json" || exit 1
  render_secondmate_harness "$mode" "$PROVIDERS" > "$tmpdir/secondmate-harness" || exit 1
  render_selection "$mode" "$PROVIDERS" > "$tmpdir/strategy" || exit 1

  print_resolved "$mode" "$PROVIDERS"
  echo
  for base in crew-dispatch.json secondmate-harness strategy; do
    if ! cmp -s "$CONFIG/$base" "$tmpdir/$base"; then
      changed+=("$base")
      show_diff "config/$base" "$CONFIG/$base" "$tmpdir/$base"
    fi
  done
  if [ "${#changed[@]}" -eq 0 ]; then
    echo "no change: this home already matches $mode"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry run: nothing written"
    return 0
  fi
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf 'Apply these changes? [y/N] '
      read -r answer || answer=
      case "$answer" in y | Y | yes | YES) ;; *) echo "not applied"; return 1 ;; esac
    else
      echo "not applied: rerun with --yes to write these changes" >&2
      return 1
    fi
  fi

  # Move each new file into place; on a failure restore the earlier ones.
  for base in "${changed[@]}"; do
    if [ -f "$CONFIG/$base" ]; then
      cp -p "$CONFIG/$base" "$tmpdir/$base.orig" || die "cannot back up config/$base; nothing written"
    fi
  done
  i=0
  for base in "${changed[@]}"; do
    new="$tmpdir/$base"
    [ ! -f "$CONFIG/$base" ] || chmod "$(file_mode "$CONFIG/$base")" "$new" 2>/dev/null || true
    if ! mv -f "$new" "$CONFIG/$base"; then
      while [ "$i" -gt 0 ]; do
        i=$((i - 1))
        f=${changed[$i]}
        if [ -f "$tmpdir/$f.orig" ]; then mv -f "$tmpdir/$f.orig" "$CONFIG/$f"; else rm -f "$CONFIG/$f"; fi
      done
      die "could not write config/$base; earlier changes were restored"
    fi
    i=$((i + 1))
    [ "$base" = crew-dispatch.json ] && dispatch_changed=1
  done
  echo "written: ${changed[*]}"

  if [ "$dispatch_changed" -eq 1 ]; then
    if push_out=$(FM_HOME="$FM_HOME" "${FM_STRATEGY_PUSH_BIN:-$SCRIPT_DIR/fm-config-push.sh}" 2>&1); then
      printf '%s\n' "$push_out" | sed 's/^/  /'
    else
      printf '%s\n' "$push_out" | sed 's/^/  /'
      echo "second mates were not all updated; run bin/fm-config-push.sh again" >&2
      return 1
    fi
  fi
}

cmd_status() {
  local mode dispatch_now h recorded_mates drift=0
  [ "$#" -eq 0 ] || usage_die "status takes no arguments"
  mode=$(selection_get mode)
  if [ -z "$mode" ]; then
    echo "strategy: none selected (settings are unmanaged); run bin/fm-strategy.sh list"
    return 0
  fi
  valid_mode "$mode" || die "config/strategy names unknown mode '$mode'"
  resolve_providers ""
  printf 'strategy: %s (providers: %s)\n' "$mode" "$PROVIDERS"
  printf '  %s\n' "$(jq -r .summary "$(template "$mode")")"

  echo "drift:"
  if [ ! -f "$DISPATCH" ]; then
    echo "  config/crew-dispatch.json is missing"; drift=1
  elif ! jq -e . "$DISPATCH" >/dev/null 2>&1; then
    echo "  config/crew-dispatch.json is not valid JSON"; drift=1
  else
    dispatch_now=$(render_dispatch "$mode" "$PROVIDERS" "$DISPATCH" | jq -S .)
    if [ "$dispatch_now" != "$(jq -S . "$DISPATCH")" ]; then
      echo "  config/crew-dispatch.json differs from $mode"; drift=1
    fi
  fi
  if ! cmp -s "$SM_HARNESS" <(render_secondmate_harness "$mode" "$PROVIDERS"); then
    echo "  config/secondmate-harness differs from $mode"; drift=1
  fi
  if [ "$drift" -eq 1 ]; then
    echo "  run bin/fm-strategy.sh set $mode to see and apply the difference"
  else
    echo "  none"
  fi

  echo "not applied by this tool:"
  if [ -f "$DISPATCH" ] && jq -e . "$DISPATCH" >/dev/null 2>&1; then
    jq -r '
      def profiles($u): if ($u | type) == "array" then $u else [$u] end;
      (.rules // [])[] | select(.strategy == null) | . as $r
      | profiles($r.use)[] | select(.model == null or .effort == null)
      | "  custom rule leaves \(.harness) without an explicit model or effort: \($r.when)"
    ' "$DISPATCH"
  fi
  for h in ${PROVIDERS//,/ }; do
    command -v "$h" >/dev/null 2>&1 || echo "  $h is in the provider set but not on PATH"
  done
  if [ "$(jq -r .secondmates.allowed "$(template "$mode")")" != true ]; then
    recorded_mates=$(grep -l '^kind=secondmate$' "$STATE"/*.meta 2>/dev/null | wc -l | tr -d ' ')
    [ "$recorded_mates" = 0 ] \
      || echo "  $mode turns second mates off by default, but $recorded_mates recorded second mate(s) keep running until the captain retires them"
  fi
  echo "  primary coordinator launch flags and no-mistakes agent_config: set by hand, see bin/fm-strategy.sh show $mode"
  if [ "$(jq -r .present_mode "$(template "$mode")")" = quiet ]; then
    echo "  /quiet is recommended while the captain is present; it is a session choice, not a file"
  fi
}

case "${1:-}" in
  list) shift; [ "$#" -eq 0 ] || usage_die "list takes no arguments"; cmd_list ;;
  show) shift; cmd_show "$@" ;;
  set) shift; cmd_set "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h | --help | help) usage ;;
  '') usage >&2; exit 2 ;;
  *) usage_die "unknown command '$1'" ;;
esac
