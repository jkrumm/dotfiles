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

Six boxes, each with one job. Full rationale for any of these lives in the
docs/wiki pages linked at the end of each reference table below — this section
is only the *why this box exists*.

**Mac mini — the always-on dev host.** Where agents actually run: Claude Code
sessions (`c`/`ca`/`cap`), Hermes's gateway, sideclaw's workers, every LaunchAgent
below. It never sleeps and holds no human-facing UI of its own; everything on it
is reached, never sat in front of.

**MacBook and iPhone — the UI layer he builds from.** Neither holds durable
state. The MacBook is `desk` (a herdr client) plus editing and biometric
1Password; closing the lid ends a *connection*, never the work. The iPhone is
Collie in a browser tab — the phone-side control surface, nothing installed.

**herdr, Slack, Argo, the brain reader, Collie — where he sees what happens and
interacts.** Five different windows onto the same mini, each answering a
different question:

- **herdr** — the terminal-level view: `make agent-overview` opens a pane
  watching every agent's live status text, and any other pane is a session he
  can attach to directly.
- **Slack** — Hermes's channel: `#agents` is the **work board** — one
  deduplicated card per problem from the triage loop, updated in place, plus the
  06:30 project-narrative line. The 30-min agent-status digest that used to run
  here was paused 2026-09-08 (it reposted the same blocked pane ~35 times in two
  days). `#briefings`/`#watchdog` get the cron
  digests, and dispatch approvals land as buttons in the origin thread.
- **Argo dashboard** (`/agents`) — the durable, queryable record: the mini
  pushes every completed sideclaw overview snapshot there (plus one push every
  10 min regardless), so a browser tab shows 24 h history after herdr and
  Slack have scrolled past it.
- **brain reader** (`brain.mini.jkrumm.com`) — read-only render of the vault,
  rebuilt every 5 min; how the model in his second brain gets checked from a
  phone or a browser with nothing installed.
- **Collie** — the one surface here that can *act*, not just observe: it types
  into a live herdr pane from the phone. Gated by the tailnet ACL, scoped to
  `tag:phone` alone.

**VPS — the mature, always-running stack.** Traefik-fronted production apps
(argo, rollhook, the research/audio/image gateways' prod side, meteo's edge,
bun-email-api, free-planning-poker, …), backed by ClickStack/HyperDX for OTel,
alerts-as-code, and its own backup/prune crons. Nothing here depends on the mini
being up, and it is reached over Tailscale SSH, never through the mini.

**HomeLab — his own container world.** A ~36-service personal stack (Immich,
the ebook/reading pipeline, Garmin/KoInsight, media, the VPN watchdog) plus the
single Uptime Kuma instance every push monitor in this doc reports to — the
mini's heartbeat destination, not a peer of the mini.

**The gateways — outsourcing work and workflows.** research-gateway (agentic
Tavily+Context7 research), audio-gateway (STT/TTS, the podcast pipeline) and the
image-gen gateway (generate/edit/enhance) each take one kind of work off the
mini and expose it as a submit-then-poll HTTP service — an agent on the mini
calls out and polls rather than doing STT, TTS or image generation itself.

## Diagrams

Two validated artifacts in `docs/diagrams/`, each one self-contained HTML: open
the file, no server. They carry pan/zoom, search, relationship tracing and their
own image export, so a screenshot is never the way to share one.

| File | The question it answers |
|-|-|
| `estate.html` | Where does everything sit, and what talks to what — the mental model above, drawn. |
| `dispatch-path.html` | What happens between a Slack message and committed work, including the two ways it stops. |

Both are compiled from the `.json` beside them with the vendored `archify`
skill, which validates geometry and composition before it will deliver: an
arrow through a box or a label over a node fails the build. Regenerate with
`node skills/archify/bin/archify.mjs deliver <type> <spec.json> <out.html>
--quality showcase`. Both specs carry `quality_profile: showcase`.
`dispatch-path.html` delivers clean. The estate diagram's readability failure
was fixed by narrowing `viewBox` from 3000 to 930 (the desktop-reader legibility
budget caps out at 930px of usable width, and anything under it scores full
marks regardless of sublabel length) and reflowing the five regions into
vertical bands instead of one wide row. One open item remains:
`composition/proper-crossing` between `devhost → kuma` and `argoapi → otel` —
both must route through the same 40px gap between adjacent VPS nodes, and no
corridor assignment found so far clears one without re-crossing the other, so
`deliver` still declines and `estate.html` is regenerated with `render`
instead — same validated geometry, without that one crossing guarantee.

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
| `argo` | Personal API + dashboard, the agent backbone | hosts the `/agents` overview + narratives feed |
| `hermes-agent` | Hermes gateway — Slack-facing control surface, dispatch bridge, 5-job cron layer | see [[hermes-as-control-surface]] |
| `warden` | **The control plane.** Ingests signals, decides, drives the lifecycle to a verified outcome, and holds the only ledger (`~/.warden/warden.db`). Extracted from `hermes-agent` 2026-09-09 — a control plane cannot live inside the thing it supervises. Five LaunchAgents (`### warden` below), never gateway cron. `DESIGN.md` is authoritative, `STATE.md` is where the build actually is. Docs: `warden/docs/api.md`, `warden/FLOWS.md`, `warden/docs/triage.md`. `warden run <repo> '<brief>'` is the unattended lane; `sideclaw dispatch` and `rd bg` are a session's and a human's |
| `sideclaw` | Local MCP daemon behind `/check`, `/review`, `dispatch`, `/otel` | `mcp.ts` stdio-only; lives only here |
| `audio-gateway` | STT/TTS service; repo here, container on the VPS | second instance on the mini (`com.jkrumm.audio-gateway`, `scripts/launch.sh`, :7719) runs the podcast pipeline only — brain access, STT/TTS stays on the VPS |
| `basalt-ui-obsidian` | Obsidian plugin building the brain reader | |
| `bun-email-api`, `free-planning-poker`, `jkrumm.com`, `kobo-mods`, `ticktick-raycast`, `rollhook`, `rollhook-action`, `image-share`, `modelpick`, `rb`, `research-gateway`, `usage-tracker`, `king-smith-walkingpad-mac`, `linewatch`, `dispatch-scratch` | see global CLAUDE.md repo table | |
| `meteo` | weather/wave service, 8 LaunchAgents | all 8 templated in `meteo/ops`, `make launchd-install` (idempotent; `FORCE=1` bounces all) |
| `dispatch-scratch` | disposable dispatch test target | by design |
| `homelab`, `homelab-private`, `vps` | server stacks, reached over Tailscale SSH | |

### MacBook-only

| Repo | Purpose |
|-|-|
| `photo-flow` · `shutterflow` | the two photography apps |
| `image-gen` | the Tauri studio — a GUI app belongs on the machine with a human at it; its gateway stays on the VPS |
| `basalt-ui` | followed image-gen: it is consumed as a `file:` dependency, so the studio's machine needs the build |

## LaunchAgents — mini (gui/501 unless noted)

Every label here is asserted by `scripts/architecture-check.sh`, and the
KeepAlive subset also by the heartbeat's `check_boot_path`. Homebrew 6 writes
`sh.brew.<name>` on the next start/restart and deletes `homebrew.mxcl.<name>`
(both still `homebrew.mxcl.*` on the mini today); both names map to the same
row and `scripts/lib/brew-service.sh` resolves whichever exists.

### dotfiles

| Label | Schedule | What |
|-|-|-|
| `sh.brew.herdr` | KeepAlive | herdr server, setsid wrapper — **supervised boot path** |
| `sh.brew.colima` | KeepAlive | Docker VM, bounded-retry wrapper — **supervised boot path** |
| `com.colima.docker-socket` | daemon (root) | `/var/run/docker.sock` symlink at boot |
| `sh.brew.caddy` | daemon (root) | local HTTPS + tailnet doors |
| `sh.brew.dnsmasq` | daemon (root) | `*.test` DNS |
| `sh.brew.tailscale` | daemon (root) | tailnet |
| `sh.brew.postgresql@18` | KeepAlive | local Postgres |
| `sh.brew.sleepwatcher` | KeepAlive | runs `~/.wakeup` |
| `com.jkrumm.brain-sync` | 300s | vault reconcile via GitHub |
| `com.jkrumm.brain-backup` | 03:30 daily | vault backup |
| `com.jkrumm.brain-web-refresh` | 300s | brain-web rebuild |
| `com.jkrumm.devhost-health` | 300s | the composite heartbeat → Kuma |
| `com.jkrumm.drift-check` | 09:40 daily | upstream drift notice |
| `com.jkrumm.lock-at-boot` | RunAtLoad | screen lock at login |
| `com.jkrumm.log-rotate` | 3600s | copytruncate, 16 MB cap |
| `com.jkrumm.obsidian-autostart` | RunAtLoad | Obsidian app |
| `com.jkrumm.sideclaw-server` | KeepAlive | sideclaw MCP daemon |
| `herdr.collie` | KeepAlive | collie bridge (upstream plist) |

### hermes-agent

| Label | Schedule | What |
|-|-|-|
| `ai.hermes.gateway` | KeepAlive | Hermes gateway (plist generated by hermes_cli) |
| `com.jkrumm.hermes-backup` | 03:00 daily | backup |
| `com.jkrumm.hermes-liveness` | 300s | Kuma push monitor |

**The launchd row above is not the whole of Hermes.** `ai.hermes.gateway` also
runs an in-process cron layer — 4 live jobs (morning briefing, evening report,
brain drift audit, project narratives; the agents-overview digest was paused
2026-09-08) registered with `hermes cron`, invisible to launchd and to
`architecture-check.sh` because they never leave the gateway process. The
watchdog poll and dispatch sweep that used to run here were promoted to
`warden-poll`/`warden-sweep` LaunchAgents above on 2026-09-09 — a control
plane cannot depend on the process it supervises being up. Registry:
`hermes-agent/docs/scheduled-jobs.md`; model: [[hermes-as-control-surface]]
(superseded on the dispatch mechanics — see its own banner).

### warden

Five LaunchAgents, not four — `warden-api` is easy to miss counting because it
has no fixed interval (`KeepAlive`, not a timer), but `GET /health` and
`/metrics` on `127.0.0.1:7735` are the ledger's only HTTP surface, read by
`make status` here and by Hermes nowhere yet ([[hermes-as-control-surface]]
finding: no read path). The other four were extracted from `hermes-agent`
2026-09-09 — a control plane cannot live inside the thing it supervises — and
are LaunchAgents rather than gateway cron on purpose: the loop that notices
Hermes is broken cannot depend on Hermes being up, and its Slack delivery is a
plain HTTP client, not the gateway's live connection.

| Label | Schedule | What |
|-|-|-|
| `com.jkrumm.warden-api` | KeepAlive | The ledger's HTTP surface — `GET /health`, `/metrics` on `127.0.0.1:7735` |
| `com.jkrumm.warden-loop` | 600s | The alert triage act-loop — turns deduplicated `~/.warden/warden.db` events into one card per problem in `#agents` and a sideclaw `investigate` episode in the owning repo. Was gateway cron, extracted from `hermes-agent` 2026-09-09. |
| `com.jkrumm.warden-poll` | 1800s | Ingest. Was gateway cron job `4b1faabda97d`; promoted for the same reason — ingest running inside the process it supervises is how the loop kept ticking against a ledger that had stopped receiving signals. Posts its own digest and pings the `watchdog` UptimeKuma push URL on a clean poll. |
| `com.jkrumm.warden-sweep` | 300s | Folds a terminal sideclaw verdict onto the card the loop already wrote. Was gateway cron job `4dd759917dd1`. |
| `com.jkrumm.warden-backup` | daily 03:10 | `VACUUM INTO` snapshot of the ledger, rotated, rsynced to `homelab:/mnt/hdd/backups/warden/` — inside the restic source mount, so it reaches B2 with no homelab-side change. Between `hermes-backup` (03:00) and restic (03:30). |

### modelpick

| Label | Schedule | What |
|-|-|-|
| `com.jkrumm.modelpick-refresh` | 06:00 daily | bun run refresh: probe → collect → recommend (make refresh-setup) |

### meteo

| Label | Schedule | What |
|-|-|-|
| `com.jkrumm.meteo.serve` | KeepAlive | API server (:8080, loopback) |
| `com.jkrumm.meteo.tileserver` | KeepAlive | map tiles (:8081) |
| `com.jkrumm.meteo.sync` | KeepAlive | data sync |
| `com.jkrumm.meteo.obs` | 1200s | observations ingest |
| `com.jkrumm.meteo.fcstlog` | 900s | forecast logging |
| `com.jkrumm.meteo.blendfield` | 10800s | blend field |
| `com.jkrumm.meteo.backfill` | 07:15 daily | backfill |
| `com.jkrumm.meteo.watchdog` | 900s | Kuma push monitor |

### others

| Label | Owner | Schedule |
|-|-|-|
| `com.jkrumm.linewatch-collector-agent` | linewatch | KeepAlive |
| `com.jkrumm.linewatch-watchdog` | linewatch | KeepAlive |
| `com.jkrumm.linewatch-heartbeat` | linewatch | 60s |
| `com.jkrumm.usage-tracker` | usage-tracker | 900s |
| `com.jkrumm.walkingpad` | king-smith-walkingpad-mac | KeepAlive |
| `com.jkrumm.audio-gateway` | audio-gateway | KeepAlive |
| `com.iu.prometheus-epos-token` | IuRoot (prometheus-scripts) | 300s |
| `com.iu.prometheus-state-backup` | IuRoot | 3600s |
| `com.iu.prometheus-conduktor-token` | IuRoot | 21600s |
| `com.iu.prometheus-vpn-watcher` | IuRoot | KeepAlive |
| `com.iu.prometheus-artefact-daily` | IuRoot | 07:30 daily |

Four of the five IU jobs (`epos-token`, `state-backup`, `conduktor-token`,
`artefact-daily`) log to `/tmp` — a known gap, owned by `prometheus-scripts`,
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

`com.jkrumm.batt-reset` (09:00) · `com.jkrumm.brain-sync` (5 min) ·
`com.jkrumm.db-tunnel` (KeepAlive) · `com.jkrumm.opbackup` (hourly guard) ·
`com.jkrumm.photoflow` (logs to `/tmp`, known) · `com.jkrumm.tailnet-sshd`
(KeepAlive, :2222 door) · `sh.brew.colima` · `sh.brew.sleepwatcher` ·
`sh.brew.ntfy-mac` (push notifications) · `cc.chlc.batt` (root daemon, the
charge limiter). The machine is MDM-managed — Jamf, Okta, Adobe and the cancom
hardening daemons are corporate, not mapped; `architecture-check.sh` asserts only
the `com.jkrumm.` / `sh.brew.` / `homebrew.mxcl.` / `cc.chlc.` prefixes there.
Rationale for every one of these: `docs/macbook.md`.

## Doors (inbound)

Every dev app's own `<name>.test` / `<name>.mini.jkrumm.com` door (25 of them —
argo, sideclaw, meteo, rollhook, …) is one row in `config/Caddyfile`, the single
registry — not repeated here. This table is everything else: the fixed,
non-Caddy doors.

| Door | Terminates at | Scope |
|-|-|-|
| `*.test` HTTPS | mini Caddy (`bind 127.0.0.1`) | local machine only |
| `https://<app>.mini.jkrumm.com` | mini Caddy wildcard block | tailnet, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on 443 |
| `:7730` (`rb`) | `tailscale serve` → 127.0.0.1:4050 | tailnet only |
| `:8081` (meteo tiles) | `tailscale serve` → 127.0.0.1:8081 | tailnet only |
| `:8788` (Collie) | `tailscale serve` → 127.0.0.1:8787 | tailnet, ACL `tag:phone → tag:mac` |
| `tcp:22` → mini | OpenSSH, key-only | tailnet `tag:mac → tag:mac` |
| `tcp:5900` → mini | macOS Screen Sharing (VNC) | tailnet `tag:mac → tag:mac`, MacBook → mini only |
| `tcp:8642` → mini | Hermes's OpenAI-compatible API, for Argo's chat route | tailnet `tag:vps → tag:mac`, grant only — the API server is currently off, port closed |
| `:8443` (IU dashboard) | `tailscale serve` Funnel | **public internet** — the mini's entire public surface |
| `tcp:2222` → iumac | userland sshd behind `tailscale serve --tcp` | tailnet `tag:mac → tag:mac` |
| `ssh homelab` / `ssh vps` | Tailscale SSH (keyless) | tailnet ACL |
| `tcp:445` (SMB `~/Shuttle`) | macOS smbd | tailnet `tag:mac → tag:mac` |

Live rows: `dotfiles-private/tailscale-serve.mini.conf` (serve/funnel) and
`tailscale-acl.jsonc` (grants) — this table is a snapshot, that repo is the
source of truth.

## Secrets flow

1Password → biometric seed (`make secrets-seed`) → SOPS+age cache on the mini →
`secrets-run` resolves `op://` refs at runtime, in memory. Full model, tiering
and the reseed trigger: `dotfiles-private/docs/design.md`.

## Monitoring (Uptime Kuma on homelab)

Push, not probe — the ACL grants `tag:homelab → tag:vps` but not `→ tag:mac`.
Full rationale: [[mac-host-monitoring]].

| Monitor | Pusher | Cadence |
|-|-|-|
| `MacMini Dev Host - Push` | `devhost-health-check.sh` composite (16 components, incl. sideclaw job health, the overview pane, Max quota) | 10 min |
| `MacMini Collie - Push` | collie behavioural check | 10 min |
| `MacMini Secret Seed - Push` | cache-freshness check | 8 days |
| `MacMini Drift - Push` | drift-check agent | 2 days |
| `Brain Sync - Push` | brain-sync agent | 10 min |
| `Brain Backup - Push` | brain-backup agent | 25 h |
| `Hermes Agent - Push` | hermes-liveness | 6 min |
| `Hermes Watchdog - Push` | hermes watchdog poll | 35 min |
| `Hermes Backup - Push` | hermes-backup agent | 25 h |
| `Meteo Watchdog - Push` | meteo watchdog | 35 min |
| `Home Line - Push` | linewatch | 4 min |
| `1Password Backup - Push` | opbackup (MacBook) | weekly |

Declarative source: `homelab/uptime-kuma/monitors.yaml` (`make uk-sync`).

## Pinning policy

`caddy` is pinned (its dependencies too, or the pin rots); `colima` is
deliberately unpinned and asserted instead. Full rationale: `docs/homebrew.md`.

Related: [[remote-dev-stack]] · [[mac-host-monitoring]] · [[agent-overview-loop]] · [[hermes-as-control-surface]]
