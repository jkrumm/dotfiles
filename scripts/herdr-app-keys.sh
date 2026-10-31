#!/usr/bin/env bash
# Bind our keys in the Herdr app's keys.json (the app's own file, not tracked): one binding per row of
# BINDINGS, merged with jq so every other key stays as the owner left it.
#
#   herdr-app-keys.sh [APP_HOME]     APP_HOME defaults to $HERDR_APP_HOME, else ~/.config/herdr-app
#
# A row is `<key> <action>`, written into `.global`. A key that is unbound, or already ours, is set; a key
# bound to something else is reported and left alone (the owner's binding wins). Called by
# scripts/herdr-app-setup.sh; safe to run by hand, idempotent. Needs jq.
set -euo pipefail

# jk-keys.brain-note: scripts/brain-note.sh as a peek (config/herdr-app/mods/jk-keys), the classic prefix+e.
BINDINGS=(
  "cmd-e jk-keys.brain-note"
)

HOME_DIR="${1:-${HERDR_APP_HOME:-$HOME/.config/herdr-app}}"
KEYS="$HOME_DIR/keys.json"
say() { echo "  $*"; }

# The app writes keys.json on its first start; without it there is nothing to merge into.
[ -f "$KEYS" ] || { say "· $KEYS not there yet (open Herdr once), keys not bound"; exit 0; }
jq -e 'type == "object"' "$KEYS" >/dev/null 2>&1 || { echo "✗ $KEYS is not a JSON object, left alone" >&2; exit 1; }

for row in "${BINDINGS[@]}"; do
  key="${row%% *}" action="${row#* }"
  cur="$(jq -r --arg k "$key" '.global[$k] // ""' "$KEYS")"
  if [ "$cur" = "$action" ]; then say "· key $key (ok)"
  elif [ -z "$cur" ]; then
    jq --arg k "$key" --arg a "$action" '.global = ((.global // {}) + {($k): $a})' "$KEYS" > "$KEYS.tmp" \
      && mv "$KEYS.tmp" "$KEYS" && say "✓ key $key → $action"
  else say "- $key is taken ($cur), $action not bound"; fi
done
