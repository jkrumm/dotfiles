# Setup round 4 — agent-gateway, a loop that ships, fleet-style waves

**Status: PARKED.** Johannes is mid-build elsewhere. Do not start, spawn or
flip any wave to `active` until he gives the explicit go. No worktree or
parallel-branch tricks to "get ahead" — when the go comes, waves run one after
another on the normal branches.

**Goal:** act on the 2026-10-09 holistic review: sideclaw becomes a lean
`agent-gateway` (CLI `agw`), warden ships on every repo instead of feeding
itself, `/wave` gains the shutterflow fleet roles, the global config loses its
contradictions without losing a guardrail, Hermes is audited (not gutted), and
every doc surface describes the final names.

**Gate:** the touched repo's `make check` + `/review` on each wave's diff.
dotfiles: `make check`.

**Pre-flight on go (Wave 0, orchestrator, no code):** the audit numbers below
are a 2026-10-09 snapshot. Re-verify each wave's premises before it starts
(job stats, LOC, ledger counts, open owner actions) and amend the plan in one
`docs:` commit if reality moved.

**Cross-repo:** waves edit sideclaw, warden, hermes-agent, argo, brain,
jkrumm.com, usage-tracker, modelpick, basalt-ui, free-planning-poker,
homelab-private. Each repo gets its own commits; PR-required repos
(`config/pr-required-repos.json`) get a draft PR, never a direct push.

**Owner gates (stop and ask, never decide):** GitHub repo renames (outward),
the PAT/GitHub App scopes, the herdr restart window, the Wave 7 mapping table,
the Wave 8 verdict table, publishing on jkrumm.com.

## Wave 1 — sideclaw: drop the side-panel legacy            <!-- status: pending -->
- [ ] Delete the React UI: `src/`, `index.html`, `vite.config.ts`, `dist/`, `tsconfig.src.json`, `build`/`dev:client` scripts, the static plugin and SSE endpoint (~4k LOC).
- [ ] Delete UI-only routes and libs: `server/routes/{repos,notes,markdown,events,diagrams,kiosk}.ts`, `server/lib/{repo-scanner,markdown-scanner,notes-bus,diagram-bus,diagram-lock,chrome,workspace}.ts` (~1k LOC), and the dashboard-only env keys `PERSONAL_REPOS_PATH`/`WORK_REPOS_PATH`.
- [ ] **Keep:** `GET/POST /api/usage` (statusline + `fetch_usage.py` post to it), `server/lib/excalidraw*.ts` (the `excalidraw_diagram` tool), Octokit in `dispatch-git.ts` (live PR creation).
- [ ] Drop the now-unused deps (blueprint, codemirror, `@uiw/*`, `@excalidraw/excalidraw`, mermaid, shiki, react*, remark/rehype, vite, …) — `bun remove`, then confirm nothing imports them.
- [ ] Delete one-off scripts (`ab-review-angles.ts`, `probe-implement.ts`, `ralph*.sh`) and `docs/ui-and-caching.md`; README stops describing an "offload daemon"/dashboard.
- [ ] `make reload` (drains), then `/api/jobs/health` green and one `check` + one `dispatch investigate` job round-trip.
**Left behind:**

## Wave 2 — rename sideclaw → agent-gateway (core + runtime)            <!-- status: pending -->
Names: repo/service `agent-gateway`, CLI `agw`, MCP server `agent-gateway` (tools `mcp__agent-gateway__*`), env prefix `AGENT_GATEWAY_*`, launchd label `com.jkrumm.agent-gateway`, state `~/.local/{share,state}/agent-gateway`, logs `~/Library/Logs/agent-gateway*`.
- [ ] Scripted codemod (committed under `scripts/`, re-runnable) over the sideclaw repo: identifiers, env vars, paths, docs. Env reads accept `SIDECLAW_*` as a fallback for one deprecation window, logged once at boot.
- [ ] Runtime migration: drain (`make reload` semantics), stop the old agent, move `jobs.db`/`sideclaw.db`/salvage to the new paths, load the **new** label (never reuse `com.jkrumm.sideclaw` — BTM-denied), boot, health green.
- [ ] CLI `agw` on PATH via `make setup`; `sideclaw` stays as a thin deprecation shim that execs `agw` and prints one stderr line.
- [ ] MCP registration in `~/.claude.json` and `config/opencode/opencode.json` → `agent-gateway`. Grep the live `settings.json` and `hooks/` for `mcp__sideclaw` matchers.
- [ ] Owner gate: GitHub repo rename `jkrumm/sideclaw` → `jkrumm/agent-gateway` (GitHub redirects the old URL), local dir `~/SourceRoot/agent-gateway`.
**Left behind:**

## Wave 3 — rename sweep: consumers and docs            <!-- status: pending -->
- [ ] dotfiles: `config/global.CLAUDE.md` ("`sideclaw routing`", the lane table), every skill calling `mcp__sideclaw__*` (check, review, implement, excalidraw-diagram, otel, upgrade-deps, wave, remote-dev, research), `rules/agent-limits.md`, `docs/{agent-platform,architecture,global-reference,remote-dev,opencode}.md`, diagrams, Makefile, statusline, `devhost-health-check.sh`.
- [ ] warden: `scripts/clients/sideclaw.py` → `agent_gateway.py`, tests, docs, the `warden.board_unavailable` caller; LaunchAgents that reference the old paths.
- [ ] hermes-agent, argo (`routes/agents.ts` overview client), usage-tracker, modelpick (skip generated run-log dirs), research-gateway.
- [ ] brain: rename `projects/sideclaw.md` + the narrator's repo map together; wiki pages (`model-routing`, `gateways` — agent-gateway joins the gateway family —, `agent-harness`, `herdr`, `remote-dev-*`). jkrumm.com: `agent-infrastructure.mdx`, `public/diagrams/agent-platform.html`, `facts.ts`.
- [ ] Final grep: `rg -i sideclaw ~/SourceRoot --glob '!node_modules' --glob '!.git' --glob '!**/history/**'` returns only the shim, deprecation fallbacks and archived history.
**Left behind:**

## Wave 4 — agent-gateway hardening            <!-- status: pending -->
- [ ] `narrative` (23% failed): surface the real cause instead of "Session exited with code 1" (deploy the pending `classifyExitFailure`), add one retry/fallback.
- [ ] Alerting: push `/api/jobs/health` (`failedLastHour`, `degradedRoutes`) to Kuma; a failing route pages, not just logs.
- [ ] Keep terminal job rows 90 days (or a slim `usage` table) so effectiveness stats stop needing log scraping.
- [ ] Per-route circuit breaker for IU/Requesty 503s (`check` fell back to Max 69/70 times). Rate-limit `warden.board_unavailable` (18.9k lines of noise).
- [ ] MCP: SDK `^1.32`, `job_cancel` tool, consistent `title` + annotations (`dispatch`: destructive/openWorld), deterministic `tools/list` order. Stay on stdio and 1.x — no v2/Streamable HTTP yet; verify the Tasks extension (`io.modelcontextprotocol/tasks`) status via `/research` and note when `job_wait` can map onto it.
**Left behind:**

## Wave 5 — OpenCode as the settled dispatch default            <!-- status: pending -->
- [ ] Retry transient 503s on write tiers before the worktree is touched; make the "no fallback on half-applied worktree" rule explicit in the result.
- [ ] Fix `session.opencode_db_locked` contention (per-session DB or serialized open).
- [ ] Claude harness for dispatch becomes explicit opt-in (`AGENT_GATEWAY_HARNESS_DISPATCH=claude`); routing doc says so.
- [ ] Dedupe `opencode-runner.ts` / `session-runner.ts` shared code (the fallow-flagged clone).
- [ ] Docs/skills that still say dispatch runs `claude -p` → corrected.
- [ ] From the 2026-10-09 prometheus-scripts run:
  - a busy repo **queues** implement jobs instead of refusing them; a refusal is synchronous and loud, never a "running" ack followed by a refusal one second later
  - the caller may set branch name and PR/MR title (an auto-name `dispatch/remove-openspec-…-c0c0dd73` reached main)
  - editorial briefs (AGENTS.md, docs, prose) route to a Claude model
**Left behind:**

## Wave 6 — warden: ship on every repo, stop feeding itself            <!-- status: pending -->
Premise check (Wave 0): fine-grained PATs have **no Checks permission** (GitHub's fine-grained permission table lists no check-run endpoints), so check-runs stay 403. `scripts/clients/github.py:workflow_runs()` already falls back to Actions runs, and the token reads them (weatherorb: 200, 181 runs on 2026-10-09). The STATE.md "lacks Actions: Read" note looks stale. Confirm the train can land a weatherorb PR via that fallback; if it can, there is no credential change and STATE.md §Open gets corrected. Re-login `gh` on the mini (token invalid).
- [ ] `improve` loop: trigger on outcomes (failed / needs_decision / revision-exhausted items), not hourly; no journal commit for a quiet iteration.
- [ ] Duplicate detection before dispatch (same repo + overlapping brief/carrier); revision cap 2, then one escalation.
- [ ] Remove the 1h "sat in `merged`" deadline expiry in `sweep_deadlines`; rotate/cap `warden-*.err` logs; Kuma monitor on the loop heartbeat.
- [ ] Repo contract (`check`/`deploy`/`verify`) for basalt-ui (draft PR), free-planning-poker (draft PR), homelab-private; bring basalt-ui and jkrumm.com into triage scope.
- [ ] Owner gate: herdr under launchd / restart window (decision open since 2026-10-07 in `docs/improve/JOURNAL.md`). Implement whatever he picks.
**Left behind:**

## Wave 7 — /wave: one simple skill that picks the right shape            <!-- status: pending -->
Evidence, three runs: shutterflow fleet on the MacBook (great; `~/SourceRoot/shutterflow/fleet/{MISSION,PROTOCOL}.md`, `fleet/roles/*.md`, `scripts/fleet/*` over `ssh iumac`, read-only), the IuRoot prometheus-scripts fan-out on 2026-10-09 (great: an orchestrator tab plus 11 herdr worktrees, one Claude per MR, merge train), weatherorb waves (weird; Wave 0 reads its transcripts and PLAN to say why). Port discipline, not machinery. Simplest shape that fits wins.
- [ ] `SKILL.md` opens with a shape picker, three shapes, one paragraph each:
  - **sequential**: the default, one wave at a time in the main checkout. Mandatory when validation is a shared resource (shutterflow: one app build, e2e lock, screenshots).
  - **fan-out**: N independent changes with disjoint files and cheap independent validation. One worktree and Claude tab per change, plus an orchestrator tab running the merge train.
  - **fleet**: long multi-phase work. A lean mother that never reads code, a standing lead that owns review and merge, a fresh worker per task, rotation via `docs/waves/handoff/<name>.md`.
- [ ] Roles and the brief template as files, not prose repeated per run: `skills/wave/roles/{mother,lead,worker}.md`. Brief template fields: owned files, exact branch, title and commit message, validation command, finish with commit, push and draft PR/MR, "never touch files outside your ownership". The four stop reasons from shutterflow MISSION §Autonomy.
- [ ] `rd fan <repo> <brief-files…>` / `rd fan --clean`:
  - creates worktrees through the repo's own tooling, so `.wtp.yml`/setup hooks run (deps install, env/config copy)
  - opens tabs inside the repo's **existing** workspace (never a new workspace per worktree; the prometheus run left 11 under OTHER)
  - starts Claude and sends its brief, with a start-prompt delivery check (context counter off 0k, else re-send; shutterflow measured ~1/6 dropped)
  - also applies the delivery check to `rd wave`
- [ ] Merge train helper (`rd merge`): rebase, checks, merge, re-rebase whenever main moves. GitHub only, **fast-forward/rebase-only** (SourceRoot now; IuRoot work repos move from GitLab to GitHub Enterprise soon, so no GitLab path). Where a push drops approvals: API rebase, then arm auto-merge. Push with `git -C <worktree>` so `protect-branches` judges the worktree, not the orchestrator's cwd.
- [ ] `scripts/wave-watch.py` (from shutterflow `watch.py`) for fan-out and fleet only: wake on an agent leaving `working`/vanishing, an event line, or a 20-min heartbeat. Gates: cheap per-change check, full `make check` at merge, no `done` with "Review: none" without a recorded reason. Update `skills/remote-dev` + `docs/remote-dev.md`.
**Left behind:**

## Wave 8 — global config: contradictions out, guardrails kept            <!-- status: pending -->
No line-count target. Nothing leaves `config/global.CLAUDE.md` without a home.
- [ ] Build a mapping table (old line → kept / moved to `<file>:<section>` / duplicate of `<file>`) for every proposed change. **Owner gate: Johannes reviews the table before any edit is committed.** Operating contract, secrets/mini warnings, herdr, waves, mini vs MacBook, lanes stay verbatim.
- [ ] Fix the lanes contradiction (four lanes vs Explore/@verifier/`/check` vs `global-reference.md` §Parallelism vs `skills/implement`) with one consistent sentence.
- [ ] Narrow the lane table:
  - dispatch = "one bounded change, unattended, in a repo you are not working in"; it is no longer "default for settled multi-file edits", which pushed the prometheus run into dispatch first
  - "N independent changes in one repo" → `/wave` fan-out
- [ ] Sweep checked-in repo `.claude/settings.json` for `ask` permission rules. They still prompt under `--dangerously-skip-permissions` and stall unattended agents (push, glab). Hard stops go in `deny`; personal prompts belong in `settings.local.json`. Add a one-line rule to `docs/agents-md.md`.
- [ ] Model ids out of prose: `AGENTS.md:~441`, `docs/{opencode,codex,agents-md,agent-platform}.md`, `skills/podcast/SKILL.md` → point at routing.
- [ ] `rules/dockerfile.md:11,86` dead reference to `docker-makefile.md`. `docker-makefile.ts` (762 lines): shrink to a deny list of destructive verbs + a `make help` hint, keep the tests meaningful.
- [ ] Housekeeping: `~/.claude/skills/.trash`, redundant allow-list entries, `docs/hooks.md` title/event count, fold `docs/herdr.md` into `remote-dev.md`, `sc-note.md` at repo root.
**Left behind:**

## Wave 9 — Hermes: audit and improve the wiring (no blind deletion)            <!-- status: pending -->
- [ ] Verdict table for every live skill in `~/.hermes/skills` (73 + 24 archived): learn-from (pattern worth porting into our skills) / adapt-port / keep in Hermes / retire, with a one-line reason. **Owner gate: Johannes picks before anything is disabled.**
- [ ] Wiring map Hermes ↔ global setup: shared facts duplicated in Hermes skills (`herdr` 279 vs 195 lines, `podcast`, research, homelab/homelab-ops, dispatch/warden) → which become links to one doc, which stay Hermes-specific.
- [ ] Port the "learn-from" patterns into dotfiles skills as agreed; remove retired terms (`agent-dispatch`, `rd bg`, "colleague", `claude --bg`) from `capture` and `herdr`.
- [ ] Review the stale/oversized ones (`karakeep`, `reading`, `work` 618 lines); add a check that the live skill set matches the declared `HERMES_SKILLS` list.
**Left behind:**

## Wave 10 — docs on every surface            <!-- status: pending -->
- [ ] jkrumm.com `personal-stack.mdx` (published, stale: CLAUDE.md → AGENTS.md, Grafana/Loki → ClickStack, no agent stack); `agent-infrastructure.mdx` "rolling out" paragraph → current; cross-link the two. **Publishing is the owner's call.**
- [ ] brain: `agent-overview-loop.md` and `agent-harness.md` rewritten or bannered superseded; `Areas/Engineering/Engineering.md` links the agent platform page; rename `agent-estate-model` → `agent-platform` (keep an alias); four superseded pages → one History page.
- [ ] Narrator prompt stops writing "merge-approval gate" for warden; one human "daily workflow" note in brain Areas/Engineering (lanes, waves with roles, Argo/Hermes queue).
- [ ] Website diagram generated from or pointing at `dotfiles/docs/diagrams` source.
**Left behind:**

## Wave 11 — AGENTS.md only, no CLAUDE.md shims            <!-- status: pending -->
Independent of the other waves, so it can run in any quiet slot, but before Wave 8 rewrites `docs/agents-md.md` is cleanest. Premise re-measured 2026-10-09 on Claude Code 2.1.295: a repo with only `AGENTS.md` loaded it on the IU endpoint with a **cold** `CLAUDE_CONFIG_DIR` and with a warm one (`docs/agents-md.md` §Why not a bare AGENTS.md is stale; per the docs, the flag dependency ended in v2.1.281). Any `CLAUDE.md`/`CLAUDE.local.md` in cwd or above suppresses direct AGENTS.md reading, so the shims are what must go.
- [ ] Re-run the measurement matrix (Max `c`/`claude -p`, IU warm, IU cold, `rd wave`, an agent-gateway dispatch worker, OpenCode, Codex) with root + nested AGENTS.md and no CLAUDE.md. Rewrite `docs/agents-md.md`: AGENTS.md is the only per-repo file; never commit `CLAUDE.local.md` (it suppresses AGENTS.md); `InstructionsLoaded` hooks don't fire for directly read AGENTS.md (none in use today).
- [ ] Delete every 11-byte `@AGENTS.md` shim, root and nested (~30 across SourceRoot, incl. `argo/apps/{api,dashboard}`, `basalt-ui/apps/marketing`, `free-planning-poker/{apps/server,fpp-analytics}`). One commit per repo; PR-required repos get a draft PR.
- [ ] basalt-ui (own commit, draft PR): the CLI placement engine (`src/cli/index.ts`, `agent/templates/CLAUDE-block.md.tpl`, `placement-engine`/`template-ledger`/`doctor` tests) writes the `<!-- basalt:start/end -->` block into **AGENTS.md** and migrates an existing CLAUDE.md block on upgrade. Then re-run it in the consumers: argo, basalt-ui-obsidian, image-gen, image-share/apps/admin, linewatch/web, rb, weatherorb/apps/web.
- [ ] `basalt-ui/packages/basalt-ui/CLAUDE.md` (50 KB, real content next to an AGENTS.md): merge it into that AGENTS.md deliberately. It references `../../CLAUDE.md`, and `agent/` ships to npm, so check what consumers rely on.
- [ ] `sy-serendipity/CLAUDE.md` (3.4 KB, no AGENTS.md) → `AGENTS.md`. Leave `modelpick/fixtures/**` (benchmark fixture) and vendored `.venv` files alone. Update every AGENTS.md "CLAUDE.md shim" mention, `scripts/architecture-check.sh` or any lint that asserts the shim, and `Projects/dotfiles.md` in brain.
**Left behind:**
