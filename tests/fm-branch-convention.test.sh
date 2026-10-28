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

detect() { "$ROOT/bin/fm-branch-convention.sh" "$repo" "$@"; }

[ -z "$(detect --task-id task-1 --title 'New panel')" ] || fail 'no rule should make no proposal'
branch=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix project 2>/dev/null)
[ "$branch" = 'fm/' ] || fail 'no rule must keep fm/ fallback'
pass 'no repository rule keeps the fm/ fallback'

# shellcheck disable=SC2016 # Literal backticks are fixture content.
printf 'Ship branch prefix: `design/`\n' > "$repo/CONTRIBUTING.md"
out=$(detect --task-id task-1 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'value=design/'* && "$out" == *'source=CONTRIBUTING.md'* && "$out" == *'branch=design/task-1'* ]] || fail "documented prefix was missed: $out"
rm "$repo/CONTRIBUTING.md"
pass 'documented branch prefix wins and cites its source'

mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$3" in
  */rulesets\?*) [ -f "$FM_TEST_RULESET_DETAIL" ] && printf '  - id: 71\n    enforcement: active\n    target: branch\n' ;;
  */rulesets/71) [ -f "$FM_TEST_RULESET_DETAIL" ] && cat "$FM_TEST_RULESET_DETAIL" ;;
esac
SH
chmod +x "$tmp/fakebin/gh-axi"
git -C "$repo" remote add origin https://github.com/example/project.git
export FM_TEST_RULESET_DETAIL="$tmp/ruleset-detail"
detect() { PATH="$tmp/fakebin:$PATH" "$ROOT/bin/fm-branch-convention.sh" "$repo" "$@"; }
printf 'type: branch_name_pattern\npattern: "^(feat|fix)/[a-z0-9-]+$"\nnegate: false\n' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-1 --title 'Fix tab tooltip')
[[ "$out" == *'kind=rule'* && "$out" == *'source=GitHub ruleset 71'* && "$out" == *'branch=fix/fix-tab-tooltip-task-1'* ]] || fail "ruleset branch was missed: $out"
rule=$(printf '%s\n' "$out" | sed -n 's/^value=//p')
printf '%s\n' '# Projects' "- project [no-mistakes branch-rule=$rule] - fixture" > "$tmp/home/data/projects.md"
out=$(detect --template "$rule" --task-id task-1 --title 'Fix tab tooltip')
[[ "$out" == *'branch=fix/fix-tab-tooltip-task-1'* ]] || fail "registered regex was not preserved: $out"
out=$(detect --template "$rule" --task-id task-1 --title 'Fix HGRS-1679 selector')
[[ "$out" == *'branch=fix/hgrs-1679-fix-hgrs-1679-selector'* ]] || fail "lowercase-only regex received an uppercase ticket: $out"
setting=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-setting project)
[ "$setting" = "typed:$rule" ] || fail "registry changed the regex rule: $setting"
printf 'type: branch_name_pattern\npattern: "^(feat|fix)/[A-Z]+-[0-9]+-[a-z0-9-]+$"\nnegate: false\n' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-1 --title 'Fix selector')
[[ "$out" == *'status=needs-decision'* && "$out" == *'rule=^(feat|fix)/[A-Z]+-[0-9]+-[a-z0-9-]+$'* && "$out" != *$'\nbranch='* ]] || fail "ticket-required regex invented a branch: $out"
FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" task-1 project --mode local-only --branch-name fix/fix-tab-tooltip-task-1 >/dev/null 2>&1 || fail 'brief refused ruleset branch name'
grep -q 'Ship branch: fix/fix-tab-tooltip-task-1' "$tmp/home/data/task-1/brief.md" || fail 'brief lost full branch name'
grep -q 'git checkout -b fix/fix-tab-tooltip-task-1' "$tmp/home/data/task-1/brief.md" || fail 'worker command lost full branch name'
printf 'type: branch_name_pattern\npattern: "^(feat|fix)/[a-z0-9-]+$"\nnegate: false\n' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --template type/ticket-description --task-id task-1 --title 'Add HGRS-1679 selector')
[[ "$out" == *'branch=feature/HGRS-1679-add-hgrs-1679-selector'* ]] || fail "registered typed rule was missed: $out"
typed_out=$out
out=$(detect --template type/ticket-description --task-id task-1 --title 'Add selector')
[[ "$out" == *'status=needs-decision'* && "$out" == *'rule=type/ticket-description'* && "$out" != *$'\nbranch='* ]] || fail "ticketless rule invented a branch: $out"
printf 'Ship branch: `<ticket>-<description>`\n' > "$repo/BRANCHING.md"
out=$(detect --task-id task-1 --title 'Add selector')
[[ "$out" == *'value=ticket-description'* && "$out" == *'status=needs-decision'* ]] || fail "documented ticket rule was guessed: $out"
rm "$repo/BRANCHING.md"
for shell in /bin/bash /bin/zsh /bin/sh "$(command -v bash)"; do
  [ -x "$shell" ] || continue
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  observed=$("$shell" -c 'exec "$1" "$2" --template type/ticket-description --task-id task-1 --title "Add HGRS-1679 selector"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail "detector failed through $shell"
  [ "$observed" = "$typed_out" ] || fail "detector changed result through $shell"
done
if [ -x /bin/zsh ]; then
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  observed=$(/bin/zsh -lc 'exec "$1" "$2" --template type/ticket-description --task-id task-1 --title "Add HGRS-1679 selector"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail 'detector failed through zsh login shell'
  [ "$observed" = "$typed_out" ] || fail 'zsh login shell changed detector result'
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
rm "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'branch=design/task-2'* && "$out" == *'origin history'* ]] || fail "history-only pattern was missed: $out"
pass 'consistent recent remote branch history gives a prefix proposal'

for name in design/one design/two design/three design/four design/five; do
  git -C "$repo" update-ref -d "refs/remotes/origin/$name"
done
for name in user/alice/one user/alice/two user/alice/three user/alice/four; do
  git -C "$repo" update-ref "refs/remotes/origin/$name" "$(git -C "$repo" rev-parse HEAD)"
done
out=$(detect --task-id task-2 --title 'New panel' 2>"$tmp/history-note")
[ -z "$out" ] || fail "multi-segment history became a partial prefix: $out"
grep -q 'multi-segment branch history' "$tmp/history-note" || fail 'multi-segment history lacked a note'
pass 'multi-segment owner history does not record a partial prefix'

printf '%s\n' '# Projects' '- project [no-mistakes branch=owner/] - fixture' > "$tmp/home/data/projects.md"
setting=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-project-mode.sh" --branch-setting project)
[ "$setting" = 'prefix:owner/' ] || fail "explicit registry prefix was missed: $setting"
FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" task-3 project --mode local-only --branch-name design/task-3 --branch-prefix owner/ >/dev/null 2>&1 || fail 'brief refused explicit prefix override'
grep -q 'Ship branch: owner/task-3' "$tmp/home/data/task-3/brief.md" || fail 'explicit prefix did not win'
pass 'explicit prefix wins over a detected full branch name'

mkdir -p "$tmp/no-python"
ln -s "$(command -v dirname)" "$tmp/no-python/dirname"
ln -s "$(command -v awk)" "$tmp/no-python/awk"
ln -s "$(command -v git)" "$tmp/no-python/git"
ln -s "$(command -v tr)" "$tmp/no-python/tr"
printf '%s\n' '# Projects' '- repo [no-mistakes branch-rule=type/ticket-description] - fixture' > "$tmp/home/data/projects.md"
out=$(FM_HOME="$tmp/home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-4 --title 'Add HGRS-1679 selector' 2>"$tmp/no-python-warning") \
  || fail 'missing python3 blocked registered rule'
[[ "$out" == *'branch=feature/HGRS-1679-add-hgrs-1679-selector'* ]] || fail "missing python3 lost registered rule: $out"
out=$(FM_HOME="$tmp/home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-4 --title 'Add selector' 2>"$tmp/no-python-warning") \
  || fail 'missing python3 blocked rule decision'
[[ "$out" == *'status=needs-decision'* && "$out" != *$'\nbranch='* ]] || fail "missing python3 invented a ticket: $out"
printf '%s\n' '# Projects' "- repo [no-mistakes branch-rule=$rule] - fixture" > "$tmp/home/data/projects.md"
out=$(FM_HOME="$tmp/home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-4 --title 'Fix tab tooltip' 2>"$tmp/no-python-warning")
[[ "$out" == *'status=needs-decision'* && "$out" == *"rule=$rule"* && "$out" != *$'\nbranch='* ]] || fail "missing python3 guessed a regex branch: $out"
printf '%s\n' '# Projects' '- repo [no-mistakes branch=owner/] - fixture' > "$tmp/home/data/projects.md"
out=$(FM_HOME="$tmp/home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-4 2>"$tmp/no-python-warning")
[[ "$out" == *'branch=owner/task-4'* ]] || fail "missing python3 lost registered prefix: $out"
printf '%s\n' '# Projects' > "$tmp/home/data/projects.md"
out=$(PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-4 --title 'New panel' 2>"$tmp/no-python-warning") \
  || fail 'missing python3 blocked detection fallback'
[[ "$out" == *'kind=prefix'* && "$out" == *'value=fm/'* && "$out" == *'branch=fm/task-4'* ]] \
  || fail "missing python3 did not choose fm/: $out"
[ "$(wc -l < "$tmp/no-python-warning")" -eq 1 ] || fail 'missing python3 emitted more than one warning line'
out=$(PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" 2>"$tmp/no-python-warning") \
  || fail 'missing python3 blocked project-add discovery'
[ -z "$out" ] || fail 'failed project-add discovery invented a declaration'
printf '#!/bin/sh\nexit 7\n' > "$tmp/no-python/python3"
chmod +x "$tmp/no-python/python3"
out=$(PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-5 2>"$tmp/no-python-warning") \
  || fail 'failing python3 blocked branch decision'
[[ "$out" == *'status=needs-decision'* && "$out" != *$'\nbranch='* ]] || fail 'failing python3 invented a branch'
pass 'missing Python keeps registered rules and detector failures need a decision'

echo '# all fm-branch-convention tests passed'
