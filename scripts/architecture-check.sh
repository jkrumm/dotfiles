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
#   2. Every plist in ~/Library/LaunchAgents, /Library/LaunchAgents and
#      /Library/LaunchDaemons named com.jkrumm.* / com.iu.* / ai.hermes.* /
#      herdr.* / homebrew.mxcl.* / sh.brew.* must appear in the map — a plist
#      on disk that launchd has not loaded is exactly the silent state the map
#      exists to prevent. /Library/LaunchAgents is where a dead vendor stub
#      crash-loops at exit 78 for every login with nothing reporting it.
#
# Exit 1 lists the unmapped labels. Adding a legit new agent = add a row to the
# map in the same change; that friction IS the point.
#
# HOMEBREW SERVICES ARE MATCHED UNDER BOTH NAMES. Homebrew 6 renamed every
# service label from homebrew.mxcl.<name> to sh.brew.<name>, and writes the new
# one only on the next `brew services start|restart` — so the mini still carries
# old names, the MacBook already carries new ones, and one map has to satisfy
# both. A row naming EITHER form maps the service, and the map itself was NOT
# left half-migrated: labels are reduced to the bare service name and matched
# against `(sh.brew|homebrew.mxcl).<name>`. Without this the MacBook's
# sh.brew.colima simply fell outside the owned prefix regex and the check went
# on returning 0 over an unmapped, disarmed service.

set -u

DOTFILES="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAP="$DOTFILES/docs/architecture.md"
LAUNCHCTL="${LAUNCHCTL_BIN:-/bin/launchctl}"
# Overridable so the hermetic test can point at a fake machine.
LAUNCHD_DIRS=("${LAUNCHD_AGENT_DIRS[@]:-$HOME/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons}")

[[ -f "$MAP" ]] || { echo "✗ $MAP not found"; exit 1; }

# Labels that are not ours to map. application.* are GUI apps launched by
# LaunchServices (1Password, Obsidian…); the rest are vendor updaters that
# ship their own plists and are not managed by any repo here.
allowlist_regex='^(com\.apple\.|application\.|com\.google\.GoogleUpdater|com\.jetbrains\.toolbox|com\.riot\.riotclient|com\.microsoft\.|org\.pqrs\.|com\.amazonaws\.|com\.logi\.|com\.macromates\.|us\.zoom\.|2BUA8C4S2C\.|com\.openssh\.ssh-agent|com\.google\.keystone|net\.imput\.helium-sparkle)'

# The MacBook is MDM-managed: Jamf, Okta, Adobe and the cancom hardening daemons
# ship dozens of plists nobody here owns, so on the `op` backend only the prefixes
# this repo manages are asserted. The mini is entirely ours — full scan there.
BACKEND=$(tr -d '[:space:]' < "${BACKEND_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend}" 2>/dev/null || echo "")
if [[ "$BACKEND" == "op" ]]; then
  owned_regex='^(com\.jkrumm\.|homebrew\.mxcl\.|sh\.brew\.|cc\.chlc\.)'
else
  owned_regex='.'
fi

unmapped=""

# Is this label in the map? For a Homebrew service, strip whichever generation
# prefix it carries and accept a row written with EITHER — one service, one row,
# regardless of which machine is asking and when it last restarted.
mapped() {
  local label="$1" name=""
  case "$label" in
    sh.brew.*)        name=${label#sh.brew.} ;;
    homebrew.mxcl.*)  name=${label#homebrew.mxcl.} ;;
  esac
  if [[ -n "$name" ]]; then
    grep -qE "(sh\.brew|homebrew\.mxcl)\.${name//./\\.}([^A-Za-z0-9@._-]|$)" "$MAP"
  else
    grep -qF "$label" "$MAP"
  fi
}

# 1. loaded labels (gui domain)
while IFS= read -r label; do
  [[ -n "$label" && "$label" != "Label" ]] || continue
  [[ "$label" =~ $allowlist_regex ]] && continue
  [[ "$label" =~ $owned_regex ]] || continue
  if ! mapped "$label"; then
    unmapped="${unmapped}  loaded-but-unmapped: $label
"
  fi
done < <($LAUNCHCTL list 2>/dev/null | /usr/bin/awk 'NR>1 {print $3}')

# 2. plists on disk, un-loaded or not
# shellcheck disable=SC2068
for dir in ${LAUNCHD_DIRS[@]}; do
  [[ -d "$dir" ]] || continue
  for plist in "$dir"/*.plist; do
    [[ -e "$plist" ]] || continue
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null) || label=""
    [[ -n "$label" ]] || label=$(basename "$plist" .plist)
    [[ "$label" =~ $allowlist_regex ]] && continue
    [[ "$label" =~ $owned_regex ]] || continue
    if ! mapped "$label"; then
      unmapped="${unmapped}  on-disk-but-unmapped: $label ($plist)
"
    fi
  done
done

# 3. The reverse: every label the map lists for THIS machine must still exist
# here — loaded, or a plist on disk (root daemons never show in the user's
# `launchctl list`). The section is picked by backend: `op` is the MacBook, the
# `cache` backend the mini. A row for a job that was deleted or became something
# else (the weatherorb timers that turned into DBOS schedules) fails here instead
# of lingering as a map that lies. Only labels with an owned prefix are asserted;
# prose mentions of vendor labels are not rows.
if [[ "$BACKEND" == "op" ]]; then
  section_re='^## LaunchAgents — MacBook'
  machine=MacBook
else
  section_re='^## LaunchAgents — mini'
  machine=mini
fi
loaded=$($LAUNCHCTL list 2>/dev/null | /usr/bin/awk 'NR>1 {print $3}')
label_live() {
  local label="$1" name="" cand dir
  local -a cands=("$label")
  case "$label" in
    sh.brew.*)       name=${label#sh.brew.} ;;
    homebrew.mxcl.*) name=${label#homebrew.mxcl.} ;;
  esac
  [[ -n "$name" ]] && cands=("sh.brew.$name" "homebrew.mxcl.$name")
  for cand in "${cands[@]}"; do
    grep -qxF "$cand" <<<"$loaded" && return 0
    # shellcheck disable=SC2068
    for dir in ${LAUNCHD_DIRS[@]}; do
      [[ -e "$dir/$cand.plist" ]] && return 0
    done
  done
  return 1
}
stale=""
while IFS= read -r label; do
  [[ -n "$label" ]] || continue
  label_live "$label" || stale="${stale}  mapped-but-absent ($machine): $label
"
done < <(/usr/bin/awk -v re="$section_re" '
    $0 ~ re {on=1; next}
    /^## / {on=0}
    on' "$MAP" \
  | grep -oE '`(com\.jkrumm\.|com\.iu\.|com\.colima\.|ai\.hermes\.|herdr\.|sh\.brew\.|homebrew\.mxcl\.|cc\.chlc\.)[A-Za-z0-9._@-]*[A-Za-z0-9@_-]`' \
  | tr -d '`' | sort -u)

if [[ -n "$unmapped" || -n "$stale" ]]; then
  if [[ -n "$unmapped" ]]; then
    echo "✗ launchd labels not in docs/architecture.md — add a row or delete the agent:"
    printf '%s' "$unmapped"
  fi
  if [[ -n "$stale" ]]; then
    echo "✗ docs/architecture.md lists labels that do not exist on this machine — delete the row or restore the agent:"
    printf '%s' "$stale"
  fi
  exit 1
fi
echo "✓ every loaded and on-disk launchd label is mapped, and every mapped $machine label exists (architecture.md)"
