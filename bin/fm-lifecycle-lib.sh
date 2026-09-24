#!/usr/bin/env bash
# fm-lifecycle-lib.sh - the append-only `fm-lifecycle.v1` lifecycle event feed.
#
# docs/configuration.md "Lifecycle event feed (data/lifecycle)" owns the
# consumer contract: file layout, envelope, event types, keys, time sources,
# rotation, and the fm-fleet-snapshot.v1 discovery pointer. This header owns
# the writer mechanics below; nothing else restates either.
#
# Best-effort by construction. Every public fm_lifecycle_* entry point runs its
# body in a subshell with errexit and nounset off, discards stdout and stderr,
# waits at most FM_LIFECYCLE_LOCK_WAIT seconds for the home lock, and returns 0
# whatever happens, so an emit can never fail, abort, or print into the spawn,
# teardown, promote, steer, wake-drain, or watcher path that calls it. A failure
# after the feed directory resolves is appended to <feed-dir>/emit-errors.log
# (rotated once past 256 KiB); the event itself is lost, and the gap-free `seq`
# lets a reader see nothing more than that it was never written.
#
# Where the feed lives. FM_LIFECYCLE_DIR wins; otherwise FM_DATA_OVERRIDE's
# lifecycle/ directory; otherwise $FM_HOME/data/lifecycle, but only when the
# caller's state directory is that same home's state/ (textually or after
# canonicalizing). A caller whose state directory belongs to no resolvable home
# - a fixture that overrides only its state directory - emits nothing rather
# than writing into whatever home FM_HOME defaulted to. The data directory must
# already exist. FM_LIFECYCLE=off (also 0, false, no) disables every emit.
#
# Writing. One home lock (<feed-dir>/.lock, the portable owner-recorded lock
# from bin/fm-wake-lib.sh) serializes every batch. Under it the writer reads
# the last `seq` from the active feed's tail (falling back to <feed-dir>/head,
# then the newest rotated file) before rotating the active file past
# FM_LIFECYCLE_ROTATE_BYTES, terminates a torn final line left by a crash, and
# appends the whole batch in one write before rewriting head. The first event a feed ever holds
# is `feed.started`. "Once" batches (backfill and cursor recovery) first drop
# every event whose `key` already appears in any feed file.
#
# Status transcription keeps its own per-task cursor,
# state/.<task>.lifecycle-cursor: `version`, `stream` (fixed when this status
# file is first transcribed by _fm_lifecycle_stream_pick, which anchors every
# key read from it), `offset`, `ident` (the status file identity from
# bin/fm-classify-lib.sh), `spawned` (the last spawn_gen recorded as
# task.spawned), then the folded open-decision set in that library's
# "<key>\t<verb>\t<note>" form. Each pass reads only bytes past `offset`, and
# only through the last complete line unless it is the teardown flush, folds
# decision lines through the same _fm_decision_fold_line the wake drain uses,
# and replaces the cursor atomically after the batch lands; the span is read
# through the lock holder's scratch file <feed-dir>/.span. A pass handles at
# most FM_LIFECYCLE_TRANSCRIBE_CHUNK lines per lock hold. A replaced status
# file (new identity) starts a new stream, suffixed with its identity, and a
# truncated one re-reads from byte 0; both are "once" batches, so a re-read
# never duplicates a key. The wake drain transcribes every task; teardown
# flushes the tail and pending acknowledgements and records task.torn_down
# before the task's status, metadata, and inbox are deleted, leaving the cursor
# at the end of the log for the next drain to retire once both records are gone.
# A fresh spawn restarts a cursor that does not follow its current status log.
#
# Steering. task.steered is recorded when a new inbox record is written, with
# metadata only (sequence, delivery mode, body byte count, SHA-256), never the
# body. task.steer_acked is recorded the first time the watcher, a teardown, or
# a backfill finds a record in handled/; <task>.inbox/.lifecycle-acked lists the
# records already recorded and is removed with the inbox.
#
# Tunables (env):
#   FM_LIFECYCLE                    off|0|false|no disables the feed (default on)
#   FM_LIFECYCLE_DIR                explicit feed directory
#   FM_LIFECYCLE_LOCK_WAIT          whole seconds to wait for the lock (default 2)
#   FM_LIFECYCLE_ROTATE_BYTES       active-file rotation size (default 16777216)
#   FM_LIFECYCLE_TRANSCRIBE_CHUNK   status lines per lock hold (default 64)
#
# Sourced by bin/fm-spawn.sh, bin/fm-teardown.sh, bin/fm-promote.sh,
# bin/fm-task-inbox-lib.sh (and through it bin/fm-watch.sh), bin/fm-wake-drain.sh,
# bin/fm-fleet-snapshot.sh, and bin/fm-lifecycle.sh. No side effects on source;
# bin/fm-wake-lib.sh and bin/fm-classify-lib.sh are loaded on first use when the
# caller has not already sourced them.

_FM_LIFECYCLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_LIFECYCLE_DEFAULT_ROOT="$(cd "$_FM_LIFECYCLE_LIB_DIR/.." && pwd)"

FM_LIFECYCLE_SCHEMA='fm-lifecycle.v1'
FM_LIFECYCLE_CURSOR_VERSION=1
FM_LIFECYCLE_NOTE_MAX=200
_FM_LIFECYCLE_US=$'\037'
_FM_LIFECYCLE_CTRL=$'[\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037]'
_FM_LIFECYCLE_BATCH=()
_FM_LIFECYCLE_WRITTEN=0
_FM_LIFECYCLE_EMITTED=0

# --- resolution ----------------------------------------------------------------

_fm_lifecycle_disabled() {
  case "${FM_LIFECYCLE:-on}" in off|OFF|0|false|no) return 0 ;; esac
  return 1
}

_fm_lifecycle_home() {  # <outvar>
  printf -v "$1" '%s' "${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_ROOT:-$_FM_LIFECYCLE_DEFAULT_ROOT}}}"
}

_fm_lifecycle_same_dir() {  # <a> <b>
  local a b
  [ "$1" = "$2" ] && return 0
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [ "$a" = "$b" ]
}

# Feed directory for a caller's state directory, or 1 when the feed is off or
# the caller belongs to no resolvable home (see the header).
fm_lifecycle_feed_dir() {  # <state> <outvar>
  local __st=$1 __home __data __dir=''
  _fm_lifecycle_disabled && return 1
  if [ -n "${FM_LIFECYCLE_DIR:-}" ]; then
    __dir=$FM_LIFECYCLE_DIR
    __data=${__dir%/*}
  elif [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    __data=$FM_DATA_OVERRIDE
  else
    _fm_lifecycle_home __home
    _fm_lifecycle_same_dir "$__st" "$__home/state" || return 1
    __data=$__home/data
  fi
  [ -d "$__data" ] || return 1
  [ -n "$__dir" ] || __dir=$__data/lifecycle
  printf -v "$2" '%s' "$__dir"
}

_fm_lifecycle_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_LIFECYCLE_LIB_DIR/fm-wake-lib.sh"
}

_fm_lifecycle_require_classify() {
  command -v _fm_decision_fold_line >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_LIFECYCLE_LIB_DIR/fm-classify-lib.sh"
}

_fm_lifecycle_log() {  # <dir> <message>
  local log="$1/emit-errors.log" size
  [ -d "$1" ] || return 0
  if [ -f "$log" ]; then
    size=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -lt 262144 ] || mv -f "$log" "$log.1" 2>/dev/null
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$log" 2>/dev/null
}

# --- small pure helpers ----------------------------------------------------------

_fm_lifecycle_bytelen() {  # <string> <outvar>
  local LC_ALL=C
  printf -v "$2" '%s' "${#1}"
}

# JSON string literal, control characters escaped or dropped.
_fm_lifecycle_jstr() {  # <value> <outvar>
  local __s=$1
  __s=${__s//\\/\\\\}
  __s=${__s//\"/\\\"}
  __s=${__s//$'\n'/\\n}
  __s=${__s//$'\r'/\\r}
  __s=${__s//$'\t'/\\t}
  __s=${__s//$_FM_LIFECYCLE_CTRL/}
  printf -v "$2" '"%s"' "$__s"
}

_fm_lifecycle_uint_ok() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

# Build a JSON object from specs: name=string, name?=string-or-null-when-empty,
# name#=number-or-null, name!=raw-json.
_fm_lifecycle_obj() {  # <outvar> <spec>...
  local __out=$1 __acc='' __spec __name __val __j
  shift
  for __spec in "$@"; do
    __name=${__spec%%=*}
    __val=${__spec#*=}
    case "$__name" in
      *\?) __name=${__name%\?}; if [ -n "$__val" ]; then _fm_lifecycle_jstr "$__val" __j; else __j=null; fi ;;
      *\#) __name=${__name%\#}; if _fm_lifecycle_uint_ok "$__val"; then __j=$__val; else __j=null; fi ;;
      *!) __name=${__name%!}; __j=${__val:-null} ;;
      *) _fm_lifecycle_jstr "$__val" __j ;;
    esac
    __acc="$__acc${__acc:+,}\"$__name\":$__j"
  done
  printf -v "$__out" '{%s}' "$__acc"
}

_fm_lifecycle_cap() {  # <text> <outvar>
  local __t=$1
  if [ "${#__t}" -gt "$FM_LIFECYCLE_NOTE_MAX" ]; then
    __t="${__t:0:$FM_LIFECYCLE_NOTE_MAX}"
  fi
  printf -v "$2" '%s' "$__t"
}

# Load a task metadata record once, then read fields from the loaded copy.
_FM_LIFECYCLE_META=''
_fm_lifecycle_meta_load() {  # <meta>
  local __line
  _FM_LIFECYCLE_META=''
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 0
  while IFS= read -r __line || [ -n "$__line" ]; do
    _FM_LIFECYCLE_META="$_FM_LIFECYCLE_META$__line"$'\n'
  done < "$1"
}

_fm_lifecycle_mget() {  # <field> <outvar>; the last occurrence wins
  local __line __v=''
  while IFS= read -r __line; do
    case "$__line" in "$1="*) __v=${__line#"$1="} ;; esac
  done <<EOF
$_FM_LIFECYCLE_META
EOF
  printf -v "$2" '%s' "$__v"
}

_fm_lifecycle_now() {  # <outvar>
  local __n=''
  printf -v __n '%(%s)T' -1 2>/dev/null || __n=''
  _fm_lifecycle_uint_ok "$__n" || __n=$(date +%s 2>/dev/null) || __n=''
  _fm_lifecycle_uint_ok "$__n" || __n=''
  printf -v "$1" '%s' "$__n"
}

# One stat call for a file's identity (device, inode, birth time where the
# platform records it) and its byte size.
_fm_lifecycle_stat() {  # <file> <ident-outvar> <size-outvar>
  local __out='' __os=${_FM_UNAME:-${_FM_LIFECYCLE_UNAME:-}}
  if [ -z "$__os" ]; then
    _FM_LIFECYCLE_UNAME=$(uname -s 2>/dev/null)
    __os=$_FM_LIFECYCLE_UNAME
  fi
  if [ "$__os" = Darwin ]; then
    __out=$(LC_ALL=C /usr/bin/stat -f '%d:%i:%B %z' "$1" 2>/dev/null) || return 1
  else
    __out=$(LC_ALL=C stat -c '%d:%i:%W %s' "$1" 2>/dev/null) \
      || __out=$(LC_ALL=C stat -c '%d:%i %s' "$1" 2>/dev/null) || return 1
  fi
  case "$__out" in *' '*) ;; *) return 1 ;; esac
  _fm_lifecycle_uint_ok "${__out##* }" || return 1
  printf -v "$2" '%s' "${__out% *}"
  printf -v "$3" '%s' "${__out##* }"
}

# --- the locked batch writer -------------------------------------------------------

# Queue one event for the next batch write.
_fm_lifecycle_queue() {  # <type> <task> <spawn-gen> <key> <at> <at-source> <backfill> <data-json>
  local __f __rec='' __i=0
  for __f in "$@"; do
    __f=${__f//$_FM_LIFECYCLE_US/}
    if [ "$__i" -eq 0 ]; then __rec=$__f; else __rec="$__rec$_FM_LIFECYCLE_US$__f"; fi
    __i=$((__i + 1))
  done
  _FM_LIFECYCLE_BATCH+=("$__rec")
}

_fm_lifecycle_lock() {  # <dir>
  local wait=${FM_LIFECYCLE_LOCK_WAIT:-2} deadline now
  case "$wait" in ''|*[!0-9]*) wait=2 ;; esac
  _fm_lifecycle_require_locks || return 1
  mkdir -p "$1" 2>/dev/null || return 1
  fm_lock_try_acquire "$1/.lock" && return 0
  deadline=$(( $(date +%s) + wait ))
  while :; do
    sleep 0.05
    fm_lock_try_acquire "$1/.lock" && return 0
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
  done
}

_fm_lifecycle_unlock() {  # <dir>
  fm_lock_release "$1/.lock" 2>/dev/null || true
}

_FM_LIFECYCLE_HOME_JSON_DIR=''
_FM_LIFECYCLE_HOME_JSON=''
_fm_lifecycle_home_json() {  # <dir> <outvar>
  local __dir=$1 __id='' __home __path __jid __jpath
  if [ "$_FM_LIFECYCLE_HOME_JSON_DIR" = "$__dir" ] && [ -f "$__dir/home-id" ]; then
    printf -v "$2" '%s' "$_FM_LIFECYCLE_HOME_JSON"
    return 0
  fi
  if [ -f "$__dir/home-id" ]; then
    IFS= read -r __id < "$__dir/home-id" || true
  fi
  case "$__id" in fmh_[0-9a-f]*) ;; *)
    __id="fmh_$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$__id" in fmh_[0-9a-f][0-9a-f]*) ;; *) __id="fmh_$(date +%s)$$" ;; esac
    printf '%s\n' "$__id" > "$__dir/home-id.tmp.$$" && mv -f "$__dir/home-id.tmp.$$" "$__dir/home-id" || return 1
    ;;
  esac
  _fm_lifecycle_home __home
  __path=$(cd "$__home" 2>/dev/null && pwd -P) || __path=$__home
  _fm_lifecycle_jstr "$__id" __jid
  _fm_lifecycle_jstr "$__path" __jpath
  _FM_LIFECYCLE_HOME_JSON="{\"id\":$__jid,\"path\":$__jpath,\"host\":null}"
  _FM_LIFECYCLE_HOME_JSON_DIR=$__dir
  printf -v "$2" '%s' "$_FM_LIFECYCLE_HOME_JSON"
}

# Last seq in a feed file's tail; returns 1 when none is readable.
_fm_lifecycle_tail_seq() {  # <file> <outvar>
  local __ts_t __ts_rest __ts_seq
  [ -s "$1" ] || return 1
  __ts_t=$(tail -c 4096 "$1" 2>/dev/null) || return 1
  case "$__ts_t" in *'"seq":'*) ;; *) __ts_t=$(tail -c 65536 "$1" 2>/dev/null) || return 1 ;; esac
  case "$__ts_t" in *'"seq":'*) ;; *) return 1 ;; esac
  __ts_rest=${__ts_t##*\"seq\":}
  __ts_seq=${__ts_rest%%[!0-9]*}
  _fm_lifecycle_uint_ok "$__ts_seq" || return 1
  printf -v "$2" '%s' "$__ts_seq"
}

_fm_lifecycle_last_seq() {  # <dir> <outvar>
  local __dir=$1 __seq='' __f __best='' __n __bn=0
  if _fm_lifecycle_tail_seq "$__dir/events.v1.jsonl" __seq; then
    printf -v "$2" '%s' "$__seq"
    return 0
  fi
  if [ -f "$__dir/head" ]; then
    IFS= read -r __seq < "$__dir/head" || true
    if _fm_lifecycle_uint_ok "$__seq"; then printf -v "$2" '%s' "$__seq"; return 0; fi
  fi
  for __f in "$__dir"/events.v1.*.jsonl; do
    [ -f "$__f" ] || continue
    __n=${__f##*/events.v1.}
    __n=${__n%.jsonl}
    _fm_lifecycle_uint_ok "$__n" || continue
    if [ -z "$__best" ] || [ "$__n" -gt "$__bn" ]; then __best=$__f; __bn=$__n; fi
  done
  if [ -n "$__best" ] && _fm_lifecycle_tail_seq "$__best" __seq; then
    printf -v "$2" '%s' "$__seq"
    return 0
  fi
  printf -v "$2" '0'
}

_fm_lifecycle_rotate() {  # <dir>
  local feed="$1/events.v1.jsonl" max=${FM_LIFECYCLE_ROTATE_BYTES:-16777216} size ident first rest
  case "$max" in ''|*[!0-9]*|0) max=16777216 ;; esac
  [ -s "$feed" ] || return 0
  _fm_lifecycle_stat "$feed" ident size || return 1
  [ "$size" -ge "$max" ] || return 0
  first=$(head -c 4096 "$feed" 2>/dev/null) || return 1
  rest=${first#*\"seq\":}
  first=${rest%%[!0-9]*}
  _fm_lifecycle_uint_ok "$first" || return 1
  [ ! -e "$1/events.v1.$first.jsonl" ] || return 1
  mv "$feed" "$1/events.v1.$first.jsonl"
}

# Write every queued event under the already-held lock. <once> drops events
# whose key is already in any feed file. Sets _FM_LIFECYCLE_WRITTEN.
_fm_lifecycle_write_batch_locked() {  # <dir> <once>
  local dir=$1 once=$2 feed="$1/events.v1.jsonl" last now home_json existing='' keys='' rec out='' n=0
  local type task gen key at src bf data jkey jtype jsrc jtask jgen task_json at_json line f files=() rev started=0
  _FM_LIFECYCLE_WRITTEN=0
  [ "${#_FM_LIFECYCLE_BATCH[@]}" -gt 0 ] || return 0
  _fm_lifecycle_home_json "$dir" home_json || return 1
  # Read the last seq from the active file before it can rotate away: head is
  # only advisory and may trail a write that landed just before a crash.
  _fm_lifecycle_last_seq "$dir" last
  _fm_lifecycle_rotate "$dir" || _fm_lifecycle_log "$dir" "rotation skipped: could not rotate $feed"
  _fm_lifecycle_now now
  [ -n "$now" ] || return 1
  if [ "$last" = 0 ] && [ ! -s "$feed" ]; then
    rev=$(git -C "$_FM_LIFECYCLE_DEFAULT_ROOT" rev-parse HEAD 2>/dev/null) || rev=''
    _fm_lifecycle_obj data "firstmate_rev?=$rev"
    started=1
    _FM_LIFECYCLE_BATCH=("feed.started$_FM_LIFECYCLE_US$_FM_LIFECYCLE_US${_FM_LIFECYCLE_US}started$_FM_LIFECYCLE_US$now${_FM_LIFECYCLE_US}firstmate${_FM_LIFECYCLE_US}false$_FM_LIFECYCLE_US$data" "${_FM_LIFECYCLE_BATCH[@]}")
  fi
  if [ "$once" = 1 ]; then
    for f in "$dir"/events.v1*.jsonl; do [ -f "$f" ] && files+=("$f"); done
    if [ "${#files[@]}" -gt 0 ]; then
      for rec in "${_FM_LIFECYCLE_BATCH[@]}"; do
        IFS=$_FM_LIFECYCLE_US read -r type task gen key at src bf data <<< "$rec"
        _fm_lifecycle_jstr "$key" jkey
        keys="$keys\"key\":$jkey,"$'\n'
      done
      printf '%s' "$keys" > "$dir/.keys.$$" || return 1
      existing=$(grep -hoF -f "$dir/.keys.$$" "${files[@]}" 2>/dev/null)
      rm -f "$dir/.keys.$$"
    fi
  fi
  for rec in "${_FM_LIFECYCLE_BATCH[@]}"; do
    IFS=$_FM_LIFECYCLE_US read -r type task gen key at src bf data <<< "$rec"
    _fm_lifecycle_jstr "$key" jkey
    if [ -n "$existing" ]; then
      case $'\n'"$existing"$'\n' in *$'\n'"\"key\":$jkey,"$'\n'*) continue ;; esac
    fi
    _fm_lifecycle_jstr "$type" jtype
    _fm_lifecycle_jstr "$src" jsrc
    if [ -n "$task" ]; then
      _fm_lifecycle_jstr "$task" jtask
      if [ -n "$gen" ]; then _fm_lifecycle_jstr "$gen" jgen; else jgen=null; fi
      task_json="{\"id\":$jtask,\"spawn_gen\":$jgen}"
    else
      task_json=null
    fi
    if _fm_lifecycle_uint_ok "$at"; then at_json=$at; else at_json=null; fi
    [ "$bf" = true ] || bf=false
    [ -n "$data" ] || data='{}'
    last=$((last + 1))
    line="{\"schema\":\"$FM_LIFECYCLE_SCHEMA\",\"home\":$home_json,\"seq\":$last,\"key\":$jkey,\"type\":$jtype,\"at\":$at_json,\"at_source\":$jsrc,\"recorded_at\":$now,\"task\":$task_json,\"backfill\":$bf,\"data\":$data}"
    out="$out$line"$'\n'
    n=$((n + 1))
  done
  _FM_LIFECYCLE_BATCH=()
  [ "$n" -gt 0 ] || return 0
  if [ -s "$feed" ] && [ -n "$(tail -c 1 "$feed" 2>/dev/null)" ]; then
    printf '\n' >> "$feed" || return 1
  fi
  printf '%s' "$out" >> "$feed" || return 1
  printf '%s\n' "$last" > "$dir/head" 2>/dev/null
  _FM_LIFECYCLE_WRITTEN=$n
  _FM_LIFECYCLE_EMITTED=$((_FM_LIFECYCLE_EMITTED + n - started))
  return 0
}

# Take the lock, write the queued batch, release. Drops the batch on failure.
_fm_lifecycle_flush() {  # <dir> <once>
  [ "${#_FM_LIFECYCLE_BATCH[@]}" -gt 0 ] || return 0
  if ! _fm_lifecycle_lock "$1"; then
    _fm_lifecycle_log "$1" "dropped ${#_FM_LIFECYCLE_BATCH[@]} event(s): lock not acquired within ${FM_LIFECYCLE_LOCK_WAIT:-2}s"
    _FM_LIFECYCLE_BATCH=()
    return 1
  fi
  _fm_lifecycle_write_batch_locked "$1" "$2" \
    || { _fm_lifecycle_log "$1" "dropped ${#_FM_LIFECYCLE_BATCH[@]} event(s): append failed"; _FM_LIFECYCLE_BATCH=(); }
  _fm_lifecycle_unlock "$1"
}

# --- status transcription -------------------------------------------------------------

_fm_lifecycle_cursor_path() {  # <state> <task> <outvar>
  printf -v "$3" '%s/.%s.lifecycle-cursor' "$1" "$2"
}

# Globals filled by _fm_lifecycle_cursor_read.
_FM_LC_VALID=0 _FM_LC_STREAM='' _FM_LC_OFFSET=0 _FM_LC_IDENT='' _FM_LC_SPAWNED='' _FM_LC_OPEN=''
_fm_lifecycle_cursor_read() {  # <cursor>
  local line n=0
  _FM_LC_VALID=0 _FM_LC_STREAM='' _FM_LC_OFFSET=0 _FM_LC_IDENT='' _FM_LC_SPAWNED='' _FM_LC_OPEN=''
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$n:$line" in
      1:version=*) [ "${line#version=}" = "$FM_LIFECYCLE_CURSOR_VERSION" ] || return 1 ;;
      2:stream=*) _FM_LC_STREAM=${line#stream=} ;;
      3:offset=*) _FM_LC_OFFSET=${line#offset=} ;;
      4:ident=*) _FM_LC_IDENT=${line#ident=} ;;
      5:spawned=*) _FM_LC_SPAWNED=${line#spawned=} ;;
      [1-5]:*) return 1 ;;
      *) [ -n "$line" ] && _FM_LC_OPEN="$_FM_LC_OPEN$line"$'\n' ;;
    esac
  done < "$1"
  [ "$n" -ge 5 ] || return 1
  _fm_lifecycle_uint_ok "$_FM_LC_OFFSET" || return 1
  _FM_LC_VALID=1
}

_fm_lifecycle_cursor_write() {  # <cursor> <stream> <offset> <ident> <spawned> <open>
  local tmp="$1.tmp.$$"
  {
    printf 'version=%s\nstream=%s\noffset=%s\nident=%s\nspawned=%s\n' \
      "$FM_LIFECYCLE_CURSOR_VERSION" "$2" "$3" "$4" "$5"
    [ -z "$6" ] || printf '%s' "$6"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$1"
}

# "<verb>\t<note>" for <key> in an open set, or 1 when the key is not open.
_fm_lifecycle_set_get() {  # <open-set> <key> <outvar>
  local __line
  while IFS= read -r __line; do
    case "$__line" in "$2"$'\t'*) printf -v "$3" '%s' "${__line#"$2"$'\t'}"; return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}

# The stream a status log's lines are keyed under, from the cursor just read
# by _fm_lifecycle_cursor_read (_FM_LC_VALID=0 when there is none): the cursor's
# stream while it follows the log; otherwise a new stream anchored on the last
# recorded spawn_gen, else <gen>, suffixed with the log's identity when it
# replaced the one the cursor followed. Anchoring on the recorded spawn_gen
# rather than the caller's <gen> is what lets a reader outside the writer
# predict the stream before the first pass (fm_lifecycle_status_stream).
_fm_lifecycle_stream_pick() {  # <cur-ident> <gen> <outvar>
  local __base
  if [ "$_FM_LC_VALID" != 1 ]; then
    printf -v "$3" '%s' "${2:-unknown}"
    return 0
  fi
  __base=${_FM_LC_SPAWNED:-${2:-unknown}}
  if [ -n "$_FM_LC_IDENT" ] && [ "$_FM_LC_IDENT" != "$1" ]; then
    printf -v "$3" '%s~%s' "$__base" "${1##*:}"
  else
    printf -v "$3" '%s' "${_FM_LC_STREAM:-$__base}"
  fi
}

# Queue task.decision events for the change from <before> to <after> caused by
# one status line.
_fm_lifecycle_queue_decisions() {  # <task> <gen> <stream> <offset> <at> <src> <bf> <verb> <before> <after>
  local task=$1 gen=$2 stream=$3 off=$4 at=$5 src=$6 bf=$7 verb=$8 before=$9 after=${10}
  local line key rest old change dverb note closed_by data resolve held
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    rest=${line#*$'\t'}
    if _fm_lifecycle_set_get "$before" "$key" old; then
      [ "$old" != "$rest" ] || continue
      change=replaced
    else
      change=opened
    fi
    dverb=${rest%%$'\t'*}
    _fm_lifecycle_cap "${rest#*$'\t'}" note
    _fm_lifecycle_obj data "key=$key" "change=$change" "verb=$dverb" "closed_by!=null" "note=$note"
    _fm_lifecycle_queue task.decision "$task" "$gen" "decision/$task/$stream/@$off/$key" "$at" "$src" "$bf" "$data"
  done <<EOF
$after
EOF
  case "$verb" in
    "$resolve") closed_by='"resolved"' ;;
    "$held") closed_by='"captain-held"' ;;
    done|failed) closed_by='"terminal"' ;;
    *) closed_by=null ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    rest=${line#*$'\t'}
    _fm_lifecycle_set_get "$after" "$key" old && continue
    dverb=${rest%%$'\t'*}
    _fm_lifecycle_obj data "key=$key" "change=closed" "verb=$dverb" "closed_by!=$closed_by" "note!=null"
    _fm_lifecycle_queue task.decision "$task" "$gen" "decision/$task/$stream/@$off/$key" "$at" "$src" "$bf" "$data"
  done <<EOF
$before
EOF
}

# One transcription chunk under the held lock. Returns 0 when the status file is
# fully transcribed, 2 when more lines remain for another chunk.
# <final>=1 also consumes a trailing partial line (teardown flush); <gen> overrides
# the attributed spawn_gen (a relaunch flushing its predecessor's lines).
_fm_lifecycle_transcribe_chunk_locked() {  # <state> <dir> <task> <final> <gen> <backfill>
  local state=$1 dir=$2 task=$3 final=$4 gen=$5 bf=$6 f cursor cur_ident size once=0 stream offset open spawned
  local span chunk_max lines=0 line len off verb at src note dkey until data before kind resolve held unstamped
  local rest end status=0 chunk_file
  f="$state/$task.status"
  _fm_lifecycle_cursor_path "$state" "$task" cursor
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  _fm_lifecycle_require_classify || return 1
  _fm_lifecycle_stat "$f" cur_ident size || return 1
  _fm_lifecycle_meta_load "$state/$task.meta"
  [ -n "$gen" ] || _fm_lifecycle_mget spawn_gen gen
  if _fm_lifecycle_cursor_read "$cursor"; then
    offset=$_FM_LC_OFFSET open=$_FM_LC_OPEN spawned=$_FM_LC_SPAWNED
    if [ -n "$_FM_LC_IDENT" ] && [ "$_FM_LC_IDENT" != "$cur_ident" ]; then
      offset=0 open='' once=1
    elif [ "$offset" -gt "$size" ]; then
      offset=0 open='' once=1
    fi
  else
    [ -e "$cursor" ] && once=1
    offset=0 open='' spawned=''
  fi
  _fm_lifecycle_stream_pick "$cur_ident" "$gen" stream
  [ "$bf" = true ] && once=1
  if [ "$offset" -ge "$size" ]; then
    [ "$_FM_LC_IDENT" = "$cur_ident" ] && [ "$_FM_LC_VALID" = 1 ] && return 0
    _fm_lifecycle_cursor_write "$cursor" "$stream" "$offset" "$cur_ident" "$spawned" "$open" || return 1
    return 0
  fi
  # One scratch file per home is enough: only the lock holder transcribes.
  chunk_file="$dir/.span"
  _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null || return 1
  span=''
  IFS= read -r -d '' span < "$chunk_file"
  _fm_lifecycle_bytelen "$span" len
  [ "$len" = "$((size - offset))" ] || return 1
  if [ "$final" != 1 ]; then
    case "$span" in
      *$'\n'*) span=${span%$'\n'*}$'\n' ;;
      *) return 0 ;;
    esac
  fi
  chunk_max=${FM_LIFECYCLE_TRANSCRIBE_CHUNK:-64}
  case "$chunk_max" in ''|*[!0-9]*|0) chunk_max=64 ;; esac
  kind=$(_fm_status_kind "$f")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  off=$offset
  rest=$span
  while [ -n "$rest" ]; do
    if [ "$lines" -ge "$chunk_max" ]; then status=2; break; fi
    case "$rest" in
      *$'\n'*) line=${rest%%$'\n'*}; rest=${rest#*$'\n'}; _fm_lifecycle_bytelen "$line" len; end=$((off + len + 1)) ;;
      *) line=$rest; rest=''; _fm_lifecycle_bytelen "$line" len; end=$((off + len)) ;;
    esac
    case "$line" in
      *[![:space:]]*) ;;
      *) off=$end; continue ;;
    esac
    lines=$((lines + 1))
    status_line_verb "$line" verb
    case "$verb" in
      working|needs-decision|blocked|done|failed|note|"$resolve"|"$held"|\
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      *) verb='' ;;
    esac
    if _fm_status_at_epoch "$line" at; then src=stamp; else at='' src=unknown; fi
    note=$(status_line_note "$line") || note=''
    _fm_lifecycle_cap "$note" note
    dkey=''
    _fm_status_unstamped "$line" unstamped
    case "$verb" in
      needs-decision|blocked|"$resolve"|"$held") dkey=$(_fm_decision_key "$line") || dkey='' ;;
      *)
        if _fm_key_before_colon "$unstamped" || _fm_key_at_note_head "$unstamped" >/dev/null; then
          dkey=$(_fm_decision_key "$line") || dkey=''
        fi
        ;;
    esac
    until=''
    [ "$verb" != "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ] \
      || until=$(status_paused_until "$line") || until=''
    _fm_lifecycle_obj data "verb?=$verb" "key?=$dkey" "until#=$until" "note=$note" "offset#=$off" "stream=$stream"
    _fm_lifecycle_queue task.status "$task" "$gen" "status/$task/$stream/@$off" "$at" "$src" "$bf" "$data"
    case "$verb" in
      needs-decision|blocked|done|failed|"$resolve"|"$held")
        before=$open
        open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind") || open=$before
        [ "$open" = "$before" ] \
          || _fm_lifecycle_queue_decisions "$task" "$gen" "$stream" "$off" "$at" "$src" "$bf" "$verb" "$before" "$open"
        ;;
    esac
    off=$end
  done
  _fm_lifecycle_write_batch_locked "$dir" "$once" || { _FM_LIFECYCLE_BATCH=(); return 1; }
  _fm_lifecycle_cursor_write "$cursor" "$stream" "$off" "$cur_ident" "$spawned" "$open" || return 1
  return "$status"
}

# Transcribe one task's status file to its end. With <held>=1 the caller
# already holds the lock; either way the lock is released and re-taken between
# chunks so other writers are never starved, and is held again on return.
_fm_lifecycle_transcribe() {  # <state> <dir> <task> <final> <gen> <backfill> [<held>]
  local rc guard=0 held=${7:-0}
  if [ "$held" != 1 ]; then
    _fm_lifecycle_lock "$2" || { _fm_lifecycle_log "$2" "transcription of $3 deferred: lock not acquired"; return 1; }
  fi
  while :; do
    _fm_lifecycle_transcribe_chunk_locked "$1" "$2" "$3" "$4" "$5" "$6"
    rc=$?
    case "$rc" in
      2)
        guard=$((guard + 1))
        [ "$guard" -lt 100000 ] || rc=1
        ;;
    esac
    [ "$rc" = 2 ] || break
    _fm_lifecycle_unlock "$2"
    _fm_lifecycle_lock "$2" || { _fm_lifecycle_log "$2" "transcription of $3 deferred: lock not acquired"; return 1; }
  done
  [ "$rc" = 0 ] || _fm_lifecycle_log "$2" "transcription of $3 failed"
  [ "$held" = 1 ] || _fm_lifecycle_unlock "$2"
  [ "$rc" = 0 ]
}

# 0 when the cursor just read (_fm_lifecycle_cursor_read) is bound to the task's
# current status log.
_fm_lifecycle_cursor_follows() {  # <state> <task>
  local ident size
  [ -n "$_FM_LC_IDENT" ] && [ -f "$1/$2.status" ] || return 1
  _fm_lifecycle_stat "$1/$2.status" ident size || return 1
  [ "$ident" = "$_FM_LC_IDENT" ]
}

# 0 when a status file has bytes past its lifecycle cursor (cheap pre-check).
_fm_lifecycle_has_new_bytes() {  # <state> <task>
  local f="$1/$2.status" cursor size ident
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  _fm_lifecycle_cursor_path "$1" "$2" cursor
  _fm_lifecycle_cursor_read "$cursor" || return 0
  _fm_lifecycle_stat "$f" ident size || return 0
  [ "$size" != "$_FM_LC_OFFSET" ] || [ "$ident" != "$_FM_LC_IDENT" ]
}

# --- steering -------------------------------------------------------------------------

_fm_lifecycle_sha256() {  # reads stdin
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else return 1
  fi
}

# Header values of one inbox record: _FM_LC_REC_AT (ISO) and _FM_LC_REC_DELIVERY.
_fm_lifecycle_record_header() {  # <record>
  local line
  _FM_LC_REC_AT='' _FM_LC_REC_DELIVERY=ringing
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      --) return 0 ;;
      at=*) _FM_LC_REC_AT=${line#at=} ;;
      delivery=fire-and-forget) _FM_LC_REC_DELIVERY=fire-and-forget ;;
    esac
  done < "$1"
  return 0
}

_fm_lifecycle_queue_steered() {  # <task> <gen> <record> <backfill>
  local task=$1 gen=$2 rec=$3 bf=$4 msg at='' src=inbox bytes='' sha='' data
  msg=${rec##*/}
  msg=${msg%.msg}
  _fm_lifecycle_record_header "$rec" || return 1
  _fm_lifecycle_require_classify || return 1
  at=$(fm_utc_iso_to_epoch "$_FM_LC_REC_AT" 2>/dev/null) || at=''
  _fm_lifecycle_uint_ok "$at" || { at=''; src=unknown; }
  if command -v fm_task_inbox_body >/dev/null 2>&1; then
    bytes=$(fm_task_inbox_body "$rec" 2>/dev/null | wc -c | tr -d ' ') || bytes=''
    sha=$(fm_task_inbox_body "$rec" 2>/dev/null | _fm_lifecycle_sha256) || sha=''
  fi
  _fm_lifecycle_obj data "msg=$msg" "delivery=$_FM_LC_REC_DELIVERY" "bytes#=$bytes" "sha256?=$sha"
  _fm_lifecycle_queue task.steered "$task" "$gen" "steered/$task/$msg/$_FM_LC_REC_AT" "$at" "$src" "$bf" "$data"
}

# Queue task.steer_acked for every handled record not yet recorded, then list
# them in the marker. Prints nothing; the marker is written by the caller after
# the batch lands (_fm_lifecycle_acks_commit).
_FM_LC_ACK_NEW=''
_fm_lifecycle_queue_acks() {  # <state> <task> <gen> <at> <at-source> <backfill>
  local inbox="$1/$2.inbox" marker acked='' f name data
  _FM_LC_ACK_NEW=''
  [ -d "$inbox/handled" ] || return 0
  marker="$inbox/.lifecycle-acked"
  [ ! -f "$marker" ] || IFS= read -r acked < "$marker" || true
  for f in "$inbox/handled"/*.msg; do
    [ -f "$f" ] || continue
    name=${f##*/}
    case " $acked " in *" $name "*) continue ;; esac
    _fm_lifecycle_record_header "$f" || continue
    _fm_lifecycle_obj data "msg=${name%.msg}"
    _fm_lifecycle_queue task.steer_acked "$2" "$3" "steer_acked/$2/${name%.msg}/$_FM_LC_REC_AT" "$4" "$5" "$6" "$data"
    _FM_LC_ACK_NEW="$_FM_LC_ACK_NEW $name"
  done
}

_fm_lifecycle_acks_commit() {  # <state> <task>
  local inbox="$1/$2.inbox" marker acked=''
  [ -n "$_FM_LC_ACK_NEW" ] && [ -d "$inbox" ] || return 0
  marker="$inbox/.lifecycle-acked"
  [ ! -f "$marker" ] || IFS= read -r acked < "$marker" || true
  printf '%s\n' "${acked}${_FM_LC_ACK_NEW}" > "$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker"
}

# 0 when handled/ holds a record the marker does not list (no fork).
_fm_lifecycle_has_new_acks() {  # <state> <task>
  local inbox="$1/$2.inbox" acked='' f
  [ -d "$inbox/handled" ] || return 1
  [ ! -f "$inbox/.lifecycle-acked" ] || IFS= read -r acked < "$inbox/.lifecycle-acked" || true
  for f in "$inbox/handled"/*.msg; do
    [ -f "$f" ] || continue
    case " $acked " in *" ${f##*/} "*) continue ;; esac
    return 0
  done
  return 1
}

# Acknowledgements under the held lock: queue, write, then mark.
_fm_lifecycle_acks_locked() {  # <state> <dir> <task> <gen> <at> <at-source> <backfill> <once>
  _fm_lifecycle_queue_acks "$1" "$3" "$4" "$5" "$6" "$7"
  [ -n "$_FM_LC_ACK_NEW" ] || return 0
  _fm_lifecycle_write_batch_locked "$2" "$8" || { _FM_LIFECYCLE_BATCH=(); return 1; }
  _fm_lifecycle_acks_commit "$1" "$3"
}

# --- public entry points (best-effort) --------------------------------------------------

# Run <function> [args...] best-effort: subshell, errexit/nounset off, output
# discarded, always 0.
_fm_lifecycle_best_effort() {
  ( set +eu; trap - ERR 2>/dev/null; "$@" ) </dev/null >/dev/null 2>&1 || true
  return 0
}

_fm_lifecycle_task_spawned_body() {  # <state> <task> <relaunch>
  local state=$1 task=$2 relaunch=$3 dir cursor gen prev='' now data kind v
  local harness model effort mode yolo project backend window home projects rhost sm_json remote_json
  fm_lifecycle_feed_dir "$state" dir || return 0
  _fm_lifecycle_meta_load "$state/$task.meta"
  _fm_lifecycle_mget spawn_gen gen
  _fm_lifecycle_cursor_path "$state" "$task" cursor
  if [ "$relaunch" = 1 ]; then
    _fm_lifecycle_cursor_read "$cursor" && prev=$_FM_LC_SPAWNED
    [ "$prev" != "$gen" ] || prev=''
    # Lines the predecessor wrote before this relaunch stay attributed to it.
    [ -z "$prev" ] || _fm_lifecycle_transcribe "$state" "$dir" "$task" 0 "$prev" false
    _fm_lifecycle_meta_load "$state/$task.meta"
  fi
  for v in kind harness model effort mode yolo project backend window home projects; do
    _fm_lifecycle_mget "$v" "$v"
  done
  _fm_lifecycle_mget remote_host rhost
  [ -n "$backend" ] || backend=tmux
  sm_json=null
  [ "$kind" != secondmate ] || _fm_lifecycle_obj sm_json "home?=$home" "projects?=$projects"
  remote_json=null
  [ -z "$rhost" ] || _fm_lifecycle_obj remote_json "host=$rhost"
  _fm_lifecycle_obj v "target?=$window"
  if [ "$relaunch" = 1 ]; then relaunch=true; else relaunch=false; fi
  _fm_lifecycle_obj data "kind?=$kind" "harness?=$harness" "model?=$model" "effort?=$effort" \
    "mode?=$mode" "yolo?=$yolo" "project?=$project" "backend=$backend" "endpoint!=$v" \
    "relaunch!=$relaunch" "previous_spawn_gen?=$prev" "secondmate!=$sm_json" "remote!=$remote_json"
  _fm_lifecycle_now now
  _fm_lifecycle_queue task.spawned "$task" "$gen" "spawned/$task/${gen:-@$now}" "$now" firstmate false "$data"
  _fm_lifecycle_lock "$dir" || { _fm_lifecycle_log "$dir" "dropped task.spawned for $task: lock not acquired"; return 0; }
  if _fm_lifecycle_write_batch_locked "$dir" 0; then
    # A fresh spawn keeps a cursor only when it already follows this task's
    # current status log; one left by an earlier task of the same id restarts.
    if _fm_lifecycle_cursor_read "$cursor" \
      && { [ "$relaunch" = true ] || _fm_lifecycle_cursor_follows "$state" "$task"; }; then
      _fm_lifecycle_cursor_write "$cursor" "$_FM_LC_STREAM" "$_FM_LC_OFFSET" "$_FM_LC_IDENT" "$gen" "$_FM_LC_OPEN"
    else
      _fm_lifecycle_cursor_write "$cursor" "" 0 "" "$gen" ""
    fi
  else
    _FM_LIFECYCLE_BATCH=()
    _fm_lifecycle_log "$dir" "dropped task.spawned for $task: append failed"
  fi
  _fm_lifecycle_unlock "$dir"
}

# Record a committed fresh spawn or relaunch (after its final commit point).
fm_lifecycle_task_spawned() {  # <state> <task> <relaunch:0|1>
  _fm_lifecycle_best_effort _fm_lifecycle_task_spawned_body "$@"
}

_fm_lifecycle_task_reclassified_body() {  # <state> <task> <from-kind> <to-kind> <mode> <yolo>
  local state=$1 dir gen now data to
  fm_lifecycle_feed_dir "$state" dir || return 0
  _fm_lifecycle_transcribe "$state" "$dir" "$2" 0 "" false
  _fm_lifecycle_meta_load "$state/$2.meta"
  _fm_lifecycle_mget spawn_gen gen
  _fm_lifecycle_obj to "kind=$4" "mode?=$5" "yolo?=$6"
  _fm_lifecycle_obj data "from!={\"kind\":\"${3//[!a-z]/}\"}" "to!=$to"
  _fm_lifecycle_now now
  _fm_lifecycle_queue task.reclassified "$2" "$gen" "reclassified/$2/${gen:-@$now}/$3-$4" "$now" firstmate false "$data"
  _fm_lifecycle_flush "$dir" 0
}

# Record an in-place reclassification (scout promoted to ship).
fm_lifecycle_task_reclassified() {  # <state> <task> <from-kind> <to-kind> <mode> <yolo>
  _fm_lifecycle_best_effort _fm_lifecycle_task_reclassified_body "$@"
}

_fm_lifecycle_task_torn_down_body() {  # <state> <task> <backlog-closed> <transition> <pr> <force> [merge-proven]
  local state=$1 task=$2 transition=$4 pr=$5 forced=false merge_proven=${7-} dir gen now data kind mode outcome report='' data_dir
  fm_lifecycle_feed_dir "$state" dir || return 0
  [ "$3" = 1 ] || transition=remove
  [ -z "$6" ] || forced=true
  _fm_lifecycle_transcribe "$state" "$dir" "$task" 1 "" false
  _fm_lifecycle_meta_load "$state/$task.meta"
  _fm_lifecycle_mget spawn_gen gen
  _fm_lifecycle_mget kind kind
  _fm_lifecycle_mget mode mode
  _fm_lifecycle_now now
  data_dir=${dir%/*}
  case "$kind" in
    scout) outcome=reported; [ ! -f "$data_dir/$task/report.md" ] || report="data/$task/report.md" ;;
    secondmate) outcome=retired ;;
    *)
      if [ "$mode" = local-only ]; then outcome=landed
      elif [ -n "$pr" ] && [ "$merge_proven" = 1 ]; then outcome=merged
      else outcome=unknown
      fi
      ;;
  esac
  [ "$forced" = false ] || outcome=unknown
  _fm_lifecycle_obj data "transition=$transition" "outcome=$outcome" "forced!=$forced" \
    "kind?=$kind" "report?=$report" "pr?=$pr"
  if _fm_lifecycle_lock "$dir"; then
    _fm_lifecycle_acks_locked "$state" "$dir" "$task" "$gen" "$now" observed false 0 \
      || _fm_lifecycle_log "$dir" "teardown acknowledgement flush for $task failed"
    _fm_lifecycle_queue task.torn_down "$task" "$gen" "torn_down/$task/${gen:-@$now}" "$now" firstmate false "$data"
    _fm_lifecycle_write_batch_locked "$dir" 0 \
      || { _FM_LIFECYCLE_BATCH=(); _fm_lifecycle_log "$dir" "dropped task.torn_down for $task: append failed"; }
    _fm_lifecycle_unlock "$dir"
  else
    _fm_lifecycle_log "$dir" "dropped task.torn_down for $task: lock not acquired"
  fi
}

# Flush a task's untranscribed status tail and acknowledgements and record its
# teardown. Call before its status/meta/inbox are removed; the cursor stays at
# the end of the flushed log so a concurrent drain cannot re-read it, and the
# next drain retires it once the task's records are gone. A ship records
# `merged` only when the caller passes merge-proven=1 from its own proof that
# the PR merged; a recorded PR alone never claims a merge.
fm_lifecycle_task_torn_down() {  # <state> <task> <backlog-closed:0|1> <close|retain> <pr-url> <force-flag> [merge-proven:0|1]
  _fm_lifecycle_best_effort _fm_lifecycle_task_torn_down_body "$@"
}

_fm_lifecycle_steer_record_body() {  # <record>
  local rec=$1 inbox state task dir gen
  inbox=${rec%/*}
  state=${inbox%/*}
  task=${inbox##*/}
  task=${task%.inbox}
  [ "$inbox" != "$rec" ] && [ -n "$task" ] || return 0
  fm_lifecycle_feed_dir "$state" dir || return 0
  _fm_lifecycle_meta_load "$state/$task.meta"
  _fm_lifecycle_mget spawn_gen gen
  _fm_lifecycle_queue_steered "$task" "$gen" "$rec" false || return 0
  _fm_lifecycle_flush "$dir" 0
}

# Record one newly written steering-inbox record (metadata only).
fm_lifecycle_steer_record() {  # <record-path>
  _fm_lifecycle_best_effort _fm_lifecycle_steer_record_body "$@"
}

_fm_lifecycle_steer_acks_body() {  # <state> <task>
  local dir gen now
  fm_lifecycle_feed_dir "$1" dir || return 0
  _fm_lifecycle_meta_load "$1/$2.meta"
  _fm_lifecycle_mget spawn_gen gen
  _fm_lifecycle_now now
  _fm_lifecycle_lock "$dir" || { _fm_lifecycle_log "$dir" "acknowledgements for $2 deferred: lock not acquired"; return 0; }
  _fm_lifecycle_acks_locked "$1" "$dir" "$2" "$gen" "$now" observed false 0 \
    || _fm_lifecycle_log "$dir" "acknowledgements for $2 failed"
  _fm_lifecycle_unlock "$dir"
}

# Record handled steering records not yet recorded. Costs one directory glob and
# no fork when there is nothing new, so the watcher can call it every poll.
fm_lifecycle_steer_acks() {  # <state> <task>
  _fm_lifecycle_has_new_acks "$1" "$2" || return 0
  _fm_lifecycle_best_effort _fm_lifecycle_steer_acks_body "$@"
}

_fm_lifecycle_transcribe_all_body() {  # <state>
  local state=$1 dir f task tasks=()
  fm_lifecycle_feed_dir "$state" dir || return 0
  _fm_lifecycle_require_classify || return 0
  # Retire cursors whose task has neither a status log nor a record (torn down).
  for f in "$state"/.*.lifecycle-cursor; do
    [ -f "$f" ] || continue
    task=${f##*/.}
    task=${task%.lifecycle-cursor}
    [ -e "$state/$task.status" ] || [ -e "$state/$task.meta" ] || rm -f "$f"
  done
  for f in "$state"/*.status; do
    [ -f "$f" ] || continue
    task=${f##*/}
    task=${task%.status}
    _fm_lifecycle_has_new_bytes "$state" "$task" && tasks+=("$task")
  done
  [ "${#tasks[@]}" -gt 0 ] || return 0
  _fm_lifecycle_lock "$dir" || { _fm_lifecycle_log "$dir" "transcription deferred: lock not acquired"; return 0; }
  for task in "${tasks[@]}"; do
    _fm_lifecycle_transcribe "$state" "$dir" "$task" 0 "" false 1 || break
  done
  _fm_lifecycle_unlock "$dir"
}

# Transcribe every task's new status lines (the wake drain's pass).
fm_lifecycle_transcribe_all() {  # <state>
  _fm_lifecycle_best_effort _fm_lifecycle_transcribe_all_body "$@"
}

# --- discovery ------------------------------------------------------------------------

# Print the fm-fleet-snapshot.v1 `lifecycle` pointer as compact JSON, or `null`
# when the feed is off or unresolvable for this state directory.
fm_lifecycle_snapshot_json() {  # <state>
  local state=$1 dir path id='' head='' present=false homes='' meta kind home rhost task entry cdir cid chead cpath
  local jpath jid jtask
  if ! fm_lifecycle_feed_dir "$state" dir; then
    printf 'null'
    return 0
  fi
  path="$dir/events.v1.jsonl"
  [ ! -f "$dir/home-id" ] || IFS= read -r id < "$dir/home-id" || true
  [ ! -f "$dir/head" ] || IFS= read -r head < "$dir/head" || true
  [ ! -s "$path" ] || present=true
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    _fm_lifecycle_meta_load "$meta"
    _fm_lifecycle_mget kind kind
    [ "$kind" = secondmate ] || continue
    task=${meta##*/}
    task=${task%.meta}
    _fm_lifecycle_mget home home
    _fm_lifecycle_mget remote_host rhost
    _fm_lifecycle_jstr "$task" jtask
    if [ -n "$rhost" ] || [ -z "$home" ]; then
      entry="{\"id\":null,\"task\":$jtask,\"path\":null,\"head_seq\":null,\"remote\":true}"
    else
      cdir="$home/data/lifecycle"
      cid='' chead=''
      [ ! -f "$cdir/home-id" ] || IFS= read -r cid < "$cdir/home-id" || true
      [ ! -f "$cdir/head" ] || IFS= read -r chead < "$cdir/head" || true
      if [ -n "$cid" ]; then _fm_lifecycle_jstr "$cid" jid; else jid=null; fi
      _fm_lifecycle_jstr "$cdir/events.v1.jsonl" cpath
      _fm_lifecycle_uint_ok "$chead" || chead=null
      entry="{\"id\":$jid,\"task\":$jtask,\"path\":$cpath,\"head_seq\":$chead,\"remote\":false}"
    fi
    homes="$homes${homes:+,}$entry"
  done
  _fm_lifecycle_jstr "$path" jpath
  if [ -n "$id" ]; then _fm_lifecycle_jstr "$id" jid; else jid=null; fi
  _fm_lifecycle_uint_ok "$head" || head=null
  printf '{"schema":"%s","id":%s,"path":%s,"present":%s,"head_seq":%s,"homes":[%s]}' \
    "$FM_LIFECYCLE_SCHEMA" "$jid" "$jpath" "$present" "$head" "$homes"
}

# The identity of <task>'s status log as it stands now, "<ident>\t<stream>",
# where <stream> is the one its task.status keys use (_fm_lifecycle_stream_pick)
# and <gen> is the spawn_gen in the task's metadata. Read-only, silent, and 1 when the
# log cannot be read; bin/fm-fleet-snapshot.sh samples it around its own copy
# of the log to publish the feed key of the line it reports.
fm_lifecycle_status_stream() {  # <state> <task> <gen>
  local cursor ident size stream
  [ -f "$1/$2.status" ] && [ ! -L "$1/$2.status" ] || return 1
  _fm_lifecycle_stat "$1/$2.status" ident size || return 1
  _fm_lifecycle_cursor_path "$1" "$2" cursor
  _fm_lifecycle_cursor_read "$cursor" 2>/dev/null || _FM_LC_VALID=0
  _fm_lifecycle_stream_pick "$ident" "$3" stream
  printf '%s\t%s\n' "$ident" "$stream"
}

# --- backfill ---------------------------------------------------------------------------

# Replay live tasks into the feed as backfill events; idempotent by key. Prints
# one summary line. Unlike the emit entry points this runs in the foreground of
# bin/fm-lifecycle.sh and reports failure.
fm_lifecycle_backfill() {  # <state>
  local state=$1 dir meta task gen epoch data cursor f tasks_json='' jt rc=0
  if ! fm_lifecycle_feed_dir "$state" dir; then
    echo "fm-lifecycle: the feed is disabled or this home's data directory is unavailable" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1
  _fm_lifecycle_require_classify || return 1
  _FM_LIFECYCLE_EMITTED=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    _fm_lifecycle_meta_load "$meta"
    _fm_lifecycle_mget spawn_gen gen
    epoch=${gen#s}
    epoch=${epoch%%.*}
    _fm_lifecycle_uint_ok "$epoch" || epoch=''
    local kind harness model effort mode yolo project backend window home projects rhost v sm_json remote_json src
    for v in kind harness model effort mode yolo project backend window home projects; do
      _fm_lifecycle_mget "$v" "$v"
    done
    _fm_lifecycle_mget remote_host rhost
    [ -n "$backend" ] || backend=tmux
    sm_json=null
    [ "$kind" != secondmate ] || _fm_lifecycle_obj sm_json "home?=$home" "projects?=$projects"
    remote_json=null
    [ -z "$rhost" ] || _fm_lifecycle_obj remote_json "host=$rhost"
    _fm_lifecycle_obj v "target?=$window"
    _fm_lifecycle_obj data "kind?=$kind" "harness?=$harness" "model?=$model" "effort?=$effort" \
      "mode?=$mode" "yolo?=$yolo" "project?=$project" "backend=$backend" "endpoint!=$v" \
      "relaunch!=null" "previous_spawn_gen!=null" "secondmate!=$sm_json" "remote!=$remote_json"
    if [ -n "$epoch" ]; then src=firstmate; else src=unknown; fi
    if [ -n "$gen" ]; then
      _fm_lifecycle_queue task.spawned "$task" "$gen" "spawned/$task/$gen" "$epoch" "$src" true "$data"
    fi
    _fm_lifecycle_cursor_path "$state" "$task" cursor
    if [ "${#_FM_LIFECYCLE_BATCH[@]}" -gt 0 ]; then
      _fm_lifecycle_lock "$dir" || { echo "fm-lifecycle: lock not acquired for $task" >&2; _FM_LIFECYCLE_BATCH=(); rc=1; continue; }
      if _fm_lifecycle_write_batch_locked "$dir" 1; then
        if _fm_lifecycle_cursor_read "$cursor"; then
          [ -n "$_FM_LC_SPAWNED" ] \
            || _fm_lifecycle_cursor_write "$cursor" "$_FM_LC_STREAM" "$_FM_LC_OFFSET" "$_FM_LC_IDENT" "$gen" "$_FM_LC_OPEN"
        else
          _fm_lifecycle_cursor_write "$cursor" "" 0 "" "$gen" ""
        fi
      else
        _FM_LIFECYCLE_BATCH=()
        rc=1
      fi
      _fm_lifecycle_unlock "$dir"
    fi
    if [ -f "$state/$task.status" ]; then
      if _fm_lifecycle_cursor_read "$cursor" && [ -n "$_FM_LC_IDENT" ]; then
        _fm_lifecycle_transcribe "$state" "$dir" "$task" 0 "" false || rc=1
      else
        _fm_lifecycle_transcribe "$state" "$dir" "$task" 0 "" true || rc=1
      fi
    fi
    for f in "$state/$task.inbox"/*.msg "$state/$task.inbox/handled"/*.msg; do
      [ -f "$f" ] || continue
      _fm_lifecycle_queue_steered "$task" "$gen" "$f" true || true
    done
    if _fm_lifecycle_lock "$dir"; then
      _fm_lifecycle_write_batch_locked "$dir" 1 || { _FM_LIFECYCLE_BATCH=(); rc=1; }
      _fm_lifecycle_acks_locked "$state" "$dir" "$task" "$gen" "" unknown true 1 || rc=1
      _fm_lifecycle_unlock "$dir"
    else
      _FM_LIFECYCLE_BATCH=()
      rc=1
    fi
    _fm_lifecycle_jstr "$task" jt
    tasks_json="$tasks_json${tasks_json:+,}$jt"
  done
  if [ "$_FM_LIFECYCLE_EMITTED" -gt 0 ]; then
    local total=$_FM_LIFECYCLE_EMITTED now
    _fm_lifecycle_now now
    _fm_lifecycle_obj data "tasks!=[$tasks_json]" "events#=$total"
    _fm_lifecycle_queue feed.backfilled "" "" "backfilled/$now" "$now" firstmate true "$data"
    _fm_lifecycle_flush "$dir" 0
    _FM_LIFECYCLE_EMITTED=$total
  fi
  printf 'fm-lifecycle: backfill recorded %s event(s) into %s\n' "$_FM_LIFECYCLE_EMITTED" "$dir/events.v1.jsonl"
  return "$rc"
}
