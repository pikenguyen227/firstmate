#!/usr/bin/env bash
# Propose a repository branch prefix without overriding a registered rule.
# Usage: fm-branch-convention.sh <repo> [--task-id ID --title TITLE]
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=${1:?repository required}
project=${repo%/}
project=${project##*/}
task_id=
want=
for arg in "$@"; do
  if [ "$want" = task-id ]; then task_id=$arg; want=; continue; fi
  case "$arg" in
    --task-id) want=task-id ;;
    --task-id=*) task_id=${arg#--task-id=} ;;
  esac
done

# A recorded project decision is authoritative even when the Python detector
# is installed and later repository evidence changes.
setting=$("$BASH" "$SCRIPT_DIR/fm-project-mode.sh" --branch-setting "$project" 2>/dev/null) || setting=none
case "$setting" in
  prefix:*)
    prefix=${setting#prefix:}
    printf 'kind=prefix\nvalue=%s\nsource=registered branch prefix\n' "$prefix"
    if [ -n "$task_id" ]; then
      branch=$prefix$task_id
      if git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        printf 'branch=%s\n' "$branch"
      else
        printf 'status=needs-decision\nrule=%s\nproposed-branch=%s\n' "$prefix" "$branch"
      fi
    fi
    exit 0 ;;
  typed:*)
    printf 'status=needs-decision\nrule=%s\nsource=registered branch rule\nproposed-branch=fm/%s\n' "${setting#typed:}" "${task_id:-task-id}"
    exit 0 ;;
esac

if command -v python3 >/dev/null 2>&1; then
  if result=$(python3 "$SCRIPT_DIR/fm-branch-convention.py" "$@" 2>/dev/null); then
    [ -z "$result" ] || printf '%s\n' "$result"
    exit 0
  fi
fi
echo 'warn: branch convention detection unavailable; no registered rule, using fm/' >&2
if [ -n "$task_id" ]; then
  printf 'kind=prefix\nvalue=fm/\nsource=fallback\nbranch=fm/%s\n' "$task_id"
fi
