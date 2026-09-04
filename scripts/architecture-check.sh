#!/bin/bash
# architecture-check — every launchd label loaded on THIS machine must appear
# in docs/architecture.md, or this exits 1. The subtraction pass's enforcement
# half: the map says what runs, this proves nothing runs un-mapped.
#
# Read-only. Runs on both machines via `make doctor`; the map covers both.
#
# What it checks:
#   1. Every label in `launchctl list` (this user's gui domain) that is NOT an
#      Apple label, a running-app label (`application.*`, `application.com.*`),
#      or a known third-party allowlist entry must appear in the map.
#   2. Every plist in ~/Library/LaunchAgents named com.jkrumm.* / com.iu.* /
#      ai.hermes.* / herdr.* / homebrew.mxcl.* must appear in the map — a plist
#      on disk that launchd has not loaded is exactly the silent state the map
#      exists to prevent.
#
# Exit 1 lists the unmapped labels. Adding a legit new agent = add a row to the
# map in the same change; that friction IS the point.

set -u

DOTFILES="${DOTFILES_DIR:-$HOME/SourceRoot/dotfiles}"
MAP="$DOTFILES/docs/architecture.md"
LAUNCHCTL=/bin/launchctl

[[ -f "$MAP" ]] || { echo "✗ $MAP not found"; exit 1; }

# Labels that are not ours to map. application.* are GUI apps launched by
# LaunchServices (1Password, Obsidian…); the rest are vendor updaters that
# ship their own plists and are not managed by any repo here.
allowlist_regex='^(com\.apple\.|application\.|com\.google\.GoogleUpdater|com\.jetbrains\.toolbox|com\.riot\.riotclient|com\.microsoft\.|org\.pqrs\.|com\.amazonaws\.|com\.logi\.|com\.macromates\.|us\.zoom\.|2BUA8C4S2C\.|com\.openssh\.ssh-agent)'

# The MacBook is MDM-managed: Jamf, Okta, Adobe and the cancom hardening daemons
# ship dozens of plists nobody here owns, so on the `op` backend only the prefixes
# this repo manages are asserted. The mini is entirely ours — full scan there.
BACKEND=$(tr -d '[:space:]' < "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null || echo "")
if [[ "$BACKEND" == "op" ]]; then
  owned_regex='^(com\.jkrumm\.|homebrew\.mxcl\.|cc\.chlc\.)'
else
  owned_regex='.'
fi

unmapped=""

# 1. loaded labels (gui domain)
while IFS= read -r label; do
  [[ -n "$label" && "$label" != "Label" ]] || continue
  [[ "$label" =~ $allowlist_regex ]] && continue
  [[ "$label" =~ $owned_regex ]] || continue
  if ! grep -q "$label" "$MAP"; then
    unmapped="${unmapped}  loaded-but-unmapped: $label
"
  fi
done < <($LAUNCHCTL list 2>/dev/null | /usr/bin/awk 'NR>1 {print $3}')

# 2. plists on disk, un-loaded or not
for dir in "$HOME/Library/LaunchAgents" "/Library/LaunchDaemons"; do
  [[ -d "$dir" ]] || continue
  for plist in "$dir"/*.plist; do
    [[ -e "$plist" ]] || continue
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null) || label=""
    [[ -n "$label" ]] || label=$(basename "$plist" .plist)
    [[ "$label" =~ $allowlist_regex ]] && continue
    [[ "$label" =~ $owned_regex ]] || continue
    if ! grep -q "$label" "$MAP"; then
      unmapped="${unmapped}  on-disk-but-unmapped: $label ($plist)
"
    fi
  done
done

if [[ -n "$unmapped" ]]; then
  echo "✗ launchd labels not in docs/architecture.md — add a row or delete the agent:"
  printf '%s' "$unmapped"
  exit 1
fi
echo "✓ every loaded and on-disk launchd label is mapped (architecture.md)"
