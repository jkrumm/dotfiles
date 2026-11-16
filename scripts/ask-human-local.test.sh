#!/usr/bin/env bash
# ask-human-local.test.sh — the MacBook defaults of the `ask-human` entry point (scripts/ask-human-local.sh).
# Hermetic: a stub ask-human.sh next to a copy of the wrapper prints the environment and argv it received.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ask-human-local-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/s" "$TMP/cfg/secrets"
cp "$HERE/ask-human-local.sh" "$TMP/s/ask-human-local.sh"
cat >"$TMP/s/ask-human.sh" <<'STUB'
#!/bin/bash
printf 'host=%s errands=%s' "${HUMAN_QUEUE_MAC_HOST-unset}" "${HUMAN_QUEUE_ERRANDS-unset}"
for a in "$@"; do printf '|%s' "$a"; done
printf '\n'
STUB

W() { local b="$1"; shift; printf '%s\n' "$b" >"$TMP/cfg/secrets/backend"; XDG_CONFIG_HOME="$TMP/cfg" bash "$TMP/s/ask-human-local.sh" "$@" 2>&1; }

assert_eq "mini: untouched" "host=unset errands=unset|ask|do it|--cmd|x y" "$(W cache ask "do it" --cmd "x y")"
assert_eq "macbook: local dialog, no factory, text prefixed" \
  "host=local errands=0|ask|(asked by an agent on this MacBook) do it|--cmd|x y|--key|k" "$(W op ask "do it" --cmd "x y" --key k)"
assert_eq "macbook: other verbs pass through" "host=local errands=0|push|2026-1" "$(W op push 2026-1)"
assert_eq "macbook: ask with only flags is not prefixed" "host=local errands=0|ask|--wait|5" "$(W op ask --wait 5)"
printf 'op\n' >"$TMP/cfg/secrets/backend"
assert_eq "an explicit setting wins" "host=iumac errands=1|list" \
  "$(HUMAN_QUEUE_MAC_HOST=iumac HUMAN_QUEUE_ERRANDS=1 XDG_CONFIG_HOME="$TMP/cfg" bash "$TMP/s/ask-human-local.sh" list)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
