#!/usr/bin/env bash
# bin/fm-fresh-start.sh: when an automatic fresh start is due, and when it is
# refused.
#
# Every case drives the real command against a scratch primary home, a scratch
# second-mate home, and Claude session records written in the harness's own
# JSONL shape under a scratch CLAUDE_CONFIG_DIR. The clock is pinned with
# FM_FRESH_START_NOW and TZ=UTC, and the persist-gated restart is replaced by a
# stub through FM_FRESH_START_RESTART_BIN, so the tests pin the decisions and the
# reporting, never a real relaunch (tests/fm-secondmate-restart.test.sh owns
# that pass).
#
#   1. No config file means off: silent check, no records.
#   2. Idle: due once the last turn ended idle_minutes ago; the offer is not
#      repeated within the hour.
#   3. Context: due at the threshold of the model's window; an unknown model or a
#      reading larger than the window is unmeasured, and config context_windows
#      supplies a window.
#   4. Nightly: due inside the night span when no fresh start happened since
#      nightly_at, including at the next idle moment after a busy nightly_at.
#   5. Cooldown: at most one fresh start per window.
#   6. Refusal while busy: mid-turn and a request awaiting its reply always
#      refuse; a live worker (not a child second mate), open decision, unread
#      steering, or undrained notifications refuse idle and nightly but not the
#      context trigger.
#   7. run re-decides, calls the restart with --fresh-start, and appends one note
#      to the mate's status channel; a busy mate is never passed to the restart.
#   8. The primary gets one deduplicated suggestion instead of a restart, on the
#      context trigger even while it holds a live worker.
#   9. Invalid config is reported once; arm --if-configured follows the file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FRESH="$ROOT/bin/fm-fresh-start.sh"
export TZ=UTC
TMP_ROOT=$(fm_test_tmproot fm-fresh-start)

epoch_of() {  # <iso8601 UTC>
  jq -n --arg t "$1" '$t | fromdateiso8601'
}

NOON=$(epoch_of 2026-09-25T12:00:00Z)

# A fresh case: primary home H, mate home M registered as second mate "mate",
# and an empty Claude config root C. Echoes the case directory.
new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/state" "$d/home/config" "$d/mate/state" "$d/claude/projects"
  printf '%s\n' \
    "window=fake:1" \
    "harness=claude" \
    "kind=secondmate" \
    "home=$d/mate" \
    "worktree=$d/mate" > "$d/home/state/mate.meta"
  printf '%s\n' "$d"
}

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# Write a Claude session record for the home rooted at <cwd> and bind it to
# <state-dir> through .lock-session, the same way bin/fm-lock.sh records it.
# <turns> completed turns, the last ending at <settled-epoch>; <tokens> is the
# latest turn's input usage on <model>. <tail> "open" appends a new user turn
# that has not ended.
write_session() {  # <case> <state-dir> <cwd> <turns> <settled-epoch> <tokens> <model> [open]
  local d=$1 sd=$2 cwd=$3 turns=$4 settled=$5 tokens=$6 model=$7 tail=${8:-} sid dir file i ts
  sid="sess-$(printf '%s' "$sd" | cksum | awk '{print $1}')"
  dir="$d/claude/projects/$(slug "$cwd")"
  mkdir -p "$dir"
  file="$dir/$sid.jsonl"
  : > "$file"
  i=1
  while [ "$i" -le "$turns" ]; do
    ts=$(jq -n --argjson e "$((settled - (turns - i) * 60))" '$e | todateiso8601 | sub("Z$"; ".123Z")')
    {
      jq -nc '{type:"user", isSidechain:false, message:{role:"user", content:"do the thing"}}'
      jq -nc --argjson t "$((tokens - 10))" --arg m "$model" \
        '{type:"assistant", isSidechain:false, message:{model:$m, stop_reason:"end_turn",
          usage:{input_tokens:2, cache_creation_input_tokens:8, cache_read_input_tokens:$t}}}'
      # A subagent's own turn inside the main turn must not count as the main thread.
      jq -nc '{type:"assistant", isSidechain:true, message:{model:"claude-haiku-4-5", usage:{input_tokens:999999}}}'
      jq -nc --argjson ts "$ts" '{type:"system", subtype:"stop_hook_summary", isSidechain:false, timestamp:$ts}'
      jq -nc --argjson ts "$ts" '{type:"system", subtype:"turn_duration", isSidechain:false, timestamp:$ts}'
    } >> "$file"
    i=$((i + 1))
  done
  if [ "$tail" = open ]; then
    jq -nc '{type:"user", isSidechain:false, message:{role:"user", content:"next"}}' >> "$file"
  fi
  printf '%s\n' "$sid" > "$sd/.lock-session"
}

mate_session() {  # <case> <turns> <settled-epoch> <tokens> <model> [open]
  write_session "$1" "$1/mate/state" "$1/mate" "$2" "$3" "$4" "$5" "${6:-}"
}

config() {  # <case> <json>
  printf '%s\n' "$2" > "$1/home/config/fresh-start.json"
}

fresh() {  # <case> <now-epoch> <args>...
  local d=$1 now=$2
  shift 2
  FM_HOME="$d/home" CLAUDE_CONFIG_DIR="$d/claude" FM_FRESH_START_NOW="$now" \
    FM_FRESH_START_RESTART_BIN="$d/restart-stub" "$FRESH" "$@"
}

mate_line() {  # <case> <now> -> the mate's status line
  fresh "$1" "$2" status mate
}

stub_restart() {  # <case> <line printed for the mate>
  cat > "$1/restart-stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/restart-calls"
printf '%s\n' "$2"
SH
  chmod +x "$1/restart-stub"
}

# --- 1. off without a config file ---------------------------------------------------
test_absent_config_is_off() {
  local d out
  d=$(new_case absent)
  mate_session "$d" 5 $((NOON - 86400)) 900000 claude-opus-5
  out=$(fresh "$d" "$NOON" check) || fail "check without a config must succeed"
  assert_equals "" "$out" "no config file must keep the check silent"
  assert_absent "$d/home/state/fresh-start" "no config file must write no records"
  out=$(fresh "$d" "$NOON" status)
  assert_contains "$out" "off" "status must say the feature is off"
  pass "absent config: automatic fresh starts are off"
}

# --- 2. idle trigger ----------------------------------------------------------------
test_idle_trigger_and_offer_dedupe() {
  local d out
  d=$(new_case idle)
  config "$d" '{"idle_minutes": 120, "nightly_at": null}'
  mate_session "$d" 3 $((NOON - 30 * 60)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: wait -: idle 30m of 2h 0m" \
    "a mate idle for less than the period must wait"
  mate_session "$d" 3 $((NOON - 3 * 3600)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due idle: idle 3h 0m; context 10%" \
    "a mate idle past the period must be due"
  out=$(fresh "$d" "$NOON" check)
  assert_contains "$out" "fresh start due for second mate mate (idle 3h 0m; context 10%)" "check must name the due mate"
  assert_contains "$out" "fm-fresh-start.sh run mate in the background" "check must carry the run command"
  assert_contains "$out" "FM_HOME=$d/home" "the run command must name this home"
  out=$(fresh "$d" $((NOON + 600)) check)
  assert_equals "" "$out" "a mate offered within the hour must not be offered again"
  out=$(fresh "$d" $((NOON + 3700)) check)
  assert_contains "$out" "run mate" "a mate still due an hour later is offered again"
  mate_session "$d" 1 $((NOON - 3 * 3600)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: wait -: no work since its session started" \
    "a mate with a single turn since it started must not be restarted for being idle"
  pass "idle trigger fires after the idle period and the offer is deduplicated"
}

# --- 3. context trigger ---------------------------------------------------------------
test_context_trigger() {
  local d
  d=$(new_case context)
  config "$d" '{"context_percent": 70, "idle_minutes": null, "nightly_at": null}'
  mate_session "$d" 1 $((NOON - 60)) 690000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: wait -: no work since its session started; context 69%" \
    "context below the threshold must wait"
  mate_session "$d" 1 $((NOON - 60)) 700000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due context: context 70% is at or over 70%" \
    "context at the threshold must be due regardless of idle time or turn count"
  mate_session "$d" 1 $((NOON - 60)) 150000 claude-haiku-4-5-20251001
  assert_contains "$(mate_line "$d" "$NOON")" "due context: context 75%" \
    "a dated model id must use its base model's window"
  mate_session "$d" 1 $((NOON - 60)) 900000 claude-future-9
  assert_contains "$(mate_line "$d" "$NOON")" "context unmeasured: no known window for claude-future-9" \
    "an unknown model's window must never be guessed"
  mate_session "$d" 1 $((NOON - 60)) 300000 claude-haiku-4-5
  assert_contains "$(mate_line "$d" "$NOON")" "context unmeasured: 300000 tokens exceeds the 200000 window" \
    "a reading larger than the window on record must be unmeasured, not over 100%"
  config "$d" '{"context_percent": 70, "idle_minutes": null, "nightly_at": null, "context_windows": {"claude-future-9": 1000000}}'
  mate_session "$d" 1 $((NOON - 60)) 900000 claude-future-9
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due context: context 90%" \
    "config context_windows must supply a window"
  pass "context trigger measures the latest main-thread turn against the model window"
}

# --- 4. nightly trigger -------------------------------------------------------------
test_nightly_window() {
  local d three
  d=$(new_case nightly)
  config "$d" '{"nightly_at": "03:00", "idle_minutes": null, "cooldown_hours": 1}'
  three=$(epoch_of 2026-09-25T03:00:00Z)
  mate_session "$d" 3 $((three + 3600 - 120)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" $((three + 3600)))" "mate: due nightly: nightly at 03:00" \
    "an idle mate inside the night span must be due"
  mate_session "$d" 3 $((three - 120)) 100000 claude-opus-5 open
  assert_contains "$(mate_line "$d" "$three")" "mate: busy -: mid-turn" \
    "a mate mid-turn at nightly_at must not be restarted"
  mate_session "$d" 4 $((three + 2 * 3600)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" $((three + 2 * 3600 + 60)))" "mate: due nightly" \
    "the nightly fresh start must happen at the next idle moment that night"
  assert_contains "$(mate_line "$d" $((three + 7 * 3600)))" "mate: wait -" \
    "outside the night span nightly must not fire"
  mkdir -p "$d/home/state/fresh-start"
  printf '%s\n' "$((three + 600)) idle restarted" > "$d/home/state/fresh-start/mate.attempt"
  assert_contains "$(mate_line "$d" $((three + 3 * 3600)))" "mate: wait -" \
    "a fresh start since this night's nightly_at must satisfy nightly"
  pass "nightly trigger fires once per night at the first idle moment"
}

# --- 5. cooldown --------------------------------------------------------------------------
test_cooldown() {
  local d
  d=$(new_case cooldown)
  config "$d" '{"idle_minutes": 60, "nightly_at": null, "cooldown_hours": 6}'
  mate_session "$d" 3 $((NOON - 5 * 3600)) 900000 claude-opus-5
  mkdir -p "$d/home/state/fresh-start"
  printf '%s\n' "$((NOON - 2 * 3600)) context restarted" > "$d/home/state/fresh-start/mate.attempt"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: wait -: cooldown: last fresh start 2h 0m ago, 4h 0m left" \
    "a fresh start inside the cooldown must wait even when a trigger holds"
  assert_contains "$(mate_line "$d" $((NOON + 4 * 3600)))" "mate: due context" \
    "after the cooldown the trigger must fire again"
  pass "cooldown allows at most one fresh start per window"
}

# --- 6. refusal while busy ----------------------------------------------------------------
test_refusal_while_busy() {
  local d
  d=$(new_case busy)
  config "$d" '{"idle_minutes": 5, "nightly_at": null}'
  mate_session "$d" 3 $((NOON - 3600)) 950000 claude-opus-5 open
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: mid-turn" "a mate mid-turn must never be restarted, even over the context threshold"

  mate_session "$d" 3 $((NOON - 3600)) 950000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due context" "the settled mate is due"
  printf 'kind=ship\n' > "$d/mate/state/child.meta"
  printf 'needs-decision [key=pick]: which one\n' > "$d/home/state/mate.status"
  mkdir -p "$d/home/state/mate.inbox"
  printf 'do this\n' > "$d/home/state/mate.inbox/001.msg"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due context" \
    "in-flight work must not refuse the context trigger; the persist gate files it"
  rm -rf "$d/mate/state/child.meta" "$d/home/state/mate.status" "$d/home/state/mate.inbox"

  mkdir -p "$d/home/state/pending-replies"
  printf 'task_id=mate\nresolved_epoch=\n' > "$d/home/state/pending-replies/0123456789abcdef"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: a request still awaiting its reply" \
    "a request awaiting its reply must refuse even the context trigger"
  rm -rf "$d/home/state/pending-replies"

  mate_session "$d" 3 $((NOON - 3600)) 100000 claude-opus-5
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due idle" "the settled mate under the threshold is due for idle"

  printf 'kind=secondmate\n' > "$d/mate/state/grandchild.meta"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due idle" "a child second mate is not a live worker"
  printf 'kind=ship\n' > "$d/mate/state/child.meta"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: 1 live worker(s)" "a mate with a live worker must be refused"
  rm -f "$d/mate/state/child.meta" "$d/mate/state/grandchild.meta"

  printf 'needs-decision [key=pick]: which one\n' > "$d/home/state/mate.status"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: an open decision" "an open decision on its parent channel must refuse"
  printf 'resolved [key=pick]: this one\n' >> "$d/home/state/mate.status"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: due" "a resolved decision no longer refuses"

  printf 'blocked [key=creds]: needs a token\n' > "$d/mate/state/child.status"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: an open decision" "an open decision in its own home must refuse"
  rm -f "$d/mate/state/child.status"

  mkdir -p "$d/home/state/mate.inbox"
  printf 'do this\n' > "$d/home/state/mate.inbox/001.msg"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: an unacknowledged instruction" "unread steering must refuse"
  rm -rf "$d/home/state/mate.inbox"

  mkdir -p "$d/home/state/pending-replies"
  printf 'task_id=mate\nresolved_epoch=\n' > "$d/home/state/pending-replies/0123456789abcdef"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: a request still awaiting its reply" "an unanswered request must refuse"
  printf 'task_id=mate\nresolved_epoch=%s\n' "$NOON" > "$d/home/state/pending-replies/0123456789abcdef"

  printf '1\t1\tcheck\tx\ty\n' > "$d/mate/state/.wake-queue"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: busy -: undrained notifications" "undrained notifications must refuse"
  : > "$d/mate/state/.wake-queue"

  assert_contains "$(mate_line "$d" "$NOON")" "mate: due idle" "with nothing in flight the mate is due again"
  pass "mid-turn refuses every trigger; in-flight work refuses idle and nightly but not context"
}

test_unavailable_runtimes() {
  local d
  d=$(new_case unavailable)
  config "$d" '{}'
  mate_session "$d" 3 $((NOON - 86400)) 950000 claude-opus-5
  sed -i.bak 's/^harness=claude$/harness=codex/' "$d/home/state/mate.meta"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: unavailable -: no verified session reader for its runtime (codex)" \
    "a runtime without a verified session reader must be unavailable"
  sed -i.bak 's/^harness=codex$/harness=claude/' "$d/home/state/mate.meta"
  printf 'remote_host=box\n' >> "$d/home/state/mate.meta"
  assert_contains "$(mate_line "$d" "$NOON")" "mate: unavailable -: remote second mate" \
    "a remote mate must be unavailable"
  pass "runtimes and placements without a verified reader are never fresh-started"
}

# --- 7. run -----------------------------------------------------------------------------------
test_run_restarts_and_reports() {
  local d out
  d=$(new_case run)
  config "$d" '{"idle_minutes": 60, "nightly_at": null}'
  mate_session "$d" 3 $((NOON - 2 * 3600)) 300000 claude-opus-5
  stub_restart "$d" "restarted: mate (claude)"

  out=$(env -u FM_HOME CLAUDE_CONFIG_DIR="$d/claude" FM_FRESH_START_NOW="$NOON" "$FRESH" run mate 2>&1) \
    && fail "run without an explicit FM_HOME must refuse"
  assert_contains "$out" "FM_HOME is not set" "run must name the missing home"

  out=$(fresh "$d" "$NOON" run mate) || fail "run must succeed: $out"
  assert_equals "--fresh-start mate" "$(cat "$d/restart-calls")" "run must use the persist-gated restart in fresh-start mode"
  assert_grep "]: automatic fresh start (idle 2h 0m; context 30%): restarted" "$d/home/state/mate.status" \
    "run must report the fresh start on the mate's status channel"
  assert_equals "$NOON idle restarted" "$(cat "$d/home/state/fresh-start/mate.attempt")" "run must record the attempt"

  out=$(fresh "$d" $((NOON + 60)) run mate)
  assert_contains "$out" "not started: mate: wait cooldown" "a second run inside the cooldown must not restart again"
  assert_equals "1" "$(wc -l < "$d/restart-calls" | tr -d ' ')" "the restart must have run exactly once"

  d=$(new_case run-busy)
  config "$d" '{"idle_minutes": 60, "nightly_at": null}'
  mate_session "$d" 3 $((NOON - 2 * 3600)) 300000 claude-opus-5 open
  stub_restart "$d" "restarted: mate (claude)"
  out=$(fresh "$d" "$NOON" run mate)
  assert_contains "$out" "not started: mate: busy mid-turn" "run must re-decide and leave a busy mate alone"
  assert_absent "$d/restart-calls" "a busy mate must never reach the restart"
  assert_absent "$d/home/state/mate.status" "a mate left alone gets no status note"

  d=$(new_case run-skip)
  config "$d" '{"idle_minutes": 60, "nightly_at": null}'
  mate_session "$d" 3 $((NOON - 2 * 3600)) 300000 claude-opus-5
  stub_restart "$d" "skipped: mate: it did not confirm within 900s that its open work is written down"
  fresh "$d" "$NOON" run mate >/dev/null || fail "a skipped restart is a reported outcome, not a run failure"
  assert_grep "automatic fresh start (idle 2h 0m; context 30%): not done: it did not confirm within 900s" \
    "$d/home/state/mate.status" "a restart that did not happen must be reported as not done"
  assert_equals "$NOON idle skipped" "$(cat "$d/home/state/fresh-start/mate.attempt")" \
    "an attempt that did not restart still starts the cooldown"
  pass "run re-decides, restarts through the persist gate, and reports on the status channel"
}

# --- 8. primary suggestion ----------------------------------------------------------------------
test_primary_suggestion() {
  local d out
  d=$(new_case primary)
  rm -f "$d/home/state/mate.meta"
  config "$d" '{"context_percent": 80, "idle_minutes": null, "nightly_at": null}'
  write_session "$d" "$d/home/state" "$d/home" 4 $((NOON - 60)) 820000 claude-opus-5-5
  out=$(fresh "$d" "$NOON" check)
  assert_equals "fresh-start suggestion (context): my context is at 82%; say /stow then /clear when convenient" "$out" \
    "the primary must get one short suggestion instead of a restart"
  out=$(fresh "$d" $((NOON + 600)) check)
  assert_equals "" "$out" "the suggestion must not repeat every poll"
  out=$(fresh "$d" $((NOON + 7 * 3600)) check)
  assert_contains "$out" "fresh-start suggestion" "the suggestion may return once the cooldown passes"
  printf 'kind=ship\n' > "$d/home/state/work.meta"
  out=$(fresh "$d" $((NOON + 14 * 3600)) check)
  assert_contains "$out" "fresh-start suggestion (context)" "a live worker must not hold back the context suggestion"
  config "$d" '{"context_percent": null, "idle_minutes": 5, "nightly_at": null}'
  out=$(fresh "$d" $((NOON + 21 * 3600)) check)
  assert_equals "" "$out" "a primary with a live worker gets no idle suggestion"
  rm -f "$d/home/state/work.meta"
  out=$(fresh "$d" $((NOON + 21 * 3600)) check)
  assert_contains "$out" "fresh-start suggestion (idle)" "with nothing in flight the idle suggestion fires"
  pass "the primary is suggested a fresh start once per cooldown and never restarted"
}

# --- 9. config and arming ------------------------------------------------------------------------
test_invalid_config_and_arming() {
  local d out
  d=$(new_case config)
  config "$d" '{"context_percent": 150}'
  out=$(fresh "$d" "$NOON" check)
  assert_contains "$out" "config/fresh-start.json is invalid (context_percent must be a whole number from 10 to 99" \
    "an invalid config must be reported"
  out=$(fresh "$d" "$NOON" check)
  assert_equals "" "$out" "the same invalid config must be reported only once"
  config "$d" '{"enabled": false}'
  out=$(fresh "$d" "$NOON" check)
  assert_equals "" "$out" "enabled false must keep the check silent"

  fresh "$d" "$NOON" arm --if-configured >/dev/null || fail "arm --if-configured must succeed with a config"
  assert_present "$d/home/state/fresh-start.check.sh" "arm must write the check shim"
  assert_present "$d/home/state/fresh-start.check-trust" "arm must register the check shim"
  config "$d" '{"idle_minutes": 1}'
  out=$(env -u FM_HOME FM_FRESH_START_NOW="$NOON" bash "$d/home/state/fresh-start.check.sh") \
    || fail "the armed shim must run"
  assert_contains "$out" "config/fresh-start.json is invalid (idle_minutes" \
    "the armed shim must run the check against this home"
  rm -f "$d/home/config/fresh-start.json"
  fresh "$d" "$NOON" arm --if-configured >/dev/null || fail "arm --if-configured must succeed without a config"
  assert_absent "$d/home/state/fresh-start.check.sh" "removing the config must disarm on the next session start"
  assert_absent "$d/home/state/fresh-start.check-trust" "disarm must drop the trust binding"
  pass "invalid config is reported once and arming follows the config file"
}

test_absent_config_is_off
test_idle_trigger_and_offer_dedupe
test_context_trigger
test_nightly_window
test_cooldown
test_refusal_while_busy
test_unavailable_runtimes
test_run_restarts_and_reports
test_primary_suggestion
test_invalid_config_and_arming
echo "# all fm-fresh-start tests passed"
