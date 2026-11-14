#!/usr/bin/env bash
# kiri-trial — the measurements of docs/kiri-trial.md, one step per call (make kiri-trial STEP=…).
#
#   a [ALLOC_MIB]   memory returned while running: footprint at rest, at the peak, +2 and +10 min
#   b               sleep and wake: seconds to no VM process, `docker ps` and `run` from asleep, compose to healthy
#   c-mariadb | c-linewatch | c-internal | c-tun | c-restart     our compose shapes under other names and ports
#   d               bind-mount speed on kiri and Colima
#   e               what it installed and opened
#   sample          one line of the long-running mariadb copy: VM footprint, health, restarts (cron-free 48 h reading)
#
# Every kiri command names --context kiri; Colima is only read (ps, the d step's scratch bind). Output
# goes to stdout and to ~/.local/state/kiri-trial/<step>-<time>.log. Never sudo.
set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
T="$DOTFILES_DIR/kiri/trial"
OUT="$HOME/.local/state/kiri-trial"
mkdir -p "$OUT"
DK=(docker --context kiri)
DC=(docker --context colima)
IMG=alpine:3.20
PY=python:3.13-alpine

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
since() { perl -e "printf '%.1f', $(now) - $1"; }

# The kiri VM is the Virtualization XPC process that holds kiri's guest kernel open (every VM is a
# child of launchd, so the parent says nothing; a Colima VM holds its disk under ~/.colima instead).
vm_pid() {
  local p
  for p in $(pgrep -f '^/System/Library/Frameworks/Virtualization.framework/.*VirtualMachine'); do
    lsof -p "$p" 2>/dev/null | grep -q 'Kiri.app/Contents/Resources/guest/Image' && { echo "$p"; return 0; }
  done
  return 1
}

# Physical footprint in MiB, as `top` reports it (the Report's command: top -l 1 -pid <pid> -stats pid,mem).
foot() {
  local pid="$1" v
  v=$(top -l 1 -pid "$pid" -stats pid,mem 2>/dev/null | awk -v p="$pid" '$1==p{print $2}')
  [ -n "$v" ] || { echo "-"; return; }
  echo "$v" | awk '{u=$0; sub(/[^0-9.].*$/,"",$0); n=$0+0; if (u ~ /G/) n*=1024; else if (u ~ /K/) n/=1024; else if (u ~ /M/) n=n; else n/=1048576; printf "%d", n}'
}

reading() {   # label
  local pid; pid=$(vm_pid) || { echo "  $1: no VM process"; return; }
  echo "  $1: pid=$pid footprint=$(foot "$pid") MiB"
}

wait_asleep() {   # seconds until no VM process (cap 300)
  local t0 i; t0=$(now)
  for i in $(seq 1 300); do vm_pid >/dev/null || { since "$t0"; return 0; }; /bin/sleep 1; done
  echo ">300"
}

log() { local f; f="$OUT/$1-$(date +%Y%m%dT%H%M%S).log"; shift; "$@" 2>&1 | tee "$f"; echo "log: $f"; }

step_a() {
  local alloc="${1:-2048}"
  echo "# a: memory returned while running (ceiling $(launchctl print "gui/$(id -u)/com.jkrumm.kiri" 2>/dev/null | awk '/KIRI_MEMORY_MIB/{print $3}') MiB, allocation $alloc MiB)"
  "${DK[@]}" rm -f kiri-keeper kiri-alloc >/dev/null 2>&1
  "${DK[@]}" run -d --name kiri-keeper "$IMG" sleep 86400 >/dev/null
  /bin/sleep 30
  reading "rest (keeper only, +30 s)"
  "${DK[@]}" exec kiri-keeper free -m | sed 's/^/    guest: /'
  "${DK[@]}" run -d --name kiri-alloc "$PY" python -c "import time; b=b'\\x01'*($alloc<<20); time.sleep(40)" >/dev/null
  local peak=0 pid f i
  for i in $(seq 1 14); do
    /bin/sleep 3
    pid=$(vm_pid) || continue
    f=$(foot "$pid"); [ "$f" != "-" ] && [ "$f" -gt "$peak" ] && peak=$f
  done
  echo "  peak: footprint=$peak MiB (max of 14 samples over 42 s)"
  "${DK[@]}" exec kiri-keeper free -m | sed 's/^/    guest: /'
  "${DK[@]}" wait kiri-alloc | sed 's/^/  alloc exit code: /'
  "${DK[@]}" rm -f kiri-alloc >/dev/null
  local t0; t0=$(now)
  reading "just after the allocation ended"
  /bin/sleep 120; reading "+2 min after"
  "${DK[@]}" exec kiri-keeper free -m | sed 's/^/    guest: /'
  /bin/sleep 480; reading "+10 min after"
  "${DK[@]}" exec kiri-keeper free -m | sed 's/^/    guest: /'
  "${DK[@]}" rm -f kiri-keeper >/dev/null
  echo "  (elapsed since the allocation ended: $(since "$t0") s)"
}

step_b() {
  echo "# b: sleep and wake"
  # Any running container keeps the VM awake: stop the mariadb copy (a stopped compose project is the third measurement).
  "${DK[@]}" compose -p kiri-trial-mariadb -f "$T/mariadb.compose.yml" stop >/dev/null 2>&1
  "${DK[@]}" rm -f kiri-keeper kiri-alloc kiri-probe >/dev/null 2>&1
  "${DK[@]}" run --rm "$IMG" true >/dev/null
  echo "  seconds from the last container's exit to no VM process: $(wait_asleep)"
  local t0; t0=$(now)
  "${DK[@]}" ps >/dev/null
  echo "  docker ps from asleep: $(since "$t0") s; VM process after it: $(vm_pid >/dev/null && echo yes || echo no)"
  t0=$(now)
  "${DK[@]}" run --rm "$IMG" true >/dev/null
  echo "  docker run --rm alpine true from asleep (wake + start): $(since "$t0") s"
  # compose project: stopped, asleep, up --wait
  if "${DK[@]}" compose -p kiri-trial-mariadb -f "$T/mariadb.compose.yml" ps -a --format '{{.Name}}' | grep -q mariadb; then
    "${DK[@]}" compose -p kiri-trial-mariadb -f "$T/mariadb.compose.yml" stop >/dev/null
    echo "  mariadb project stopped; seconds to no VM process: $(wait_asleep)"
    t0=$(now)
    "${DK[@]}" compose -p kiri-trial-mariadb -f "$T/mariadb.compose.yml" up -d --wait >/dev/null
    echo "  stopped compose project (mariadb, healthcheck) from asleep to healthy: $(since "$t0") s"
  else
    echo "  (no mariadb project: run c-mariadb first)"
  fi
}

step_c_mariadb() {
  echo "# c: vps dev mariadb shape (healthcheck, named volume, loopback port 23306)"
  local t0; t0=$(now)
  "${DK[@]}" compose -p kiri-trial-mariadb -f "$T/mariadb.compose.yml" up -d --wait 2>&1 | tail -5
  echo "  up --wait: $(since "$t0") s, exit ${PIPESTATUS[0]}"
  "${DK[@]}" ps --filter name=kiri-trial-mariadb --format '  {{.Names}} {{.Status}} {{.Ports}}'
  "${DK[@]}" exec kiri-trial-mariadb mariadb -uroot -ptrial-only-not-a-secret -e "create table if not exists trial.t(i int); insert into trial.t values (1); select count(*) as rows_ from trial.t" 2>&1 | sed 's/^/  sql: /'
  echo "  from the Mac on 127.0.0.1:23306: $( (exec 3<>/dev/tcp/127.0.0.1/23306 && head -c 20 <&3 | strings | head -1) 2>&1 )"
}

step_c_linewatch() {
  echo "# c: linewatch shape (build, healthcheck, named volume, loopback port 17731); a copy at HEAD under another project"
  local src="$HOME/SourceRoot/linewatch" work
  work=$(mktemp -d "${TMPDIR:-/tmp}/kiri-linewatch.XXXXXX")
  git -C "$src" archive HEAD | tar -x -C "$work"
  echo "LINEWATCH_TOKEN=trial-only-not-a-secret" > "$work/.env"   # the app refuses to start without a bearer token
  sed -i '' -e 's|container_name: linewatch|container_name: kiri-trial-linewatch|' \
            -e "s|127.0.0.1:7731:7731|127.0.0.1:17731:7731|" \
            -e 's|linewatch-data:/app/data|kiri-trial-linewatch-data:/app/data|' \
            -e 's|^  linewatch-data:|  kiri-trial-linewatch-data:|' \
            -e 's|name: linewatch-data|name: kiri-trial-linewatch-data|' \
            -e '/external: true/d' "$work/docker-compose.yml"
  "${DK[@]}" volume create kiri-trial-linewatch-data >/dev/null
  # linewatch's `make up` chowns the volume to the image's app user (999) before the first start; so do we.
  # FINDING (kiri 0.2.0): on an EMPTY named volume the root's owner and mode are reset to root:root 0755
  # every time a container mounts it, so linewatch's chown is gone by the first start and the app dies with
  # SQLITE_CANTOPEN (src/db/client.ts:130). With any file in the volume the chown persists; hence the .keep.
  # LINEWATCH_NO_KEEP=1 reproduces the failure.
  "${DK[@]}" run --rm -v kiri-trial-linewatch-data:/d "$IMG" sh -c "[ \"${LINEWATCH_NO_KEEP:-0}\" = 1 ] || touch /d/.keep; chown -R 999:999 /d"
  local t0; t0=$(now)
  "${DK[@]}" compose -p kiri-trial-linewatch -f "$work/docker-compose.yml" up -d --build --wait 2>&1 | tail -15
  echo "  build + up --wait: $(since "$t0") s, exit ${PIPESTATUS[0]}"
  "${DK[@]}" ps --filter name=kiri-trial-linewatch --format '  {{.Names}} {{.Status}} {{.Ports}}'
  echo "  /health from the Mac: $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:17731/health)"
  echo "  (work dir kept for the teardown: $work)"; echo "$work" > "$OUT/linewatch-work"
}

step_c_internal() {
  echo "# c: internal network, outside only through the proxy container"
  local p=(compose -p kiri-trial-internal -f "$T/internal.compose.yml")
  "${DK[@]}" "${p[@]}" up -d 2>&1 | tail -4
  /bin/sleep 3
  echo "  direct to the outside from the internal-only client (must FAIL):"
  "${DK[@]}" "${p[@]}" exec -T client wget -T 5 -qO- http://1.1.1.1/ 2>&1 | head -2 | sed 's/^/    /'
  echo "  exit: ${PIPESTATUS[0]}"
  echo "  through the proxy (must answer HTTP):"
  "${DK[@]}" "${p[@]}" exec -T client wget -T 10 -qO- --header "Host: example.com" http://proxy:8080/ 2>&1 | head -3 | sed 's/^/    /'
  echo "  exit: ${PIPESTATUS[0]}"
  "${DK[@]}" network inspect kiri-trial-internal_inner --format '  inner internal={{.Internal}}'
  "${DK[@]}" "${p[@]}" down -v >/dev/null 2>&1
}

step_c_tun() {
  echo "# c: NET_ADMIN and /dev/net/tun"
  local p=(compose -p kiri-trial-tun -f "$T/tun.compose.yml")
  "${DK[@]}" "${p[@]}" up -d 2>&1 | tail -3
  /bin/sleep 12
  "${DK[@]}" "${p[@]}" logs 2>&1 | tail -6 | sed 's/^/  /'
  "${DK[@]}" "${p[@]}" down -v >/dev/null 2>&1
}

step_c_restart() {
  echo "# c: restart unless-stopped across a daemon restart and across a VM sleep"
  local p=(compose -p kiri-trial-restart -f "$T/restart.compose.yml")
  "${DK[@]}" "${p[@]}" up -d 2>&1 | tail -2
  /bin/sleep 5
  echo "  start #: $("${DK[@]}" "${p[@]}" logs 2>&1 | tail -1)"
  echo "  VM stays awake for 150 s with a running unless-stopped container? asleep after: $(/bin/sleep 150; vm_pid >/dev/null && echo 'no, still awake' || echo 'YES, slept')"
  echo "  daemon restart (make kiri-down, kiri-up):"
  make -C "$DOTFILES_DIR" --no-print-directory kiri-down >/dev/null 2>&1
  /bin/sleep 3
  make -C "$DOTFILES_DIR" --no-print-directory kiri-up >/dev/null 2>&1
  /bin/sleep 15
  "${DK[@]}" ps -a --filter label=com.docker.compose.project=kiri-trial-restart --format '  {{.Names}} {{.Status}}'
  echo "  start #: $("${DK[@]}" "${p[@]}" logs 2>&1 | tail -1)"
  echo "  now docker stop (a user stop), the VM sleeps, then a daemon restart: must stay stopped"
  "${DK[@]}" "${p[@]}" stop >/dev/null
  echo "  seconds to no VM process: $(wait_asleep)"
  make -C "$DOTFILES_DIR" --no-print-directory kiri-down >/dev/null 2>&1; /bin/sleep 3
  make -C "$DOTFILES_DIR" --no-print-directory kiri-up >/dev/null 2>&1; /bin/sleep 5
  "${DK[@]}" ps -a --filter label=com.docker.compose.project=kiri-trial-restart --format '  {{.Names}} {{.Status}}'
  echo "  and docker start from asleep: $("${DK[@]}" "${p[@]}" start 2>&1 | tail -1); then:"
  /bin/sleep 5; echo "  start #: $("${DK[@]}" "${p[@]}" logs 2>&1 | tail -1)"
  "${DK[@]}" "${p[@]}" down -v >/dev/null 2>&1
}

step_d() {
  echo "# d: bind-mount speed (python:3.13-alpine, bindbench.py; 512 MiB sequential, 2000 x 4 KiB files)"
  local kdir="$HOME/.local/state/kiri-trial/bench" cdir="$HOME/.local/state/prometheus-scripts/kiri-bench"
  mkdir -p "$kdir/bench" "$cdir"
  cp "$T/bindbench.py" "$kdir/" && cp "$T/bindbench.py" "$cdir/"
  local i
  for i in 1 2; do
    echo "  kiri   run $i: $("${DK[@]}" run --rm -v "$kdir:/work" "$PY" python /work/bindbench.py 2>&1 | tail -1)"
    echo "  colima run $i: $("${DC[@]}" run --rm -v "$cdir:/work" "$PY" python /work/bindbench.py 2>&1 | tail -1)"
  done
  echo "  (kiri bind: $kdir; colima bind: $cdir, a scratch dir inside the VM's one writable non-company mount)"
  rm -rf "$cdir"
}

step_e() {
  echo "# e: what kiri installed and opened"
  local s="$HOME/kiri-trial-dl/snap"
  echo "## listening TCP, new since the snapshot (before the install):"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1,$9}' | sort -u > "$s/listen.now"
  diff "$s/listen.before" "$s/listen.now" | grep '^>' | sed 's/^/  /'
  echo "## UDP:"; lsof -nP -iUDP 2>/dev/null | awk 'NR>1{print $1,$9}' | sort -u > "$s/udp.now"; diff "$s/udp.before" "$s/udp.now" | grep '^>' | sed 's/^/  /'
  echo "## launchd labels new since the snapshot:"
  launchctl list | awk '{print $3}' | sort > "$s/launchctl.now"; diff "$s/launchctl.before" "$s/launchctl.now" | grep '^>' | sed 's/^/  /'
  echo "## plists new:"
  ls ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null | sort > "$s/plists.now"; diff "$s/plists.before" "$s/plists.now" | grep '^>' | sed 's/^/  /'
  echo "## new entries in the home directory:"
  ls -la ~ | awk '{print $9}' | sort > "$s/home.now"; diff "$s/home.before" "$s/home.now" | grep '^>' | sed 's/^/  /'
  echo "## ~/.kiri:"; du -sh ~/.kiri/* 2>/dev/null | sed 's/^/  /'
  echo "## rc files and docker config unchanged? (md5 before/after)"
  md5 -q ~/.docker/config.json ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc 2>/dev/null > "$s/rc.now"; diff -q "$s/rc.before" "$s/rc.now" && echo "  identical"
  echo "## docker contexts:"; docker context ls --format '  {{.Name}} {{.DockerEndpoint}}'
  echo "## /etc/resolver, /usr/local/bin/kiri, /var/run/docker.sock:"; ls -la /etc/resolver /usr/local/bin/kiri 2>&1 | sed 's/^/  /'; ls -la /var/run/docker.sock 2>&1 | sed 's/^/  /'
  echo "## mounts:"; mount | grep -i kiri | sed 's/^/  /'
  echo "## processes:"; ps -axo pid,rss,command | grep -E 'kiri|Virtualization' | grep -v grep | cut -c1-140 | sed 's/^/  /'
  echo "## the shares: a container that binds the VM's /mnt/mac sees the Mac (names only, listing /Users and nothing below it)"
  "${DK[@]}" run --rm -v /mnt/mac:/h:ro "$IMG" sh -c 'ls /h; echo ---; ls /h/Users' 2>&1 | sed 's/^/  /'
  echo "## settings that narrow MAC_SHARES (source, v0.2.0):"
  rg -n "MAC_SHARES|mac_shared" "$HOME/kiri-trial-dl/src/crates" -g '*.rs' 2>/dev/null | sed 's/^/  /' | head -12
}

step_sample() {
  local pid; pid=$(vm_pid 2>/dev/null) || pid=""
  local fp="asleep"; [ -n "$pid" ] && fp="$(foot "$pid") MiB"
  echo "$(date -u +%FT%TZ) vm=$fp health=$("${DK[@]}" inspect kiri-trial-mariadb --format '{{.State.Health.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}' 2>&1) daemon_rss_kb=$(ps -o rss= -p "$(pgrep -f 'kiri daemon' | head -1)" 2>/dev/null)"
}

case "${1:-}" in
  a) log a step_a "${2:-2048}" ;;
  b) log b step_b ;;
  c-mariadb) log c-mariadb step_c_mariadb ;;
  c-linewatch) log c-linewatch step_c_linewatch ;;
  c-internal) log c-internal step_c_internal ;;
  c-tun) log c-tun step_c_tun ;;
  c-restart) log c-restart step_c_restart ;;
  d) log d step_d ;;
  e) log e step_e ;;
  sample) step_sample ;;
  *) echo "usage: kiri-trial.sh a|b|c-mariadb|c-linewatch|c-internal|c-tun|c-restart|d|e|sample" >&2; exit 2 ;;
esac
