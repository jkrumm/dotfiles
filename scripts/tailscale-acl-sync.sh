#!/usr/bin/env bash
# Tailscale ACL sync — manages the tailnet-wide ACL as code.
#
# Moved here from homelab-private 2026-07-27. The ACL is tailnet-wide, not
# homelab's: it governs Mac↔Mac ssh/screen-sharing, mosh, the dev-port block,
# rb, the phone and the e-reader. Living in homelab-private made it invisible
# from the machine that can actually apply it — the API key is
# `op://Private/Tailscale`, which the mini's cache refuses by design, so an
# ACL change needed the repo (mini) and the biometric human (MacBook) at once.
# dotfiles-private is on the MacBook, which collapses that back to one machine.
#
# Same split as tailscale-serve: tooling here (public-safe), declared state in
# the private repo (it is an access-control map).
#
#   $SECRETS_PRIVATE_REPO/tailscale-acl.jsonc
#
# Auth: OAuth client credentials in 1Password `op://Private/Tailscale`.
#   OAUTH_CLIENT_ID, OAUTH_CLIENT_SECRET — scopes set in Tailscale admin (acl read+write).
#   TAILNET — tailnet identifier.
#
# Control-plane, not a server operation, so no ENV=prod gate.
#
# Subcommands:
#   pull   — fetch live ACL and WRITE it to the local file (normalises formatting)
#   diff   — show diff: live ACL vs local file
#   push   — validate then apply local file to Tailscale (prompts before apply)

set -euo pipefail

PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
ACL_FILE="$PRIVATE_REPO/tailscale-acl.jsonc"
API_BASE="https://api.tailscale.com/api/v2"
OP_ACCOUNT="tkrumm"
OP_REF_BASE="op://Private/Tailscale"

die() { echo "ERROR: $*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"
}

require_tool curl
require_tool jq
require_tool op

# `pull` BOOTSTRAPS this file, so it must NOT require it to already exist —
# an unconditional guard here made the very first pull on a fresh checkout
# impossible, which is exactly how the 2026-07-27 ACL move stalled half-done:
# the tooling landed in this repo while the declared state stayed uncommitted,
# and the one command able to create it refused to run.
#
# diff and push still require it, and deliberately so: both compare against a
# declared state, and treating "no file" as "empty ACL" would let a push wipe
# every grant on the tailnet.
case "${1:-}" in
  diff|push)
    [ -f "$ACL_FILE" ] \
      || die "ACL file not found: $ACL_FILE (bootstrap it first: make tailscale-acl-pull)"
    ;;
esac
# This is MacBook-only, and says so rather than suggesting `op signin` — on the
# mini that advice is actively wrong. The Tailscale API key is op://Private/*,
# which the headless cache refuses unconditionally by design, so no amount of
# signing in there helps; `op signin` itself just hangs on a biometric prompt
# with nobody to answer it. Checked before `op whoami` so the useless generic
# error can't win the race.
if [ "$(cat "${SECRETS_BACKEND_FILE:-$HOME/.config/secrets/backend}" 2>/dev/null)" = "cache" ]; then
  die "this is the headless dev host — run it on the MacBook.
      The Tailscale API key is op://Private/*, refused by the mini's secrets
      cache by design, and 'op signin' here would hang on a biometric prompt.
      Note the ACL cannot tag a device either way: tagging is console-only."
fi
# The probe is the shared one, and it is NOT `op whoami` — under desktop-app
# integration whoami reports rc=1 on a perfectly unlocked app, which made this
# guard refuse every single run on the only machine that can push the ACL. See
# scripts/lib/op-signed-in.sh for the measurement.
"$(dirname "${BASH_SOURCE[0]}")/lib/op-signed-in.sh" "$OP_ACCOUNT" \
  || die "1Password is locked or unavailable for account '$OP_ACCOUNT' — unlock the desktop app and re-run."

urlencode() {
  # POSIX-safe percent-encoding for a single value (used on OAuth creds).
  local s="$1" out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}

oauth_token() {
  # Credentials are piped via stdin, NEVER passed as curl argv (-d/-u flags would
  # expose the client_secret to `ps auxww` for the lifetime of the curl process).
  local cid csec
  cid=$(op read --account "$OP_ACCOUNT" "$OP_REF_BASE/OAUTH_CLIENT_ID")
  csec=$(op read --account "$OP_ACCOUNT" "$OP_REF_BASE/OAUTH_CLIENT_SECRET")
  printf 'client_id=%s&client_secret=%s' "$(urlencode "$cid")" "$(urlencode "$csec")" \
    | curl -sf -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-binary @- \
        "$API_BASE/oauth/token" \
    | jq -er .access_token \
    || die "OAuth token request failed (check OAUTH_CLIENT_ID/SECRET scopes in Tailscale admin)"
}

tailnet_name() {
  op read --account "$OP_ACCOUNT" "$OP_REF_BASE/TAILNET"
}

fetch_live() {
  local token tailnet
  token=$(oauth_token)
  tailnet=$(tailnet_name)
  curl -sf \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/hujson" \
    "$API_BASE/tailnet/$tailnet/acl" \
    || die "fetching live ACL failed"
}

# `pull` writes the file, matching what the name promises and what its `push`
# sibling does in the other direction. It used to only print to stdout, so
# "normalise the formatting with pull" silently did nothing — the file kept its
# 4-space indentation while the live ACL used tabs, and every subsequent diff
# rendered the whole file instead of the lines that actually changed.
#
# Staged through a temp file so a failed fetch cannot truncate the source of
# truth (a bare `> $ACL_FILE` redirect would).
cmd_pull() {
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  fetch_live > "$tmp"
  [ -s "$tmp" ] || die "live ACL came back empty — refusing to overwrite $ACL_FILE"
  if cmp -s "$tmp" "$ACL_FILE"; then
    echo "    already in sync — $ACL_FILE unchanged."
    return 0
  fi
  cat "$tmp" > "$ACL_FILE"
  echo "    wrote live ACL to $ACL_FILE — review with 'git diff' before committing."
}

cmd_diff() {
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  fetch_live > "$tmp"
  echo "# diff: live (-) vs $ACL_FILE (+)"
  diff -u "$tmp" "$ACL_FILE" || true
}

cmd_push() {
  local token tailnet
  token=$(oauth_token)
  tailnet=$(tailnet_name)

  echo "==> Validating $ACL_FILE against Tailscale..."
  local validate_out
  validate_out=$(curl -sf -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/hujson" \
    --data-binary "@$ACL_FILE" \
    "$API_BASE/tailnet/$tailnet/acl/validate") \
    || die "validation failed:\n$validate_out"
  echo "    valid."

  if [ "${ACL_PUSH_YES:-0}" != "1" ]; then
    echo ""
    echo "About to overwrite the live Tailscale ACL with: $ACL_FILE"
    echo "This affects the entire tailnet."
    read -r -p "Type 'apply' to continue: " confirm
    [ "$confirm" = "apply" ] || die "aborted"
  fi

  echo "==> Pushing ACL..."
  curl -sf -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/hujson" \
    --data-binary "@$ACL_FILE" \
    "$API_BASE/tailnet/$tailnet/acl" >/dev/null \
    || die "push failed"
  echo "    applied — propagation is near-instant."
}

case "${1:-}" in
  pull) cmd_pull ;;
  diff) cmd_diff ;;
  push) cmd_push ;;
  *) echo "usage: $0 {pull|diff|push}" >&2; exit 2 ;;
esac
