#!/bin/bash
# tailscale-upgrade.sh: every machine's Tailscale from the MacBook, one node at a time (docs/tailnet.md §Updates).
#
#   tailscale-upgrade.sh status            read-only: each daemon's version against the latest stable
#   tailscale-upgrade.sh homelab|vps|mini  upgrade one node and prove its daemon came back on the new version
#
# Restarting tailscaled ends every ssh session that runs over it, so nothing here depends on the session surviving:
# - Linux: apt runs in its own systemd unit. A Tailscale SSH child dies with the session mid-upgrade otherwise
#   (upstream #21021: the session hung for days holding the dpkg lock).
# - mini: the formula upgrade alone is harmless (the running daemon keeps its old inode). The restart runs in a detached
#   root watchdog that puts the previous keg back when the new daemon does not reach Running. Refuses without a LAN path
#   to the mini unless FORCE=1: the mini's other door is a person at its screen.
# Sudo: `docs/global-reference.md` §Sudo on a server, the password on stdin, never in argv. bash 3.2.
set -u

SSH=(ssh -o ControlPath=none -o ControlMaster=no -o ConnectTimeout=8)
MINI_TS='/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket'
WAIT_S="${TAILSCALE_UPGRADE_WAIT_S:-180}"

die() { echo "  ✗ $*" >&2; exit 1; }
latest() { curl -fsS --max-time 10 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.TarballsVersion // .Version // empty'; }
ts_cmd() { if [[ "$1" == mini ]]; then echo "$MINI_TS"; else echo tailscale; fi; }

# The daemon carries the traffic; the CLI's own version advances the moment a package is poured.
daemon_version() {
  "${SSH[@]}" "$1" "$(ts_cmd "$1") version --daemon" </dev/null 2>/dev/null | awk -F': ' '/^Daemon:/{print $2}' | cut -d- -f1
}

# Seconds until the node answers on $2 over a NEW connection. Prints the elapsed time; rc 1 on timeout.
wait_for_version() {
  local host="$1" want="$2" start=$SECONDS v=""
  while (( SECONDS - start < WAIT_S )); do
    v=$(daemon_version "$host")
    [[ "$v" == "$want" ]] && { echo "  ✓ $host: daemon $v, answering again after $(( SECONDS - start )) s"; return 0; }
    sleep 3
  done
  echo "  ✗ $host: daemon '${v:-unreachable}' after ${WAIT_S} s, wanted $want" >&2
  return 1
}

cmd_status() {
  local want host v note
  want=$(latest) || want=""
  echo "  latest stable: ${want:-unknown}"
  for host in homelab vps mini; do
    v=$(daemon_version "$host")
    note=""
    [[ -n "$v" && "$v" == "$want" ]] && note="current"
    [[ -n "$v" && "$v" != "$want" ]] && note="behind (make tailscale-upgrade HOST=$host)"
    printf '  %-8s %-10s %s\n' "$host" "${v:-unreachable}" "$note"
  done
  printf '  %-8s %-10s %s\n' macbook "$(/Applications/Tailscale.app/Contents/MacOS/Tailscale version 2>/dev/null | head -1)" \
    "App Store build, newest there: $(curl -fsS --max-time 10 'https://itunes.apple.com/lookup?bundleId=io.tailscale.ipn.macos&country=de' | jq -r '.results[0].version // "unknown"')"
}

# homelab has a sudo password, vps is NOPASSWD. The unit is its own cgroup, so the restart cannot take apt with it.
upgrade_linux() {
  local host="$1" want="$2" rc pw_ref=""
  local unit='systemd-run --collect --no-block --unit=tailscale-upgrade --setenv=DEBIAN_FRONTEND=noninteractive /bin/sh -c "apt-get update -qq && apt-get install -y -qq --only-upgrade -o Dpkg::Options::=--force-confold tailscale"'
  [[ "$host" == homelab ]] && pw_ref="op://Private/homelab-server/password"
  if [[ -n "$pw_ref" ]]; then
    op read "$pw_ref" --account tkrumm | "${SSH[@]}" "$host" "sudo -S -p '' $unit"
    rc=${PIPESTATUS[1]}
  else
    "${SSH[@]}" "$host" "sudo -n $unit" </dev/null
    rc=$?
  fi
  [[ "$rc" == 0 ]] || die "$host: could not start the upgrade unit (rc=$rc)"
  echo "  · $host: apt runs in unit tailscale-upgrade; the ssh path drops when tailscaled restarts"
  wait_for_version "$host" "$want" || { echo "    logs: ssh $host 'journalctl -u tailscale-upgrade -n 40'" >&2; return 1; }
}

upgrade_mini() {
  local want="$1" lan old new log rc
  log='$HOME/Library/Logs/tailscale-upgrade.log'
  lan=$("${SSH[@]}" mini 'ipconfig getifaddr en0' </dev/null 2>/dev/null) || lan=""
  if [[ -n "$lan" ]] && "${SSH[@]}" -o ConnectTimeout=4 -o IdentitiesOnly=yes -o IdentityAgent=none -i "$HOME/.ssh/id_ed25519_mini" "jkrumm@$lan" true </dev/null 2>/dev/null; then
    echo "  · fallback if the tailnet stays down: ssh -i ~/.ssh/id_ed25519_mini jkrumm@$lan"
  elif [[ "${FORCE:-0}" == 1 ]]; then
    echo "  · no LAN path to the mini, FORCE=1: the watchdog's rollback is the only net"
  else
    die "no LAN path to the mini: run this at home, or FORCE=1 to rely on the watchdog's rollback alone"
  fi

  "${SSH[@]}" mini "$MINI_TS serve status --json" </dev/null >/tmp/ts-serve-before.$$ 2>/dev/null
  old=$("${SSH[@]}" mini 'basename "$(readlink /opt/homebrew/opt/tailscale)"' </dev/null)
  [[ -n "$old" ]] || die "mini: no linked tailscale keg"

  # Old inode keeps serving. No install cleanup: the rollback needs the previous keg on disk.
  "${SSH[@]}" mini 'export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_INSTALL_CLEANUP=1; brew unpin tailscale; brew upgrade tailscale; rc=$?; brew pin tailscale; exit $rc' </dev/null 2>&1 | tail -3 | cut -c1-140
  new=$("${SSH[@]}" mini 'basename "$(readlink /opt/homebrew/opt/tailscale)"' </dev/null)
  [[ "$new" == "$want"* ]] || die "mini: the keg is '$new', wanted $want; the daemon was not touched"
  "${SSH[@]}" mini "/opt/homebrew/opt/tailscale/bin/tailscaled --version" </dev/null >/dev/null 2>&1 || die "mini: the new tailscaled does not run; the daemon was not touched"

  "${SSH[@]}" mini "mkdir -p \$HOME/.local/state; cat > \$HOME/.local/state/tailscale-watchdog.sh; touch $log" <<WATCHDOG
#!/bin/bash
# Runs as root, detached: it outlives the ssh session the restart ends.
ts='$MINI_TS'
echo "\$(date) restart: $old -> $new"
launchctl kickstart -k system/homebrew.mxcl.tailscale
for _ in \$(seq 1 45); do
  sleep 2
  v=\$(\$ts version --daemon 2>/dev/null | awk -F': ' '/^Daemon:/{print \$2}' | cut -d- -f1)
  if [ "\$v" = "$want" ] && \$ts status --json 2>/dev/null | grep -q '"BackendState": "Running"'; then
    echo "\$(date) ok: daemon \$v Running"; exit 0
  fi
done
echo "\$(date) ROLLBACK to $old: the new daemon did not reach Running"
owner=\$(stat -f %Su /opt/homebrew/Cellar)
ln -sfn "../Cellar/tailscale/$old" /opt/homebrew/opt/tailscale
chown -h "\$owner" /opt/homebrew/opt/tailscale
launchctl kickstart -k system/homebrew.mxcl.tailscale
echo "\$(date) rolled back; the CLI links still point at $new (brew link --overwrite after a look)"
WATCHDOG
  "${SSH[@]}" mini 'test -s "$HOME/.local/state/tailscale-watchdog.sh"' </dev/null || die "mini: watchdog not written; the daemon was not touched"

  op read "op://Private/mac-mini-server/password" --account tkrumm \
    | "${SSH[@]}" mini "sudo -S -p '' /bin/bash -c 'nohup /bin/bash \$HOME/.local/state/tailscale-watchdog.sh >>$log 2>&1 </dev/null &'"
  rc=${PIPESTATUS[1]}
  # The restart may cut this very connection: 255 after the sudo succeeded is expected, the version check decides.
  [[ "$rc" == 0 || "$rc" == 255 ]] || die "mini: sudo failed (rc=$rc); the daemon was not touched"

  sleep 3
  if ! wait_for_version mini "$want"; then
    echo "    read ~/Library/Logs/tailscale-upgrade.log on the mini (LAN path above); the watchdog rolls back by itself" >&2
    return 1
  fi
  "${SSH[@]}" mini "tail -n 2 $log" </dev/null 2>/dev/null | sed 's/^/    /'
  "${SSH[@]}" mini "$MINI_TS serve status --json" </dev/null >/tmp/ts-serve-after.$$ 2>/dev/null
  if diff /tmp/ts-serve-after.$$ /tmp/ts-serve-before.$$ >/dev/null; then
    echo "  ✓ mini: serve and funnel config unchanged"
  else
    echo "  ! mini: serve/funnel config differs from before; check make tailscale-serve-check"
  fi
  rm -f /tmp/ts-serve-before.$$ /tmp/ts-serve-after.$$
}

cmd_upgrade() {
  local host="$1" want cur
  want=$(latest); [[ -n "$want" ]] || die "pkgs.tailscale.com unreachable"
  cur=$(daemon_version "$host")
  [[ -n "$cur" ]] || die "$host: daemon unreadable, not touching it"
  [[ "$cur" == "$want" ]] && { echo "  · $host: already $want"; return 0; }
  echo "  $host: $cur -> $want"
  case "$host" in
    mini) upgrade_mini "$want" ;;
    *) upgrade_linux "$host" "$want" ;;
  esac
}

case "${1:-status}" in
  status) cmd_status ;;
  homelab | vps | mini) cmd_upgrade "$1" ;;
  *) echo "usage: $0 status|homelab|vps|mini" >&2; exit 2 ;;
esac
