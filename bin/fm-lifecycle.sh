#!/usr/bin/env bash
# fm-lifecycle.sh - operator entry point for the fm-lifecycle.v1 event feed.
#
# Usage:
#   fm-lifecycle.sh backfill
#     Replay this home's live tasks into the feed as `backfill: true` events:
#     task.spawned from each state/<id>.meta (its time taken from the
#     spawn_gen epoch), every status line and decision change not yet
#     transcribed, and every pending or handled steering-inbox record with its
#     acknowledgement. Idempotent: events are keyed, so a second run records
#     nothing, and a run that records anything ends with one feed.backfilled.
#     History of tasks torn down before the feed existed is not recoverable and
#     is not invented.
#   fm-lifecycle.sh path
#     Print this home's active feed file path; exit 1 when the feed is off or
#     this home has no data directory.
#
# bin/fm-lifecycle-lib.sh owns the writer mechanics and docs/configuration.md
# "Lifecycle event feed (data/lifecycle)" owns the consumer contract. An unset
# FM_STATE_OVERRIDE selects FM_HOME/state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-lifecycle.sh backfill | path" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"

case "$1" in
  backfill) fm_lifecycle_backfill "$STATE" ;;
  path)
    fm_lifecycle_feed_dir "$STATE" LIFECYCLE_DIR || {
      echo "error: the lifecycle feed is off or this home has no data directory" >&2
      exit 1
    }
    printf '%s/events.v1.jsonl\n' "$LIFECYCLE_DIR"
    ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
