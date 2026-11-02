#!/usr/bin/env bash
# agent-refresh — restart a LOADED KeepAlive agent whose program files changed
# after the process started.
#
#   agent-refresh.sh <label> <file>...
#
# `_render-plists` compares only the plist, so a deploy that changed just the
# script (or a module it imports) left the old process running the old code
# ("(up to date)" while hc-resume ran a pre-fix build). This closes that gap:
# process start = now - `ps etime`; if any <file> mtime is newer, `launchctl
# kickstart -k`. Not running (no pid) is left alone: launchd starts it fresh.
#
# Writes the deliberate-restart marker (scripts/lib/launchd-restarts.sh) right
# before the kickstart so the heartbeat reads the bumped `runs` as a deploy.
# NEVER restarts com.jkrumm.herdr-core: a core restart ends every terminal and
# is owner-timed (AGENTS.md §Machines & remote dev).
#
# Overridable for the hermetic suite: LAUNCHCTL_BIN PS_BIN STAT_BIN DATE_BIN
# AGENT_REFRESH_UID DEVHOST_DELIBERATE_RESTART_DIR.
set -uo pipefail

LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
PS_BIN="${PS_BIN:-/bin/ps}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
DATE_BIN="${DATE_BIN:-/bin/date}"
MARKER_DIR="${DEVHOST_DELIBERATE_RESTART_DIR:-$HOME/.local/state/devhost/deliberate-restart}"
CORE_LABEL=com.jkrumm.herdr-core

[ "$#" -ge 2 ] || { echo "usage: agent-refresh.sh <label> <file>..." >&2; exit 2; }
label=$1; shift
[ "$label" != "$CORE_LABEL" ] || { echo "  ✗ $CORE_LABEL is never refreshed here: a core restart ends every terminal and is owner-timed" >&2; exit 2; }
uid="${AGENT_REFRESH_UID:-$(id -u)}"

pid=$("$LAUNCHCTL_BIN" print "gui/$uid/$label" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  echo "    · $label (not running, nothing to refresh)"; exit 0
fi

# etime: [[dd-]hh:]mm:ss
et=$("$PS_BIN" -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
[[ "$et" =~ ^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$ ]] || { echo "    · $label (cannot read process age, left alone)"; exit 0; }
days=0; [[ "$et" == *-* ]] && { days=${et%%-*}; et=${et#*-}; }
IFS=: read -r -a p <<<"$et"
secs=0; for x in "${p[@]}"; do secs=$((secs * 60 + 10#$x)); done
secs=$((secs + 10#$days * 86400))
now=$("$DATE_BIN" +%s)
started=$((now - secs))

newest=0; newest_file=
for f in "$@"; do
  m=$("$STAT_BIN" -f %m "$f" 2>/dev/null) || { echo "  ✗ $label: program file missing: $f" >&2; exit 1; }
  [ "$m" -gt "$newest" ] && { newest=$m; newest_file=$f; }
done

if [ "$newest" -le "$started" ]; then
  echo "    · $label (running current code)"; exit 0
fi

mkdir -p "$MARKER_DIR" && "$DATE_BIN" +%s >> "$MARKER_DIR/$label"
if "$LAUNCHCTL_BIN" kickstart -k "gui/$uid/$label" >/dev/null 2>&1; then
  echo "    ✓ $label (restarted: $(basename "$newest_file") changed after the process started)"
else
  echo "  ✗ $label: kickstart -k failed" >&2; exit 1
fi
