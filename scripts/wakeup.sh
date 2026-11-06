#!/bin/sh
# Runs on wake from sleep via sleepwatcher.
BREW=$( [ -x /opt/homebrew/bin/brew ] && echo /opt/homebrew || echo /usr/local )

# 1) Reload local dev routing (Caddy *.test reverse proxy).
"${BREW}/bin/caddy" reload --config "${BREW}/etc/Caddyfile" 2>/dev/null || true

# 2) Heal Colima's host→guest docker-socket forward.
#    Across sleep/wake, Lima can drop the forward while the VM keeps running: the host
#    socket stops accepting, so every docker client gets `ECONNREFUSED /var/run/docker.sock`
#    even though dockerd inside the VM is fine. A plain `colima start` or `brew services
#    restart colima` does NOT fix it — the orphaned VM survives the service restart and the
#    stale ~/.colima/default/docker.sock blocks the new forward from binding. Only a full
#    restart rebuilds it, and the only supported one is `make colima-restart`: it re-arms the
#    supervised job (bootout + bootstrap of the converged plist), whereas `brew services
#    stop/start colima` regenerates the plist and drops the supervisor wrapper.
SOCK="${HOME}/.colima/default/docker.sock"
colima_socket_ok() {
	[ "$(/usr/bin/curl -s --max-time 3 --unix-socket "$SOCK" http://localhost/_ping 2>/dev/null)" = "OK" ]
}
# This file is symlinked to ~/.wakeup by `make setup`; the checkout is where the link points.
SELF=$(/usr/bin/readlink "$0" 2>/dev/null || echo "$0")
DOTFILES="$(cd "$(/usr/bin/dirname "$SELF")/.." 2>/dev/null && pwd || echo "${HOME}/SourceRoot/dotfiles")"
# Only act if Colima is meant to be up (don't fight an intentional `make colima-stop`): the
# job is loaded in launchd. Asked of launchd directly — `brew services list` is not the judge
# of the supervised plist — and by service name, so either Homebrew label generation resolves.
COLIMA_TARGET=$(/bin/bash "${DOTFILES}/scripts/lib/brew-service.sh" target colima 2>/dev/null || true)
if [ -n "$COLIMA_TARGET" ] && /bin/launchctl print "$COLIMA_TARGET" >/dev/null 2>&1; then
	# Retry once — the forward can lag a couple seconds right after wake before declaring it dead.
	colima_socket_ok || /bin/sleep 3
	if ! colima_socket_ok; then
		rm -f "$SOCK"   # clear the stale socket that blocks the re-forward
		# A restart takes ~30 s+; the hook must return at once, so it runs backgrounded (last run kept in the log).
		( PATH="${BREW}/bin:/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/make -C "$DOTFILES" colima-restart \
			>"${HOME}/Library/Logs/wakeup-colima-restart.log" 2>&1 ) >/dev/null 2>&1 &
	fi
fi

# 3) Grade the background jobs against awake time and notify on a bad row. A stale row is only
#    reported once the machine has been awake for the job's whole window (jobs-grade --notify),
#    so a closed lid is not a stalled job. Backgrounded: the hook must return at once.
if [ -x "${HOME}/.local/bin/jobs-grade" ]; then
	( /bin/sleep 120; "${HOME}/.local/bin/jobs-grade" --notify >/dev/null 2>&1 ) >/dev/null 2>&1 &
fi

# 4) Session health: grade the Claude logins on this Mac and the mini, re-push the re-login dialogs the mini could not
#    deliver while this Mac slept, and notify once when the picture changed. Waits for the network; backgrounded.
if [ -x "${HOME}/.local/bin/claude-account" ]; then
	( /bin/sleep 30; "${HOME}/.local/bin/claude-account" health --wake >/dev/null 2>&1 ) >/dev/null 2>&1 &
fi
