#!/usr/bin/env bash
# launchagents-check — audit this machine's own LaunchAgents for the failures
# that produce no error anyone ever sees.
#
# WHY THIS EXISTS. On 2026-08-18 the MacBook was found running two agents whose
# WorkingDirectory pointed at repos that live only on the mini. launchd cannot
# chdir there, so every spawn died with 78 (EX_CONFIG) — `com.jkrumm.sideclaw`
# had accumulated **40,281** failed spawns under KeepAlive, and
# `com.jkrumm.usage-tracker` 449. Nothing reported it: both logged to /tmp, which
# macOS sweeps after 3 idle days, and `launchctl list` shows the exit code in a
# column nobody reads. The dev-host heartbeat that would have caught it is
# mini-only, by design — this machine has no equivalent, which is the gap.
#
# Read-only. Exits 1 if anything is wrong, so it can gate a target later; run it
# by hand with `make launchagents-check`.
set -euo pipefail

AGENT_DIR="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
PREFIX="${LAUNCHAGENTS_PREFIX:-com.jkrumm.}"
uid=$(id -u)
problems=0

plist_val() {  # $1=plist  $2=key path → value or empty
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

for plist in "$AGENT_DIR/$PREFIX"*.plist; do
  [ -e "$plist" ] || { echo "no $PREFIX* agents in $AGENT_DIR"; exit 0; }
  label=$(basename "$plist" .plist)

  # The program is either Program, or the first element of ProgramArguments.
  prog=$(plist_val "$plist" Program)
  [ -n "$prog" ] || prog=$(plist_val "$plist" ProgramArguments.0)
  wd=$(plist_val "$plist" WorkingDirectory)

  # `launchctl print` is the only place the last exit code lives; a missing job
  # is not an error here (an agent can be legitimately unloaded).
  detail=$(launchctl print "gui/$uid/$label" 2>/dev/null || true)
  exitcode=$(printf '%s\n' "$detail" | sed -n 's/.*last exit code = \([0-9]*\).*/\1/p' | head -1)
  runs=$(printf '%s\n' "$detail" | sed -n 's/.*runs = \([0-9]*\).*/\1/p' | head -1)

  issues=""
  # An absolute program path that does not exist can never run. A bare name
  # (resolved from PATH) is not checkable here and is deliberately not flagged.
  case "$prog" in
    /*) [ -x "$prog" ] || issues="$issues; program missing: $prog" ;;
  esac
  [ -z "$wd" ] || [ -d "$wd" ] || issues="$issues; WorkingDirectory missing: $wd"

  # EXIT CODES ARE GRADED, because a flat "non-zero is bad" cries wolf and a check
  # you learn to skim is worth nothing. Two different facts:
  #
  #   78 (EX_CONFIG) always matters — launchd could not even start the job, so no
  #   amount of retrying will ever help. This is what a missing repo produces.
  #
  #   Any OTHER non-zero exit matters only if the job is supposed to be up and
  #   is not. com.jkrumm.db-tunnel exits 255 every time the lid closes or the
  #   mini drops off the tailnet — a normal laptop state, by design, with
  #   KeepAlive re-dialling. It is currently running with 103 such exits behind
  #   it and is perfectly healthy; flagging that on every run is exactly the
  #   noise this check exists to cut through.
  keepalive=$(plist_val "$plist" KeepAlive)
  running=0
  printf '%s\n' "$detail" | grep -q 'state = running' && running=1
  if [ "${exitcode:-0}" = "78" ]; then
    issues="$issues; last exit 78 (EX_CONFIG — never started)${runs:+ after $runs runs}"
  elif [ "${exitcode:-0}" != "0" ] && [ "$keepalive" = "true" ] && [ "$running" -eq 0 ]; then
    issues="$issues; KeepAlive job is down, last exit $exitcode${runs:+ after $runs runs}"
  fi

  # Logs in /tmp are swept by macOS after 3 idle days, and launchd opens the file
  # ONCE at spawn — so a long-lived agent keeps writing into an unlinked inode
  # and its post-mortem is gone. See CLAUDE.md "Agent logs".
  for k in StandardOutPath StandardErrorPath; do
    case "$(plist_val "$plist" "$k")" in
      /tmp/*|/private/tmp/*) issues="$issues; $k is in /tmp (swept; use ~/Library/Logs)" ;;
    esac
  done

  # A plaintext credential in a plist is a credential outside 1Password, which
  # rules/security.md forbids — and unlike a repo file, nothing scans it.
  if /usr/bin/plutil -extract EnvironmentVariables xml1 -o - "$plist" 2>/dev/null \
      | grep -qiE '<key>[^<]*(TOKEN|SECRET|PASSWORD|API_?KEY)[^<]*</key>'; then
    issues="$issues; plaintext credential in EnvironmentVariables (move to op:// + a wrapper)"
  fi

  if [ -n "$issues" ]; then
    printf '  ✗ %s%s\n' "$label" "${issues}"
    problems=$((problems + 1))
  else
    printf '  ✓ %s\n' "$label"
  fi
done

if [ "$problems" -gt 0 ]; then
  echo "  → $problems agent(s) need attention"
  exit 1
fi
echo "  → all agents healthy"
