#!/usr/bin/env bash
# The move to the mini's one Postgres (docs/postgres.md §Cutover). Every verb logs to
# ~/.local/state/pg-cutover/<run>/run.log and keeps its dumps and reports there.
#
#   pg-cutover.sh fresh-build     a scratch cluster (port 5499) built from config/postgres/cluster.yaml,
#                                 every declared database restored into it from where it lives today,
#                                 each copy proven (pg-cluster copy), then a full apply must change
#                                 nothing. Live servers are only read. The scratch cluster is removed.
#   pg-cutover.sh rollback-drill  the cutover's stop-and-switch with a failure injected after the port
#                                 switch, so the rollback runs for real: drain, stop the DB clients and
#                                 Athena's server, stop the Docker container, move the bare server to
#                                 5432, then put everything back and verify. No data is copied.
#   pg-cutover.sh cutover         the real move: drain, stop the clients, copy the Docker databases and
#                                 Athena's into the bare server (proven), switch it to 5432, start, verify.
#                                 Any failure runs the rollback (the Docker container starts again unchanged).
#   pg-cutover.sh alias           /tmp/.s.PGSQL.5432 -> the bare server's 5433 socket, so a client moved to
#                                 the default socket (weatherorb) works before and after the cutover.
#
# Add --detach to run it under nohup, detached from the calling session (a lead's own Issue lives in
# the database this stops). Nothing here drops a source database or deletes a volume.
set -Eeuo pipefail

VERB="${1:-}"
shift || true
DETACH=0
for a in "$@"; do [ "$a" = "--detach" ] && DETACH=1; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGC=(bun "$HERE/pg-cluster.ts")
PGBIN=/opt/homebrew/opt/postgresql@18/bin
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STATE_ROOT="${PG_CUTOVER_STATE:-$HOME/.local/state/pg-cutover}"
BARE_DATA=/opt/homebrew/var/postgresql@18
OLD_PORT=5433
NEW_PORT=5432
ATHENA_SOCK="$HOME/.local/state/athena/pgsock"
ATHENA_DATA="$HOME/.local/state/athena/pg18"
ATHENA_LABEL=com.iu.athena-postgres
# The launchd jobs that hold connections to the Docker server (lsof on 2026-11-14).
CLIENT_LABELS=(com.jkrumm.software-factory com.jkrumm.argo com.jkrumm.agent-workflows-host com.jkrumm.agent-workflows-audio com.jkrumm.agent-workflows-gateway)
DOCKER_DBS=(postgres shared agent_workflows spike_s1)
UID_GUI="gui/$(id -u)"

case "$VERB" in fresh-build | rollback-drill | cutover | alias) ;; *)
  sed -n '2,24p' "${BASH_SOURCE[0]}"
  exit 2
  ;;
esac

if [ "$DETACH" = 1 ]; then
  mkdir -p "$STATE_ROOT"
  out="$STATE_ROOT/detached-$VERB-$(date +%Y%m%dT%H%M%S).log"
  nohup "${BASH_SOURCE[0]}" "$VERB" >"$out" 2>&1 </dev/null &
  echo "detached pid $! — log $out"
  exit 0
fi

RUN="$STATE_ROOT/$(date +%Y%m%dT%H%M%S)-$VERB"
mkdir -p "$RUN"
chmod 700 "$STATE_ROOT" "$RUN"
exec > >(tee -a "$RUN/run.log") 2>&1
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "FAIL: $*"; exit 1; }

docker_user() { secrets-run read op://vps/config/POSTGRES_USER; }
DOCKER_PW_REF=op://mini/vps-dev/POSTGRES_PASSWORD

wait_ready() { # wait_ready <socket dir> <port> <seconds>
  local i
  for ((i = 0; i < $3; i++)); do
    "$PGBIN/pg_isready" -q -h "$1" -p "$2" && return 0
    sleep 1
  done
  return 1
}

brew_pg_label() { # the launchd label brew gave postgresql@18 (sh.brew.* since Homebrew 6)
  # shellcheck source=lib/brew-service.sh
  . "$HERE/lib/brew-service.sh"
  brew_service_label postgresql@18
}

# Never `launchctl kickstart -k`: its SIGTERM is Postgres's smart shutdown, which waits for every
# client to leave; launchd then starts a second postmaster beside it ("pre-existing shared memory
# block is still in use") and at last SIGKILLs the first, so the next start runs crash recovery
# (drill of 2026-11-14). A fast shutdown ends the sessions and checkpoints cleanly; brew's plist
# restarts only on a crash (KeepAlive Crashed), so the start is an explicit kickstart.
restart_bare() {
  local label i
  label=$(brew_pg_label)
  log "restart the bare server ($label): fast shutdown, then start"
  if "$PGBIN/pg_ctl" -D "$BARE_DATA" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$BARE_DATA" -m fast -w -t 120 stop >/dev/null || return 1
  fi
  for ((i = 0; i < 30; i++)); do
    launchctl print "$UID_GUI/$label" 2>/dev/null | grep -q 'state = running' || break
    sleep 1
  done
  launchctl kickstart "$UID_GUI/$label"
}

# --------------------------------------------------------------- alias
if [ "$VERB" = alias ]; then
  target=/tmp/.s.PGSQL.$OLD_PORT
  link=/tmp/.s.PGSQL.$NEW_PORT
  if [ -S "$link" ] && [ ! -L "$link" ]; then log "$link is a real socket: the cutover is done, no alias needed"; exit 0; fi
  [ -S "$target" ] || die "$target is missing: the bare server is not on $OLD_PORT"
  ln -sfn "$target" "$link"
  "$PGBIN/pg_isready" -h /tmp -p "$NEW_PORT" || die "the alias does not answer"
  log "alias $link -> $target"
  exit 0
fi

# --------------------------------------------------------------- fresh-build
if [ "$VERB" = fresh-build ]; then
  SCRATCH="$RUN/fresh"
  PORT=5499
  mkdir -p "$SCRATCH"
  cleanup() {
    "$PGBIN/pg_ctl" -D "$SCRATCH/data" -m fast stop >/dev/null 2>&1 || true
    rm -rf "$SCRATCH/data"
  }
  trap cleanup EXIT
  log "initdb a scratch cluster in $SCRATCH (port $PORT)"
  "$PGBIN/initdb" -D "$SCRATCH/data" -U "$(id -un)" -E UTF8 --locale=en_US.UTF-8 -A trust >/dev/null
  "$PGBIN/pg_ctl" -D "$SCRATCH/data" -l "$SCRATCH/server.log" -w \
    -o "-p $PORT -k $SCRATCH -c listen_addresses='' -c shared_buffers=256MB -c max_locks_per_transaction=1024" start >/dev/null
  SC=(--port "$PORT" --socket-dir "$SCRATCH" --data-dir "$SCRATCH/data")
  CP=("${PGC[@]}" copy --live "${SC[@]}")
  log "apply --no-schemas (roles, databases, privileges)"
  "${PGC[@]}" apply "${SC[@]}" --no-schemas
  DU=$(docker_user)
  for db in "${DOCKER_DBS[@]}"; do
    log "copy $db from the Docker server"
    "${CP[@]}" --db "$db" --from-host 127.0.0.1 --from-port "$NEW_PORT" --from-user "$DU" --from-password-ref "$DOCKER_PW_REF" --keep-dir "$RUN/dumps" | tee "$RUN/copy-$db.json"
  done
  log "copy athena from Athena's cluster"
  "${CP[@]}" --db athena --from-host "$ATHENA_SOCK" --from-port 5432 --from-user postgres --keep-dir "$RUN/dumps" | tee "$RUN/copy-athena.json"
  for db in weatherorb weatherorb_dbos weatherorb_accounts_test; do
    log "copy $db from the bare server"
    "${CP[@]}" --db "$db" --from-host /tmp --from-port "$OLD_PORT" --from-user "$(id -un)" --keep-dir "$RUN/dumps" | tee "$RUN/copy-$db.json"
  done
  log "full apply after the restores: the declaration must already hold"
  "${PGC[@]}" plan "${SC[@]}" | tee "$RUN/plan-after-restore.txt"
  grep -q '^plan: in sync' "$RUN/plan-after-restore.txt" || die "the restored cluster differs from the declaration (above)"
  log "fresh-build PASSED: every copy proven, the declaration holds after the restore. Reports: $RUN"
  exit 0
fi

# --------------------------------------------------------------- cutover and rollback-drill
STOPPED=()
ATHENA_STOPPED=0
DOCKER_STOPPED=0
SWITCHED=0
ALIAS=0
SOURCE_READONLY=0
docker_su() { docker exec postgres psql -U "$(docker_user)" -d postgres -At "$@"; }
COPIED=()
DONE=0

start_clients() {
  local l
  # ${a[@]+...}: macOS's bash 3.2 treats an empty array as unbound under set -u
  for l in ${STOPPED[@]+"${STOPPED[@]}"}; do
    log "start $l"
    launchctl bootstrap "$UID_GUI" "$HOME/Library/LaunchAgents/$l.plist" 2>/dev/null || launchctl kickstart "$UID_GUI/$l" || log "WARN: $l did not start"
  done
  STOPPED=()
}

verify_clients() { # the DB clients answer: the factory's health and CLI, agw's own verify
  local i ok=0
  for ((i = 0; i < 60; i++)); do
    curl -fsS --max-time 5 http://127.0.0.1:7793/health >/dev/null 2>&1 && { ok=1; break; }
    sleep 2
  done
  [ "$ok" = 1 ] || return 1
  # the CLI reaches the server, which reads the database; a fresh server answers /health before
  # its first read is fast (drill of 2026-11-14 timed out once), so give it two minutes
  ok=0
  for ((i = 0; i < 12; i++)); do
    factory --format json read flow >/dev/null 2>&1 && { ok=1; break; }
    sleep 10
  done
  [ "$ok" = 1 ] || { factory --format json read flow >/dev/null; return 1; }
  make -C "$HOME/SourceRoot/agent-workflows" verify || return 1
  make -C "$HOME/SourceRoot/software-factory" verify || log "WARN: software-factory make verify failed (above); its health and CLI answer"
  return 0
}

rollback() {
  [ "$DONE" = 1 ] && return
  set +e
  log "ROLLBACK"
  if [ "$SWITCHED" = 1 ]; then
    log "put the bare server back on $OLD_PORT with its saved config"
    cp "$RUN/saved/postgresql.auto.conf" "$RUN/saved/pg_hba.conf" "$RUN/saved/pg_ident.conf" "$BARE_DATA/"
    restart_bare
    wait_ready /tmp "$OLD_PORT" 60 || log "WARN: the bare server does not answer on $OLD_PORT"
    # the 5432 server removed its socket on shutdown, and with it the alias weatherorb connects through
    if [ "$ALIAS" = 1 ]; then ln -sfn "/tmp/.s.PGSQL.$OLD_PORT" "/tmp/.s.PGSQL.$NEW_PORT" && log "alias /tmp/.s.PGSQL.$NEW_PORT restored"; fi
    SWITCHED=0
  fi
  for db in ${COPIED[@]+"${COPIED[@]}"}; do
    log "drop the copy $db from the bare server (its source is untouched)"
    "$PGBIN/dropdb" -h /tmp -p "$OLD_PORT" --if-exists --force "$db"
    # the maintenance database was empty before the copy (preflight checks it): recreate it empty
    [ "$db" = postgres ] && "$PGBIN/createdb" -h /tmp -p "$OLD_PORT" -T template0 postgres
  done
  if [ "$DOCKER_STOPPED" = 1 ]; then
    log "start the Docker container again, unchanged"
    docker start postgres
    for _ in $(seq 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' postgres)" = healthy ] && break; sleep 2; done
    DOCKER_STOPPED=0
  fi
  if [ "$SOURCE_READONLY" = 1 ]; then
    log "make the Docker databases writable again"
    for db in "${DOCKER_DBS[@]}"; do docker_su -c "ALTER DATABASE \"$db\" RESET default_transaction_read_only"; done
    SOURCE_READONLY=0
  fi
  if [ "$ATHENA_STOPPED" = 1 ] && "$PGBIN/pg_ctl" -D "$ATHENA_DATA" status >/dev/null 2>&1; then
    # the read-only copy instance, or one still in a smart shutdown, holds the data dir;
    # launchd's would crash-loop beside it
    log "stop the Athena postmaster still holding its data dir"
    "$PGBIN/pg_ctl" -D "$ATHENA_DATA" -m fast -w -t 60 stop >/dev/null
  fi
  if [ "$ATHENA_STOPPED" = 1 ]; then
    log "start Athena's cluster again"
    launchctl enable "$UID_GUI/$ATHENA_LABEL"
    launchctl bootstrap "$UID_GUI" "$HOME/Library/LaunchAgents/$ATHENA_LABEL.plist"
    wait_ready "$ATHENA_SOCK" 5432 30 || log "WARN: Athena's cluster does not answer"
    ATHENA_STOPPED=0
  fi
  start_clients
  if verify_clients; then
    ROLLBACK_OK=1
    log "rollback verified: the clients answer on the Docker server"
  else
    log "WARN: rollback done, but a client check failed (above)"
  fi
  undrain
  DONE=1
}
ROLLBACK_OK=0
DRAINED=0
undrain() {
  [ "$DRAINED" = 1 ] || return 0
  factory queue set run >/dev/null 2>&1 && { DRAINED=0; log "queue: run"; } || log "WARN: could not set the queue back to run"
}
# Exit explicitly: a failure inside `a || { ...; false; }` runs the ERR trap but does not stop a
# set -e script (drill of 2026-11-14 rolled back, then went on as if switched).
trap 'rollback; log "FAILED after rollback (above)"; exit 1' ERR INT TERM

log "preflight"
[ "$(docker inspect -f '{{.State.Status}}' postgres)" = running ] || die "the Docker container is not running; nothing to cut over"
"$PGBIN/pg_isready" -q -h /tmp -p "$OLD_PORT" || die "the bare server does not answer on $OLD_PORT"
wait_ready "$ATHENA_SOCK" 5432 1 || die "Athena's cluster does not answer"
if lsof -nP -iTCP:"$OLD_PORT" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1' | grep -q .; then
  [ "$VERB" = cutover ] && die "clients still connect over TCP to $OLD_PORT (weatherorb?); they lose the server at the switch. Move them to the socket first."
  log "WARN: TCP clients on $OLD_PORT will see a short gap"
fi
if [ "$VERB" = cutover ]; then
  n=$("$PGBIN/psql" -h /tmp -p "$OLD_PORT" -d postgres -Atc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'")
  [ "$n" = 0 ] || die "the bare server's postgres database is not empty ($n relations); the copy needs it empty"
fi
if [ -L "/tmp/.s.PGSQL.$NEW_PORT" ]; then ALIAS=1; fi
mkdir -p "$RUN/saved"
cp "$BARE_DATA/postgresql.auto.conf" "$BARE_DATA/pg_hba.conf" "$BARE_DATA/pg_ident.conf" "$RUN/saved/"

log "drain the queue"
# Best effort: an agent token may not set the queue state (403); the window then runs unannounced
# and leads that touch the factory meanwhile see a few minutes of errors (owner-accepted downtime).
if factory queue set drain >/dev/null 2>&1; then DRAINED=1; else log "WARN: factory queue set drain was refused; the window is not announced"; fi
for l in "${CLIENT_LABELS[@]}"; do
  if launchctl print "$UID_GUI/$l" >/dev/null 2>&1; then
    log "stop $l"
    STOPPED+=("$l")
    launchctl bootout "$UID_GUI/$l"
  fi
done
log "stop Athena's cluster (disabled so a login does not start it beside the one server)"
ATHENA_STOPPED=1
launchctl disable "$UID_GUI/$ATHENA_LABEL"
launchctl bootout "$UID_GUI/$ATHENA_LABEL"
# bootout's SIGTERM is a smart shutdown that waits for teamchat's sessions, and the lock file in
# the socket dir the one server takes over stays until it ends (third drill). Make it fast.
if "$PGBIN/pg_ctl" -D "$ATHENA_DATA" status >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$ATHENA_DATA" -m fast -w -t 60 stop >/dev/null
fi
[ ! -e "$ATHENA_DATA/postmaster.pid" ] || { log "Athena's server did not stop"; false; }

if [ "$VERB" = cutover ]; then
  # A client outside the stopped jobs (an agw CLI call) would write after the copy's snapshot.
  # Writers outside the stopped jobs exist (the second cutover attempt: lead sessions' hook events
  # moved two factory sequences mid-copy, and their rows would have been lost). Make the source
  # read-only, then end every session, so a stray write fails instead of vanishing.
  log "make the Docker databases read-only and end their sessions"
  SOURCE_READONLY=1
  for db in "${DOCKER_DBS[@]}"; do docker_su -c "ALTER DATABASE \"$db\" SET default_transaction_read_only = on"; done
  docker_su -c "SELECT datname, usename, pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()"
  # A full pg-apply before the cutover creates the declared databases with their schemas but no
  # tables (2026-11-14: one ran through the /tmp alias); a restore cannot create those schemas
  # again. Such a shell holds no data: drop it. A target with any table stops the cutover.
  # The maintenance database `postgres` gets the same treatment (its prod-mirror schemas, empty, stop
  # the restore just the same: first cutover attempt), recreated empty since it must exist.
  for db in postgres shared agent_workflows spike_s1 athena; do
    exists=$("$PGBIN/psql" -h /tmp -p "$OLD_PORT" -d template1 -Atc "SELECT count(*) FROM pg_database WHERE datname = '$db'")
    [ "$exists" = 1 ] || continue
    n=$("$PGBIN/psql" -h /tmp -p "$OLD_PORT" -d "$db" -Atc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'S', 'v', 'm') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'")
    [ "$n" = 0 ] || { log "$db on the bare server already holds $n relations; not a shell left by an apply"; false; }
    s=$("$PGBIN/psql" -h /tmp -p "$OLD_PORT" -d "$db" -Atc "SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname NOT IN ('information_schema', 'public')")
    [ "$s" = 0 ] && continue
    log "drop the empty shell $db on the bare server ($s schemas, no relations)"
    "$PGBIN/dropdb" -h /tmp -p "$OLD_PORT" --maintenance-db=template1 --force "$db"
    if [ "$db" = postgres ]; then "$PGBIN/createdb" -h /tmp -p "$OLD_PORT" --maintenance-db=template1 -T template0 postgres; fi
  done
  log "apply --no-schemas on the bare server: roles, empty databases, privileges"
  "${PGC[@]}" apply --port "$OLD_PORT" --no-schemas
  DU=$(docker_user)
  for db in "${DOCKER_DBS[@]}"; do
    COPIED+=("$db")
    log "copy $db"
    "${PGC[@]}" copy --port "$OLD_PORT" --db "$db" --from-host 127.0.0.1 --from-port "$NEW_PORT" --from-user "$DU" --from-password-ref "$DOCKER_PW_REF" --keep-dir "$RUN/dumps" | tee "$RUN/copy-$db.json"
  done
  log "start Athena's cluster read-only for its copy"
  "$PGBIN/pg_ctl" -D "$ATHENA_DATA" -l "$RUN/athena-copy.log" -w -o "-c default_transaction_read_only=on" start >/dev/null
  COPIED+=(athena)
  "${PGC[@]}" copy --port "$OLD_PORT" --db athena --from-host "$ATHENA_SOCK" --from-port 5432 --from-user postgres --keep-dir "$RUN/dumps" | tee "$RUN/copy-athena.json"
  "$PGBIN/pg_ctl" -D "$ATHENA_DATA" -m fast -w stop >/dev/null
  log "full apply: schemas and default privileges must already hold"
  "${PGC[@]}" plan --port "$OLD_PORT" | tee "$RUN/plan-after-restore.txt"
  grep -q '^plan: in sync' "$RUN/plan-after-restore.txt" || { log "the restored databases differ from the declaration"; false; }
fi

log "stop the Docker container (volume untouched)"
DOCKER_STOPPED=1
docker stop postgres >/dev/null
log "switch the bare server to $NEW_PORT"
[ -L "/tmp/.s.PGSQL.$NEW_PORT" ] && rm -f "/tmp/.s.PGSQL.$NEW_PORT"
SWITCHED=1
"${PGC[@]}" apply --port "$OLD_PORT" --address
restart_bare
wait_ready /tmp "$NEW_PORT" 60 || { log "the bare server does not answer on $NEW_PORT"; false; }
wait_ready "$ATHENA_SOCK" "$NEW_PORT" 5 || { log "no socket in Athena's directory"; false; }
log "the one server answers on $NEW_PORT (TCP and both sockets)"

if [ "$VERB" = rollback-drill ]; then
  log "drill: injecting the failure now"
  trap - ERR
  rollback
  [ "$ROLLBACK_OK" = 1 ] || die "drill: the rollback did not verify"
  log "rollback-drill PASSED: switched to $NEW_PORT, rolled back, clients verified on the Docker server. Reports: $RUN"
  exit 0
fi

"${PGC[@]}" plan --port "$NEW_PORT" | tee "$RUN/plan-after-switch.txt"
grep -q '^plan: in sync' "$RUN/plan-after-switch.txt" || { log "the switched server differs from the declaration"; false; }
start_clients
verify_clients || { log "client verification failed"; false; }
undrain
DONE=1
log "cutover PASSED. Docker volume vps_postgres-dev-data (its databases left read-only) and Athena's data dir are kept 7 days. Reports: $RUN"
