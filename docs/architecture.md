---
type: Reference
title: Architecture — the whole environment on one page
tags:
  - engineering
  - infrastructure
timestamp: 2026-09-07
description: The whole personal environment on one page — the owner's mental model (what each machine and surface is FOR), then the asserted reference tables — machines, repos, launchd jobs and their owner repos, inbound doors, secrets flow, monitoring. Lives in dotfiles/docs and is symlinked into the brain vault.
---

# Architecture — the whole environment on one page

> The map: every machine, every repo on it, every launchd job and its owner repo,
> every inbound door, the secrets flow, and what monitors what. The rule it
> enforces — **anything running on a machine appears here or gets deleted** — is
> asserted by `scripts/architecture-check.sh` (run by `make doctor`): a launchd
> label loaded or on disk with no row here exits 1.

## The mental model

Six boxes, each with one job; the *why* only — depth lives behind the links.

- **Mac mini — the always-on dev host.** Every agent and LaunchAgent runs here. It never sleeps and has no UI of its own.
- **MacBook and iPhone — the UI layer.** No durable state. The MacBook runs the Herdr app (a window on the mini's core) plus biometric 1Password; the iPhone is Collie in a browser tab. Closing the lid ends a *connection*, never the work.
- **Windows onto the mini.** The Herdr app (live terminals), Slack `#agents` (Hermes's channel), Argo `/agents` (the durable record), the brain reader, Collie (the only one that can *act*).
- **VPS — the mature production stack.** Traefik-fronted apps, ClickStack/HyperDX, its own crons. Nothing there depends on the mini; reached over Tailscale SSH.
- **HomeLab — his own container world**, plus the single Uptime Kuma every push monitor reports to.
- **Gateways — outsourced work** as submit-then-poll HTTP services: email-gateway. Detail: brain `gateways`.

**The agent platform** — one engine (agent-workflows),
one front door (Hermes), one cockpit (the Herdr app over herdr-core), the lanes (factory Issue, `@implementer`), one repo contract —
is specified in [`agent-platform.md`](agent-platform.md), which wins over any
older doc on that topic. This map only places its parts on machines.

## Diagrams

No diagram is current. The estate, agent-platform, dispatch-path and episode-lifecycle diagrams
described the warden-era platform; only `docs/archive/diagrams/agent-platform.html` is kept (see `docs/archive/README.md`); the text above and
[`agent-platform.md`](agent-platform.md) are the current map. A new one is a self-contained HTML
compiled from a `.json` spec with the vendored `archify` skill
(`node skills/archify/bin/archify.mjs deliver <type> <spec.json> <out.html> --quality showcase`),
which validates geometry before it delivers.

## Repos

### On both machines (sanctioned set)

| Repo | Purpose |
|-|-|
| `dotfiles` | Claude config, hooks, skills, machine bootstrap. Source of truth. |
| `dotfiles-private` | Secrets data half: refs lists, tailscale ACL + serve declarations. |
| `brain` | Obsidian vault — the deliberate second checkout, reconciled by brain-sync. |

### Mini-only (`~/SourceRoot`)

| Repo | Purpose | Notes |
|-|-|-|
| `argo` | Personal API + dashboard, the agent backbone | hosts the `/agents` overview + narratives feed; runs natively here since 2026-10-30 (`com.jkrumm.argo`, `~/.argo/releases/<sha>`, `make deploy` in the repo), shared Postgres database `shared` (schema `argo`, reads `usage`); still served at `argo.jkrumm.com`. The VPS containers are stopped (rollback kept) |
| `hermes-agent` | Hermes gateway — the narrate / answer / route front door (`docs/agent-platform.md`); files work as a GitHub issue (nothing works it automatically), 5-job cron layer | see [[agent-platform]] |
| `warden` | **Switched off 2026-10-27** (agent-workflows P0) — reference only. Was the autonomous triage/remediation loop and the only ledger (`~/.warden/warden.db`, final backup in `homelab:hdd/backups/warden-final/`). No LaunchAgent, no port, no caller; alerts go straight to Slack. Docs: `warden/DESIGN.md`, `warden/STATE.md`. Unattended work is a factory Issue |
| `agent-workflows` | The agent platform (public repo; concept in its `docs/concept.md`). Three processes: the host (HTTP on `127.0.0.1:7791`) and the audio process (`:7792`) from one release dir, and the inference gateway (`:7794`, own bundle). `GET /health` is unauthenticated (200 `ok` / 503 `degraded`), everything else bearer-gated. The gateway holds every provider key on the mini; agw itself holds none (§Secrets flow) | runs natively here from a release dir `~/.agent-workflows/releases/<sha>` (`current` symlink; origin/master exported by `make deploy`, never the main checkout) — `com.jkrumm.agent-workflows-host` and `com.jkrumm.agent-workflows-audio` run from it, the host via its `scripts/launch.sh` (zsh wrapper, `secrets-run`, `bun packages/host/src/main.ts`); store is Postgres database `agent_workflows` (journal schema `agw`) on the mini's maintained instance; CLI `~/.local/bin/agw` → `~/.agent-workflows/current/packages/cli/bin/agw.ts` |
| `iris` | Voice-memo server: a phone memo is uploaded as segments, transcribed, routed to Hermes, summarized and notified. Swift apps follow under `apple/` | runs natively here (`com.jkrumm.iris{,-deploy}`, deploy clone `~/.iris/app`, data `~/.iris/data`, `iris.mini.jkrumm.com`) |
| `ntfy-mac` | Native macOS client for ntfy servers, a public product (Swift, CLI-first). A factory project, `deploy.mode none`: users get it from its manual Release workflow | no server here; the mini builds it, the owner runs it on the MacBook (`make install-macbook`) |
| `email-gateway` | The gateway for all personal mail — Proton via the homelab's Bridge, Resend, later Gmail; send, sync, classify, read. Renamed from `bun-email-api` 2026-09-27; target in its `docs/vision.md` | container on the VPS (RollHook) |
| `basalt-ui-obsidian` | Obsidian plugin building the brain reader | |
| `home` | Apple Home control + diagnostics: HomeClaw (App Store Catalyst app, must run in the GUI session) and its `homeclaw-cli`, wrapped for agents and Tinycast | HomeClaw in `/Applications`; MacBook reaches it over SSH |
| `free-planning-poker`, `jkrumm.com`, `kobo-mods`, `rollhook`, `rollhook-action`, `modelpick`, `rb`, `usage-tracker`, `king-smith-walkingpad-mac`, `linewatch` | see each repo's own `AGENTS.md` | |
| `weatherorb` | weather/wave service, 11 templated LaunchAgents + 2 mother agents (legacy pattern, retired at weatherorb's next wave boundary) | the 11 are templated in `weatherorb/ops`, `make launchd-install` (idempotent; `FORCE=1` bounces all) |
| `dispatch-scratch` | disposable dispatch test target | by design |
| `homelab`, `homelab-private`, `vps` | server stacks, reached over Tailscale SSH | |

### MacBook-only

| Repo | Purpose |
|-|-|
| `shutterflow` | the photography app (photo-flow is discontinued) |
| `image-gateway` | the Tauri studio — a GUI app belongs on the machine with a human at it; it generates through agw's image door on the mini (the VPS gateway is retired) |
| `basalt-ui` | followed image-gateway when the studio consumed it as a `file:` dependency; every consumer now pins the published npm version, so this placement is convenience, not a requirement |
| `tinycast-extensions` | the personal Tinycast extension (TickTick, Claude usage, Netgear M2) — Tinycast and the router's LAN both live here |

## LaunchAgents — mini (gui/501 unless noted)

Every label here is asserted by `scripts/architecture-check.sh`, and a short fixed list of
boot-critical labels (six of about 25 KeepAlive jobs; the list is in `check_boot_path`) also by the heartbeat. Homebrew 6 writes
`sh.brew.<name>` on the next start/restart and deletes `homebrew.mxcl.<name>`
(both still `homebrew.mxcl.*` on the mini today); both names map to the same
row and `scripts/lib/brew-service.sh` resolves whichever exists.

### dotfiles

| Label | Schedule | What |
|-|-|-|
| `sh.brew.colima` | KeepAlive | Docker VM, bounded-retry wrapper — **supervised boot path** |
| `com.colima.docker-socket` | daemon (root) | `/var/run/docker.sock` symlink at boot |
| `com.jkrumm.maxvnodes` | daemon (root), RunAtLoad one-shot | `sysctl -w kern.maxvnodes=526336` (2x stock) at boot — the issue 1059 trial, see §kern.maxvnodes trial; `make maxvnodes-status`, rollback `make maxvnodes-teardown` |
| `sh.brew.caddy` | daemon (root) | local HTTPS + tailnet doors |
| `sh.brew.dnsmasq` | daemon (root) | `*.test` DNS |
| `sh.brew.tailscale` | daemon (root) | tailnet |
| `sh.brew.postgresql@18` | KeepAlive | the mini's one Postgres (weatherorb's today; takes the Docker container's and Athena's databases at the cutover, then 127.0.0.1:5432), declared in `config/postgres/cluster.yaml` — `docs/postgres.md` |
| `sh.brew.sleepwatcher` | KeepAlive | runs `~/.wakeup` |
| `com.jkrumm.brain-sync` | 300s | vault reconcile via GitHub |
| `com.jkrumm.brain-backup` | 03:30 daily | vault backup |
| `com.jkrumm.brain-web-refresh` | 300s | brain-web rebuild |
| `com.jkrumm.devhost-health` | 300s | the composite heartbeat → Kuma, under `jobrun --timeout 270` (bounded); also pushes the collie, factory and secrets monitors, runs the daily drift sweep as a side job, appends the rolling pre-hang snapshot (`~/Library/Logs/devhost-snapshots.jsonl`, rotated by `log-rotate`), and pushes one ntfy message per new kernel-panic report (`docs/devhost-health.md` §Forensics: the rolling snapshot and the panic push) |
| `com.jkrumm.beszel-agent` | KeepAlive | push-mode system metrics → the homelab Beszel hub |
| `com.jkrumm.lock-at-boot` | RunAtLoad | screen lock at login |
| `com.jkrumm.log-rotate` | 900s | copytruncate, 16 MB cap; list derived from our plists; Chrome clone sweep bounded on one clock from script start (background priority, lsof 90 s, removal budget 300 s, `--timeout 840`) after rc=124 under load (issue 870) |
| `com.jkrumm.fseventsd-watch` | 05:10 daily | restarts a leaking `fseventsd` (memory > 1.5 GB, or CPU >= 150 % for 10 min) with `sudo -n killall fseventsd`, allowed by one sudoers rule the owner installs once (`make fseventsd-sudoers` through ask-human); `make fseventsd-watch-dry` names what it would do |
| `com.jkrumm.smb-keepalive` | 60 s + network change | mounts and heals the HomeLab Samba shares at `~/HomeLab/<share>` (`docs/macbook.md` §HomeLab Samba); HomeLab down = skipped, exit 0 |
| `com.jkrumm.disk-sweep` | 04:40 daily | bounds what regrows: Docker build cache (15 GB cap) + dangling images, Colima fstrim, stale `$TMPDIR` entries, package caches, Lima IPSW downloads |
| `com.jkrumm.jobrun-canary` | 300s | end-to-end probe for the job → ntfy chain; exits 1 unless `config/jobrun-canary.json` is healthy |
| `com.jkrumm.hc-events` | KeepAlive | the herdr-core event record: `events.subscribe` via `hc connect` (only while `lib/core-up.sh` says a launchd-born core answers: `hc connect` would start a core) into the same `~/.local/share/herdr-events/YYYY-MM-DD.jsonl` (data: never rotated); `recorder.snapshot` lines carry the terminal roster, `recorder.gap` lines (stream ended, `missed`, unparseable line, silence) mark holes; records only; `make hc-events-setup`, log `~/Library/Logs/hc-events.log` |
| `com.jkrumm.hc-resume` | KeepAlive | Claude session resume on herdr-core: subscribes via `hc connect` (only while `lib/core-up.sh` says a launchd-born core answers: `hc connect` would start a core) and types `claude --resume <id>` into the login shell of a kept terminal whose program was lost, from the `jk.claude.*` labels `hooks/hc-session-label.ts` sets; `make hc-resume-setup`, log `~/Library/Logs/hc-resume.log`, `docs/herdr-core.md` §Resume |
| `com.jkrumm.herdr-core` | RunAtLoad (starter, mini only) | a starter, not the core: runs `Herdr Core.app/Contents/MacOS/herdr-core serve` (the official bundle, installed by upstream's installer under `~/.local/share/herdr-core/`) once at login, which detaches into upstream's own one-shot launchd job and exits 0; that detached process is the core, in the GUI session (keychain reach for Claude), attributed to `Herdr Core.app` (the Full Disk Access grant lives on the bundle). The MacBook has no such job: the Herdr app starts its core and connects to the mini as `hc machine` `mini`. Graded by the heartbeat's `core` component and `doctor.sh` (`scripts/lib/core-health.sh`: `lib/core-up.sh` = socket answers AND launchd-born core, `hc server status`, `scripts/hc-responsible.py`, version parity); `make herdr-core-setup`, `make herdr-core-update`, `docs/herdr-core.md`, `docs/tcc.md` |
| `com.jkrumm.kuma-door` | KeepAlive | the Kuma door: `GET /h/<name>` on `127.0.0.1:8795` relays the loopback health URLs in `kuma-door/registry.json` for the homelab's Uptime Kuma (log `~/Library/Logs/kuma-door.{out,err}.log`) |
| `com.jkrumm.home-climate` | 600s | Eve Room climate → ntfy topic `home` (humidity, cold, heat, silent sensor; urgent when the dog is alone); owner repo `home`, `make climate-setup` |
| `com.jkrumm.home-nacht` | KeepAlive | follows the Homebridge `Nacht` switch: mirrors it into Do Not Disturb (`shortcuts run`), pushes the day's weather on the first morning off; owner repo `home` (`tools/climate/watch.ts`, via `secrets-run`) |
| `com.jkrumm.soloist-speaker` | KeepAlive | connects the Bluetooth speaker whenever the mini plays audio (Soloist or AirPlay); owner repo `home`, `make audio-setup` |
| `com.jkrumm.hc-reap` | 1800s | the herdr-core janitor (`rd reap`, `scripts/hc-reap.py` over `hc connect`, only while the core runs): the janitor rules on `terminal.list` — closes (`terminal.kill` + `rm`) finished agents with a clean, pushed checkout (`REAP_IDLE_H`, 12; idle age from the `jk.claude.session` label's transcript) (never a terminal without a `factory.key` label or a `plan:<repo>` one, a working agent, a dirty/unpushed tree or a terminal with live children), messages dirty ones, closes orphan shells, stops `claude --bg` leftovers > 24 h; `make hc-reap-setup`, actions in `~/Library/Logs/hc-reap.log` |
| `com.jkrumm.claude-accounts-keepalive` | 3600s (also on the MacBook) | quota + login keepalive: `claude-account refresh --all` (OAuth usage endpoint sample, renewing an expired token via `claude auth status` on a 401, else the `auth status` verdict, per enabled Claude account, 0 tokens) so an idle account stays inside the picker's 6 h window and its login verified; feeds the quota cache; log `~/Library/Logs/claude-accounts-keepalive.log` |
| `com.jkrumm.obsidian-autostart` | RunAtLoad | Obsidian app |
| `com.jkrumm.collie` | KeepAlive | collie bridge, the phone control surface, standalone on herdr-core (`bin/collie _exec-bridge`, loopback `:8787`, pinned commit, log `~/Library/Logs/collie.log`); `docs/collie.md` |

### hermes-agent

| Label | Schedule | What |
|-|-|-|
| `ai.hermes.gateway` | KeepAlive | Hermes gateway (plist generated by hermes_cli) |
| `com.jkrumm.hermes-backup` | 03:00 daily | backup |
| `com.jkrumm.hermes-liveness` | 300s | Kuma push monitor |
| `com.jkrumm.hermes-serve` | KeepAlive | `hermes serve` (:9119, loopback), the Hermes Desktop backend (`hermes-agent/docs/hermes-serve.md`) |
| `com.jkrumm.hermes-serve-liveness` | 300s | Kuma push monitor for `hermes serve` |

**The launchd row above is not the whole of Hermes.** `ai.hermes.gateway` also
runs an in-process cron layer — 4 live jobs (morning briefing, evening report,
brain drift audit, project narratives; the agents-overview digest was paused
2026-09-08) registered with `hermes cron`, invisible to launchd and to
`architecture-check.sh` because they never leave the gateway process. Registry:
`hermes-agent/docs/scheduled-jobs.md`; model: [[agent-platform]]
(superseded on the dispatch mechanics — see its own banner).

### modelpick

| Label | Schedule | What |
|-|-|-|
| `com.jkrumm.modelpick-refresh` | 06:00 daily | bun run refresh: catalog → probe → collect → release alerts (ntfy `models`) (make refresh-setup) |
| `com.jkrumm.modelpick-web` | KeepAlive | data server for Argo `/models` (`/api/efficiency`) and the TTS playground on :7727 behind the Caddy `modelpick.test` entry; a LaunchAgent, not a container, because its SQLite file is shared with host-side writers (`make web-setup`) |

### weatherorb

| Label | Schedule | What |
|-|-|-|
| `com.jkrumm.weatherorb.serve` | KeepAlive | API server (:8080, loopback) |
| `com.jkrumm.weatherorb.tileserver` | KeepAlive | map tiles (:8081) |
| `com.jkrumm.weatherorb.public` | KeepAlive | blend-only public app (:8082), the VPS edge's only door |
| `com.jkrumm.weatherorb.sync` | KeepAlive | data sync |
| `com.jkrumm.weatherorb.watchdog` | 900s | Kuma push monitor |
| `com.jkrumm.weatherorb.retention` | daily 04:30 | member-store retention (`--apply`) |
| `com.jkrumm.weatherorb.verify` | daily 05:45 | blend-vs-member verification report |
| `com.jkrumm.weatherorb.worker-ingest` | KeepAlive | durable-jobs worker: ingest (DBOS, ADR 0010) |
| `com.jkrumm.weatherorb.worker-round` | KeepAlive | durable-jobs worker: blend rounds (DBOS, ADR 0010) |

The 1200s/900s/hourly/daily/3 h timers that used to ingest, log, archive,
backfill and run blend rounds (`obs`, `fcstlog`, `archive`, `backfill`, `round`) are
DBOS schedules inside the two workers now, not launchd jobs.

The last two are not templated in `weatherorb/ops` — installed by hand, owned by
the weatherorb session workflow.

### others

| Label | Owner | Schedule |
|-|-|-|
| `com.jkrumm.linewatch-collector-agent` | linewatch | KeepAlive |
| `com.jkrumm.linewatch-watchdog` | linewatch | KeepAlive |
| `com.jkrumm.linewatch-heartbeat` | linewatch | 60s |
| `com.jkrumm.usage-tracker` | usage-tracker | 900s |
| `com.jkrumm.usage-tracker-prices` | usage-tracker | 04:20 daily — `prices-sync` under `jobrun`: refreshes the model price catalog behind `usage.compute_cost` |
| `com.jkrumm.usage-tracker-report` | usage-tracker | Monday 07:00 — `report weekly` under `jobrun`: writes the weekly "where the window went" report that Hermes posts at 07:30 |
| `com.jkrumm.walkingpad` | king-smith-walkingpad-mac | KeepAlive |
| `com.jkrumm.agent-workflows-host` | agent-workflows | KeepAlive (:7791, loopback) |
| `com.jkrumm.argo` | argo | KeepAlive (:7737, loopback) — the live Argo since 2026-10-30, from `~/.argo/releases/<sha>`, crons on; Caddy doors `argo-live.test` and `argo.jkrumm.com` (extra FQDN door); health for Kuma through the Kuma door `/h/argo` |
| `com.jkrumm.agent-workflows-audio` | agent-workflows | KeepAlive (:7792; audio process, same release dir as the host) |
| `com.jkrumm.agent-workflows-eval-mine` | agent-workflows | 04:30 daily — `scripts/eval-mine-daily.sh` from the release dir |
| `com.jkrumm.agent-workflows-gateway` | agent-workflows | KeepAlive (:7794, loopback) — the inference gateway (`packages/gateway`, `gateway/<build>/` under `~/.agent-workflows`, not the release dir; restarted by a deploy only when its build changed). The one process that holds provider keys: the personal IU key and one API key per Claude Console org (`iu`, `me`, `me2`, from `config/claude-accounts.json` `platform` blocks, `docs/claude-accounts.md`). Callers present a door token from `~/.agent-workflows/data/door-tokens`; its own SQLite ledger is the outbox for `usage.records`. Claude Code and Athena Teamchat stay outside it |
| `com.jkrumm.research-chrome` | agent-workflows | KeepAlive — headed Chrome with DevTools on loopback `:9222` and its own profile under `~/.local/share/research-chrome`; the browser `agw web fetch` falls back to for pages a plain client cannot read (`make research-chrome` in agent-workflows) |
| `com.jkrumm.iris` | iris | KeepAlive (:7730, loopback) |
| `com.jkrumm.iris-deploy` | iris | 120s — deploy-on-push poller (CI-green and idle gated) |
| `com.jkrumm.iris-testflight-crashes` | iris | 3600s — `scripts/testflight-crashes.ts` from the deploy clone under `jobrun`: reads new TestFlight crash reports from App Store Connect and files one factory Issue per crash signature (`factory issue new --repo iris`) |
| `com.jkrumm.finances` | finances | KeepAlive — the app from a release dir `~/.finances/releases/<sha>`, started through its `scripts/launch.sh` |
| `com.jkrumm.finances-backup-push` | finances | 3600s — `scripts/backup-push.sh` from the release dir, pushes the vault backups |
| `com.jkrumm.soloist` | home | KeepAlive — the audio tool `tools/audio/soloist.sh` under `secrets-run` |
| `com.jkrumm.software-factory` | software-factory | KeepAlive (:7793, loopback; the Console on :7795, loopback, same process — read-only plus the owner's answer verbs, never starts a session; door `factory.test` / `https://factory.<DEV_DOMAIN>`, `config/Caddyfile`) — the factory server (`factory` CLI) from a release dir `~/.software-factory/releases/<sha>`, started through its `scripts/launch.sh` (`secrets-run`, fails closed) |
| `com.jkrumm.homebridge` | home | KeepAlive — Homebridge for Apple Home, installed by `make homebridge` in the home repo |
| `com.jkrumm.factory-door` | software-factory | KeepAlive (:8796, loopback, tailscale serve in front) — the alert door, same release dir as the factory server; files Issues over the socket, holds no token of the factory |
| `com.jkrumm.vps-pg-backup` | vps | 03:15 daily — mini Postgres to the HomeLab, ends with a restore drill (`vps/docs/mini-postgres.md`) |
| `com.iu.prometheus-epos-token` | IuRoot (prometheus-scripts) | 300s |
| `com.iu.prometheus-state-backup` | IuRoot | 3600s |
| `com.iu.prometheus-conduktor-token` | IuRoot | 21600s |
| `com.iu.prometheus-vpn-watcher` | IuRoot | KeepAlive |
| `com.iu.prometheus-artefact-daily` | IuRoot | 07:30 daily |
| `com.iu.prometheus-dashboard-autodeploy` | IuRoot | 600s — deploys the public dashboard from origin/main |
| `com.iu.tool-checkout-deploy` | IuRoot (tool-checkout) | 600s — `prometheus-deploy-gate/gate.py` for the tool-checkout dashboard worktree |
| `com.iu.athena-repo-sync` | IuRoot (epos-tool-athena) | 600s — `bash/repo-sync.sh run`: keeps epos-tool-athena and epos-knowledge-athena current, pushes committed knowledge notes |
| `com.iu.teamchat-vm-watch` | IuRoot (teamchat) | 120s |
| `com.iu.prometheus-stack-dashboard` | IuRoot (prometheus-scripts) | KeepAlive — local stack dashboard |
| `com.iu.athena-postgres` | IuRoot (chat) | KeepAlive — Athena's own Postgres 18 for teamchat, Unix socket only (no TCP), data under `~/.local/state/athena`; rendered by `make -C chat pg-setup` |
| `com.iu.teamchat-profile` | IuRoot (chat) | RunAtLoad — `teamchat-autostart.sh`, the profile's session autostart |
| `com.iu.teamchat-api` | IuRoot (chat) | KeepAlive — `make -C chat api` in the teamchat-runtime worktree |
| `com.iu.teamchat-broker` | IuRoot (chat) | KeepAlive — `epx serve run --port 8790` in the teamchat-runtime worktree |
| `com.iu.teamchat-runtime-deploy` | IuRoot (chat) | 600s — `prometheus-deploy-gate/gate.py` for the teamchat runtime |
| `com.iu.teamchat-funnel-reconcile` | IuRoot (chat) | 300s — `chat/scripts/funnel.sh reconcile` in the teamchat-runtime worktree |

Five of the seven IU jobs (`epos-token`, `state-backup`, `conduktor-token`,
`artefact-daily`, `stack-dashboard`) log to `/tmp` — a known gap, owned by `prometheus-scripts`,
not fixed here because IuRoot repos are out of this map's write scope, and one
that bites on a schedule: macOS sweeps `/tmp` files untouched for three days,
and launchd opens its stdio once at spawn, so a swept log leaves the job writing
into an unlinked inode. `vpn-watcher` logs correctly under the repo's own
`vpn/state/`.

`com.1password.1password-launcher` is a vendor LaunchAgent, not owned by any
repo above. `com.radiosilenceapp.agent` used to sit beside it in
`/Library/LaunchAgents` looping on exit 78 with no app installed; it was removed
2026-09-08. `architecture-check.sh` now scans that directory too, so the next
such stray fails the assertion instead of hiding from it.

## LaunchAgents — MacBook

**Parked while at home (van gear):** the 60 s netgear-watchdog and the 15 min van-sampler
(both `jobrun`, owner `tinycast-extensions`). Back in the van: `make watchdog-setup
van-sampler-setup` there (the sampler is gated on a passing Bluetooth spike), restore both
rows to the list below (original text: this file's git history), and un-hide the `netgear` / `van-power` Tinycast extensions.

`com.jkrumm.appearance-sync` (WatchPaths, Herdr app light/dark) ·
`com.jkrumm.batt-reset` (09:00) · `com.jkrumm.brain-sync` (5 min) ·
`com.jkrumm.claude-accounts-keepalive` (hourly, `jobrun`, the same job as on the mini) ·
`com.jkrumm.db-tunnel` (KeepAlive) ·
`com.jkrumm.opbackup` (hourly guard; runs through `~/.local/libexec/herdr-core-launcher`, the Full Disk Access umbrella for `op`) ·
`com.jkrumm.smb-keepalive` (60 s +
network change, `jobrun`, remounts a stale HomeLab Samba share) · `com.jkrumm.tailnet-sshd`
(KeepAlive, :2222 door) · `sh.brew.colima` · `sh.brew.sleepwatcher` ·
`sh.brew.ntfy-mac` (push notifications) · `cc.chlc.batt` (root daemon, the
charge limiter). The machine is MDM-managed — Jamf, Okta, Adobe and the cancom
hardening daemons are corporate, not mapped; `architecture-check.sh` asserts only
the `com.jkrumm.` / `sh.brew.` / `homebrew.mxcl.` / `cc.chlc.` prefixes there.
Rationale for every one of these: `docs/macbook.md`.

## Doors (inbound)

Every dev app's own `<name>.test` / `<name>.mini.jkrumm.com` door (23 of them —
argo, weatherorb, rollhook, …) is one row in `config/Caddyfile`, the single
registry — not repeated here. This table is everything else: the fixed,
non-Caddy doors.

The agent-workflows audio process (`:7792`) has a Caddy door too, `audio.test` and its tailnet twin, so Mac clients (MacWhisper) reach the OpenAI-compatible STT/TTS endpoint over the tailnet with their per-caller bearer token. It forwards only `/v1/audio/*` and `/audio/*`; everything else on that port (`/health`, `/api/*`) is a 404 at Caddy. The generator carries the restriction into the tailnet door (`scripts/lib/caddy-registry.py` → `scripts/caddy-tailnet.sh`).

The agent-workflows host (`:7791`) has the same kind of door for the image studio, `agw-image.test` and its tailnet twin: it forwards only `/door/image/*` (generate, edit, enhance) with a per-caller bearer token; `/health`, `/workflows/*` and every other path on that port are a 404 at Caddy.

| Door | Terminates at | Scope |
|-|-|-|
| `*.test` HTTPS | mini Caddy (`bind 127.0.0.1`) | local machine only |
| `https://<app>.mini.jkrumm.com` | mini Caddy wildcard block | tailnet, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on 443 |
| `https://argo.jkrumm.com` | mini Caddy extra FQDN door (machine-local `~/.config/caddy-tailnet.hosts`, `docs/remote-dev.md`) → 127.0.0.1:7737 | tailnet, DNS-only A record → the mini's tailnet IP; `tag:mac/tag:phone/tag:tablet` on 443; the homelab and VPS get 403 from the source guard |
| `:7730` (`rb`) | `tailscale serve` → 127.0.0.1:4050 | tailnet only |
| `:8081` (weatherorb tiles) | `tailscale serve` → 127.0.0.1:8081 | tailnet only |
| `:8788` (Collie) | `tailscale serve` → 127.0.0.1:8787 | tailnet, ACL `tag:phone → tag:mac` |
| `:8795` (Kuma door) | `tailscale serve` → 127.0.0.1:8795 | tailnet, ACL `tag:homelab → tag:devhost` on `tcp:8795`; GET `/h/<name>` only, registry-mapped health URLs |
| `tcp:22` → mini | OpenSSH, key-only | tailnet `tag:mac → tag:mac` |
| `tcp:5900` → mini | macOS Screen Sharing (VNC) | tailnet `tag:mac → tag:mac`, MacBook → mini only |
| `tcp:8642` → mini | Hermes's OpenAI-compatible API (iris is its consumer; Argo's chat route was removed 2026-10-30 with its `tag:vps → tag:mac` grant) | no tailnet grant — the API server is currently off, port closed |
| `:8443` (IU dashboard), `:10000` (Athena Teamchat) | `tailscale serve` Funnel | **public internet** — the mini's entire public surface |
| `tcp:2222` → `<peer-host>` | userland sshd behind `tailscale serve --tcp` | tailnet `tag:mac → tag:mac` |
| `ssh homelab` / `ssh vps` | Tailscale SSH (keyless) | tailnet ACL |
| `tcp:445` (SMB `~/Shuttle`) | macOS smbd | tailnet `tag:mac → tag:mac` |
| `https://s3.jkrumm.com` (HomeLab files, S3) | homelab Caddy → VersityGW over existing folders (`homelab/docs/s3.md`); agents via `hl` | tailnet, `tag:mac` on 443 |
| `smb://samba.jkrumm.com` (`SSD`, `HDD`) | homelab Samba, bound to its Tailscale IP; mounted from the mini by `smb-keepalive` | tailnet, `tag:mac` + `tag:phone` on 445 |

Live rows: `dotfiles-private/tailscale-serve.mini.conf` (serve/funnel) and
`tailscale-acl.jsonc` (grants) — this table is a snapshot, that repo is the
source of truth.

## Secrets flow

1Password → biometric seed (`make secrets-seed`) → SOPS+age cache on the mini →
`secrets-run` resolves `op://` refs at runtime, in memory. Full model, tiering
and the reseed trigger: `dotfiles-private/docs/design.md`.

**IU and Anthropic keys.** The personal IU key and the three Claude Console API keys
(`op://mini/claude-platform/`) resolve through `secrets-run` into the inference gateway's
process (agent-workflows' `scripts/launch-gateway.sh`). agw, its OpenCode server, Hermes,
`oc` and modelpick hold no provider key: each reaches every model through the gateway
(`127.0.0.1:7794`) with its own door token from `~/.agent-workflows/data/door-tokens`
(mode 0600, a caller per line, never in a repo or a log). `~/.config/agw/iu.env` is no
longer read. Claude Code (subscription logins) and Athena Teamchat (its own team key)
never pass through it. The Codex lane (`cx`, `cxa`, `astra`) is the other holder of the personal IU key: its launcher (`config/zsh/codex.zsh`) resolves it for codex. Money flow and pool picking: agent-workflows `docs/gateway.md`;
the registry the pools come from: `docs/claude-accounts.md` §Platform.

## Watchers

One table of everything that watches something. Alert paths and the "nothing auto-heals"
rule: `docs/ops-signals.md`. Kuma alerts post to Slack today; job failures go to ntfy topic `alerts`.

| Watcher | Mechanism | Watches | Alerts to | Who acts | Owner repo | Verdict |
|-|-|-|-|-|-|-|
| `com.jkrumm.devhost-health` liveness (`MacMini Dev Host - Push`) | push, **first** act of the run | the dead-machine checks only: tailnet Running, sshd listening, herdr-core socket answering (~15 s). Slow or hung components, swap pressure and a spent budget are WARN text, never DOWN | Kuma, Slack `Slack - Alerts` | the owner: the mini is unreachable or its core is dead | dotfiles | kept; reordered by issue 870 after nine false DOWNs in 48 h |
| `com.jkrumm.devhost-health` detail (`MacMini Dev Host Detail - Push`, opt-in URL file) | push, second | the 19 components (services, disk, memory, auth, jobs WARN, quota, ...) | Kuma → the factory door, not the owner | a lead, through the door | dotfiles | kept; bounded (`jobrun --timeout 270`, per-component timeouts, 200 s budget) |
| Heartbeat side monitors: `MacMini Collie - Push`, `MacMini Secret Seed - Push`, factory monitor | push (same scheduler, own monitors, pushed before the composite) | collie bridge, secrets-cache freshness, the factory's `GET /health` relay (tick and queue movement) | Kuma, Slack | the owner | dotfiles / software-factory (the `/health` source) | kept |
| `MacMini Drift - Push` | push | pins, brew-upgrade recency, pending macOS update | Kuma, Slack (2-day interval) | the owner applies by hand (`make collie-upgrade`, `make brew-upgrade`, `make mini-macos-update`) | dotfiles | merged into the heartbeat as a daily bounded side job, 2026-11-06 (`com.jkrumm.drift-check` retired) |
| Kuma door monitors (`Local / Mac mini door`) | pull (Kuma through `:8795`) | mini service health: agent-workflows host and audio, brain-web, walkingpad, argo, ... from `kuma-door/registry.json` | Kuma, Slack | the owner | dotfiles (door, registry) / homelab (monitors) | kept; replaces the heartbeat's four duplicated service probes (agw host/audio, brain-web, walkingpad), retired 2026-11-06; the audio-vs-host version-mismatch comparison was dropped with them on purpose (the door proves liveness only; agent-workflows' own `make verify` covers release parity) |
| Beszel agent (`com.jkrumm.beszel-agent`) | push (outbound WebSocket) | mini CPU, RAM, disk, network | the Beszel hub on homelab | unspecified (no alert route in these docs) | dotfiles | kept |
| `jobrun` + `jobs-grade` | in-process record, then grading | every `jobrun` job: failure, absence, flapping, unloaded | a factory signal on the job's owner repo after 2 consecutive not-ok grades (once a day per job at most); ntfy topic `alerts` at priority 3 only when `factory` is unreachable; a WARN in the detail message; MacBook: a native notification on wake | a lead fixes it; nothing auto-heals | dotfiles | kept; the only grader |
| `com.jkrumm.jobrun-canary` | in-process probe | the job, then signal chain, end to end | jobs-grade, so a signal on dotfiles | a lead | dotfiles | kept |
| `make doctor` | on demand | LaunchAgents, architecture map, brew, drift (no push), remote path | the terminal | whoever runs it | dotfiles | kept; read-only |
| `com.jkrumm.factory-door` | alert door (inbound, `:8796`) | receives alerts from outside | files a factory Issue over the socket | the factory's lead is the Issue consumer; ops-signals.md does not cover it, so the exact flow is unspecified here | software-factory | kept |
| `brain-sync`, `brain-backup` own pushes (`Brain Sync - Push`, `Brain Backup - Push`) | push (dead-man) | vault reconcile, nightly vault backup | Kuma, Slack | the owner (backup failures are tickets, not pages) | dotfiles | kept; both jobs now under a `jobrun` deadline |
| `1Password Backup - Push` (opbackup, MacBook) | push | the weekly backup left the box | Kuma, Slack | the owner | dotfiles | kept |
| `com.jkrumm.hermes-liveness`, `Hermes Backup - Push` | push | Hermes gateway (and the inference gateway door token), the 03:00 backup | Kuma, Slack | the owner | hermes-agent | kept; see Open below |
| `com.jkrumm.hermes-serve-liveness` | push (backstop 4 h) | `hermes serve` (:9119) | Kuma, Slack | the owner | hermes-agent | kept; see Open below |
| `com.jkrumm.weatherorb.watchdog` | push (`Push` and `Degraded` beats) | WeatherOrb service health, `overdue_after` dead-man | Kuma, Slack | the owner | weatherorb | kept; see Open below |
| `com.jkrumm.linewatch-watchdog`, `com.jkrumm.linewatch-heartbeat` | push (`Home Line - Push`, `Home Line - Watchdog` latch) | the home internet line, the collector | Kuma, Slack | the owner | linewatch | kept; see Open below |
| `com.iu.teamchat-vm-watch` | unspecified | teamchat VM (IuRoot, read-only mention) | unspecified | unspecified | IuRoot (teamchat) | not reviewed here |
| `com.iu.prometheus-vpn-watcher` | in-process self-heal ladder (IuRoot, read-only mention) | the VPN | a desktop notification per the archived note `docs/archive/background-jobs-2026-10-warden-era.md` | unspecified | IuRoot | not reviewed here |

**`fseventsd` leak (2026-11-06):** the system daemon (pid 551, up 5 days) grew to 61 GiB, 55 GiB compressed, filled the 64 GiB swap and held `MacMini Dev Host - Push` DOWN. The heartbeat's memory component now names it above 10 GiB (WARN). The restart is `sudo killall fseventsd` (launchd respawns it at a few MiB; run it through `ask-human`, the mini's sudo password is MacBook-only). `launchctl kickstart -k system/com.apple.fseventsd` does **not** work: SIP refuses it. It recurred (2026-11-12: 2.1 GB, 260 % CPU, 5 days up, swapouts 5 GB per 300 s), so `com.jkrumm.fseventsd-watch` now restarts it daily when its memory is above 1.5 GB or its CPU stays at 150 % for 10 min, through one sudoers rule (`scripts/sudoers.d/fseventsd-restart`, installed once by `make fseventsd-sudoers` through `ask-human`; until it is installed the job logs that and exits 0). Whether worktree churn feeds the leak is unproven: only 6 worktrees exist now, too few to implicate them.

**kern.maxvnodes trial (issue 1059, 2026-11-14):** `kern.num_vnodes` sat at its ceiling, 263168 of 263168, on the 32 GiB mini (~760 processes, 20+ worktrees, bun test, Playwright, two Colima VMs on virtiofs mounts of `$HOME`); every new file open then recycles a vnode, which shows up as kernel CPU, not memory: factory class `system` 1.82 cores, 6538 CPU s over the previous hour, the largest class. The trial raises the ceiling to 526336 (2x) through the root daemon `com.jkrumm.maxvnodes` (`launchd/com.jkrumm.maxvnodes.plist.template`, `make maxvnodes-install` through `ask-human`; deliberately not in `make setup`). Judged on the same 24 h before and after: class `system` cores and footprint, host CPU idle p50, pressure minutes, and `make maxvnodes-status` showing `num_vnodes` below its ceiling. Keep it only if the measure improves; roll back (`make maxvnodes-teardown`, same route) if the `system` footprint grows by more than the CPU falls. Before: `num_vnodes` 263168 = `maxvnodes` 263168 (100 %), class `system` 1.82 cores.

Not a watcher: `com.jkrumm.hc-reap` is the janitor. It closes finished factory agent terminals and messages a dirty one; it grades nothing.

**Open: other repos' pushers** (their scripts run without a bounded wrapper; not fixable from dotfiles, owner-repo follow-ups):
- `hermes-liveness` and `hermes-serve-liveness` (hermes-agent)
- the weatherorb watchdog (weatherorb)
- the linewatch heartbeat and watchdog (linewatch)

## Monitoring (Uptime Kuma on homelab)

Push for the composite and the jobs — the ACL grants `tag:homelab → tag:vps` but
not `→ tag:mac`. Service health is pulled through the Kuma door (`:8795`, the one
narrow grant `tag:homelab → tag:devhost`), with monitors generated from
`kuma-door/registry.json`. Full rationale: [[mac-host-monitoring]],
`docs/devhost-health.md`.

The mini additionally reports CPU/RAM/disk/network to a **Beszel** hub on
homelab (`https://beszel.jkrumm.com`) via `com.jkrumm.beszel-agent` — its own
outbound WebSocket, same push posture as the Push monitors below, separate from
Uptime Kuma.

| Monitor | Pusher | Cadence |
|-|-|-|
| `Local / Mac mini door` (group, one `<service> - Door` monitor each) | Kuma **pulls** `https://<mini MagicDNS host>:8795/h/<name>`; generated by `make kuma-door-gen` | 120 s, 2 retries |
| `MacMini Dev Host - Push` | `devhost-health-check.sh` liveness (tailnet, sshd, core socket; first push of the run, ~15 s). The 18 slow components (herdr-core `hc`, Max quota, kernel panics, ...) follow in a second push (WARN text) and on the opt-in `MacMini Dev Host Detail - Push`; bounded, 270 s `jobrun` deadline | 10 min, 1 retry |
| `MacMini Collie - Push` | collie behavioural check | 4 h backstop, 1 retry |
| `MacMini Secret Seed - Push` | cache-freshness check | 8 days, 1 retry |
| `MacMini Drift - Push` | `drift-check.sh`, a daily side job of the heartbeat (no agent of its own) | 2 days, 1 retry |
| `Brain Sync - Push` | brain-sync agent | 4 h backstop, 1 retry |
| `Brain Backup - Push` | brain-backup agent | 25 h |
| `Hermes Agent - Push` | hermes-liveness | 6 min |
| `Hermes Backup - Push` | hermes-backup agent | 25 h |
| `WeatherOrb Watchdog - Push` | weatherorb watchdog | 35 min |
| `WeatherOrb Watchdog - Degraded` | weatherorb watchdog (degraded-state beat) | 35 min |
| `Home Line - Push` | linewatch | 4 min |
| `Home Line - Watchdog` | linewatch watchdog latch | 10 min, 2 retries |
| `Hermes Serve - Push` | hermes-serve-liveness | 4 h backstop, 1 retry |
| `1Password Backup - Push` | opbackup (MacBook) | weekly |

Every push monitor has `maxretries: 1` with `retry_interval = min(interval, 1 h)`, so a flake does not page and time-to-DOWN stays ≈ interval. Backstops (Brain Sync, Collie, Hermes Serve) run at a 4 h interval.

Declarative source: `homelab/uptime-kuma/monitors.yaml` (`make uk-sync`).

**The inference gateway has no Kuma monitor of its own.** agent-workflows' `make verify`
probes it (its `/health` at the deployed build, then real Haiku calls through it with
their `source='gateway'` rows); `/health` also reports the ledger (unsynced,
quarantined), each pool's meter and its last reconcile error. Hermes' liveness check
(`scripts/inference-gateway-check.sh`) withholds its heartbeat when the gateway's
`/health` is not ok or its `hermes` door token is refused, and Hermes' `make verify`
checks both: a gateway outage turns the `Hermes Agent - Push` monitor red.

## Pinning policy

`caddy` is pinned (its dependencies too, or the pin rots); `colima` is
deliberately unpinned and asserted instead. Full rationale: `docs/homebrew.md`.

Related: [[remote-dev-stack]] · [[mac-host-monitoring]] · [[agent-overview-loop]] · [[agent-platform]]
