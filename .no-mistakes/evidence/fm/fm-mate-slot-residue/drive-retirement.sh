#!/usr/bin/env bash
# Drives real fm-home-seed.sh / fm-teardown.sh (from CODE_ROOT) against a
# pool-like fake treehouse and fake tmux; real git, real lsof, real processes.
# Usage: drive-retirement.sh <worktree-for-helpers> <code-root> <scenario>
set -u
W=$1; CODE_ROOT=$2; SC=$3
. "$W/tests/secondmate-helpers.sh"
ROOT=$CODE_ROOT
TMP_ROOT=$(fm_test_tmproot drive-retire)
export FM_BACKEND=tmux
eval "$(sed -n '/^install_pool_like_treehouse()/,/^}/p;/^seed_pooled_secondmate()/,/^}/p;/^make_pooled_secondmate_fixture()/,/^}/p' "$W/tests/fm-secondmate-safety.test.sh")"
make_pooled_secondmate_fixture drv
teardown() { PATH="${TPATH:-$POOL_FAKEBIN:$PATH}" FM_HOME="$POOL_HOME" FM_FAKE_TMUX_LOG="$POOL_LOG" \
  FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/drv-fake/pane.txt" "$POOL_PRIMARY/bin/fm-teardown.sh" "$@"; }
show_slot() { echo "--- slot contents ($POOL_SLOT):"; ls -A "$POOL_SLOT" | grep -E '^(\.fm-secondmate|data|state|config|projects)' || echo "(no home-owned entries left)"; echo "--- parent meta: $(ls "$POOL_HOME/state" 2>/dev/null | tr '\n' ' ')"; }
echo "=== seed secondmate 'first' onto pooled slot"
seed_pooled_secondmate "$POOL_PRIMARY" "$POOL_HOME" "$POOL_SLOT" first "$POOL_FAKEBIN" "$POOL_LOG" >/dev/null 2>&1 && echo "seed first: rc=0"
PID=
case "$SC" in
  reap|nolsof)
    ( cd "$POOL_SLOT/projects/alpha" && exec sleep 300 ) </dev/null >/dev/null 2>&1 &
    PID=$!; disown $PID; sleep 0.3
    echo "=== detached leftover process pid=$PID cwd=$(lsof -a -p $PID -d cwd -Fn | sed -n 's/^n//p')"
    ;;
  dsstore) : > "$POOL_SLOT/projects/.DS_Store"; echo "=== wrote stray $POOL_SLOT/projects/.DS_Store" ;;
  nongit) mkdir "$POOL_SLOT/projects/scratch"; echo x > "$POOL_SLOT/projects/scratch/f"; echo "=== created non-git dir projects/scratch" ;;
  unlanded) echo work > "$POOL_SLOT/projects/alpha/w.txt"; git -C "$POOL_SLOT/projects/alpha" add w.txt; git -C "$POOL_SLOT/projects/alpha" -c user.name=t -c user.email=t@x commit -qm unlanded; echo "=== committed unpushed work in projects/alpha" ;;
esac
if [ "$SC" = nolsof ]; then
  NB="$TMP_ROOT/nolsof-bin"; mkdir -p "$NB"
  for d in /usr/bin /bin /opt/homebrew/bin /usr/local/bin; do :; done
  TPATH="$POOL_FAKEBIN:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx /usr/sbin | grep -vx /sbin | paste -sd: -)"
  echo "=== teardown PATH without lsof: $(PATH=$TPATH command -v lsof || echo 'lsof not found')"
fi
echo "=== fm-teardown.sh first (no --force)"
teardown first 2>&1 | sed 's/^/  | /'; echo "teardown rc=${PIPESTATUS[0]}"
if [ -n "$PID" ]; then
  if kill -0 $PID 2>/dev/null; then echo "leftover pid $PID: STILL ALIVE"; kill -KILL $PID; else echo "leftover pid $PID: gone"; fi
fi
show_slot
echo "=== seed secondmate 'second' onto the same slot"
PATH="$POOL_FAKEBIN:$PATH" FM_HOME="$POOL_HOME" FM_FAKE_TREEHOUSE_HOME="$POOL_SLOT" FM_FAKE_TMUX_LOG="$POOL_LOG" \
  FM_SECONDMATE_CHARTER="second scope" FM_SECONDMATE_SCOPE="second scope" \
  "$POOL_PRIMARY/bin/fm-home-seed.sh" second - alpha > "$TMP_ROOT/seed2.out" 2>&1; rc=$?
tail -2 "$TMP_ROOT/seed2.out" | sed 's/^/  | /'
echo "fm-home-seed.sh second rc=$rc; slot marker now=$(cat "$POOL_SLOT/.fm-secondmate-home" 2>/dev/null)"
