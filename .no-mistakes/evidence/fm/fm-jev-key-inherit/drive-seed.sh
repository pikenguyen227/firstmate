#!/usr/bin/env bash
# Live driver: seed a new secondmate from a disposable lab primary using code root $1, report outcome.
set -u
SRC=$1; REV=$2; LABEL=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MATES=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mates.XXXXXX")
trap 'rm -rf "$LAB" "$MATES"' EXIT
CODE="$MATES/primary-code"; git clone -q --no-checkout "$SRC" "$CODE" && git -C "$CODE" checkout -q -B main "$REV" || exit 1
echo "code root at main=$(git -C "$CODE" rev-parse --short HEAD)"
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
FAKE='fm-lab-fake-not-a-real-key-0001'
printf 'OTHER_PRIMARY_SECRET=do-not-copy\nTYPESAFE_API_KEY=%s\n' "$FAKE" > "$LAB/.env"; chmod 600 "$LAB/.env"
MATE="$MATES/sm-new"
run() { env -u TYPESAFE_API_KEY -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
echo "== [$LABEL] primary dispatch-resolve (control)"
run bash "$CODE/bin/fm-dispatch-resolve.sh" /dev/null 2>&1 | sed -e "s#$LAB#\$LAB#g" -e "s#$MATES#\$MATES#g"
echo "== [$LABEL] fm-home-seed.sh sm-new <new home> --no-projects"
out=$(FM_SECONDMATE_CHARTER='lab jev fixture' run bash "$CODE/bin/fm-home-seed.sh" sm-new "$MATE" --no-projects 2>&1); rc=$?
printf '%s\n' "$out" | sed -e "s#$LAB#\$LAB#g" -e "s#$MATES#\$MATES#g" | tail -8
echo "seed exit=$rc"
printf '%s' "$out" | grep -q "$FAKE" && echo "LEAK: key value in seed output" || echo "no key value in seed output"
echo "== [$LABEL] new mate .env"
if [ -e "$MATE/.env" ]; then
  echo "mode=$(stat -f %Lp "$MATE/.env") links=$(stat -f %l "$MATE/.env")"
  grep -c "^TYPESAFE_API_KEY=$FAKE\$" "$MATE/.env" | sed 's/^/key lines matching primary: /'
  grep -q OTHER_PRIMARY_SECRET "$MATE/.env" && echo "other primary line copied (BAD)" || echo "other primary lines not copied"
  git -C "$MATE" check-ignore -q .env && echo ".env gitignored in mate" || echo ".env NOT ignored"
  echo "untracked/staging leftovers: $(git -C "$MATE" status --porcelain --ignored | grep -E 'inherit' || echo none)"
else echo "no .env in new mate home"; fi
echo "== [$LABEL] mate dispatch-resolve (run with FM_HOME=mate)"
env -u TYPESAFE_API_KEY FM_HOME="$MATE" bash "$MATE/bin/fm-dispatch-resolve.sh" /dev/null 2>&1 | sed -e "s#$LAB#\$LAB#g" -e "s#$MATES#\$MATES#g"
