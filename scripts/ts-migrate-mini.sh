#!/usr/bin/env bash
set -euo pipefail

# ts-migrate-mini — move the Mac mini from the Standalone (macsys) GUI variant
# to the open-source tailscaled daemon installed by Homebrew.
#
# WHY. The macsys variant couples the tunnel to a GUI app: quitting the app stops
# the tunnel, and on this host the tunnel is the only way in — homelab is on a
# different LAN and Screen Sharing rides the same tunnel. It also updates through Sparkle's phased rollout, which
# on 2026-08-05 left the mini on 1.98.9 with 1.102.2 released and no way to pull
# it forward. The brew daemon is the same shape as systemd on the Linux servers:
# root LaunchDaemon, keep_alive always, starts BEFORE login, upgraded by
# `brew upgrade` — which `make brew-upgrade` and drift-check already cover.
#
# VERIFIED BEFORE WRITING THIS, because the docs contradict themselves on it: a
# throwaway node on the brew daemon (userspace, isolated socket) accepted BOTH
# `serve --bg 8080` and `funnel --bg 8080`, i.e. port-based Funnel works. The KB
# claim that port-sharing needs the App Store or Standalone build is wrong. The
# mini's :8443 dashboard is a port share, so this was the blocking question.
#
# THE NODE IDENTITY DOES NOT SURVIVE. macsys keeps its state inside the system
# extension's sandbox, unreadable by the OSS daemon, so this creates a NEW node
# with a NEW tailnet IP. Four places hardcode the old one — fix them AFTER, per
# the runbook at the bottom. Do not pretend this step is idempotent; it is not.
#
# RUN IT OVER LAN SSH, NOT THE TAILNET. Phase B takes the tunnel down; a tailnet
# session running this script dies with it, halfway. That is exactly the failure
# detached-run.sh exists for, and this script is its first real caller.
#
# Usage: ts-migrate-mini.sh [--phase-a-only]

TS_APP="/Applications/Tailscale.app"
TS_APP_BIN="$TS_APP/Contents/MacOS/Tailscale"
BREW_TS="/opt/homebrew/bin/tailscale"
BREW_TSD="/opt/homebrew/opt/tailscale/bin/tailscaled"
STATE_DIR="$HOME/.local/state/ts-migration"
TAGS="tag:mac,tag:devhost,tag:iu-dashboard-funnel"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$BREW_TSD" ] || die "brew tailscaled missing — run: brew install tailscale"
mkdir -p "$STATE_DIR"

# --- Phase A: prep, fully reversible ----------------------------------------

log "Phase A: prep"

# Snapshot for rollback and for the post-migration diff. Captured even though a
# snapshot already exists from the dry run — this must reflect the state at the
# moment of the actual cutover, not an hour earlier.
{
  echo "=== pre-migration $(date -u +%FT%TZ) ==="
  "$TS_APP_BIN" version | head -1
  "$TS_APP_BIN" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); s=d["Self"]; print("IP:", s["TailscaleIPs"]); print("Tags:", s.get("Tags"))'
  echo "--- serve ---"
  "$TS_APP_BIN" serve status
} > "$STATE_DIR/pre-migration.txt" 2>&1
log "  state snapshot → $STATE_DIR/pre-migration.txt"

if [ "${1:-}" = "--phase-a-only" ]; then
  log "Phase A complete (stopping here as asked)"
  exit 0
fi

# --- Phase B: destructive ----------------------------------------------------

log "Phase B: cutover (tunnel goes down here)"

# Stop the app coming back at the next login. Without this, macsys and the brew
# daemon both start and race for the tunnel on every reboot — an intermittent
# failure that would be miserable to diagnose later.
/usr/bin/defaults write io.tailscale.ipn.macsys TailscaleStartOnLogin -bool false 2>/dev/null || true
log "  TailscaleStartOnLogin disabled"

/usr/bin/osascript -e 'quit app "Tailscale"' 2>/dev/null || true
sleep 5
if /usr/bin/pgrep -x Tailscale >/dev/null 2>&1; then
  log "  app still running, forcing"
  /usr/bin/pkill -x Tailscale 2>/dev/null || true
  sleep 3
fi
log "  macsys app stopped"

MACSYS_ROLLBACK=/Users/Shared/tailscale-macsys-rollback
if [ -d "$TS_APP" ]; then
  sudo mkdir -p "$MACSYS_ROLLBACK"
  sudo mv "$TS_APP" "$MACSYS_ROLLBACK/" || die "could not move $TS_APP aside"
  log "  macsys app moved to $MACSYS_ROLLBACK (see comment above — quitting is NOT enough)"
fi

# THE APP MUST BE REMOVED, NOT MERELY QUIT. This was wrong in the first version
# and the first reboot test caught it, which is the whole reason that test exists.
#
# Quitting is enough until the next boot. Then macOS relaunches the app ITSELF as
# the container for its still-activated system extension — `TailscaleStartOnLogin
# = 0` does not prevent this, because it is not a login item doing it — and two
# Tailscale stacks contest the tunnel. The symptom is deeply misleading: the node
# looks HEALTHY (BackendState Running, correct IP and tags, 29 peers, `tailscale
# ping` answers in 25ms) and `tailscale serve` ports keep working, because those
# terminate INSIDE tailscaled. Everything needing delivery to a host process —
# sshd, caddy, even ICMP — is silently dropped. Measured 2026-08-06: :7730 and
# :8443 up, :22 and :443 and ping all dead, and quitting the app fixed every one
# of them instantly.
#
# `systemextensionsctl uninstall` cannot do this: SIP blocks it ("cannot be used
# if System Integrity Protection is enabled"), and disabling SIP to tidy up an
# extension is not a trade worth making. Removing the container app is the
# supported route — with no app, macOS has nothing to launch and the extension
# stays dormant.
#
# Moved, not deleted, so rollback survives: reinstating it is a `mv` back plus a
# relaunch. That is cheaper than it sounds because the OLD NODE RECORD is the
# real rollback anyway, and it must outlive this step.
# sudo, NOT bare `brew services start`. As the user it installs a LaunchAgent,
# and this service is require_root — the agent then dies on every attempt with
# "tailscaled requires root" while `brew services list` merely says `error`.
# Found the hard way on 2026-08-06.
log "  starting brew tailscaled (root LaunchDaemon, keep_alive always)"
sudo /opt/homebrew/bin/brew services start tailscale >/dev/null 2>&1 \
  || die "sudo brew services start tailscale failed"
sleep 6

/usr/bin/pgrep -f "$BREW_TSD" >/dev/null 2>&1 || die "tailscaled did not start — check /opt/homebrew/var/log/tailscaled.log"
log "  tailscaled running"

# --advertise-tags is the whole safety story. Tags applied at `up` time mean the
# node is never present-but-untagged, and an untagged node is one the ACL drops
# entirely — which is precisely how the 2026-08-05 lockout happened. Do not
# split this into "log in now, tag in the console later".
# --socket is MANDATORY, not tidiness. The dormant macsys extension is left
# installed for rollback, and the brew CLI prefers ITS socket over its own when
# both exist — every command then silently drives the stopped daemon. That is
# how three `serve` calls returned "Tailscale is stopped" on a running host.
#
# Run it in the FOREGROUND. Backgrounding this with `sudo -b` lets the child be
# reaped when the ssh session ends: the control plane mints the node, the daemon
# never persists its state, and the local end reports "Logged out" while the
# console shows a healthy node. Foreground here, and the CALLER detaches the
# whole script (that is what detached-run.sh is for).
log "  bringing the node up — A LOGIN URL FOLLOWS, open it to authorise"
echo
sudo "$BREW_TS" --socket=/var/run/tailscaled.socket up \
  --hostname=mini --advertise-tags="$TAGS" --accept-dns=true
echo
log "Phase B complete. Next: re-declare serve config, then the four fix-ups."

# --- Runbook: what must happen after this script ------------------------------
#
#  1. Re-declare serve/funnel (source of truth:
#     dotfiles-private/tailscale-serve.mini.conf). --socket on EVERY call, see
#     the comment above:
#       T="sudo /opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket"
#       $T serve  --bg --https=7730 http://127.0.0.1:4050
#       $T serve  --bg --https=8788 http://127.0.0.1:8787
#       $T funnel --bg --https=8443 http://localhost:5173
#  2. Console FIRST, before anything reads the new IP: rename the old node to
#     `mini-old` and the new one to `mini`. Until this happens, ssh, MagicDNS
#     and the public Funnel URL all still point at the dead node. Rename, do
#     NOT delete — the old record is the rollback.
#  3. On the mini:  make caddy-tailnet   (regenerates both Caddy `bind` lines
#     AND both DNS A records — 3 of the 4 hardcoded sites). NOT
#     `caddy-dns-build`, which only rebuilds the caddy binary and leaves the
#     stale IP in place — a distinction that cost an hour on 2026-08-06.
#  4. On the VPS:   HERMES_BASE_URL in apps/argo/.env → the new IP, then
#     redeploy argo. The only manual edit.
#  5. Verify everything, THEN delete `mini-old` (and any probe nodes).
#
# ROLLBACK, if Phase B goes wrong:
#     sudo brew services stop tailscale
#     sudo mv /Users/Shared/tailscale-macsys-rollback/Tailscale.app /Applications/
#     defaults write io.tailscale.ipn.macsys TailscaleStartOnLogin -bool true
#     open -a Tailscale
#   The macsys node keeps its identity and IP as long as it was not deleted in
#   the console — so step 5 is LAST, only after everything else verifies.
