# agent-workflows — dotfiles lane

**Goal:** warden is switched off with no caller left, every former warden alert reaches Slack, and the setup docs describe three lanes (P0 of `docs/agent-workflows/concept.md` §11).
**Gate:** `make check` in dotfiles and `make doctor` on the mini, both green; `/review` on the non-doc changes.

## Wave 1 — Switch warden off (P0)            <!-- status: active -->
Brief: `docs/agent-workflows/waves/P0-warden-off.md` — its Rules and Acceptance bind this wave.

- [ ] Inventory every warden caller and alert path; write it into the brief's `## Inventory`
- [ ] Kill switch, final backup copied to the HomeLab
- [ ] Kuma, HyperDX and jobs-grade alerts rerouted to Slack, each proven
- [ ] Callers removed: dotfiles (global CLAUDE.md, AGENTS.md, docs, rd help, skills), Hermes, Argo, the rest of the inventory
- [ ] LaunchAgents unloaded, architecture map fixed, `warden/AGENTS.md` status line
- [ ] Brief's `## Findings` filled; Acceptance list met
**Left behind:**
