#!/usr/bin/env bash
# Refuse a ship branch that ignores the repository's branch rules.
# Usage: fm-branch-gate.sh <repo> <branch> [--pattern <regex>]
#
# Runs fm-branch-convention.sh and fm-branch-name-validate.sh, so spawn and
# promotion enforce the same decision intake made.
#   - No rule passage found: the branch needs only valid Git syntax (fm/ default).
#   - Any passage found (docs, vault, GitHub, or a registered declaration): the
#     coordinator must supply the ERE it derived from them as --pattern, which the
#     branch must match. A registered regex can supply that pattern; registered
#     rules are also enforced and are never cleared or replaced.
# Prints status=ok or status=refused plus a reason; exit 0 only for ok.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=${1:?repository required}
branch=${2:?branch required}
shift 2
pattern=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pattern) pattern=${2:?pattern required}; shift 2 ;;
    --pattern=*) pattern=${1#--pattern=}; shift ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
refuse() { printf 'status=refused\nreason=%s\n' "$1"; exit 1; }
validate() { "$BASH" "$SCRIPT_DIR/fm-branch-name-validate.sh" "$repo" "$branch" "$@"; }

found=0
repository_found=0
recorded=0
recorded_regex=0
registered=0
operator=
checks=()
# The finder prints blank-line separated blocks of source=/quote=/operator=/pattern= lines.
finder_out=$("$BASH" "$SCRIPT_DIR/fm-branch-convention.sh" "$repo" 2>/dev/null) || finder_out=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    source=registered*) found=1; registered=1 ;;
    source=GitHub\ branch\ settings) ;;
    source=*) found=1; repository_found=1; registered=0 ;;
    operator=*) operator=${line#operator=} ;;
    pattern=*)
      if [ "$registered" -eq 1 ] && [ -n "$operator" ]; then
        recorded=1
        [ "$operator" != regex ] || recorded_regex=1
        checks+=("$operator" "${line#pattern=}")
      fi ;;
    '') registered=0; operator= ;;
  esac
done <<< "$finder_out"

if [ "$found" -eq 1 ] && [ -z "$pattern" ]; then
  if [ "$recorded" -eq 0 ] || { [ "$repository_found" -eq 1 ] && [ "$recorded_regex" -eq 0 ]; }; then
    refuse "branch rules were found but no pattern is recorded; derive an ERE from them and pass --branch-pattern, or record regex:<pattern> as the project's branch-rule"
  fi
fi
rc=0
out=$(validate) || rc=$?
[ "$rc" -eq 0 ] || refuse "${out#*reason=}"
if [ -n "$pattern" ]; then
  rc=0
  out=$(validate --operator regex --pattern "$pattern") || rc=$?
  [ "$rc" -eq 0 ] || refuse "branch '$branch' does not satisfy the recorded pattern: ${out#*reason=}"
fi
i=0
while [ "$i" -lt "${#checks[@]}" ]; do
  rc=0
  out=$(validate --operator "${checks[$i]}" --pattern "${checks[$((i + 1))]}") || rc=$?
  [ "$rc" -eq 0 ] || refuse "branch '$branch' does not satisfy the registered rule: ${out#*reason=}"
  i=$((i + 2))
done
printf 'status=ok\n'
