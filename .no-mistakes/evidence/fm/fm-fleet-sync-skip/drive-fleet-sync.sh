#!/usr/bin/env bash
# Live driver: build a lab FM_HOME reproducing evidence 1e and run fm-fleet-sync.sh
# and fm-bootstrap.sh from <root>. Usage: drive-fleet-sync.sh <fm-root> <label>
set -u
ROOT=$1; LABEL=$2
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || bash /Users/pike/.no-mistakes/worktrees/81f2a0639ef5/01M4FJKFXPQPM2M889KTB8D51T/bin/fm-lab-home.sh create "$LAB" >/dev/null
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-work.XXXXXX")
# slow upload-pack: mimics copilot-studio's 23s fetch
cat > "$W/slow-upload-pack" <<'S'
#!/bin/sh
sleep 23
exec git-upload-pack "$@"
S
chmod +x "$W/slow-upload-pack"
mk() { # name
  git init -q "$W/$1"; git -C "$W/$1" symbolic-ref HEAD refs/heads/main
  echo v0 > "$W/$1/f"; git -C "$W/$1" add f; git -C "$W/$1" commit -qm C0
  git clone -q --bare "$W/$1" "$W/$1.git"
  git clone -q "file://$W/$1.git" "$LAB/projects/$1"
  echo v1 > "$W/$1/f"; git -C "$W/$1" commit -qam C1; git -C "$W/$1" push -q "file://$W/$1.git" main
}
for p in alpha beta gamma copilot-studio jira-etl; do mk $p; done
for p in copilot-studio jira-etl; do
  c="$LAB/projects/$p"
  git -C "$c" checkout -q --detach; git -C "$c" update-ref -d refs/heads/main
  git -C "$c" symbolic-ref HEAD refs/heads/main; rm -f "$c/.git/index" "$c/f"
  git -C "$c" config remote.origin.uploadpack "$W/slow-upload-pack"
done
echo "== [$LABEL] lab layout"; for p in "$LAB"/projects/*; do printf '%s: HEAD->%s local-main=%s worktree-files=%s\n' "$(basename $p)" "$(git -C $p symbolic-ref HEAD)" "$(git -C $p rev-parse -q --verify refs/heads/main >/dev/null && echo yes || echo no)" "$(ls $p | wc -l | tr -d ' ')"; done
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
echo "== [$LABEL] fm-fleet-sync.sh run 1 (timed)"; s=$SECONDS; run "$ROOT/bin/fm-fleet-sync.sh" 2>&1; echo "elapsed=$((SECONDS-s))s"
echo "== [$LABEL] fm-fleet-sync.sh run 2 (timed)"; s=$SECONDS; run "$ROOT/bin/fm-fleet-sync.sh" 2>&1; echo "elapsed=$((SECONDS-s))s"
echo "== [$LABEL] per-clone state after sync"; for p in alpha beta gamma; do echo "$p main=$(git -C $LAB/projects/$p log -1 --format=%s main)"; done
echo "== [$LABEL] marker dir"; ls "$LAB/state/fleet-sync-needs-setup" 2>&1
# reset clones behind for bootstrap phase, fresh marker state
for p in alpha beta gamma; do git -C "$LAB/projects/$p" reset -q --hard HEAD~1; done
rm -rf "$LAB/state/fleet-sync-needs-setup"
echo "== [$LABEL] fm-bootstrap.sh session start 1 (FLEET_SYNC lines; timeout=5+3*5=20s)"; s=$SECONDS; run "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep FLEET_SYNC; echo "elapsed=$((SECONDS-s))s"
for p in alpha beta gamma; do echo "$p main=$(git -C $LAB/projects/$p log -1 --format=%s main)"; done
echo "== [$LABEL] fm-bootstrap.sh session start 2 (FLEET_SYNC lines)"; run "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep FLEET_SYNC || echo "(no FLEET_SYNC lines)"
echo "== [$LABEL] adversarial: check out copilot-studio, then relapse"
c="$LAB/projects/copilot-studio"; git -C "$c" config --unset remote.origin.uploadpack; git -C "$c" checkout -q -B main origin/main
run "$ROOT/bin/fm-fleet-sync.sh" copilot-studio 2>&1
git -C "$c" checkout -q --detach; git -C "$c" update-ref -d refs/heads/main; git -C "$c" symbolic-ref HEAD refs/heads/main; rm -f "$c/.git/index" "$c/f"
run "$ROOT/bin/fm-fleet-sync.sh" copilot-studio 2>&1
echo "== [$LABEL] adversarial: detached HEAD with no local main is NOT treated as needs-setup"
d="$LAB/projects/alpha"; git -C "$d" checkout -q --detach; git -C "$d" branch -q -D main
run "$ROOT/bin/fm-fleet-sync.sh" alpha 2>&1
rm -rf "$LAB" "$W"
echo "== [$LABEL] lab removed"
