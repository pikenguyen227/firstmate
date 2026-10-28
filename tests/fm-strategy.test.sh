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
#   2. Mode contents: full routes hard Codex work to Astra at medium, balanced
#      and lean move it to Sol high, light Codex work runs Luna high, lean
#      turns second mates off and requests /quiet, and every Codex coordinator
#      runs Sol at high effort.
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
#   8. Autonomy transitions preserve trigger tuning, running second mates, and
#      unrelated settings; configuration drift and application failures surface.
#      The real fresh-start owner arms/disarms without restarting an agent.
#   9. In a Codex-only home a brief naming a Claude model is offered no
#      requested-model rule, so bin/fm-dispatch-resolve.sh (with Jev and
#      quota-axi stubbed) resolves it through the tier rules.
#  10. Plans: every plan in every mode and provider shape resolves explicitly;
#      the plan profiles, tier ladders, floors, equivalences, Terra placement,
#      second-mate switch, and Fable why text follow the approved matrix; no
#      plan leaves the template output unchanged; API plans write no floor, and
#      the rendered ladders resolve through bin/fm-dispatch-resolve.sh to the
#      cheaper route as the live quota falls.
#  11. Plans are recorded, reused, reported by status, narrowed with the
#      provider set, and cleared with none; full warns without refusing on the
#      small plans; bad plan input is a usage error.
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
  cat > "$home/bin/fresh-start" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FM_HOME/fresh-start.log"
[ ! -e "$FM_HOME/fresh-start.fail" ] || { echo "fresh-start failed"; exit 1; }
SH
  chmod +x "$home/bin/push" "$home/bin/fresh-start"
  printf '%s\n' "$home"
}

strat() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STRATEGY_FRESH_START_BIN="$home/bin/fresh-start" FM_STRATEGY_PUSH_BIN="$home/bin/push" "$STRATEGY" "$@" </dev/null 2>&1
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
          expected_mate="codex gpt-6-sol medium"
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
  local home out
  home=$(new_home contents)
  out=$(strat "$home" show full --providers claude,codex)
  assert_contains "$out" "hard: codex gpt-6-astra medium" "full routes hard Codex work to Astra at medium effort"
  assert_contains "$out" "light: claude claude-sonnet-5-5 low" "full keeps today's light Claude tier"
  assert_contains "$out" "codex-requested: codex gpt-6-sol high" "a requested Codex worker is pinned to Sol high"
  assert_contains "$out" "light: codex gpt-6-luna high" "light Codex work runs Luna at high effort"
  assert_contains "$out" "claude: claude-opus-5-5 effort high" "the Claude coordinator stays on Opus"
  assert_contains "$out" "codex -m gpt-6-sol -c model_reasoning_effort=\"high\" -c project_doc_max_bytes=" \
    "a Codex coordinator runs Sol at high effort with the full contract loaded"
  assert_contains "$out" "second mates: allowed; new ones launch as claude claude-opus-5-5 medium" "full allows second mates"
  assert_contains "$out" "normal supervision" "full keeps normal supervision"
  for mode in balanced lean; do
    out=$(strat "$home" show "$mode" --providers claude,codex)
    assert_contains "$out" "hard: codex gpt-6-sol high" "$mode moves the hard Codex tier to Sol high"
    assert_not_contains "$out" "gpt-6-astra" "$mode never routes to Astra"
    assert_contains "$out" "hard: claude claude-opus-5-5 high" "$mode keeps the hard Claude tier on Opus high"
    assert_contains "$out" "claude: claude-opus-5-5 effort high" "$mode keeps an Opus coordinator"
    assert_contains "$out" "codex: gpt-6-sol effort high" "$mode runs a Codex coordinator on Sol high"
    assert_not_contains "$out" "claude-sonnet-5-5 effort" "$mode never runs a Sonnet coordinator"
  done
  out=$(strat "$home" show lean --providers codex)
  assert_contains "$out" "light: codex gpt-6-luna high" "lean's light Codex tier is Luna high"
  assert_contains "$out" "standard: codex gpt-6-sol medium" "lean's standard Codex tier is Sol medium"
  assert_not_contains "$out" "gpt-6.1-terra" "without a plan nothing routes to Terra"
  assert_contains "$out" "second mates: off by default" "lean turns second mates off"
  assert_contains "$out" "/quiet requested" "lean requests /quiet while present"
  assert_not_contains "$out" "  claude:" "a Codex-only show prints no Claude coordinator or validation"
  out=$(strat "$home" show balanced --providers claude)
  assert_contains "$out" "second mates: allowed when the benefit justifies the standing cost" "balanced allows second mates when they earn their cost"
  assert_not_contains "$out" "codex" "a Claude-only show prints nothing for Codex"
  for mode in full balanced lean; do
    out=$(strat "$home" show "$mode" --providers claude,codex)
    assert_contains "$out" "unchanged by every mode and plan: delivery mode, yolo and merge authority, ask-user authority" \
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

test_missing_provider_model_falls_to_tiers() {
  local home bin hard out
  home=$(new_home named-missing)
  bin="$home/fakebin"
  mkdir -p "$bin"
  strat "$home" set lean --providers codex --yes >/dev/null || fail "set lean for codex failed"
  hard=$(jq -r '.rules | to_entries[] | select(.value.strategy == "hard") | "rule_\(.key + 1)"' "$home/config/crew-dispatch.json")
  printf '%s\n' '# Task' '## Captain'"'"'s intent' 'Use claude-fable-5-1 to diagnose this unexplained crash in the pager.' > "$home/brief.md"
  jq --arg hard "$hard" '{model: "jev-test", answers: {rule: {type: "choice", choice: $hard, confidence: 0.9,
      probabilities: ([(.rules | to_entries[] | "rule_\(.key + 1)"), "default"] | map({key: ., value: (if . == $hard then 1 else 0 end)}) | from_entries)}}}' \
    "$home/config/crew-dispatch.json" > "$home/response.json"
  cat > "$home/quota.json" <<'JSON'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
  { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.5 } } ] } } ] }
JSON
  cat > "$bin/curl" <<SH
#!/usr/bin/env bash
out=''
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac; done
cat > "$home/request.json"
cp "$home/response.json" "\$out"
printf 200
SH
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$home/quota.json" > "$bin/quota-axi"
  chmod +x "$bin/curl" "$bin/quota-axi"
  out=$(PATH="$bin:$PATH" FM_HOME="$home" TYPESAFE_API_KEY=test-key "$ROOT/bin/fm-dispatch-resolve.sh" "$home/brief.md" 2>&1)
  assert_contains "$(cat "$home/request.json")" "exact Codex model" "the resolver is offered the Codex-model rule"
  assert_not_contains "$(cat "$home/request.json")" "exact Claude model" \
    "a Codex-only home offers the resolver no Claude-model rule to match"
  assert_contains "$out" "status: clear" "the brief resolves through a tier rule"
  assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-sol' --effort 'high'" \
    "a Claude model named in a Codex-only home resolves to the hard Codex tier, not a requested-model rule"
  pass "a model from a missing provider matches no requested-model rule and falls to the tier rules"
}


test_autonomy_transitions() {
  local home mode out expected rounds dispatch reviews step
  home=$(new_home autonomy)
  printf '%s\n' '{"enabled":false,"idle_minutes":180,"nightly_at":null,"context_windows":{"custom":200000}}' > "$home/config/fresh-start.json"
  printf 'unchanged approval settings\n' > "$home/config/safety-sentinel"
  printf 'kind=secondmate\n' > "$home/state/mate.meta"
  for mode in full balanced lean full; do
    case "$mode" in
      full) expected=true; rounds='within existing pipeline limits'; dispatch=automatic; reviews=true; step=automatic ;;
      balanced) expected=true; rounds=1; dispatch=light-standard; reviews=false; step=ask ;;
      lean) expected=false; rounds=0; dispatch=confirm; reviews=false; step=ask ;;
    esac
    out=$(strat "$home" set "$mode" --providers codex --yes) || fail "$mode apply failed: $out"
    assert_contains "$(cat "$home/config/strategy")" "autonomy=$mode" "persist $mode autonomy"
    assert_equals "$expected" "$(jq -r .enabled "$home/config/fresh-start.json")" "$mode fresh starts"
    assert_equals '180 null 200000' "$(jq -r '[.idle_minutes,.nightly_at,.context_windows.custom] | map(tostring) | join(" ")' "$home/config/fresh-start.json")" 'trigger tuning survives switches'
    out=$(strat "$home" status)
    assert_contains "$out" "autonomy: $mode" "$mode status shows autonomy"
    assert_contains "$out" "dispatch: $dispatch" "$mode dispatch policy"
    assert_contains "$out" "automatic fix rounds: $rounds" "$mode fix policy"
    assert_contains "$out" "automatic fleet reviews: $reviews" "$mode review policy"
    assert_contains "$out" "one-tier model step-up after a worker failure: $step" "$mode step-up policy"
    assert_contains "$out" $'drift:\n  none' "$mode converges"
    out=$(strat "$home" show)
    assert_contains "$out" "automatic fresh starts: $expected" "$mode preview"
  done
  assert_equals $'arm\narm\ndisarm\narm' "$(cat "$home/fresh-start.log")" 'fresh starts use existing lifecycle owner'
  assert_equals 'kind=secondmate' "$(cat "$home/state/mate.meta")" 'no running second mate is retired'
  assert_equals 'unchanged approval settings' "$(cat "$home/config/safety-sentinel")" 'unrelated settings preserved'
  printf 'mode=full\nproviders=codex\nautonomy=lean\n' > "$home/config/strategy"
  printf '{"enabled":false}\n' > "$home/config/fresh-start.json"
  out=$(strat "$home" status)
  assert_contains "$out" 'config/strategy differs from full (autonomy selection)' 'autonomy drift detected'
  assert_contains "$out" 'config/fresh-start.json enabled differs from full' 'fresh-start drift detected'
  pass 'all autonomy levels apply, preserve tuning and running work, and report drift'
}

test_autonomy_refusal_and_recovery() {
  local home out before
  home=$(new_home autonomy-recovery)
  out=$(strat "$home" set full --providers codex --dry-run)
  assert_contains "$out" 'a/config/fresh-start.json' 'fresh-start diff is reviewable'
  assert_absent "$home/config/fresh-start.json" 'dry run does not enable fresh starts'
  assert_absent "$home/fresh-start.log" 'dry run does not arm a check'
  out=$(strat "$home" set full --providers codex)
  expect_code 1 "$?" 'unconfirmed autonomy selection'
  assert_absent "$home/fresh-start.log" 'unconfirmed selection does not arm a check'
  printf '{"idle_minutes":1}\n' > "$home/config/fresh-start.json"
  out=$(strat "$home" set full --providers codex --yes)
  expect_code 1 "$?" 'invalid tuning refuses selection'
  assert_absent "$home/config/strategy" 'invalid tuning publishes nothing'
  printf '{}\n' > "$home/config/fresh-start.json"
  : > "$home/fresh-start.fail"
  out=$(strat "$home" set balanced --providers codex --yes)
  expect_code 1 "$?" 'fresh-start application failure'
  assert_contains "$out" 'rerun bin/fm-strategy.sh set balanced --yes' 'failure names retry'
  before=$(cat "$home/config/strategy")
  rm "$home/fresh-start.fail"
  out=$(strat "$home" set balanced --yes)
  expect_code 0 "$?" 'unchanged selection retries runtime application'
  assert_equals "$before" "$(cat "$home/config/strategy")" 'retry preserves selected config'
  assert_equals $'arm\narm' "$(cat "$home/fresh-start.log")" 'retry reaches owner again'
  pass 'autonomy writes require confirmation and failed application can be retried'
}

test_real_fresh_start_owner() {
  local home mode out
  home=$(new_home real-fresh-start)
  for mode in full balanced lean; do
    out=$(FM_HOME="$home" FM_STRATEGY_PUSH_BIN="$home/bin/push" "$STRATEGY" set "$mode" --providers codex --yes 2>&1) || fail "real owner $mode failed: $out"
    if [ "$mode" = lean ]; then
      assert_absent "$home/state/fresh-start.check.sh" 'lean disarms the check'
      out=$(FM_HOME="$home" "$ROOT/bin/fm-fresh-start.sh" status)
      assert_contains "$out" 'enabled is false' 'real owner recognizes lean disablement'
    else
      [ -f "$home/state/fresh-start.check.sh" ] || fail "$mode did not arm the check"
      [ -f "$home/state/fresh-start.check-trust" ] || fail "$mode did not register check trust"
    fi
  done
  pass 'strategy uses real fresh-start registration without restarting agents'
}

# plan_profile <home> <slot> <harness>: "model effort floor" for each of the
# slot's routes on that harness, stronger first, joined by ", ".
plan_profile() {
  jq -r --arg s "$2" --arg h "$3" '
    def profiles($u): if ($u | type) == "array" then $u else [$u] end;
    [.rules[] | select(.strategy == $s)] | first | [profiles(.use)[] | select(.harness == $h)
      | "\(.model) \(.effort) \(.floor.min_percent // "-")"] | if length == 0 then "absent" else join(", ") end
  ' "$1/config/crew-dispatch.json"
}

# stale_whys <home>: each requested-worker or tier rule whose why omits one of
# its routes, or names a model or percentage none of its routes has.
stale_whys() {
  jq -r '
    .rules[] | select(.strategy | test("^(light|standard|hard|claude-requested|codex-requested)$"))
    | . as $r | (if (.use | type) == "array" then .use else [.use] end) as $u
    | ([$r.why | scan("(?:claude|gpt)-[a-z0-9.-]+[a-z0-9]|\\b(?:Opus|Sonnet|Haiku|Sol|Luna|Terra|Astra)\\b")] - [$u[].model]) as $stray_models
    | ([$r.why | scan("[0-9]+%")] - [$u[] | select(.floor) | "\(.floor.min_percent)%"]) as $stray_percents
    | [$u[] | "\(.model) at \(.effort) effort on \(.harness)" + (if .floor then " while at least \(.floor.min_percent)%" else "" end)
        | select(. as $p | $r.why | contains($p) | not)] as $missing
    | select(($stray_models + $stray_percents + $missing) | length > 0)
    | "\(.strategy): \($r.why)"
  ' "$1/config/crew-dispatch.json"
}

test_plans_render_matrix() {
  local mode cp xp home out bad h
  for mode in full balanced lean; do
    for cp in pro max5x max20x api; do
      for xp in plus pro api; do
        home=$(new_home "plans-$mode-$cp-$xp")
        out=$(strat "$home" set "$mode" --providers claude,codex --plans "claude=$cp,codex=$xp" --yes) \
          || fail "set $mode claude=$cp,codex=$xp failed: $out"
        bad=$(profiles "$home" | awk '$3 == "-" || $4 == "-" || $3 ~ /fable/')
        [ -z "$bad" ] || fail "$mode claude=$cp,codex=$xp left an unpinned or Fable route: $bad"
        bad=$(jq -r '.rules[] | select(.strategy == "light" or .strategy == "standard" or .strategy == "hard")
          | select(([.use[].harness] | unique) != ["claude", "codex"] or [.use[].harness] != ([.use[].harness] | sort)
              or .select != "ladder") | .strategy' "$home/config/crew-dispatch.json")
        [ -z "$bad" ] || fail "$mode claude=$cp,codex=$xp does not list Claude then Codex routes as a declared ladder in tier: $bad"
        bad=$(jq -r '.rules[] | select(.strategy == "light" or .strategy == "standard" or .strategy == "hard") | .strategy as $s
          | .use | group_by(.harness)[] | . as $l | range(0; length) as $i
          | select(($i < ($l | length) - 1 and ($l[$i].floor.min_percent // -1) <= ($l[$i + 1].floor.min_percent // 0))
              or ($s == "hard" and $i == ($l | length) - 1 and $l[$i].floor != null))
          | "\($s) \($l[$i].model) \($l[$i].effort)"' "$home/config/crew-dispatch.json")
        [ -z "$bad" ] || fail "$mode claude=$cp,codex=$xp has a ladder step without a higher floor than the next, or a floored last hard route: $bad"
        bad=$(jq -r '[.rules[].use, .default] | map(if type == "array" then .[] else . end)
          | .[] | select(.floor != null and (.floor.scope != "all_models" or .floor.min_percent <= 0)) | .model' "$home/config/crew-dispatch.json")
        [ -z "$bad" ] || fail "$mode claude=$cp,codex=$xp wrote a floor off the all_models scope: $bad"
        for h in claude codex; do
          bad=$(jq -r --arg h "$h" '[.rules[] | select(.strategy == "light" or .strategy == "standard") | .use[] | select(.harness == $h)]
            | if length > 0 and all(.floor == null) then "none" else empty end' "$home/config/crew-dispatch.json")
          case "$h=$( [ "$h" = claude ] && echo "$cp" || echo "$xp")" in
            *=api) [ "$bad" = none ] || fail "$mode $h API plan wrote a floor" ;;
            *) [ -z "$bad" ] || fail "$mode $h plan wrote no light or standard floor" ;;
          esac
        done
        bad=$(stale_whys "$home")
        [ -z "$bad" ] || fail "$mode claude=$cp,codex=$xp left a why that does not match its routes: $bad"
      done
    done
  done
  for mode in full balanced lean; do
    for cp in pro max5x max20x api; do
      home=$(new_home "plans-claude-only-$mode-$cp")
      strat "$home" set "$mode" --providers claude --plans "claude=$cp" --yes >/dev/null || fail "claude-only $mode $cp failed"
      assert_not_contains "$(profiles "$home")" " codex " "a Claude-only $cp home routes nothing to Codex"
      assert_equals "" "$(stale_whys "$home")" "a Claude-only $cp $mode home's why text matches its routes"
    done
    for xp in plus pro api; do
      home=$(new_home "plans-codex-only-$mode-$xp")
      strat "$home" set "$mode" --providers codex --plans "codex=$xp" --yes >/dev/null || fail "codex-only $mode $xp failed"
      assert_not_contains "$(profiles "$home")" " claude " "a Codex-only $xp home routes nothing to Claude"
      assert_equals "" "$(stale_whys "$home")" "a Codex-only $xp $mode home's why text matches its routes"
    done
  done
  pass "every plan in every mode and provider shape resolves explicitly, lists each tier as declared Claude then Codex ladders with falling floors, floors only subscription plans, and explains its routes"
}

test_plan_profiles() {
  local home out mode plan full
  home=$(new_home plan-pro-lean)
  out=$(strat "$home" set lean --providers claude,codex --plans claude=pro,codex=plus --yes) || fail "pro/plus lean failed: $out"
  assert_equals "claude-haiku-5-5 low 30" "$(plan_profile "$home" light claude)" "Pro lean light work runs Haiku low above a 30% floor"
  assert_equals "claude-sonnet-5-5 low 20" "$(plan_profile "$home" standard claude)" "Pro lean standard work runs Sonnet low above a 20% floor"
  assert_equals "claude-opus-5-5 medium -" "$(plan_profile "$home" hard claude)" "Pro lean hard work stays on Opus, unfloored"
  assert_equals "claude-opus-5-5 medium -" "$(plan_profile "$home" claude-requested claude)" "a requested Claude worker on Pro lean runs Opus medium"
  assert_equals "gpt-6-luna medium 30" "$(plan_profile "$home" light codex)" "Plus lean light work runs Luna medium above a 30% floor"
  assert_equals "gpt-6.1-terra low 60, gpt-6-luna high 20" "$(plan_profile "$home" standard codex)" "Plus lean standard work steps from Terra low to Luna high"
  assert_equals "gpt-6-sol medium -" "$(plan_profile "$home" hard codex)" "Plus lean hard work runs Sol medium"
  assert_equals "gpt-6-sol medium -" "$(plan_profile "$home" codex-requested codex)" "a requested Codex worker on Plus lean runs Sol medium"
  assert_equals "claude claude-sonnet-5-5 medium" "$(grep -v '^#' "$home/config/secondmate-harness")" "Pro pins a created second mate to Sonnet medium"
  out=$(strat "$home" show)
  assert_contains "$out" "claude: claude-opus-5-5 effort medium" "the Pro coordinator runs Opus at medium"
  assert_contains "$out" "codex: gpt-6-sol effort medium" "the Plus coordinator runs Sol at medium"
  assert_contains "$out" $'    claude:\n      model: claude-opus-5-5\n      effort: high' "Pro validation stays Opus high"
  assert_contains "$out" $'    codex:\n      model: gpt-6-sol\n      effort: high' "Plus validation stays Sol high"
  assert_contains "$out" "second mates: off by default" "Pro lean turns second mates off"
  assert_contains "$out" "gpt-6.1-terra needs Codex CLI 0.159.0 or later; choose an available model explicitly if an interactive session refuses it" "a Terra route names its Codex CLI minimum and manual recovery"
  assert_contains "$out" "the first whose floor holds is used" "show explains a ladder"
  assert_contains "$(jq -r '.rules[] | select(.strategy == "claude-model-requested") | .why' "$home/config/crew-dispatch.json")" \
    "bills usage credits" "the requested-model rule on Pro says a Fable request bills usage credits"

  strat "$home" set balanced --yes >/dev/null || fail "Pro/Plus balanced failed"
  assert_equals "claude-haiku-5-5 medium 50, claude-haiku-5-5 low 30" "$(plan_profile "$home" light claude)" "Pro balanced light work steps from Haiku medium to Haiku low"
  assert_equals "claude-sonnet-5-5 medium 50, claude-sonnet-5-5 low 20" "$(plan_profile "$home" standard claude)" "Pro balanced standard work steps from Sonnet medium to Sonnet low"
  assert_equals "claude-opus-5-5 high 50, claude-opus-5-5 medium -" "$(plan_profile "$home" hard claude)" "Pro balanced hard work only lowers Opus effort"
  assert_equals "gpt-6.1-terra medium 50, gpt-6.1-terra low 20" "$(plan_profile "$home" standard codex)" "Plus balanced standard work steps from Terra medium to Terra low"
  assert_contains "$(strat "$home" show)" "second mates: off by default" "Pro balanced turns second mates off"
  out=$(strat "$home" show full)
  assert_contains "$out" "standard: codex gpt-6-sol medium, floor 20%" "Plus full standard work stays on Sol above the Plus floor"
  assert_not_contains "$out" "gpt-6.1-terra" "Plus full never routes to Terra"
  assert_contains "$out" "light: claude claude-sonnet-5-5 low, floor 30%" "Pro full light work runs Sonnet low above the Pro floor"
  assert_not_contains "$out" "the first whose floor holds is used" "full lists no ladder"
  assert_contains "$out" "second mates: allowed; new ones launch as claude claude-sonnet-5-5 medium" "Pro full allows Sonnet second mates"

  for plan in max5x max20x; do
    home=$(new_home "plan-$plan")
    strat "$home" set full --providers claude,codex --plans "claude=$plan,codex=pro" --yes >/dev/null || fail "$plan full failed"
    full=$(cat "$home/config/crew-dispatch.json")
    strat "$home" set balanced --yes >/dev/null || fail "$plan balanced failed"
    assert_equals "claude-haiku-5-5 medium 35, claude-haiku-5-5 low $([ "$plan" = max5x ] && echo 20 || echo 15)" "$(plan_profile "$home" light claude)" "$plan balanced light work steps from Haiku medium to Haiku low"
    assert_equals "claude-sonnet-5-5 medium 35, claude-sonnet-5-5 low $([ "$plan" = max5x ] && echo 10 || echo 5)" "$(plan_profile "$home" standard claude)" "$plan balanced standard work steps from Sonnet medium to Sonnet low"
    assert_equals "claude-opus-5-5 high 35, claude-opus-5-5 medium -" "$(plan_profile "$home" hard claude)" "$plan balanced hard work keeps Opus"
    assert_equals "claude claude-sonnet-5-5 medium" "$(grep -v '^#' "$home/config/secondmate-harness")" "$plan balanced second mates run Sonnet medium"
    out=$(strat "$home" show)
    assert_contains "$out" "claude: claude-opus-5-5 effort high" "$plan balanced keeps the Opus high coordinator"
    assert_contains "$out" $'    claude:\n      model: claude-opus-5-5\n      effort: high' "$plan balanced reviews stay Opus high"
    assert_contains "$out" "second mates: allowed when the benefit justifies" "$plan balanced allows second mates"
    strat "$home" set lean --yes >/dev/null || fail "$plan lean failed"
    assert_equals "claude-haiku-5-5 low $([ "$plan" = max5x ] && echo 20 || echo 15)" "$(plan_profile "$home" light claude)" "$plan lean light work runs Haiku low"
    assert_equals "claude-sonnet-5-5 low $([ "$plan" = max5x ] && echo 10 || echo 5)" "$(plan_profile "$home" standard claude)" "$plan lean standard work runs Sonnet low"
    assert_equals "claude-opus-5-5 medium -" "$(plan_profile "$home" hard claude)" "$plan lean hard work runs Opus medium"
    assert_equals "claude-opus-5-5 high -" "$(plan_profile "$home" claude-requested claude)" "$plan lean keeps a requested Claude worker on Opus high"
    out=$(strat "$home" show)
    assert_contains "$out" "claude: claude-opus-5-5 effort medium" "$plan lean runs the coordinator on Opus medium"
    assert_contains "$out" $'    claude:\n      model: claude-opus-5-5\n      effort: high' "$plan lean reviews stay Opus high"
    assert_contains "$out" "second mates: off by default" "$plan lean turns second mates off"
    strat "$home" set full --yes >/dev/null || fail "$plan full again failed"
    assert_equals "$full" "$(cat "$home/config/crew-dispatch.json")" "$plan full renders the same after a balanced and lean round trip"
    assert_equals "claude-sonnet-5-5 low $([ "$plan" = max5x ] && echo 20 || echo 15)" "$(plan_profile "$home" light claude)" "$plan full light work is unchanged"
    assert_equals "claude-opus-5-5 medium $([ "$plan" = max5x ] && echo 10 || echo 5)" "$(plan_profile "$home" standard claude)" "$plan full standard work is unchanged"
    assert_equals "claude-opus-5-5 high -" "$(plan_profile "$home" hard claude)" "$plan full hard work is unchanged"
  done

  home=$(new_home plan-codex-pro)
  strat "$home" set balanced --providers codex --plans codex=pro --yes >/dev/null || fail "Codex Pro balanced failed"
  assert_equals "gpt-6-luna high 35, gpt-6-luna medium 20" "$(plan_profile "$home" light codex)" "Codex Pro balanced light work steps from Luna high to Luna medium"
  assert_equals "gpt-6.1-terra medium 35, gpt-6.1-terra low 10" "$(plan_profile "$home" standard codex)" "Codex Pro balanced standard work steps from Terra medium to Terra low"
  assert_equals "gpt-6-sol high 35, gpt-6-sol medium -" "$(plan_profile "$home" hard codex)" "Codex Pro balanced hard work keeps Sol"
  out=$(strat "$home" show)
  assert_contains "$out" "codex: gpt-6-sol effort high" "Codex Pro balanced keeps the Sol high coordinator"
  assert_contains "$out" "second mates: allowed when the benefit justifies the standing cost; new ones launch as codex gpt-6-sol medium" "Codex Pro balanced second mates run Sol medium"
  strat "$home" set lean --yes >/dev/null || fail "Codex Pro lean failed"
  assert_equals "gpt-6-luna medium 20" "$(plan_profile "$home" light codex)" "Codex Pro lean light work runs Luna medium"
  assert_equals "gpt-6.1-terra low 50, gpt-6-luna high 10" "$(plan_profile "$home" standard codex)" "Codex Pro lean standard work steps from Terra low to Luna high"
  assert_equals "gpt-6-sol medium -" "$(plan_profile "$home" hard codex)" "Codex Pro lean hard work runs Sol medium"
  out=$(strat "$home" show)
  assert_contains "$out" "codex: gpt-6-sol effort medium" "Codex Pro lean runs the coordinator on Sol medium"
  assert_contains "$out" $'    codex:\n      model: gpt-6-sol\n      effort: high' "Codex Pro lean reviews stay Sol high"
  assert_contains "$out" "second mates: off by default" "Codex Pro lean turns second mates off"
  out=$(strat "$home" show full)
  assert_contains "$out" "hard: codex gpt-6-astra medium" "Codex Pro full runs hard work on Astra medium"
  assert_contains "$out" "light: codex gpt-6-luna high, floor 20%" "Codex Pro full light work keeps Luna high above the Codex Pro floor"
  assert_not_contains "$out" "gpt-6.1-terra" "Codex Pro full never routes to Terra"

  for mode in full balanced lean; do
    out=$(strat "$home" show "$mode" --providers claude,codex --plans claude=api,codex=api)
    assert_not_contains "$out" ", floor " "an API $mode home writes no floor"
    case "$mode" in
      lean) assert_contains "$out" "standard: codex gpt-6.1-terra medium" "a Codex API key in lean runs standard work on Terra" ;;
      *) assert_not_contains "$out" "gpt-6.1-terra" "a Codex API key in $mode never routes to Terra" ;;
    esac
  done
  out=$(strat "$home" show balanced --providers claude,codex --plans claude=max5x,codex=plus)
  assert_contains "$out" "second mates: allowed when the benefit justifies the standing cost; new ones launch as claude claude-sonnet-5-5 medium" \
    "a Max 5x home keeps balanced second mates although its Codex plan would turn them off"
  assert_contains "$out" "suggested primary (coordinator and no-mistakes validation): claude" "Max 5x with Plus suggests a Claude primary"
  out=$(strat "$home" show balanced --providers codex --plans codex=plus)
  assert_contains "$out" "second mates: off by default" "a Codex-only Plus home turns balanced second mates off"
  out=$(strat "$home" show balanced --providers claude,codex --plans claude=pro,codex=pro)
  assert_contains "$out" "suggested primary (coordinator and no-mistakes validation): codex" "Claude Pro with Codex Pro suggests a Codex primary"
  assert_contains "$(strat "$home" set balanced --providers claude,codex --plans claude=max5x --yes >/dev/null && jq -r '.rules[] | select(.strategy == "claude-model-requested") | .why' "$home/config/crew-dispatch.json")" \
    "separate weekly Fable limit" "the requested-model rule on Max says Fable draws on its separate weekly limit"
  pass "plan profiles follow the approved matrix for models, efforts, ladders, floors, Terra, second mates, and the suggested primary"
}

# The rendered ladders are what the resolver reads: with Jev and quota-axi
# stubbed, a Claude-only Max 20x balanced home sends light work to Haiku medium
# while the week has room and to Haiku low once all_models falls below the
# step-down floor, and a Codex-only Pro home does the same on its all_models row.
test_plan_ladder_resolves() {
  local home bin light_rule h plan pct expect out
  for h in claude codex; do
    home=$(new_home "ladder-$h")
    bin="$home/fakebin"
    mkdir -p "$bin"
    plan=max20x
    [ "$h" = claude ] || plan=pro
    strat "$home" set balanced --providers "$h" --plans "$h=$plan" --yes >/dev/null || fail "set balanced $h=$plan failed"
    light_rule=$(jq -r '.rules | to_entries[] | select(.value.strategy == "light") | "rule_\(.key + 1)"' "$home/config/crew-dispatch.json")
    printf '%s\n' '# Task' '## Captain'"'"'s intent' 'Bump the version string in package.json to 2.1.0.' > "$home/brief.md"
    jq --arg rule "$light_rule" '{model: "jev-test", answers: {rule: {type: "choice", choice: $rule, confidence: 0.9,
        probabilities: ([(.rules | to_entries[] | "rule_\(.key + 1)"), "default"] | map({key: ., value: (if . == $rule then 1 else 0 end)}) | from_entries)}}}' \
      "$home/config/crew-dispatch.json" > "$home/response.json"
    cat > "$bin/curl" <<SH
#!/usr/bin/env bash
out=''
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
cp "$home/response.json" "\$out"
printf 200
SH
    printf '#!/usr/bin/env bash\ncat "%s"\n' "$home/quota.json" > "$bin/quota-axi"
    chmod +x "$bin/curl" "$bin/quota-axi"
    for pct in 80 25; do
      jq -n --arg h "$h" --argjson pct "$pct" '{generatedAt: "2030-01-01T00:00:00Z", schemaVersion: 5, providers: [
        {provider: $h, state: {status: "fresh"}, quotaSemantics: {status: "known", effectiveAvailability: [
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct, runway: {status: "projected_exhaustion"}, selection: {spendPriority: -0.5}}]}}]}' \
        > "$home/quota.json"
      out=$(PATH="$bin:$PATH" FM_HOME="$home" TYPESAFE_API_KEY=test-key "$ROOT/bin/fm-dispatch-resolve.sh" "$home/brief.md" 2>&1)
      case "$h-$pct" in
        claude-80) expect="--harness 'claude' --model 'claude-haiku-5-5' --effort 'medium'" ;;
        claude-25) expect="--harness 'claude' --model 'claude-haiku-5-5' --effort 'low'" ;;
        codex-80) expect="--harness 'codex' --model 'gpt-6-luna' --effort 'high'" ;;
        codex-25) expect="--harness 'codex' --model 'gpt-6-luna' --effort 'medium'" ;;
      esac
      assert_contains "$out" "status: clear" "$h=$plan balanced light work resolves at $pct% remaining"
      assert_contains "$out" "profile: $expect" "$h=$plan balanced light work at $pct% remaining runs $expect"
    done
  done
  pass "a plan's tier ladder resolves to the stronger route while quota holds and to the cheaper route once it falls"
}

test_plan_equivalences_and_no_plan() {
  local mode home base alias pair
  for mode in full balanced lean; do
    home=$(new_home "no-plan-$mode")
    strat "$home" set "$mode" --providers claude,codex --yes >/dev/null || fail "no-plan $mode failed"
    assert_equals "$(jq -S '.dispatch | {rules, default}' "$ROOT/bin/strategies/$mode.json")" "$(jq -S . "$home/config/crew-dispatch.json")" \
      "$mode without a plan writes the template routing unchanged"
    assert_not_contains "$(cat "$home/config/strategy")" "plans=" "$mode without a plan records no plans"
    assert_equals "$(jq -r '.secondmates.claude | "claude \(.model) \(.effort)"' "$ROOT/bin/strategies/$mode.json")" \
      "$(grep -v '^#' "$home/config/secondmate-harness")" "$mode without a plan pins the template second mate"
  done
  # Equivalence is data (same_as), not per-mode logic, so one mode pins it.
  mode=balanced
  for pair in team-standard:pro enterprise-standard:pro team-premium:max5x enterprise-premium:max5x; do
    alias=${pair%%:*}
    base=${pair#*:}
    strat "$(new_home "eq-$mode-$alias")" set "$mode" --providers claude --plans "claude=$alias" --yes >/dev/null || fail "$alias failed"
    strat "$(new_home "eq-$mode-$alias-base")" set "$mode" --providers claude --plans "claude=$base" --yes >/dev/null || fail "$base failed"
    assert_equals "$(cat "$TMP_ROOT/eq-$mode-$alias-base/config/crew-dispatch.json")" "$(cat "$TMP_ROOT/eq-$mode-$alias/config/crew-dispatch.json")" \
      "$mode: Claude $alias routes exactly as $base"
  done
  for pair in business-standard:plus business-premium:pro enterprise-edu:pro; do
    alias=${pair%%:*}
    base=${pair#*:}
    strat "$(new_home "eq-$mode-x-$alias")" set "$mode" --providers codex --plans "codex=$alias" --yes >/dev/null || fail "$alias failed"
    strat "$(new_home "eq-$mode-x-$alias-base")" set "$mode" --providers codex --plans "codex=$base" --yes >/dev/null || fail "$base failed"
    assert_equals "$(cat "$TMP_ROOT/eq-$mode-x-$alias-base/config/crew-dispatch.json")" "$(cat "$TMP_ROOT/eq-$mode-x-$alias/config/crew-dispatch.json")" \
      "$mode: Codex $alias routes exactly as $base"
  done
  pass "plan equivalences route exactly as their shared profile, and no plan leaves the template output unchanged"
}

test_plan_recording_and_warnings() {
  local home out status plan
  home=$(new_home plan-record)
  out=$(strat "$home" set balanced --providers claude,codex --plans claude=max5x,codex=plus --yes) || fail "set with plans failed: $out"
  assert_equals "plans=claude=max5x,codex=plus" "$(grep '^plans=' "$home/config/strategy")" "the plans are recorded"
  out=$(strat "$home" show)
  assert_contains "$out" "plans: claude=max5x (Max 5x) codex=plus (Plus)" "show reuses the recorded plans"
  out=$(strat "$home" status)
  assert_contains "$out" "plans: claude=max5x,codex=plus" "status reports the recorded plans"
  assert_not_contains "$out" "second mates: off by default" "status on Max 5x balanced leaves second mates allowed"
  strat "$home" set balanced --plans claude=pro --yes >/dev/null || fail "set Pro balanced failed"
  assert_contains "$(strat "$home" status)" "second mates: off by default" "status says a Pro balanced home turns second mates off"
  strat "$home" set balanced --plans claude=max5x,codex=plus --yes >/dev/null || fail "restoring Max 5x and Plus failed"
  out=$(strat "$home" status)
  assert_contains "$out" $'drift:\n  none' "no drift right after a set with plans"
  out=$(strat "$home" list)
  assert_contains "$out" "(not recommended on codex=plus)" "list marks full as not recommended on a recorded small plan"
  out=$(strat "$home" set lean --yes) || fail "set lean with recorded plans failed: $out"
  assert_equals "gpt-6.1-terra low 60, gpt-6-luna high 20" "$(plan_profile "$home" standard codex)" "a mode change keeps the recorded plans"
  out=$(strat "$home" set lean --providers claude --yes) || fail "narrowing the providers failed: $out"
  assert_equals "plans=claude=max5x" "$(grep '^plans=' "$home/config/strategy")" "a recorded plan for a dropped provider is dropped with it"
  out=$(strat "$home" set lean --plans none --yes) || fail "clearing the plans failed: $out"
  assert_no_grep "plans=" "$home/config/strategy" "none clears the recorded plans"
  assert_equals "$(jq -S '.dispatch.rules[] | select(.strategy == "light") | .use[0]' "$ROOT/bin/strategies/lean.json")" \
    "$(jq -S '.rules[] | select(.strategy == "light") | .use[0]' "$home/config/crew-dispatch.json")" "none restores the template routing"

  for plan in claude=pro claude=team-standard codex=plus codex=business-standard; do
    home=$(new_home "warn-${plan/=/-}")
    out=$(strat "$home" set full --providers claude,codex --plans "$plan" --yes)
    status=$?
    expect_code 0 "$status" "full on $plan is applied"
    assert_contains "$out" "warning: full is not recommended on $plan" "full on $plan warns"
    assert_contains "$(cat "$home/config/strategy")" "mode=full" "full on $plan is written despite the warning"
    out=$(strat "$home" set balanced --yes)
    assert_not_contains "$out" "warning:" "balanced on $plan does not warn"
  done
  for plan in claude=enterprise-standard claude=max5x claude=api codex=pro codex=api; do
    out=$(strat "$(new_home "nowarn-${plan/=/-}")" show full --providers claude,codex --plans "$plan")
    assert_not_contains "$out" "warning:" "full on $plan does not warn"
  done
  pass "plans are recorded, reused, narrowed, and cleared, and full on a small plan warns without refusing"
}

test_plan_refusals() {
  local home out
  home=$(new_home plan-refuse)
  out=$(strat "$home" show lean --providers claude,codex --plans claude=max)
  expect_code 2 "$?" "an unknown Claude plan"
  assert_contains "$out" "claude: pro, team-standard, enterprise-standard, max5x, team-premium, enterprise-premium, max20x, api" "the refusal lists the Claude plans"
  out=$(strat "$home" show lean --providers claude,codex --plans codex=go)
  expect_code 2 "$?" "an unknown Codex plan"
  out=$(strat "$home" show lean --providers claude --plans codex=plus)
  expect_code 2 "$?" "a plan for a provider outside the set"
  assert_contains "$out" "codex is not in the provider set" "the refusal names the missing provider"
  out=$(strat "$home" set lean --providers claude,codex --plans claude=pro,claude=max5x --yes)
  expect_code 2 "$?" "two plans for one provider"
  out=$(strat "$home" set lean --providers claude,codex --plans pro --yes)
  expect_code 2 "$?" "a plan without its provider"
  out=$(strat "$home" list --plans claude=nope)
  expect_code 2 "$?" "list with an unknown plan"
  assert_absent "$home/config/strategy" "no refused plan input writes anything"
  printf 'mode=lean\nproviders=claude\nautonomy=lean\nplans=claude=gold\n' > "$home/config/strategy"
  out=$(strat "$home" status)
  expect_code 1 "$?" "an unknown recorded plan"
  assert_contains "$out" "unknown plans 'claude=gold'" "the unknown recorded plan is named"
  pass "unknown, misplaced, duplicated, and unknown recorded plans are refused"
}

test_every_mode_and_shape_is_explicit
test_mode_contents
test_set_merges_legacy_file
test_set_confirmation_and_push
test_status_reports
test_refusals
test_provider_detection
test_missing_provider_model_falls_to_tiers
test_autonomy_transitions
test_autonomy_refusal_and_recovery
test_real_fresh_start_owner
test_plans_render_matrix
test_plan_profiles
test_plan_ladder_resolves
test_plan_equivalences_and_no_plan
test_plan_recording_and_warnings
test_plan_refusals
echo "# all fm-strategy tests passed"
