#!/usr/bin/env bash
# bin/fm-secondmate-restart.sh: persist-then-restart, and the honest fallback.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control
# transaction) against a lifecycle-modelling session-provider stub:
#
#   1. The persist request is a GATE. Nothing is stopped until that mate's own
#      correlated answer lands on the parent channel, and a mate that never
#      answers keeps its agent and gets the re-read message instead.
#   2. The order is persist THEN restart, observable in what reaches the pane.
#   3. The persist request is the task-subset of /stow: it asks for open records,
#      task status, and a rewritten where-I-left-off note, and explicitly not for
#      the memory, learnings, or captain-preference sweeps.
#   4. Every unsafe case says what is known: pre-restart capability and persist
#      failures use the nudge path, while a failed relaunch is reported as an
#      unknown outcome; none is reported as a clean reload.
#   5. A remote mate restarts by running the SAME local control-plane relaunch on
#      its host, over the fm-on transport, with the profile resolved from the
#      PARENT's own pin rather than the remote home's copy of it.
#   6. End to end with bin/fm-update.sh: a live mate whose home needed no
#      fast-forward is still named for restart and genuinely restarted, and one
#      whose runtime cannot prove a restart keeps the honest re-read path with
#      its agent left running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESTART="$ROOT/bin/fm-secondmate-restart.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          printf 'zsh' > "$D/command.$target"
          if [ -x "$D/on-exit" ]; then
            "$D/on-exit" "$target"
          fi
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          # A pending launch failure leaves the pane on its bare shell, as a
          # replacement that never came up does.
          failures=$(cat "$D/launch-failures.$target" 2>/dev/null || printf '0')
          if [ "$failures" -gt 0 ]; then
            printf '%s' "$((failures - 1))" > "$D/launch-failures.$target"
          else
            cat "$D/becomes" > "$D/command.$target"
          fi
          ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -f "$D/cwd.$target" ]; then cat "$D/cwd.$target"; else cat "$D/cwd"; fi
          printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  kill-window)
    # A closed window leaves the session inventory, as the guarded respawn
    # expects before it creates the replacement.
    target=
    prev=
    for a in "$@"; do
      [ "$prev" != -t ] || target=$a
      prev=$a
    done
    name=${target##*:}
    name=${name#=}
    if [ -n "$name" ] && [ -f "$D/windows" ]; then
      grep -vFx "$name" "$D/windows" > "$D/windows.tmp" || true
      mv "$D/windows.tmp" "$D/windows"
    fi
    exit 0 ;;
  new-window)
    name=
    prev=
    for a in "$@"; do
      [ "$prev" != -n ] || name=$a
      prev=$a
    done
    [ -z "$name" ] || printf '%s\n' "$name" >> "$D/windows"
    printf '@%s\n' "$name"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # Every case runs on the stubbed tmux backend only. A real herdr call would
  # reach whatever live session the test happens to run beside, so the client is
  # shadowed by one that records the call and refuses it; run_restart asserts
  # it was never reached.
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/herdr-calls"
exit 1
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
  printf '%s' "$smhome" > "$dir/fake/cwd.fmses:fm-$id"
}

# add_repo_backed_mate <case-dir> <id> [harness] [backend-line]
# Like add_local_mate, but the world is the one /updatefirstmate actually runs
# against: a bare origin, a firstmate repo clone on its default branch, and the
# mate's home as a DETACHED worktree of that repo already sitting on origin's tip.
# That "already current" home is the shape the old classifier skipped entirely.
add_repo_backed_mate() {  # <case-dir> <id> [harness] [backend]
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" repo="$dir/fmrepo" smhome="$dir/$id-home"
  if [ ! -d "$repo" ]; then
    git init -q --bare "$dir/origin.git"
    git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
    mkdir -p "$dir/seed/bin" "$dir/seed/.agents/skills"
    printf '# agents\n' > "$dir/seed/AGENTS.md"
    printf 'echo a\n' > "$dir/seed/bin/tool.sh"
    printf 's1\n' > "$dir/seed/.agents/skills/note.md"
    # The operational dirs a live home carries are gitignored in a real firstmate
    # checkout; without that the home would read as dirty and be skipped.
    printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
      > "$dir/seed/.gitignore"
    git -C "$dir/seed" add -A
    git -C "$dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
    git -C "$dir/seed" push -q origin main
    git clone -q "$dir/origin.git" "$repo"
    git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
    touch "$home/state/.last-watcher-beat"
  fi
  git -C "$repo" worktree add -q --detach "$smhome" main
  mkdir -p "$smhome/state" "$smhome/data" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# run_update_in_case <case-dir>: the real /updatefirstmate mechanics over that world.
run_update_in_case() {
  local dir=$1
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u TMUX -u TMUX_PANE \
    PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/fmrepo" FM_HOME="$dir/home" FM_BACKEND=tmux \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  printf '%s' "$dir/home/state/$id.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/$id.status" > "$dir/fake/answer-status"
}

# The pass runs hermetically: inherited terminal-multiplexer identity is
# dropped and the backend is pinned to the stubbed tmux, so no path - including
# the guarded secondmate respawn a retry takes - can auto-detect a real session.
run_restart() {  # <case-dir> <args...>
  local dir=$1 rc=0; shift
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u TMUX -u TMUX_PANE \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    CLAUDE_CONFIG_DIR="$dir/claude-config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SECONDMATE_LIVENESS_TIMEOUT=30 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$RESTART" "$@" 2>&1 || rc=$?
  [ ! -s "$dir/fake/herdr-calls" ] \
    || fail "the restart pass reached a real herdr client: $(cat "$dir/fake/herdr-calls")"
  return "$rc"
}

# --- T1: the persist request is the task subset of /stow, and it gates --------
test_persist_gates_and_asks_only_for_open_records() {
  local dir out rc request
  dir=$(new_case gate)
  add_local_mate "$dir" sm1
  # No answer armed: the mate never confirms its open work is written down.
  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" fm-sm1); rc=$?

  expect_code 3 "$rc" "an unconfirmed persist is a fallback, not a success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unconfirmed persist must fall back to the re-read message"
  assert_contains "$out" "its open work is written down" "the fallback must name the missing confirmation"
  assert_not_contains "$out" "restarted: sm1" "a mate that never confirmed must not be restarted"
  assert_contains "$out" "summary: 0 of 1 restarted" "the summary must not claim a reload"
  # The agent is untouched: nothing exited, nothing relaunched.
  assert_no_grep '^/exit$' "$dir/fake/literal" "the agent was stopped without a confirmed persist"
  assert_absent "$dir/home/state/sm1.control-relaunch" \
    "a restart transaction was opened without a confirmed persist"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=awaiting_report$' \
    || fail "the timed-out persist expectation was closed instead of left to recovery"

  # The request the mate actually received is the open-record half of /stow only.
  request=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$request" "Open-record persistence" "the request must reuse stow's open-record contract"
  assert_contains "$request" "file a task for each open record" "the request must ask for the unfiled open records"
  assert_contains "$request" "correct any task whose status" "the request must ask for stale task status"
  assert_contains "$request" "captain call you had formed but never registered" \
    "the request must flush an unregistered captain call"
  assert_contains "$request" 'rewrite data/left-off.md following that skill'"'"'s "Where-I-left-off note" section' \
    "the request must refresh the note the fresh start reads first"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the request must exclude the memory curation half of stow"
  pass "T1 persist is a gate, and asks for open records, task status, and the left-off note only"
}

# --- T2: persist THEN restart, in that order --------------------------------
test_persist_precedes_restart() {
  local dir out rc doorbell_line exit_line
  dir=$(new_case order)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a confirmed persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on its pinned runtime"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" "the summary should report the reload"
  # The pane transcript orders the two phases: the instruction doorbell first,
  # the harness exit command only after it.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # The reply expectation is settled rather than left open behind the restart.
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"
  pass "T2 the mate persists before anything is stopped"
}

# --- T2b: an answer delivered at a zero-second bound still releases the gate -
test_arrived_answer_precedes_deadline_check() {
  local dir out rc
  dir=$(new_case arrived-at-bound)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer delivered with the request must beat the deadline check"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the arrived persist answer was ignored at the deadline"
  pass "T2b an arrived persist answer is resolved before timeout"
}

# --- T2c: an answer arriving between resolution and timeout wins -------------
test_answer_between_resolution_and_timeout_wins() {
  local dir out rc
  dir=$(new_case answer-at-timeout-decision)
  add_local_mate "$dir" sm1

  # Delay the modelled answer until the first resolution attempt has completed
  # its unsuccessful status scan. The real pending-reply machinery publishes
  # that scan signature with mv; this wrapper appends the correlated answer only
  # after that publication, reproducing the boundary race deterministically.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@" || exit $?
target=${!#}
case "$target" in
  "${FM_FAKE_DIR%/fake}"/home/state/pending-replies/*)
    if [ ! -e "$FM_FAKE_DIR/answer-after-scan" ] \
      && grep -q '^parent_status_scan_signature=.' "$target"; then
      : > "$FM_FAKE_DIR/answer-after-scan"
      corr=${target##*/}
      status=$(sed -n 's/^parent_status=//p' "$target")
      printf 'done [corr=%s]: open records written down\n' "$corr" >> "$status"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/mv"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer already on disk at the timeout decision must release the gate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the reply that raced the timeout was ignored"
  assert_not_contains "$out" "nudged: sm1" "a confirmed mate must not take the timeout fallback"
  pass "T2c a reply between the preliminary scan and timeout decision wins"
}

# --- T3: a runtime that cannot prove a restart never gets one ----------------
test_unprovable_runtime_falls_back() {
  local dir out rc
  dir=$(new_case unprovable)
  # zellij has no recovery-grade agent-state classifier, so "the old agent
  # stopped and the replacement came up" can never be established there.
  add_local_mate "$dir" sm1 claude zellij

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable runtime must not report a reload"$'\n'"$out"
  # Its liveness cannot be proven either, so the queued message is not reported
  # as a nudge that reached a running agent.
  assert_contains "$out" "unreached: sm1:" "an unprovable runtime cannot be confirmed to hold the re-read message"
  assert_contains "$out" "cannot prove an agent stopped" "the fallback must name the runtime limit"
  assert_contains "$out" "could not be confirmed running" "the report must say the agent's liveness is unconfirmed"
  assert_not_contains "$out" "nudged: sm1" "a nudge is reported only for an agent proven running"
  assert_not_contains "$out" "restarted: sm1" "an unprovable runtime must not be reported as restarted"
  # It is never even asked to spend a turn persisting, because it could not be
  # restarted afterwards either way; the only thing it was handed is the nudge.
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a mate that cannot be restarted should not be asked to persist first"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the fallback should hand the mate the ordinary re-read message"
  pass "T3 a runtime that cannot prove a restart gets the re-read message and is never claimed nudged"
}

# --- T3b: --fresh-start asks for the project map too, and skips instead of nudging
test_fresh_start_mode() {
  local dir out rc request
  dir=$(new_case fresh-start)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  out=$(run_restart "$dir" --fresh-start sm1); rc=$?
  expect_code 0 "$rc" "a confirmed fresh-start persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the fresh start must restart the mate"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 skipped, 0 unreached" "the fresh-start summary counts skips, not nudges"
  request=$(cat "$dir/home/state/sm1.inbox/handled"/*.msg "$dir/home/state/sm1.inbox"/*.msg 2>/dev/null)
  assert_contains "$request" "automatic fresh start" "the request must say why the mate is restarted"
  assert_contains "$request" 'data/project-map.md' "the fresh-start request must refresh the project map"
  assert_contains "$request" "Where-I-left-off note" "the fresh-start request must refresh the left-off note"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the fresh-start request must still exclude the memory curation half of stow"

  dir=$(new_case fresh-start-skip)
  add_local_mate "$dir" sm1 claude zellij
  out=$(run_restart "$dir" --fresh-start sm1); rc=$?
  expect_code 3 "$rc" "a mate the fresh start could not restart is not a success"$'\n'"$out"
  assert_contains "$out" "skipped: sm1: its runtime cannot prove an agent stopped" "an unprovable runtime is skipped"
  assert_not_contains "$out" "nudged: sm1" "a fresh start must never fall back to the update re-read nudge"
  assert_absent "$dir/home/state/sm1.inbox/001.msg" "a skipped mate must be sent nothing"
  pass "T3b --fresh-start refreshes the project map and skips instead of nudging"
}

# --- T4: a mate with no durable record in this home --------------------------
test_unknown_mate_is_accounted_for() {
  local dir out rc
  dir=$(new_case unknown)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1 ghost); rc=$?

  expect_code 3 "$rc" "an unknown mate must not pass silently"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the known mate should still be restarted"
  assert_contains "$out" "ghost:" "the unknown mate must be accounted for by name"
  assert_contains "$out" "no durable record" "the unknown mate's reason must be concrete"
  assert_contains "$out" "summary: 1 of 2 restarted, 0 nudged, 1 unreached" "the summary must count both mates"
  pass "T4 every named mate is accounted for, including one this home does not know"
}

# --- T5: a refused restart leaves the mate running and says so ---------------
# The control plane refused before touching the agent, so the mate is still on
# its previous agent: that is exactly the re-read-message outcome, and saying
# "unknown" would understate what is known.
test_refused_restart_falls_back_without_claiming_a_reload() {
  local dir out rc before
  dir=$(new_case refused)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  # muse is a crewmate-only adapter, so the control plane refuses a secondmate
  # relaunch onto it BEFORE stopping anything.
  printf 'muse\n' > "$dir/home/config/secondmate-harness"
  before=$(cat "$dir/fake/command")

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a refused restart must not be reported as a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "a refusal before the stop leaves the old agent running, which is a nudge"
  assert_contains "$out" "still running its previous agent" "the report must say the old agent is still running"
  assert_contains "$out" "not verified to run a secondmate task" "the report must carry the control plane's refusal"
  assert_not_contains "$out" "restarted: sm1" "a refused restart must not be reported as restarted"
  assert_contains "$out" "summary: 0 of 1 restarted, 1 nudged, 0 unreached" "the summary must count the kept agent as nudged"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "a refusal before the stop should leave the running agent exactly as it was"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a pre-stop refusal must not have stopped the agent"
  [ "$(grep -c '^: Firstmate instruction waiting: ' "$dir/fake/literal")" -ge 2 ] \
    || fail "the kept agent was not sent the re-read message"
  pass "T5 a refused restart leaves the mate running and reports it as a nudge"
}

# --- T6: a remote mate restarts over the fm-on hop, on the parent's pin -------
# The seam decodes what fm-on.sh actually put on the wire, so this pins the
# host-local command and the profile the PARENT resolved, not a local shortcut.
# The far side also models the live mate: it answers the persist request that
# crossed the same hop, on the parent channel, with that request's own token.
setup_remote_case() {  # <case-dir> <id> <ssh-mode>
  local dir=$1 id=$2 mode=$3
  local fb="$dir/fakebin"
  mkdir -p "$dir/$id-home"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/$id-home"
    echo "project=$dir/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/$id-home"
    echo "remote_host=remote-mac"
    echo "remote_backend=herdr"
    echo "remote_target=fm-remote:2ndmate-$id"
  } > "$dir/home/state/$id.meta"
  printf -- '- %s - remote domain (host: remote-mac; root: /srv/fm; home: /srv/%s; scope: things; projects: p; added 2026-09-03)\n' \
    "$id" "$id" > "$dir/home/data/secondmates.md"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
printf '%s\n' "${rargs[*]}" >> "$FM_FAKE_SSH_LOG"
case "${FM_FAKE_SSH_MODE:-ok}" in
  unreachable) exit 255 ;;
esac
case "${rargs[1]:-}" in
  state)
    # The remote endpoint's own verdict: dead once a modelled relaunch stopped
    # the agent and its replacement failed, alive otherwise.
    if [ -e "$FM_FAKE_DIR/remote-down" ]; then printf 'dead\n'; else printf 'alive\n'; fi
    ;;
  send)
    # Model the live remote mate: act on the instruction and report back on the
    # parent channel, carrying the correlation token the request embedded.
    if [ -n "${FM_FAKE_ANSWER_STATUS:-}" ]; then
      corr=$(printf '%s' "${rargs[3]:-}" | grep -oE 'corr=[0-9a-f]{16}' | head -1)
      [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
        >> "$FM_FAKE_ANSWER_STATUS"
    fi
    ;;
  relaunch)
    case "${FM_FAKE_SSH_MODE:-ok}" in
      stop-then-fail-once)
        if [ ! -e "$FM_FAKE_DIR/remote-relaunch-failed" ]; then
          : > "$FM_FAKE_DIR/remote-relaunch-failed"
          : > "$FM_FAKE_DIR/remote-down"
          printf "error: %s's agent was stopped but the replacement did not launch; no agent is running\n" "${rargs[2]}"
          printf 'relaunch_phase=failed:launching\n'
          printf 'relaunch_rollback=prior-record-kept\n'
          exit 1
        fi
        rm -f "$FM_FAKE_DIR/remote-down"
        ;;
      slow-relaunch)
        : > "$FM_FAKE_DIR/remote-relaunch-start"
        /bin/sleep 2
        : > "$FM_FAKE_DIR/remote-relaunch-end"
        ;;
    esac
    printf 'relaunched %s harness=%s from=claude model=%s effort=%s backend=herdr endpoint=fm-remote:2ndmate-%s worktree=/srv/fm\n' \
      "${rargs[2]}" "${rargs[3]}" "${rargs[4]}" "${rargs[5]}" "${rargs[2]}"
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=fm-remote:2ndmate-%s\n' "${rargs[2]}"
    printf 'herdr_session=fm-remote\n'
    printf 'harness=%s\n' "${rargs[3]}"
    printf 'model=%s\n' "${rargs[4]}"
    printf 'effort=%s\n' "${rargs[5]}"
    ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  : > "$dir/ssh.log"
  export FM_FAKE_SSH_LOG="$dir/ssh.log"
  export FM_FAKE_SSH_MODE="$mode"
  export FM_TEST_SSH_BIN="$fb/fake-ssh"
}

test_remote_mate_restarts_over_the_transport_hop() {
  local dir out rc relaunch_line
  dir=$(new_case remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  # The parent's own pin is what the replacement must run on; the remote home's
  # copy of config/secondmate-harness is a different home's file.
  printf 'codex big-model high\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" fm-sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a remote mate should restart over its transport hop"$'\n'"$out"
  assert_contains "$out" "restarted: sm2 on remote-mac (codex)" \
    "a remote restart should be reported with its host and the parent's pinned runtime"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ -n "$relaunch_line" ] || fail "no relaunch crossed the transport hop"$'\n'"$(cat "$dir/ssh.log")"
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 codex big-model high" ] \
    || fail "the host-local relaunch did not carry the parent's resolved profile: $relaunch_line"
  # The persist request crossed the SAME hop before the restart did.
  [ "$(grep -n '^fm-remote-secondmate-control.sh send' "$dir/ssh.log" | head -1 | cut -d: -f1)" \
     -lt "$(grep -n '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1 | cut -d: -f1)" ] \
    || fail "the remote mate was restarted before it was asked to persist"$'\n'"$(cat "$dir/ssh.log")"
  pass "T6 a remote mate restarts through the host-local control plane over the fm-on hop"
}

# --- T7: an unreachable host is unknown, never a claimed reload --------------
test_unreachable_host_is_reported_unknown() {
  local dir out rc
  dir=$(new_case unreachable)
  setup_remote_case "$dir" sm3 unreachable

  out=$(run_restart "$dir" sm3); rc=$?

  expect_code 3 "$rc" "an unreachable host must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm3" "an unreachable host must not be claimed as restarted"
  assert_contains "$out" "sm3:" "the unreachable mate must still be named"
  assert_contains "$out" "could not be delivered" "an unreachable host must be reported as undelivered, not as reloaded"
  pass "T7 an unreachable host is reported honestly instead of claimed as reloaded"
}

# --- T8: a local restart lands on this home's durable pin, and says which -----
test_local_restart_uses_the_home_pin_and_reports_what_ran() {
  local dir out rc
  dir=$(new_case pin)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'codex\n' > "$dir/home/config/secondmate-harness"
  printf 'codex' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a pinned local restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (codex)" \
    "the restart should land on this home's pin and report the runtime that actually came up"
  [ "$(grep '^harness=' "$dir/home/state/sm1.meta" | tail -1)" = "harness=codex" ] \
    || fail "the durable record did not follow the replacement onto the pinned runtime"
  pass "T8 a local restart re-resolves this home's pin and reports the runtime that came up"
}

test_native_ultra_restart_keeps_local_and_remote_profiles() {
  local dir out rc relaunch_line
  dir=$(new_case native-local)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'pi codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  printf 'pi' > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "native local restart failed: $out"
  assert_contains "$out" "restarted: sm1 (pi)" "native local restart did not complete"
  assert_contains "$(cat "$dir/home/state/sm1.meta")" "effort=ultra" "local restart dropped native effort"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "local restart dropped native launch flag"

  dir=$(new_case native-remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'pi-signed codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS
  expect_code 0 "$rc" "native remote restart failed: $out"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 pi-signed codex-native/gpt-6-astra ultra" ] \
    || fail "remote restart dropped native profile: $relaunch_line"
  pass "native Ultra survives local restart and the remote restart transport"
}

# --- T9: an unrelated concurrent reply cannot release the persist gate -------
test_concurrent_reply_cannot_release_persist_gate() {
  local dir out rc state corr rec
  dir=$(new_case correlation)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  corr=ffffffffffffffff
  rec="$state/pending-replies/$corr"
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/concurrent-created" ] || exit 0
: > "$dir/fake/concurrent-created"
mkdir -p "$state/pending-replies"
cat > "$rec" <<EOF
phase=awaiting_report
task_id=sm1
parent_status=$state/sm1.status
parent_status_scan_signature=
delivered_epoch=1
resolved_epoch=
resolved_via=
EOF
printf 'done [corr=$corr]: unrelated request answered\n' >> "$state/sm1.status"
SH
  chmod +x "$dir/fake/on-doorbell"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unrelated concurrent answer must not release the persist gate"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm1" "the unrelated answer authorized a restart"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the unrelated answer stopped the mate"
  pass "T9 the persist gate retains its explicitly allocated correlation"
}

# --- T10: one unanswered mate does not hold a confirmed mate behind it -------
test_persist_waits_are_polled_together() {
  local dir out rc exit_line nudge_line
  dir=$(new_case concurrent-waits)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  arm_answer "$dir" sm2

  # The bound comfortably exceeds one relaunch, so the confirmed mate's stop
  # landing first proves it was not held behind the unanswered mate's wait.
  out=$(FM_TEST_PERSIST_WAIT=20 run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "the unanswered mate should fall back after the confirmed mate restarts"$'\n'"$out"
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  nudge_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | tail -1 | cut -d: -f1)
  [ -n "$exit_line" ] && [ -n "$nudge_line" ] && [ "$exit_line" -lt "$nudge_line" ] \
    || fail "the first mate's timeout held the confirmed second mate behind it: $out"
  pass "T10 pending persist answers are polled as one fleet"
}

# --- T11: a stopped mate whose replacement never comes up is reported down --
test_post_stop_failure_is_reported_unreached() {
  local dir out rc
  dir=$(new_case post-stop)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a post-stop relaunch failure must remain accounted for"$'\n'"$out"
  assert_contains "$out" "unreached: sm1: DOWN - no agent is running" "a stopped mate left down must be reported as down"
  assert_contains "$out" "even on a retry" "the report must say the replacement was retried"
  assert_contains "$out" "recover it with: FM_HOME='$dir/home' '$ROOT/bin/fm-spawn.sh' sm1 --secondmate" \
    "the down report must carry the exact command that recovers the mate"
  [ "$(grep -c '^/exit$' "$dir/fake/literal")" -eq 1 ] \
    || fail "the retry must not stop anything again"
  assert_not_contains "$out" "nudged: sm1" "a durable enqueue must not masquerade as a running mate's nudge"
  assert_contains "$out" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the summary must not claim that a stopped mate remains on older instructions with a message"
  pass "T11 a stopped mate whose replacement never comes up is reported down, never as a nudge"
}

# --- T11b: a replacement that fails once is retried and proven running ------
test_post_stop_launch_failure_is_retried() {
  local dir out rc window
  dir=$(new_case post-stop-retry)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf '1' > "$dir/fake/launch-failures.fmses:fm-sm1"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a replacement that comes up on the retry is a restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the retried replacement must be reported restarted"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" "the summary must count the restart"
  [ "$(grep -c '^/exit$' "$dir/fake/literal")" -eq 1 ] \
    || fail "the retry must launch the replacement without stopping anything again"
  window=$(sed -n 's/^window=//p' "$dir/home/state/sm1.meta" | tail -1)
  [ -n "$window" ] && [ "$(cat "$dir/fake/command.$window" 2>/dev/null)" = claude ] \
    || fail "the mate is not running at its recorded endpoint '$window' after the retried launch"
  pass "T11b a replacement that fails once is retried and proven running"
}

# --- T11c: a predictable launch refusal is caught before the stop ----------
# The launch owner refuses a home without bin/, a check it used to reach only
# after the old agent was gone. The relaunch now proves it first, so the old
# agent is never touched and the mate is reported on its previous agent.
test_launch_refusal_is_caught_before_the_stop() {
  local dir out rc
  dir=$(new_case pre-stop-refusal)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'claude' > "$dir/fake/command.fmses:fm-sm1"
  rmdir "$dir/sm1-home/bin"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a launch the owner would refuse must not be reported as a restart"$'\n'"$out"
  assert_contains "$out" "nudged: sm1: its restart was refused before its agent was touched" \
    "the predictable refusal must leave the old agent running and say so"
  assert_contains "$out" "missing bin/" "the report must carry the launch owner's own refusal"
  assert_no_grep '/exit' "$dir/fake/literal" "the old agent was stopped for a launch that was always going to be refused"
  [ "$(cat "$dir/fake/command.fmses:fm-sm1")" = claude ] || fail "the old agent is no longer running"
  pass "T11c a predictable launch refusal is caught before the old agent is stopped"
}

test_unsafe_task_temp_root_is_refused_before_stop() (
  local dir out rc id task_tmp
  id="pf$RANDOM$RANDOM"
  dir=$(new_case temp-root-refusal)
  add_local_mate "$dir" "$id"
  arm_answer "$dir" "$id"
  task_tmp="/tmp/fm-$id"
  [ ! -e "$task_tmp" ] && [ ! -L "$task_tmp" ] || fail "test task temp root already exists"
  ln -s "$dir" "$task_tmp"
  trap 'rm -f -- "$task_tmp"' EXIT

  out=$(run_restart "$dir" "$id"); rc=$?

  expect_code 3 "$rc" "an unsafe task temp root must refuse before the agent stops"$'\n'"$out"
  assert_contains "$out" "nudged: $id: its restart was refused before its agent was touched" \
    "the unsafe temp root must leave the old agent running"
  assert_contains "$out" "task temp root $task_tmp already exists" \
    "the refusal must identify the unsafe task temp root"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the old agent stopped despite the unsafe temp root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent is no longer running"
  pass "T11c1 an unsafe task temp root refuses before the old agent stops"
)

test_wrong_endpoint_worktree_is_refused_before_stop() {
  local dir out rc
  dir=$(new_case endpoint-worktree-refusal)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf '%s' "$dir/home" > "$dir/fake/cwd.fmses:fm-sm1"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an endpoint outside the mate home must refuse before the agent stops"$'\n'"$out"
  assert_contains "$out" "nudged: sm1: its restart was refused before its agent was touched" \
    "the wrong endpoint worktree must leave the old agent running"
  assert_contains "$out" "not its recorded worktree" "the refusal must identify the endpoint location"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the old agent stopped despite the wrong endpoint worktree"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent is no longer running"
  pass "T11c2 an endpoint outside the mate home refuses before the old agent stops"
}

test_preflight_rejects_other_task_kinds() {
  local dir kind out rc
  dir=$(new_case preflight-kind)
  add_local_mate "$dir" sm1
  for kind in ship scout; do
    sed "s/^kind=.*/kind=$kind/" "$dir/home/state/sm1.meta" > "$dir/home/state/sm1.meta.next"
    mv "$dir/home/state/sm1.meta.next" "$dir/home/state/sm1.meta"
    rc=0
    out=$(env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID \
      -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u TMUX -u TMUX_PANE \
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      CLAUDE_CONFIG_DIR="$dir/claude-config" \
      FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" sm1 --relaunch --preflight 2>&1) || rc=$?
    expect_code 1 "$rc" "a $kind task must not enter the secondmate preflight"$'\n'"$out"
    assert_contains "$out" "--preflight applies to secondmate relaunches only" \
      "the $kind preflight must be rejected at the public command"
    assert_no_grep '^/exit$' "$dir/fake/literal" "a $kind preflight stopped the agent"
  done
  [ ! -s "$dir/fake/herdr-calls" ] || fail "the kind checks reached a real herdr client"
  pass "T11c3 the launch preflight is limited to secondmate relaunches"
}

# --- T11d: a nudge is reported only to an agent proven running --------------
test_dead_mate_is_never_reported_nudged() {
  local dir out rc
  dir=$(new_case dead-nudge)
  add_local_mate "$dir" sm1
  printf 'zsh' > "$dir/fake/command.fmses:fm-sm1"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a mate with no running agent is not a success"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a queued message to a dead agent must not count as a nudge"
  assert_contains "$out" "could not be confirmed running (its endpoint reads 'dead')" \
    "the report must say the agent is not running"
  assert_not_contains "$out" "nudged: sm1" "a dead agent must never be reported nudged"
  pass "T11d a mate whose agent is not running is never reported nudged"
}

# --- T11e: a remote mate left down by its relaunch is retried once -----------
test_remote_stop_then_failed_launch_is_retried() {
  local dir out rc
  dir=$(new_case remote-retry)
  setup_remote_case "$dir" sm1 stop-then-fail-once
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a remote replacement that comes up on the retry is a restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 on remote-mac (claude)" "the retried remote replacement must be reported restarted"
  [ "$(grep -c '^fm-remote-secondmate-control.sh relaunch sm1 ' "$dir/ssh.log")" -eq 2 ] \
    || fail "a remote stop with a failed launch must be retried exactly once"
  pass "T11e a remote mate whose relaunch stopped it and failed is retried once"
}

# --- T11f: the batch stops after a mate is left down ------------------------
# Every launch of sm1 fails, so it ends down; sm2 must then keep its old agent
# rather than risk a second mate down.
test_batch_stops_after_a_down_mate() {
  local dir out rc
  dir=$(new_case batch-halt)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  printf 'claude' > "$dir/fake/command.fmses:fm-sm1"
  printf 'claude' > "$dir/fake/command.fmses:fm-sm2"
  printf '9' > "$dir/fake/launch-failures.fmses:fm-sm1"
  printf '9' > "$dir/fake/launch-failures.firstmate:fm-sm1"
  # A respawned window the stub has not seen yet holds a bare shell.
  printf 'zsh' > "$dir/fake/command"
  make_batch_hooks "$dir"
  rm -f "$dir/fake/on-exit"

  out=$(run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "a down mate is not a success"$'\n'"$out"
  assert_contains "$out" "unreached: sm1: DOWN - no agent is running" "the first mate must be reported down"
  assert_contains "$out" "nudged: sm2: it was not restarted because the batch stopped after sm1 was left with no agent running" \
    "the next mate must be left on its old agent with the reason"
  [ "$(cat "$dir/fake/command.fmses:fm-sm2")" = claude ] || fail "the next mate's old agent was touched"
  [ "$(grep -c '^/exit$' "$dir/fake/literal")" -eq 1 ] || fail "a second mate was stopped after the first was left down"
  assert_contains "$out" "summary: 0 of 2 restarted, 1 nudged, 1 unreached" "the summary must count the halt"
  pass "T11f the batch stops after a mate is left down and leaves the rest on their old agents"
}

# --- T12: restarts run one at a time while answers keep arriving -----------
# A batch must never have two mates down at once: the second mate's relaunch
# waits for the first, slow one to finish, while its persist answer is still
# collected in the meantime.
test_relaunches_do_not_block_persist_polling() {
  local dir out rc
  dir=$(new_case relaunch-polling)
  setup_remote_case "$dir" sm1 slow-relaunch
  add_local_mate "$dir" sm2
  printf -- '- sm2 - local domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' \
    "$dir/sm2-home" >> "$dir/home/data/secondmates.md"
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=5 run_restart "$dir" sm1 sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "both confirmed mates should restart"$'\n'"$out"
  assert_absent "$dir/fake/local-relaunch-during-remote" \
    "the second mate was stopped while the first mate's relaunch was still running"
  assert_contains "$out" "summary: 2 of 2 restarted, 0 nudged, 0 unreached" \
    "serial relaunches were not both accounted for"
  assert_grep 'fm-remote-secondmate-control.sh relaunch sm1 claude default default' "$dir/ssh.log" \
    "an absent remote model and effort pin were not expressed as explicit defaults"
  pass "T12 restarts run one at a time and every confirmed mate still restarts"
}

# --- T12b: a batch restart cannot be raced by dead-secondmate recovery ------
# The 2026-10-28 batch: every mate answered, then the watcher's liveness tick
# found the deliberately stopped agents, read them as dead, closed their
# endpoints, and raced its own launch against each restart, leaving mates with
# no agent. Here four mates restart in one call, and at the exact moment each
# agent is stopped the watcher's recovery runs the shared liveness library the
# same way its tick does: take the per-mate lock, probe, and act only on a
# relaunchable verdict. It must find every mate held, and the batch must never
# have more than one mate down at once.
make_batch_hooks() {  # <case-dir>
  local dir=$1
  cat > "$dir/fake/on-doorbell" <<'SH'
#!/usr/bin/env bash
# Each modelled mate answers its own persist request on the parent channel.
set -u
inbox=${1#*list \'}
inbox=${inbox%%\'*}
corr=$(cat "$inbox"/*.msg 2>/dev/null | grep -oE 'corr=[0-9a-f]{16}' | head -1)
[ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" >> "${inbox%.inbox}.status"
SH
  cat > "$dir/fake/on-exit" <<'SH'
#!/usr/bin/env bash
set -u
target=$1
id=${target##*:fm-}
D=$FM_FAKE_DIR
down=0
for f in "$D"/command.*; do
  [ "$(cat "$f")" != zsh ] || down=$((down + 1))
done
printf '%s\n' "$down" >> "$D/down-counts"
(
  STATE=$FM_HOME/state
  FM_ROOT=$FM_TEST_ROOT
  # shellcheck source=/dev/null
  . "$FM_TEST_ROOT/bin/fm-secondmate-liveness-lib.sh"
  if fm_secondmate_liveness_lock "$id"; then
    fm_secondmate_liveness_probe "$STATE/$id.meta" "$id" poll
    printf '%s %s\n' "$id" "$FM_SM_LIVE_STATUS" >> "$D/watcher"
    fm_secondmate_liveness_unlock "$id"
  else
    printf '%s held\n' "$id" >> "$D/watcher"
  fi
)
SH
  chmod +x "$dir/fake/on-doorbell" "$dir/fake/on-exit"
}

test_batch_restart_is_not_raced_by_liveness_recovery() {
  local dir out rc id
  dir=$(new_case batch)
  for id in sm1 sm2 sm3 sm4; do
    add_local_mate "$dir" "$id"
    printf 'claude' > "$dir/fake/command.fmses:fm-$id"
  done
  make_batch_hooks "$dir"

  export FM_TEST_ROOT="$ROOT"
  out=$(run_restart "$dir" fm-sm1 fm-sm2 fm-sm3 fm-sm4); rc=$?
  unset FM_TEST_ROOT

  expect_code 0 "$rc" "every mate in the batch should restart"$'\n'"$out"
  assert_contains "$out" "summary: 4 of 4 restarted, 0 nudged, 0 unreached" "the whole batch must be restarted"
  for id in sm1 sm2 sm3 sm4; do
    assert_contains "$out" "restarted: $id (claude)" "mate $id was not restarted"
    [ "$(cat "$dir/fake/command.fmses:fm-$id")" = claude ] || fail "mate $id is not running after the batch"
    assert_grep "$id held" "$dir/fake/watcher" "the watcher's recovery could act on $id while it was mid-restart"
  done
  assert_no_grep 'relaunchable' "$dir/fake/watcher" "the watcher's recovery read a mid-restart mate as dead"
  [ "$(grep -c . "$dir/fake/down-counts")" -eq 4 ] || fail "every mate should have been stopped exactly once"
  [ "$(sort -n "$dir/fake/down-counts" | tail -1)" -eq 1 ] \
    || fail "the batch had more than one mate down at once: $(tr '\n' ' ' < "$dir/fake/down-counts")"
  pass "T12b a batch restart is never raced by dead-secondmate recovery and keeps one mate down at most"
}

# --- T13: a worker that cannot publish its result cannot hang the pass -------
test_unpublished_worker_result_is_accounted_for() {
  local dir out rc_file driver i result_dir
  dir=$(new_case worker-result)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  out="$dir/restart.out"
  rc_file="$dir/restart.rc"

  ( run_restart "$dir" sm1 > "$out" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  driver=$!
  result_dir=
  i=0
  while [ "$i" -lt 200 ]; do
    result_dir=$(find "$dir/home/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    [ -e "$dir/fake/remote-relaunch-start" ] && [ -n "$result_dir" ] && break
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -n "$result_dir" ] || { kill "$driver" 2>/dev/null || true; fail "restart result directory never appeared"; }
  rm -rf -- "$result_dir"
  i=0
  while kill -0 "$driver" 2>/dev/null && [ "$i" -lt 400 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$driver" 2>/dev/null; then
    kill "$driver" 2>/dev/null || true
    wait "$driver" 2>/dev/null || true
    fail "a terminated restart worker left the parent hung"
  fi
  wait "$driver" 2>/dev/null || true
  unset FM_FAKE_ANSWER_STATUS

  [ "$(cat "$rc_file")" = 3 ] || fail "an unpublished worker result did not fail as accounted"
  assert_contains "$(cat "$out")" "restart worker exited before publishing an outcome" \
    "the missing worker result was not reported"
  assert_contains "$(cat "$out")" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the missing worker result was not included in the summary"
  pass "T13 a dead restart worker cannot hang the parent"
}

# --- T14: result publication after the first probe remains authoritative -----
test_result_published_while_reaping_is_honored() {
  local dir out rc
  dir=$(new_case result-race)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_DIR/remote-relaunch-start" ] && [ ! -e "$FM_FAKE_DIR/result-race-injected" ]; then
  result=$(find "$FM_HOME/state" -maxdepth 2 -name '0.result' -print -quit)
  if [ -z "$result" ]; then
    result_dir=$(find "$FM_HOME/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    if [ -n "$result_dir" ]; then
      printf 'restarted: sm1 on remote-mac (claude)\n' > "$result_dir/0.result"
      : > "$FM_FAKE_DIR/result-race-injected"
      printf 'Z\n'
      exit 0
    fi
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a result published while the worker is reaped must remain authoritative"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 on remote-mac (claude)" \
    "the result published during the reap window was replaced with a worker failure"
  assert_not_contains "$out" "exited before publishing" \
    "the parent failed to recheck the worker result after wait"
  pass "T14 a result published during reaping is honored"
}

# --- T15: an already-current mate still restarts, end to end -----------------
# The SSHHIP regression, driven through BOTH real commands rather than either
# one's own idea of the other. The mate's home needs no fast-forward at all, so
# the old instruction-diff classifier left it out of every action set and its
# agent kept running the launch-time wiring it started with. The update pass must
# now name it, and the restart pass must then persist its open records and only
# afterwards replace the agent.
test_already_current_mate_restarts_end_to_end() {
  local dir out restart_line ids rc head_before head_after doorbell_line exit_line
  dir=$(new_case already-current)
  add_repo_backed_mate "$dir" sm1
  arm_answer "$dir" sm1
  head_before=$(git -C "$dir/sm1-home" rev-parse HEAD)

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live second mate must still be named for restart"
  assert_contains "$out" "nudge-secondmates: none" \
    "a mate named for restart must not also be steered"

  ids=${restart_line#restart-secondmates: }
  # shellcheck disable=SC2086
  out=$(run_restart "$dir" $ids); rc=$?

  expect_code 0 "$rc" "the mate named by the update pass did not restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "an already-current mate must actually be replaced"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" \
    "the pass must report the reload it performed"
  # Persist strictly before replace, read off the pane transcript.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the already-current mate"
  [ -n "$exit_line" ] || fail "the already-current mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # Nothing about the home's git state was touched to buy that restart.
  head_after=$(git -C "$dir/sm1-home" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "the already-current home's checkout moved"
  [ -z "$(git -C "$dir/sm1-home" status --porcelain)" ] \
    || fail "the restart left the mate's home dirty"
  pass "T15 an already-current live mate is named by the update pass and genuinely restarted"
}

# --- T16: an already-current mate that cannot prove a restart stays honest ----
# Same already-current home, a runtime with no recovery-grade state classifier.
# Unconditional restart must not become an unconditional CLAIM of one: the update
# pass routes it to the re-read steer, and the restart pass reports a nudge with
# the agent still running.
test_already_current_unprovable_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line before
  dir=$(new_case already-current-unprovable)
  # zellij can never establish "the old agent stopped and the replacement came up".
  add_repo_backed_mate "$dir" sm1 claude zellij
  arm_answer "$dir" sm1
  before=$(cat "$dir/fake/command")

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a mate whose restart cannot be proven must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live mate that cannot be restarted must keep the honest re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable restart must not report success"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "an unprovable runtime cannot be confirmed to hold the re-read message"
  assert_contains "$out" "could not be confirmed running" "the report must say the agent's liveness is unconfirmed"
  assert_not_contains "$out" "restarted: sm1" "an unprovable mate must never be reported as reloaded"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "the unprovable mate's agent was stopped anyway"
  assert_no_grep '^/exit$' "$dir/fake/literal" "nothing may be stopped on the nudge path"
  pass "T16 an already-current mate with an unprovable runtime gets the re-read message and an honest report"
}

test_persist_gates_and_asks_only_for_open_records
test_persist_precedes_restart
test_arrived_answer_precedes_deadline_check
test_answer_between_resolution_and_timeout_wins
test_unprovable_runtime_falls_back
test_fresh_start_mode
test_unknown_mate_is_accounted_for
test_refused_restart_falls_back_without_claiming_a_reload
test_local_restart_uses_the_home_pin_and_reports_what_ran
test_native_ultra_restart_keeps_local_and_remote_profiles
test_remote_mate_restarts_over_the_transport_hop
test_unreachable_host_is_reported_unknown
test_concurrent_reply_cannot_release_persist_gate
test_persist_waits_are_polled_together
test_post_stop_failure_is_reported_unreached
test_post_stop_launch_failure_is_retried
test_launch_refusal_is_caught_before_the_stop
test_unsafe_task_temp_root_is_refused_before_stop
test_wrong_endpoint_worktree_is_refused_before_stop
test_preflight_rejects_other_task_kinds
test_dead_mate_is_never_reported_nudged
test_remote_stop_then_failed_launch_is_retried
test_batch_stops_after_a_down_mate
test_relaunches_do_not_block_persist_polling
test_batch_restart_is_not_raced_by_liveness_recovery
test_unpublished_worker_result_is_accounted_for
test_result_published_while_reaping_is_honored
test_already_current_mate_restarts_end_to_end
test_already_current_unprovable_mate_stays_on_the_nudge_path

echo "# all fm-secondmate-restart tests passed"
