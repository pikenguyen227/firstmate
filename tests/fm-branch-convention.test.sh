#!/usr/bin/env bash
# Branch rule evidence and name validation through executable interfaces.
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
finder() { FM_HOME="$home" PATH="$tmp/fakebin:$PATH" "$ROOT/bin/fm-branch-convention.sh" "$repo"; }
validate() { "$ROOT/bin/fm-branch-name-validate.sh" "$repo" "$@"; }

[ "$(finder)" = status=no-rule ] || fail 'empty repository should have no rule'
[ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix repo 2>/dev/null)" = fm/ ] \
  || fail 'no rule must retain fm/ fallback'
git -C "$repo" update-ref refs/remotes/origin/feature/one "$(git -C "$repo" rev-parse HEAD)"
[ "$(finder)" = status=no-rule ] || fail 'branch history should not be treated as a rule'
pass 'no rule retains fm/ fallback'

cat > "$repo/CONTRIBUTING.md" <<'MD'
## Branch naming
Branch names must start with design/.
git checkout -b design/example
MD
out=$(finder)
[[ "$out" == *'source=CONTRIBUTING.md:2'* && "$out" == *'quote=Branch names must start with design/.'* && "$out" == *'operator=starts_with'* && "$out" == *'pattern=design/'* && "$out" == *'source=CONTRIBUTING.md:3'* ]] \
  || fail "documented rule passages were missed: $out"
for shell in /bin/bash /bin/zsh /bin/sh "$(command -v bash)"; do
  [ -x "$shell" ] || continue
  # shellcheck disable=SC2016 # Child shell uses its own positional parameters.
  observed=$(FM_HOME="$home" "$shell" -c 'exec "$1" "$2"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail "finder failed through $shell"
  [ "$observed" = "$out" ] || fail "finder changed result through $shell"
done
rm "$repo/CONTRIBUTING.md"
pass 'repository docs are quoted with line provenance across shells'

mkdir -p "$repo/_vaults/workspace/wiki" "$repo/_vaults/workspace/raw"
cat > "$repo/_vaults/workspace/wiki/project-context.md" <<'MD'
## Git workflow
feature/workspace/<desc>                          ← root configs
feature/<pillar>/<package>/<TICKET-desc>          ← package work
MD
printf 'Branch prefix: secret/\n' > "$repo/_vaults/workspace/raw/scratch.md"
git -C "$repo" add _vaults/workspace/wiki
out=$(finder)
[[ "$out" == *'source=_vaults/workspace/wiki/project-context.md:2'* && "$out" == *'feature/workspace/<desc>'* && "$out" == *'source=_vaults/workspace/wiki/project-context.md:3'* && "$out" != *'secret/'* ]] \
  || fail "UIUX-shaped vault rule or raw exclusion failed: $out"
git -C "$repo" reset -q -- _vaults
rm -rf "$repo/_vaults"
pass 'tracked UIUX-shaped vault wiki is quoted and raw notes are excluded'

cat > "$tmp/fakebin/gh-axi" <<'AXI'
#!/usr/bin/env bash
[ "${FM_TEST_FAIL:-0}" = 0 ] || exit 1
case "$3" in
  */rulesets\?*) [ -f "$FM_TEST_RULESET_DETAIL" ] && printf '[{"id":71,"enforcement":"active","target":"branch"}]\n' || printf '[]\n' ;;
  */rulesets/71) cat "$FM_TEST_RULESET_DETAIL" ;;
esac
AXI
chmod +x "$tmp/fakebin/gh-axi"
export FM_TEST_RULESET_DETAIL="$tmp/ruleset-detail"
git -C "$repo" remote add origin https://github.com/example/project.git
printf '%s\n' '{"conditions":{"ref_name":{"include":[],"exclude":[]}},"rules":[{"type":"branch_name_pattern","parameters":{"operator":"regex","pattern":"^feature/[a-z0-9-]+$","negate":false}}]}' > "$FM_TEST_RULESET_DETAIL"
out=$(finder)
[[ "$out" == *'source=GitHub ruleset 71'* && "$out" == *'operator=regex'* && "$out" == *'pattern=^feature/[a-z0-9-]+$'* ]] \
  || fail "GitHub rule was not quoted: $out"
if validate feature/ABC --operator regex --pattern '^feature/[a-z0-9-]+$' > "$tmp/out"; then fail 'uppercase branch escaped GitHub regex'; fi
grep -q '^status=invalid$' "$tmp/out" || fail 'regex failure not reported'
[ "$(validate feature/task-2 --operator regex --pattern '^feature/[a-z0-9-]+$')" = $'status=valid\ncheck=git+regex' ] \
  || fail 'valid regex name was rejected'
pass 'GitHub pattern is quoted and validator enforces its constraints'

printf '%s\n' '{"conditions":{"ref_name":{"include":["refs/heads/design/*"],"exclude":[]}},"rules":[]}' > "$FM_TEST_RULESET_DETAIL"
out=$(finder)
[[ "$out" == *'operator=fnmatch'* && "$out" == *'pattern=design/*'* ]] || fail "GitHub ref pattern was missed: $out"
[ "$(validate design/task-2 --operator fnmatch --pattern 'design/*')" = $'status=valid\ncheck=git+fnmatch' ] \
  || fail 'valid fnmatch name was rejected'
if validate bad..name > "$tmp/out"; then fail 'invalid Git ref was accepted'; fi
[ "$(validate design/task-2 --operator starts_with --pattern design/)" = $'status=valid\ncheck=git+starts_with' ] \
  || fail 'valid prefix name was rejected'
if validate feature/task-2 --operator starts_with --pattern design/ > "$tmp/out"; then fail 'wrong prefix was accepted'; fi
pass 'Git syntax, prefix and GitHub protection patterns are validated'

export FM_TEST_FAIL=1
out=$(finder)
[[ "$out" == *'status=unavailable'* && "$out" != *'status=no-rule'* ]] || fail "unreadable GitHub settings looked like no rule: $out"
unset FM_TEST_FAIL
pass 'unreadable GitHub settings require a decision'

printf '%s\n' '# Projects' '- repo [no-mistakes branch=owner/] - fixture' > "$home/data/projects.md"
out=$(finder)
[[ "$out" == *'source=registered branch prefix'* && "$out" == *'pattern=owner/'* ]] \
  || fail "recorded prefix was lost: $out"
printf '%s\n' '# Projects' '- repo [no-mistakes branch-rule=regex:^feature/[a-z0-9-]+$] - fixture' > "$home/data/projects.md"
out=$(finder)
[[ "$out" == *'source=registered branch rule'* && "$out" == *'operator=regex'* && "$out" == *'pattern=^feature/[a-z0-9-]+$'* ]] \
  || fail "recorded rule was lost: $out"
mkdir -p "$tmp/no-python"
for tool in dirname awk git; do ln -s "$(command -v "$tool")" "$tmp/no-python/$tool"; done
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo") \
  || fail 'recorded rule required Python'
[[ "$out" == *'source=registered branch rule'* && "$out" == *'pattern=^feature/[a-z0-9-]+$'* ]] \
  || fail "Python-free registered rule was lost: $out"
pass 'registered prefixes and rules survive without Python'

echo '# all fm-branch-convention tests passed'
