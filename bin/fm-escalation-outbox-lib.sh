#!/usr/bin/env bash
# fm-escalation-outbox-lib.sh - the durable hand-off between the away/quiet
# daemon (bin/fm-supervise-daemon.sh) and a primary harness whose OWN wake path
# delivers the daemon's escalation digests, instead of the daemon typing them
# into the captain's pane.
#
# Why: typing into the supervisor pane needs that pane to read idle with a
# provably empty composer. A captain who stays in a quiet session keeps the
# pane busy or its composer unprovable, so a pane-typed digest can wait
# indefinitely (the 2026-10-28 balanced-strategy incident: 25 escalations,
# including merge asks and a review decision, sat undelivered for 41 minutes
# behind "supervisor pane busy" and "composer not confirmed-empty" deferrals,
# and the same home had never delivered a quiet digest at all). Claude and
# Codex primaries already own a structural wake path that needs no pane read:
#
#   hook        Claude: the Stop asyncRewake hook (bin/fm-claude-stop-autoarm.sh)
#               parks on the outbox while state/.afk exists and delivers with
#               its exit-2 rewake, which reaches an idle session and a running
#               turn alike.
#   checkpoint  Codex: the foreground checkpoint (bin/fm-watch-checkpoint.sh)
#               parks on the outbox for its bound while state/.afk exists and
#               returns the digest as its output.
#   pane        every other primary keeps the daemon's pane injection.
#
# Layout: state/.subsuper-outbox/<epoch>.<pid>.<n>.msg, one published digest
# per file, written to a temporary name and renamed into place. A consumer
# claims a file by renaming it to <name>.claimed.<pid> (a rename either wins or
# finds the file gone, so exactly one consumer delivers it), prints it, and
# commits by moving it under delivered/ (the newest FM_OUTBOX_KEEP_DELIVERED
# are kept as audit evidence). A claim whose owner died, or that is older than
# FM_OUTBOX_CLAIM_STALE_SECS (a live claim is held for well under a second),
# is put back for the next consumer: a duplicate delivery is possible after a
# crash between print and commit, a lost one is not.
#
# Tunables: FM_OUTBOX_CLAIM_STALE_SECS (default 120), FM_OUTBOX_KEEP_DELIVERED
# (default 50).

FM_OUTBOX_DIRNAME=.subsuper-outbox

fm_outbox_dir() {  # <state>
  printf '%s/%s' "$1" "$FM_OUTBOX_DIRNAME"
}

# fm_outbox_transport: how a digest reaches this primary harness.
fm_outbox_transport() {  # <harness> -> hook|checkpoint|pane
  case "$1" in
    claude) printf 'hook' ;;
    codex) printf 'checkpoint' ;;
    *) printf 'pane' ;;
  esac
}

fm_outbox_publish() {  # <state> <text>
  local dir tmp n=0 dest
  dir=$(fm_outbox_dir "$1")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.publish.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$2" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  while :; do
    dest="$dir/$(date +%s).$$.$n.msg"
    [ -e "$dest" ] || break
    n=$((n + 1))
  done
  mv "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# fm_outbox_pending_files: unclaimed digests, oldest first.
fm_outbox_pending_files() {  # <state>
  local dir f
  dir=$(fm_outbox_dir "$1")
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.msg; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done | sort -t. -k1,1n -k2,2n -k3,3n | while IFS= read -r f; do
    printf '%s/%s\n' "$dir" "$f"
  done
}

fm_outbox_pending() {  # <state>
  [ -n "$(fm_outbox_pending_files "$1")" ]
}

# fm_outbox_oldest_age: seconds since the oldest unclaimed digest was published,
# or nothing when none is waiting.
fm_outbox_oldest_age() {  # <state>
  local first epoch
  first=$(fm_outbox_pending_files "$1" | head -n 1)
  [ -n "$first" ] || return 0
  epoch=${first##*/}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' $(( $(date +%s) - epoch ))
}

# fm_outbox_recover: put back every claim whose owner died or that outlived the
# stale bound.
fm_outbox_recover() {  # <state>
  local dir f pid mtime now stale
  dir=$(fm_outbox_dir "$1")
  [ -d "$dir" ] || return 0
  stale=${FM_OUTBOX_CLAIM_STALE_SECS:-120}
  case "$stale" in ''|*[!0-9]*) stale=120 ;; esac
  now=$(date +%s)
  for f in "$dir"/*.msg.claimed.*; do
    [ -f "$f" ] || continue
    pid=${f##*.claimed.}
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if ! kill -0 "$pid" 2>/dev/null || [ $((now - mtime)) -gt "$stale" ]; then
      mv "$f" "${f%.claimed.*}" 2>/dev/null || true
    fi
  done
}

# fm_outbox_claim: claim every waiting digest for this process. Returns 0 and
# sets FM_OUTBOX_CLAIMED (newline-separated claimed paths, oldest first) when at
# least one was claimed, 1 otherwise.
FM_OUTBOX_CLAIMED=
fm_outbox_claim() {  # <state>
  local f claimed
  FM_OUTBOX_CLAIMED=
  fm_outbox_recover "$1"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    claimed="$f.claimed.$$"
    if mv "$f" "$claimed" 2>/dev/null; then
      touch "$claimed" 2>/dev/null || true
      FM_OUTBOX_CLAIMED="${FM_OUTBOX_CLAIMED:+$FM_OUTBOX_CLAIMED
}$claimed"
    fi
  done < <(fm_outbox_pending_files "$1")
  [ -n "$FM_OUTBOX_CLAIMED" ]
}

# fm_outbox_render_claimed: print the claimed digests, one per line, each noting
# how late it is when it waited at least <late-seconds> (0 disables the note).
fm_outbox_render_claimed() {  # [late-seconds]
  local late=${1:-0} f epoch age now
  now=$(date +%s)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    epoch=${f##*/}
    epoch=${epoch%%.*}
    age=0
    case "$epoch" in ''|*[!0-9]*) ;; *) age=$((now - epoch)) ;; esac
    if [ "$late" -gt 0 ] && [ "$age" -ge "$late" ]; then
      printf '%s [delivered %ss after it was buffered]\n' "$(tr '\n' ' ' < "$f" | sed 's/[[:space:]]*$//')" "$age"
    else
      tr '\n' ' ' < "$f" | sed 's/[[:space:]]*$//'
      printf '\n'
    fi
  done <<< "$FM_OUTBOX_CLAIMED"
}

fm_outbox_commit() {  # <state>
  local dir f keep
  dir=$(fm_outbox_dir "$1")
  mkdir -p "$dir/delivered" 2>/dev/null || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv "$f" "$dir/delivered/$(basename "${f%.claimed.*}")" 2>/dev/null || rm -f "$f"
  done <<< "$FM_OUTBOX_CLAIMED"
  FM_OUTBOX_CLAIMED=
  keep=${FM_OUTBOX_KEEP_DELIVERED:-50}
  case "$keep" in ''|*[!0-9]*) keep=50 ;; esac
  local -a kept=()
  for f in "$dir"/delivered/*.msg; do
    [ -f "$f" ] && kept+=("${f##*/}")
  done
  [ "${#kept[@]}" -gt "$keep" ] || return 0
  printf '%s\n' "${kept[@]}" | sort -t. -k1,1n -k2,2n -k3,3n \
    | head -n $(( ${#kept[@]} - keep )) | while IFS= read -r f; do
      rm -f "$dir/delivered/$f"
    done
}

fm_outbox_release() {  # <state>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv "$f" "${f%.claimed.*}" 2>/dev/null || true
  done <<< "$FM_OUTBOX_CLAIMED"
  FM_OUTBOX_CLAIMED=
}
