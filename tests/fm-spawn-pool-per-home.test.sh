#!/usr/bin/env bash
# Regression test: every firstmate home allocates task worktrees from its own
# clone, even when another home holds a clone of the same repository.
#
# Treehouse names a pool by repository, not by the clone that invokes it, so on
# one shared root every clone of a repository lands in one pool whose slots are
# worktrees of whichever clone created them. A secondmate home spawning there
# was handed the primary's slots, and bin/fm-claude-trust.sh then rightly
# refused every claude worker because the worktree was not of the spawning
# project. bin/fm-spawn.sh now sends each secondmate home's own pool root
# (fm_treehouse_home_pool_root in bin/fm-wake-lib.sh) and refuses a worktree of
# any other clone. That root sits outside every firstmate home, so no worker's
# directory ancestry reaches the home's CLAUDE.md or supervisor AGENTS.md; the
# pre-move in-home pool is drained without losing work, and retirement cleans
# both pools.
#
# The fake treehouse below reproduces the pooling behavior that matters: the
# pool path is <root>/.treehouse/<repo>-<origin hash>, the root is the LAST
# --root flag, else TREEHOUSE_ROOT, else $HOME (a wrapper-injected leading
# --root therefore loses to a later one), a new slot is created from the
# invoking clone, and a bulk destroy removes only idle, clean, landed slots. The fake tmux runs every line spawn types into the pane from
# the pane's current directory, so the worktree recorded is the one the typed
# command really produced.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-per-home)

make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
pane=${FM_FAKE_PANE_FILE:?FM_FAKE_PANE_FILE unset}
case "$*" in
  *"#{pane_current_path}"*) cat "$pane" 2>/dev/null; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  new-window|new-session)
    prev=
    for a in "$@"; do
      [ "$prev" != "-c" ] || printf '%s\n' "$a" > "$pane"
      prev=$a
    done
    exit 0
    ;;
  send-keys)
    # Only whole typed lines (text then Enter) are commands; literal sends
    # (-l) are the harness launch, which this suite never needs to run.
    case " $* " in *" -l "*) exit 0 ;; esac
    text=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        Enter) ;;
        *) text=$1 ;;
      esac
      shift
    done
    case "$text" in
      treehouse*|"cd -- "*)
        printf '%s\n' "$text" >> "${FM_FAKE_TYPED_LOG:-/dev/null}"
        cwd=$(cat "$pane")
        out=$(cd "$cwd" && eval "$text") || exit 0
        [ -z "$out" ] || printf '%s\n' "$out" > "$pane"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
root=${TREEHOUSE_ROOT:-${HOME:?}}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    *) break ;;
  esac
done
cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  get)
    top=$(git rev-parse --show-toplevel) || exit 1
    name=$(basename "$top")
    origin=$(git -C "$top" remote get-url origin)
    pool="$root/.treehouse/$name-$(printf '%s' "$origin" | git hash-object --stdin | cut -c1-6)"
    mkdir -p "$pool"
    [ -f "$pool/treehouse-state.json" ] || printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
    n=1
    while [ -d "$pool/$n" ]; do
      if [ ! -e "$pool/$n/.in-use" ]; then
        touch "$pool/$n/.in-use"
        printf '%s\n' "$pool/$n/$name"
        exit 0
      fi
      n=$((n + 1))
    done
    mkdir -p "$pool/$n"
    git -C "$top" worktree add --quiet --detach "$pool/$n/$name" >/dev/null 2>&1 || exit 1
    touch "$pool/$n/.in-use"
    printf '%s\n' "$pool/$n/$name"
    ;;
  return)
    [ "${1:-}" != --force ] || shift
    slot=$(cd "$1" && pwd -P) || exit 1
    rm -f "$(dirname "$slot")/.in-use"
    printf '%s\n' "$slot" >> "${FM_FAKE_RETURN_LOG:-/dev/null}"
    ;;
  destroy)
    # Destroy removes only disposable slots: idle, clean, and landed. A pool
    # takes --all; a single slot is named by its worktree.
    if [ "$*" = "$1 --all --yes" ]; then
      single=0 slots=$(ls -d "$1"/*/ 2>/dev/null)
    elif [ "$*" = "$1 --yes" ]; then
      single=1 slots=$(dirname "$1")
    else
      exit 2
    fi
    status=0
    for slot in $slots; do
      slot=${slot%/}
      wt=$(ls -d "$slot"/*/ 2>/dev/null | head -1)
      wt=${wt%/}
      if [ -e "$slot/.in-use" ]; then echo "skip in-use $slot" >&2; status=1; continue; fi
      if [ -z "$wt" ] || [ -n "$(git -C "$wt" status --porcelain)" ]; then echo "skip dirty $slot" >&2; status=1; continue; fi
      if [ -n "$(git -C "$wt" rev-list HEAD --not --remotes)" ]; then echo "skip unlanded $slot" >&2; status=1; continue; fi
      git -C "$wt" worktree remove --force "$wt" && rm -rf "$slot"
    done
    [ "$single" -eq 0 ] || exit "$status"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_test_fake_sleep_log "$fakebin"
  printf '%s\n' "$fakebin"
}

# One origin, a primary home and a secondmate home, each with its own clone of
# it under its own projects/, sharing one Treehouse default root. Each home
# carries the supervisor contract a real one does (CLAUDE.md importing
# AGENTS.md), which a worker must never be able to reach from its worktree.
CASE="$TMP_ROOT/case"
FAKEBIN=$(make_pool_fakebin "$CASE")
SHARED_ROOT="$CASE/shared-treehouse-root"
PRIMARY="$CASE/primary-home"
MATE="$CASE/mate-home"
# Secondmate pools live under the user's state dir, outside every home.
export XDG_STATE_HOME="$CASE/user-state"
fm_git_init_commit "$CASE/seed/app"
git clone --quiet --bare "$CASE/seed/app" "$CASE/app.git"

make_contract_home() {  # <home> [secondmate-id]
  fm_test_spawn_home "$1" claude
  printf '@AGENTS.md\n' > "$1/CLAUDE.md"
  printf '# supervisor contract\n' > "$1/AGENTS.md"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  git clone --quiet "file://$CASE/app.git" "$1/projects/app"
}
make_contract_home "$PRIMARY"
make_contract_home "$MATE" mate

common_dir() {
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  (cd "$d" && pwd -P)
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

run_pool_spawn() {  # <home> <id>
  local home=$1 id=$2
  fm_test_spawn_brief "$home" "$id"
  : > "$CASE/pane"
  : > "$CASE/sleeps.$id"
  FM_FAKE_PANE_FILE="$CASE/pane" FM_FAKE_TYPED_LOG="$CASE/typed.$id" FM_SLEEP_LOG="$CASE/sleeps.$id" \
    TREEHOUSE_ROOT="${POOL_ROOT:-$SHARED_ROOT}" FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "" "$FAKEBIN" "$id" "$home/projects/app" \
    --mode no-mistakes --yolo off
}

test_each_home_gets_a_worktree_of_its_own_clone() {
  local out status wt_primary wt_mate
  out=$(run_pool_spawn "$PRIMARY" pool-primary-z1)
  status=$?
  expect_code 0 "$status" "primary spawn should succeed"$'\n'"$out"
  wt_primary=$(meta_value "$PRIMARY/state/pool-primary-z1.meta" worktree)
  [ -n "$wt_primary" ] || fail "primary spawn recorded no worktree"$'\n'"$out"
  [ "$(common_dir "$wt_primary")" = "$(common_dir "$PRIMARY/projects/app")" ] ||
    fail "primary worktree $wt_primary is not a worktree of the primary's clone"
  case "$wt_primary" in "$SHARED_ROOT"/*) ;; *) fail "primary did not keep the configured default pool: $wt_primary" ;; esac
  [ "$(cat "$CASE/typed.pool-primary-z1")" = "treehouse get" ] ||
    fail "primary spawn should keep treehouse's configured default root, typed: $(cat "$CASE/typed.pool-primary-z1")"

  # The primary's slot is returned, so the shared pool now holds an available
  # slot of the primary's clone - exactly what a secondmate used to be handed.
  FM_FAKE_RETURN_LOG=/dev/null "$FAKEBIN/treehouse" return --force "$wt_primary"

  out=$(run_pool_spawn "$MATE" pool-mate-z1)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed with its own clone's worktree (the claude trust check passes on its merits)"$'\n'"$out"
  wt_mate=$(meta_value "$MATE/state/pool-mate-z1.meta" worktree)
  [ -n "$wt_mate" ] || fail "secondmate spawn recorded no worktree"$'\n'"$out"
  [ "$(common_dir "$wt_mate")" = "$(common_dir "$MATE/projects/app")" ] ||
    fail "secondmate worktree $wt_mate is not a worktree of the secondmate's own clone"
  case "$wt_mate" in
    "$(cd "$XDG_STATE_HOME" && pwd -P)/firstmate/treehouse-pools/mate-"*) ;;
    *) fail "secondmate worktree $wt_mate is not in the secondmate's own pool" ;;
  esac
  [ "$(common_dir "$wt_mate")" != "$(common_dir "$wt_primary")" ] ||
    fail "the two homes' worktrees share a clone"
  pass "a primary and a secondmate with clones of one repository each get a worktree of their own clone"
}

# A treehouse that still hands out another clone's slot (for example a wrapper
# overriding the root after firstmate's flag) must be refused with the owning
# clone named, never launched in.
test_foreign_clone_worktree_is_refused_loudly() {
  local out status foreign
  foreign="$CASE/foreign-slot"
  git -C "$PRIMARY/projects/app" worktree add --quiet --detach "$foreign"
  cat > "$CASE/fakebin/treehouse-foreign" <<SH
#!/usr/bin/env bash
printf '%s\n' '$foreign'
SH
  chmod +x "$CASE/fakebin/treehouse-foreign"
  mv "$CASE/fakebin/treehouse" "$CASE/fakebin/treehouse-real"
  mv "$CASE/fakebin/treehouse-foreign" "$CASE/fakebin/treehouse"
  out=$(run_pool_spawn "$MATE" pool-mate-z2)
  status=$?
  mv "$CASE/fakebin/treehouse" "$CASE/fakebin/treehouse-foreign"
  mv "$CASE/fakebin/treehouse-real" "$CASE/fakebin/treehouse"
  [ "$status" -ne 0 ] || fail "spawn launched in another clone's worktree"$'\n'"$out"
  assert_contains "$out" "worktree of another clone" "refusal does not name the foreign clone"
  assert_contains "$out" "$(common_dir "$PRIMARY/projects/app")" "refusal does not name the owning clone's git dir"
  [ ! -e "$MATE/state/pool-mate-z2.meta" ] || fail "refused spawn left a task record"
  pass "a worktree of another home's clone is refused with its owner named"
}

test_unreadable_secondmate_marker_fails_loudly() {
  local out status home="$CASE/broken-home"
  fm_test_spawn_home "$home" claude
  mkdir "$home/.fm-secondmate-home"
  git clone --quiet "file://$CASE/app.git" "$home/projects/app"
  out=$(run_pool_spawn "$home" pool-broken-z3)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded with an unreadable secondmate marker"$'\n'"$out"
  assert_contains "$out" "could not resolve this home's own Treehouse pool root" \
    "refusal does not name the pool-root failure"
  [ ! -s "$CASE/typed.pool-broken-z3" ] || fail "spawn typed a treehouse command despite an unresolvable pool root"
  pass "a home that cannot resolve its own pool fails the spawn before touching any pool"
}

test_teardown_returns_the_slot_to_the_pool_it_came_from() {
  local out status wt
  wt=$(meta_value "$MATE/state/pool-mate-z1.meta" worktree)
  [ -n "$wt" ] || fail "no secondmate task to tear down"
  : > "$CASE/returns"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$MATE" HOME="$MATE/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_PROJECTS_OVERRIDE="$MATE/projects" FM_CONFIG_OVERRIDE="$MATE/config" \
    FM_FAKE_PANE_FILE="$CASE/pane" FM_FAKE_RETURN_LOG="$CASE/returns" FM_BACKEND=tmux TMUX=fake,1,0 \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" pool-mate-z1 2>&1)
  status=$?
  expect_code 0 "$status" "secondmate teardown should succeed"$'\n'"$out"
  assert_grep "$(cd "$wt" && pwd -P)" "$CASE/returns" "teardown did not return the secondmate's slot"$'\n'"$out"
  [ ! -e "$(dirname "$wt")/.in-use" ] || fail "secondmate slot still in use in its own pool after teardown"
  pass "teardown returns a secondmate task's slot to that home's own pool"
}

# Leave <count> available slots in <root>'s pool, each a worktree of the
# secondmate's clone, as a shared pool used before per-home pools would hold.
seed_foreign_slots() {  # <root> <count>
  local root=$1 count=$2 i slot
  for i in $(seq 1 "$count"); do
    slot=$(cd "$MATE/projects/app" && TREEHOUSE_ROOT="$root" "$FAKEBIN/treehouse" get) || return 1
  done
  for i in $(seq 1 "$count"); do
    rm -f "$(dirname "$(dirname "$slot")")/$i/.in-use"
  done
}

test_primary_skips_a_leftover_foreign_slot() {
  local out status root="$CASE/leftover-root" wt foreign polls
  seed_foreign_slots "$root" 1 || fail "could not seed a foreign slot"
  foreign=$(cd "$root"/.treehouse/app-*/1/app && pwd -P)
  out=$(POOL_ROOT="$root" run_pool_spawn "$PRIMARY" pool-primary-z4)
  status=$?
  expect_code 0 "$status" "primary spawn should skip the leftover foreign slot"$'\n'"$out"
  wt=$(meta_value "$PRIMARY/state/pool-primary-z4.meta" worktree)
  [ "$(common_dir "$wt")" = "$(common_dir "$PRIMARY/projects/app")" ] ||
    fail "primary landed in $wt, not a worktree of its own clone"
  [ "$(cd "$wt" && pwd -P)" != "$foreign" ] || fail "primary adopted the foreign slot"
  polls=$(grep -c '^1$' "$CASE/sleeps.pool-primary-z4")
  [ "$polls" -lt 10 ] || fail "primary waited $polls polls before skipping the foreign slot"
  [ "$(common_dir "$foreign")" = "$(common_dir "$MATE/projects/app")" ] ||
    fail "the foreign slot was not left a worktree of its own clone"
  [ -e "$(dirname "$foreign")/.in-use" ] || fail "the foreign slot was released instead of left held"
  [ "$(sed -n 2p "$CASE/typed.pool-primary-z4")" = "cd -- '$PRIMARY/projects/app' && treehouse get" ] ||
    fail "retry did not rerun the same get from the spawning project: $(cat "$CASE/typed.pool-primary-z4")"
  pass "a primary spawn handed a leftover foreign slot skips it at once and lands in its own clone's slot"
}

test_only_foreign_slots_fail_naming_them() {
  local out status root="$CASE/all-foreign-root" i slot
  seed_foreign_slots "$root" 6 || fail "could not seed foreign slots"
  out=$(POOL_ROOT="$root" run_pool_spawn "$PRIMARY" pool-primary-z5)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded with only foreign slots available"$'\n'"$out"
  assert_contains "$out" "kept handing out worktrees of another clone" "refusal does not explain the foreign slots"
  assert_contains "$out" "$(common_dir "$MATE/projects/app")" "refusal does not name the owning clone"
  for i in 1 2 3 4; do
    slot=$(cd "$root"/.treehouse/app-*/"$i"/app && pwd -P)
    assert_contains "$out" "$slot" "refusal does not name rejected slot $i"
    [ "$(common_dir "$slot")" = "$(common_dir "$MATE/projects/app")" ] || fail "foreign slot $i was altered"
  done
  for i in 5 6; do
    [ ! -e "$(dirname "$slot")/../$i/.in-use" ] || fail "spawn kept acquiring past its retry bound (slot $i)"
  done
  [ ! -e "$PRIMARY/state/pool-primary-z5.meta" ] || fail "refused spawn left a task record"
  pass "a spawn that is only ever handed foreign slots fails naming each one and its owner"
}

# The property the pool placement exists for: nothing above a secondmate's
# worker worktree is that home, or holds its CLAUDE.md or AGENTS.md.
test_secondmate_worker_cannot_reach_its_home_contract() {
  local wt dir mate_real case_real
  wt=$(meta_value "$MATE/state/pool-mate-z1.meta" worktree)
  [ -n "$wt" ] || fail "no secondmate worker worktree to inspect"
  wt=$(cd "$wt" && pwd -P)
  mate_real=$(cd "$MATE" && pwd -P)
  case_real=$(cd "$CASE" && pwd -P)
  dir=$(dirname "$wt")
  while :; do
    [ "$dir" != "$mate_real" ] || fail "secondmate worker $wt sits inside its home $mate_real"
    case "$dir" in
      "$case_real"|"$case_real"/*)
        [ ! -e "$dir/CLAUDE.md" ] && [ ! -e "$dir/AGENTS.md" ] ||
          fail "secondmate worker $wt has ancestor $dir holding supervisor instructions"
        ;;
    esac
    [ "$dir" != / ] || break
    dir=$(dirname "$dir")
  done
  [ ! -e "$MATE/state/treehouse-pool" ] || fail "secondmate spawn still created an in-home pool"
  pass "a secondmate's worker worktree has no ancestor holding that home's CLAUDE.md or AGENTS.md"
}

pool_root_of() {  # <worktree> -> <root> of <root>/.treehouse/<pool>/<slot>/<repo>
  dirname "$(dirname "$(dirname "$(dirname "$1")")")"
}

# Two secondmate homes holding clones of one repository, even under the same
# id, still get separate pools, each handing out worktrees of its own clone.
test_two_secondmate_homes_keep_separate_pools() {
  local out status other="$CASE/other-mate-home" wt_other wt_mate
  make_contract_home "$other" mate
  out=$(run_pool_spawn "$other" pool-other-z1)
  status=$?
  expect_code 0 "$status" "second secondmate spawn should succeed"$'\n'"$out"
  wt_other=$(meta_value "$other/state/pool-other-z1.meta" worktree)
  wt_mate=$(meta_value "$MATE/state/pool-mate-z1.meta" worktree)
  [ "$(common_dir "$wt_other")" = "$(common_dir "$other/projects/app")" ] ||
    fail "second secondmate worktree $wt_other is not of its own clone"
  [ "$(pool_root_of "$wt_other")" != "$(pool_root_of "$wt_mate")" ] ||
    fail "two secondmate homes drew from one pool root"
  pass "two secondmate homes with clones of one repository keep separate pools outside both homes"
}

# A pool root that would land under a firstmate home is refused before any
# Treehouse command is typed.
test_pool_root_under_a_home_is_refused() {
  local out status
  out=$(XDG_STATE_HOME="$MATE/user-state" run_pool_spawn "$MATE" pool-mate-z6)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn allocated from a pool root inside a firstmate home"$'\n'"$out"
  assert_contains "$out" "sits under firstmate home '$(cd "$MATE" && pwd -P)'" \
    "refusal does not name the home whose instructions workers would load"
  [ ! -s "$CASE/typed.pool-mate-z6" ] || fail "spawn typed a treehouse command toward a pool inside a home"
  [ ! -e "$MATE/state/pool-mate-z6.meta" ] || fail "refused spawn left a task record"
  pass "a pool root under a firstmate home refuses the spawn before touching any pool"
}

# Slots left in the pre-move in-home pool: disposable ones are removed at the
# next spawn, and one still in use is left intact and named.
test_legacy_in_home_pool_is_drained_without_losing_work() {
  local out status legacy="$MATE/state/treehouse-pool" free held wt
  free=$(cd "$MATE/projects/app" && TREEHOUSE_ROOT="$legacy" "$FAKEBIN/treehouse" get) || fail "could not seed a legacy slot"
  held=$(cd "$MATE/projects/app" && TREEHOUSE_ROOT="$legacy" "$FAKEBIN/treehouse" get) || fail "could not seed a legacy slot"
  rm -f "$(dirname "$free")/.in-use"
  out=$(run_pool_spawn "$MATE" pool-mate-z7)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed beside a legacy pool"$'\n'"$out"
  wt=$(meta_value "$MATE/state/pool-mate-z7.meta" worktree)
  case "$(cd "$wt" && pwd -P)" in "$(cd "$MATE" && pwd -P)"/*) fail "spawn still drew from the in-home pool: $wt" ;; esac
  [ ! -e "$free" ] || fail "a disposable legacy slot was left behind"
  [ -d "$held" ] && [ -e "$(dirname "$held")/.in-use" ] || fail "an in-use legacy slot was touched"
  assert_contains "$out" "$(dirname "$held")" "the kept legacy slot was not reported"
  rm -f "$(dirname "$held")/.in-use"
  out=$(run_pool_spawn "$MATE" pool-mate-z8)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed once the legacy slot is free"$'\n'"$out"
  [ ! -e "$legacy" ] || fail "an emptied legacy pool was not removed"
  pass "a legacy in-home pool loses only disposable slots and reports the ones it keeps"
}

# A legacy slot whose lease lapsed (say the tmux server restarted) but whose
# firstmate claim names a task still recorded in the home is kept, not handed to
# Treehouse's destroy, until that task's record is gone; a disposable sibling in
# the same pool is still removed.
test_legacy_drain_keeps_a_slot_claimed_by_a_live_task() {
  local out status legacy="$MATE/state/treehouse-pool" claimed sibling
  claimed=$(cd "$MATE/projects/app" && TREEHOUSE_ROOT="$legacy" "$FAKEBIN/treehouse" get) || fail "could not seed a legacy slot"
  sibling=$(cd "$MATE/projects/app" && TREEHOUSE_ROOT="$legacy" "$FAKEBIN/treehouse" get) || fail "could not seed a legacy slot"
  rm -f "$(dirname "$claimed")/.in-use" "$(dirname "$sibling")/.in-use"
  printf 'task=legacy-live-z1\nhome=%s\n' "$MATE" > "$(dirname "$claimed")/.fm-slot-owner"
  printf 'worktree=%s\n' "$claimed" > "$MATE/state/legacy-live-z1.meta"
  out=$(run_pool_spawn "$MATE" pool-mate-z9)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed beside a claimed legacy slot"$'\n'"$out"
  [ -d "$claimed" ] || fail "the drain destroyed a legacy slot claimed by a live task"
  assert_contains "$out" "$(dirname "$claimed") (claimed by task legacy-live-z1)" "the claimed legacy slot was not reported as kept by its claim"
  [ ! -e "$sibling" ] || fail "a disposable sibling of a claimed legacy slot was left behind"
  case "$out" in *"$(dirname "$sibling")"*) fail "the removed disposable sibling was reported as kept"$'\n'"$out" ;; esac
  rm -f "$MATE/state/legacy-live-z1.meta"
  out=$(run_pool_spawn "$MATE" pool-mate-z10)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed once the claiming task is gone"$'\n'"$out"
  [ ! -e "$legacy" ] || fail "a legacy slot whose claiming task is gone was not drained"
  pass "a legacy in-home pool keeps a slot claimed by a task the home still records"
}

retire_home() {  # <secondmate-id>
  FM_ROOT_OVERRIDE='' FM_HOME="$PRIMARY" HOME="$PRIMARY/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$PRIMARY/state" FM_DATA_OVERRIDE="$PRIMARY/data" \
    FM_PROJECTS_OVERRIDE="$PRIMARY/projects" FM_CONFIG_OVERRIDE="$PRIMARY/config" \
    FM_FAKE_PANE_FILE="$CASE/pane" FM_BACKEND=tmux TMUX=fake,1,0 \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$1" 2>&1
}

# Retiring a secondmate home cleans its pools wherever they live, and refuses
# while any slot still holds work, naming each such slot.
test_retirement_cleans_the_home_pool() {
  local out status home="$CASE/retiree-home" wt root legacy_slot
  make_contract_home "$home" retiree
  out=$(run_pool_spawn "$home" pool-retiree-z1)
  status=$?
  expect_code 0 "$status" "retiree spawn should succeed"$'\n'"$out"
  wt=$(meta_value "$home/state/pool-retiree-z1.meta" worktree)
  root=$(pool_root_of "$wt")
  FM_FAKE_RETURN_LOG=/dev/null "$FAKEBIN/treehouse" return --force "$wt"
  rm -rf "$home/state/pool-retiree-z1."* "$home/data/pool-retiree-z1"
  legacy_slot=$(cd "$home/projects/app" && TREEHOUSE_ROOT="$home/state/treehouse-pool" "$FAKEBIN/treehouse" get) ||
    fail "could not seed a legacy slot"
  printf 'unsaved\n' > "$wt/work.txt"
  cat > "$PRIMARY/state/retiree.meta" <<EOF
window=firstmate:fm-retiree
worktree=$home
project=$home
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$home
projects=app
EOF
  printf '%s\n' "- retiree - retiring domain (home: $home; scope: retiring domain; projects: app; added 2026-09-24)" \
    > "$PRIMARY/data/secondmates.md"
  out=$(retire_home retiree)
  status=$?
  [ "$status" -ne 0 ] || fail "retirement discarded pool slots holding work"$'\n'"$out"
  assert_contains "$out" "$(dirname "$legacy_slot")" "refusal does not name the in-use legacy slot"
  assert_contains "$out" "$(dirname "$wt")" "refusal does not name the slot with uncommitted work"
  [ -f "$wt/work.txt" ] || fail "retirement lost uncommitted work in a pool slot"
  [ -d "$legacy_slot" ] || fail "retirement removed an in-use legacy slot"
  [ -d "$home" ] && [ -e "$PRIMARY/state/retiree.meta" ] || fail "refused retirement removed the home or its record"
  rm -f "$wt/work.txt" "$(dirname "$legacy_slot")/.in-use"
  out=$(retire_home retiree)
  status=$?
  expect_code 0 "$status" "retirement should succeed once every slot is disposable"$'\n'"$out"
  [ ! -e "$root" ] || fail "retirement left the home's pool root $root"
  [ ! -e "$home" ] || fail "retirement did not remove the home"
  pass "retiring a secondmate home cleans its outside pool and its legacy pool, refusing while any slot holds work"
}

test_each_home_gets_a_worktree_of_its_own_clone
test_secondmate_worker_cannot_reach_its_home_contract
test_two_secondmate_homes_keep_separate_pools
test_pool_root_under_a_home_is_refused
test_legacy_in_home_pool_is_drained_without_losing_work
test_legacy_drain_keeps_a_slot_claimed_by_a_live_task
test_retirement_cleans_the_home_pool
test_primary_skips_a_leftover_foreign_slot
test_only_foreign_slots_fail_naming_them
test_foreign_clone_worktree_is_refused_loudly
test_unreadable_secondmate_marker_fails_loudly
test_teardown_returns_the_slot_to_the_pool_it_came_from
