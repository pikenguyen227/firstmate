#!/usr/bin/env bash
# Quote repository branch rules, preserving any registered project declaration.
# Usage: fm-branch-convention.sh <repo>
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=${1:?repository required}
project=${repo%/}
project=${project##*/}
setting=$("$BASH" "$SCRIPT_DIR/fm-project-mode.sh" --branch-setting "$project" 2>/dev/null) || setting=none
case "$setting" in
  prefix:*)
    prefix=${setting#prefix:}
    printf 'source=registered branch prefix\nquote=%s\n' "$prefix"
    [ -z "$prefix" ] || printf 'operator=starts_with\npattern=%s\n' "$prefix"
    printf '\n' ;;
  typed:*)
    rule=${setting#typed:}
    printf 'source=registered branch rule\nquote=%s\n' "$rule"
    case "$rule" in
      regex:*) printf 'operator=regex\npattern=%s\n' "${rule#regex:}" ;;
      starts_with:*) printf 'operator=starts_with\npattern=%s\n' "${rule#starts_with:}" ;;
      fnmatch:*) printf 'operator=fnmatch\npattern=%s\n' "${rule#fnmatch:}" ;;
    esac
    printf '\n' ;;
esac
if command -v python3 >/dev/null 2>&1; then
  if python3 "$SCRIPT_DIR/fm-branch-convention.py" "$repo"; then exit 0; fi
fi
case "$setting" in prefix:*|typed:*) exit 0 ;; esac
echo 'warn: branch rule finder unavailable and no registered rule exists' >&2
printf 'status=unavailable\nsource=branch rule finder\nquote=repository rules could not be read\n'
