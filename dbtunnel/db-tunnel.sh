#!/usr/bin/env bash
# Persistent SSH port-forwards into the mini's dev databases.
#
# Runs in the FOREGROUND and never daemonises: launchd's KeepAlive is the
# supervisor, so `ssh` must be the process launchd actually watches. An `ssh -f`
# here would fork away, launchd would see a clean exit, and KeepAlive would
# respawn it in a loop forever.
#
# MacBook-only by design — on the mini these databases are already on loopback,
# so the agent self-guards on the secrets-backend marker (`op` = MacBook,
# `cache` = mini) exactly like brain-sync.sh.
#
# Declared state: dbtunnel/tunnels.conf. See that file for why forwards, and not
# `tailscale serve --tcp` or Caddy.
set -euo pipefail

CONF="${DBTUNNEL_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnels.conf}"

fail() { echo "db-tunnel: $*" >&2; exit 1; }
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] db-tunnel: $*"; }

# --- role ---------------------------------------------------------------------
# Same marker, same semantics as brain-sync.sh. Exit 0, not a failure: the agent
# is installed from a shared dotfiles checkout and being a no-op on the mini is
# the correct outcome, not an error worth restarting over.
MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
if [ -f "$MARKER" ]; then
  case "$(tr -d '[:space:]' < "$MARKER")" in
    op)    : ;;
    cache) log "secrets backend is 'cache' (the mini) — databases are local here, nothing to forward."; exit 0 ;;
    *)     fail "cannot determine role: $MARKER holds an unknown backend" ;;
  esac
fi

[ -f "$CONF" ] || fail "no tunnel declaration at $CONF"

# --- parse the declaration ----------------------------------------------------
SSH_HOST=""
FORWARDS=()
NFORWARDS=0
while read -r local_port ssh_host remote_host remote_port _label; do
  case "${local_port:-}" in ''|\#*) continue ;; esac
  [ -n "$ssh_host" ] && [ -n "$remote_host" ] && [ -n "$remote_port" ] \
    || fail "malformed row in $CONF: '$local_port $ssh_host $remote_host $remote_port'"

  if [ -z "$SSH_HOST" ]; then
    SSH_HOST="$ssh_host"
  elif [ "$ssh_host" != "$SSH_HOST" ]; then
    # One supervised process holds every forward, so a second host cannot be
    # served without a second agent. Refuse rather than quietly skip the row.
    fail "row for host '$ssh_host' but this agent already serves '$SSH_HOST' — one agent per SSH host"
  fi

  # Bind the local end to 127.0.0.1 EXPLICITLY. Bare `-L port:host:port` honours
  # GatewayPorts and can land on the wildcard address, which is precisely the
  # exposure this whole file exists to avoid.
  FORWARDS+=(-L "127.0.0.1:${local_port}:${remote_host}:${remote_port}")
  NFORWARDS=$((NFORWARDS + 1))
done < "$CONF"

[ "$NFORWARDS" -gt 0 ] || fail "no forwards declared in $CONF"

# --- identity -----------------------------------------------------------------
# This machine keeps NO private keys on disk (`ls ~/.ssh/id_*` is empty) — every
# identity is served by the 1Password SSH agent. launchd does not hand a job the
# SSH_AUTH_SOCK an interactive shell has, so without this ssh finds no identities
# at all and dies on `Permission denied (publickey)` while KeepAlive dutifully
# retries forever. Point ssh at the agent socket explicitly.
#
# 1Password's socket is preferred and the INHERITED one is the fallback, which is
# the opposite of the obvious ordering — because launchd does not leave
# SSH_AUTH_SOCK unset. It sets it to Apple's own ssh-agent
# (/var/run/com.apple.launchd.*/Listeners), which is a perfectly valid socket
# holding ZERO identities. So an `[ -S "$SSH_AUTH_SOCK" ]` test passes, ssh gets
# an agent with no keys, and the tunnel fails `Permission denied (publickey)`
# while `ssh-add -l` against 1Password from a terminal looks completely healthy.
# Verified under a throwaway launchd job rather than assumed.
#
# The value is passed with LITERAL DOUBLE QUOTES INSIDE IT, and that is not
# belt-and-braces: 1Password's socket lives under "Group Containers", and ssh
# splits an `-o` argument on whitespace, so the bare path dies with
#   command-line line 0: keyword identityagent extra arguments at end of line
# and then falls through to "Permission denied (publickey)" — which reads as a
# key/authorization problem and sends you looking in entirely the wrong place.
OP_AGENT="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
if [ -S "$OP_AGENT" ]; then
  AGENT_SOCK="$OP_AGENT"
elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  AGENT_SOCK="$SSH_AUTH_SOCK"
else
  fail "no SSH agent socket — is the 1Password desktop app running? ($OP_AGENT)"
fi

log "forwarding ${NFORWARDS} port(s) to ${SSH_HOST}"

exec ssh -N -T \
  -o BatchMode=yes \
  -o "IdentityAgent=\"$AGENT_SOCK\"" \
  -o ExitOnForwardFailure=yes \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ControlMaster=no \
  -o ControlPath=none \
  "${FORWARDS[@]}" \
  "$SSH_HOST"

# Two of those options are load-bearing and non-obvious:
#
#   ExitOnForwardFailure=yes — without it ssh connects happily when a local port
#   is already taken and only warns; you then get a client that connects to
#   *something else* on that port. Fail, let launchd retry, surface it in the log.
#
#   ControlMaster=no + ControlPath=none — ~/.ssh/config sets `ControlMaster auto`
#   for mini so herdr/cmux share one connection. A long-lived tunnel must NOT
#   ride that shared socket: when the last interactive session exits and
#   ControlPersist expires, the master tears down and takes every forward with
#   it. This agent owns its own connection.
