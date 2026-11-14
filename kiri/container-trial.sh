#!/usr/bin/env bash
# container-trial — Apple's `container` as the second candidate of docs/kiri-trial.md, no sudo.
#
#   container-trial.sh install    pinned signed pkg → sha256, signature, notarization → expanded (never installed) under ~/.local/share/apple-container
#   container-trial.sh measure    start the system service, read the seven items of step 4, stop it
#   container-trial.sh stop       stop the service (and every container with it)
#   container-trial.sh teardown   stop, then remove the install and its data
#
# The pkg installs into /usr/local with sudo; `container system start` takes --install-root and
# --app-root, so the signed payload is expanded in place and run from the home directory. The service
# runs only inside `measure` (or until `stop`). Env: CONTAINER_VERSION CONTAINER_SHA256 CONTAINER_TEAM (the Makefile's pin).
set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VERSION="${CONTAINER_VERSION:?run through make}"
ROOT="$HOME/.local/share/apple-container"
INSTALL="$ROOT/$VERSION"
APP="$ROOT/data"
C="$INSTALL/bin/container"
OUT="$HOME/.local/state/kiri-trial"
BENCH="$HOME/.local/state/kiri-trial/bench"
mkdir -p "$OUT" "$BENCH"
ALPINE=docker.io/library/alpine:3.20
MARIA=docker.io/library/mariadb:11.4
PY=docker.io/library/python:3.13-alpine

die() { echo "  ✗ $*" >&2; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
since() { perl -e "printf '%.1f', $(now) - $1"; }

foot() {   # pid → MiB, as top's MEM column
  top -l 1 -pid "$1" -stats pid,mem 2>/dev/null | awk -v p="$1" '$1==p{u=$2; n=u+0; if (u ~ /G/) n*=1024; else if (u ~ /K/) n/=1024; else if (u ~ /M/) n=n; else n/=1048576; printf "%d", n}'
}

service_pids() { ps -axo pid=,command= | awk -v r="$INSTALL" -v a="$APP" 'index($0,r)||index($0,a){print $1}' | while read -r p; do [ "$p" != "$$" ] && echo "$p"; done; }

services_footprint() {   # label
  local total=0 p f cmd
  echo "  $1:"
  for p in $(service_pids); do
    cmd=$(ps -o command= -p "$p" 2>/dev/null | awk '{print $1}' | sed "s|$INSTALL/||")
    case "$cmd" in *container-trial*|*awk*|*ps*) continue ;; esac
    f=$(foot "$p"); [ -n "$f" ] || continue
    echo "    pid $p $cmd ${f} MiB"; total=$((total + f))
  done
  echo "    total: $total MiB"
}

# The container's VM is a Virtualization XPC process (a child of launchd) that holds files under our data root;
# the container-runtime-linux helper beside it is a 20 MiB shell of a process and says nothing about memory.
runtime_pid() {
  local p
  for p in $(pgrep -f '^/System/Library/Frameworks/Virtualization.framework/.*VirtualMachine'); do
    lsof -p "$p" 2>/dev/null | grep -q "$APP" && { echo "$p"; return 0; }
  done
  return 1
}

install() {
  [ -x "$C" ] && { echo "    v$VERSION already expanded at $INSTALL"; return 0; }
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/container-dl.XXXXXX")
  gh release download "$VERSION" -R apple/container -p "container-$VERSION-installer-signed.pkg" -D "$tmp" || die "download failed"
  local pkg="$tmp/container-$VERSION-installer-signed.pkg"
  [ "$(shasum -a 256 "$pkg" | cut -d' ' -f1)" = "${CONTAINER_SHA256:?}" ] || die "sha256 differs from the pin"
  local sig; sig=$(pkgutil --check-signature "$pkg" 2>&1)
  [[ "$sig" == *"${CONTAINER_TEAM:?}"* && "$sig" == *"Notarization: trusted by the Apple notary service"* ]] || die "signature or notarization check failed: $sig"
  pkgutil --expand-full "$pkg" "$tmp/x" || die "expand failed"
  mkdir -p "$INSTALL"
  cp -R "$tmp/x/Payload/bin" "$tmp/x/Payload/libexec" "$INSTALL/"
  codesign --verify --deep --strict "$INSTALL/bin/container" || die "binary signature does not verify"
  rm -rf "$tmp"
  echo "    ✓ expanded v$VERSION at $INSTALL (sha256, installer signature $CONTAINER_TEAM, notarization checked; nothing installed system-wide)"
}

start() {
  mkdir -p "$APP"
  "$C" system start --app-root "$APP" --install-root "$INSTALL" --enable-kernel-install --timeout 180 2>&1 | tail -5
}

stop() {
  [ -x "$C" ] && "$C" system stop 2>&1 | tail -3
  echo "    stopped; service processes left: $(service_pids | wc -l | tr -d ' ')"
}

measure() {
  echo "# Apple container $VERSION (macOS $(sw_vers -productVersion))"
  local t0 pid f
  t0=$(now); start; echo "  system start (incl. kernel install on the first run): $(since "$t0") s"
  /bin/sleep 60
  echo "## 1. footprint of the services, no container running (60 s and 5 min after the start; no image pulled yet)"
  services_footprint "services at +60 s"
  /bin/sleep 240
  services_footprint "services at +5 min"
  echo "## 2. start time of alpine running true"
  "$C" image pull "$ALPINE" >/dev/null 2>&1
  for i in 1 2 3; do t0=$(now); "$C" run --rm "$ALPINE" true; echo "  run $i: $(since "$t0") s (exit $?)"; done
  echo "## 3. footprint of one long-running container (mariadb, -m 4G) at rest and 10 min after a 2 GiB allocation ended"
  "$C" image pull "$MARIA" >/dev/null 2>&1; "$C" image pull "$PY" >/dev/null 2>&1
  "$C" rm -f mdb >/dev/null 2>&1
  t0=$(now)
  "$C" run -d --name mdb -m 4G -e MARIADB_ROOT_PASSWORD=trial-only-not-a-secret -p 127.0.0.1:23307:3306 "$MARIA" >/dev/null 2>&1 || echo "  run -d failed"
  /bin/sleep 40
  echo "  mariadb up after $(since "$t0") s: $("$C" ls 2>&1 | grep mdb | head -1)"
  pid=$(runtime_pid mdb); echo "  runtime helper pid: ${pid:-none}"
  [ -n "$pid" ] && echo "  at rest: footprint $(foot "$pid") MiB"
  [ -n "$pid" ] && echo "  guest: $("$C" exec mdb sh -c 'free -m | sed -n 2p' 2>&1)"
  echo "  allocating 2 GiB in the guest (tmpfs write, 30 s hold, then freed):"
  # (no mount: the container has no CAP_SYS_ADMIN, so a tmpfs is refused; perl is in the image)
  "$C" exec mdb perl -e '$x = "a" x (2048 << 20); sleep 30; print "allocation held 30 s and freed\n"' 2>&1 | sed 's/^/    /' &
  local bg=$! peak=0
  for i in $(seq 1 12); do /bin/sleep 3; f=$(foot "$pid"); [ -n "$f" ] && [ "$f" -gt "$peak" ] && peak=$f; done
  wait "$bg"
  echo "  peak footprint: $peak MiB"
  /bin/sleep 600
  echo "  10 min after the allocation ended: footprint $(foot "$pid") MiB; guest: $("$C" exec mdb sh -c 'free -m | sed -n 2p' 2>&1)"
  echo "## 4. publish on 127.0.0.1 and reach it from the Mac (mariadb on 127.0.0.1:23307)"
  /bin/sleep 5
  echo "  tcp connect: $( (exec 3<>/dev/tcp/127.0.0.1/23307 && head -c 40 <&3 | strings | head -1) 2>&1 | head -2)"
  "$C" rm -f mdb >/dev/null 2>&1
  echo "## 5. tun device (NET_ADMIN, /dev/net/tun; no --device flag exists)"
  # busybox `ip` has no tuntap: TUNSETIFF by hand (IFF_TUN|IFF_NO_PI), with and without the capability
  local tunpy="import fcntl,os,struct; f=os.open('/dev/net/tun',os.O_RDWR); fcntl.ioctl(f,0x400454ca,struct.pack('16sH',b'tun0',0x1001)); print('TUN_OK')"
  echo "  with --cap-add CAP_NET_ADMIN: $("$C" run --rm --cap-add CAP_NET_ADMIN "$PY" python -c "$tunpy" 2>&1 | tail -1)"
  echo "  without it:                   $("$C" run --rm "$PY" python -c "$tunpy" 2>&1 | tail -1)"
  echo "## 6. bind-mount speed (python bindbench.py on $BENCH)"
  cp "$DOTFILES_DIR/kiri/trial/bindbench.py" "$BENCH/"
  for i in 1 2; do echo "  run $i: $("$C" run --rm -v "$BENCH:/work" "$PY" python /work/bindbench.py 2>&1 | tail -1)"; done
  echo "## 7. compose keys with no flag: from \`container run --help\` and \`network create --help\`"
  local h; h=$("$C" run --help 2>&1)
  for k in restart health device depends cap-add publish network internal; do printf '  %-10s %s\n' "$k" "$(echo "$h" | grep -c -- "--$k") flag(s) in run --help"; done
  echo "  network create --internal: $("$C" network create --help 2>&1 | grep -- '--internal')"
  echo "## after: services with no container"
  /bin/sleep 5; services_footprint "services after"
  stop
}

teardown() { stop; rm -rf "$ROOT"; echo "    ✓ removed $ROOT"; }

case "${1:-}" in
  install) install ;;
  measure) measure ;;
  stop) stop ;;
  teardown) teardown ;;
  *) die "usage: container-trial.sh install|measure|stop|teardown" ;;
esac
