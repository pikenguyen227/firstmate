#!/usr/bin/env bash
# Live CLI drive of bin/fm-dispatch-resolve.sh (bash 3.2). A network sentinel
# curl on PATH records any outbound call and the exact body; no real request.
set -u
WT=${WT:?}; S=$(mktemp -d); H=$S/home; B=$S/bin; L=$S/log
mkdir -p $H/config $B $L
sed -n '/^cat > "\$BASE_RULES" <<.JSON.$/,/^JSON$/p' $WT/tests/fm-dispatch-resolve.test.sh | sed '1d;$d' > $H/config/crew-dispatch.json
cat > $B/curl <<'SH'
#!/usr/bin/env bash
out=''; while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2;; *) shift;; esac; done
cat > "$SENT_LOG/body"; echo CALLED >> "$SENT_LOG/calls"
printf '%s' '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_4","confidence":0.93,"probabilities":{"rule_1":0.01,"rule_2":0.01,"rule_3":0.02,"rule_4":0.93,"default":0.03}}},"usage":{"input_tokens":300,"output_tokens":40}}' > "$out"; printf 200
SH
cat > $B/quota-axi <<'SH'
#!/usr/bin/env bash
cat <<J
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.5}}]}}]}
J
SH
chmod +x $B/*; export SENT_LOG=$L
brief() {  # <task line>
  cat <<MD
# Current worker role contract
Your steering inbox is /Users/someone/fm-home/state/pager.inbox. Report to ops@build01.acme.corp.

# Task
## Captain's intent
Fix the off-by-one in the pager; root cause is the <= on line 40 of pager.sh.

## Firstmate spec
$1
Add a regression test; see https://github.com/o/pager/issues/4.

# Setup
You are in /Users/someone/.worktrees/pager; the build cache is at 10.1.2.3 and https://jenkins.acme.internal.

# Home brief additions
HOME-ADDITION: always use /Users/someone/fm-home/.env
MD
}
drive() {  # <label> <task line> [args]
  local label=$1 line=$2; shift 2; rm -f $L/*
  brief "$line" > $S/brief.md
  echo "=================================================================="
  echo "SCENARIO: $label"
  echo "Firstmate spec line: $line"
  echo "\$ TYPESAFE_API_KEY=*** fm-dispatch-resolve.sh brief.md $*"
  PATH="$B:$PATH" FM_HOME=$H TYPESAFE_API_KEY=dummy-key "$WT/bin/fm-dispatch-resolve.sh" $S/brief.md "$@" 2>&1
  echo "[exit $?]"
  if [ -e $L/calls ]; then
    echo "-> OUTBOUND REQUEST MADE. whole brief $(wc -c < $S/brief.md | tr -d ' ') bytes; sent state.task.brief $(jq -r .state.task.brief $L/body | wc -c | tr -d ' ') bytes"
    echo "-> sent state:"; jq .state $L/body
    for leak in /Users/someone 10.1.2.3 jenkins HOME-ADDITION steering build01 acme; do
      grep -q "$leak" $L/body && echo "   LEAK: $leak in body" || echo "   absent from body: $leak"
    done
  else
    echo "-> NO OUTBOUND REQUEST (curl never invoked)"
  fi
}
drive "clean task is sent as Task section only" "Keep the fix in pager.sh." --project pager
drive "internal company server hostname (motivating case)" "Reproduce against https://build01.acme-corp.com/pager first." --project pager
drive "bare internal host user@host" "ssh deploy@buildbox then restart the pager." --project pager
drive "internal .corp hostname" "Deploy to build01.acme.corp after tests." --project pager
drive "private IP" "The staging box is 192.168.40.7." --project pager
drive "password assignment" "Log in as admin, password: hunter22" --project pager
drive "spaced API key" "API key: 9f8e7d6c5b4a" --project pager
drive "provider token" "Use ghp_Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0LmNbV for the API." --project pager
drive "connection string" "Point it at postgres://app:pw@db/prod." --project pager
drive "internal host in project name" "Keep the fix in pager.sh." --project git.acme.internal
drive "version specifier is NOT a host (false-positive guard)" "Bump uses: actions/checkout@v4 and run npx snyk@latest test." --project pager
echo "=================================================================="
echo SCENARIO: no Task section
printf '# Charter\nOwn pager.\n# Setup\n10.1.2.3\n' > $S/b2.md; rm -f $L/*
PATH="$B:$PATH" FM_HOME=$H TYPESAFE_API_KEY=dummy-key "$WT/bin/fm-dispatch-resolve.sh" $S/b2.md --project pager 2>&1; echo "[exit $?]"
[ -e $L/calls ] && echo "-> OUTBOUND REQUEST MADE" || echo "-> NO OUTBOUND REQUEST (curl never invoked)"
rm -rf "$S"
