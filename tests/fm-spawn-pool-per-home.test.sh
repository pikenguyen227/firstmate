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
# any other clone.
#
# The fake treehouse below reproduces the pooling behavior that matters: the
# pool path is <root>/.treehouse/<repo>-<origin hash>, the root is the LAST
# --root flag, else TREEHOUSE_ROOT, else $HOME (a wrapper-injected leading
# --root therefore loses to a later one), and a new slot is created from the
# invoking clone. The fake tmux runs every line spawn types into the pane from
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
      treehouse*)
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
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# One origin, a primary home and a secondmate home, each with its own clone of
# it under its own projects/, sharing one Treehouse default root.
CASE="$TMP_ROOT/case"
FAKEBIN=$(make_pool_fakebin "$CASE")
SHARED_ROOT="$CASE/shared-treehouse-root"
PRIMARY="$CASE/primary-home"
MATE="$CASE/mate-home"
fm_git_init_commit "$CASE/seed/app"
git clone --quiet --bare "$CASE/seed/app" "$CASE/app.git"
fm_test_spawn_home "$PRIMARY" claude
fm_test_spawn_home "$MATE" claude
printf 'mate\n' > "$MATE/.fm-secondmate-home"
git clone --quiet "file://$CASE/app.git" "$PRIMARY/projects/app"
git clone --quiet "file://$CASE/app.git" "$MATE/projects/app"

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
  FM_FAKE_PANE_FILE="$CASE/pane" FM_FAKE_TYPED_LOG="$CASE/typed.$id" \
    TREEHOUSE_ROOT="$SHARED_ROOT" FM_BACKEND=tmux \
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
    "$(cd "$MATE/state" && pwd -P)/treehouse-pool/"*) ;;
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

test_each_home_gets_a_worktree_of_its_own_clone
test_foreign_clone_worktree_is_refused_loudly
test_unreadable_secondmate_marker_fails_loudly
test_teardown_returns_the_slot_to_the_pool_it_came_from
