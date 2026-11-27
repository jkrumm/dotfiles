#!/usr/bin/env bash
# paper-link.test.sh: regression harness for scripts/paper-link.sh.
#
# Hermetic: HOME is a temp tree, the "remote" is a local repo with a paper-like Makefile. No network, no real checkout.
#
# Usage: scripts/paper-link.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/paper-link.sh"
pass=0
fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/paper-link-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# the stand-in remote: a paper-like repo whose install links bin/paper
REMOTE="$TMP/remote"
mkdir -p "$REMOTE/bin"
printf '#!/bin/sh\necho paper\n' >"$REMOTE/bin/paper"
chmod +x "$REMOTE/bin/paper"
printf 'install:\n\t@mkdir -p $(HOME)/.local/bin\n\t@ln -sf $(CURDIR)/bin/paper $(HOME)/.local/bin/paper\n' >"$REMOTE/Makefile"
git -C "$REMOTE" init -q -b master
git -C "$REMOTE" -c user.name=t -c user.email=t@example.com add -A
git -C "$REMOTE" -c user.name=t -c user.email=t@example.com commit -q -m init

run() { HOME="$H" PAPER_LINK_REMOTE="$REMOTE" "$SCRIPT"; }
fresh() { H="$TMP/home-$1"; rm -rf "$H"; mkdir -p "$H/.local/bin"; }

# 1. no checkout: cloned, linked; no backend marker means no config
fresh a
out="$(run)"; rc=$?
assert_eq "clone and link exits 0" "0" "$rc"
assert_eq "paper is linked into the checkout" "$H/SourceRoot/paper/bin/paper" "$(readlink "$H/.local/bin/paper")"
assert_eq "no backend marker writes no config" "no" "$([[ -e "$H/.config/paper/config.json" ]] && echo yes || echo no)"

# 2. an existing checkout is fast-forwarded to the remote
git -C "$REMOTE" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m next
out="$(run)"; rc=$?
assert_eq "re-run exits 0" "0" "$rc"
assert_eq "checkout follows the remote" "$(git -C "$REMOTE" rev-parse HEAD)" "$(git -C "$H/SourceRoot/paper" rev-parse HEAD)"

# 3. MacBook (backend op): config written once, an existing one untouched
fresh b
mkdir -p "$H/.config/secrets"
echo op >"$H/.config/secrets/backend"
out="$(run)"
assert_contains "MacBook gets host mini" '"host": "mini"' "$(cat "$H/.config/paper/config.json")"
echo '{"host":"other"}' >"$H/.config/paper/config.json"
out="$(run)"
assert_eq "an existing config is left alone" '{"host":"other"}' "$(cat "$H/.config/paper/config.json")"

# 4. the mini (backend cache) writes no config
fresh c
mkdir -p "$H/.config/secrets"
echo cache >"$H/.config/secrets/backend"
out="$(run)"
assert_eq "the mini writes no config" "no" "$([[ -e "$H/.config/paper/config.json" ]] && echo yes || echo no)"

# 5. the old print wrapper goes, an unrelated print stays
fresh d
ln -s "$H/SourceRoot/dotfiles/scripts/print.sh" "$H/.local/bin/print"
out="$(run)"
assert_eq "the dead print link is removed" "no" "$([[ -L "$H/.local/bin/print" ]] && echo yes || echo no)"
assert_contains "the removal is announced" "removed the old" "$out"
fresh e
ln -s /usr/bin/true "$H/.local/bin/print"
out="$(run)"
assert_eq "an unrelated print link stays" "/usr/bin/true" "$(readlink "$H/.local/bin/print")"

# 6. no checkout and a remote that fails: one FAIL line, exit 1
fresh f
out="$(HOME="$H" PAPER_LINK_REMOTE="$TMP/missing" "$SCRIPT")"; rc=$?
assert_eq "a failed clone exits 1" "1" "$rc"
assert_contains "a failed clone says FAIL" "FAIL" "$out"

echo
echo "paper-link.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
