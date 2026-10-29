#!/usr/bin/env bash
# Validate a chosen branch against Git syntax and an optional quoted rule.
# Usage: fm-branch-name-validate.sh <repo> <branch> [--operator regex|starts_with|fnmatch --pattern <value>]
set -eu
repo=${1:?repository required}
branch=${2:?branch required}
shift 2
operator=
pattern=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --operator) operator=${2:?operator required}; shift 2 ;;
    --pattern) pattern=${2:?pattern required}; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
if ! git -C "$repo" check-ref-format --branch "$branch" >/dev/null 2>&1; then
  printf 'status=invalid\nreason=invalid Git branch name\n'
  exit 1
fi
if [ -z "$operator" ] && [ -z "$pattern" ]; then
  printf 'status=valid\ncheck=git\n'
  exit 0
fi
if [ -z "$operator" ] || [ -z "$pattern" ]; then
  printf 'status=low-confidence\nreason=incomplete machine pattern\n'
  exit 2
fi
regex_matches() { [[ "$branch" =~ $pattern ]]; }
# fnmatch intentionally uses a glob pattern.
# shellcheck disable=SC2053
case "$operator" in
  starts_with) [[ "$branch" == "$pattern"* ]] && matched=1 || matched=0 ;;
  fnmatch) [[ "$branch" == $pattern ]] && matched=1 || matched=0 ;;
  regex)
    rc=0
    regex_matches || rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'status=low-confidence\nreason=unsupported regex pattern\n'
      exit 2
    fi
    [ "$rc" -eq 0 ] && matched=1 || matched=0 ;;
  *) printf 'status=low-confidence\nreason=unsupported pattern operator\n'; exit 2 ;;
esac
if [ "$matched" -eq 1 ]; then
  printf 'status=valid\ncheck=git+%s\n' "$operator"
else
  printf 'status=invalid\nreason=branch does not match repository pattern\n'
  exit 1
fi
