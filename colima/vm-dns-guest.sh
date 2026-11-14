#!/usr/bin/env bash
# Runs INSIDE the colima VM, as root: make /etc/resolv.conf name the default route's gateway as its only
# nameserver. Lima's host resolver IS the guest's default gateway, and the gateway changes when lima renumbers
# the guest (the default and teamchat profiles share one lima network, so whichever boots first takes .2/.3).
# The file colima writes once at provisioning goes stale and every name lookup in the VM dies
# (2026-11-14: the VPN container looped on `could not resolve` for five minutes).
# Idempotent; prints "changed" or "unchanged". colima/apply-provision.sh embeds this file as an `after-boot`
# provision step, which colima runs on every start before the container runtime does, so no container ever
# reads a stale resolver on the start path. Host-side wrapper: colima/vm-dns.sh.
#   env (tests): VM_DNS_RESOLV_CONF, VM_DNS_ROUTE_CMD, VM_DNS_ROUTE_WAIT (seconds), VM_DNS_SUDO ('' = none)
set -euo pipefail

resolv="${VM_DNS_RESOLV_CONF:-/etc/resolv.conf}"
route_cmd="${VM_DNS_ROUTE_CMD:-ip -o -4 route show default}"
wait_s="${VM_DNS_ROUTE_WAIT:-30}"
if [ -n "${VM_DNS_SUDO+set}" ]; then sudo_cmd="$VM_DNS_SUDO"; elif [ "$(id -u)" = 0 ]; then sudo_cmd=""; else sudo_cmd="sudo"; fi

gateway=""
i=0
while :; do
  gateway=$($route_cmd 2>/dev/null | awk '{ for (n = 1; n < NF; n++) if ($n == "via") { print $(n + 1); exit } }') || true
  [ -n "$gateway" ] && break
  [ "$i" -ge "$wait_s" ] && { echo "vm-dns: no default route after ${wait_s}s; leaving $resolv alone" >&2; exit 1; }
  i=$((i + 1))
  sleep 1
done

current=$(awk '$1 == "nameserver" { print $2 }' "$resolv" 2>/dev/null || true)
if [ "$current" = "$gateway" ]; then
  echo unchanged
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '# Lima host resolver is the default gateway; derived at every start (dotfiles colima/vm-dns-guest.sh), never remembered.\nnameserver %s\n' "$gateway" >"$tmp"
# Overwrite in place (cat >), not mv: /etc/resolv.conf may be a bind mount or a symlink target.
$sudo_cmd sh -c 'cat "$1" > "$2"' sh "$tmp" "$resolv"
echo changed
