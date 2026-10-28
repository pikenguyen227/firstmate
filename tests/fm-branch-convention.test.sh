#!/usr/bin/env bash
# Behavior of repository branch-convention proposals and full-name delivery.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-branch-convention)
repo="$tmp/repo"
mkdir -p "$repo" "$tmp/home/data"
git init -q "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -qm base

detect() { "$ROOT/bin/fm-branch-convention.py" "$repo" "$@"; }

[ -z "$(detect --task-id task-1 --title 'New panel')" ] || fail 'no rule should make no proposal'
branch=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix project 2>/dev/null)
[ "$branch" = 'fm/' ] || fail 'no rule must keep fm/ fallback'
pass 'no repository rule keeps the fm/ fallback'

printf 'Ship branch prefix: `design/`\n' > "$repo/CONTRIBUTING.md"
out=$(detect --task-id task-1 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'value=design/'* && "$out" == *'source=CONTRIBUTING.md'* && "$out" == *'branch=design/task-1'* ]] || fail "documented prefix was missed: $out"
rm "$repo/CONTRIBUTING.md"
pass 'documented branch prefix wins and cites its source'

cat > "$tmp/rulesets.json" <<'JSON'
[{"id": 71, "rules": [{"type": "branch_name_pattern", "parameters": {"operator": "regex", "pattern": "^(feature|bugfix)/[a-z0-9-]+$", "negate": false}}]}]
JSON
out=$(detect --rulesets-json "$tmp/rulesets.json" --task-id task-1 --title 'Fix tab tooltip')
[[ "$out" == *'kind=typed'* && "$out" == *'source=GitHub ruleset 71'* && "$out" == *'branch=bugfix/fix-tab-tooltip-task-1'* ]] || fail "ruleset branch was missed: $out"
FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" task-1 project --mode local-only --branch-name bugfix/fix-tab-tooltip-task-1 >/dev/null 2>&1 || fail 'brief refused ruleset branch name'
grep -q 'Ship branch: bugfix/fix-tab-tooltip-task-1' "$tmp/home/data/task-1/brief.md" || fail 'brief lost full branch name'
grep -q 'git checkout -b bugfix/fix-tab-tooltip-task-1' "$tmp/home/data/task-1/brief.md" || fail 'worker command lost full branch name'
out=$(detect --template type/ticket-description --task-id task-1 --title 'Add HGRS-1679 selector')
[[ "$out" == *'branch=feature/HGRS-1679-add-hgrs-1679-selector'* ]] || fail "registered typed rule was missed: $out"
for shell in /bin/bash /bin/zsh /bin/sh "$(command -v bash)"; do
  [ -x "$shell" ] || continue
  observed=$("$shell" -c 'exec "$1" "$2" --template type/ticket-description --task-id task-1 --title "Add HGRS-1679 selector"' _ "$ROOT/bin/fm-branch-convention.py" "$repo") \
    || fail "detector failed through $shell"
  [ "$observed" = "$out" ] || fail "detector changed result through $shell"
done
if [ -x /bin/zsh ]; then
  observed=$(/bin/zsh -lc 'exec "$1" "$2" --template type/ticket-description --task-id task-1 --title "Add HGRS-1679 selector"' _ "$ROOT/bin/fm-branch-convention.py" "$repo") \
    || fail 'detector failed through zsh login shell'
  [ "$observed" = "$out" ] || fail 'zsh login shell changed detector result'
fi
pass 'available Bash, zsh, sh, and zsh login shells select the same branch'
printf '%s\n' '# Projects' '- project [no-mistakes branch-rule=type/ticket-description] - fixture' > "$tmp/home/data/projects.md"
setting=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-setting project)
[ "$setting" = 'typed:type/ticket-description' ] || fail "registered typed setting was missed: $setting"
pass 'ruleset pattern and registered typed rule produce full branch names'

for name in design/one design/two design/three design/four design/five; do
  git -C "$repo" branch "$name"
  git -C "$repo" update-ref "refs/remotes/origin/$name" "$(git -C "$repo" rev-parse HEAD)"
done
printf '[]\n' > "$tmp/empty.json"
out=$(detect --task-id task-2 --title 'New panel' --rulesets-json "$tmp/empty.json")
[[ "$out" == *'kind=prefix'* && "$out" == *'branch=design/task-2'* && "$out" == *'origin history'* ]] || fail "history-only pattern was missed: $out"
pass 'consistent recent remote branch history gives a prefix proposal'

printf '%s\n' '# Projects' '- project [no-mistakes branch=owner/] - fixture' > "$tmp/home/data/projects.md"
setting=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-setting project)
[ "$setting" = 'prefix:owner/' ] || fail "explicit registry prefix was missed: $setting"
FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" task-3 project --mode local-only --branch-name design/task-3 --branch-prefix owner/ >/dev/null 2>&1 || fail 'brief refused explicit prefix override'
grep -q 'Ship branch: owner/task-3' "$tmp/home/data/task-3/brief.md" || fail 'explicit prefix did not win'
pass 'explicit prefix wins over a detected full branch name'

echo '# all fm-branch-convention tests passed'
