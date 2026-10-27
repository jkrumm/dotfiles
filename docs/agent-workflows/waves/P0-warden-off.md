# P0 — switch warden off

Phase P0 of `../concept.md` §11. The factory is deferred, so nothing replaces warden yet; for now
every alert goes raw to Slack and nothing auto-heals. The owner chose this on 2026-10-27.

## Goal

Warden stops running and nothing calls it any more. Every alert source that fed warden still reaches
a human through Slack. The warden repo and its data survive as read-only reference.

## Steps

1. **Inventory first.** `grep -rn -i warden` across `~/SourceRoot` (skip `node_modules`, `.git`,
   `warden/` itself, `docs/**/archive/`, `docs/factory/`, `docs/agent-workflows/research/`) plus
   `~/.hermes`, the LaunchAgents (`launchctl list | grep warden`: api, loop, poll, sweep, backup), the
   Uptime Kuma config, HyperDX alert webhooks, Argo, usage-tracker, jobs-grade
   (`docs/ops-signals.md`: "every alert source feeds warden directly"). Write the caller list into
   this file under `## Inventory` before changing anything.
2. **Kill switch, then a final backup.** Engage warden's kill switch (warden `DESIGN.md` § The
   kill-switch), run `com.jkrumm.warden-backup` once, and copy the backup to the HomeLab with `hl`.
3. **Reroute alerts to Slack**, then prove each one:
   - Uptime Kuma: remove the webhook into warden's `/ingest/kuma` (homelab repo, AGENTS.md around
     line 351, `op://homelab/warden-ingest/token`) and delete the `Warden Loop` push monitor. Kuma's
     own Slack notifications must stay on — verify.
   - HyperDX alert webhooks into warden → point them at Slack.
   - `jobs-grade --notify` and any other source in `docs/ops-signals.md` → Slack.
4. **Remove callers:**
   - dotfiles: `config/global.CLAUDE.md` (the `warden run` routing row; "four lanes" becomes three),
     `AGENTS.md` (lanes table, the `~/.local/bin/warden` symlink row), `docs/agent-platform.md`,
     `docs/architecture.md` (warden LaunchAgents), `docs/ops-signals.md`, `scripts/remote-dev.sh`
     help text, any skill naming `warden run`. Remove the `~/.local/bin/warden` link.
   - Hermes: `scripts/hermes-cc.sh`, the read-only `warden` skill, any cron or script calling
     warden's API. Hermes' project narratives keep running unless they depend on warden; if they
     do, stop them and say so.
   - Argo: disable the *implement* button and any warden call.
   - Anything else the inventory found.
5. **Unload the LaunchAgents** (`launchctl bootout`, remove the plists the way the warden Makefile
   installed them). Run `make doctor` and fix what the removal breaks in the map, nothing else.
6. **Archive:** add a status line at the top of `warden/AGENTS.md` ("switched off 2026-10-27 by
   agent-workflows P0; reference only"), commit, push.

## Rules

- Commit per repo with conventional commits; PR-required repos go through a PR, self-review,
  merge (`config/pr-required-repos.json`).
- No deletion of warden's code or database in this phase.
- Something unexpected (a caller you can't classify, an alert with no Slack path) goes into
  `## Findings` here; route around it and keep going.

## Acceptance

- `launchctl list | grep warden` is empty; nothing listens on warden's port (7735).
- The grep from step 1 finds only history (archives, factory design, research).
- Each rerouted alert source is shown to reach Slack (a test alert, or the config read back).
- `make doctor` is green on the mini; `make check` is green in dotfiles.
- `## Inventory` and `## Findings` filled in, then committed.

## Inventory

Taken 2026-10-27 before any change. "Runtime" = something that calls or feeds warden while it runs;
"prose" = documentation that describes it.

**Running state:** LaunchAgents `com.jkrumm.warden-{api,loop,poll,sweep,backup}` (plists in
`~/Library/LaunchAgents`, rendered from `warden/launchd/*.plist.template`); `warden-api` listens on
`127.0.0.1:7735`; ledger `~/.warden/warden.db`; CLI wrapper `~/.local/bin/warden` (written by
dotfiles `make setup`, Makefile ~1224).

**Alert sources that fed warden**

| Source | Path | Slack today |
|-|-|-|
| Uptime Kuma | provider `Warden - Ingest` (`homelab/uptime-kuma/monitors.yaml` `settings.notifications` + `settings.webhooks`, token `WARDEN_INGEST_TOKEN` in `homelab/.env.tpl`) → `warden-ingest.mini.jkrumm.com/ingest/kuma` | `Slack - Alerts` provider is attached to every leaf beside it |
| Kuma monitors about warden | `Warden Loop - Push`, `Warden Backup` push monitors (`homelab`, `homelab-private`, `homelab-w7` monitors.yaml) | n/a — they die with warden |
| HyperDX | 21 `vps/observability/alerts/*.json` list webhook `Warden ingest` in `channels` (created by `vps/scripts/hyperdx-warden-webhook-setup.sh`, make `hyperdx-warden-webhook-setup`) | every one also lists `Slack #alerts` |
| `jobs-grade` (`job` source) | warden polled `~/.local/bin/jobs-grade`; MacBook wake hook runs `jobs-grade --notify` (macOS notification only) | **none on the mini** — heartbeat shows WARN lines in the Kuma composite message only |
| `slack_alert`, `hermes_log`, GitHub issues, `warden run` | warden's own pollers/CLI | die with warden; GitHub issues keep notifying by mail |
| weatherorb watchdog | `route = "warden"` opens a GitHub issue labelled `alert` (`weatherorb/config/weatherorb.toml`, `src/weatherorb/ops/alert.py`) | its HyperDX alerts keep their own webhook; the issue is a normal GitHub issue |

**Runtime callers**

| Where | What |
|-|-|
| dotfiles | `Makefile` (`~/.local/bin/warden` wrapper), `scripts/remote-dev.sh` help text (2 lines), `config/Caddyfile` + `scripts/caddy-tailnet.sh` (`warden-ingest` door, port 7735), `scripts/lib/jobs-grade.ts` / `jobrun-canary.ts` / `devhost-health-check.sh` / `doctor.sh` / `log-rotate.sh` (`warden-cli.log`) / canary plist template (comments + the `job` source contract), `skills/remote-dev/SKILL.md`, `config/herdr/groups.json` |
| agent-gateway | `server/lib/warden-board.ts` GETs `http://127.0.0.1:7735/board` for the overview; `overview-payload.ts`, `agents.ts`, `render-text-utils.ts` consume it; `server/jobs/handlers/triage.ts` and the `dispatch-verdict` handler are warden's episode verdict plumbing |
| Hermes (`~/.hermes`) | `scripts/hermes-cc.sh` (exec shim into warden CLI), `skills/warden/` (read-only API skill), `skills/devops/heartbeat-monitoring/references/warden-card-triage.md`, `config.yaml` comments, `scripts/briefing-context.py` (`watchdog-summary.py` from warden; the briefing cron is disabled), `scripts/agents-overview.py` (docstring only). Enabled crons: `Project narratives`, `Brain drift audit`, `claude-release-watch` — none call warden |
| Argo | API `apps/api/src/routes/warden.ts` + `warden_snapshots`/`warden_actions` tables (warden pushes snapshots, pulls queued actions); dashboard `features/warden/*`, `nav.tsx`, `home/*` (needs-you, today), `Makefile` design-shot route |
| homelab / homelab-private / homelab-w7 | Kuma config above; `homelab/AGENTS.md` ~351 |
| vps | HyperDX webhook script, Makefile target, 21 alert files, `AGENTS.md`, `docs/observability.md`, `observability/README.md` |
| dotfiles-private | `tailscale-acl.jsonc` (ingest grants homelab/VPS → devhost :443), `headless.refs` (`WARDEN_BOT_TOKEN`, ingest bearer) |
| usage-tracker, modelpick, email-gateway, weatherorb | comments / labels only (`warden` as a billing-lane name, a backup-script comparison, the `warden:skip` issue label) — no calls |

**Prose only (history, left alone unless operational):** `brain` wiki/Areas/Inbox, `jkrumm.com`
content, `basalt-ui` maturation and wave notes, generated diagrams under `dotfiles/docs/diagrams/`
and `jkrumm.com/public/diagrams/`, `hermes-agent` clone (upstream fork — not touched).

## Findings

Done 2026-10-27. Evidence per source is in the commits named below.

**Proofs**

| Check | Result |
|-|-|
| LaunchAgents / port | `launchctl list \| grep warden` empty, five plists removed, nothing on `127.0.0.1:7735`, `~/.local/bin/warden` gone |
| Kill switch + backup | `warden pause` engaged first (0 items `working`); final snapshot + repo bundle in `homelab:hdd/backups/warden-final/` (`hl lsl` read back) |
| Uptime Kuma | live provider `Warden - Ingest` deleted; providers now `['Slack - Alerts']`, attached to 96 of 96 leaf monitors; `Warden`, `Warden Backup - Push`, `Warden Loop - Push` deleted; sync dry-run clean (homelab `7ce5599`) |
| HyperDX | `Warden ingest` channel stripped from 23 alert files and applied to prod; live read-back: 33 alerts, none reference it, webhook deleted, remaining `['Slack #alerts', 'WeatherOrb ops.alert']` (vps `10098d1`) |
| jobs-grade | `--summary --slack` posts to #alerts when the not-ok set changes; the live heartbeat posted within minutes (state file written only after Slack returned `ok:true`) |
| Argo | PR #205 merged; prod `/api/health` commit equals `origin/master`; `POST /warden/items/*/actions` 410s, action UI removed, Home stops counting frozen items |
| agent-gateway | overview no longer fetches `127.0.0.1:7735` (`6c8bf38`) |
| Hermes | `dispatch` + `warden` skills, `hermes-cc.sh`, the warden card-triage reference moved to `~/.hermes/skills/.retired-warden-off-2026-10-27/`; SOUL, memory, config comments and `briefing-context.py` rewritten (originals in `~/.hermes/backups/warden-off-2026-10-27/`) |

**Findings**

1. **`make check` and `make doctor` are not green, for reasons unrelated to warden.** `architecture-check` fails on the IuRoot teamchat/athena LaunchAgents (`com.iu.athena-postgres` unmapped; `com.iu.teamchat-*` mapped but absent) and `drift-check` on a collie pin and a tailscale daemon bump. Same on `HEAD` before this wave. Every other `make check` target passes. Not fixed (files this wave did not touch).
2. **Tailnet ACL grant `tag:homelab,tag:vps -> tag:devhost tcp:443` is removed in `dotfiles-private` (`4fc5b42`) but not applied.** The MacBook was unreachable; the push is queued in human-queue (`make human-queue`). Until applied, `scripts/caddy-tailnet.sh` keeps the 403 source guard for those tags (so the retired ingest door left no exposure). Drop `GUARD_SRC_TAGS` after the push.
3. **Two real job failures were previously warden's to fix:** `com.jkrumm.disk-sweep` and `com.jkrumm.drift-check` grade `failing`. They now surface in #alerts and nothing works them.
4. **One spurious Slack line:** the heartbeat announced `com.jkrumm.warden-backup=unloaded` before I moved its jobrun state file to `~/.local/state/jobs-retired/`; a recovery line follows on the next tick.
5. **Open warden items abandoned:** at pause the ledger held 4 `new`, 1 `triaged`, 7 `needs_decision`, 5 `failed`. They remain in `~/.warden/warden.db` and in the backup.
6. **HyperDX apply created 2 alerts** (`shutterflow master serving tripped / unreachable`) that existed as files but not in prod; both notify Slack only.
7. **Left for the owner (credentials):** `op://common/slack/WARDEN_BOT_TOKEN` (warden's Slack app) and `op://mini/warden-ingest/token` + `op://homelab/warden-ingest/token` are unused but still in `dotfiles-private/headless.refs` and 1Password. Revoking them and dropping the refs needs a biometric reseal.
8. **Not touched, history or other owners:** generated diagrams (`dotfiles/docs/diagrams/*`, `jkrumm.com/public/diagrams/*`) still draw warden and need an archify regen; `brain` wiki/Areas/Inbox, `jkrumm.com` guide pages, `basalt-ui` wave notes, `hermes-agent` fork; `homelab-w7` is a stale checkout with the old Kuma file; weatherorb's `route = "warden"` alert class still opens a GitHub issue (nothing works it) and its docs/comments name warden; agent-gateway keeps `warden` as a caller name in triage/dispatch-verdict/review handlers and archived wave docs; `usage-tracker`, `modelpick`, `email-gateway` mention it in comments only.
9. **The wave brief's grep acceptance is not met literally:** the diagrams, the repos in item 8, and four deliberate one-line archive pointers in dotfiles docs still match `grep -i warden`.
