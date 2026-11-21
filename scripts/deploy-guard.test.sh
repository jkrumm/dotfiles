#!/usr/bin/env bash
# deploy-guard.test.sh — regression harness for scripts/deploy-guard.sh.
#
# Hermetic: a scratch repo with one linked worktree, no signing, make never run.
# Proves: the main checkout passes; a linked worktree is refused with exit 1 and
# the refusal names the main checkout's `make -C` line (for the goal given); the
# Makefile's deploy recipe runs the guard before setup; a worktree's `make setup`
# and `make <x>-setup` refuse at parse time (no recipe runs), `make help` does not.
#
# Usage: scripts/deploy-guard.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/deploy-guard.sh"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }

[[ -x "$GUARD" ]] || { echo "✗ $GUARD not found/executable"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-guard-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/dotfiles"
WT="$TMP/dotfiles-wt"
git init -q "$MAIN" || exit 2
git -C "$MAIN" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init || exit 2
git -C "$MAIN" worktree add -q -b deploy-guard-under-test "$WT" || exit 2

out="$(bash "$GUARD" "$MAIN" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "main checkout passes"; else bad "main checkout passes" "rc=$rc $out"; fi

out="$(bash "$GUARD" "$WT" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "linked worktree is refused (exit 1)"; else bad "linked worktree is refused (exit 1)" "rc=$rc $out"; fi
case "$out" in
  *"make -C $MAIN deploy"*) ok "refusal names the main checkout" ;;
  *) bad "refusal names the main checkout" "$out" ;;
esac

out="$(bash "$GUARD" "$WT" setup 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"make -C $MAIN setup"* && "$out" == *"make setup refuses"* ]]; then
  ok "goal argument names setup in the refusal"
else
  bad "goal argument names setup in the refusal" "rc=$rc $out"
fi

# Wiring: the deploy recipe runs the guard before setup. Read from the Makefile, never run
# (a missing guard would run setup against the real $HOME).
MAKEFILE="$HERE/../Makefile"
deploy_recipe="$(awk '/^deploy:/{f=1} f&&/^$/{exit} f' "$MAKEFILE")"
case "$(printf '%s\n' "$deploy_recipe" | sed -n '2p')" in
  *"scripts/deploy-guard.sh"*) ok "deploy runs the guard before setup" ;;
  *) bad "deploy runs the guard before setup" "first recipe line: $(printf '%s\n' "$deploy_recipe" | sed -n '2p')" ;;
esac

# Wiring: setup and every *-setup refuse from the worktree at parse time. The worktree gets a
# copy of the Makefile and the guard; `make -n` keeps any recipe that slipped past the guard from
# running (a broken guard would otherwise run setup against the real $HOME). HOME is scratch too.
mkdir -p "$WT/scripts" && cp "$MAKEFILE" "$WT/Makefile" && cp "$GUARD" "$WT/scripts/deploy-guard.sh" || exit 2
for goal in setup batt-setup _link; do
  out="$(HOME="$TMP/home" make -C "$WT" -n "$goal" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"make $goal refused"* && "$out" != *"Setting up dotfiles"* ]]; then
    ok "make $goal refuses in a linked worktree"
  else
    bad "make $goal refuses in a linked worktree" "rc=$rc $out"
  fi
done
out="$(HOME="$TMP/home" make -C "$WT" -n help 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "make help still runs in a linked worktree"; else bad "make help still runs in a linked worktree" "rc=$rc $out"; fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
