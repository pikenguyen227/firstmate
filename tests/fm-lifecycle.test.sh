#!/usr/bin/env bash
# tests/fm-lifecycle.test.sh - the fm-lifecycle.v1 event feed
# (bin/fm-lifecycle-lib.sh, bin/fm-lifecycle.sh) and every script that emits
# into it.
#
# The feed is Firstmate's only lifecycle history that outlives teardown, so
# these tests pin it with real processes and the real entry points:
#   1. The writer: every line is a valid envelope, `seq` is gap-free across
#      processes and concurrent writers, a torn final line is fenced off, and
#      rotation keeps `seq` continuous across files.
#   2. Best effort: a disabled feed, a fixture state directory that belongs to
#      no home, an unwritable feed, and a held lock all leave the caller's exit
#      status, stdout, stderr, and errexit untouched.
#   3. Transcription through the real wake drain: one event per status line,
#      the drain's own keyed-decision fold transitions, incomplete lines held
#      back until they end, chunked passes, no duplicate on re-run, and a
#      replaced status file keyed apart from the one it replaced.
#   4. The emit sites, end to end on one task: fm-spawn (fresh and relaunch),
#      fm-promote, a steer through the inbox writer, the watcher's
#      acknowledgement scan, and fm-teardown's final flush before it deletes
#      the task's status, metadata, and inbox.
#   5. Discovery: the fleet snapshot's additive `lifecycle` pointer, and the
#      feed key it publishes for each task's last status line, matched exactly
#      against the feed for stamped, unstamped, repeated, relaunched, and
#      replaced lines.
#   6. fm-lifecycle.sh backfill replays live tasks once and only once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCHER="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-lifecycle)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# A minimal home: state/ and data/ side by side, as every real home has them.
new_home() {  # <name> -> echoes home
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

# Run public library functions in a fresh shell scoped to <home>, the way every
# production caller sources them.
lc() {  # <home> <function> [args...]
  local home=$1
  shift
  FM_HOME="$home" bash -c '
    set -eu
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    . "$1/bin/fm-task-inbox-lib.sh"
    . "$1/bin/fm-lifecycle-lib.sh"
    shift
    "$@"
  ' _ "$ROOT" "$@"
}

feed_file() { printf '%s/data/lifecycle/events.v1.jsonl\n' "$1"; }

# Every feed line of a home, oldest file first, as one JSON array.
feed_json() {  # <home>
  local dir="$1/data/lifecycle" files=() f
  for f in "$dir"/events.v1.*.jsonl; do [ -f "$f" ] && files+=("$f"); done
  [ ! -f "$dir/events.v1.jsonl" ] || files+=("$dir/events.v1.jsonl")
  if [ "${#files[@]}" -eq 0 ]; then printf '[]\n'; return 0; fi
  cat "${files[@]}" | jq -cs 'sort_by(.seq)'
}

count_type() {  # <home> <type> [task]
  feed_json "$1" | jq --arg t "$2" --arg id "${3:-}" \
    '[.[] | select(.type == $t and ($id == "" or .task.id == $id))] | length'
}

# The envelope contract, checked on every line of every feed file: each line
# parses, carries the full envelope from one home, keys are unique, and seq runs
# 1..N with no gap or repeat.
assert_feed_valid() {  # <home> <label>
  local home=$1 label=$2 dir="$1/data/lifecycle" f line n=0
  for f in "$dir"/events.v1*.jsonl; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      printf '%s' "$line" | jq -e '
        .schema == "fm-lifecycle.v1"
        and (.home.id | type) == "string" and (.home.path | type) == "string" and .home.host == null
        and (.seq | type) == "number"
        and (.key | type) == "string" and (.key | length) > 0
        and (.type | type) == "string"
        and ((.at | type) == "number" or .at == null)
        and ([.at_source] | inside(["stamp","firstmate","inbox","observed","unknown"]))
        and (.recorded_at | type) == "number"
        and ((.task == null) or ((.task.id | type) == "string"))
        and (.backfill | type) == "boolean"
        and (.data | type) == "object"
      ' >/dev/null || fail "$label: feed line $n is not a valid fm-lifecycle.v1 envelope: $line"
    done < "$f"
  done
  feed_json "$home" | jq -e --arg id "$(cat "$dir/home-id")" '
    (map(.seq) == [range(1; length + 1)])
    and ((map(.key) | unique | length) == length)
    and all(.[]; .home.id == $id)
    and (.[0].type == "feed.started")
  ' >/dev/null || fail "$label: feed seq is not gap-free from 1, keys repeat, home ids differ, or it does not open with feed.started:"$'\n'"$(feed_json "$home" | jq -c '.[] | {seq,key,type}')"
}

# --- 1. the writer --------------------------------------------------------------

test_writer_envelope_and_gap_free_seq() {
  local home state i pids=() pid
  home=$(new_home writer)
  state="$home/state"
  fm_write_meta "$state/t1.meta" "kind=ship" "mode=local-only" "harness=claude" \
    "spawn_gen=s1790000000.11.22" "window=fmses:fm-t1" "project=/p"
  lc "$home" fm_lifecycle_task_spawned "$state" t1 0
  lc "$home" fm_lifecycle_task_reclassified "$state" t1 scout ship local-only off
  # Eight concurrent writers, each a separate process writing a steer for its
  # own task, must interleave into one gap-free sequence.
  for i in 1 2 3 4 5 6 7 8; do
    fm_write_meta "$state/w$i.meta" "kind=ship" "spawn_gen=s1790000000.$i.1"
    lc "$home" fm_task_inbox_write "$state" "w$i" "steer $i" >/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent inbox write failed"; done
  assert_feed_valid "$home" "writer"
  assert_equals 8 "$(count_type "$home" task.steered)" "every concurrent steer should be recorded exactly once"
  assert_equals 1 "$(feed_json "$home" | jq '[.[] | select(.type == "feed.started")] | length')" \
    "the feed should hold exactly one feed.started"
  feed_json "$home" | jq -e '.[] | select(.type == "task.spawned") |
    .task == {id:"t1", spawn_gen:"s1790000000.11.22"} and .at_source == "firstmate"
    and .data.kind == "ship" and .data.backend == "tmux" and .data.endpoint == {target:"fmses:fm-t1"}
    and .data.relaunch == false and .key == "spawned/t1/s1790000000.11.22"' >/dev/null \
    || fail "task.spawned did not carry the record's identity: $(feed_json "$home" | jq -c '.[1]')"
  feed_json "$home" | jq -e '.[] | select(.type == "task.reclassified") |
    .data == {from:{kind:"scout"}, to:{kind:"ship", mode:"local-only", yolo:"off"}}' >/dev/null \
    || fail "task.reclassified did not carry the transition"
  assert_equals "$(feed_json "$home" | jq -r 'map(.seq) | max')" "$(cat "$home/data/lifecycle/head")" \
    "head should name the last written seq"
  pass "writer: every line is a full envelope and seq stays gap-free across processes and concurrent writers"
}

test_writer_fences_a_torn_line_and_rotates() {
  local home state feed before last i rotated
  home=$(new_home torn)
  state="$home/state"
  feed=$(feed_file "$home")
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1790000000.1.1"
  lc "$home" fm_lifecycle_task_spawned "$state" t1 0
  last=$(feed_json "$home" | jq 'map(.seq) | max')
  # A crash mid-append leaves an unterminated fragment that already claimed the
  # next seq. The next write must fence it onto its own line and not reuse it.
  printf '{"schema":"fm-lifecycle.v1","home":{"id":"x"},"seq":%s,"key":"torn' "$((last + 1))" >> "$feed"
  lc "$home" fm_lifecycle_task_reclassified "$state" t1 scout ship direct-PR on
  tail -n 1 "$feed" | jq -e --argjson want "$((last + 2))" '.type == "task.reclassified" and .seq == $want' >/dev/null \
    || fail "the event after a torn line should take the next unclaimed seq: $(tail -n 2 "$feed")"
  [ "$(grep -c '"key":"torn$' "$feed")" = 1 ] || fail "the torn fragment should be fenced onto its own line"
  # A reader skips the fenced fragment; drop it here so the rest must run 1..N
  # with only the fragment's own claimed seq missing.
  grep -v '"key":"torn$' "$feed" > "$feed.clean" && mv "$feed.clean" "$feed"
  before=$(wc -l < "$feed" | tr -d ' ')
  # Rotation: a tiny threshold rotates the active file before each write, and
  # seq keeps counting across files.
  for i in 1 2 3; do
    FM_LIFECYCLE_ROTATE_BYTES=200 lc "$home" fm_lifecycle_task_reclassified "$state" t1 scout ship local-only "r$i"
  done
  rotated=$(find "$home/data/lifecycle" -name 'events.v1.*.jsonl' | wc -l | tr -d ' ')
  [ "$rotated" -ge 2 ] || fail "a tiny rotation size should have produced rotated files, got $rotated"
  for f in "$home/data/lifecycle"/events.v1.*.jsonl; do
    first=$(head -n 1 "$f" | jq '.seq')
    case "$f" in *".v1.$first.jsonl") ;; *) fail "rotated file $f is not named by its first seq ($first)" ;; esac
  done
  feed_json "$home" | jq -e --argjson n "$((before + 3 + 1))" --argjson torn "$((last + 1))" '
    (map(.seq) | .[-1]) == $n and (map(.seq) == ([range(1; $n + 1)] - [$torn]))' >/dev/null \
    || fail "seq did not continue across rotation: $(feed_json "$home" | jq -c 'map(.seq)')"
  # A crash can land an append without rewriting head. The next write, even one
  # that rotates the active file away, must continue from the feed itself.
  last=$(feed_json "$home" | jq 'map(.seq) | max')
  printf '%s\n' "$((last - 1))" > "$home/data/lifecycle/head"
  FM_LIFECYCLE_ROTATE_BYTES=200 lc "$home" fm_lifecycle_task_reclassified "$state" t1 scout ship local-only stale
  feed_json "$home" | jq -e --argjson want "$((last + 1))" '
    (map(.seq) | max) == $want and ((map(.seq) | unique | length) == length)' >/dev/null \
    || fail "a stale head reused a seq across rotation: $(feed_json "$home" | jq -c 'map(.seq)')"
  pass "writer: a torn final line is fenced and never reused, and rotation keeps seq continuous across files"
}

# --- 2. best effort ---------------------------------------------------------------

test_disabled_or_foreign_state_emits_nothing() {
  local home other out
  home=$(new_home disabled)
  fm_write_meta "$home/state/t1.meta" "kind=ship" "spawn_gen=s1.1.1"
  FM_LIFECYCLE=off lc "$home" fm_lifecycle_task_spawned "$home/state" t1 0
  assert_absent "$home/data/lifecycle" "FM_LIFECYCLE=off must not create the feed"
  # A fixture that overrides only its state directory belongs to no home: the
  # writer must not fall back to FM_HOME's data directory.
  other="$TMP_ROOT/disabled/foreign-state"
  mkdir -p "$other"
  fm_write_meta "$other/t1.meta" "kind=ship" "spawn_gen=s1.1.1"
  out=$(lc "$home" fm_lifecycle_task_spawned "$other" t1 0 2>&1)
  assert_equals "" "$out" "a skipped emit must print nothing"
  assert_absent "$home/data/lifecycle" "a state directory outside the home must not write into the home's feed"
  out=$(lc "$home" fm_lifecycle_snapshot_json "$other")
  assert_equals null "$out" "the snapshot pointer should be null when no feed resolves"
  pass "best effort: a disabled feed or a state directory that belongs to no home records nothing"
}

test_emit_never_disturbs_the_caller() {
  local home state out rc start elapsed
  home=$(new_home caller)
  state="$home/state"
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1.1.1"
  # An unwritable feed location: the emit fails inside and the errexit caller
  # carries on with a clean exit status and no output.
  printf 'not a directory\n' > "$home/data/lifecycle"
  out=$(FM_HOME="$home" bash -c '
    set -euo pipefail
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"
    fm_lifecycle_task_spawned "$2" t1 0
    fm_lifecycle_task_torn_down "$2" t1 1 close "" ""
    fm_lifecycle_transcribe_all "$2"
    echo reached
  ' _ "$ROOT" "$state" 2>&1)
  rc=$?
  expect_code 0 "$rc" "an emit into an unwritable feed must not fail an errexit caller"
  assert_equals reached "$out" "an emit must print nothing into its caller"
  rm -f "$home/data/lifecycle"
  # A lock held by a live process: the emit gives up after its bounded wait,
  # returns success, and records why in the error log.
  mkdir -p "$home/data/lifecycle/.lock"
  printf '%s\n' "$$" > "$home/data/lifecycle/.lock/pid"
  start=$(date +%s)
  out=$(FM_LIFECYCLE_LOCK_WAIT=1 lc "$home" fm_lifecycle_task_spawned "$state" t1 0 2>&1)
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "a held lock must not fail the caller"
  assert_equals "" "$out" "a held lock must print nothing into the caller"
  [ "$elapsed" -le 5 ] || fail "a held lock should bound the wait, took ${elapsed}s"
  assert_grep "lock not acquired" "$home/data/lifecycle/emit-errors.log" \
    "a dropped event should record why in the feed's error log"
  assert_absent "$(feed_file "$home")" "no event may be written without the lock"
  pass "best effort: an unwritable feed or a held lock never fails, delays unboundedly, or prints into the caller"
}

# --- 3. transcription through the real wake drain ------------------------------------

run_drain() {  # <home>
  FM_HOME="$home" FM_ROOT_OVERRIDE='' "$DRAIN" 2>&1
}

test_drain_transcribes_status_and_decisions() {
  local home state status out before
  home=$(new_home drain)
  state="$home/state"
  status="$state/t1.status"
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1790000000.5.6" "window=fmses:fm-t1"
  printf '%s\n' \
    'working [at=1790000010]: setup done' \
    'needs-decision [key=api] [at=1790000020]: REST or gRPC?' \
    'blocked [key=creds] [at=1790000025]: need a token' \
    'an unstamped continuation line' > "$status"
  printf 'resolved [key=api] [at=179000003' >> "$status"
  out=$(run_drain "$home")
  assert_not_contains "$out" "events.v1" "the drain must not print anything about the feed"
  assert_not_contains "$out" "emit-errors" "the drain must not print anything about the feed"
  assert_feed_valid "$home" "drain pass 1"
  assert_equals 4 "$(count_type "$home" task.status t1)" "every complete status line should be transcribed once, the incomplete one held back"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.status")] |
    .[0].data == {verb:"working", key:null, until:null, note:"setup done", offset:0, stream:"s1790000000.5.6"}
    and .[0].at == 1790000010 and .[0].at_source == "stamp"
    and .[1].data.verb == "needs-decision" and .[1].data.key == "api"
    and .[3].data.verb == null and .[3].at == null and .[3].at_source == "unknown"
    and .[1].key == "status/t1/s1790000000.5.6/@\(.[1].data.offset)"' >/dev/null \
    || fail "status events did not carry verb, key, note, offset, and time source: $(feed_json "$home" | jq -c '.[] | select(.type == "task.status") | {key,at,at_source,data}')"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.decision") | .data] ==
    [{key:"api", change:"opened", verb:"needs-decision", closed_by:null, note:"REST or gRPC?"},
     {key:"creds", change:"opened", verb:"blocked", closed_by:null, note:"need a token"}]' >/dev/null \
    || fail "decision opens were not recorded from the drain's fold: $(feed_json "$home" | jq -c '.[] | select(.type == "task.decision") | .data')"
  # The held-back line completes; a later done on a ship closes every open
  # decision, exactly as the drain's own fold does.
  printf '0]: REST\n' >> "$status"
  printf '%s\n' 'done [at=1790000040]: ready in branch' >> "$status"
  run_drain "$home" >/dev/null
  assert_feed_valid "$home" "drain pass 2"
  assert_equals 6 "$(count_type "$home" task.status t1)" "the completed line and the next one should each be transcribed once"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.decision" and .data.change == "closed") | .data] ==
    [{key:"api", change:"closed", verb:"needs-decision", closed_by:"resolved", note:null},
     {key:"creds", change:"closed", verb:"blocked", closed_by:"terminal", note:null}]' >/dev/null \
    || fail "decision closes were not recorded: $(feed_json "$home" | jq -c '.[] | select(.type == "task.decision") | .data')"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.status")][4] |
    .data.verb == "resolved" and .at == 1790000030' >/dev/null \
    || fail "the completed line was not transcribed whole"
  before=$(cksum < "$(feed_file "$home")")
  run_drain "$home" >/dev/null
  assert_equals "$before" "$(cksum < "$(feed_file "$home")")" "a drain with no new status bytes must record nothing"
  pass "drain: status lines and the drain's own decision fold are transcribed once, incomplete lines only once they end"
}

test_chunked_and_replaced_status_logs() {
  local home state status i keys
  home=$(new_home chunks)
  state="$home/state"
  status="$state/t1.status"
  fm_write_meta "$state/t1.meta" "kind=scout" "spawn_gen=s1790000000.7.8"
  : > "$status"
  for i in 1 2 3 4 5 6 7; do printf 'working [at=17900001%02d]: step %s\n' "$i" "$i" >> "$status"; done
  FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_LIFECYCLE_TRANSCRIBE_CHUNK=2 "$DRAIN" >/dev/null 2>&1
  assert_feed_valid "$home" "chunked"
  assert_equals 7 "$(count_type "$home" task.status t1)" "a chunked pass should still transcribe every line exactly once"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.status") | .data.note] ==
    ["step 1","step 2","step 3","step 4","step 5","step 6","step 7"]' >/dev/null \
    || fail "chunked transcription lost or reordered lines"
  # A replaced status file (new identity) is a new stream: its lines are
  # recorded under distinct keys rather than dropped as already seen.
  rm -f "$status"
  printf '%s\n' 'working [at=1790000200]: fresh file' > "$status"
  run_drain "$home" >/dev/null
  assert_feed_valid "$home" "replaced"
  assert_equals 8 "$(count_type "$home" task.status t1)" "the replaced file's line should be recorded"
  keys=$(feed_json "$home" | jq -r '[.[] | select(.type == "task.status")][-1].key')
  case "$keys" in
    status/t1/s1790000000.7.8~*/@0) ;;
    *) fail "a replaced status file should be keyed under a distinct stream, got $keys" ;;
  esac
  pass "drain: chunked passes lose nothing, and a replaced status log is keyed apart from its predecessor"
}

# A task id reused after teardown, spawned again before the old cursor was
# swept, must start a fresh stream rather than inherit the old one's offset.
test_reused_task_id_starts_fresh() {
  local home state
  home=$(new_home reuse)
  state="$home/state"
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1790000000.1.1"
  lc "$home" fm_lifecycle_task_spawned "$state" t1 0
  printf '%s\n' 'working [at=1790000010]: first life' 'working [at=1790000011]: still first' > "$state/t1.status"
  run_drain "$home" >/dev/null
  lc "$home" fm_lifecycle_task_torn_down "$state" t1 0 remove "" ""
  rm -f "$state/t1.status" "$state/t1.meta"
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1790000500.2.2"
  printf '%s\n' 'working [at=1790000510]: second life' > "$state/t1.status"
  lc "$home" fm_lifecycle_task_spawned "$state" t1 0
  run_drain "$home" >/dev/null
  assert_feed_valid "$home" "reused id"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.status")][-1] |
    .key == "status/t1/s1790000500.2.2/@0" and .task.spawn_gen == "s1790000500.2.2" and .data.note == "second life"' >/dev/null \
    || fail "a reused task id should start a fresh stream: $(feed_json "$home" | jq -c '.[] | select(.type == "task.status") | {key,data}')"
  pass "drain: a task id reused after teardown starts a fresh stream"
}

# --- 4. the emit sites, end to end on one task ---------------------------------------------

# A session-provider stub modelled on tests/fm-control-relaunch.test.sh: the
# pane's current command lives in $D/command, a launch-brief literal starts the
# harness named in $D/becomes, and new-window adds to the session inventory.
make_tmux_stub() {  # <case-dir>
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
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fmses\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window)
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  # Teardown's landed-work check stays hermetic: no PR exists and no pipeline runs.
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: run-step · fake'
SH
  chmod +x "$fb/gh-axi" "$fb/gh" "$fb/no-mistakes" "$fb/fm-crew-state.sh"
}

in_case() {  # <case-dir> <command> [args...]
  local dir=$1
  shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u FM_BACKEND \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE='' FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' TMUX="fake,1,0" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 "$@" 2>&1
}

test_emit_sites_end_to_end() {
  local dir home state id brief out gen1 gen2 rec rec2 pid i watch_out
  dir="$TMP_ROOT/e2e"
  home="$dir/home"
  state="$home/state"
  id=e2e1
  mkdir -p "$state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$state/.last-watcher-beat"
  : > "$dir/fake/literal"
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_tmux_stub "$dir"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null || fail "could not scaffold the scout brief"
  brief="$home/data/$id/brief.md"
  sed 's/{TASK}/Exercise the lifecycle feed./; s/{FIRSTMATE_SPEC}/Record every transition./' "$brief" > "$brief.filled"
  mv "$brief.filled" "$brief"

  # Fresh spawn.
  out=$(in_case "$dir" "$SPAWN" "$id" "$dir/proj" --scout) || fail "the scout spawn should succeed: $out"
  gen1=$(sed -n 's/^spawn_gen=//p' "$state/$id.meta" | tail -1)
  [ -n "$gen1" ] || fail "the spawn recorded no spawn_gen"
  feed_json "$home" | jq -e --arg g "$gen1" '[.[] | select(.type == "task.spawned")] |
    length == 1 and .[0].task.spawn_gen == $g and .[0].data.kind == "scout"
    and .[0].data.relaunch == false and .[0].data.harness == "claude"' >/dev/null \
    || fail "fm-spawn did not record task.spawned: $(feed_json "$home" | jq -c '.[]')"

  # Promotion.
  printf '%s\n' 'working [at=1790000300]: investigating' >> "$state/$id.status"
  out=$(in_case "$dir" "$PROMOTE" "$id" --mode local-only --yolo off) || fail "promotion should succeed: $out"
  feed_json "$home" | jq -e '[.[] | select(.type == "task.reclassified")] | length == 1 and
    .[0].data.to == {kind:"ship", mode:"local-only", yolo:"off"}' >/dev/null \
    || fail "fm-promote did not record task.reclassified"
  feed_json "$home" | jq -e '(map(select(.type == "task.status")) | .[0].seq) < (map(select(.type == "task.reclassified")) | .[0].seq)' >/dev/null \
    || fail "promotion should transcribe earlier status lines before its own event"

  # A steer through the inbox writer, then the watcher's acknowledgement scan.
  rec=$(FM_HOME="$home" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" "$3" "private steer text"' \
    _ "$ROOT" "$state" "$id") || fail "the steer could not be written"
  feed_json "$home" | jq -e --arg m "$(basename "$rec" .msg)" '[.[] | select(.type == "task.steered")] | length == 1 and
    .[0].data.msg == $m and .[0].data.delivery == "ringing" and .[0].data.bytes == 18
    and (.[0].data.sha256 | test("^[0-9a-f]{64}$")) and .[0].at_source == "inbox"' >/dev/null \
    || fail "the inbox writer did not record task.steered: $(feed_json "$home" | jq -c '.[] | select(.type == "task.steered")')"
  assert_no_grep "private steer text" "$(feed_file "$home")" "a steer body must never reach the feed"
  mv "$rec" "$state/$id.inbox/handled/"
  watch_out="$dir/watch.out"
  in_case "$dir" env FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCHER" > "$watch_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(count_type "$home" task.steer_acked)" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_equals 1 "$(count_type "$home" task.steer_acked)" "the watcher did not record the acknowledgement: $(cat "$watch_out")"

  # Relaunch: the predecessor's untranscribed lines stay attributed to it.
  printf '%s\n' 'working [at=1790000400]: before the relaunch' >> "$state/$id.status"
  printf 'zsh' > "$dir/fake/command"
  out=$(in_case "$dir" "$SPAWN" "$id" --relaunch) || fail "the relaunch should succeed: $out"
  gen2=$(sed -n 's/^spawn_gen=//p' "$state/$id.meta" | tail -1)
  [ "$gen2" != "$gen1" ] || fail "the relaunch did not publish a new spawn_gen"
  feed_json "$home" | jq -e --arg g1 "$gen1" --arg g2 "$gen2" '
    ([.[] | select(.type == "task.spawned")][1] | .task.spawn_gen == $g2 and .data.relaunch == true and .data.previous_spawn_gen == $g1)
    and ([.[] | select(.type == "task.status" and .data.note == "before the relaunch")][0].task.spawn_gen == $g1)' >/dev/null \
    || fail "the relaunch was not recorded with its predecessor: $(feed_json "$home" | jq -c '.[] | select(.type == "task.spawned" or .type == "task.status") | {type,task,data}')"

  # Teardown: its flush records the unterminated last line and the pending
  # acknowledgement before task.torn_down, then the task's history is deleted.
  rec2=$(FM_HOME="$home" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" "$3" "second"' \
    _ "$ROOT" "$state" "$id") || fail "the second steer could not be written"
  mv "$rec2" "$state/$id.inbox/handled/"
  printf '%s\n' 'done [at=1790000500]: ready in branch' >> "$state/$id.status"
  printf 'a final line with no newline' >> "$state/$id.status"
  printf 'zsh' > "$dir/fake/command"
  out=$(in_case "$dir" "$TEARDOWN" "$id") || fail "teardown should succeed: $out"
  assert_absent "$state/$id.status" "teardown should still delete the status log"
  assert_absent "$state/$id.meta" "teardown should still delete the task record"
  run_drain "$home" >/dev/null
  assert_absent "$state/.$id.lifecycle-cursor" "the next drain should retire the torn-down task's cursor"
  assert_feed_valid "$home" "end to end"
  feed_json "$home" | jq -e --arg g2 "$gen2" '
    (.[-1] | .type == "task.torn_down" and .task.spawn_gen == $g2
      and .data == {transition:"remove", outcome:"landed", forced:false, kind:"ship", report:null, pr:null})
    and (.[-2].type == "task.steer_acked")
    and ([.[] | select(.type == "task.status")][-1] | .data.note == "a final line with no newline" and .at_source == "unknown")
    and ([.[] | select(.type == "task.status")][-2] | .data.verb == "done")
    and ([.[] | select(.type == "task.steered")] | length == 2)
    and ([.[] | select(.type == "task.steer_acked")] | length == 2)' >/dev/null \
    || fail "teardown did not flush the tail and record task.torn_down last: $(feed_json "$home" | jq -c '.[-4:][] | {type,data}')"
  pass "emit sites: spawn, promotion, steer, watcher acknowledgement, relaunch, and teardown's final flush are all recorded"
}

# --- 5. discovery ------------------------------------------------------------------

test_snapshot_carries_the_lifecycle_pointer() {
  local home child out
  home=$(new_home snapshot)
  child="$TMP_ROOT/snapshot/child"
  mkdir -p "$child/data/lifecycle"
  printf 'fmh_c0ffee\n' > "$child/data/lifecycle/home-id"
  printf '7\n' > "$child/data/lifecycle/head"
  fm_write_meta "$home/state/t1.meta" "kind=ship" "spawn_gen=s1.1.1" "window=fmses:fm-t1"
  lc "$home" fm_lifecycle_task_spawned "$home/state" t1 0
  fm_write_meta "$home/state/sm1.meta" "kind=secondmate" "home=$child" "window=fmses:fm-sm1"
  fm_write_meta "$home/state/sm2.meta" "kind=secondmate" "home=/remote/home" "remote_host=box"
  out=$(lc "$home" fm_lifecycle_snapshot_json "$home/state")
  printf '%s' "$out" | jq -e --arg p "$(feed_file "$home")" --arg id "$(cat "$home/data/lifecycle/home-id")" \
    --arg cp "$child/data/lifecycle/events.v1.jsonl" '
    .schema == "fm-lifecycle.v1" and .path == $p and .id == $id and .present == true and .head_seq == 2
    and .homes == [{id:"fmh_c0ffee", task:"sm1", path:$cp, head_seq:7, remote:false},
                   {id:null, task:"sm2", path:null, head_seq:null, remote:true}]' >/dev/null \
    || fail "the lifecycle pointer did not describe this home and its secondmates: $out"
  rm -f "$home/state/sm1.meta" "$home/state/sm2.meta"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_CREW_STATE_BIN=/usr/bin/true "$SNAPSHOT" --json 2>/dev/null) \
    || fail "the fleet snapshot failed with a lifecycle feed present"
  printf '%s' "$out" | jq -e --arg p "$(feed_file "$home")" \
    '.schema == "fm-fleet-snapshot.v1" and .lifecycle.schema == "fm-lifecycle.v1" and .lifecycle.path == $p and .lifecycle.head_seq == 2' >/dev/null \
    || fail "fm-fleet-snapshot.v1 did not carry the lifecycle pointer: $(printf '%s' "$out" | jq -c '.lifecycle')"
  pass "discovery: the fleet snapshot points at this home's feed and each secondmate's"
}

# The snapshot's last status line, as "<lifecycle_key>\t<stream>\t<offset>\t<raw>".
snapshot_status_id() {  # <home> <task>
  FM_HOME="$1" FM_ROOT_OVERRIDE='' FM_CREW_STATE_BIN=/usr/bin/true "$SNAPSHOT" --json 2>/dev/null \
    | jq -r --arg id "$2" '.tasks[] | select(.id == $id) | .paths.status_log.last_event
      | [(.lifecycle_key // "null"), (.stream // "null"), (.offset // "null" | tostring), .raw] | @tsv'
}

# 0 when the feed holds exactly one task.status event under <key>, for <offset>
# and <stream>, attributed to spawn_gen <gen>.
feed_has_status_key() {  # <home> <key> <stream> <offset> <gen>
  feed_json "$1" | jq -e --arg k "$2" --arg s "$3" --argjson o "$4" --arg g "$5" '
    [.[] | select(.type == "task.status" and .key == $k)]
    | length == 1 and .[0].data.stream == $s and .[0].data.offset == $o and .[0].task.spawn_gen == $g' >/dev/null
}

test_snapshot_status_line_matches_its_feed_event() {
  local home state status id k1 k2 k3 k4 k5 again stream off rest
  home=$(new_home status-id)
  state="$home/state"
  status="$state/t1.status"
  fm_write_meta "$state/t1.meta" "kind=ship" "spawn_gen=s1790000000.1.1" "window=fmses:fm-t1"
  lc "$home" fm_lifecycle_task_spawned "$state" t1 0

  # A stamped line, read before the drain has transcribed anything.
  printf '%s\n' 'working [at=1790000010]: setup done' > "$status"
  id=$(snapshot_status_id "$home" t1)
  k1=${id%%$'\t'*}
  assert_equals "status/t1/s1790000000.1.1/@0" "$k1" "a stamped line should carry the feed key before any drain: $id"
  again=$(snapshot_status_id "$home" t1)
  assert_equals "$id" "$again" "repeated snapshots should publish the same identity"
  run_drain "$home" >/dev/null
  feed_has_status_key "$home" "$k1" s1790000000.1.1 0 s1790000000.1.1 \
    || fail "the feed does not hold the stamped line under the snapshot's key: $(feed_json "$home" | jq -c '.[] | select(.type == "task.status") | {key,data}')"
  assert_equals "$id" "$(snapshot_status_id "$home" t1)" "transcription must not change the published identity"

  # An unstamped line, then the identical line again at a later offset.
  printf '%s\n' 'working: no stamp here' >> "$status"
  id=$(snapshot_status_id "$home" t1)
  k2=${id%%$'\t'*}
  rest=${id#*$'\t'}; stream=${rest%%$'\t'*}; rest=${rest#*$'\t'}; off=${rest%%$'\t'*}
  assert_equals "status/t1/s1790000000.1.1/@36" "$k2" "an unstamped line should carry its byte-offset key: $id"
  printf '%s\n' 'working: no stamp here' >> "$status"
  id=$(snapshot_status_id "$home" t1)
  k3=${id%%$'\t'*}
  assert_equals "status/t1/s1790000000.1.1/@59" "$k3" "a repeated identical line should get its own key: $id"
  assert_equals "$(snapshot_status_id "$home" t1)" "$id" "the repeated line's identity should be stable"
  run_drain "$home" >/dev/null
  feed_has_status_key "$home" "$k2" "$stream" "$off" s1790000000.1.1 \
    || fail "the feed does not hold the unstamped line under the snapshot's key $k2"
  feed_has_status_key "$home" "$k3" "$stream" 59 s1790000000.1.1 \
    || fail "the feed does not hold the repeated line under the snapshot's key $k3"
  feed_json "$home" | jq -e --arg a "$k2" --arg b "$k3" '
    [.[] | select(.type == "task.status" and (.key == $a or .key == $b))]
    | length == 2 and .[0].data.note == .[1].data.note and .[0].at == null and .[1].at == null' >/dev/null \
    || fail "two identical unstamped lines should be two feed events told apart only by key"

  # A new attempt: the line written between the relaunch's metadata commit and
  # its feed record is attributed to the predecessor, under the key the
  # snapshot published in that window.
  fm_write_meta "$state/t2.meta" "kind=ship" "spawn_gen=s1790000100.2.1" "window=fmses:fm-t2"
  lc "$home" fm_lifecycle_task_spawned "$state" t2 0
  printf '%s\n' 'working: first attempt' > "$state/t2.status"
  fm_write_meta "$state/t2.meta" "kind=ship" "spawn_gen=s1790000200.2.2" "window=fmses:fm-t2"
  id=$(snapshot_status_id "$home" t2)
  k4=${id%%$'\t'*}
  assert_equals "status/t2/s1790000100.2.1/@0" "$k4" "mid-relaunch, the line should keep its predecessor's stream: $id"
  lc "$home" fm_lifecycle_task_spawned "$state" t2 1
  feed_has_status_key "$home" "$k4" s1790000100.2.1 0 s1790000100.2.1 \
    || fail "the relaunch flush did not record the line under the snapshot's key: $(feed_json "$home" | jq -c '.[] | select(.type == "task.status" and .task.id == "t2") | {key,task,data}')"
  printf '%s\n' 'working: second attempt' >> "$state/t2.status"
  id=$(snapshot_status_id "$home" t2)
  k5=${id%%$'\t'*}
  assert_equals "status/t2/s1790000100.2.1/@23" "$k5" "after a relaunch the log keeps its stream and keys by offset: $id"
  run_drain "$home" >/dev/null
  feed_has_status_key "$home" "$k5" s1790000100.2.1 23 s1790000200.2.2 \
    || fail "the new attempt's line is not in the feed under the snapshot's key $k5"

  # A replaced status log starts a new stream on both sides.
  rm -f "$status"
  printf '%s\n' 'working: replaced log' > "$status"
  id=$(snapshot_status_id "$home" t1)
  k1=${id%%$'\t'*}
  case "$k1" in
    status/t1/s1790000000.1.1~*/@0) ;;
    *) fail "a replaced log should be keyed under a suffixed stream: $id" ;;
  esac
  rest=${id#*$'\t'}; stream=${rest%%$'\t'*}
  run_drain "$home" >/dev/null
  feed_has_status_key "$home" "$k1" "$stream" 0 s1790000000.1.1 \
    || fail "the replaced log's line is not in the feed under the snapshot's key $k1"
  assert_feed_valid "$home" "status identity"

  # Best effort: an unreadable cursor or a disabled feed never fails the
  # snapshot, and a line whose identity cannot be sampled publishes null.
  printf 'garbage\n' > "$state/.t1.lifecycle-cursor"
  FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_CREW_STATE_BIN=/usr/bin/true "$SNAPSHOT" --json >/dev/null 2>&1 \
    || fail "a corrupt lifecycle cursor must not fail the snapshot"
  FM_LIFECYCLE=off FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_CREW_STATE_BIN=/usr/bin/true "$SNAPSHOT" --json 2>/dev/null \
    | jq -e '.lifecycle == null and all(.tasks[]; .paths.status_log.last_event | has("lifecycle_key"))' >/dev/null \
    || fail "a disabled feed must not fail the snapshot or drop the identity fields"
  : > "$state/t2.status"
  FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_CREW_STATE_BIN=/usr/bin/true "$SNAPSHOT" --json 2>/dev/null \
    | jq -e '.tasks[] | select(.id == "t2") | .paths.status_log.last_event
      | .raw == "" and .offset == null and .stream == null and .lifecycle_key == null' >/dev/null \
    || fail "an empty status log should publish a null identity"
  pass "identity: the snapshot's last status line carries the exact feed key, stamped or not, repeated, relaunched, or replaced"
}

# --- 6. backfill --------------------------------------------------------------------

test_backfill_is_idempotent() {
  local home state out before rec
  home=$(new_home backfill)
  state="$home/state"
  fm_write_meta "$state/t1.meta" "kind=ship" "mode=direct-PR" "harness=codex" \
    "spawn_gen=s1790000000.3.4" "window=fmses:fm-t1" "project=/p"
  printf '%s\n' 'working [at=1790000010]: a' 'needs-decision [at=1790000020]: pick one' > "$state/t1.status"
  rec=$(FM_HOME="$home" FM_LIFECYCLE=off bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "first"' _ "$ROOT" "$state")
  mv "$rec" "$state/t1.inbox/handled/"
  FM_HOME="$home" FM_LIFECYCLE=off bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "second" fire-and-forget' _ "$ROOT" "$state" >/dev/null
  assert_absent "$home/data/lifecycle" "the fixture history must predate the feed"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' "$LIFECYCLE" backfill 2>&1) || fail "backfill failed: $out"
  assert_contains "$out" "backfill recorded 7 event(s)" "backfill should report what it recorded"
  assert_feed_valid "$home" "backfill"
  feed_json "$home" | jq -e '
    ([.[] | select(.type != "feed.started")] | all(.backfill == true))
    and ([.[] | select(.type == "task.spawned")][0] | .at == 1790000000 and .at_source == "firstmate" and .data.relaunch == null and .data.harness == "codex")
    and ([.[] | select(.type == "task.status")] | length == 2)
    and ([.[] | select(.type == "task.decision")][0].data == {key:"default", change:"opened", verb:"needs-decision", closed_by:null, note:"pick one"})
    and ([.[] | select(.type == "task.steered") | .data.delivery] | sort == ["fire-and-forget","ringing"])
    and ([.[] | select(.type == "task.steer_acked")] | length == 1 and .[0].at == null and .[0].at_source == "unknown")
    and (.[-1].type == "feed.backfilled" and .[-1].data.tasks == ["t1"] and .[-1].data.events == 7)' >/dev/null \
    || fail "backfill did not replay the live task: $(feed_json "$home" | jq -c '.[] | {type,at,at_source,backfill,data}')"

  before=$(cksum < "$(feed_file "$home")")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' "$LIFECYCLE" backfill 2>&1) || fail "a second backfill failed: $out"
  assert_contains "$out" "backfill recorded 0 event(s)" "a second backfill should record nothing"
  assert_equals "$before" "$(cksum < "$(feed_file "$home")")" "a second backfill must leave the feed unchanged"
  run_drain "$home" >/dev/null
  assert_equals "$before" "$(cksum < "$(feed_file "$home")")" "the drain after a backfill must not re-record its lines"
  printf '%s\n' 'working [at=1790000030]: after backfill' >> "$state/t1.status"
  run_drain "$home" >/dev/null
  assert_feed_valid "$home" "after backfill"
  feed_json "$home" | jq -e '.[-1] | .type == "task.status" and .backfill == false and .data.note == "after backfill"' >/dev/null \
    || fail "live transcription should resume after a backfill without replaying it"
  pass "backfill: live tasks are replayed once, a second run records nothing, and live transcription resumes cleanly"
}

test_writer_envelope_and_gap_free_seq
test_writer_fences_a_torn_line_and_rotates
test_disabled_or_foreign_state_emits_nothing
test_emit_never_disturbs_the_caller
test_drain_transcribes_status_and_decisions
test_chunked_and_replaced_status_logs
test_reused_task_id_starts_fresh
test_emit_sites_end_to_end
test_snapshot_carries_the_lifecycle_pointer
test_snapshot_status_line_matches_its_feed_event
test_backfill_is_idempotent
