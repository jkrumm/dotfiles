# agent-workflows — dotfiles lane

**Goal:** warden is switched off with no caller left, every former warden alert reaches Slack, and the setup docs describe three lanes (P0 of `docs/agent-workflows/concept.md` §11).
**Gate:** `make check` in dotfiles and `make doctor` on the mini, both green; `/review` on the non-doc changes.

## Wave 1 — Switch warden off (P0)            <!-- status: done -->
Brief: `docs/agent-workflows/waves/P0-warden-off.md` — its Rules and Acceptance bind this wave.

- [x] Inventory every warden caller and alert path; write it into the brief's `## Inventory`
- [x] Kill switch, final backup copied to the HomeLab
- [x] Kuma, HyperDX and jobs-grade alerts rerouted to Slack, each proven
- [x] Callers removed: dotfiles (global CLAUDE.md, AGENTS.md, docs, rd help, skills), Hermes, Argo, the rest of the inventory
- [x] LaunchAgents unloaded, architecture map fixed, `warden/AGENTS.md` status line
- [x] Brief's `## Findings` filled; Acceptance list met
**Left behind:** warden is off and has no caller in dotfiles, Hermes, Argo (PR #205 merged and live), agent-gateway (deployed), homelab, vps. Findings with evidence: `docs/agent-workflows/waves/P0-warden-off.md` `## Findings`. Open for the orchestrator/owner:
- `make check` and `make doctor` stay red on pre-existing, unrelated items (IuRoot teamchat/athena LaunchAgents unmapped in architecture.md; collie pin and tailscale daemon drift). Every other check target and all warden-related doctor rows are green.
- ACL grant removal (`dotfiles-private` `4fc5b42`) is queued in human-queue because the MacBook was unreachable; after the push, drop `GUARD_SRC_TAGS` from `scripts/caddy-tailnet.sh`.
- Not literal-grep-clean: generated diagrams, other repos' prose, 4 archive pointers (Findings #8-9). Credentials `WARDEN_BOT_TOKEN` and the two ingest tokens are unused but not revoked (Findings #7).
- `/review` (agent-gateway, 5 of 6 angles; architect timed out) found 2 blocking issues in the Slack path, both fixed in `fix(jobs-grade)`; the improvements list was applied except the complexity refactor of `readCronStates`/`gradeOne`.
- No next wave in this plan; nothing spawned.
