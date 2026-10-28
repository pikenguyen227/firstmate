#!/usr/bin/env bash
# Propose a repository branch convention. See fm-branch-convention.py for
# detection and output details.
# Usage: fm-branch-convention.sh <repo> [--task-id ID --title TITLE] [--template RULE]
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_id=
title=
template=
want=
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      task-id) task_id=$arg ;;
      title) title=$arg ;;
      template) template=$arg ;;
    esac
    want=
    continue
  fi
  case "$arg" in
    --task-id) want=task-id ;;
    --task-id=*) task_id=${arg#--task-id=} ;;
    --title) want=title ;;
    --title=*) title=${arg#--title=} ;;
    --template) want=template ;;
    --template=*) template=${arg#--template=} ;;
  esac
done

detector_failed=0
if command -v python3 >/dev/null 2>&1; then
  if result=$(python3 "$SCRIPT_DIR/fm-branch-convention.py" "$@"); then
    [ -z "$result" ] || printf '%s\n' "$result"
    exit 0
  fi
  detector_failed=1
fi

repo=${1%/}
project=${repo##*/}
setting=$template
if [ -z "$setting" ]; then
  setting=$("$BASH" "$SCRIPT_DIR/fm-project-mode.sh" --branch-setting "$project" 2>/dev/null) || setting=none
fi
case "$setting" in
  prefix:*)
    value=${setting#prefix:}
    printf 'kind=prefix\nvalue=%s\nsource=registered branch prefix\n' "$value"
    if [ -n "$task_id" ]; then
      branch=$value$task_id
      if git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        printf 'branch=%s\n' "$branch"
      else
        printf 'status=needs-decision\nrule=%s\nproposed-branch=%s\n' "$value" "$branch"
      fi
    fi
    ;;
  typed:*) template=${setting#typed:} ;;
  none|'')
    if [ "$detector_failed" -eq 1 ]; then
      echo 'warn: branch convention detector failed; branch choice needs a decision' >&2
      if [ -n "$task_id" ]; then
        printf 'status=needs-decision\nrule=detector failed\nproposed-branch=fm/%s\n' "$task_id"
      fi
      exit 0
    fi
    echo 'warn: branch convention detector unavailable; no registered rule, using fm/' >&2
    if [ -n "$task_id" ]; then
      printf 'kind=prefix\nvalue=fm/\nsource=fallback\nbranch=fm/%s\n' "$task_id"
    fi
    exit 0 ;;
  *) template=$setting ;;
esac
if [ -n "$template" ]; then
  printf 'kind=rule\nvalue=%s\nsource=registered branch rule\n' "$template"
  if [ -n "$task_id" ]; then
    ticket=
    if [[ "$title $task_id" =~ ([A-Z][A-Z0-9]*-[0-9]+) ]]; then ticket=${BASH_REMATCH[1]}; fi
    slug=
    lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    for ((i=0; i<${#lower}; i++)); do
      char=${lower:i:1}
      case "$char" in [a-z0-9]) slug+=$char ;; *) [[ "$slug" == *- ]] || slug+=- ;; esac
    done
    slug=${slug#-}; slug=${slug%-}
    [ -n "$slug" ] || slug=change
    if [[ "$lower" =~ (^|[^a-z])(bug|fix|broken|regression)([^a-z]|$) ]]; then branch_type=bugfix; else branch_type=feature; fi
    case "$template" in
      type/ticket-description|ticket-description)
        if [ -n "$ticket" ]; then
          if [ "$template" = type/ticket-description ]; then branch="$branch_type/$ticket-$slug"; else branch="$ticket-$slug"; fi
          if git check-ref-format --branch "$branch" >/dev/null 2>&1; then
            printf 'branch=%s\n' "$branch"
          else
            printf 'status=needs-decision\nrule=%s\nproposed-branch=%s\n' "$template" "$branch"
          fi
        else
          if [ "$template" = type/ticket-description ]; then proposal="$branch_type/$slug-$task_id"; else proposal="$slug-$task_id"; fi
          printf 'status=needs-decision\nrule=%s\nproposed-branch=%s\n' "$template" "$proposal"
        fi ;;
      *) printf 'status=needs-decision\nrule=%s\nproposed-branch=feature/%s-%s\n' "$template" "$slug" "$task_id" ;;
    esac
  fi
fi
