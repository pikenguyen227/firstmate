#!/usr/bin/env bash
# Live driver: existing mate homes converge via fm-config-push.sh; guards and absence behavior.
set -u
SRC=$1; REV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); MATES=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mates.XXXXXX")
trap 'rm -rf "$LAB" "$MATES"' EXIT
CODE="$MATES/primary-code"; git clone -q --no-checkout "$SRC" "$CODE" 2>/dev/null && git -C "$CODE" checkout -q -B main "$REV" || exit 1
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
K1=fm-lab-fake-key-one-0001; K2=fm-lab-fake-key-two-0002
san() { sed -e "s#/private$LAB#\$LAB#g" -e "s#$LAB#\$LAB#g" -e "s#/private$MATES#\$MATES#g" -e "s#$MATES#\$MATES#g"; }
leak() { grep -qE "$K1|$K2" && echo "LEAK: key value in output" || echo "(no key value in output)"; }
run() { env -u TYPESAFE_API_KEY -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
seed() { out=$(FM_SECONDMATE_CHARTER="lab fixture $1" run bash "$CODE/bin/fm-home-seed.sh" "$1" "$MATES/$1" --no-projects 2>&1); rc=$?; printf '%s\n' "$out" | grep -E 'SECONDMATE_SYNC|^home=|error' | san; echo "seed $1 exit=$rc"; printf '%s' "$out" | leak; }
showkey() { local f="$MATES/$1/.env"; if [ -f "$f" ]; then printf '%s: mode=%s key=%s lines=%s\n' "$1" "$(stat -f %Lp "$f")" "$(grep '^TYPESAFE_API_KEY=' "$f" | sed -e "s/$K1/<K1>/" -e "s/$K2/<K2>/")" "$(sed -e "s/$K1/<K1>/" -e "s/$K2/<K2>/" "$f" | tr '\n' '|')"; else echo "$1: no .env"; fi; }
meta() { printf 'kind=secondmate\nhome=%s\nwindow=lab:%s\n' "$MATES/$1" "$1" > "$LAB/state/$1.meta"; }
push() { out=$(run bash "$CODE/bin/fm-config-push.sh" 2>&1); rc=$?; printf '%s\n' "$out" | grep -E 'secondmate|TYPESAFE|SECONDMATE_SYNC' | san; echo "config-push exit=$rc"; printf '%s' "$out" | leak; }

echo "### A. primary has NO key: seed sm-old (absence warns, seed succeeds)"
seed sm-old; showkey sm-old
echo "### B. mate adds its own local line; primary now has K1; seed sm-new"
printf 'MATE_LOCAL=keep\n' > "$MATES/sm-old/.env"
printf 'PRIMARY_OTHER=no-copy\nTYPESAFE_API_KEY=%s\n' "$K1" > "$LAB/.env"; chmod 600 "$LAB/.env"
seed sm-new; showkey sm-new
echo "### C. config push covers every live home (sm-old existing, sm-new)"
meta sm-old; meta sm-new; push; showkey sm-old; showkey sm-new
echo "### D. rotate primary key to K2, config push again"
printf 'TYPESAFE_API_KEY=%s\n' "$K2" > "$LAB/.env"; push; showkey sm-old; showkey sm-new
echo "### E. primary key removed: config push preserves mates' K2 and warns"
printf 'PRIMARY_OTHER=no-copy\n' > "$LAB/.env"; push; showkey sm-old; showkey sm-new
echo "### F. adversarial: sm-new .env hardlinked to an outside file; sm-old .env tracked (not ignored)"
printf 'TYPESAFE_API_KEY=%s\n' "$K1" > "$LAB/.env"
printf 'VICTIM=keep\n' > "$MATES/victim"; rm -f "$MATES/sm-new/.env"; ln "$MATES/victim" "$MATES/sm-new/.env"
git -C "$MATES/sm-old" add -f .env
push; showkey sm-old; echo "victim file: $(cat "$MATES/victim")"
echo "### G. leftover staging/credential files in mate working trees"
for m in sm-old sm-new; do echo "$m: $(git -C "$MATES/$m" status --porcelain --untracked-files=all | grep -v '^A  .env$' | tr '\n' ' ')$(ls -a "$MATES/$m" "$MATES/$m/config" | grep -E 'inherit' | tr '\n' ' ')"; done
