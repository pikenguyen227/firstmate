#!/usr/bin/env bash
# Drives the real bin/ entry points (fm_task_inbox_write, fm-wake-drain.sh) against
# a throwaway FM_HOME. Usage: drive-lifecycle.sh <root> <scenario> <iterations>
set -u
ROOT=$1 SC=$2 N=$3
DRAIN="$ROOT/bin/fm-wake-drain.sh"
T=$(mktemp -d /tmp/fmdrive.XXXX); trap 'rm -rf "$T"' EXIT
meta() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }
lc() { local home=$1; shift; FM_HOME="$home" bash -c 'set -eu; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-task-inbox-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
feed() { cat "$1"/data/lifecycle/events.v1*.jsonl 2>/dev/null | jq -cs 'sort_by(.seq)'; }
newhome() { local h="$T/$1/home"; mkdir -p "$h/state" "$h/data" "$h/config"; touch "$h/state/.last-watcher-beat"; echo "$h"; }
drain() { FM_HOME="$1" FM_ROOT_OVERRIDE='' "$DRAIN" >/dev/null 2>&1; }
pass=0 failn=0
for it in $(seq 1 "$N"); do
  h=$(newhome "$SC$it"); s="$h/state"
  case $SC in
  steers)
    meta "$s/t1.meta" kind=ship spawn_gen=s1790000000.11.22
    lc "$h" fm_lifecycle_task_spawned "$s" t1 0
    pids=()
    for i in 1 2 3 4 5 6 7 8; do meta "$s/w$i.meta" kind=ship "spawn_gen=s1790000000.$i.1"
      lc "$h" fm_task_inbox_write "$s" "w$i" "steer $i" >/dev/null & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p"; done
    got=$(feed "$h" | jq '[.[]|select(.type=="task.steered")]|length')
    gapfree=$(feed "$h" | jq '(map(.seq)==[range(1;length+1)]) and ((map(.key)|unique|length)==length)')
    detail="steers=$got gapfree=$gapfree"; [ "$got" = 8 ] && [ "$gapfree" = true ] ;;
  reuse)
    meta "$s/t1.meta" kind=ship spawn_gen=s1790000000.1.1
    lc "$h" fm_lifecycle_task_spawned "$s" t1 0
    printf '%s\n' 'working [at=1790000010]: first life' 'working [at=1790000011]: still first' > "$s/t1.status"
    drain "$h"; lc "$h" fm_lifecycle_task_torn_down "$s" t1 0 remove "" ""
    rm -f "$s/t1.status" "$s/t1.meta"
    meta "$s/t1.meta" kind=ship spawn_gen=s1790000500.2.2
    printf '%s\n' 'working [at=1790000510]: second life' > "$s/t1.status"
    lc "$h" fm_lifecycle_task_spawned "$s" t1 0; drain "$h"
    last=$(feed "$h" | jq -c '[.[]|select(.type=="task.status")][-1]|{key,note:.data.note}')
    detail="last=$last"; [ "$last" = '{"key":"status/t1/s1790000500.2.2/@0","note":"second life"}' ] ;;
  sameident)
    # in-place rewrites keep device:inode:birth identical on every platform
    st="$s/t1.status"; meta "$s/t1.meta" kind=ship spawn_gen=s1790000500.2.2
    lc "$h" fm_lifecycle_task_spawned "$s" t1 0
    printf '%s\n' 'working [at=1790000510]: log1 a' > "$st"; drain "$h"
    printf '%s\n' 'working [at=1790000600]: log2 a' 'working [at=1790000601]: log2 b' 'working [at=1790000602]: log2 c' > "$st"; drain "$h"
    printf '%s\n' 'working [at=1790000700]: log3 a' > "$st"; drain "$h"
    printf '%s\n' 'working [at=1790000600]: log2 a' 'working [at=1790000800]: log4 b' > "$st"; drain "$h"
    printf '%s\n' 'working [at=1790000700]: log3 a' 'working [at=1790000900]: log5 b' > "$st"; drain "$h"
    notes=$(feed "$h" | jq -c '[.[]|select(.type=="task.status")|.data.note]')
    keys=$(feed "$h" | jq -c '[.[]|select(.type=="task.status")|.key]')
    uniq=$(feed "$h" | jq '[.[]|select(.type=="task.status")|.key|sub("/@[0-9]+$";"")]|unique|length')
    detail="notes=$notes streams=$uniq keys=$keys"
    [ "$notes" = '["log1 a","log2 a","log2 b","log2 c","log3 a","log2 a","log4 b","log3 a","log5 b"]' ] && [ "$uniq" = 5 ] ;;
  esac
  if [ $? -eq 0 ]; then pass=$((pass+1)); r=PASS; else failn=$((failn+1)); r=FAIL; fi
  echo "[$SC #$it] $r $detail"
  [ "$r" = PASS ] || { echo "  emit-errors: $(cat "$h"/data/lifecycle/emit-errors.log 2>/dev/null | tr '\n' '|')"; }
done
echo "== $SC on $ROOT: $pass pass, $failn fail of $N"
