# The mini's one Postgres

One Postgres server on the mini: the Homebrew `postgresql@18` (launchd `sh.brew.postgresql@18`),
bare, data directory on the internal disk (`/opt/homebrew/var/postgresql@18`). Not Docker: weatherorb
needs PostGIS, the software factory must not depend on a VM and its ssh port forward, and a bare
server costs no VM memory. Owner decision of 2026-11-14, issue 1119. An unplugged external SSD must
never stop it, so its data never moves there.

| | |
|-|-|
| Declaration | `config/postgres/cluster.yaml`: settings, client auth, roles and their password refs, databases, privileges, provisioned schemas, extensions, default privileges |
| Converge | `make pg-plan` (what would change, no secrets shown) · `make pg-apply` (idempotent) · `scripts/pg-cluster.ts` |
| Prove | `make pg-fresh-build`: a scratch cluster built from the declaration plus a restore of every database must equal the live ones |
| Move | `scripts/pg-cutover.sh` (`make pg-rollback-drill`, `make pg-cutover`), §Cutover |
| Backup | the nightly dump to the HomeLab (vps `scripts/backup-pg-dev.sh`, `com.jkrumm.vps-pg-backup`); restic on the HomeLab covers its target directory |

## Who connects, and how

| Database | Owner | Clients | Auth |
|-|-|-|-|
| `shared` | superuser | software-factory (`factory`), argo (`argo`), agw's usage ledger (`usage`): one schema per writer | TCP 127.0.0.1:5432, scram |
| `agent_workflows` | `agent_workflows` | agent-workflows; argo reads as `argo_agw_ro` | TCP, scram |
| `postgres` | superuser | the vps prod mirror's schemas (`make restore-local`) | TCP, scram |
| `spike_s1` | superuser | none (agent-workflows' finished runtime spike, kept) | - |
| `athena` | `athena_owner` | Athena teamchat as `athena_app` | peer over `~/.local/state/athena/pgsock` (0700) |
| `weatherorb`, `weatherorb_dbos` | `weatherorb_owner` (PostGIS and pg_trgm stay the superuser's) | weatherorb (`weatherorb_owner`, `weatherorb_spots_ro`) | peer over `/tmp` (0700) |
| `weatherorb_<suite>_test_<id>` | superuser | weatherorb's tests: scratch databases, undeclared (reported as drift), the app roles log in by peer | peer over `/tmp` |
| `weatherorb_accounts_test` | superuser | weatherorb's accounts test | moves to a test container (weatherorb issue 1131) |

The superuser is the OS user that ran initdb. It logs in only over the unix sockets (trust; both
socket directories are 0700 sockets owned by that user), for admin, backups and this apply. TCP is
password-only. Peer maps the OS user to the app roles named in `ident`, so Athena and weatherorb
need no password at all; containers cannot reach a host socket.

Rules the loader enforces: every role in a grant is declared, a password is an `op://` ref or
`none`, no two roles share a ref, privileges are real privileges of their object type. Rules by
convention: one role per app, least privilege, no app logs in as the superuser.

## Apply

`make pg-apply` reads the live server over the socket and runs only what differs:

- Roles: created `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE`, connection limit as declared. A
  password is resolved through `secrets-run read`; the tool computes the SCRAM verifier itself and
  sends that, so the plaintext never reaches the server, its log or argv. A stored verifier that
  already matches is left alone, so a second apply changes nothing.
- Databases: created from `template0` with the declared locale; an existing database is never
  recreated (a locale difference is reported as drift). Database privileges and the grants on
  declared schemas converge exactly: extras are revoked. Default privileges are granted; extras are
  reported, not revoked (an app may set its own).
- Settings: `ALTER SYSTEM`, compared against `postgresql.auto.conf`. A restart-only setting is
  reported as pending.
- Address (`port`, `listen_addresses`, the socket directories) and `pg_hba.conf` / `pg_ident.conf`
  change only with `--address`, which is the cutover's step: earlier, an unplanned restart would
  take a port another server still holds. The new files are checked by the server
  (`pg_hba_file_rules`); a rejected file is put back.
- Undeclared roles and databases are reported, never dropped.

Flags (`PG_ARGS="..." make pg-apply`): `--port N` (5433 before the cutover), `--no-schemas` (roles,
databases and their privileges only: the state a restore starts from), `--roles-only`,
`--socket-dir`/`--data-dir` (a scratch cluster).

### Adding an app

1. The 1Password field (MacBook), its ref in `dotfiles-private/headless.refs`, `make
   secrets-reseal-request`; check `secrets-run read op://…` on the mini.
2. A role under `roles:` with that ref and a connection limit; the database or schema under
   `databases:` with its owner and grants.
3. `make pg-plan`, then `make pg-apply`; commit the YAML.

An app that runs as the OS user on the mini and needs no password can use peer instead: a `none`
role, an `ident` line and an `hba` line, like Athena.

## Proving a copy

`pg-cluster copy` moves one database and proves it. On the source it opens one `REPEATABLE READ`
transaction and exports its snapshot; `pg_dump --snapshot` dumps exactly that state while the same
transaction reads, per table, `count(*)` and a content hash (the sum of `hashtextextended` over
each row's text, with TimeZone, DateStyle, IntervalStyle, extra_float_digits and bytea_output
pinned so both servers print rows alike), every sequence's value, the number of large objects,
schema owners and grants, extensions, default privileges, and each relation's owner and ACL. The
dump is restored (`pg_restore --exit-on-error`, into a database with no tables), the same is read
from the copy, and any difference fails the copy and is named. The dump file is kept.

Sequences are not transactional: while the source is written, one can move between pg_dump's read
and the digest's. A rehearsal (`--live`) therefore accepts a copy's sequence at or below the
source's; the cutover copies a stopped source and compares them exactly. An extension's own
objects come from its install script and are left out of the relation comparison (a fresh PostGIS
install has a `simple_detail` type an upgraded one lacks).

## Cutover

`scripts/pg-cutover.sh` (every run logs and keeps its dumps under `~/.local/state/pg-cutover/<run>/`;
`--detach` runs it under nohup, because the software factory's own database is what it stops):

1. `fresh-build`: a scratch cluster on port 5499, `apply --no-schemas`, every declared database
   copied in from where it lives today (the Docker container, Athena's cluster, the bare server),
   each copy proven, then `plan` must say `in sync`. Reads the live servers only.
2. `rollback-drill`: drain the queue (best effort: an agent token is refused `queue set`, and the
   window then runs unannounced), stop the database clients (`com.jkrumm.software-factory`,
   `com.jkrumm.argo`, the agent-workflows host, audio and gateway) and Athena's server, stop the
   Docker container, switch the bare server to 5432, then roll back for real: the saved
   `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` back, the bare server on 5433, the
   container started unchanged, Athena's server started, the clients started and verified (factory
   health and CLI, `make -C agent-workflows verify`), the queue back to `run`.
3. `cutover`: the same, with the copies in the middle: the Docker databases made read-only
   (`default_transaction_read_only`, so a writer outside the stopped jobs, such as a lead's hook
   event, fails instead of writing after the copy's snapshot), the remaining client sessions on the
   container ended, `apply --no-schemas`, the four Docker databases and `athena` copied and proven
   (Athena's server started read-only for its copy), `plan` in sync, the container stopped, `apply
   --address`, the restart, both sockets answering, `plan` in sync on 5432, the clients started and
   verified, the queue back to `run`. Any failure runs the rollback above and drops the copies it
   made (their sources are untouched). It refuses while any client still holds a TCP connection
   to 5433.
4. `alias`: `/tmp/.s.PGSQL.5432` as a symlink to the 5433 socket, so a client moved to libpq's
   default socket (weatherorb) works before and after the switch. `/tmp` is cleared at boot, and a
   restart of the server on 5432 removes the link on shutdown: after a reboot or a manual restart
   before the cutover, run it again. The rollback restores it itself.

An apply converges database grants exactly, so a grant made by hand outside the declaration (an
app's own `make db-owner`) is revoked by the next apply, a drill's included. Put what an app needs
into `cluster.yaml`.

### Status (issue 1119, 2026-11-14)

Done: `fresh-build` passed (all 8 databases, zero differences, declaration in sync after the
restore); `rollback-drill` passed on the fourth run (switch to 5432 in 2 s, rollback with verified
clients in 55 s); the first three runs failed on real defects (smart shutdown under `kickstart -k`,
`unix_socket_directories` written as one element, Athena's smart shutdown holding its socket lock)
and each rolled back for real with the clients verified. The roles exist on the bare server; the
`/tmp/.s.PGSQL.5432` alias is in place; 122 leaked weatherorb test databases are dropped.

Open, in order: weatherorb issue 1131 moves its DSNs to the socket (the cutover refuses while a TCP
client holds 5433); vps issue 1132 points the nightly backup at whichever server is live; then
`make pg-cutover`; then the default Colima VM shrinks to 4 GiB with narrowed mounts; the teamchat
VM and Athena's script cleanup need Issues in the work repo epos-ai-teamchat-athena, which only
the owner can file (drafts: `~/.local/state/pg-cutover/work-repo-drafts/`).

Kept after the cutover, untouched: the Docker volume `vps_postgres-dev-data` and Athena's data
directory `~/.local/state/athena/pg18` (its launchd job disabled, not removed). They are removed in a
follow-up only after 7 days AND a restore from the HomeLab copy of the nightly dump is proven
(owner's rule). Rollback within those 7 days: stop the bare server's clients, `docker start
postgres`, `ALTER DATABASE <db> RESET default_transaction_read_only` for each of its four databases
(the cutover left them read-only), `launchctl enable` and bootstrap `com.iu.athena-postgres`,
restore the saved config from the cutover's run directory, restart the bare server. Writes made to
the bare server since the cutover are not in the old copies.

## Settings

Sized for a 32 GiB host shared with every agent, about 60 clients: `max_connections` 100,
`shared_buffers` 2 GB (weatherorb alone had 4 GB; the rest is the OS page cache),
`effective_cache_size` 8 GB, `work_mem` 16 MB, `maintenance_work_mem` 512 MB,
`max_locks_per_transaction` 1024 (the nightly dump holds one transaction over every table of a
database, and agent_workflows has one schema per tenant), `max_wal_size` 4 GB. The server's time
zone stays Europe/Berlin (weatherorb's and Athena's); the databases that came from the Docker
container keep the UTC they had there as a database setting.

## Data placement

Internal disk: this server's data directory, Docker and the Colima VM disk, swap, everything the
factory and the boot path need. External SSD: bulk data only, first weatherorb's raw data (its
`data/` and `products/` directories and `~/orb`, about 184 GB), behind the volume contract of the
plan rows `ssd-prep` and `ssd-adopt` (`docs/plan.yaml`).
