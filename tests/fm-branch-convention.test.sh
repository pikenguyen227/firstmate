#!/usr/bin/env bash
# Branch rule evidence and name validation through executable interfaces.
set -u
# shellcheck source=tests/lib.sh
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

[ -z "$(finder)" ] || fail 'empty repository should provide no rule evidence'
[ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix repo 2>/dev/null)" = fm/ ] \
  || fail 'no rule must retain fm/ fallback'
git -C "$repo" update-ref refs/remotes/origin/feature/one "$(git -C "$repo" rev-parse HEAD)"
[ -z "$(finder)" ] || fail 'branch history should not be treated as a rule'
pass 'no rule retains fm/ fallback'

cat > "$repo/CONTRIBUTING.md" <<'MD'
## Branch naming
Branch names must start with design/.
git checkout -b design/example
design/<desc> is used for design work.
Follow the repository's branch instructions.
MD
out=$(finder)
[[ "$out" == *'source=CONTRIBUTING.md:2'* && "$out" == *'quote=Branch names must start with design/.'* && "$out" == *'operator=starts_with'* && "$out" == *'pattern=design/'* && "$out" == *'source=CONTRIBUTING.md:4'* && "$out" == *'source=CONTRIBUTING.md:5'* && "$out" != *'source=CONTRIBUTING.md:3'* ]] \
  || fail "documented rule passages were missed: $out"
for shell in /bin/bash /bin/zsh /bin/sh "$(command -v bash)"; do
  [ -x "$shell" ] || continue
  # shellcheck disable=SC2016 # Child shell uses its own positional parameters.
  observed=$(FM_HOME="$home" "$shell" -c 'exec "$1" "$2"' _ "$ROOT/bin/fm-branch-convention.sh" "$repo") \
    || fail "finder failed through $shell"
  [ "$observed" = "$out" ] || fail "finder changed result through $shell"
done
rm "$repo/CONTRIBUTING.md"
printf 'Branch name: design/sample\n' > "$repo/BRANCHING.md"
out=$(finder)
[[ "$out" == *'source=BRANCHING.md:1'* && "$out" == *'quote=Branch name: design/sample'* ]] \
  || fail "standalone branch name pattern was missed: $out"
rm "$repo/BRANCHING.md"
cat > "$repo/README.md" <<'MD'
## Branching
Follow existing conventions.
## Configuration
config/<name> is a file path.
MD
out=$(finder)
[[ "$out" == *'source=README.md:2'* && "$out" == *'quote=Follow existing conventions.'* && "$out" != *'config/<name>'* && "$out" != *'status='* ]] \
  || fail "vague advice or unrelated path was mishandled: $out"
rm "$repo/README.md"
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

# Mirrors gh-axi api: only --field/--jq/--full are accepted, failures exit non-zero,
# and a --jq read is answered as an api_response body of plain lines.
cat > "$tmp/fakebin/gh-axi" <<'AXI'
#!/usr/bin/env bash
[ "${FM_TEST_FAIL:-0}" = 0 ] || { echo 'error: "gh: Not Found (HTTP 404)"'; exit 1; }
for arg in "$@"; do
  case "$arg" in -f|-F) echo 'error: "unknown flag"'; exit 1 ;; esac
done
python3 - "$@" <<'PY'
import json, os, sys
args = sys.argv[1:]
def emit(lines):
    print("api_response:\n  body: " + json.dumps("\n".join(lines)) + "\n  truncated: false")
def load(name):
    return json.load(open(os.environ[name]))
path = next(a for a in args[1:] if a == "graphql" or a.startswith("/repos/"))
if path == "graphql":
    rules = load("FM_TEST_CLASSIC_DETAIL")["data"]["repository"]["branchProtectionRules"]
    emit(["more=" + str(rules["pageInfo"]["hasNextPage"]).lower()] +
         ["rule=%s\t%s" % (json.dumps(n["pattern"]), str(n["blocksCreations"]).lower()) for n in rules["nodes"]])
elif "/rulesets/" in path:
    detail = load("FM_TEST_RULESET_DETAIL")
    ref = (detail.get("conditions") or {}).get("ref_name") or {}
    emit(["ref_include=" + json.dumps(ref.get("include") or []), "ref_exclude=" + json.dumps(ref.get("exclude") or [])] +
         ["rule=" + json.dumps(r) for r in detail.get("rules") or [] if r.get("type") in ("branch_name_pattern", "creation")])
else:
    emit(["ruleset=71\tactive\tbranch"] if os.path.isfile(os.environ["FM_TEST_RULESET_DETAIL"]) else [])
PY
AXI
chmod +x "$tmp/fakebin/gh-axi"
export FM_TEST_RULESET_DETAIL="$tmp/ruleset-detail"
export FM_TEST_CLASSIC_DETAIL="$tmp/classic-detail"
printf '%s\n' '{"data":{"repository":{"branchProtectionRules":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}' > "$FM_TEST_CLASSIC_DETAIL"
git -C "$repo" remote add origin https://github.com/example/project.git
git -C "$repo" remote set-url origin ssh://git@github.com/example/project.git
[ -z "$(finder)" ] || fail 'declined ssh origin form was accepted'
git -C "$repo" remote set-url origin https://github.com/example/project.git
out=$(finder 2>&1)
[ -z "$out" ] || fail "empty GitHub rulesets and protection were not read as no rules: $out"
pass 'empty GitHub rulesets read as none, not unreadable'

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
[[ "$out" == *'ref_name include='* && "$out" != *'status='* && "$out" != *'operator=fnmatch'* ]] || fail "GitHub target was mistaken for a naming rule: $out"
[ "$(validate design/task-2 --operator fnmatch --pattern 'design/*')" = $'status=valid\ncheck=git+fnmatch' ] \
  || fail 'valid fnmatch name was rejected'
if validate bad..name > "$tmp/out"; then fail 'invalid Git ref was accepted'; fi
[ "$(validate design/task-2 --operator starts_with --pattern design/)" = $'status=valid\ncheck=git+starts_with' ] \
  || fail 'valid prefix name was rejected'
if validate feature/task-2 --operator starts_with --pattern design/ > "$tmp/out"; then fail 'wrong prefix was accepted'; fi
pass 'Git syntax, prefix and GitHub protection patterns are validated'

printf '%s\n' '{"data":{"repository":{"branchProtectionRules":{"nodes":[{"pattern":"release/*","blocksCreations":true},{"pattern":"main","blocksCreations":false}],"pageInfo":{"hasNextPage":false}}}}}' > "$FM_TEST_CLASSIC_DETAIL"
out=$(finder)
[[ "$out" == *'source=GitHub classic branch protection'* && "$out" == *'pattern=release/* blocksCreations=true'* && "$out" != *'status='* && "$out" != *'operator=fnmatch'* ]] \
  || fail "classic branch creation restriction was missed: $out"
printf '%s\n' '{"data":{"repository":{"branchProtectionRules":{"nodes":[{"pattern":"main","blocksCreations":false}],"pageInfo":{"hasNextPage":false}}}}}' > "$FM_TEST_CLASSIC_DETAIL"
out=$(finder)
[[ "$out" == *'pattern=main blocksCreations=false'* && "$out" != *'status='* ]] \
  || fail "classic review-only protection was mistaken for a naming rule: $out"
pass 'classic protection is read and creation restrictions are distinguished'

export FM_TEST_FAIL=1
out=$(finder 2>"$tmp/finder-error")
[[ "$out" == *'source=GitHub branch settings'* && "$out" == *'quote=branch settings could not be read'* && "$out" != *'status='* ]] || fail "unreadable GitHub settings lost evidence: $out"
if grep -q Traceback "$tmp/finder-error"; then fail 'unreadable settings crashed the finder'; fi
unset FM_TEST_FAIL
pass 'unreadable GitHub settings require a decision'

printf '%s\n' '# Projects' '- repo [no-mistakes branch=owner/] - fixture' > "$home/data/projects.md"
out=$(finder)
[[ "$out" == *'source=registered branch prefix'* && "$out" == *'quote=owner/'* ]] \
  || fail "recorded prefix was lost: $out"
printf '%s\n' '# Projects' '- repo [no-mistakes branch-rule="regex:^feature/[a-z0-9-]+$"] - fixture' > "$home/data/projects.md"
out=$(finder)
[[ "$out" == *'source=registered branch rule'* && "$out" == *'operator=regex'* && "$out" == *'pattern=^feature/[a-z0-9-]+$'* ]] \
  || fail "quoted machine rule was lost: $out"
mkdir -p "$tmp/no-python"
for tool in dirname awk git; do ln -s "$(command -v "$tool")" "$tmp/no-python/$tool"; done
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo") \
  || fail 'quoted machine rule required Python'
[[ "$out" == *'source=registered branch rule'* && "$out" == *'pattern=^feature/[a-z0-9-]+$'* ]] \
  || fail "Python-free quoted machine rule was lost: $out"
printf '%s\n' '# Projects' '- repo [no-mistakes] - fixture' > "$home/data/projects.md"
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo" 2>"$tmp/no-python-error") \
  || fail 'Python-free default failed'
[[ -z "$out" && "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --branch-prefix repo)" = fm/ ]] \
  || fail "Python-free default did not leave fm/ available: $out"
grep -q 'use fm/' "$tmp/no-python-error" || fail 'Python-free default did not warn'
printf '%s\n' '# Projects' '- repo [no-mistakes branch-rule="feature/workspace for root work; feature/[a-z] for packages"] - fixture' > "$home/data/projects.md"
out=$(FM_HOME="$home" PATH="$tmp/no-python" /bin/bash "$ROOT/bin/fm-branch-convention.sh" "$repo") \
  || fail 'quoted registered rule required Python'
[[ "$out" == *'quote=feature/workspace for root work; feature/[a-z] for packages'* ]] \
  || fail "quoted registered rule was truncated: $out"
pass 'registered prefixes and rules survive without Python'

gate() { FM_HOME="$home" PATH="$tmp/fakebin:$PATH" "$ROOT/bin/fm-branch-gate.sh" "$repo" "$@"; }
uiux='^(feature|fix)/[^/]+/[^/]+/[A-Z]+-[0-9]+-.+$'
printf '%s\n' '# Projects' '- repo [no-mistakes] - fixture' > "$home/data/projects.md"
rm -f "$FM_TEST_RULESET_DETAIL"
git -C "$repo" remote remove origin
out=$(gate fm/x) || fail "no-rule repo refused the fm/ default: $out"
[ "$(gate fm/x)" = status=ok ] || fail 'no-rule repo needs no pattern'
[ "$(gate feature/x)" = status=ok ] || fail 'no-rule explicit branch name was refused'
printf '%s\n' '# Projects' '- repo [no-mistakes branch=feature/] - fixture' > "$home/data/projects.md"
[ "$(gate fix/apps/adc/ADCCP-751-project-information-qa)" = status=ok ] || fail 'advisory prefix blocked an explicit branch without repository rules'
printf '%s\n' '# Projects' '- repo [no-mistakes] - fixture' > "$home/data/projects.md"
mkdir -p "$repo/docs"
cat > "$repo/docs/branching.md" <<'MD'
## Git workflow
feature/<pillar>/<package>/<TICKET-desc>   - package work
fix/apps/adc/ADCCP-751-project-information-qa
MD
if out=$(gate fm/x); then fail 'rules found without a pattern were accepted'; fi
[[ "$out" == *status=refused* && "$out" == *'no pattern is recorded'* ]] || fail "missing-pattern refusal unclear: $out"
if out=$(gate fm/x --pattern "$uiux"); then fail 'fm/ branch passed the derived pattern'; fi
[[ "$out" == *'does not satisfy the recorded pattern'* ]] || fail "pattern refusal unclear: $out"
for good in feature/apps/adc/ADCCP-1-x fix/apps/adc/ADCCP-1-x; do
  [ "$(gate "$good" --pattern "$uiux")" = status=ok ] || fail "$good was refused under the derived pattern"
done
if gate bad..name --pattern "$uiux" >/dev/null; then fail 'invalid git ref passed the gate'; fi
if gate fm/x --pattern '(' >/dev/null; then fail 'unusable pattern passed the gate'; fi
for declaration in 'branch=feature/' 'branch-rule="starts_with:feature/"' 'branch-rule="fnmatch:feature/*"'; do
  printf '%s\n' '# Projects' "- repo [no-mistakes $declaration] - fixture" > "$home/data/projects.md"
  if out=$(gate feature/x); then fail "$declaration bypassed repository passages without a derived pattern"; fi
  [[ "$out" == *status=refused* && "$out" == *'no pattern is recorded'* ]] || fail "missing-pattern refusal unclear for $declaration: $out"
  if out=$(gate feature/x --pattern "$uiux"); then fail "$declaration allowed a branch against the derived pattern"; fi
  [[ "$out" == *'does not satisfy the recorded pattern'* ]] || fail "pattern refusal unclear for $declaration: $out"
  [ "$(gate feature/apps/adc/ADCCP-1-x --pattern "$uiux")" = status=ok ] || fail "$declaration rejected a conforming branch"
  if [ "$declaration" = 'branch=feature/' ]; then
    [ "$(gate fix/apps/adc/ADCCP-751-project-information-qa --pattern "$uiux")" = status=ok ] || fail 'advisory prefix rejected a valid fix branch'
  elif gate fix/apps/adc/ADCCP-751-project-information-qa --pattern "$uiux" >/dev/null; then
    fail "$declaration did not enforce its explicit branch rule"
  fi
done
printf '%s\n' '# Projects' "- repo [no-mistakes branch-rule=\"regex:$uiux\"] - fixture" > "$home/data/projects.md"
[ "$(gate fix/apps/adc/ADCCP-1-x)" = status=ok ] || fail 'registered machine pattern was not accepted as the record'
if gate fm/x >/dev/null; then fail 'registered pattern did not reject fm/'; fi
printf '%s\n' '# Projects' '- repo [no-mistakes branch-rule="feature or fix by ticket"] - fixture' > "$home/data/projects.md"
if gate fm/x >/dev/null; then fail 'registered prose rule needed no pattern'; fi
[ "$(gate fix/apps/adc/ADCCP-1-x --pattern "$uiux")" = status=ok ] || fail 'prose rule plus pattern was refused'
pass 'gate enforces a recorded pattern wherever rules are found and leaves no-rule repos on fm/'

echo '# all fm-branch-convention tests passed'
