#!/usr/bin/env bash
# Upgrade herdr on the dev host, with the two things that make a hand-driven
# upgrade go wrong taken away from you.
#
# THE FIRST IS THE DRIVER. A herdr upgrade bounces the herdr server, so run it
# from inside a herdr pane and it kills the shell running it — mid-sequence,
# between `brew upgrade` and the plist convergence, which is the one window
# where stopping leaves the boot path reverted. This refuses to start there
# (the same `CLAUDECODE`-style guard agent-dispatch uses) rather than trusting
# you to remember which kind of shell you are in.
#
# THE SECOND IS THE PLIST. `brew upgrade herdr` regenerates herdr's brew-service
# plist from the formula and strips the session-leader wrapper. Nothing errors;
# the server comes up fine and only the next `desk` starts asking "restart the
# remote server now? [y/N]" again, which reads as a herdr quirk rather than as a
# reverted config. `_herdr-supervise` runs here unconditionally.
#
# WHAT A RESTART ACTUALLY COSTS, measured rather than feared: shells, dev
# servers and anything else in a pane die, but Claude panes do NOT — herdr's
# native agent session restore resumes them with `claude --resume <id>`, needs
# integration version 6+ (this machine reports 8) and `resume_agents_on_restore`
# defaults to true. The inventory below is written anyway, because "eligible"
# is not "observed" and a list beats memory.
#
# LIVE HANDOFF — CHECKED ON 0.9.0, DELIBERATELY NOT WIRED YET. The capability is
# real: the running server reports `capabilities.live_handoff: true`, and
# `server.live_handoff` takes {import_exe, expected_version, expected_protocol}
# over the socket, replacing a running server while KEEPING pane processes
# alive. There is NO `herdr server live-handoff` subcommand — `herdr server` is
# {stop, reload-config, agent-manifests, update-agent-manifests,
# reload-agent-manifests} — and the two CLI doors, `herdr update --handoff` and
# `herdr --remote <target> --handoff`, both route through herdr's self-updater,
# which would install a binary outside brew and fight the Brewfile. So from this
# install the only route is the socket method, and that part is easy.
#
# WHAT BLOCKS IT IS LAUNCHD, NOT HERDR. This server is a launchd-supervised
# session leader on purpose (_herdr-supervise, herdr/herdr-server-start.py), and
# a handoff hands the panes to a process THIS repo did not start. Unresolved,
# and unresolvable without a restart to test with: whether the brew-service job
# then sees its process exit and KeepAlive-spawns a second server, and whether
# the survivor is still a session leader. Two servers, or one unsupervised one,
# is a worse failure than a bounce that costs an interrupted turn — and since
# native agent session restore already brings the Claude panes back, a bounce is
# cheap. Resolve those two questions on a throwaway `--session` first; this is
# where the code goes once they are answered.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$HOME/.config/herdr/last-restore-inventory.txt"

die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

# --- guards ------------------------------------------------------------------

if [[ -n "${HERDR_ENV:-}" ]]; then
  cat >&2 <<'BRIEF'
  ✗ refusing to run inside a herdr pane — this restarts the server that owns it

    Run it detached, from a shell herdr does not own. DETACHED MATTERS AWAY FROM
    HOME: a foreground `ssh mini '<cmd>'` dies with the link, and a link that
    drops between `brew upgrade` and the plist convergence is the one failure
    this target exists to prevent.

      ssh mini 'cd ~/SourceRoot/dotfiles && nohup make herdr-upgrade YES=1 \
        </dev/null >~/Library/Logs/herdr-upgrade.log 2>&1 & echo started'
      ssh mini 'tail -f ~/Library/Logs/herdr-upgrade.log'

    Or from a daemon that outlives both the link and the restart:
      claude --bg 'run make herdr-upgrade YES=1 in dotfiles and report'
BRIEF
  exit 1
fi

BACKEND=$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")
[[ "$BACKEND" == "cache" ]] || die "not the dev host (backend=${BACKEND:-unset}) — herdr runs no server here"
command -v herdr >/dev/null 2>&1 || die "herdr not installed — run: brew bundle install"
command -v jq >/dev/null 2>&1 || die "jq not installed — run: brew bundle install"

# --- version delta -----------------------------------------------------------

CURRENT=$(herdr --version | awk '{print $2}')
LATEST=$(brew info --json=v2 herdr 2>/dev/null | jq -r '.formulae[0].versions.stable // empty')
[[ -n "$LATEST" ]] || die "could not resolve herdr's stable version from brew"

if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "  ✓ herdr $CURRENT is current — nothing to upgrade"
  exit 0
fi
echo "  herdr $CURRENT → $LATEST"

# --- inventory, and the working/blocked gate ---------------------------------

# Written BEFORE anything is touched: once the server is bounced, the only
# record of what was running is this file.
AGENTS=$(herdr agent list 2>/dev/null || echo '{}')
BUSY=$(jq -r '[.result.agents[]? | select(.agent_status=="working" or .agent_status=="blocked")] | length' <<<"$AGENTS")
TOTAL=$(jq -r '.result.agents? | length // 0' <<<"$AGENTS")

mkdir -p "$(dirname "$INVENTORY")"
{
  echo "# herdr restore inventory — $(date '+%Y-%m-%d %H:%M:%S'), before $CURRENT → $LATEST"
  echo "# Panes herdr does not resume itself come back as plain shells in these directories."
  echo
  jq -r '.result.agents[]? | "\(.agent_status)\t\(.cwd)\t\(.agent_session.value // "-")\t\(.terminal_title // "")"' <<<"$AGENTS"
} > "$INVENTORY"
echo "  $TOTAL agents ($BUSY working or blocked) → $INVENTORY"

if [[ "$BUSY" -gt 0 && "${YES:-}" != "1" ]]; then
  jq -r '.result.agents[]? | select(.agent_status=="working" or .agent_status=="blocked")
         | "    \(.agent_status)  \(.cwd)"' <<<"$AGENTS"
  die "agents are mid-flight — park them, or override with: make herdr-upgrade YES=1"
fi

if [[ "${YES:-}" != "1" ]]; then
  [[ -t 0 ]] || die "no TTY and YES is unset — re-run with: make herdr-upgrade YES=1"
  printf '  Upgrade and restart the herdr server, killing every pane? [y/N] '
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "  · aborted"; exit 0; }
fi

# --- upgrade -----------------------------------------------------------------

echo "  → brew upgrade herdr"
brew upgrade herdr || die "brew upgrade herdr failed"

# Unconditional, and before the restart: the plist brew just rewrote is the one
# launchd will bootstrap.
make -C "$DOTFILES_DIR" --no-print-directory _herdr-supervise
make -C "$DOTFILES_DIR" --no-print-directory herdr-restart YES=1

# --- assert ------------------------------------------------------------------

# The gate, not a guess. `make herdr-restart` already waited for a compatible
# server before it ran agent-overview; this waits for the RIGHT ONE — a server
# that is up, protocol-compatible AND reporting the version brew just poured.
# The old probe here grepped `herdr status server` for "status: running" and
# called a healthy 0.9.0 server dead: it ran while the detached 0.8.2 daemon
# still held the socket, and nothing in that text form says which binary
# answered. A green upgrade exited 1.
bash "$DOTFILES_DIR/scripts/lib/herdr-ready.sh" --timeout 120 --version "$LATEST" \
  || die "herdr $LATEST never took the socket — brew services info herdr --json"

# A new herdr can reject a key the old one accepted, and a rejected config is
# silently the default rather than an error at startup.
herdr config check || die "config.toml is not valid for herdr $LATEST — fix it, then: herdr server reload-config"

# Spaces come back from session.json, but a restored space that was opened after
# the last run lands under OTHER until this re-asserts the declared order.
make -C "$DOTFILES_DIR" --no-print-directory herdr-groups

# Full Disk Access is granted to the resolved Cellar path, so a new version is a
# new, ungranted binary. Without it the first agent that touches ~/Documents,
# ~/Desktop, ~/Downloads or iCloud Drive raises a TCC consent dialog on the
# headless screen, and the open() behind it blocks until someone clicks —
# freezing that whole Claude process, subagents included. Nothing from a shell
# can grant it or even read the grant, so this is a checklist line, not a gate.
HERDR_BIN=$(realpath "$(command -v herdr)")
echo "  ! re-grant Full Disk Access to $HERDR_BIN"
echo "    (screen-share → System Settings → Privacy & Security → Full Disk Access)"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true

echo "  ✓ herdr $LATEST running, boot path converged, groups re-applied"
echo "    restore checklist: $INVENTORY"
echo "    reattach with: desk"
