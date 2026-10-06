#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation> [--jev-key-only]
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner, except that an undelivered Jev key
# only warns. FM_CONFIG_INHERIT_LIVE=1 marks a live
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
# Map only known, value-free receiver refusals; never relay raw remote output.
jev_key_remote_failure_reason() {  # <rc> <stderr-file>
  local line
  if [ "$1" -eq 255 ]; then
    echo "remote host unreachable or transfer outcome unknown"
    return 0
  fi
  line=$(grep -m1 '^error: ' "$2" 2>/dev/null || true)
  case "$line" in
    "error: path is not inherited material: $FM_JEV_KEY_REL") echo "remote receiver predates the key item" ;;
    "error: inherited destination is hardlinked") echo "remote .env is hardlinked" ;;
    "error: inherited destination is a symlink"|"error: inherited destination is not a regular file")
      echo "remote .env is not an ordinary file" ;;
    "error: TYPESAFE_API_KEY not delivered: .env is not gitignored") echo "remote .env is not gitignored" ;;
    "error: TYPESAFE_API_KEY not delivered: config/ staging is unsafe or not gitignored")
      echo "remote config/ staging is unsafe or not gitignored" ;;
    "error: TYPESAFE_API_KEY not delivered: home is not a git checkout root") echo "remote home is not a git checkout root" ;;
    "error: TYPESAFE_API_KEY not delivered: payload or .env is unsafe"*) echo "remote payload or .env is unsafe" ;;
    *) echo "remote receiver refused the transfer" ;;
  esac
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
    reason="primary .env is unreadable or unsafe"
    if [ "$rc" -eq 0 ]; then
      bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
      if ! hash=$(sha256_file "$snapshot"); then
        reason="cannot hash the key payload"
      elif "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh \
        put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot" > "$TMP/jev-result" 2> "$TMP/jev-error"; then
        # Print only a known action, even when the remote revision is different.
        if grep -Fxq "unchanged: $FM_JEV_KEY_REL" "$TMP/jev-result"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        elif grep -Fxq "pushed: $FM_JEV_KEY_REL" "$TMP/jev-result"; then
          printf 'pushed: %s\n' "$rel"
          continue
        fi
        reason="remote receiver returned an unrecognized result"
      else
        reason=$(jev_key_remote_failure_reason "$?" "$TMP/jev-error")
      fi
    fi
    # Key-only failure warns and never fails the push: Jev is optional.
    printf 'SECONDMATE_SYNC: secondmate %s: TYPESAFE_API_KEY not delivered: %s\n' "$ID" "$reason" >&2
    continue
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
