#!/usr/bin/env bash
# Default-on live guard: every firstmate home gets task worktrees of its own
# clone from the REAL Treehouse, driven through real bin/fm-spawn.sh and
# bin/fm-teardown.sh in an isolated Herdr lab session.
#
# tests/fm-spawn-pool-per-home.test.sh proves the spawn logic against a fake
# treehouse that models the pooling rule. What no fake can prove is the real
# binary's side of the contract, which this guard measures:
#   S1  a secondmate spawn on a repository the primary also holds, while the
#       shared default pool has a free slot of the primary's clone, lands in
#       that home's own pool under <user state>/firstmate/treehouse-pools/,
#       outside the home, on a worktree of the secondmate's own clone, with no
#       ancestor holding the home's CLAUDE.md or AGENTS.md;
#   S2  a primary spawn types plain `treehouse get` and lands in the default
#       pool on its own clone;
#   S3  a primary handed a leftover free slot that a secondmate clone made in
#       the default pool skips it at once, the nested `cd -- <proj> && treehouse
#       get` typed inside that slot's subshell lands in a new own-clone slot,
#       and the foreign slot is left intact;
#   S4  a default pool holding only foreign slots makes the primary spawn fail
#       past the retry limit naming each rejected slot and its owning clone,
#       leaving every slot in place;
#   S5  the real binary honours a later --root over an earlier one (the shape a
#       wrapper that injects a leading --root produces), and a nested get from
#       inside a held slot's subshell hands out a different slot;
#   S6  a single-slot `treehouse --root <root> destroy <worktree> --yes`, the
#       call the legacy-pool drain (fm_treehouse_pool_root_drain) makes beside a
#       claimed slot, removes a disposable slot and refuses, with a non-zero
#       exit, a dirty one and a leased one, leaving both worktrees in place;
#   S7  a secondmate spawn whose pool root would sit under its home refuses,
#       naming the home, before any Treehouse call;
#   S8  the next secondmate spawn drains the pre-move in-home pool: a
#       disposable slot is removed, while a slot claimed by a task the home
#       still records, a dirty slot and a leased slot are kept and reported;
#   S9  relaunching a task whose recorded worktree is an in-home slot refuses,
#       naming the home, and the same relaunch in the outside pool succeeds;
#   S10 retiring the secondmate refuses while a slot of either pool holds work,
#       naming each, then removes both pools and the home once they are clean.
#
# It submits no prompt, so the shared live gate runs it wherever herdr, jq, git,
# and treehouse are installed. FM_TREEHOUSE_LIVE_BIN names the real treehouse
# binary when the `treehouse` on PATH is a wrapper that pins its own --root;
# this guard never lets any wrapper's root near the run. Every Treehouse call
# runs with a throwaway HOME, a throwaway default root, and throwaway homes and
# clones of a throwaway origin, all under one private temp dir that is removed
# at exit. docs/verification/secondmate-pool-per-home.md records the result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pool-live.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
if [ -n "${FM_TREEHOUSE_LIVE_BIN:-}" ]; then
  mkdir -p "$TMP_ROOT/real-bin"
  ln -s "$FM_TREEHOUSE_LIVE_BIN" "$TMP_ROOT/real-bin/treehouse"
  PATH="$TMP_ROOT/real-bin:$PATH"
fi

fm_live_gate default-on FM_SPAWN_POOL_PER_HOME_LIVE_E2E herdr jq git treehouse

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

TH_REAL=$(command -v treehouse)
TH_VERSION=$("$TH_REAL" --version 2>/dev/null | head -1)
[ -n "$TH_VERSION" ] || TH_VERSION='(no version reported)'

LAB_SESSION=
LAB_TORN=0
cleanup() {
  local status=$?
  if [ -n "$LAB_SESSION" ] && [ "$LAB_TORN" = 0 ]; then
    LAB_TORN=1
    "$LAB_HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 ||
      { printf 'not ok - lab session %s teardown failed\n' "$LAB_SESSION" >&2; status=1; }
  fi
  rm -rf "$TMP_ROOT" || { printf 'not ok - could not remove %s\n' "$TMP_ROOT" >&2; status=1; }
  exit "$status"
}
trap cleanup EXIT

fail() { printf 'not ok - treehouse %s: %s\n' "$TH_VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - treehouse %s: %s\n' "$TH_VERSION" "$1"; }

# The wrapper every pane and every call here uses mirrors an installed wrapper
# that injects a leading --root: the "configured default" is whichever root the
# active scenario wrote to default-root.path, so no scenario shares pool state
# it did not set up.
TH_HOME="$TMP_ROOT/th-home"
LAB_BIN="$TMP_ROOT/lab-bin"
mkdir -p "$TH_HOME" "$LAB_BIN"
CALLS="$TMP_ROOT/treehouse-calls.log"
: > "$CALLS"
cat > "$LAB_BIN/treehouse" <<SH
#!/bin/sh
printf '%s\t%s\n' "\$(pwd -P)" "\$*" >> "$CALLS"
exec env -u TREEHOUSE_ROOT HOME="$TH_HOME" "$TH_REAL" --root "\$(cat "$TMP_ROOT/default-root.path")" "\$@"
SH
chmod +x "$LAB_BIN/treehouse"
use_default_root() { mkdir -p "$1" && printf '%s\n' "$1" > "$TMP_ROOT/default-root.path"; }
PATH="$LAB_BIN:$PATH"
export PATH

mkhome() {
  mkdir -p "$1/data" "$1/projects" "$1/state" "$1/config"
  touch "$1/state/.last-watcher-beat"
  printf 'off\n' > "$1/config/herdr-presentation-spaces"
}
brief() {
  mkdir -p "$1/data/$2"
  printf '# Task\n## Captain'"'"'s intent\nlive %s\n\n## Firstmate spec\nlive\n' "$2" > "$1/data/$2/brief.md"
}
real() { (cd "$1" 2>/dev/null && pwd -P); }
common() { real "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; }
meta() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

PRIMARY="$TMP_ROOT/primary-home"
MATE="$TMP_ROOT/mate-home"
mkhome "$PRIMARY"
mkhome "$MATE"
printf 'livemate\n' > "$MATE/.fm-secondmate-home"
printf '@AGENTS.md\n' > "$MATE/CLAUDE.md"
printf '# supervisor contract\n' > "$MATE/AGENTS.md"
export XDG_STATE_HOME="$TMP_ROOT/user-state"
mkdir -p "$XDG_STATE_HOME"
mkdir -p "$TMP_ROOT/seed/app"
git -C "$TMP_ROOT/seed/app" init -q
echo live > "$TMP_ROOT/seed/app/README.md"
git -C "$TMP_ROOT/seed/app" add .
git -C "$TMP_ROOT/seed/app" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$TMP_ROOT/seed/app" "$TMP_ROOT/app.git"
git clone -q "file://$TMP_ROOT/app.git" "$PRIMARY/projects/app"
git clone -q "file://$TMP_ROOT/app.git" "$MATE/projects/app"
P_COMMON=$(common "$PRIMARY/projects/app")
M_COMMON=$(common "$MATE/projects/app")
MATE_POOLS="$(real "$XDG_STATE_HOME")/firstmate/treehouse-pools"

# Leftover slots are made the way they really arose: the secondmate clone asks
# the shared default root for a worktree and gives it back, leaving a free slot
# of its own clone in the pool the primary allocates from.
seed_foreign_slots() { # <count>
  local path paths=()
  for _ in $(seq 1 "$1"); do
    path=$(cd "$MATE/projects/app" && treehouse get --lease --no-fetch 2>/dev/null) ||
      fail "seeding: treehouse get --lease from the secondmate clone failed"
    paths+=("$path")
  done
  for path in "${paths[@]}"; do
    (cd "$MATE/projects/app" && treehouse return --force "$path" >/dev/null 2>&1) ||
      fail "seeding: treehouse return --force $path failed"
    [ "$(common "$path")" = "$M_COMMON" ] || fail "seeding: $path is not a worktree of the secondmate clone"
    printf '%s\n' "$(real "$path")"
  done
}

RC=0
ELAPSED=0
SPAWN_CALLS=
spawn() { # <home> <id>
  local t0 before
  brief "$1" "$2"
  before=$(wc -l < "$CALLS")
  t0=$(date +%s)
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$1/projects/app" "sh -c 'echo pool-live-ok; exec sleep 600'" \
    --backend herdr --mode no-mistakes --yolo off >"$TMP_ROOT/$2.out" 2>"$TMP_ROOT/$2.err"
  RC=$?
  ELAPSED=$(($(date +%s) - t0))
  SPAWN_CALLS=$(tail -n +"$((before + 1))" "$CALLS" | grep -E '	(--root [^ ]+ )?get$' || true)
  printf '# spawn %s home=%s rc=%s elapsed=%ss\n' "$2" "$(basename "$1")" "$RC" "$ELAPSED"
  sed 's/^/#   out| /' "$TMP_ROOT/$2.out"
  grep -v 'records no delivery contract line' "$TMP_ROOT/$2.err" | sed 's/^/#   err| /'
  printf '%s\n' "$SPAWN_CALLS" | sed 's/^/#   treehouse (cwd<TAB>argv)| /'
}
teardown_task() { # <home> <id>
  local out
  out=$(FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$LAB_SESSION" \
    "$ROOT/bin/fm-teardown.sh" "$2" --force 2>&1) ||
    { printf '%s\n' "$out" | sed 's/^/#   teardown| /'; fail "fm-teardown.sh $2 failed"; }
}

printf '# treehouse binary: %s (%s)\n' "$TH_REAL" "$TH_VERSION"
printf '# primary clone common dir: %s\n# secondmate clone common dir: %s\n' "$P_COMMON" "$M_COMMON"

# --- S5: the real binary's --root precedence and nested get -----------------
# Both are properties of Treehouse itself that bin/fm-spawn.sh relies on, so
# they are measured first, outside the lab, from a throwaway clone.
S5_A="$TMP_ROOT/s5-leading-root"
S5_B="$TMP_ROOT/s5-later-root"
use_default_root "$S5_A"
S5_PATH=$(cd "$PRIMARY/projects/app" && treehouse --root "$S5_B" get --lease --no-fetch 2>/dev/null) ||
  fail "S5: treehouse --root <later> get --lease failed behind a leading --root"
printf '# S5 leased %s\n' "$S5_PATH"
case "$(real "$S5_PATH")" in
  "$(real "$S5_B")"/*) ;;
  *) fail "S5: a later --root did not win over the leading one; slot landed at $S5_PATH" ;;
esac
[ ! -e "$S5_A/.treehouse" ] || fail "S5: the leading --root pool was written to despite a later --root"
(cd "$PRIMARY/projects/app" && treehouse --root "$S5_B" return --force "$S5_PATH" >/dev/null 2>&1) ||
  fail "S5: returning the --root lease failed"
pass "S5 a later --root wins over a wrapper's leading --root"

# --- S6: single-slot destroy keeps a slot that holds work -------------------
S6_ROOT="$TMP_ROOT/s6-root"
S6_WT=()
for _ in 1 2 3; do
  S6_PATH=$(cd "$PRIMARY/projects/app" && treehouse --root "$S6_ROOT" get --lease --no-fetch 2>/dev/null) ||
    fail "S6: treehouse --root <root> get --lease failed"
  S6_WT+=("$S6_PATH")
done
for i in 0 1; do
  (cd "$PRIMARY/projects/app" && treehouse --root "$S6_ROOT" return --force "${S6_WT[$i]}" >/dev/null 2>&1) ||
    fail "S6: returning ${S6_WT[$i]} failed"
done
printf 'untracked\n' > "${S6_WT[1]}/untracked.txt"
s6_destroy() { # <worktree>
  local out rc=0
  out=$(cd "$S6_ROOT" && treehouse --root "$S6_ROOT" destroy "$1" --yes 2>&1) || rc=$?
  printf '# S6 destroy %s rc=%s\n' "$1" "$rc"
  printf '%s\n' "$out" | sed 's/^/#   | /'
  return "$rc"
}
! s6_destroy "${S6_WT[1]}" || fail "S6: destroying the dirty slot exited 0"
[ -f "${S6_WT[1]}/untracked.txt" ] || fail "S6: single-slot destroy removed a dirty slot's work"
! s6_destroy "${S6_WT[2]}" || fail "S6: destroying the leased slot exited 0"
[ -d "${S6_WT[2]}" ] || fail "S6: single-slot destroy removed a leased slot"
s6_destroy "${S6_WT[0]}" || fail "S6: destroying the disposable slot failed"
[ ! -e "${S6_WT[0]}" ] || fail "S6: single-slot destroy left the disposable slot"
pass "S6 single-slot destroy removes a disposable slot and refuses a dirty or leased one"

# Herdr panes inherit the server's environment, so PATH already names the lab
# wrapper when the lab is provisioned.
herdr_forget_inherited_pane
LAB_SESSION=$("$LAB_HELPER" name fm-pool-live) || fail "could not name a Herdr lab session"
"$LAB_HELPER" provision "$LAB_SESSION" >/dev/null || fail "could not provision Herdr lab session $LAB_SESSION"
printf '# lab session: %s\n' "$LAB_SESSION"

# --- S2 then S1: primary on the default pool, secondmate on its own ---------
S12_ROOT="$TMP_ROOT/default-root-s12"
use_default_root "$S12_ROOT"
spawn "$PRIMARY" livep1
[ "$RC" = 0 ] || fail "S2: primary spawn failed"
[ "$SPAWN_CALLS" = "$(real "$PRIMARY/projects/app")"$'\t'get ] ||
  fail "S2: primary did not type exactly one plain 'treehouse get' from its project (saw: $SPAWN_CALLS)"
WT=$(meta "$PRIMARY/state/livep1.meta" worktree)
case "$(real "$WT")" in "$(real "$S12_ROOT")"/.treehouse/*) ;; *) fail "S2: primary worktree $WT is not in the default pool" ;; esac
[ "$(common "$WT")" = "$P_COMMON" ] || fail "S2: primary worktree $WT is not of the primary clone"
teardown_task "$PRIMARY" livep1
PRIMARY_SLOT=$(real "$WT")
pass "S2 primary spawn lands in the default pool on its own clone ($WT)"

spawn "$MATE" livem1
[ "$RC" = 0 ] || fail "S1: secondmate spawn failed while the default pool held a free primary-clone slot ($PRIMARY_SLOT)"
WT=$(meta "$MATE/state/livem1.meta" worktree)
MATE_POOL=$(dirname "$(dirname "$(dirname "$(dirname "$(real "$WT")")")")")
case "$MATE_POOL" in "$MATE_POOLS"/livemate-*) ;; *) fail "S1: secondmate worktree $WT is not in its own pool under $MATE_POOLS" ;; esac
[ "$SPAWN_CALLS" = "$(real "$MATE/projects/app")"$'\t'"--root $MATE_POOL get" ] ||
  fail "S1: secondmate did not type 'treehouse --root $MATE_POOL get' from its project (saw: $SPAWN_CALLS)"
case "$(real "$WT")" in "$(real "$MATE")"/*) fail "S1: secondmate worktree $WT sits inside its home" ;; esac
S1_DIR=$(dirname "$(real "$WT")")
while [ "$S1_DIR" != "$(real "$TMP_ROOT")" ] && [ "$S1_DIR" != / ]; do
  [ ! -e "$S1_DIR/CLAUDE.md" ] && [ ! -e "$S1_DIR/AGENTS.md" ] ||
    fail "S1: secondmate worktree $WT has ancestor $S1_DIR holding supervisor instructions"
  S1_DIR=$(dirname "$S1_DIR")
done
[ "$(common "$WT")" = "$M_COMMON" ] || fail "S1: secondmate worktree $WT is not of the secondmate clone"
[ "$(common "$PRIMARY_SLOT")" = "$P_COMMON" ] || fail "S1: the primary's free slot $PRIMARY_SLOT changed owner"
teardown_task "$MATE" livem1
pass "S1 secondmate spawn lands in its own pool on its own clone ($WT)"

# --- S3: a leftover foreign slot is skipped at once -------------------------
S3_ROOT="$TMP_ROOT/default-root-s3"
use_default_root "$S3_ROOT"
FOREIGN=$(seed_foreign_slots 1) || exit 1
printf '# S3 seeded free foreign slot %s\n' "$FOREIGN"
spawn "$PRIMARY" livep2
[ "$RC" = 0 ] || fail "S3: primary spawn failed when handed one leftover foreign slot"
[ "$SPAWN_CALLS" = "$(real "$PRIMARY/projects/app")"$'\t'get$'\n'"$(real "$PRIMARY/projects/app")"$'\t'get ] ||
  fail "S3: expected the plain get and one nested get typed from the primary project (saw: $SPAWN_CALLS)"
WT=$(meta "$PRIMARY/state/livep2.meta" worktree)
[ "$(common "$WT")" = "$P_COMMON" ] || fail "S3: primary worktree $WT is not of the primary clone"
[ "$(real "$WT")" != "$FOREIGN" ] || fail "S3: primary adopted the foreign slot"
case "$(real "$WT")" in "$(real "$S3_ROOT")"/.treehouse/*) ;; *) fail "S3: primary worktree $WT left the default pool" ;; esac
[ "$ELAPSED" -lt 30 ] || fail "S3: skipping the foreign slot took ${ELAPSED}s, not an immediate retry"
[ -d "$FOREIGN" ] && [ "$(common "$FOREIGN")" = "$M_COMMON" ] || fail "S3: the foreign slot $FOREIGN was not left intact"
teardown_task "$PRIMARY" livep2
pass "S3 primary skips a foreign slot in ${ELAPSED}s and a nested get lands in a new own-clone slot ($WT); foreign slot intact"
pass "S5 a nested get inside a held slot's subshell hands out a different slot"

# --- S4: only foreign slots fails loudly, naming them -----------------------
S4_ROOT="$TMP_ROOT/default-root-s4"
use_default_root "$S4_ROOT"
FOREIGN_ALL=$(seed_foreign_slots 5) || exit 1
printf '# S4 seeded free foreign slots:\n'
printf '%s\n' "$FOREIGN_ALL" | sed 's/^/#   /'
# Treehouse hands out free slots before creating one, so with five free foreign
# slots every get up to the retry bound (three retries, four rejected) yields one.
spawn "$PRIMARY" livep3
REJECTED=$(grep -c "worktree of git common dir '$M_COMMON'" "$TMP_ROOT/livep3.err")
if [ "$RC" = 0 ]; then
  fail "S4: primary spawn succeeded in a pool of only foreign slots (worktree $(meta "$PRIMARY/state/livep3.meta" worktree))"
fi
[ "$REJECTED" -ge 4 ] || fail "S4: the failure named $REJECTED rejected foreign slots, expected 4"
while IFS= read -r slot; do
  [ -d "$slot" ] && [ "$(common "$slot")" = "$M_COMMON" ] || fail "S4: foreign slot $slot was not left intact"
done <<EOF
$FOREIGN_ALL
EOF
pass "S4 primary fails after the retry bound naming $REJECTED foreign slots and their owning clone; all 5 left intact"

# --- S7: a pool root under a home refuses before any pool is touched --------
use_default_root "$TMP_ROOT/default-root-s7"
S7_BEFORE=$(wc -l < "$CALLS")
XDG_STATE_HOME="$MATE/user-state" spawn "$MATE" livem7
[ "$RC" != 0 ] || fail "S7: spawn allocated from a pool root under the home"
grep -qF "sits under firstmate home '$(real "$MATE")'" "$TMP_ROOT/livem7.err" ||
  fail "S7: the refusal does not name the home"
[ "$(wc -l < "$CALLS")" = "$S7_BEFORE" ] || fail "S7: treehouse was called despite the refusal"
[ ! -e "$MATE/state/livem7.meta" ] || fail "S7: the refused spawn left a task record"
pass "S7 a pool root under a firstmate home refuses the spawn before any treehouse call"

# --- S8: the pre-move in-home pool is drained at the next spawn -------------
# Slots are made in <home>/state/treehouse-pool the way the earlier spawns made
# them: a claimed one whose lease lapsed but whose task the home still records,
# a disposable one, a dirty one, and a leased one.
LEGACY="$MATE/state/treehouse-pool"
legacy_get() {
  (cd "$MATE/projects/app" && treehouse --root "$LEGACY" get --lease --no-fetch 2>/dev/null) ||
    fail "S8: seeding a legacy slot failed"
}
legacy_return() {
  (cd "$MATE/projects/app" && treehouse --root "$LEGACY" return --force "$1" >/dev/null 2>&1) ||
    fail "S8: returning legacy slot $1 failed"
}
L_CLAIMED=$(real "$(legacy_get)") || exit 1
L_FREE=$(real "$(legacy_get)") || exit 1
L_DIRTY=$(real "$(legacy_get)") || exit 1
L_LEASED=$(real "$(legacy_get)") || exit 1
legacy_return "$L_CLAIMED"
legacy_return "$L_FREE"
legacy_return "$L_DIRTY"
printf 'untracked\n' > "$L_DIRTY/untracked.txt"
printf 'task=livelegacy\nhome=%s\n' "$MATE" > "$(dirname "$L_CLAIMED")/.fm-slot-owner"
printf 'worktree=%s\n' "$L_CLAIMED" > "$MATE/state/livelegacy.meta"
printf '# S8 seeded legacy slots: claimed=%s free=%s dirty=%s leased=%s\n' \
  "$(dirname "$L_CLAIMED")" "$(dirname "$L_FREE")" "$(dirname "$L_DIRTY")" "$(dirname "$L_LEASED")"
use_default_root "$TMP_ROOT/default-root-s8"
spawn "$MATE" livem8
[ "$RC" = 0 ] || fail "S8: secondmate spawn failed beside a legacy in-home pool"
WT8=$(real "$(meta "$MATE/state/livem8.meta" worktree)")
case "$WT8" in "$MATE_POOLS"/livemate-*) ;; *) fail "S8: the spawn did not land in the home's own outside pool ($WT8)" ;; esac
[ ! -e "$L_FREE" ] || fail "S8: the disposable legacy slot was left behind"
[ -d "$L_CLAIMED" ] || fail "S8: the drain destroyed the slot claimed by a recorded task"
[ -f "$L_DIRTY/untracked.txt" ] || fail "S8: the drain lost the dirty slot's work"
[ -d "$L_LEASED" ] || fail "S8: the drain destroyed the leased slot"
grep -qF "$(dirname "$L_CLAIMED") (claimed by task livelegacy)" "$TMP_ROOT/livem8.err" ||
  fail "S8: the claimed slot was not reported as kept by its claim"
grep -qF "$(dirname "$L_DIRTY") (kept by Treehouse" "$TMP_ROOT/livem8.err" ||
  fail "S8: the dirty slot was not reported as kept"
grep -qF "$(dirname "$L_LEASED") (kept by Treehouse" "$TMP_ROOT/livem8.err" ||
  fail "S8: the leased slot was not reported as kept"
! grep -qF "$(dirname "$L_FREE")" "$TMP_ROOT/livem8.err" || fail "S8: the removed disposable slot was reported as kept"
pass "S8 the next spawn drains the legacy in-home pool: the disposable slot is removed; the claimed, dirty and leased slots are kept and reported"

# --- S9: relaunch refuses a recorded worktree inside the home ---------------
# The task's pane is closed so the relaunch can prove its agent gone, and its
# record is pointed at the claimed legacy slot, as a task spawned before the
# move records.
relaunch() { # <home> <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" --relaunch --harness "sh -c 'echo pool-live-ok; exec sleep 600'" \
    >"$TMP_ROOT/$2.relaunch.out" 2>"$TMP_ROOT/$2.relaunch.err"
  RC=$?
  printf '# relaunch %s home=%s rc=%s\n' "$2" "$(basename "$1")" "$RC"
  sed 's/^/#   out| /' "$TMP_ROOT/$2.relaunch.out"
  grep -v 'records no delivery contract line' "$TMP_ROOT/$2.relaunch.err" | sed 's/^/#   err| /'
}
set_worktree() { # <meta> <worktree>
  awk -v wt="$2" '/^worktree=/ { print "worktree=" wt; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
"$LAB_HELPER" run "$LAB_SESSION" pane close "$(meta "$MATE/state/livem8.meta" herdr_pane_id)" >/dev/null ||
  fail "S9: could not close livem8's lab pane"
set_worktree "$MATE/state/livem8.meta" "$L_CLAIMED"
relaunch "$MATE" livem8
[ "$RC" != 0 ] || fail "S9: relaunch launched into a worktree inside the home"
grep -qF "sits under firstmate home '$(real "$MATE")'" "$TMP_ROOT/livem8.relaunch.err" ||
  fail "S9: the relaunch refusal does not name the home"
set_worktree "$MATE/state/livem8.meta" "$WT8"
relaunch "$MATE" livem8
[ "$RC" = 0 ] || fail "S9: relaunch into the home's outside pool failed"
[ "$(real "$(meta "$MATE/state/livem8.meta" worktree)")" = "$WT8" ] || fail "S9: relaunch changed the recorded worktree"
teardown_task "$MATE" livem8
pass "S9 relaunch refuses a recorded worktree inside the home, naming it, and relaunches one in the outside pool"

# --- S10: retiring the secondmate cleans both of its pools ------------------
# The home is registered as the primary's secondmate on a lab pane that has
# already closed. Retirement first refuses while the home records any task, so
# the claiming task's record goes; the legacy pool still holds S8's dirty and
# leased slots, and the outside slot S9 returned is given uncommitted work.
rm -f "$MATE/state/livelegacy.meta"
printf 'unsaved\n' > "$WT8/work.txt"
cat > "$PRIMARY/state/livemate.meta" <<META
window=$LAB_SESSION:w9:p9
endpoint_task_id=livemate
spawn_gen=s1.1.1
worktree=$MATE
project=$MATE
harness=sh
kind=secondmate
mode=secondmate
yolo=off
home=$MATE
projects=app
backend=herdr
herdr_session=$LAB_SESSION
herdr_workspace_id=w9
herdr_tab_id=w9:t9
herdr_pane_id=w9:p9
META
printf '%s\n' "- livemate - live pool guard (home: $MATE; scope: live pool guard; projects: app; added 2026-09-24)" \
  > "$PRIMARY/data/secondmates.md"
retire() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$LAB_SESSION" \
    FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" livemate >"$TMP_ROOT/retire.out" 2>&1
  RC=$?
  printf '# retire livemate rc=%s\n' "$RC"
  sed 's/^/#   | /' "$TMP_ROOT/retire.out"
}
retire
[ "$RC" != 0 ] || fail "S10: retirement discarded pool slots holding work"
for slot in "$(dirname "$L_DIRTY")" "$(dirname "$L_LEASED")" "$(dirname "$WT8")"; do
  grep -qF "$slot" "$TMP_ROOT/retire.out" || fail "S10: the refusal does not name $slot"
done
[ -f "$WT8/work.txt" ] && [ -f "$L_DIRTY/untracked.txt" ] && [ -d "$L_LEASED" ] ||
  fail "S10: the refused retirement lost a slot's work"
[ -d "$MATE" ] && [ -e "$PRIMARY/state/livemate.meta" ] || fail "S10: the refused retirement removed the home or its record"
rm -f "$WT8/work.txt" "$L_DIRTY/untracked.txt"
(cd "$MATE/projects/app" && treehouse --root "$LEGACY" return --force "$L_LEASED" >/dev/null 2>&1) ||
  fail "S10: returning the leased legacy slot failed"
retire
[ "$RC" = 0 ] || fail "S10: retirement failed once every slot was disposable"
[ ! -e "$(dirname "$(dirname "$(dirname "$WT8")")")" ] || fail "S10: retirement left the home's outside pool root"
[ ! -e "$MATE" ] || fail "S10: retirement did not remove the home"
pass "S10 retiring a secondmate refuses while any slot of either pool holds work, then cleans its outside pool and its legacy pool"
