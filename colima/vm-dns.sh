#!/usr/bin/env bash
# Host side of the default colima VM's resolver (the guest half is vm-dns-guest.sh, which colima also runs on
# every start as a provision step).
#   vm-dns.sh apply [--restart]  derive now; if it changed, containers still hold the old resolver (they read
#                                it when they start): name them, or with --restart restart them
#   vm-dns.sh check              exit 0 when a name resolves inside the VM; else print the resolver in the file
#                                and the gateway, exit 1 (the heartbeat's colima probe calls this)
#   env: COLIMA_BIN, COLIMA_PROFILE (default), DOCKER_BIN, VM_DNS_PROBE_NAME (github.com)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
colima="${COLIMA_BIN:-/opt/homebrew/bin/colima}"
profile="${COLIMA_PROFILE:-default}"
docker_bin="${DOCKER_BIN:-docker}"
probe_name="${VM_DNS_PROBE_NAME:-github.com}"

vm() { "$colima" ssh -p "$profile" -- "$@"; }

case "${1:-}" in
  apply)
    out=$(vm sudo bash -s <"$here/vm-dns-guest.sh") || { echo "vm-dns: could not derive the resolver inside the '$profile' VM" >&2; exit 1; }
    echo "$out"
    [ "$out" = changed ] || exit 0
    ids=$("$docker_bin" ps -q 2>/dev/null) || ids=""
    [ -n "$ids" ] || exit 0
    names=$(echo "$ids" | xargs "$docker_bin" inspect --format '{{.Name}}' | sed 's|^/||' | tr '\n' ' ')
    if [ "${2:-}" = --restart ]; then
      echo "$ids" | xargs "$docker_bin" restart >/dev/null && echo "restarted: $names"
    else
      echo "still hold the old resolver (restart them, or rerun with --restart): $names"
    fi
    ;;
  check)
    vm getent hosts "$probe_name" >/dev/null 2>&1 && exit 0
    file=$(vm awk '$1 == "nameserver" { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null) || file=""
    gw=$(vm sh -c "ip -o -4 route show default | awk '{ for (n = 1; n < NF; n++) if (\$n == \"via\") { print \$(n + 1); exit } }'" 2>/dev/null) || gw=""
    echo "no name resolves inside the '$profile' VM ($probe_name): /etc/resolv.conf names '${file% }', the default gateway is '${gw:-unreadable}' (fix: colima/vm-dns.sh apply --restart)"
    exit 1
    ;;
  *)
    echo "usage: vm-dns.sh apply [--restart] | check" >&2
    exit 2
    ;;
esac
