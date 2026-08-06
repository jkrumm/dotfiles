#!/usr/bin/env bash
set +x
set -euo pipefail

# tailscale-watchdog — RECOVERS the Mac mini's tailnet when the Tailscale app
# has stopped running. Not a monitor: devhost-health-check.sh already reports
# tailscaled liveness to Uptime Kuma every 300s. This is the half that report
# cannot do — bring it back.
#
# WHY THIS EXISTS. The mini has exactly ONE remote access path, and it is
# Tailscale. There is no out-of-band console, homelab is on a different LAN
# (192.168.178.0/24 vs the mini's 192.168.1.0/24, verified 2026-08-05 — homelab
# cannot open tcp:22 on the mini at all), and Screen Sharing rides the same
# tunnel, so it dies with ssh rather than surviving it. Whatever stops the
# Tailscale app also removes every means of starting it again. The failure is
# absorbing: nothing recovers from it except a human walking to the machine.
#
# That is not hypothetical. On 2026-08-05 a remote session quit the app to force
# a Sparkle update check and locked itself out mid-operation; it was recoverable
# only because the operator happened to be on the same LAN that day. A reboot
# WOULD fix it (auto-login + TailscaleStartOnLogin=1), but triggering a reboot
# needs the access that is gone.
#
# SCOPE IS DELIBERATELY NARROW: it recovers "the app is not running", and
# nothing else. See the state machine below for why Stopped and NeedsLogin are
# reported rather than acted on. A watchdog that guesses is worse than one that
# only handles the case that actually bites — the same reasoning that keeps
# check_runaways in devhost-health-check.sh report-only.
#
# LaunchAgent, NOT a LaunchDaemon, and this is load-bearing: `open -a` needs the
# user's Aqua session. A root daemon would have to go through
# `launchctl asuser <uid>`, which fails with "Could not switch to audit session"
# unless it is already root and adds a privilege boundary for no benefit. The
# mini auto-logs-in, so the GUI session is always there. Same reason
# devhost-health is a user agent.
#
# bash 3.2 ONLY (Apple's /bin/bash), same constraint as devhost-health-check.sh:
# launchd hands a user agent a minimal PATH, so `/usr/bin/env bash` is 3.2, not
# Homebrew's 5.x. No mapfile, no ${var,,}.
#
# Usage: tailscale-watchdog.sh
#   TS_WATCHDOG_DISABLED_FILE  touch it to stop the watchdog acting (see below)

# launchd gives no aliases and a minimal PATH — `tailscale` is a shell alias in
# the interactive shell and simply does not exist here. Absolute paths only.
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
TAILSCALE_APP="${TAILSCALE_APP:-/Applications/Tailscale.app}"
OPEN_BIN="${OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${PGREP_BIN:-/usr/bin/pgrep}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
SYSCTL_BIN="${SYSCTL_BIN:-/usr/sbin/sysctl}"
DATE_BIN="${DATE_BIN:-/bin/date}"

STATE_DIR="${TS_WATCHDOG_STATE_DIR:-$HOME/.local/state/tailscale-watchdog}"
JOURNAL="$STATE_DIR/recoveries"
# An operator who deliberately quits Tailscale (debugging, a migration) must be
# able to keep it down without racing a 120s timer. Absence of the file is the
# normal state, so forgetting to remove it is the only failure mode — and that
# one is visible in the devhost-health heartbeat, which keeps reporting the
# tailnet down.
DISABLED_FILE="${TS_WATCHDOG_DISABLED_FILE:-$HOME/.config/tailscale-watchdog/disabled}"

# Login items are not instant. TailscaleStartOnLogin brings the app up a few
# seconds into the session; relaunching underneath that race would spawn a
# second instance rather than fix anything. devhost-health uses 300s for the
# same reason; 180s is enough here because this only needs the app, not the
# whole service stack.
BOOT_GRACE_SECONDS="${TS_WATCHDOG_BOOT_GRACE:-180}"
# How long to wait for the backend to reach Running after a relaunch before
# calling the attempt failed. The extension re-attaches in a few seconds.
SETTLE_SECONDS="${TS_WATCHDOG_SETTLE:-25}"
# Crash-loop ceiling. KeepAlive-style blind restarting is exactly what makes a
# crash-looping service look healthy — check_launchd_restarts in
# devhost-health-check.sh exists because that already cost us herdr. Past this
# many recoveries in the window, STOP relaunching and let the tailnet stay down
# so the heartbeat pages a human. A watchdog that hides a crash loop is worse
# than no watchdog.
MAX_RECOVERIES="${TS_WATCHDOG_MAX_RECOVERIES:-4}"
RECOVERY_WINDOW_SECONDS="${TS_WATCHDOG_RECOVERY_WINDOW:-3600}"

log() { echo "$("$DATE_BIN" '+%Y-%m-%dT%H:%M:%S%z') tailscale-watchdog: $*"; }

# Seconds since boot. Returns a LARGE number when kern.boottime is unparseable,
# so a parse failure means "no grace, act normally" rather than a permanent
# grace window that would silence this script forever. Anchored at `^{` because
# a leading `.*sec = ` is greedy and captures **usec** from the second
# occurrence — the exact bug host_uptime_seconds in devhost-health-check.sh
# documents having shipped.
uptime_seconds() {
  local boot now up
  boot=$("$SYSCTL_BIN" -n kern.boottime 2>/dev/null | /usr/bin/sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')
  case "${boot:-}" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  if [ "$boot" -lt 1600000000 ]; then echo 999999; return 0; fi
  now=$("$DATE_BIN" +%s)
  up=$(( now - boot ))
  if [ "$up" -lt 0 ]; then echo 999999; return 0; fi
  echo "$up"
}

# Echoes BackendState, or the empty string when the CLI cannot reach the
# backend at all (which is itself the signal that the app is gone).
backend_state() {
  local json
  json=$("$TAILSCALE_BIN" status --json 2>/dev/null) || return 0
  [ -n "$json" ] || return 0
  "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' <<<"$json" 2>/dev/null || true
}

app_running() { "$PGREP_BIN" -x Tailscale >/dev/null 2>&1; }

# Count journal entries inside the window. The journal is append-only epoch
# seconds, one per line, and is the ONLY thing that makes a crash loop visible
# — both to the ceiling below and to a human reading the log later.
recent_recoveries() {
  local now cutoff n
  now=$("$DATE_BIN" +%s)
  cutoff=$(( now - RECOVERY_WINDOW_SECONDS ))
  [ -f "$JOURNAL" ] || { echo 0; return 0; }
  n=$(/usr/bin/awk -v c="$cutoff" '$1 > c { n++ } END { print n + 0 }' "$JOURNAL" 2>/dev/null) || n=0
  echo "${n:-0}"
}

# --- main --------------------------------------------------------------------

if [ -e "$DISABLED_FILE" ]; then
  log "disabled by $DISABLED_FILE — not acting"
  exit 0
fi

if [ ! -d "$TAILSCALE_APP" ]; then
  log "ERROR $TAILSCALE_APP missing — nothing to recover"
  exit 1
fi

up=$(uptime_seconds)
if [ "$up" -lt "$BOOT_GRACE_SECONDS" ]; then
  log "boot grace (${up}s < ${BOOT_GRACE_SECONDS}s) — login items still starting"
  exit 0
fi

state=$(backend_state)

# THE STATE MACHINE, and why only one branch acts.
#
#   Running      → healthy, the overwhelmingly common case. Do nothing.
#   app running, but state is Stopped / NeedsLogin / anything else
#                → a human decision or an expired node key. `Tailscale up` here
#                  would either fight a deliberate toggle or fail outright —
#                  NeedsLogin needs a BROWSER ON THE MINI and no amount of
#                  relaunching produces one. Report; let the heartbeat page.
#                  (devhost-health's check_tailscale already warns 30 days
#                  before a key lapses, precisely because it is unfixable
#                  remotely.)
#   app NOT running
#                → the absorbing failure this script exists for. Relaunch.
if [ "$state" = "Running" ]; then
  exit 0
fi

if app_running; then
  log "app running but backend state='${state:-unreachable}' — NOT acting (needs a human; see check_tailscale)"
  exit 1
fi

count=$(recent_recoveries)
if [ "$count" -ge "$MAX_RECOVERIES" ]; then
  log "REFUSING to relaunch: ${count} recoveries in the last $(( RECOVERY_WINDOW_SECONDS / 60 ))min (max ${MAX_RECOVERIES}) — this is a crash loop, not a one-off. Leaving the tailnet down so the heartbeat pages."
  exit 1
fi

log "Tailscale app is not running (backend '${state:-unreachable}') — relaunching (recovery $(( count + 1 ))/${MAX_RECOVERIES} this window)"

/bin/mkdir -p "$STATE_DIR" 2>/dev/null || true
"$DATE_BIN" +%s >> "$JOURNAL" 2>/dev/null || true

if ! "$OPEN_BIN" -a "$TAILSCALE_APP" 2>&1; then
  log "ERROR open -a failed"
  exit 1
fi

# Poll rather than sleeping the full settle window: the usual case comes back in
# a few seconds and a shorter log line is easier to read against the timestamps.
waited=0
while [ "$waited" -lt "$SETTLE_SECONDS" ]; do
  sleep 5
  waited=$(( waited + 5 ))
  state=$(backend_state)
  if [ "$state" = "Running" ]; then
    log "RECOVERED after ${waited}s — tailnet is back"
    exit 0
  fi
done

log "ERROR relaunched but backend is '${state:-unreachable}' after ${SETTLE_SECONDS}s — still down"
exit 1
