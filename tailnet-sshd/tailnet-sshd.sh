#!/usr/bin/env bash
# Wrapper that runs a userland Apple sshd on LOOPBACK:2222, fronted by a
# `tailscale serve --tcp 2222` forwarder — a personal ssh door into iumac (the
# work MacBook) that BYPASSES the MDM SACL (see sshd_config.template header).
# Launched by the com.jkrumm.tailnet-sshd LaunchAgent (RunAtLoad + KeepAlive) in
# the GUI session.
#
# Why loopback + serve instead of binding the tailnet IP directly: tailscaled
# owns the tailnet exposure and re-applies serve config across every daemon
# restart / interface flap, while sshd binds 127.0.0.1 (which never flaps). That
# makes the door self-healing across reboot, login, sshd crash (KeepAlive),
# tailscaled restart (serve re-applied), and even a node re-auth that changes the
# tailnet IP (serve forwards by port, not IP). Same pattern Collie uses.
set -euo pipefail

TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
CFG_DIR="$HOME/.config/tailnet-sshd"
TEMPLATE="$HOME/SourceRoot/dotfiles/tailnet-sshd/sshd_config.template"
HOSTKEY="$CFG_DIR/ssh_host_ed25519_key"
RENDERED="$CFG_DIR/sshd_config"

mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"

# 1. Persistent host key (stable known_hosts on the mini).
if [ ! -f "$HOSTKEY" ]; then
  ssh-keygen -q -t ed25519 -f "$HOSTKEY" -N "" -C "iumac-tailnet-sshd"
fi
chmod 600 "$HOSTKEY"

# 2. Render the config (absolute paths, loopback bind).
sed -e "s#__HOME__#$HOME#g" \
    -e "s#__USER__#$(whoami)#g" \
    "$TEMPLATE" > "$RENDERED"
chmod 600 "$RENDERED"

# 3. Assert the tailnet TCP door (idempotent; persists in tailscaled, re-asserted
#    each start for self-healing). Best-effort: wait briefly for tailscaled, but
#    start sshd regardless — the loopback listener must never depend on the tailnet.
for _ in $(seq 1 15); do
  "$TS_BIN" ip -4 >/dev/null 2>&1 && break
  sleep 2
done
if "$TS_BIN" serve status 2>/dev/null | grep -q '127.0.0.1:2222'; then
  echo "tailnet-sshd: serve door tcp:2222 already present" >&2
elif "$TS_BIN" serve --bg --tcp 2222 tcp://127.0.0.1:2222 >/dev/null 2>&1; then
  echo "tailnet-sshd: serve door tcp:2222 -> 127.0.0.1:2222 asserted" >&2
else
  echo "tailnet-sshd: WARNING could not assert serve door (tailscaled down?) — loopback sshd still up" >&2
fi

echo "tailnet-sshd: binding 127.0.0.1:2222 (userland sshd, UsePAM no, SACL bypassed)" >&2
# -D: foreground, so launchd KeepAlive supervises it directly.
exec /usr/sbin/sshd -D -f "$RENDERED"
