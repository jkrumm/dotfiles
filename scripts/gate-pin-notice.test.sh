#!/usr/bin/env bash
# gate-pin-notice.test.sh — regression harness for scripts/gate-pin-notice.sh.
#
# Hermetic: a scratch git repo stands in for dotfiles, a scratch config.json for
# the installed gate's, a scratch queue for ask-human.sh (never pushes, never
# ssh). Proves: a change to a pinned file enqueues exactly one item, a second
# change replaces it, an unrelated change enqueues nothing, a re-pin clears it,
# an unchanged drift is not re-announced, and the fallback list matches the live
# gate config when one is installed.
#
# Usage: scripts/gate-pin-notice.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTICE="$HERE/gate-pin-notice.sh"
AH="$HERE/ask-human.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

[[ -x "$NOTICE" ]] || { echo "✗ $NOTICE not found/executable"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-pin-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/config/secrets"
printf 'op' > "$TMP/config/secrets/backend"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export HUMAN_QUEUE_PUSH=0
unset FACTORY_SESSION

REPO="$TMP/dotfiles"
export DOTFILES_DIR="$REPO"
export GATE_PIN_CONFIG="$TMP/gate-config.json"
export GATE_PIN_STATE="$TMP/gate-pin-seen"
export ASK_HUMAN="$AH"

mkdir -p "$REPO/scripts/lib"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
printf 'ask v1\n' > "$REPO/scripts/ask-human.sh"
printf 'json v1\n' > "$REPO/scripts/lib/human-queue-json.sh"
printf 'unrelated v1\n' > "$REPO/scripts/other.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
write_pins() {
  printf '{"ask_human_pins":{"%s":"%s","%s":"%s"}}\n' \
    "$REPO/scripts/ask-human.sh" "$(sha "$REPO/scripts/ask-human.sh")" \
    "$REPO/scripts/lib/human-queue-json.sh" "$(sha "$REPO/scripts/lib/human-queue-json.sh")" > "$GATE_PIN_CONFIG"
}
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"; }
pending() { "$AH" list --json | grep -o '"key":"gate-pin"' | wc -l | tr -d ' '; }
pending_text() { "$AH" list --json; }

echo "gate-pin-notice"
write_pins

"$NOTICE" >/dev/null
assert_eq "pins match -> no item" 0 "$(pending)"

printf 'unrelated v2\n' > "$REPO/scripts/other.sh"; commit unrelated
"$NOTICE" >/dev/null
assert_eq "unrelated change -> no item" 0 "$(pending)"

printf 'ask v2\n' > "$REPO/scripts/ask-human.sh"; commit "ask v2"
"$NOTICE" >/dev/null
assert_eq "pinned file changed -> one item" 1 "$(pending)"
txt="$(pending_text)"
assert_contains "item names the file" "scripts/ask-human.sh" "$txt"
assert_contains "item carries the diff range from the pin commit" "$BASE..$(git -C "$REPO" rev-parse HEAD)" "$txt"
assert_contains "item carries the re-pin command" "make deploy-gate-install" "$txt"

"$NOTICE" >/dev/null
assert_eq "same drift again -> still one item, no re-announce" 1 "$(pending)"
first_id="$("$AH" list --json | grep -o '"id":"[^"]*"' | head -n1)"

printf 'json v2\n' > "$REPO/scripts/lib/human-queue-json.sh"; commit "json v2"
"$NOTICE" >/dev/null
assert_eq "second pinned change -> still exactly one item" 1 "$(pending)"
assert_contains "replacement lists the newer file" "human-queue-json.sh" "$(pending_text)"
second_id="$("$AH" list --json | grep -o '"id":"[^"]*"' | head -n1)"
[[ "$first_id" != "$second_id" ]] && ok "second change replaced the first item" || bad "second change replaced the first item" "$first_id"

write_pins
"$NOTICE" >/dev/null
assert_eq "owner re-pinned -> item cleared" 0 "$(pending)"

# Fallback: config unreadable, change detected against the previous run.
rm -f "$GATE_PIN_CONFIG" "$GATE_PIN_STATE" "$GATE_PIN_STATE.notified"
mkdir -p "$REPO/scripts/lib"
for f in human-queue.sh human-queue-notify-hook.sh; do printf '%s v1\n' "$f" > "$REPO/scripts/$f"; done
commit fallback-files
"$NOTICE" >/dev/null
assert_eq "fallback first run baselines silently" 0 "$(pending)"
printf 'other v3\n' > "$REPO/scripts/other.sh"; commit unrelated2
"$NOTICE" >/dev/null
assert_eq "fallback: unrelated change -> no item" 0 "$(pending)"
printf 'queue v2\n' > "$REPO/scripts/human-queue.sh"; commit "queue v2"
"$NOTICE" >/dev/null
assert_eq "fallback: pinned change -> one item" 1 "$(pending)"

# The fallback list must cover the live gate's pins (skipped where no gate is installed).
LIVE="$HOME/.local/libexec/prometheus-deploy-gate/config.json"
if [[ -r "$LIVE" ]] && command -v python3 >/dev/null 2>&1; then
  missing=""
  while read -r p; do
    rel="${p#*/dotfiles/}"
    [[ "$rel" != "$p" ]] || continue
    grep -qF "  $rel" "$NOTICE" || missing+=" $rel"
  done < <(python3 -I -c 'import json,sys; print("\n".join((json.load(open(sys.argv[1])).get("ask_human_pins") or {})))' "$LIVE")
  assert_eq "fallback list covers the live gate's pins" "" "$missing"
else
  ok "live gate config not installed here — fallback comparison skipped"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
