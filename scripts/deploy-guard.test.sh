#!/usr/bin/env bash
# deploy-guard.test.sh — regression harness for scripts/deploy-guard.sh.
#
# Hermetic: a scratch repo with one linked worktree, no signing, make never run.
# Proves: the main checkout passes; a linked worktree is refused with exit 1 and
# the refusal names the main checkout's `make -C` line; the Makefile's deploy
# recipe runs the guard before setup.
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

# Wiring: the deploy recipe runs the guard before setup. Read from the Makefile, never run
# (a missing guard would run setup against the real $HOME).
MAKEFILE="$HERE/../Makefile"
deploy_recipe="$(awk '/^deploy:/{f=1} f&&/^$/{exit} f' "$MAKEFILE")"
case "$(printf '%s\n' "$deploy_recipe" | sed -n '2p')" in
  *"scripts/deploy-guard.sh"*) ok "deploy runs the guard before setup" ;;
  *) bad "deploy runs the guard before setup" "first recipe line: $(printf '%s\n' "$deploy_recipe" | sed -n '2p')" ;;
esac

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
