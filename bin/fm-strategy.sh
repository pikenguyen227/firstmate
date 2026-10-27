#!/usr/bin/env bash
# Select a token and autonomy strategy (full, balanced, or lean) for this firstmate home.
# Usage: fm-strategy.sh list [--plans <plans>]
#        fm-strategy.sh show [<mode>] [--providers <set>] [--plans <plans>]
#        fm-strategy.sh set <mode> [--providers <set>] [--plans <plans>] [--dry-run] [--yes]
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
# Plans: <plans> is claude=<plan>, codex=<plan>, or both comma-separated, naming
# the subscription plan behind each provider, or none to clear a recorded set.
# Plan names and profiles are data in bin/strategies/plans.json. A named plan
# lays its profile for the mode over the template for that provider only: the
# coordinator, second-mate pin, validation, the light, standard, hard, and
# requested-worker routes, the default, the light and standard floors (the
# plan's own, or none when it has none), and the Claude requested-model why
# text. A plan that turns second mates off does so when its provider is the one
# new second mates launch on. Without --plans, show, set, and status reuse the
# plans recorded in config/strategy for providers still in the set; with no
# plan every file renders exactly as the template does. A plan for a provider
# outside the set is a usage error. show and set warn, never refuse, when full
# is chosen on a plan marked full_warning, and list marks full for it.
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
#   config/strategy            mode=, providers=, autonomy= lines, and plans=
#                              when a plan is named (not inherited).
#   config/fresh-start.json    enabled from the mode; all trigger tuning is kept.
# The coordinator applies the session policy through the strategy-autonomy skill;
# this command never launches or stops quiet supervision or second mates.
# After confirmed writes (also an unchanged --yes retry), reconcile the fresh-
# start check through fm-fresh-start.sh arm/disarm. A failure leaves the selected
# config in place, exits 1, and names the retry; no agent is restarted here.
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
# status prints the selected mode, provider set, and plans, drift of each managed file
# from what that mode renders today, custom rules whose routes do not name an
# explicit model and effort, recorded second mates a mode without second mates
# leaves running, and the manual settings above.
#
# FM_STRATEGY_FRESH_START_BIN replaces the fresh-start arm/disarm command in tests.
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
PLANS_FILE="$TEMPLATES/plans.json"
MODES="full balanced lean"

# shellcheck source=bin/fm-codex-launch-lib.sh
. "$SCRIPT_DIR/fm-codex-launch-lib.sh"

DISPATCH="$CONFIG/crew-dispatch.json"
SM_HARNESS="$CONFIG/secondmate-harness"
SELECTION="$CONFIG/strategy"
FRESH_START="$CONFIG/fresh-start.json"

usage() {
  cat <<'EOF'
Usage: fm-strategy.sh list [--plans <plans>]
       fm-strategy.sh show [<mode>] [--providers claude|codex|claude,codex] [--plans <plans>]
       fm-strategy.sh set <mode> [--providers claude|codex|claude,codex] [--plans <plans>] [--dry-run] [--yes]
       fm-strategy.sh status

Modes: full, balanced, lean.
Plans: none, or claude=<plan>,codex=<plan> (either or both), where <plan> is
EOF
  printf '  claude: %s\n  codex: %s\n' "$(plan_names claude)" "$(plan_names codex)"
  echo 'See docs/configuration.md "Token strategies".'
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

plan_names() {  # <harness>
  jq -r --arg h "$1" '.[$h] | keys_unsorted | join(", ")' "$PLANS_FILE"
}

# plan_field <harness> <plan> <field>: label and full_warning belong to the
# named plan itself; every other field follows same_as to the shared profile.
plan_field() {
  jq -r --arg h "$1" --arg p "$2" --arg f "$3" '
    .[$h] as $v | $v[$p] as $e
    | if $f == "label" or $f == "full_warning" then ($e[$f] // false)
      else ($v[$e.same_as // $p][$f] // "") end
  ' "$PLANS_FILE"
}

# Normalize a plan list to "claude=<plan>", "codex=<plan>", or both in that
# order; "none" normalizes to the empty set. Fail on anything else.
normalize_plans() {
  local raw=${1//[[:space:]]/} item h p claude='' codex='' out=''
  local -a items=()
  if [ "$raw" = none ]; then
    printf '\n'
    return 0
  fi
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    case "$item" in *=*) ;; *) return 1 ;; esac
    h=${item%%=*}
    p=${item#*=}
    case "$h" in claude | codex) ;; *) return 1 ;; esac
    jq -e --arg h "$h" --arg p "$p" '.[$h] | has($p)' "$PLANS_FILE" >/dev/null 2>&1 || return 1
    case "$h" in
      claude) [ -z "$claude" ] || return 1; claude=$p ;;
      codex) [ -z "$codex" ] || return 1; codex=$p ;;
    esac
  done
  [ -z "$claude" ] || out=claude=$claude
  if [ -n "$codex" ]; then
    out=${out:+$out,}codex=$codex
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

plans_usage() {
  printf -- '--plans must be none or claude=<plan>,codex=<plan> (claude: %s; codex: %s); got '"'"'%s'"'" \
    "$(plan_names claude)" "$(plan_names codex)" "$1"
}

# resolve_plans <explicit-or-empty> [<providers>]: sets PLANS. An explicit set
# must name only providers in <providers>; a recorded set keeps only those.
# Without <providers> (list), every named plan is kept.
resolve_plans() {
  local explicit=$1 providers=${2:-claude,codex} recorded normalized item kept=
  PLANS=
  if [ -n "$explicit" ]; then
    PLANS=$(normalize_plans "$explicit") || usage_die "$(plans_usage "$explicit")"
    for item in ${PLANS//,/ }; do
      case ",$providers," in
        *",${item%%=*},"*) ;;
        *) usage_die "--plans names a ${item%%=*} plan, but ${item%%=*} is not in the provider set ($providers)" ;;
      esac
    done
    return 0
  fi
  recorded=$(selection_get plans)
  [ -n "$recorded" ] || return 0
  normalized=$(normalize_plans "$recorded") || die "config/strategy names unknown plans '$recorded'; rerun set with --plans"
  for item in ${normalized//,/ }; do
    case ",$providers," in *",${item%%=*},"*) kept=${kept:+$kept,}$item ;; esac
  done
  PLANS=$kept
}

plan_of() {  # <harness> <plans>: that harness's plan name, or nothing
  local item
  for item in ${2//,/ }; do
    [ "${item%%=*}" != "$1" ] || printf '%s\n' "${item#*=}"
  done
}

plans_json() {
  jq -cn --arg p "$1" '$p | split(",") | map(split("=") | {key: .[0], value: .[1]}) | from_entries'
}

# effective_template <mode> <providers> <plans>: print the mode template with
# each named plan's profile laid over its provider; with no plan, the template.
effective_template() {
  local mode=$1 providers=$2 plans=$3
  if [ -z "$plans" ]; then
    cat "$(template "$mode")"
    return
  fi
  jq --arg mode "$mode" --arg mate "$(mate_harness "$providers")" \
    --argjson providers "$(providers_json "$providers")" \
    --argjson sel "$(plans_json "$plans")" --slurpfile plans "$PLANS_FILE" '
    $plans[0] as $P
    | def profile($s): ($s | split(" ")) as $w | {model: $w[0], effort: $w[1]};
      def resolved($h; $name): $P[$h][$name] as $e | $P[$h][$e.same_as // $name];
      def route: "\(.model) at \(.effort) effort on \(.harness)"
        + (if .floor then " while at least \(.floor.min_percent)% of its \(.floor.scope) quota remains" else "" end);
    reduce ($sel | to_entries[]) as $e (.;
      $e.key as $h | resolved($h; $e.value) as $p | $p.modes[$mode] as $m
      | .coordinator[$h] = profile($m.coordinator)
      | .validation[$h] = profile($m.validation)
      | .secondmates[$h] = profile($m.secondmates)
      | (if $h == $mate and $m.secondmates_allowed == false then .secondmates.allowed = false else . end)
      | .dispatch.rules |= map(
          .strategy as $s
          | if $s == "light" or $s == "standard" or $s == "hard" then
              .use |= map(if .harness == $h then
                {harness: $h} + profile($m[$s])
                + (($p.floors // {})[$s] as $f | if $f == null then {} else {floor: {scope: "all_models", min_percent: $f}} end)
              else . end)
            elif $s == "\($h)-requested" then .use = ({harness: $h} + profile($m.requested))
              | .why = "\($P.why.requested) \(.use | route)."
            elif $s == "\($h)-model-requested" and $p.model_requested_why != null then .why = $p.model_requested_why
            else . end)
      | .dispatch.default |= map(if .harness == $h then {harness: $h} + profile($m.standard) else . end)
    )
    | .dispatch.rules |= map(
        if .strategy == "light" or .strategy == "standard" or .strategy == "hard" then
          .why = "\($P.why[.strategy]) It routes to \(.use | map(select(.harness as $x | $providers | index($x)) | route) | join(", or "))."
        else . end)
  ' "$(template "$mode")"
}

# full_warnings <mode> <plans>: one stderr warning per named plan that full is
# not recommended on. A warning, never a refusal.
full_warnings() {
  local item
  [ "$1" = full ] || return 0
  for item in ${2//,/ }; do
    [ "$(plan_field "${item%%=*}" "${item#*=}" full_warning)" = true ] || continue
    printf 'warning: full is not recommended on %s (%s): automatic starts, fresh starts, and fleet reviews reach its five-hour and weekly limits first; lean or balanced fits it better\n' \
      "$item" "$(plan_field "${item%%=*}" "${item#*=}" label)" >&2
  done
}

# suggest_primary <plans>: which provider should host the primary coordinator
# and no-mistakes validation when both providers have a plan.
suggest_primary() {
  local c x cp xp
  c=$(plan_of claude "$1")
  x=$(plan_of codex "$1")
  [ -n "$c" ] && [ -n "$x" ] || return 0
  cp=$(plan_field claude "$c" pool)
  xp=$(plan_field codex "$x" pool)
  printf 'suggested primary (coordinator and no-mistakes validation): '
  if [ "$cp" = api ] && [ "$xp" = api ]; then
    echo "either; both bill per token, so lean fits best"
  elif [ "$cp" = api ]; then
    echo "codex; the Claude API key is pay-per-token overflow"
  elif [ "$xp" = api ]; then
    echo "claude; the Codex API key is pay-per-token overflow"
  elif [ "$cp" = small ] && [ "$xp" = large ]; then
    echo "codex; its pool is the larger one, and Claude takes light and hard work as a second pool"
  elif [ "$cp" = small ]; then
    echo "claude, with Codex mainly for light work; both pools are small, so lean or balanced fits"
  elif [ "$xp" = large ]; then
    echo "claude; both pools are large, so switch to codex if it has more headroom"
  else
    echo "claude; Codex mainly takes light and requested work"
  fi
}

# Every "when" text any template manages, mapped to its slot, so a rule written
# before the strategy markers existed is still recognized.
known_whens_json() {
  local m
  for m in $MODES; do jq -c '[.dispatch.rules[] | {key: .when, value: .strategy}]' "$(template "$m")"; done \
    | jq -cs 'add | from_entries'
}

# render_dispatch <mode> <providers> <current-file-or-empty>: print the new
# config/crew-dispatch.json under the plans in PLANS.
render_dispatch() {
  local mode=$1 providers=$2 current=$3 cur_json tpl
  tpl=$(effective_template "$mode" "$providers" "$PLANS") || die "cannot render the $mode template"
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
  ' <<<"$tpl"
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
  effective_template "$mode" "$providers" "$PLANS" \
    | jq -r --arg h "$h" '"\($h) \(.secondmates[$h].model) \(.secondmates[$h].effort)"'
}

render_selection() {  # <mode> <providers> <plans>
  printf '# Token strategy for this home, written by bin/fm-strategy.sh; see docs/configuration.md "Token strategies".\n'
  printf 'mode=%s\nproviders=%s\nautonomy=%s\n' "$1" "$2" "$(jq -r .autonomy.level "$(template "$1")")"
  [ -z "$3" ] || printf 'plans=%s\n' "$3"
}

# Preserve the fresh-start owner's optional trigger settings; it validates the
# staged result before any configuration is published.
render_fresh_start() {
  local current='{}' enabled
  if [ -f "$FRESH_START" ]; then
    current=$(cat "$FRESH_START")
  fi
  enabled=$(jq -r .autonomy.fresh_starts "$(template "$1")")
  jq --argjson enabled "$enabled" 'if type != "object" then error("fresh-start config must be an object") else . + {enabled: $enabled} end' <<<"$current"
}

apply_fresh_start() {
  local action=disarm
  [ "$(jq -r .autonomy.fresh_starts "$(template "$1")")" != true ] || action=arm
  if ! FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
    "${FM_STRATEGY_FRESH_START_BIN:-$SCRIPT_DIR/fm-fresh-start.sh}" "$action"; then
    echo "fresh-start check was not updated; rerun bin/fm-strategy.sh set $1 --yes" >&2
    return 1
  fi
}

print_autonomy() {
  jq -r '.autonomy |
    "autonomy: \(.level)",
    "  dispatch: \(.dispatch)",
    "  automatic fix rounds: \(if .automatic_fix_rounds == null then "within existing pipeline limits" else .automatic_fix_rounds end)",
    "  automatic fresh starts: \(.fresh_starts)",
    "  automatic fleet reviews: \(.fleet_reviews)",
    "  one-tier model step-up after a worker failure: \(.step_up // "ask")"' "$(template "$1")"
  echo "  coordinator: load strategy-autonomy to apply the session policy"
}

# print_resolved <mode> <providers>: the per-role result under PLANS.
print_resolved() {
  local mode=$1 providers=$2 tpl dispatch p item mate_h mate_pin
  tpl=$(effective_template "$mode" "$providers" "$PLANS") || die "cannot render the $mode template"
  dispatch=$(render_dispatch "$mode" "$providers" "$DISPATCH")
  printf 'strategy: %s (providers: %s, %s)\n' "$mode" "$providers" "$PROVIDERS_SOURCE"
  printf '  %s\n' "$(jq -r .summary <<<"$tpl")"
  if [ -n "$PLANS" ]; then
    printf 'plans:'
    for item in ${PLANS//,/ }; do
      printf ' %s (%s)' "$item" "$(plan_field "${item%%=*}" "${item#*=}" label)"
    done
    echo "; each plan's profile replaces the template's models, efforts, and floors for its provider"
    full_warnings "$mode" "$PLANS"
  fi
  echo "primary coordinator (set where you start the primary; this tool never edits launchers or global settings):"
  for p in ${providers//,/ }; do
    case "$p" in
      claude)
        jq -r '.coordinator.claude | "  claude: \(.model) effort \(.effort)\n    start with: claude --model \(.model) --effort \(.effort)"' <<<"$tpl"
        ;;
      codex)
        jq -r --arg doc "$FM_CODEX_PROJECT_DOC_MAX_BYTES" '.coordinator.codex | "  codex: \(.model) effort \(.effort)\n    start with: codex -m \(.model) -c model_reasoning_effort=\"\(.effort)\" -c project_doc_max_bytes=\($doc)"' <<<"$tpl"
        ;;
    esac
  done
  [ "$providers" != claude,codex ] || suggest_primary "$PLANS"
  print_autonomy "$mode"
  mate_h=$(mate_harness "$providers")
  mate_pin=$(jq -r --arg h "$mate_h" '.secondmates[$h] | "\($h) \(.model) \(.effort)"' <<<"$tpl")
  if [ "$(jq -r .secondmates.allowed <<<"$tpl")" != true ]; then
    printf 'second mates: off by default; create one only when the captain asks, and running ones are not retired; one that is created launches as %s (config/secondmate-harness)\n' "$mate_pin"
  elif [ "$mode" = balanced ]; then
    printf 'second mates: allowed when the benefit justifies the standing cost; new ones launch as %s (config/secondmate-harness)\n' "$mate_pin"
  else
    printf 'second mates: allowed; new ones launch as %s (config/secondmate-harness)\n' "$mate_pin"
  fi
  echo "worker tiers (config/crew-dispatch.json, one line per candidate):"
  jq -r '
    def profiles($u): if ($u | type) == "array" then $u else [$u] end;
    def slotname($r): ($r.strategy // "custom");
    def txt($p): "\($p.harness) \($p.model // "(harness default model)") \($p.effort // "(harness default effort)")";
    def floor($p): if $p.floor then ", floor \($p.floor.min_percent)%" else "" end;
    (.rules // [])[] as $r | profiles($r.use)[] | "  \(slotname($r)): \(txt(.))\(floor(.))",
    (profiles(.default // [])[] | "  default: \(txt(.))")
  ' <<<"$dispatch"
  if grep -q '"gpt-6.1-terra"' <<<"$dispatch"; then
    echo "  note: gpt-6.1-terra needs Codex CLI 0.159.0 or later"
  fi
  if grep -q '"gpt-6.1-sol"' <<<"$dispatch"; then
    echo "  note: where a workspace has not enabled gpt-6.1-sol, gpt-6-sol is the fallback"
  fi
  echo "validation (no-mistakes agent_config in ~/.no-mistakes/config.yaml; apply by hand):"
  echo "  agent_config:"
  for p in ${providers//,/ }; do
    jq -r --arg p "$p" '.validation[$p] | "    \($p):\n      model: \(.model)\n      effort: \(.effort)"' <<<"$tpl"
  done
  case "$(jq -r .present_mode <<<"$tpl")" in
    quiet) echo "while the captain is present: /quiet requested by this selection (apply through strategy-autonomy; captain-relevant events still arrive)" ;;
    *) echo "while the captain is present: normal supervision" ;;
  esac
  echo "unchanged by every mode and plan: delivery mode, yolo and merge authority, ask-user authority, escalation, which captain-relevant events reach the coordinator, post-handling acknowledgement, permissions, hook trust, AGENTS.md boundaries, native context compaction, and claude-mem"
}

cmd_list() {
  local selected m marker item plans_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plans) [ "$#" -ge 2 ] || usage_die "--plans needs a value"; plans_arg=$2; shift ;;
      --plans=*) plans_arg=${1#--plans=} ;;
      *) usage_die "list takes only --plans" ;;
    esac
    shift
  done
  resolve_plans "$plans_arg"
  selected=$(selection_get mode)
  for m in $MODES; do
    marker=
    [ "$m" = "$selected" ] && marker=' (selected)'
    if [ "$m" = full ]; then
      for item in ${PLANS//,/ }; do
        [ "$(plan_field "${item%%=*}" "${item#*=}" full_warning)" != true ] || marker="$marker (not recommended on $item)"
      done
    fi
    printf '%-9s %s%s\n' "$m" "$(jq -r .summary "$(template "$m")")" "$marker"
  done
  [ -z "$PLANS" ] || echo "plans: $PLANS; show <mode> prints each role under them"
}

parse_mode_flags() {
  # Sets MODE_ARG, PROVIDERS_ARG, PLANS_ARG, DRY_RUN, ASSUME_YES from "$@".
  MODE_ARG=
  PROVIDERS_ARG=
  PLANS_ARG=
  DRY_RUN=0
  ASSUME_YES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --providers) [ "$#" -ge 2 ] || usage_die "--providers needs a value"; PROVIDERS_ARG=$2; shift ;;
      --providers=*) PROVIDERS_ARG=${1#--providers=} ;;
      --plans) [ "$#" -ge 2 ] || usage_die "--plans needs a value"; PLANS_ARG=$2; shift ;;
      --plans=*) PLANS_ARG=${1#--plans=}; [ -n "$PLANS_ARG" ] || usage_die "--plans needs a value" ;;
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
  [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] || usage_die "show takes only a mode, --providers, and --plans"
  [ -n "$MODE_ARG" ] || MODE_ARG=$(selection_get mode)
  [ -n "$MODE_ARG" ] || usage_die "no strategy selected yet; name a mode (full, balanced, or lean)"
  valid_mode "$MODE_ARG" || die "config/strategy names unknown mode '$MODE_ARG'"
  resolve_providers "$PROVIDERS_ARG"
  resolve_plans "$PLANS_ARG" "$PROVIDERS"
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
  resolve_plans "$PLANS_ARG" "$PROVIDERS"
  mkdir -p "$CONFIG" || die "cannot create $CONFIG"
  for f in "$DISPATCH" "$SM_HARNESS" "$SELECTION" "$FRESH_START"; do check_target "$f"; done

  tmpdir=$(mktemp -d "$CONFIG/.fm-strategy.XXXXXX") || die "cannot create a temporary directory in $CONFIG"
  # shellcheck disable=SC2064 # Expand now: the path is fixed for this run.
  trap "rm -rf '$tmpdir'" EXIT
  render_dispatch "$mode" "$PROVIDERS" "$DISPATCH" > "$tmpdir/crew-dispatch.json" || exit 1
  render_secondmate_harness "$mode" "$PROVIDERS" > "$tmpdir/secondmate-harness" || exit 1
  render_selection "$mode" "$PROVIDERS" "$PLANS" > "$tmpdir/strategy" || exit 1

  render_fresh_start "$mode" > "$tmpdir/fresh-start.json" || exit 1
  FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$tmpdir" "$SCRIPT_DIR/fm-fresh-start.sh" validate || exit 1

  print_resolved "$mode" "$PROVIDERS"
  echo
  for base in crew-dispatch.json secondmate-harness strategy fresh-start.json; do
    if ! cmp -s "$CONFIG/$base" "$tmpdir/$base"; then
      changed+=("$base")
      show_diff "config/$base" "$CONFIG/$base" "$tmpdir/$base"
    fi
  done
  if [ "${#changed[@]}" -eq 0 ]; then
    echo "no change: this home already matches $mode"
    if [ "$ASSUME_YES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then apply_fresh_start "$mode" || return 1; fi
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
  local apply_failed=0
  apply_fresh_start "$mode" || apply_failed=1

  if [ "$dispatch_changed" -eq 1 ]; then
    if push_out=$(FM_HOME="$FM_HOME" "${FM_STRATEGY_PUSH_BIN:-$SCRIPT_DIR/fm-config-push.sh}" 2>&1); then
      printf '%s\n' "$push_out" | sed 's/^/  /'
    else
      printf '%s\n' "$push_out" | sed 's/^/  /'
      echo "second mates were not all updated; run bin/fm-config-push.sh again" >&2
      return 1
    fi
  fi
  [ "$apply_failed" -eq 0 ]
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
  resolve_plans "" "$PROVIDERS"
  printf 'strategy: %s (providers: %s)\n' "$mode" "$PROVIDERS"
  printf '  %s\n' "$(jq -r .summary "$(template "$mode")")"
  [ -z "$PLANS" ] || printf 'plans: %s\n' "$PLANS"
  if [ "$(effective_template "$mode" "$PROVIDERS" "$PLANS" | jq -r .secondmates.allowed)" != true ]; then
    echo "second mates: off by default; create one only when the captain asks"
  fi

  print_autonomy "$mode"
  echo "drift:"
  if ! cmp -s "$SELECTION" <(render_selection "$mode" "$PROVIDERS" "$PLANS"); then
    echo "  config/strategy differs from $mode (autonomy selection)"; drift=1
  fi
  if [ ! -f "$FRESH_START" ] || ! FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-fresh-start.sh" validate >/dev/null 2>&1; then
    echo "  config/fresh-start.json is missing or invalid"; drift=1
  elif [ "$(jq -r 'if has("enabled") then .enabled else true end' "$FRESH_START")" != "$(jq -r .autonomy.fresh_starts "$(template "$mode")")" ]; then
    echo "  config/fresh-start.json enabled differs from $mode"; drift=1
  fi
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

  printf 'recorded autonomy: %s\n' "$(selection_get autonomy | sed '/^$/d')"
  [ -n "$(selection_get autonomy)" ] || echo "  legacy selection: autonomy not applied; existing supervision behavior remains"
  if [ "$(jq -r .autonomy.fresh_starts "$(template "$mode")")" = true ]; then
    if [ -f "$STATE/fresh-start.check.sh" ] && [ -f "$STATE/fresh-start.check-trust" ]; then
      echo "fresh-start check: present (config validation above; runtime support is reported by fm-fresh-start.sh status)"
    else
      echo "fresh-start check: missing; rerun bin/fm-strategy.sh set $mode --yes"
    fi
  else
    echo "fresh-start check: disabled by selected policy"
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
  if [ "$(effective_template "$mode" "$PROVIDERS" "$PLANS" | jq -r .secondmates.allowed)" != true ]; then
    recorded_mates=$(grep -l '^kind=secondmate$' "$STATE"/*.meta 2>/dev/null | wc -l | tr -d ' ')
    [ "$recorded_mates" = 0 ] \
      || echo "  $mode${PLANS:+ on $PLANS} turns second mates off by default, but $recorded_mates recorded second mate(s) keep running until the captain retires them"
  fi
  echo "  primary coordinator launch flags and no-mistakes agent_config: set by hand, see bin/fm-strategy.sh show $mode"
  if [ "$(jq -r .present_mode "$(template "$mode")")" = quiet ]; then
    echo "  /quiet is requested; the coordinator applies it through strategy-autonomy"
  fi
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  set) shift; cmd_set "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h | --help | help) usage ;;
  '') usage >&2; exit 2 ;;
  *) usage_die "unknown command '$1'" ;;
esac
