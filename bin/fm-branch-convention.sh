#!/usr/bin/env bash
# Propose a repository branch convention, with the ordinary fm/ fallback when
# Python is unavailable or the detector fails. See fm-branch-convention.py for
# detection and output details. No task id means project-add discovery; on a
# detector failure that path records no declaration.
# Usage: fm-branch-convention.sh <repo> [--task-id ID --title TITLE] [--template type/ticket-description]
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_id=
want=
for arg in "$@"; do
  if [ "$want" = task-id ]; then
    task_id=$arg
    want=
    continue
  fi
  case "$arg" in
    --task-id) want=task-id ;;
    --task-id=*) task_id=${arg#--task-id=} ;;
  esac
done

if command -v python3 >/dev/null 2>&1; then
  if result=$(python3 "$SCRIPT_DIR/fm-branch-convention.py" "$@" 2>/dev/null); then
    [ -z "$result" ] || printf '%s\n' "$result"
    exit 0
  fi
fi

echo 'warn: branch convention detector unavailable; use the registered prefix if present, otherwise fm/' >&2
if [ -n "$task_id" ]; then
  printf 'kind=prefix\nvalue=fm/\nsource=fallback\nbranch=fm/%s\n' "$task_id"
fi
