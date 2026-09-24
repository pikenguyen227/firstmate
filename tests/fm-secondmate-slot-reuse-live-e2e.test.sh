#!/usr/bin/env bash
# Default-on live guard: retiring a secondmate whose home is a leased Treehouse
# slot leaves nothing of it in that slot, so the next seed onto the same slot
# succeeds - measured against the REAL Treehouse binary through real
# bin/fm-home-seed.sh and bin/fm-teardown.sh.
#
# tests/fm-secondmate-safety.test.sh proves the teardown logic against a fake
# pool. What no fake can prove is the real binary's side: `treehouse return`
# keeps git-ignored files (the home's marker, records and project clones), and
# the next `treehouse get --lease` hands back that same slot. This guard runs:
#   L1  retire a pooled secondmate, then seed a new one: the real pool hands out
#       the same slot, the seed succeeds, and the marker names the new mate;
#   L2  a detached process whose cwd is inside the home is reaped during a
#       non-forced retirement, and the slot is freed;
#   L3  with lsof off PATH, retirement completes with a warning;
#   L4  retirement refuses while a clone holds an unpushed commit, and while
#       projects/ holds a non-git directory; the home and lease stay intact;
#   L5  a stray .DS_Store under projects/ does not block retirement;
#   L6  a forced retirement sweeps a nested secondmate on its own leased slot
#       and frees both slots; a failed return puts the home's files and its
#       process-event registration back and keeps the lease and records;
#   L7  (Herdr lab) a secondmate spawned on a leased slot is retired and a new
#       secondmate is seeded and spawned on the same slot.
#
# L1-L6 close the endpoint through a stand-in tmux (the endpoint is not the
# subject there and tmux may be absent); L7 uses a real Herdr lab session
# through bin/fm-herdr-lab.sh and runs only when herdr is installed.
# FM_TREEHOUSE_LIVE_BIN names the real treehouse binary when the `treehouse` on
# PATH is a wrapper that pins its own --root. Every Treehouse call runs with a
# throwaway HOME and a throwaway --root, on a throwaway primary and origin, all
# under one private temp dir removed at exit.
# docs/verification/secondmate-slot-reuse.md records the result.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-slot-live.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
if [ -n "${FM_TREEHOUSE_LIVE_BIN:-}" ]; then
  mkdir -p "$TMP_ROOT/real-bin"
  ln -s "$FM_TREEHOUSE_LIVE_BIN" "$TMP_ROOT/real-bin/treehouse"
  PATH="$TMP_ROOT/real-bin:$PATH"
fi

fm_live_gate default-on FM_SECONDMATE_SLOT_REUSE_LIVE_E2E git treehouse lsof

TH_REAL=$(command -v treehouse)
TH_VERSION=$("$TH_REAL" --version 2>/dev/null | head -1)
[ -n "$TH_VERSION" ] || TH_VERSION='(no version reported)'

LAB_SESSION=
LAB_TORN=0
REAP_PIDS=()
cleanup() {
  local status=$? pid
  for pid in "${REAP_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
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

# Every call, from seed, teardown, and this guard, reaches the real binary with
# this run's own HOME and pool root. A marker file makes `return` fail before
# the real binary runs, for the failed-return scenario only.
TH_HOME="$TMP_ROOT/th-home"
TH_ROOT="$TMP_ROOT/pool-root"
TH_BIN="$TMP_ROOT/th-bin"
FAIL_RETURN="$TMP_ROOT/fail-next-return"
mkdir -p "$TH_HOME" "$TH_ROOT" "$TH_BIN"
cat > "$TH_BIN/treehouse" <<SH
#!/bin/sh
if [ "\${1:-}" = return ] && [ -e "$FAIL_RETURN" ]; then
  echo "injected return failure" >&2
  exit 1
fi
exec env -u TREEHOUSE_ROOT HOME="$TH_HOME" "$TH_REAL" --root "$TH_ROOT" "\$@"
SH
chmod +x "$TH_BIN/treehouse"

FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
rm -f "$FAKEBIN/treehouse"
TMUX_LOG="$TMP_ROOT/fake/tmux.log"
PATH="$TH_BIN:$FAKEBIN:$PATH"
export PATH FM_BACKEND=tmux FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE

real() { (cd "$1" 2>/dev/null && pwd -P); }

# A throwaway primary Firstmate with its own origin, and a parent home holding
# one project with its own origin.
PRIMARY=$(make_seed_primary "$TMP_ROOT/primary")
git clone -q --bare "$PRIMARY" "$TMP_ROOT/primary-origin.git"
git -C "$PRIMARY" remote add origin "file://$TMP_ROOT/primary-origin.git"
git -C "$PRIMARY" fetch -q origin
PARENT="$TMP_ROOT/parent-home"
mkdir -p "$PARENT/projects" "$PARENT/data" "$PARENT/state"
fm_git_init_commit "$PARENT/projects/alpha"
fm_git_add_origin "$PARENT/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$PARENT/data/projects.md"

slot_state() { # <slot> -> "leased (held by x)" | "available" | "absent"
  local line
  line=$(cd "$PRIMARY" && treehouse status 2>/dev/null | grep -F " $1" | head -1)
  case "$line" in
    *leased*) printf 'leased%s\n' "$(printf '%s' "$line" | sed -n 's/.*\((held by [^)]*)\).*/ \1/p')" ;;
    *available*) printf 'available\n' ;;
    '') printf 'absent\n' ;;
    *) printf '%s\n' "$line" ;;
  esac
}

HOME_OUT=
seed() { # <parent-home> <id> ; sets HOME_OUT to the leased home
  local out rc
  out=$(FM_HOME="$1" FM_SECONDMATE_CHARTER="$2 scope" FM_SECONDMATE_SCOPE="$2 scope" \
    "$(real "${3:-$PRIMARY}")/bin/fm-home-seed.sh" "$2" - alpha 2>"$TMP_ROOT/seed-$2.err")
  rc=$?
  HOME_OUT=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | head -1)
  printf '# seed %s rc=%s home=%s\n' "$2" "$rc" "${HOME_OUT:-?}"
  [ "$rc" -eq 0 ] || { sed 's/^/#   seed err| /' "$TMP_ROOT/seed-$2.err"; return 1; }
  [ -n "$HOME_OUT" ] || { printf '%s\n' "$out" | sed 's/^/#   seed out| /'; return 1; }
  cat > "$1/state/$2.meta" <<EOF
window=firstmate:fm-$2
worktree=$HOME_OUT
project=$HOME_OUT
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$HOME_OUT
projects=alpha
EOF
}

RC=0
retire() { # <parent-home> <id> [teardown args...]
  local home=$1 id=$2
  shift 2
  FM_HOME="$home" "$PRIMARY/bin/fm-teardown.sh" "$id" "$@" >"$TMP_ROOT/retire-$id.out" 2>"$TMP_ROOT/retire-$id.err"
  RC=$?
  printf '# fm-teardown.sh %s %s rc=%s\n' "$id" "$*" "$RC"
  sed 's/^/#   teardown| /' "$TMP_ROOT/retire-$id.err"
}

assert_slot_cleared() { # <slot> <label>
  local entry
  [ -d "$1/.git" ] || [ -f "$1/.git" ] || fail "$2: real treehouse did not keep the returned slot $1"
  for entry in .fm-secondmate-home .fm-secondmate-parent data state config projects; do
    [ ! -e "$1/$entry" ] || fail "$2: retired secondmate left $entry in the returned slot $1"
  done
  [ "$(slot_state "$1")" = available ] || fail "$2: slot $1 is '$(slot_state "$1")' after retirement, not available"
}

assert_retired_records() { # <parent-home> <id> <label>
  [ ! -e "$1/state/$2.meta" ] || fail "$3: retirement kept $2.meta"
  ! grep -F -- "- $2 " "$1/data/secondmates.md" >/dev/null 2>&1 || fail "$3: retirement kept the $2 registry route"
}

printf '# treehouse binary: %s (%s)\n' "$TH_REAL" "$TH_VERSION"
printf '# git: %s\n' "$(git --version)"

# --- L1: retire, then the next seed takes the same real slot ---------------
seed "$PARENT" first || fail "L1: first seed failed"
SLOT=$HOME_OUT
case "$(real "$SLOT")" in "$(real "$TH_ROOT")"/*) ;; *) fail "L1: slot $SLOT is outside this run's pool root" ;; esac
printf '# L1 slot %s is %s\n' "$SLOT" "$(slot_state "$SLOT")"
printf '# L1 home-owned entries before retirement: %s\n' "$(for e in "$SLOT"/.fm-secondmate* "$SLOT"/data* "$SLOT"/state* "$SLOT"/config* "$SLOT"/projects*; do [ -e "$e" ] || [ -L "$e" ] || continue; printf '%s ' "${e##*/}"; done)"
retire "$PARENT" first
[ "$RC" -eq 0 ] || fail "L1: retiring first failed"
assert_slot_cleared "$SLOT" L1
assert_retired_records "$PARENT" first L1
seed "$PARENT" second || fail "L1: seeding second after retiring first failed"
[ "$(real "$HOME_OUT")" = "$(real "$SLOT")" ] || fail "L1: real treehouse handed out $HOME_OUT, not the retired slot $SLOT"
[ "$(cat "$SLOT/.fm-secondmate-home")" = second ] || fail "L1: slot marker does not name second"
printf '# L1 slot %s is %s; marker=%s\n' "$SLOT" "$(slot_state "$SLOT")" "$(cat "$SLOT/.fm-secondmate-home")"
pass "L1 retiring a pooled secondmate frees its real slot and the next seed takes it"

# --- L2: a detached process inside the home is reaped ----------------------
( cd "$SLOT/projects/alpha" && exec sleep 300 ) </dev/null >/dev/null 2>&1 &
PID=$!
REAP_PIDS+=("$PID")
disown "$PID" 2>/dev/null || true
sleep 0.3
printf '# L2 detached pid %s cwd=%s\n' "$PID" "$(lsof -a -p "$PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
retire "$PARENT" second
if kill -0 "$PID" 2>/dev/null; then fail "L2: pid $PID inside the home survived retirement"; fi
[ "$RC" -eq 0 ] || fail "L2: retiring second with a leftover process failed"
grep -F "reaping leaked" "$TMP_ROOT/retire-second.err" >/dev/null || fail "L2: teardown did not report reaping the leftover process"
assert_slot_cleared "$SLOT" L2
assert_retired_records "$PARENT" second L2
seed "$PARENT" third || fail "L2: seeding third after the reap failed"
[ "$(real "$HOME_OUT")" = "$(real "$SLOT")" ] || fail "L2: next seed did not take the retired slot"
pass "L2 a detached process inside the home is reaped and the slot is freed"

# --- L3: no lsof on PATH ---------------------------------------------------
NOLSOF_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx /usr/sbin | grep -vx /sbin | paste -sd: -)
printf '# L3 lsof on teardown PATH: %s\n' "$(PATH=$NOLSOF_PATH command -v lsof || echo none)"
PATH=$NOLSOF_PATH retire "$PARENT" third
[ "$RC" -eq 0 ] || fail "L3: retirement without lsof failed"
grep -F 'lsof is unavailable' "$TMP_ROOT/retire-third.err" >/dev/null || fail "L3: retirement without lsof did not warn"
assert_slot_cleared "$SLOT" L3
assert_retired_records "$PARENT" third L3
pass "L3 retirement without lsof completes with a warning and frees the slot"

# --- L4: unlanded work and a non-git directory refuse ----------------------
seed "$PARENT" keeper || fail "L4: seeding keeper failed"
[ "$(real "$HOME_OUT")" = "$(real "$SLOT")" ] || fail "L4: keeper did not take the retired slot"
printf 'unlanded\n' > "$SLOT/projects/alpha/work.txt"
git -C "$SLOT/projects/alpha" add work.txt
git -C "$SLOT/projects/alpha" -c user.name=t -c user.email=t@e.invalid commit -qm unlanded
: > "$TMUX_LOG"
retire "$PARENT" keeper
[ "$RC" -ne 0 ] || fail "L4: retirement succeeded although a clone held an unpushed commit"
grep -F "project clone $SLOT/projects/alpha" "$TMP_ROOT/retire-keeper.err" >/dev/null || fail "L4: refusal did not name the clone"
[ "$(cat "$SLOT/.fm-secondmate-home")" = keeper ] || fail "L4: unpushed-commit refusal did not leave the home intact"
[ "$(cat "$SLOT/projects/alpha/work.txt")" = unlanded ] || fail "L4: unpushed commit did not survive"
[ -e "$PARENT/state/keeper.meta" ] || fail "L4: unpushed-commit refusal removed keeper.meta"
case "$(slot_state "$SLOT")" in leased*) ;; *) fail "L4: unpushed-commit refusal released the lease" ;; esac
! grep -F kill-window "$TMUX_LOG" >/dev/null || fail "L4: unpushed-commit refusal closed the endpoint"
printf '# L4 after unpushed-commit refusal: slot %s, marker=%s\n' "$(slot_state "$SLOT")" "$(cat "$SLOT/.fm-secondmate-home")"
git -C "$SLOT/projects/alpha" push -q origin HEAD:main
mkdir "$SLOT/projects/scratch"
printf 'x\n' > "$SLOT/projects/scratch/notes.txt"
retire "$PARENT" keeper
[ "$RC" -ne 0 ] || fail "L4: retirement succeeded although projects/ held a non-git directory"
grep -F "$SLOT/projects/scratch" "$TMP_ROOT/retire-keeper.err" >/dev/null || fail "L4: refusal did not name the non-git directory"
[ -e "$SLOT/projects/scratch/notes.txt" ] && [ "$(cat "$SLOT/.fm-secondmate-home")" = keeper ] ||
  fail "L4: non-git refusal did not leave the home intact"
case "$(slot_state "$SLOT")" in leased*) ;; *) fail "L4: non-git refusal released the lease" ;; esac
printf '# L4 after non-git refusal: slot %s, marker=%s\n' "$(slot_state "$SLOT")" "$(cat "$SLOT/.fm-secondmate-home")"
pass "L4 unpushed work and a non-git directory refuse retirement and keep the home and lease"

# --- L5: a stray .DS_Store does not block ----------------------------------
rm -rf "$SLOT/projects/scratch"
: > "$SLOT/projects/.DS_Store"
retire "$PARENT" keeper
[ "$RC" -eq 0 ] || fail "L5: a stray .DS_Store blocked retirement"
assert_slot_cleared "$SLOT" L5
assert_retired_records "$PARENT" keeper L5
seed "$PARENT" fifth || fail "L5: seeding after the .DS_Store retirement failed"
[ "$(real "$HOME_OUT")" = "$(real "$SLOT")" ] || fail "L5: next seed did not take the retired slot"
pass "L5 a stray .DS_Store under projects/ does not block retirement"

# --- L6a: forced retirement sweeps a nested secondmate on its own slot -----
# fifth seeds its own secondmate from its home; both are leased real slots.
cp "$PARENT/data/projects.md" "$SLOT/data/projects.md" 2>/dev/null || true
seed "$SLOT" nested "$SLOT" || fail "L6: seeding a nested secondmate from fifth's home failed"
CHILD=$HOME_OUT
case "$(real "$CHILD")" in "$(real "$TH_ROOT")"/*) ;; *) fail "L6: nested slot $CHILD is outside this run's pool root" ;; esac
[ "$(real "$CHILD")" != "$(real "$SLOT")" ] || fail "L6: nested secondmate reused its parent's slot"
# Forced cleanup validates every nested home against the retiring parent's
# registry (the shape tests/fm-secondmate-safety.test.sh uses), so the nested
# route is also recorded there.
grep -F -- '- nested ' "$SLOT/data/secondmates.md" >> "$PARENT/data/secondmates.md" ||
  fail "L6: nested seed did not record its route"
printf '# L6 parent slot %s is %s; nested slot %s is %s\n' "$SLOT" "$(slot_state "$SLOT")" "$CHILD" "$(slot_state "$CHILD")"
retire "$PARENT" fifth --force
[ "$RC" -eq 0 ] || fail "L6: forced retirement with a nested secondmate failed"
assert_slot_cleared "$SLOT" "L6 parent"
assert_slot_cleared "$CHILD" "L6 nested"
assert_retired_records "$PARENT" fifth L6
printf '# L6 after forced retirement: parent slot %s, nested slot %s\n' "$(slot_state "$SLOT")" "$(slot_state "$CHILD")"
pass "L6 a forced retirement sweeps a nested secondmate and frees both real slots"

# --- L6b: a failed return restores the home and its process-event state ----
seed "$PARENT" sixth || fail "L6: seeding sixth failed"
SIX=$HOME_OUT
FM_HOME="$SIX" "$SIX/bin/fm-procevent.sh" register lavish live-src -- /bin/sleep 600 >/dev/null 2>"$TMP_ROOT/register.err" ||
  { sed 's/^/#   register| /' "$TMP_ROOT/register.err"; fail "L6: registering a process-event source in sixth failed"; }
printf '# L6 sixth sources before: %s\n' "$(find "$SIX/state/procevent" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')"
: > "$FAIL_RETURN"
retire "$PARENT" sixth
rm -f "$FAIL_RETURN"
[ "$RC" -ne 0 ] || fail "L6: retirement succeeded although the return failed"
grep -F 'treehouse return failed for secondmate home' "$TMP_ROOT/retire-sixth.err" >/dev/null || fail "L6: failed return was not reported"
[ "$(cat "$SIX/.fm-secondmate-home")" = sixth ] || fail "L6: failed return did not put the marker back"
[ -d "$SIX/projects/alpha/.git" ] || fail "L6: failed return did not put the project clone back"
ls "$SIX/state/procevent/"*.source >/dev/null 2>&1 || fail "L6: failed return did not restore the process-event registration"
[ -e "$PARENT/state/sixth.meta" ] || fail "L6: failed return removed sixth.meta"
grep -F -- '- sixth ' "$PARENT/data/secondmates.md" >/dev/null || fail "L6: failed return removed the registry route"
case "$(slot_state "$SIX")" in leased*) ;; *) fail "L6: failed return left the slot '$(slot_state "$SIX")'" ;; esac
printf '# L6 after failed return: slot %s, marker=%s, sources: %s\n' "$(slot_state "$SIX")" "$(cat "$SIX/.fm-secondmate-home")" "$(find "$SIX/state/procevent" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')"
retire "$PARENT" sixth
[ "$RC" -eq 0 ] || fail "L6: retrying the retirement after the failed return failed"
assert_slot_cleared "$SIX" "L6 retry"
assert_retired_records "$PARENT" sixth "L6 retry"
pass "L6 a failed return restores the home and its process-event registration, and a retry frees the slot"

# --- L7: Herdr lab, spawn -> retire -> seed + spawn on the same slot --------
if ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip: L7 needs herdr and jq"
  exit 0
fi
[ -x "$LAB_HELPER" ] || { echo "skip: L7 Herdr lab helper not executable at $LAB_HELPER"; exit 0; }
herdr_forget_inherited_pane
unset FM_BACKEND
LAB_SESSION=$("$LAB_HELPER" name fm-slot-live) || fail "L7: could not name a Herdr lab session"
"$LAB_HELPER" provision "$LAB_SESSION" >/dev/null || fail "L7: could not provision Herdr lab session $LAB_SESSION"
printf '# L7 lab session: %s\n' "$LAB_SESSION"

lab_spawn() { # <id> <home>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$PARENT" \
    "$PRIMARY/bin/fm-spawn.sh" "$1" "$2" "sh -c 'echo slot-live-ok; exec sleep 600'" --secondmate --backend herdr \
    >"$TMP_ROOT/spawn-$1.out" 2>"$TMP_ROOT/spawn-$1.err"
  RC=$?
  printf '# L7 spawn %s rc=%s\n' "$1" "$RC"
  sed 's/^/#   out| /' "$TMP_ROOT/spawn-$1.out"
  [ "$RC" -eq 0 ] || sed 's/^/#   err| /' "$TMP_ROOT/spawn-$1.err"
}
pane_alive() { # <pane-id>
  herdr pane get "$1" --session "$LAB_SESSION" >/dev/null 2>&1
}

rm -f "$PARENT/state/"*.meta
FM_BACKEND=herdr seed "$PARENT" labfirst || fail "L7: seeding labfirst failed"
LAB_SLOT=$HOME_OUT
rm -f "$PARENT/state/labfirst.meta"
lab_spawn labfirst "$LAB_SLOT"
[ "$RC" -eq 0 ] || fail "L7: spawning labfirst in the lab failed"
P1=$(sed -n 's/^herdr_pane_id=//p' "$PARENT/state/labfirst.meta")
if [ -z "$P1" ] || ! pane_alive "$P1"; then fail "L7: labfirst pane is not live"; fi
HERDR_SESSION="$LAB_SESSION" retire "$PARENT" labfirst
[ "$RC" -eq 0 ] || fail "L7: retiring labfirst failed"
! pane_alive "$P1" || fail "L7: retiring labfirst left its pane $P1 open"
assert_slot_cleared "$LAB_SLOT" L7
assert_retired_records "$PARENT" labfirst L7
FM_BACKEND=herdr seed "$PARENT" labsecond || fail "L7: seeding labsecond after retiring labfirst failed"
[ "$(real "$HOME_OUT")" = "$(real "$LAB_SLOT")" ] || fail "L7: labsecond did not take the retired slot"
rm -f "$PARENT/state/labsecond.meta"
lab_spawn labsecond "$LAB_SLOT"
[ "$RC" -eq 0 ] || fail "L7: spawning labsecond on the retired slot failed"
P2=$(sed -n 's/^herdr_pane_id=//p' "$PARENT/state/labsecond.meta")
if [ -z "$P2" ] || ! pane_alive "$P2"; then fail "L7: labsecond pane is not live"; fi
printf '# L7 labsecond pane %s live on slot %s (%s), marker=%s\n' "$P2" "$LAB_SLOT" "$(slot_state "$LAB_SLOT")" "$(cat "$LAB_SLOT/.fm-secondmate-home")"
HERDR_SESSION="$LAB_SESSION" retire "$PARENT" labsecond
[ "$RC" -eq 0 ] || fail "L7: retiring labsecond failed"
assert_slot_cleared "$LAB_SLOT" "L7 final"
pass "L7 in a Herdr lab a secondmate retires and a new one seeds and launches on the same slot"
