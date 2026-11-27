#!/usr/bin/env bash
# print: the Tinycast print CLI on PATH (rules/clis.md, skill print). Runs the bundled
# extension/assets/print-cli.js when the checkout has one (make print-cli), else
# extension/scripts/print.ts from source (no dependencies). Every call prints one JSON line.
# zsh's builtin `print` shadows this name in zsh: agents type `command print`.
set -u

fail() {
  printf '{"ok":false,"message":"%s"}\n' "$1"
  exit 1
}

EXT="$HOME/SourceRoot/tinycast-extensions/extension"
if [[ -f "$EXT/assets/print-cli.js" ]]; then
  ENTRY="$EXT/assets/print-cli.js"
elif [[ -f "$EXT/scripts/print.ts" ]]; then
  ENTRY="$EXT/scripts/print.ts"
else
  fail "no tinycast-extensions checkout under ~/SourceRoot: the print CLI is not here"
fi

BUN="$(command -v bun 2>/dev/null || true)"
[[ -n "$BUN" ]] || BUN="$HOME/.bun/bin/bun"
[[ -x "$BUN" ]] || fail "bun is not installed (brew bundle installs it)"

exec "$BUN" "$ENTRY" "$@"
