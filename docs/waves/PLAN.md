# Clean setup: no retired wiring, no headless claude

**Goal:** nothing on the mini, in dotfiles or in the repos that agents read still names, calls or starts a
retired service (warden, agent-gateway, research-gateway, audio-gateway, `agw-legacy`, dispatch), and no
script or skill runs headless `claude -p`. Owner decisions 2026-10-30
(`docs/factory/feedback/2026-10-30-owner-voice-note-replan.md` and the chat after it): warden is gone for good;
no `claude -p` anywhere; interactive sessions in herdr, native subagents and `agw` workflows are the only lanes.
Input: the setup audit of 2026-10-30, findings quoted per step below.
**Gate:** `make check` in every repo a wave touched, `make doctor` on the mini, both green; `/review` on the
non-doc changes; `rg` for the retired names (step list in Wave 2) returns only legitimately historical hits.

## Wave 1 — Headless claude out, docs true            <!-- status: done -->
Workers: Sonnet; Haiku subagents for the mechanical doc edits. Orchestrated: do NOT spawn Wave 2.

- [x] **No `claude -p`.** Replace every live caller:
  - `brain/brain-backup.sh:145` and `brain/brain-sync.sh:377` write commit messages with `claude -p --model haiku`.
    Use an existing `agw` capability if one fits (check `agw --help`); otherwise a deterministic message from
    the diff (files and counts). A hang can no longer hold the brain-sync lock.
  - `skills/analyze/SKILL.md`: drop the `claude_iu` subprocess and its hard-coded model id (`:127`); run fallow
    in a native subagent (the report still stays out of the main context).
  - `skills/implement/SKILL.md:64`: drop the `claude -p … --allowedTools` fan-out; point at `/wave` fan-out.
  - The `claude_iu` launcher: if no caller is left, remove it with its docs (`AGENTS.md:440`,
    `config/global.CLAUDE.md` "subprocess `claude_iu --model sonnet`", `config/zsh/claude.zsh`), and say whether
    `hooks/iu-model-guard.ts` still has a job. Keep it only if a real caller remains, and name it.
  - Two kept on purpose, documented as the only exceptions: `scripts/claude-accounts-e2e.sh` (it tests the
    launchers themselves, a few Haiku tokens per account) and modelpick's bench (it measures the Claude Code
    harness). Write both into `docs/agent-platform.md` as "the only headless runs".
- [x] **`docs/agent-platform.md` describes what runs:** `:28` ("designed … not built") is wrong, it is built;
  delete the "Agent-Gateway — the engine" section (`:94-107`) and point at `agw routes`; `:74` engine is
  Claude Code only (`--kind opencode` is rejected); `:41` drop the warden-era diagram link.
- [x] **Diagrams:** `docs/diagrams/{agent-platform,estate}.architecture.json` and `dispatch-path.sequence.json`
  (and their HTML) are warden-era: move to `docs/archive/diagrams/`, and stop `docs/architecture.md:43-46`
  presenting them as current. Same for `jkrumm.com/public/diagrams/agent-platform.html` only if jkrumm.com links
  it as current (check; it is a public site, so a removal is a jkrumm.com commit of its own).
- [x] **Smaller truths:** `skills/otel/SKILL.md:153` service names are `agw` and `agw-audio`, not
  `audio-gateway`; `docs/opencode.md:76` (chrome-devtools is wired); `rules/research-first.md:12` and
  `agents/implementer.md:32-33` (Context7 → `agw web docs`); `skills/prose/SKILL.md:3` ("agw lint" is not a
  command); `config/settings.template.json:5` drop `MCP_TOOL_TIMEOUT` (it served research-gateway's MCP);
  `config/global.CLAUDE.md:88` and `config/zsh/claude.zsh:175` "IU tokens are for gateways" → for `agw`,
  OpenCode and Hermes; `docs/global-reference.md:42-48` lists `/router`, and `/podcast` and `/img` as agw-backed;
  archive `docs/waves/claude-accounts-handover.md`.
- [x] **Stale comments** (Haiku): `scripts/lib/launchd-restarts.sh:23-27,92-95`, `scripts/herdr-groups.py:35`,
  `scripts/fetch_usage.py:267`, `scripts/human-queue-notify-hook.sh:8`, `scripts/drift-check.sh:21`,
  `scripts/disk-sweep.sh:9,104` (check whether `~/.opencodereview/sessions` is still written; drop the step if
  not), `config/Caddyfile:221-223` (iris binds 7730), `config/gitignore_global:5`,
  `.claude/skills/iu-endpoint/models.txt:10`, the LaunchAgent plist comments (`jobrun-canary`,
  `modelpick-refresh`, `usage-tracker`, `weatherorb.retention`, `weatherorb.verify`: fix the templates and
  re-render), `scripts/claude-account.test.ts` agent-gateway lane fixtures if those lanes no longer exist.
- [x] Run `make setup`/the relevant install target so `~/.claude` matches the template, then the gate.

**Left behind:**
Commits `4f69ef4`..`915bf0a` on dotfiles master (pushed); one `docs:` commit each in modelpick, weatherorb, usage-tracker.
`make check` and `make doctor`: green except two failures that fail identically on clean `ebed695`, unrelated to this wave:
`architecture-check` (loaded `com.iu.athena-postgres` unmapped; `docs/architecture.md` rows `com.iu.teamchat-*` absent on the mini)
and `drift-check` (collie pin, tailscale daemon). `/review`: clean, 5 improvements, 3 applied (SIGPIPE-safe `AREAS`, `T` in the
modified count, a wildcard home-lane test), 2 not (duplicated message builder stays duplicated on purpose; settings note below).
- `claude -p` is gone from every live caller. Brain commit messages are `chore(brain): … (+A ~M -D rN; areas)` from the diff.
  `claude_iu` is removed; `claude-accounts-verify` now FAILs if it (or `ca cap cdf cdp`) comes back. `hooks/iu-model-guard.ts` stays:
  it is the backstop for any hand-rolled IU runner (no launcher sets IU any more). `/analyze` now costs Sonnet on Max, not IU Haiku.
- Two headless exceptions written into `docs/agent-platform.md` (§No headless claude).
- **Not done, for the orchestrator:**
  - `jkrumm.com` embeds `public/diagrams/agent-platform.html` in the Agent Infrastructure guide as current, and its `make diagrams` copies
    from `dotfiles/docs/diagrams/agent-platform.html` (now archived: path breaks). Untouched: the guide text is the owner's call.
  - `modelpick/src/db/deployments.ts` `analyze` slot still says "via claude_iu", `SKILL.md:127`; update with the registry's next snapshot.
  - The plan's plist re-render was skipped: the five fixes were comment-only in templates of other repos (committed there), and
    `plist.template` for `jobrun-canary` was already true; `weatherorb.retention/verify` are not templates. Re-render on next install.
  - `settings.template.json` `_NOTE` and `claude.zsh` `oc` comment still mention `ca`; `weatherorb/ops/clickstack/sync.py` has `warden:skip`;
    `docs/diagrams/episode-lifecycle.*` mentions dispatch once. All for Wave 2's final `rg` sweep.
  - `~/.claude` and every extra account dir got the new `settings.json` (`make _setup-settings`, `claude-accounts-setup`).


## Wave 2 — Other repos and the disk            <!-- status: active -->
Workers: Sonnet; Haiku for the sweeps. Orchestrated.

- [ ] **hermes-agent:** `skills/verify/references/agent-claim-verification.md:111` and
  `skills/homelab-ops/references/restart-window-prep.md:73` curl warden's port 7735 (nothing listens);
  `skills/herdr/SKILL.md:24,56,82,89` examples use `--cwd ~/SourceRoot/warden` (deleted); `README.md:34-39`
  (deepseek brain, warden channels), `.env.tpl:78`, `Makefile:21`, `docs/scheduled-jobs.md:50-53`,
  `docs/symlinks-and-agents.md:39-50`.
- [ ] **vps:** `Makefile:60,118,131,528-537` still bring up an `audio-gateway` stack and `AGENTS.md:201,538`
  list `apps/audio-gateway` and its Kuma monitor; the container is not running on the VPS (checked 2026-10-30).
  Remove the stack, the app directory, the monitor in `homelab/uptime-kuma/monitors.yaml` (`make uk-sync`) and
  any RollHook registration for the retired repo.
- [ ] **brain:** `AGENTS.md:329` cites `hermes-agent/config/dispatch-repos.json`, which does not exist.
- [ ] **Disk:** delete `~/SourceRoot/{agent-gateway,research-gateway,audio-gateway}` and the data dirs
  `~/.local/share/agent-gateway` (5 GB) and `~/.research-gateway` (1.7 GB), each only after checking its final
  backup on `homelab:/mnt/hdd/backups/<name>-final/` against its `SHA256SUMS`. research-gateway has an unpushed
  branch `feat/paper-reading-and-liveness` (worktree `.claude/worktrees/paper-liveness`, commit `036d7c5`) and
  the GitHub repo is archived: prove the final bundle contains it (`git bundle list-heads`), or write a bundle
  of that branch next to it, before deleting. warden is already gone (2026-10-30).
- [ ] **herdr:** close duplicate and dead workspaces (three `hermes-agent` spaces today) only where no agent is
  working and nothing is unpushed; one space per repo is the rule.
- [ ] **Leftovers of Wave 1 and of Hermes leaving Argo:**
  - `jkrumm.com/Makefile:30` `make diagrams` copies from `dotfiles/docs/diagrams/agent-platform.html`, which moved to
    `docs/archive/diagrams/`: repoint `DIAGRAMS_SRC` so the target works. The guide's text stays as it is.
  - `modelpick`: `src/db/deployments.ts` `analyze` slot and `SKILL.md:127` still say "via claude_iu".
  - `config/settings.template.json` `_NOTE` and the `oc` comment in `config/zsh/claude.zsh` still mention `ca`;
    `weatherorb/ops/clickstack/sync.py` `warden:skip`; `docs/diagrams/episode-lifecycle.*` mentions dispatch once.
  - **Hermes API on loopback** (argo's close-out, `argo/docs/waves/PLAN.md`): `API_SERVER_HOST` is still the mini's
    tailnet address, which iris also reads as `HERMES_HOST`. Change `hermes-agent/.env.tpl` and `iris/.env.local.tpl`
    together, adjust `hermes-agent/scripts/verify.sh` and the `hermes-validate` skill's `$host:8642` probe, restart
    `ai.hermes.gateway` and iris (`make launchd-restart`), prove iris reaches Hermes (a memo routed to Hermes, not
    just `/health`). Do it only if no iris wave or fan worker is `working`; otherwise leave it in Left behind.
- [ ] The gate's final sweep: `rg -n -i 'agent-gateway|research-gateway|audio-gateway|agw-legacy|warden|dispatch'`
  across `~/SourceRoot` (excluding archives, `docs/factory/`, node_modules, IuRoot), every hit either fixed or
  listed in Left behind as historical.

**Left behind:**
