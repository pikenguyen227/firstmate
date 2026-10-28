#!/usr/bin/env bash
# Observable branch proposals from repository evidence and saved declarations.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-branch-convention)
repo="$tmp/repo"
home="$tmp/home"
mkdir -p "$repo" "$home/data" "$tmp/fakebin"
git init -q "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -qm base

detect() { FM_HOME="$home" PATH="$tmp/fakebin:$PATH" "$ROOT/bin/fm-branch-convention.sh" "$repo" "$@"; }

[ -z "$(detect --task-id task-1 --title 'New panel')" ] || fail 'no rule should make no proposal'
[ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix repo 2>/dev/null)" = fm/ ] \
  || fail 'no rule must keep fm/ fallback'
pass 'no rule retains the fm/ fallback'

# shellcheck disable=SC2016 # Literal backticks are fixture content.
printf 'Ship branch prefix: `design/`\n' > "$repo/CONTRIBUTING.md"
out=$(detect --task-id task-1 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'value=design/'* && "$out" == *'source=CONTRIBUTING.md'* && "$out" == *'branch=design/task-1'* ]] \
  || fail "documented prefix was missed: $out"
for shell in /bin/bash /bin/zsh /bin/sh "$(command -v bash)"; do
  [ -x "$shell" ] || continue
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  observed=$(FM_HOME="$home" "$shell" -c 'exec "$1" "$2" --task-id task-1 --title "New panel"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail "detector failed through $shell"
  [ "$observed" = "$out" ] || fail "detector changed result through $shell"
done
if [ -x /bin/zsh ]; then
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  observed=$(FM_HOME="$home" /bin/zsh -lc 'exec "$1" "$2" --task-id task-1 --title "New panel"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail 'detector failed through zsh login shell'
  [ "$observed" = "$out" ] || fail 'zsh login changed the branch'
fi
rm "$repo/CONTRIBUTING.md"
pass 'documented prefix is stable across available shells'

cat > "$tmp/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$3" in
  */rulesets\?*) [ -f "$FM_TEST_RULESET_DETAIL" ] && printf '[{"id":71,"enforcement":"active","target":"branch"}]\n' ;;
  */rulesets/71) [ -f "$FM_TEST_RULESET_DETAIL" ] && cat "$FM_TEST_RULESET_DETAIL" ;;
esac
SH
chmod +x "$tmp/fakebin/gh-axi"
export FM_TEST_RULESET_DETAIL="$tmp/ruleset-detail"
git -C "$repo" remote add origin https://github.com/example/project.git
printf '%s\n' '{"conditions":{"ref_name":{"include":[],"exclude":[]}},"rules":[{"type":"branch_name_pattern","parameters":{"operator":"regex","pattern":"^feature/[a-z0-9-]+$","negate":false}}]}' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'value=feature/'* && "$out" == *'source=GitHub ruleset 71'* && "$out" == *'branch=feature/task-2'* ]] \
  || fail "simple ruleset prefix was missed: $out"
git -C "$repo" remote set-url origin ssh://git@github.com/example/project.git
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'branch=feature/task-2'* ]] || fail 'ssh origin lost the ruleset prefix'
printf '%s\n' '{"conditions":{"ref_name":{"include":["refs/heads/design/*"],"exclude":[]}},"rules":[{"type":"required_status_checks"}]}' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'value=design/'* && "$out" == *'branch=design/task-2'* ]] \
  || fail "plain protection pattern was missed: $out"
printf '%s\n' '{"conditions":{"ref_name":{"include":[],"exclude":[]}},"rules":[{"type":"branch_name_pattern","parameters":{"operator":"starts_with","pattern":"design/","negate":false}}]}' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'value=design/'* && "$out" == *'branch=design/task-2'* ]] \
  || fail "starts_with branch rule was missed: $out"
pass 'plain-prefix GitHub ruleset and protection patterns are detected'

printf '%s\n' '{"conditions":{"ref_name":{"include":[],"exclude":[]}},"rules":[{"type":"branch_name_pattern","parameters":{"operator":"regex","pattern":"^(feat|fix)/[a-z0-9-]+$","negate":false}}]}' > "$FM_TEST_RULESET_DETAIL"
out=$(detect --task-id task-2 --title 'Fix panel')
[[ "$out" == *'status=needs-decision'* && "$out" == *'GitHub ruleset 71'* && "$out" != *$'\nbranch='* ]] \
  || fail "alternating ruleset was guessed: $out"
printf '%s\n' '{"conditions":{"ref_name":{"include":[],"exclude":[]}},"rules":[{"type":"branch_name_pattern","parameters":{"operator":"regex","pattern":"^feature/[a-z0-9-]+$","negate":false}}]}' > "$FM_TEST_RULESET_DETAIL"
# shellcheck disable=SC2016 # Literal backticks are fixture content.
printf 'Ship branch prefix: `design/`\n' > "$repo/CONTRIBUTING.md"
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'status=needs-decision'* && "$out" != *$'\nbranch='* ]] \
  || fail "conflicting docs and ruleset were guessed: $out"
rm "$repo/CONTRIBUTING.md" "$FM_TEST_RULESET_DETAIL"
pass 'complex and conflicting rules ask for one project decision'

# The UIUX workspace records its Git workflow in a tracked workspace vault.
mkdir -p "$repo/_vaults/workspace/wiki" "$repo/_vaults/adc/wiki"
# shellcheck disable=SC2016 # Literal backticks are fixture content.
printf 'Ship branch prefix: `design/`\n' > "$repo/_vaults/workspace/wiki/project-context.md"
git -C "$repo" add _vaults
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'kind=prefix'* && "$out" == *'source=_vaults/workspace/wiki/project-context.md'* && "$out" == *'branch=design/task-2'* ]] \
  || fail "simple tracked vault rule was missed: $out"
cat > "$repo/_vaults/workspace/wiki/project-context.md" <<'MD'
## Git workflow
feature/workspace/<desc>                         ← root configs
feature/<pillar>/<package>/<TICKET-desc>         ← package work
hotfix/<desc>                                    ← release repair
MD
printf '<Type> renders an ordinary component.\n' > "$repo/_vaults/adc/wiki/component.md"
git -C "$repo" add _vaults
out=$(detect --task-id task-2 --title 'New panel')
[[ "$out" == *'status=needs-decision'* && "$out" == *'_vaults/workspace/wiki/project-context.md'* && "$out" != *'component.md'* && "$out" != *$'\nbranch='* ]] \
  || fail "workspace vault rule was missed or a component type was mistaken for one: $out"
git -C "$repo" reset -q -- _vaults
rm -rf "$repo/_vaults"
pass 'tracked workspace vault templates surface a decision without unrelated type noise'

for name in design/one design/two design/three design/four; do
  git -C "$repo" update-ref "refs/remotes/origin/$name" "$(git -C "$repo" rev-parse HEAD)"
done
out=$(detect --task-id task-3 --title 'New panel')
[[ "$out" == *'status=needs-decision'* && "$out" == *'branch history:'* && "$out" != *$'\nbranch='* ]] \
  || fail "history-only pattern was guessed: $out"
pass 'history-only evidence asks instead of recording an inferred prefix'

printf '%s\n' '# Projects' '- repo [no-mistakes branch=owner/] - fixture' > "$home/data/projects.md"
out=$(detect --task-id task-4 --title 'New panel')
[[ "$out" == *'source=registered branch prefix'* && "$out" == *'branch=owner/task-4'* ]] \
  || fail "recorded prefix did not win: $out"
FM_HOME="$home" "$ROOT/bin/fm-brief.sh" task-4 repo --mode local-only --branch-name feature/task-4 --branch-prefix owner/ >/dev/null 2>&1 \
  || fail 'brief refused explicit prefix override'
grep -q 'Ship branch: owner/task-4' "$home/data/task-4/brief.md" || fail 'brief lost the explicit prefix'
pass 'recorded project rule and explicit task override win'

mkdir -p "$tmp/no-python"
for tool in dirname awk git; do ln -s "$(command -v "$tool")" "$tmp/no-python/$tool"; done
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-5 2>"$tmp/warning") \
  || fail 'missing Python blocked a recorded prefix'
[[ "$out" == *'branch=owner/task-5'* ]] || fail 'missing Python lost the recorded prefix'
printf '%s\n' '# Projects' > "$home/data/projects.md"
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" --task-id task-5 2>"$tmp/warning") \
  || fail 'missing Python blocked the fallback'
[[ "$out" == *'branch=fm/task-5'* ]] || fail 'missing Python did not use fm/'
[ "$(wc -l < "$tmp/warning")" -eq 1 ] || fail 'missing Python emitted more than one warning'
pass 'missing Python preserves recorded rules and gives a one-line fallback warning'

echo '# all fm-branch-convention tests passed'
