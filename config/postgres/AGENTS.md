# config/postgres

One server, the bare Homebrew `postgresql@18`, as code: `config/postgres/cluster.yaml` declares
settings, client auth, roles (passwords as `op://` refs via `secrets-run`), databases, grants,
schemas, extensions. `make pg-plan` / `make pg-apply` converge it (idempotent, never drops);
`make pg-fresh-build` proves a fresh cluster from it plus a restore equals the live one;
`scripts/pg-cutover.sh` is the rehearsed move onto it (`--detach`: it stops the factory's own
database). Never Docker, never on the external SSD. `docs/postgres.md`.
It runs at launchd's Interactive ProcessType (priority 31, not the throttled 20); brew drops the key on every restart/upgrade, so `make pg-process-type` re-pins the file (`make setup` runs it) and the reload is a host-lane step: `docs/postgres.md` §Process type.
