#!/usr/bin/env bash
set -euo pipefail

# herdr-skill-sync — regenerate skills/herdr/SKILL.md from `herdr --skill`.
#
# WHY GENERATED, NOT HAND-WRITTEN. herdr 0.8.2 (#2847) bundles an agent skill in
# the binary and keeps it matched to that release's CLI and lifecycle behaviour.
# A hand-written copy is a second source of truth that goes stale silently on
# every `brew upgrade herdr` — and stale CLI syntax is worse than none, because
# an agent follows it confidently. So the binary stays authoritative and this
# only transcribes it.
#
# WHY TRACKED ANYWAY, rather than generated into ~/.claude at setup time: the
# git diff IS the review. An upgrade that changes what agents are told to do on
# this machine should show up as a reviewable diff, same argument as the
# Brewfile being the supply-chain audit trail.
#
# Called by `make herdr-setup`, which is the target that already runs on every
# `make setup` and after every herdr upgrade — so the skill tracks the binary
# with no separate step to remember.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${HERDR_SKILL_OUT:-$DOTFILES_DIR/skills/herdr/SKILL.md}"
MIN_BYTES="${HERDR_SKILL_MIN_BYTES:-2000}"

if ! command -v herdr >/dev/null 2>&1; then
  echo "    · herdr not installed — skill left as-is"
  exit 0
fi

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

if ! herdr --skill >"$tmp" 2>/dev/null; then
  echo "  ✗ 'herdr --skill' failed — keeping the tracked SKILL.md"
  echo "    (herdr $(herdr --version 2>&1 | awk '{print $2}') may predate #2847)"
  exit 1
fi

# Refuse to emit a degraded skill. A truncated or frontmatter-less file does not
# error at load time — it just quietly stops triggering, or triggers with half
# the contract. Same restraint as caddy-registry refusing an empty app list.
bytes=$(wc -c <"$tmp" | tr -d ' ')
if [ "$bytes" -lt "$MIN_BYTES" ]; then
  echo "  ✗ 'herdr --skill' returned only ${bytes}B (< ${MIN_BYTES}) — keeping the tracked SKILL.md"
  exit 1
fi
if [ "$(head -1 "$tmp")" != "---" ] || ! grep -q '^name: herdr$' "$tmp"; then
  echo "  ✗ 'herdr --skill' output is not a herdr SKILL.md — keeping the tracked SKILL.md"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  echo "    ✓ herdr skill current ($(herdr --version 2>&1 | awk '{print $2}'), ${bytes}B)"
  exit 0
fi

cat "$tmp" >"$OUT"
echo "    ✓ herdr skill regenerated from $(herdr --version 2>&1 | awk '{print $2}') (${bytes}B) — review the diff"
