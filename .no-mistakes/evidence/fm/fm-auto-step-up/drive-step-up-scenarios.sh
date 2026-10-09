#!/usr/bin/env bash
# Drive the real bin/fm-step-up.sh (and real fm-strategy.sh / fm-control.sh) against disposable lab homes.
set -u
WT=$1
cd "$WT"
STEP="$WT/bin/fm-step-up.sh"
LABS=()
LABLIST=$(mktemp); cleanup() { while IFS= read -r l; do [ -f "$l/.fm-lab-home" ] && rm -rf "$l"; done < "$LABLIST"; rm -f "$LABLIST"; rm -rf "$STUBDIR"; }
trap cleanup EXIT
STUBDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-stepup-stub.XXXXXX")
cat > "$STUBDIR/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/control.argv"; echo "relaunched $1 (recording control stub)"
SH
chmod +x "$STUBDIR/control"
cat > "$STUBDIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
rows=${FM_FAKE_NM_ROWS:-}; n=0; [ -z "$rows" ] || n=1
printf 'repo: %s\ncount: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$PWD" "$n" "$n" "$n"
[ -z "$rows" ] || printf '%s\n' "$rows"
SH
chmod +x "$STUBDIR/no-mistakes"

# Shipped-template-shaped dispatch: ladder slots, no research slot, plus a research rule only when asked.
dispatch() { # [with-research]
  local r=''
  [ "${1:-}" = research ] && r=',{"when":"research","strategy":"research","use":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}}'
  cat <<J
{"rules":[
 {"when":"check","strategy":"check","use":{"harness":"claude","model":"claude-haiku-5-5","effort":"medium"}},
 {"when":"light","strategy":"light","use":{"harness":"claude","model":"claude-sonnet-5-5","effort":"medium"}},
 {"when":"standard","strategy":"standard","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"}},
 {"when":"hard","strategy":"hard","use":{"harness":"claude","model":"claude-opus-5-5","effort":"high"}}$r
],"default":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}}
J
}

# lab <autonomy|-> <kind> <mode> <harness> <model> <effort> [research]
lab() {
  local L; L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$L"
  bin/fm-lab-home.sh create "$L" >/dev/null || exit 9
  echo "$L" >> "$LABLIST"
  if [ "$1" != - ]; then
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$L" bin/fm-strategy.sh set "$1" --providers claude,codex --yes >/dev/null 2>&1 \
      || { echo "fm-strategy set $1 failed" >&2; exit 9; }
  else dispatch > "$L/config/crew-dispatch.json"
  fi
  if [ "${7:-}" = research ]; then
    jq '.rules += [{"when":"research","strategy":"research","use":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}}]' "$L/config/crew-dispatch.json" > "$L/x" && mv "$L/x" "$L/config/crew-dispatch.json"
  fi
  git init -q "$L/projects/app"; git -C "$L/projects/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "kind=$2" "mode=$3" "harness=$4" "model=$5" "effort=$6" "worktree=$L/projects/app" "branch=fm/t1" "project=$L/projects/app" > "$L/state/t1.meta"
  : > "$L/state/t1.status"
  printf '%s' "$L"
}
say() { printf '%s\n' "$2" >> "$1/state/t1.status"; }
run() { # <lab> <args...>  (prints command + output + exit)
  local L=$1; shift
  printf '\n$ fm-step-up.sh t1 %s\n' "$*"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$STUBDIR:$PATH" FM_HOME="$L" ${CTRL:+FM_STEP_UP_CONTROL_BIN=$CTRL} bash "$STEP" t1 "$@" 2>&1
  printf '[exit %s]\n' "$?"
}
status() { printf -- '--- %s/state/t1.status (tail) ---\n' "$(basename "$1")"; tail -n "${2:-3}" "$1/state/t1.status" | sed 's/^/  /'; }
hdr() { printf '\n=================== %s ===================\n' "$1"; }

CTRL="$STUBDIR/control"

hdr "S1 terminal capability failed: on light (full) steps once to standard, in place"
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
grep autonomy "$L/config/strategy"
say "$L" 'working: implementing parser'
say "$L" 'failed: could not explain why the parser test fails'
run "$L" plan --trigger failed --cause 'cannot explain a failure'
run "$L" apply --trigger failed --cause 'cannot explain a failure'
run "$L" apply --trigger failed --cause 'cannot explain a failure' --harness codex --model gpt-6-sol --effort medium
echo "--- relaunch argv handed to fm-control ---"; sed 's/^/  /' "$L/control.argv"
status "$L"
hdr "S2 one step per task: second step on the same task refused"
say "$L" 'failed: still red after step (tier: standard, stepped up from light)'
run "$L" apply --trigger failed --cause 'still cannot explain'

hdr "S3 external failure (CI / quota) never steps"
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'failed: CI runner out of disk space'
run "$L" apply --trigger failed --cause 'tests could not run'
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'failed: tool error'
run "$L" apply --trigger failed --cause 'hit the API rate limit / quota'
ls "$L/control.argv" 2>/dev/null || echo "(no relaunch issued)"

hdr "S4 non-terminal latest event does not trigger failed"
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'failed: misread brief'; say "$L" 'working: retrying'
run "$L" plan --trigger failed --cause 'misread the brief'

hdr "S5 blocked: capability blocker (recovery could not clear) steps and resolves the blocker"
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'blocked [key=loop]: looping on the same edit, asks what the brief already answered'
run "$L" apply --trigger blocked --cause 'looping; asks questions the brief answered' --harness claude --model claude-opus-5-5 --effort medium
status "$L" 2
L=$(lab full ship direct-PR claude claude-haiku-5-5 medium)
say "$L" 'needs-decision [key=scope]: which API?'; say "$L" 'blocked [key=b]: looping'
run "$L" plan --trigger blocked --cause 'looping'

hdr "S6 second Test-step failure triggers; first does not; recording never masks a terminal failed:"
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'working: Test step running'
run "$L" test-failure --cause 'Test step red: parser spec'
run "$L" plan --trigger test-failure --cause 'Test step red twice'
run "$L" test-failure --cause 'Test step red again: parser spec'
run "$L" plan --trigger test-failure --cause 'Test step red twice'
say "$L" 'failed: Test step still red'
run "$L" test-failure --cause 'Test step red a third time'
status "$L" 1

hdr "S7 hard tier is never stepped (goes to captain)"
L=$(lab full ship direct-PR claude claude-opus-5-5 high)
say "$L" 'failed: cannot find the root cause'
run "$L" apply --trigger failed --cause 'cannot find the root cause'

hdr "S8 research scout never stepped; a ship on the same profile still steps"
L=$(lab full scout - claude claude-opus-5-5 medium research)
say "$L" 'failed: could not answer the research question'
run "$L" apply --trigger failed --cause 'could not answer' --harness claude --model claude-opus-5-5 --effort high
L=$(lab full ship direct-PR claude claude-opus-5-5 medium research)
# ship on the research-shared standard profile
say "$L" 'failed: misread instructions'
run "$L" apply --trigger failed --cause 'misread instructions' --harness claude --model claude-opus-5-5 --effort high
grep -o 'stepped up from .*' "$L/state/t1.status" | sed 's/^/  record: /'

hdr "S9 validation custody: concluded run refuses; live run is reattached, never a second run"
L=$(lab full ship no-mistakes claude claude-sonnet-5-5 low)
say "$L" 'failed: misread instructions'
FM_FAKE_NM_ROWS='  "01RUNDONE",fm/t1,failed,0123abcd,""' run "$L" plan --trigger failed --cause 'misread instructions'
FM_FAKE_NM_ROWS='  "01RUNLIVE",fm/t1,running,0123abcd,""' run "$L" apply --trigger failed --cause 'misread instructions' --harness claude --model claude-opus-5-5 --effort medium
grep -o 'A validation run already owns.*' "$L/control.argv" | sed 's/^/  note: /'

hdr "S10 posture: balanced asks the captain; --captain-approved then steps"
L=$(lab balanced ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'failed: misread instructions'
run "$L" apply --trigger failed --cause 'misread instructions'
run "$L" apply --trigger failed --cause 'misread instructions' --captain-approved --harness claude --model claude-opus-5-5 --effort medium

hdr "S11 real fm-control.sh relaunch failure still uses the step and surfaces a blocker"
CTRL=''
L=$(lab full ship direct-PR claude claude-sonnet-5-5 low)
say "$L" 'failed: cannot explain a failure'
run "$L" apply --trigger failed --cause 'cannot explain a failure' --harness claude --model claude-opus-5-5 --effort medium
status "$L" 2
run "$L" plan --trigger failed --cause 'cannot explain a failure'
