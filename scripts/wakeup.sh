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
#    stop + stale-socket removal + clean start rebuilds it. This auto-heals that on wake.
SOCK="${HOME}/.colima/default/docker.sock"
colima_socket_ok() {
	[ "$(/usr/bin/curl -s --max-time 3 --unix-socket "$SOCK" http://localhost/_ping 2>/dev/null)" = "OK" ]
}
# Only act if Colima is meant to be up (don't fight an intentional `brew services stop`).
if "${BREW}/bin/brew" services list 2>/dev/null | grep -E '^colima' | grep -q started; then
	# Retry once — the forward can lag a couple seconds right after wake before declaring it dead.
	colima_socket_ok || /bin/sleep 3
	if ! colima_socket_ok; then
		"${BREW}/bin/brew" services stop colima >/dev/null 2>&1   # unload launchd job (disarms KeepAlive)
		"${BREW}/bin/colima" stop -f >/dev/null 2>&1              # kill the orphaned VM the service stop leaves behind
		rm -f "$SOCK"                                             # clear the stale socket that blocks the re-forward
		"${BREW}/bin/brew" services start colima >/dev/null 2>&1  # clean start → fresh VM + fresh socket forward
	fi
fi
