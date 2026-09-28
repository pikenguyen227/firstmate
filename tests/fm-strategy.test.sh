#!/usr/bin/env bash
# bin/fm-strategy.sh: choosing full, balanced, or lean for a home.
#
# Every case drives the real command against a scratch home. The second-mate
# push is replaced through FM_STRATEGY_PUSH_BIN so the tests can see whether it
# ran and make it fail, and PATH is curated where provider detection matters.
#
#   1. Every mode, for each of the three subscription shapes (Claude plus Codex,
#      Claude only, Codex only), resolves every worker route to an explicit
#      harness, model, and effort from the declared providers only, keeps one
#      single-profile requested-model rule per declared provider and none for a
#      missing one, and pins new second mates on an available provider.
#   2. Mode contents: full keeps today's tiers, balanced and lean move the hard
#      Codex tier from Astra to Sol, lean turns second mates off and recommends
#      /quiet, and every Codex coordinator runs Sol at high effort.
#   3. set on an older unmarked file pins the requested-worker rules, adds the
#      requested-model rules, keeps custom rules, custom top-level keys, and
#      extra keys on managed rules, and is idempotent.
#   4. set shows the diff and writes nothing without --yes on a non-terminal or
#      with --dry-run; it pushes only when routing changed, and a failed push
#      exits 1 and names the push to rerun.
#   5. status reports drift, unpinned custom routes, and second mates a mode
#      without them leaves running.
#   6. Refusals: a second mate home, malformed routing, an unknown mode or
#      provider set.
#   7. The provider set is detected from PATH when undeclared and then reused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRATEGY="$ROOT/bin/fm-strategy.sh"
TMP_ROOT=$(fm_test_tmproot fm-strategy)

# new_home <name>: a scratch home with a recording push stub; prints its path.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/bin"
  cat > "$home/bin/push" <<'SH'
#!/usr/bin/env bash
echo "push ran" >> "$FM_HOME/push.log"
[ ! -e "$FM_HOME/push.fail" ] || { echo "push failed"; exit 1; }
echo "config-push: stub"
SH
  chmod +x "$home/bin/push"
  printf '%s\n' "$home"
}

strat() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STRATEGY_PUSH_BIN="$home/bin/push" "$STRATEGY" "$@" </dev/null 2>&1
}

# All profiles of the home's routing as "slot harness model effort" lines.
profiles() {
  jq -r '
    def profiles($u): if ($u | type) == "array" then $u else [$u] end;
    ((.rules // [])[] as $r | profiles($r.use)[] | "\($r.strategy // "custom") \(.harness) \(.model // "-") \(.effort // "-")"),
    (profiles(.default)[] | "default \(.harness) \(.model // "-") \(.effort // "-")")
  ' "$1/config/crew-dispatch.json"
}

# An older routing file with no strategy markers: today's tiers, no
# requested-model rules, unpinned requested-worker rules, one custom rule, a
# custom top-level key, and an approval key on the hard tier.
write_legacy_dispatch() {
  jq '
    .dispatch
    | .rules |= map(select(.strategy | endswith("model-requested") | not) | del(.strategy))
    | .rules[0].use = {harness: "codex"}
    | .rules[1].use = {harness: "claude"}
    | .rules[4].approval = "captain"
    | .rules += [{when: "Anything about the design system.", use: {harness: "claude", model: "claude-opus-5-5", effort: "xhigh"}, why: "custom"}]
    | . + {"$comment": "kept by the captain"}
  ' "$ROOT/bin/strategies/full.json" > "$1/config/crew-dispatch.json"
}

test_every_mode_and_shape_is_explicit() {
  local mode shape home out bad expected_mate expected_named _slot harness model _effort
  for mode in full balanced lean; do
    for shape in claude,codex claude codex; do
      home=$(new_home "shape-$mode-${shape/,/-}")
      out=$(strat "$home" set "$mode" --providers "$shape" --yes) \
        || fail "set $mode for $shape failed: $out"
      bad=$(profiles "$home" | awk '$3 == "-" || $4 == "-"')
      [ -z "$bad" ] || fail "$mode/$shape left a route without an explicit model or effort: $bad"
      while read -r _slot harness model _effort; do
        case ",$shape," in *",$harness,"*) ;; *) fail "$mode/$shape routes to $harness, a provider it lacks" ;; esac
        case "$model" in *fable*) fail "$mode/$shape routes to Fable without a captain request" ;; esac
      done < <(profiles "$home")
      case "$shape" in
        codex)
          assert_not_contains "$(profiles "$home")" "claude-requested" "$mode: a Codex-only home keeps no Claude-requested rule"
          expected_mate="codex gpt-6-sol high"
          expected_named="codex-model-requested codex gpt-6-sol high"
          ;;
        claude)
          assert_not_contains "$(profiles "$home")" "codex-requested" "$mode: a Claude-only home keeps no Codex-requested rule"
          expected_mate="claude claude-opus-5-5 medium"
          expected_named="claude-model-requested claude claude-opus-5-5 high"
          ;;
        *)
          expected_mate="claude claude-opus-5-5 medium"
          expected_named="claude-model-requested claude claude-opus-5-5 high"$'\n'"codex-model-requested codex gpt-6-sol high"
          ;;
      esac
      assert_equals "$expected_named" "$(profiles "$home" | grep -E '^(claude|codex)-model-requested ')" \
        "$mode/$shape keeps a requested-model rule for each declared harness only, so a model from a missing provider matches none"
      assert_equals "$expected_mate" "$(grep -v '^#' "$home/config/secondmate-harness")" "$mode/$shape second mate pin"
      assert_contains "$(cat "$home/config/strategy")" "mode=$mode"$'\n'"providers=$shape" "$mode/$shape selection record"
    done
  done
  pass "every mode resolves every route explicitly for Claude plus Codex, Claude only, and Codex only"
}

test_mode_contents() {
  local home out tpl
  home=$(new_home contents)
  for tpl in full.json balanced.json lean.json; do
    assert_equals "${tpl%.json}" "$(jq -r .mode "$ROOT/bin/strategies/$tpl")" "template $tpl names its own mode"
  done
  out=$(strat "$home" show full --providers claude,codex)
  assert_contains "$out" "hard: codex gpt-6-astra high" "full keeps today's hard Codex tier"
  assert_contains "$out" "light: claude claude-sonnet-5 low" "full keeps today's light Claude tier"
  assert_contains "$out" "codex-requested: codex gpt-6-sol high" "a requested Codex worker is pinned to Sol high"
  assert_contains "$out" "claude: claude-opus-5-5 effort high" "the Claude coordinator stays on Opus"
  assert_contains "$out" "codex -m gpt-6-sol -c model_reasoning_effort=\"high\" -c project_doc_max_bytes=" \
    "a Codex coordinator runs Sol at high effort with the full contract loaded"
  assert_contains "$out" "second mates: allowed" "full allows second mates"
  assert_contains "$out" "normal supervision" "full keeps normal supervision"
  for mode in balanced lean; do
    out=$(strat "$home" show "$mode" --providers claude,codex)
    assert_contains "$out" "hard: codex gpt-6-sol high" "$mode moves the hard Codex tier to Sol high"
    assert_not_contains "$out" "gpt-6-astra" "$mode never routes to Astra"
    assert_contains "$out" "hard: claude claude-opus-5-5 high" "$mode keeps the hard Claude tier on Opus high"
    assert_contains "$out" "claude: claude-opus-5-5 effort high" "$mode keeps an Opus coordinator"
    assert_contains "$out" "codex: gpt-6-sol effort high" "$mode runs a Codex coordinator on Sol high"
    assert_not_contains "$out" "claude-sonnet-5 effort" "$mode never runs a Sonnet coordinator"
  done
  out=$(strat "$home" show lean --providers codex)
  assert_contains "$out" "light: codex gpt-6-luna medium" "lean's light Codex tier is Luna"
  assert_contains "$out" "standard: codex gpt-6-sol medium" "lean's standard Codex tier is Sol medium"
  assert_contains "$out" "second mates: off by default" "lean turns second mates off"
  assert_contains "$out" "/quiet recommended" "lean recommends /quiet while present"
  assert_not_contains "$out" "  claude:" "a Codex-only show prints no Claude coordinator or validation"
  out=$(strat "$home" show balanced --providers claude)
  assert_contains "$out" "second mates: allowed" "balanced allows second mates"
  assert_not_contains "$out" "codex" "a Claude-only show prints nothing for Codex"
  for mode in full balanced lean; do
    out=$(strat "$home" show "$mode" --providers claude,codex)
    assert_contains "$out" "unchanged by every mode: delivery mode, yolo and merge authority, ask-user authority" \
      "$mode states the unchanged safety floor"
  done
  pass "mode contents follow the captain's decisions"
}

test_set_merges_legacy_file() {
  local home out
  home=$(new_home legacy)
  write_legacy_dispatch "$home"
  out=$(strat "$home" set full --providers claude,codex --yes) || fail "set full failed: $out"
  assert_contains "$out" '+        "model": "gpt-6-sol",' "the diff shows the new Codex pin"
  assert_equals "kept by the captain" "$(jq -r '."$comment"' "$home/config/crew-dispatch.json")" "custom top-level key kept"
  assert_equals "captain" "$(jq -r '.rules[] | select(.strategy == "hard") | .approval' "$home/config/crew-dispatch.json")" \
    "an extra key on a managed rule is kept"
  assert_equals "Anything about the design system." "$(jq -r '.rules[-1].when' "$home/config/crew-dispatch.json")" \
    "the custom rule is kept after the managed rules"
  assert_equals 8 "$(jq '.rules | length' "$home/config/crew-dispatch.json")" "legacy rules are replaced, not duplicated"
  assert_equals "codex gpt-6-sol high" \
    "$(jq -r '.rules[] | select(.strategy == "codex-requested") | .use | "\(.harness) \(.model) \(.effort)"' "$home/config/crew-dispatch.json")" \
    "the requested Codex rule is pinned"
  out=$(strat "$home" set full --yes)
  assert_contains "$out" "no change: this home already matches full" "a second set is a no-op"
  out=$(strat "$home" set balanced --yes) || fail "set balanced failed: $out"
  assert_equals "captain" "$(jq -r '.rules[] | select(.strategy == "hard") | .approval' "$home/config/crew-dispatch.json")" \
    "switching modes keeps the extra key"
  assert_equals "Anything about the design system." "$(jq -r '.rules[-1].when' "$home/config/crew-dispatch.json")" \
    "switching modes keeps the custom rule"
  pass "set merges an older file, keeps custom material, and is idempotent"
}

test_set_confirmation_and_push() {
  local home out status before
  home=$(new_home confirm)
  write_legacy_dispatch "$home"
  before=$(cat "$home/config/crew-dispatch.json")
  out=$(strat "$home" set lean --providers claude,codex --dry-run)
  expect_code 0 "$?" "dry run"
  assert_contains "$out" "--- a/config/crew-dispatch.json" "a dry run shows the diff"
  assert_contains "$out" "dry run: nothing written" "a dry run says it wrote nothing"
  out=$(strat "$home" set lean --providers claude,codex)
  status=$?
  expect_code 1 "$status" "set without --yes on a non-terminal"
  assert_contains "$out" "rerun with --yes" "set without --yes names the way to apply"
  assert_equals "$before" "$(cat "$home/config/crew-dispatch.json")" "nothing written without --yes"
  assert_absent "$home/config/strategy" "no selection written without --yes"
  assert_absent "$home/push.log" "no push without a write"

  out=$(strat "$home" set lean --providers claude,codex --yes) || fail "set lean failed: $out"
  assert_equals 1 "$(wc -l < "$home/push.log" | tr -d ' ')" "a routing change pushes to second mates once"
  out=$(strat "$home" set lean --providers claude,codex --yes)
  assert_equals 1 "$(wc -l < "$home/push.log" | tr -d ' ')" "no push when nothing changed"

  : > "$home/push.fail"
  out=$(strat "$home" set full --yes)
  status=$?
  expect_code 1 "$status" "set with a failed push"
  assert_contains "$out" "run bin/fm-config-push.sh again" "a failed push is reported"
  assert_equals "mode=full" "$(grep '^mode=' "$home/config/strategy")" "the local write stands after a failed push"
  pass "set confirms before writing and pushes routing changes to second mates"
}

test_status_reports() {
  local home out
  home=$(new_home status)
  out=$(strat "$home" status)
  assert_contains "$out" "strategy: none selected" "status before any selection"
  strat "$home" set lean --providers claude,codex --yes >/dev/null || fail "set lean failed"
  out=$(strat "$home" status)
  assert_contains "$out" "strategy: lean (providers: claude,codex)" "status names the mode and providers"
  assert_contains "$out" $'drift:\n  none' "no drift right after set"
  assert_contains "$out" "primary coordinator launch flags and no-mistakes agent_config: set by hand" \
    "status lists the settings this tool cannot apply"

  jq '(.rules[] | select(.strategy == "codex-requested") | .use.model) = "gpt-6-astra" | .rules += [{when: "custom", use: {harness: "codex"}}]' \
    "$home/config/crew-dispatch.json" > "$home/dispatch.tmp" && mv "$home/dispatch.tmp" "$home/config/crew-dispatch.json"
  printf 'kind=secondmate\nhome=/nowhere\n' > "$home/state/mate.meta"
  out=$(strat "$home" status)
  assert_contains "$out" "config/crew-dispatch.json differs from lean" "status reports routing drift"
  assert_contains "$out" "custom rule leaves codex without an explicit model or effort: custom" \
    "status reports an unpinned custom route"
  assert_contains "$out" "1 recorded second mate(s) keep running" "status reports second mates lean leaves running"
  pass "status reports the selection, drift, and what it could not apply"
}

test_refusals() {
  local home out status
  home=$(new_home refuse-mate)
  : > "$home/.fm-secondmate-home"
  out=$(strat "$home" set full --providers claude --yes)
  status=$?
  expect_code 1 "$status" "set in a second mate home"
  assert_contains "$out" "second mate home" "the refusal names the reason"
  assert_absent "$home/config/strategy" "nothing written in a second mate home"

  home=$(new_home refuse-malformed)
  printf '{ not json' > "$home/config/crew-dispatch.json"
  out=$(strat "$home" set full --providers claude --yes)
  status=$?
  expect_code 1 "$status" "set over malformed routing"
  assert_contains "$out" "not valid JSON" "malformed routing is named"
  assert_equals "{ not json" "$(cat "$home/config/crew-dispatch.json")" "malformed routing is left untouched"

  out=$(strat "$home" set cheap --providers claude)
  expect_code 2 "$?" "unknown mode"
  out=$(strat "$home" show lean --providers gemini)
  expect_code 2 "$?" "unknown provider"
  pass "set refuses a second mate home, malformed routing, and bad input"
}

test_provider_detection() {
  local home bin path out
  home=$(new_home detect)
  bin="$home/fakebin"
  mkdir -p "$bin"
  fm_fake_exit0 "$bin" codex
  path="$bin:$(fm_test_base_path_sans "$PATH" claude codex)"
  out=$(PATH="$path" strat "$home" set lean --yes) || fail "set with detection failed: $out"
  assert_contains "$out" "providers: codex, detected on PATH" "providers detected from the executables on PATH"
  assert_equals "providers=codex" "$(grep '^providers=' "$home/config/strategy")" "the detected set is recorded"
  fm_fake_exit0 "$bin" claude
  out=$(PATH="$path" strat "$home" show)
  assert_contains "$out" "providers: codex, recorded in config/strategy" "a recorded set wins over a later detection"
  out=$(PATH="$(fm_test_base_path_sans "$PATH" claude codex)" strat "$(new_home detect-none)" show lean)
  assert_contains "$out" "pass --providers" "no provider on PATH asks for an explicit set"
  pass "the provider set is detected when undeclared and then reused"
}

test_every_mode_and_shape_is_explicit
test_mode_contents
test_set_merges_legacy_file
test_set_confirmation_and_push
test_status_reports
test_refusals
test_provider_detection
echo "# all fm-strategy tests passed"
