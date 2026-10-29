#!/usr/bin/env bash
# Hand the IU credentials to OpenCode v2's shared background service.
#
# Why: v2 attaches `oc` and `opencode run` to ONE per-user service (`opencode serve --service`)
# that is started without the pane's environment, so every `{env:IU_KEY}` / `{env:IU_OPENAI_BASE}`
# placeholder in config/opencode/opencode.json resolved to empty — "Route.model(openai-compatible-
# chat) requires an endpoint baseURL" on the first message (measured 2026-10-14, opencode 2.0.25).
# The service reads an `env` map from its own service.json, so the fix is to put the values there.
#
# Called by `_oc_env` (config/zsh/claude.zsh) after it exports IU_*, so it
# inherits them. Values travel by environment only — `opencode service set env K V` would put
# the key on argv (`ps auxww`). service.json lives in the local, unversioned ~/.config/opencode/
# (a real directory, mode 0600 file — NOT the symlinked dotfiles/config/opencode).
#
# Idempotent and quiet: rewrites + restarts the service only when a value changed (a rotation),
# and never restarts one that has live sessions (it warns and leaves the old env in place).
set -euo pipefail

file="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/service.json"
[[ -n "${IU_KEY:-}" && -n "${IU_OPENAI_BASE:-}" ]] || exit 0
[[ -f "$file" ]] || exit 0 # no service configured yet; first start creates it, next call fills it

names=(IU_KEY IU_OPENAI_BASE IU_ANTHROPIC_BASE)
# jq reads the values from its environment (`env.NAME`), never from argv.
filter='. as $c | reduce ($names[]) as $n ($c; if (env[$n] // "") != "" then .env[$n] = env[$n] else . end)'
next=$(jq --argjson names "$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)" "$filter" "$file")

if [[ "$next" == "$(jq . "$file")" ]]; then
  exit 0
fi

tmp=$(umask 077 && mktemp "$file.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$next" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$file"
trap - EXIT

active=$(opencode api GET /api/session/active 2>/dev/null | jq -r '(.data // {}) | length' 2>/dev/null || echo 0)
if [[ "$active" != "0" ]]; then
  echo "opencode-service-env: service.json updated but $active session(s) are running — restart the service when idle (opencode service restart)" >&2
  exit 0
fi
opencode service restart >/dev/null 2>&1 || opencode service start >/dev/null 2>&1 || true
