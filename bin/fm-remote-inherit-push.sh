#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation> [--jev-key-only]
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
[ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --jev-key-only ]; } || {
  echo "usage: fm-remote-inherit-push.sh <secondmate-id> <generation> [--jev-key-only]" >&2
  exit 2
}
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "secondmate $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(fm_config_inherit_items)
[ "${3:-}" != --jev-key-only ] || ITEMS=$FM_JEV_KEY_REL
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "$rel" = "$FM_JEV_KEY_REL" ]; then
    snapshot="$TMP/jev-key"
    rc=0
    (umask 077; fm_jev_key_extract "$FM_HOME/.env" > "$snapshot") || rc=$?
    if [ "$rc" -eq 3 ]; then
      printf 'SECONDMATE_SYNC: TYPESAFE_API_KEY skipped\n' >&2
      continue
    fi
    if [ "$rc" -eq 0 ]; then
      bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
      hash=$(sha256_file "$snapshot") || rc=1
      if [ "$rc" -eq 0 ]; then
        "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh \
          put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot" > "$TMP/jev-result" 2>/dev/null || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        # Print only a known action, even when the remote revision is different.
        if grep -Fxq "unchanged: $FM_JEV_KEY_REL" "$TMP/jev-result"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        elif grep -Fxq "pushed: $FM_JEV_KEY_REL" "$TMP/jev-result"; then
          printf 'pushed: %s\n' "$rel"
          continue
        fi
        rc=1
      fi
    fi
    printf 'SECONDMATE_SYNC: TYPESAFE_API_KEY error (not delivered)\n' >&2
    exit "$rc"
  fi
  if [ "${FM_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$source"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        die "$reason"
      fi
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot"
  else
    # This loop's heredoc is its control stream, not remote command input.
    "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION" < /dev/null
  fi
done <<EOF
$ITEMS
EOF
