#!/usr/bin/env bash
# bin/fm-step-up.sh: the automatic one-tier model step-up after a real worker
# failure.
#
# Every case drives the real command against a scratch home. The relaunch is
# replaced through FM_STEP_UP_CONTROL_BIN with a stub that records its argv, and
# a PATH no-mistakes stub serves the validation-run overview.
#
#   1. Each trigger steps one tier up: a terminal failed:, an open blocked:
#      (closed by the step record), and the second recorded Test-step failure.
#   2. Non-triggers: an external cause or status note, a latest event that is
#      not failed:, an open needs-decision:, a first Test-step failure, the hard
#      tier, a research scout, and a runtime that matches no tier.
#   3. One step per task: a recorded step, even one whose relaunch failed,
#      refuses another.
#   4. No second validation run: a concluded run on the branch refuses, a live
#      run keeps custody and the replacement is told to reattach to it.
#   5. Profiles: a single-profile tier is taken as is, a profile array needs the
#      caller's choice, and a choice outside the next tier is refused.
#   6. Posture: only an automatic strategy steps without --captain-approved,
#      and a second mate's routed --autonomy cannot contradict its home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

STEP="$ROOT/bin/fm-step-up.sh"
TMP_ROOT=$(fm_test_tmproot fm-step-up)
mkdir -p "$TMP_ROOT"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = axi ] || exit 1
rows=${FM_FAKE_NM_ROWS:-}
n=0
[ -z "$rows" ] || n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
printf 'repo: %s\ncount: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$PWD" "$n" "$n" "$n"
[ -z "$rows" ] || printf '%s\n' "$rows"
SH
cat > "$FAKEBIN/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/control.argv"
[ ! -e "$FM_HOME/control.fail" ] || { echo "relaunch refused: stub"; exit 1; }
echo "relaunched $1"
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/control"
export PATH="$FAKEBIN:$PATH"

DISPATCH='{
  "rules": [
    {"when": "requested Claude worker", "use": {"harness": "claude", "model": "claude-opus-5-5", "effort": "high"}, "strategy": "claude-requested"},
    {"when": "check", "strategy": "check", "use": [
      {"harness": "claude", "model": "claude-haiku-5-5", "effort": "medium"},
      {"harness": "codex", "model": "gpt-6-luna", "effort": "low"}]},
    {"when": "light", "strategy": "light", "use": {"harness": "claude", "model": "claude-sonnet-5-5", "effort": "medium"}},
    {"when": "standard", "strategy": "standard", "use": [
      {"harness": "claude", "model": "claude-opus-5-5", "effort": "medium"},
      {"harness": "codex", "model": "gpt-6.1-sol", "effort": "medium"}]},
    {"when": "hard", "strategy": "hard", "use": {"harness": "claude", "model": "claude-opus-5-5", "effort": "high"}},
    {"when": "research", "strategy": "research", "use": {"harness": "claude", "model": "claude-fable-5-1", "effort": "high"}}
  ],
  "default": {"harness": "claude", "model": "claude-opus-5-5", "effort": "medium"}
}'

# new_task <name> <kind> <mode> <harness> <model> <effort> [autonomy]: a scratch
# home holding one task; prints the home path.
new_task() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/wt"
  printf '%s\n' "$DISPATCH" > "$home/config/crew-dispatch.json"
  [ -z "${7:-}" ] || printf 'mode=%s\nproviders=claude,codex\nautonomy=%s\n' "$7" "$7" > "$home/config/strategy"
  fm_write_meta "$home/state/t1.meta" "kind=$2" "mode=$3" "harness=$4" "model=$5" "effort=$6" \
    "worktree=$home/wt" "branch=fm/t1" "project=$home"
  : > "$home/state/t1.status"
  printf '%s\n' "$home"
}

step() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME=$home FM_STEP_UP_CONTROL_BIN="$FAKEBIN/control" bash "$STEP" t1 "$@" 2>&1
}

say() { printf '%s\n' "$2" >> "$1/state/t1.status"; }

test_failed_trigger_steps_light_to_standard() {
  local home out
  home=$(new_task failed ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'working: implementing'
  say "$home" 'failed: could not explain why the parser test fails'
  out=$(step "$home" plan --trigger failed --cause 'cannot explain a failure')
  expect_code 0 "$?" 'failed trigger plans a step'
  assert_contains "$out" 'from: light (claude claude-sonnet-5-5 medium)' 'current tier from the recorded runtime'
  assert_contains "$out" 'to: standard' 'next rung'
  assert_contains "$out" 'candidate: --harness codex --model gpt-6.1-sol --effort medium' 'every next-tier candidate listed'
  assert_contains "$out" 'posture: automatic (autonomy full)' 'full steps automatically'

  out=$(step "$home" apply --trigger failed --cause 'cannot explain a failure')
  expect_code 1 "$?" 'a profile array needs the caller choice'
  assert_contains "$out" 'quota-array-dispatch' 'refusal names the array owner'
  out=$(step "$home" apply --trigger failed --cause 'cannot explain a failure' --harness claude --model claude-opus-5-5 --effort high)
  expect_code 1 "$?" 'a profile outside the next tier is refused'
  assert_absent "$home/control.argv" 'a refused pick never relaunches'
  assert_no_grep 'stepped up' "$home/state/t1.status" 'a refused pick records nothing'

  out=$(step "$home" apply --trigger failed --cause 'cannot explain a failure' --harness codex --model gpt-6.1-sol --effort medium)
  expect_code 0 "$?" "apply relaunches: $out"
  assert_contains "$out" 'stepped-up t1 light -> standard (codex gpt-6.1-sol medium)' 'apply reports the step'
  assert_equals $'t1\nrelaunch\n--harness\ncodex\n--model\ngpt-6.1-sol\n--effort\nmedium\n--note' "$(head -9 "$home/control.argv")" 'in-place relaunch on the chosen profile'
  assert_grep 'after a terminal failure: cannot explain a failure' "$home/control.argv" 'note names the cause'
  assert_grep '(tier: standard, stepped up from light)' "$home/control.argv" 'note asks the final status to name the tier'
  assert_grep 'Validate exactly once' "$home/control.argv" 'no-run note forbids a second validation run'
  assert_equals working "$(status_line_verb "$(last_status_line "$home/state/t1.status")")" 'step recorded as working'
  assert_grep 'stepped up from light to standard (codex gpt-6.1-sol medium) after a terminal failure' "$home/state/t1.status" 'step record names both tiers'

  out=$(step "$home" plan --trigger failed --cause 'cannot explain a failure')
  expect_code 1 "$?" 'a second step is refused'
  assert_contains "$out" 'already stepped up once' 'one step per task'
  pass 'a terminal failure steps light to standard once, on a chosen next-tier profile'
}

test_single_profile_tier_and_default_axes() {
  local home out
  home=$(new_task check ship direct-PR codex gpt-6-luna low full)
  say "$home" 'failed: looped on the same listing step'
  out=$(step "$home" apply --trigger failed --cause 'looping')
  expect_code 0 "$?" "check steps to light: $out"
  assert_equals $'--harness\nclaude\n--model\nclaude-sonnet-5-5\n--effort\nmedium' "$(sed -n '3,8p' "$home/control.argv")" 'single light profile taken as is'
  pass 'a single-profile tier needs no caller choice'
}

test_blocked_trigger_closes_the_blocker() {
  local home out
  home=$(new_task blocked ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'blocked [key=parser]: asked again which file to edit, which the brief names'
  out=$(step "$home" plan --trigger failed --cause 'misread instructions')
  expect_code 1 "$?" 'blocked is not failed'
  out=$(step "$home" apply --trigger blocked --cause 'misread instructions' --harness claude --model claude-opus-5-5 --effort medium)
  expect_code 0 "$?" "blocked trigger steps: $out"
  assert_grep 'after a blocker recovery could not clear: misread instructions' "$home/control.argv" 'note names the blocker cause'
  assert_equals '' "$(status_open_decisions "$home/state/t1.status")" 'the step record closes the blocker'
  assert_grep 'resolved [key=parser]' "$home/state/t1.status" 'closed with the blocker key'

  home=$(new_task blocked-decision ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'blocked [key=parser]: looping'
  say "$home" 'needs-decision [key=scope]: which API'
  out=$(step "$home" plan --trigger blocked --cause looping)
  expect_code 1 "$?" 'an open decision blocks the step'
  assert_contains "$out" "decision 'scope' is open" 'refusal names the decision'
  pass 'a capability blocker steps up and is closed by the step record'
}

test_second_test_failure_triggers() {
  local home out
  home=$(new_task tests ship direct-PR claude claude-sonnet-5-5 medium full)
  out=$(step "$home" test-failure --cause 'parser test still red')
  expect_code 0 "$?" 'first failure recorded'
  assert_contains "$out" 'recorded test-step failure 1' 'count starts at one'
  out=$(step "$home" plan --trigger test-failure --cause 'parser test still red')
  expect_code 1 "$?" 'first Test-step failure does not step'
  assert_contains "$out" 'only 1 Test-step failure' 'reason names the count'
  step "$home" test-failure --cause 'parser test still red after the fix' >/dev/null
  out=$(step "$home" apply --trigger test-failure --cause 'parser test still red' --harness claude --model claude-opus-5-5 --effort medium)
  expect_code 0 "$?" "second Test-step failure steps: $out"
  assert_grep 'after a second Test-step failure' "$home/control.argv" 'note names the trigger'

  home=$(new_task tests-terminal ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: Test step still red'
  out=$(step "$home" test-failure --cause 'parser test still red')
  expect_code 1 "$?" 'a Test-step failure is not recorded over a terminal failed:'
  assert_equals failed "$(status_line_verb "$(last_status_line "$home/state/t1.status")")" 'the terminal failed: stays the latest event'
  out=$(step "$home" plan --trigger failed --cause 'parser test still red')
  expect_code 0 "$?" "the failed trigger still applies: $out"
  pass 'the second Test-step failure for a task triggers the step'
}

test_non_triggers() {
  local home out
  home=$(new_task external ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: implementation done'
  for cause in 'CI runner outage' 'disk full' 'no-mistakes daemon gone' 'quota exhausted' 'Azure login expired' 'vendor API overloaded'; do
    out=$(step "$home" plan --trigger failed --cause "$cause")
    expect_code 1 "$?" "external cause '$cause' does not step"
    assert_contains "$out" 'external system' "reason for '$cause'"
  done
  say "$home" 'failed: GitHub CI red on an unrelated job'
  out=$(step "$home" plan --trigger failed --cause 'could not finish')
  expect_code 1 "$?" 'an external failed: note does not step'

  home=$(new_task not-failed ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: gave up'
  say "$home" 'working: retrying'
  out=$(step "$home" plan --trigger failed --cause 'gave up')
  expect_code 1 "$?" 'only the latest event counts'

  home=$(new_task hard ship direct-PR claude claude-opus-5-5 high full)
  say "$home" 'failed: could not explain the crash'
  out=$(step "$home" plan --trigger failed --cause 'cannot explain a failure')
  expect_code 1 "$?" 'hard is never stepped'
  assert_contains "$out" 'captain with the evidence' 'hard goes to the captain'

  home=$(new_task research scout direct-PR claude claude-fable-5-1 high full)
  say "$home" 'failed: could not reach a conclusion'
  out=$(step "$home" plan --trigger failed --cause 'cannot explain')
  expect_code 1 "$?" 'research is never stepped'
  assert_contains "$out" 'research scout is never stepped' 'reason names research'

  home=$(new_task research-shared ship direct-PR claude claude-opus-5-5 medium full)
  jq '(.rules[] | select(.strategy == "research") | .use) = {"harness": "claude", "model": "claude-opus-5-5", "effort": "medium"}' \
    "$home/config/crew-dispatch.json" > "$home/config/d.json" && mv "$home/config/d.json" "$home/config/crew-dispatch.json"
  say "$home" 'failed: could not explain the parser crash'
  out=$(step "$home" plan --trigger failed --cause 'cannot explain a failure')
  expect_code 0 "$?" "a ship on the research profile still steps: $out"
  assert_contains "$out" 'from: standard' 'a ship is classified on the ladder, not as research'
  out=$(step "$home" plan --trigger failed --cause 'cannot explain a failure' --from-tier research)
  expect_code 2 "$?" 'research is not a tier for a ship'

  home=$(new_task unmatched ship direct-PR claude claude-sonnet-5-5 low full)
  say "$home" 'failed: gave up'
  out=$(step "$home" plan --trigger failed --cause 'gave up')
  expect_code 1 "$?" 'an unknown tier is not guessed'
  out=$(step "$home" plan --trigger failed --cause 'gave up' --from-tier light)
  expect_code 1 "$?" 'a --from-tier that does not hold the runtime is refused'
  pass 'external failures, hard, research, and unproven triggers never step'
}

test_relaunch_failure_uses_the_step() {
  local home out
  home=$(new_task relaunch-fail ship direct-PR claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: looping on lint'
  : > "$home/control.fail"
  out=$(step "$home" apply --trigger failed --cause looping --harness claude --model claude-opus-5-5 --effort medium)
  expect_code 3 "$?" 'a failed relaunch exits 3'
  assert_grep 'blocked [key=step-up]' "$home/state/t1.status" 'the failure is a blocker for firstmate'
  rm -f "$home/control.fail"
  out=$(step "$home" plan --trigger blocked --cause looping)
  expect_code 1 "$?" 'the used step is not retried'
  assert_contains "$out" 'already stepped up once' 'cap holds after a failed relaunch'
  pass 'a failed relaunch still uses the one step and surfaces a blocker'
}

test_validation_custody() {
  local home out
  home=$(new_task concluded ship no-mistakes claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: could not explain the review finding'
  out=$(FM_FAKE_NM_ROWS='  "01RUN",fm/t1,failed,0123abcd,""' step "$home" plan --trigger failed --cause 'cannot explain a failure')
  expect_code 1 "$?" 'a concluded run is never followed by a step'
  assert_contains "$out" 'second validation run' 'reason names the rule'

  out=$(FM_FAKE_NM_ROWS='  "01RUN",fm/t1,running,0123abcd,""
  "01OLD",fm/other,completed,89abcdef,""' FM_STEP_UP_CONTROL_BIN="$FAKEBIN/control" FM_HOME=$home \
    bash "$STEP" t1 apply --trigger failed --cause 'cannot explain a failure' --harness claude --model claude-opus-5-5 --effort medium 2>&1)
  expect_code 0 "$?" "a live run keeps custody: $out"
  assert_grep 'axi run` (no flags) and keep driving it' "$home/control.argv" 'replacement reattaches'
  assert_grep 'never start a second validation run' "$home/control.argv" 'replacement never starts a second run'

  home=$(new_task unreadable ship no-mistakes claude claude-sonnet-5-5 medium full)
  say "$home" 'failed: gave up'
  out=$(FM_FAKE_NM_ROWS='  "01RUN",fm/t1,mystery,0123abcd,""' step "$home" plan --trigger failed --cause 'gave up')
  expect_code 1 "$?" 'an unreadable validation state is not guessed'
  pass 'a step never needs a second validation run'
}

test_posture() {
  local home out
  home=$(new_task balanced ship direct-PR claude claude-sonnet-5-5 medium balanced)
  say "$home" 'failed: gave up'
  out=$(step "$home" plan --trigger failed --cause 'gave up')
  assert_contains "$out" 'posture: ask (autonomy balanced)' 'balanced asks'
  out=$(step "$home" apply --trigger failed --cause 'gave up' --harness claude --model claude-opus-5-5 --effort medium)
  expect_code 1 "$?" 'balanced needs the captain'
  assert_absent "$home/control.argv" 'no relaunch without approval'
  out=$(step "$home" apply --trigger failed --cause 'gave up' --harness claude --model claude-opus-5-5 --effort medium --captain-approved)
  expect_code 0 "$?" "an approved step applies: $out"

  home=$(new_task mate ship direct-PR claude claude-sonnet-5-5 medium)
  say "$home" 'failed: gave up'
  out=$(step "$home" plan --trigger failed --cause 'gave up')
  assert_contains "$out" 'posture: ask' 'no selection asks'
  out=$(step "$home" plan --trigger failed --cause 'gave up' --autonomy full)
  assert_contains "$out" 'posture: automatic (autonomy full)' 'a routed level applies in a second mate home'
  home=$(new_task contradict ship direct-PR claude claude-sonnet-5-5 medium lean)
  say "$home" 'failed: gave up'
  out=$(step "$home" plan --trigger failed --cause 'gave up' --autonomy full)
  expect_code 2 "$?" 'a routed level cannot contradict the home'
  pass 'only an automatic strategy steps without the captain'
}

test_failed_trigger_steps_light_to_standard
test_single_profile_tier_and_default_axes
test_blocked_trigger_closes_the_blocker
test_second_test_failure_triggers
test_non_triggers
test_relaunch_failure_uses_the_step
test_validation_custody
test_posture
echo "# all fm-step-up tests passed"
