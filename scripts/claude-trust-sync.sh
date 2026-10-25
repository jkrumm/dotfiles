#!/usr/bin/env bash
# claude-trust-sync.sh — copy folder trust from the default account to every extra account's .claude.json.
#
# For each registered account with its own dir (config/claude-accounts.json, or $CLAUDE_ACCOUNTS_REGISTRY): every
# project path the DEFAULT ~/.claude.json already trusts (.projects[p].hasTrustDialogAccepted == true) is set to
# true in the extra account's file. Why: a fresh `me` start in a folder it never opened stops at "trust this
# folder?", and `herdr agent start` then reports not-ready.
#
# Only ever tightens toward the default, never loosens: it sets true only where the default says true (a path the
# default marks false or does not know is left alone), and touches no other key. One atomic replace per account
# (temp file in the same dir, original mode kept; a running session rewrites the same file), and no write at all
# when nothing is missing, so it is idempotent. An account without a .claude.json yet (never logged in) is skipped:
# re-run after /login. Exit 1 if any account file could not be updated.
set -u
registry="${CLAUDE_ACCOUNTS_REGISTRY:-$(dirname "${BASH_SOURCE[0]}")/../config/claude-accounts.json}"
default_cfg="$HOME/.claude.json"

jq -e '.accounts' "$registry" >/dev/null 2>&1 || { echo "claude-trust-sync: registry unreadable: $registry" >&2; exit 1; }
[[ -f $default_cfg ]] || { echo "    · no $default_cfg yet — nothing to copy trust from"; exit 0; }
jq -e . "$default_cfg" >/dev/null 2>&1 || { echo "claude-trust-sync: $default_cfg is not valid JSON" >&2; exit 1; }

# Paths the default trusts and the extra file lacks (absent or not true).
missing='($d[0].projects // {} | with_entries(select(.value.hasTrustDialogAccepted == true)) | keys) as $want
  | [$want[] | select((($x[0].projects // {})[.].hasTrustDialogAccepted // false) != true)]'

rc=0
while IFS= read -r dir; do
  dir=${dir/#\~/$HOME}
  cfg="$dir/.claude.json"
  [[ -f $cfg ]] || continue
  n=$(jq -n --slurpfile d "$default_cfg" --slurpfile x "$cfg" "$missing | length" 2>/dev/null) \
    || { echo "    ✗ could not read $cfg" >&2; rc=1; continue; }
  (( n )) || { echo "    · $cfg: trust already in sync"; continue; }
  tmp=$(mktemp "$dir/.claude.json.XXXXXX") || { rc=1; continue; }
  if jq --slurpfile d "$default_cfg" --slurpfile x "$cfg" "($missing) as \$add | reduce \$add[] as \$p (.; .projects[\$p].hasTrustDialogAccepted = true)" "$cfg" > "$tmp" \
    && chmod "$(stat -f %Lp "$cfg" 2>/dev/null || stat -c %a "$cfg")" "$tmp" && mv "$tmp" "$cfg"; then
    echo "    ✓ $cfg: trusted $n folder(s) the default account trusts"
  else
    rm -f "$tmp"; echo "    ✗ could not update $cfg" >&2; rc=1
  fi
done < <(jq -r '.accounts[] | select(.dir != null) | .dir' "$registry")
exit $rc
