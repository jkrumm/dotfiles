#!/usr/bin/env bash
set -uo pipefail

# remote-dev-doctor — verify the MacBook→mini path FROM THE MACBOOK.
#
# The existing devhost-health-check.sh runs ON the mini and reports what the
# mini can see about itself. That is the right shape for a heartbeat, but it
# structurally cannot check the half that actually breaks: the mini has no
# private key material and cannot ssh to itself, so inbound auth, ControlMaster
# reuse, agent forwarding and the mosh UDP path are all invisible from there.
# This is the other half — the client side, which only this machine can test.
#
# Read-only. Nothing here changes state; it is safe to run any time.
#
# Exit 0 if every check passes, 1 otherwise. Each line is PASS / FAIL / SKIP
# with the reason, because a doctor that prints only a verdict makes you re-run
# the underlying commands by hand anyway.

HOST="${REMOTE_DEV_HOST:-mini}"
pass=0 fail=0 skipped=0

ok()   { printf '  \033[32m✓\033[0m %-34s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %-34s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  \033[33m·\033[0m %-34s %s\n' "$1" "${2:-}"; skipped=$((skipped+1)); }

echo ""
echo "  remote-dev doctor — MacBook → $HOST"
echo ""

# --- Layer 1: reachability ---------------------------------------------------
TS_BIN=/Applications/Tailscale.app/Contents/MacOS/Tailscale
if [[ -x "$TS_BIN" ]]; then
  # `tailscale ping` reports the path, which is the fact worth knowing: a DERP
  # relay still "works" but adds latency that makes an interactive session feel
  # wrong, and it is the thing people misattribute to mosh or herdr.
  ping_out=$("$TS_BIN" ping --c=1 "$HOST" 2>&1 | head -1)
  case "$ping_out" in
    *"via DERP"*) ok "tailscale reachable" "via DERP relay — slower than it should be" ;;
    pong*)        ok "tailscale reachable" "direct" ;;
    *)            bad "tailscale reachable" "$ping_out" ;;
  esac
else
  skip "tailscale reachable" "Tailscale.app not found"
fi

# --- Layer 2: ssh, multiplexing, agent ---------------------------------------
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true 2>/dev/null; then
  ok "ssh $HOST" "$(ssh "$HOST" 'echo $USER@$(hostname -s)' 2>/dev/null)"
else
  bad "ssh $HOST" "cannot connect — check 'ssh -v $HOST'"
fi

if ssh -O check "$HOST" >/dev/null 2>&1; then
  ok "ControlMaster" "multiplexing live (one handshake, one biometric approval)"
else
  # Not fatal: the master is created lazily by the first connection and expires
  # after ControlPersist. Worth reporting because its absence is exactly what
  # makes every launch prompt for Touch ID.
  skip "ControlMaster" "no master socket — next connection creates one"
fi

# Agent forwarding is what lets the mini do git/ssh with approval popping HERE.
if ssh "$HOST" 'ssh-add -l' >/dev/null 2>&1; then
  ok "agent forwarding" "mini can use this machine's keys"
else
  bad "agent forwarding" "forwarded agent has no usable keys"
fi

# --- Layer 3: the mosh path --------------------------------------------------
# Check the two things that silently broke it, rather than trying to run mosh:
# a real mosh test needs a TTY and a biometric approval, so it belongs in a
# human's terminal, not in a doctor.
if command -v mosh >/dev/null 2>&1; then
  ok "mosh installed (local)" "$(mosh --version 2>&1 | head -1 | awk '{print $2}')"
else
  bad "mosh installed (local)" "missing — run 'make setup'"
fi

if ssh "$HOST" 'command -v mosh-server' >/dev/null 2>&1; then
  ok "mosh-server on remote PATH" "zshenv PATH block present"
else
  bad "mosh-server on remote PATH" "stripped non-interactive PATH — run 'make setup' on $HOST"
fi

alf_real=$(ssh "$HOST" '/usr/bin/readlink -f "$(command -v mosh-server)" 2>/dev/null' 2>/dev/null)
# $alf_real is deliberately expanded CLIENT-side below: it was resolved by the
# ssh call just above, and interpolating it is what lets the remote grep match
# the exact version-stamped Cellar path.
# shellcheck disable=SC2029
if [[ -n "$alf_real" ]]; then
  if ssh "$HOST" "/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null | grep -qF '$alf_real'"; then
    ok "mosh-server firewall allow" "UDP will reach it"
  else
    # This is the failure that reads exactly like a missing ACL grant.
    bad "mosh-server firewall allow" "UDP will be DROPPED — run 'make mosh-firewall' on $HOST"
  fi
else
  skip "mosh-server firewall allow" "could not resolve mosh-server path"
fi

# --- Layer 4: herdr ----------------------------------------------------------
running=$(ssh "$HOST" 'herdr status --json 2>/dev/null' 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("server",{}).get("running"))' 2>/dev/null)
if [[ "$running" == "True" ]]; then
  ok "herdr server" "running on $HOST"
else
  bad "herdr server" "down — 'brew services restart herdr' on $HOST"
fi

# The whole reason to prefer herdr over tmux is per-pane agent state, and that
# only works if the integration hook is installed. Without it every pane reports
# agent_status "unknown" and herdr is just a worse tmux.
if ssh "$HOST" 'test -f "$HOME/.claude/hooks/herdr-agent-state.sh"' 2>/dev/null; then
  ok "herdr agent-state hook" "panes report real agent status"
else
  bad "herdr agent-state hook" "run 'make herdr-setup' on $HOST"
fi

# --- Credentials -------------------------------------------------------------
if ! ssh "$HOST" 'printf "protocol=https\nhost=github.com\n\n" | "$HOME/.local/bin/git-credential-secrets-cache" get 2>/dev/null | grep -q "^password=."' 2>/dev/null; then
  bad "github credential" "unresolvable — 'make git-headless' / 'make secrets-seed'"
else
  ok "github credential" "resolves from the secrets cache"

  # Scope, not just resolvability. A resolvable token that lacks `Contents:
  # write` fails ONLY on a real push — that is exactly how the previous
  # read-only PAT hid, presenting as `Permission to jkrumm/dotfiles.git denied`
  # mid-work. `--dry-run` still performs the git-receive-pack request GitHub
  # authorizes, so it proves write rights while updating nothing.
  #
  # This check lives HERE and deliberately not in devhost-health-check.sh: that
  # one runs every 5 minutes with maxretries 0, so a GitHub outage or a flaky
  # link would page as "dev host down". The heartbeat asserts the weaker claim
  # on purpose; the doctor is on-demand and can afford the network call.
  probe=$(ssh "$HOST" 'cd "$HOME/SourceRoot/dotfiles" 2>/dev/null \
    && GIT_TERMINAL_PROMPT=0 git push --dry-run origin HEAD:refs/heads/doctor-push-probe 2>&1' 2>/dev/null)
  case "$probe" in
    *"[new branch]"*|*"Everything up-to-date"*)
      ok "github push rights" "verified by dry-run (nothing written)" ;;
    *denied*|*403*|*"Authentication failed"*)
      bad "github push rights" "token resolves but cannot push — needs Contents: read and write" ;;
    *)
      # Don't fail on an unreachable network: that is not a dev-host fault.
      skip "github push rights" "inconclusive — ${probe:-no output from git}" ;;
  esac
fi

echo ""
if (( fail == 0 )); then
  echo "  $pass passed, $skipped skipped — remote dev is ready."
  echo ""
  echo "  dev            mosh in, herdr there (survives lid-close, no reattach)"
  echo "  desk           herdr --remote (local keybindings; answer N to the restart prompt)"
  echo ""
  exit 0
fi
echo "  $pass passed, $fail FAILED, $skipped skipped."
echo ""
exit 1
