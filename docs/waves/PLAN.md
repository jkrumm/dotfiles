# dotfiles — one core, four lanes, one repo contract

**Goal:** the dotfiles side of `docs/agent-platform.md`: four lanes, a global
CLAUDE.md that routes instead of restating, `/wave` with an orchestrated mode,
OpenCode parity, the repo contract applied across every repo, and the platform
documented once (dotfiles → brain → jkrumm.com draft).

**Gate:** `make architecture-check secrets-lint hooks-test` (or `make check` once W1 adds it) + `/review` on each wave's diff.

**Spec:** `docs/agent-platform.md` — read it first.

**Live system:** `config/global.CLAUDE.md`, `rules/`, `skills/`, `agents/` are symlinked into `~/.claude` and load in every session, including this one. Edits are live on save — keep each file valid at every commit.

**Cross-repo:** Wave 3 and Wave 4 edit other repos; each repo gets its own commits. PR-required repos (`config/pr-required-repos.json`) get a draft PR, never a direct push.

## Wave 1 — lanes, contract, a lean global CLAUDE.md            <!-- status: active -->
- [ ] `docs/agents-md.md` gains the repo contract (spec §Repo contract) as the authority. dotfiles itself gets `check` (= architecture-check + secrets-lint + hooks-test), a target wrapping setup, `verify` (= doctor), `logs`.
- [ ] Four lanes (spec §Four lanes). Delete `rd bg` and `scripts/agent-dispatch.sh` + its PATH link **after** grepping consumers in `~/SourceRoot/{hermes-agent,warden,sideclaw}`: code callers block the deletion (note them in Left behind, hermes-agent's plan removes them); doc callers just get updated. Remove the "colleague" lane wording everywhere. Put `rd` (as a script, not only a zsh function), `ask-human` and `warden` on PATH in `~/.local/bin` via `make setup`.
- [ ] `config/global.CLAUDE.md` 23k → ≤10k chars: every model id → "see `sideclaw routing`"; move basalt-ui consumers, sudo, dev proxy, IuRoot repo list, Codex lane, parallelism tiers, async-contract detail, skills table behind links (docs/ or the owning repo). The operating contract lives here once; `config/output-styles/Direct.md` keeps tone only. Fix Direct.md's "multi-file edits → @implementer" to match the lanes.
- [ ] Fix the stale facts list (dotfiles audit #3–#18): ask-human push default, `rd wave` creates a tab not a workspace, herdr restart via `make herdr-restart`, verifier in AGENTS.md, one launcher table, repo descriptions in exactly one place, `dispatch-scratch` duplicate row. AGENTS.md back under its own 40k limit by moving Codex / OpenCode / Theme / Tailnet sections to docs/.
- [ ] Make `dependency-hygiene`, `agent-limits`, `typescript` (`paths: **/*.ts,**/*.tsx`), `commit-conventions` lazy; delete the `docker-makefile` rule (the hook enforces it).
**Left behind:**

## Wave 2 — /wave orchestrated mode, OpenCode parity            <!-- status: pending -->
- [ ] `/wave` gets two modes (spec §herdr): **chain** (today) and **orchestrated**: the orchestrator tab runs `rd wave`, then `herdr agent wait <agent> --until done` (one blocking call), reads PLAN.md, decides the next. Fix the busy guard so a working orchestrator tab in the same repo does not block its own spawns. Auto-close the finished wave tab after its close-out commit is pushed.
- [ ] `rd wave` / `rd work` accept `--kind opencode`.
- [ ] Merge the agent-control half of the `remote-dev` skill with herdr guidance into one skill; keep the generated herdr skill as raw reference only. Fix remote-dev skill stale facts (#8–#11).
- [ ] OpenCode parity: add research-gateway and chrome-devtools MCP to `config/opencode/opencode.json`; symlink `agents/` into `~/.config/opencode/agent/`; add the lazy global rules to `instructions`; a small branch-protection plugin mirroring `hooks/protect-branches.ts`; GPT ids on an `@ai-sdk/openai` (Responses) provider — generated from sideclaw's registry if sideclaw Wave 1 is done, else hand-written with a pointer.
**Left behind:**

## Wave 3 — repo contract sweep            <!-- status: pending -->
- [ ] For every repo in the readiness table (in this wave's brief below), add the four Make targets (aliases / thin wrappers around existing scripts are fine) and the four AGENTS.md sections with real values (full health URL, Kuma monitor name, OTel `service.name`). Skip warden, sideclaw, hermes-agent, dotfiles (their own plans cover them) and brain, kobo-mods, dotfiles-private (no runtime; `check` only if trivial). homelab-private: contract only, never mention its contents elsewhere.
- [ ] Delegate per repo via `mcp__sideclaw__dispatch` (tier implement, `workspace: "in-place"`) in batches of 3; read every diff before committing it in that repo.
- Readiness snapshot (2026-10-02): has `check` → add rest: audio-gateway, email-gateway, image-gen, linewatch, research-gateway. Makefile but no `check`: homelab, king-smith-walkingpad-mac, rb, weatherorb, usage-tracker, modelpick, basalt-ui (PR), basalt-ui-obsidian, vps (`deploy APP=x` / `verify APP=x`). No Makefile: argo, image-share, jkrumm.com, free-planning-poker (PR), rollhook (PR), rollhook-action (PR). Missing AGENTS.md: rollhook-action, usage-tracker.
**Left behind:**

## Wave 4 — document the platform            <!-- status: pending -->
Runs after warden Wave 2 and sideclaw Wave 1 are done, so the docs describe the real thing.
- [ ] `docs/architecture.md` mental-model section → short, links `docs/agent-platform.md`; update `agent-platform.md` STATUS to what has landed.
- [ ] Brain: `wiki/engineering/agent-estate-model.md` becomes the human-readable page for the platform (or symlinks `agent-platform.md`, matching how `dotfiles-architecture.md` works); fix `gateways.md` (research-gateway is mini-only; add email-gateway, image-share); mark superseded pages (`warden-control-plane.md`, `hermes-as-control-surface.md`, `agent-dispatch-paths.md`) as pointers. Load `~/SourceRoot/brain/voice.md` first.
- [ ] One diagram of the picture via `/archify`, embedded in brain and the site.
- [ ] jkrumm.com: rewrite `src/content/guide/personal-stack.mdx` (or add `agent-infrastructure.mdx`, `order: 2`) as `status: draft` — concise, rendered version of the spec, no hostnames/IPs/secrets (rules/security.md). **Publishing is the owner's call** — stop after the draft commit.
**Left behind:**
