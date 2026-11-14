#!/usr/bin/env bash
# Hermetic test for colima/vm-dns-guest.sh, vm-dns.sh and apply-provision.sh: a temp resolv.conf, a stub route,
# a stub colima and docker. Never the live VM.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got: $3)"; }

guest() { VM_DNS_RESOLV_CONF="$t/resolv.conf" VM_DNS_ROUTE_CMD="${ROUTE:-echo default via 192.168.5.2 dev eth0 proto dhcp src 192.168.5.3}" VM_DNS_ROUTE_WAIT=0 VM_DNS_SUDO='' "$here/vm-dns-guest.sh"; }

# --- guest: derive from the route
printf '# written once at provisioning\nnameserver 192.168.5.1\n' >"$t/resolv.conf"
is "stale resolver is replaced: changed" changed "$(guest)"
is "the gateway is the only nameserver" "192.168.5.2" "$(awk '$1=="nameserver"{print $2}' "$t/resolv.conf")"
cp "$t/resolv.conf" "$t/before"
is "second run: unchanged" unchanged "$(guest)"
cmp -s "$t/before" "$t/resolv.conf" && ok "second run leaves the file alone" || bad "second run leaves the file alone"
printf 'nameserver 192.168.5.2\nnameserver 8.8.8.8\n' >"$t/resolv.conf"
is "a correct nameserver plus a stray one differs: changed" changed "$(guest)"
is "...and the stray one is gone" "1" "$(grep -c '^nameserver' "$t/resolv.conf")"
ROUTE="echo default via 192.168.5.3 dev eth0" is "a renumbered gateway is followed" changed "$(ROUTE='echo default via 192.168.5.3 dev eth0' guest)"
printf 'nameserver 192.168.5.3\n' >"$t/resolv.conf"
cp "$t/resolv.conf" "$t/before"
ROUTE='echo' guest >/dev/null 2>&1 && bad "no default route is refused" || ok "no default route is refused"
cmp -s "$t/before" "$t/resolv.conf" && ok "no route leaves the file alone" || bad "no route leaves the file alone"
rm -f "$t/resolv.conf"
is "a missing file is created: changed" changed "$(guest)"

# --- stub colima + docker for the host half
mkdir -p "$t/bin"
cat >"$t/colima" <<STUB
#!/bin/sh
# colima ssh -p <profile> -- <cmd...>: emulate the three guest calls against the temp resolv.conf.
shift 4
case "\$1" in
  sudo) VM_DNS_RESOLV_CONF="$t/resolv.conf" VM_DNS_ROUTE_CMD="echo default via 192.168.5.2 dev eth0" VM_DNS_ROUTE_WAIT=0 VM_DNS_SUDO='' bash -s ;;
  getent) [ "\${STUB_RESOLVES:-1}" = 1 ] ;;
  awk) awk '\$1=="nameserver"{printf "%s ", \$2}' "$t/resolv.conf" ;;
  sh) echo 192.168.5.2 ;;
esac
STUB
cat >"$t/docker" <<STUB
#!/bin/sh
case "\$1" in
  ps) printf 'c1\nc2\n' ;;
  inspect) shift; printf '/vpn\n/api\n' ;;
  restart) echo "\$*" >"$t/restarted" ;;
esac
STUB
chmod +x "$t/colima" "$t/docker"
host() { COLIMA_BIN="$t/colima" DOCKER_BIN="$t/docker" "$here/vm-dns.sh" "$@"; }

printf 'nameserver 192.168.5.1\n' >"$t/resolv.conf"
out=$(host apply)
case "$out" in changed*) ok "apply prints changed" ;; *) bad "apply prints changed ($out)" ;; esac
case "$out" in *"still hold the old resolver"*vpn*api*) ok "apply names the containers holding the old resolver" ;; *) bad "apply names the containers ($out)" ;; esac
[ -e "$t/restarted" ] && bad "apply alone restarts nothing" || ok "apply alone restarts nothing"
is "apply again: unchanged, nothing named" unchanged "$(host apply)"
printf 'nameserver 192.168.5.1\n' >"$t/resolv.conf"
host apply --restart >/dev/null
[ "$(cat "$t/restarted" 2>/dev/null)" = "restart c1 c2" ] && ok "apply --restart restarts the running containers" || bad "apply --restart restarts the running containers"

# --- check
STUB_RESOLVES=1 host check && ok "check passes when a name resolves" || bad "check passes when a name resolves"
printf 'nameserver 192.168.5.1\n' >"$t/resolv.conf"
msg=$(STUB_RESOLVES=0 host check); rc=$?
[ "$rc" = 1 ] && ok "check fails on a stale resolver" || bad "check fails on a stale resolver"
case "$msg" in *"names '192.168.5.1'"*"gateway is '192.168.5.2'"*) ok "the failure names the resolver in the file and the gateway" ;; *) bad "the failure names both ($msg)" ;; esac

# --- provision block
cat >"$t/colima.yaml" <<'YAML'
cpu: 4
# Default: []
provision: null

# Modify ~/.ssh/config automatically.
sshConfig: true
YAML
is "provision block written: changed" changed "$("$here/apply-provision.sh" "$t/colima.yaml" "$here/vm-dns-guest.sh")"
cp "$t/colima.yaml" "$t/before"
is "provision block second run: unchanged" unchanged "$("$here/apply-provision.sh" "$t/colima.yaml" "$here/vm-dns-guest.sh")"
cmp -s "$t/before" "$t/colima.yaml" && ok "provision second run is a no-op" || bad "provision second run is a no-op"
grep -q '^  - mode: after-boot' "$t/colima.yaml" && ok "step runs after boot, before the container runtime" || bad "step runs after boot"
grep -q '^sshConfig: true' "$t/colima.yaml" && grep -q '^# Modify ~/.ssh/config' "$t/colima.yaml" && grep -q '^cpu: 4' "$t/colima.yaml" && ok "other keys and comments kept" || bad "other keys and comments kept"
# The embedded script is the guest script, byte for byte, and still derives the resolver.
sed -n '/^    script: |$/,$p' "$t/colima.yaml" | sed '1d' | sed '/^[^ ]/,$d' | sed 's/^      //' >"$t/embedded.sh"
printf 'nameserver 192.168.5.1\n' >"$t/resolv.conf"
is "the embedded script derives the resolver" changed "$(VM_DNS_RESOLV_CONF="$t/resolv.conf" VM_DNS_ROUTE_CMD='echo default via 192.168.5.2 dev eth0' VM_DNS_ROUTE_WAIT=0 VM_DNS_SUDO='' bash "$t/embedded.sh")"
exit "$fail"
