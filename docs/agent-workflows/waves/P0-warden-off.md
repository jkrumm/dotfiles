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
