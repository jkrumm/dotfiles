# Track D: the factory's v2.4 material leaves dotfiles

**Goal:** `docs/factory/` is archived, the evidence the factory still uses (golden set, intervention KPIs) lives in
`software-factory/docs/evidence/` and runs from there, and no live doc in dotfiles, agent-workflows or brain points at
the old path as if it were current.
**Gate:** `make check` in dotfiles fails only on the known pre-existing items (`architecture-check`: the `com.iu.*`
agents; `drift-check`: collie pin, tailscale daemon); the moved evidence scripts re-run in their new home and their
`.out.json` files diff clean; `rg -n 'docs/factory' ~/SourceRoot --glob '!**/archive/**' --glob '!**/node_modules/**'`
has no hit outside history, each remaining one listed in Left behind.

Program: `software-factory/docs/program.md`, track D. The program lead reviews the close-out and spawns nothing after it.

## Wave 1 — Archive and move            <!-- status: done -->
Sonnet. Read `software-factory/docs/decisions.md` ("Smaller", last bullet) and `docs/factory/evidence/README.md` first.

- [x] **Move the evidence into software-factory, in its own worktree** (never edit `~/SourceRoot/software-factory`'s
  main checkout: the program lead commits there). `git -C ~/SourceRoot/software-factory fetch` then
  `git -C ~/SourceRoot/software-factory worktree add .claude/worktrees/evidence -b evidence origin/master`. Copy
  `docs/factory/evidence/{README.md,DEFINITIONS.md,lib,golden,interventions,kpi}` to `docs/evidence/` there, plus any
  other `evidence/*` directory a golden or KPI script imports (find out by running them, not by guessing). Fix paths
  so every script runs from its new home (`python3 -I`), re-run each one and confirm its `.out.json` diffs clean or
  only by the paths. software-factory is public: run `lib/redact.py --check` on every moved file. Add one line
  to software-factory's `AGENTS.md` "Start here" for `docs/evidence/`. Commit there (`docs: the golden set and the
  intervention KPIs move here from dotfiles`), `git -C <worktree> rebase origin/master`, push to master, remove the
  worktree and the branch.
- [x] **Archive the rest:** `git mv docs/factory docs/archive/factory-v2.4`. Untracked and ignored weight under it
  (`node_modules`, `.runtime/`, `__pycache__`, the spike `*.log` files): list it, keep any log a tracked doc cites by
  moving it as tracked, delete the rest. Write a three-line `docs/archive/factory-v2.4/README.md`: what this was, that
  `software-factory` superseded it (`docs/decisions.md` there), where the evidence went.
- [x] **Repoint references:** `config/Caddyfile` comment (the plannotator block cites an ADR path), every live
  doc/skill/rule in dotfiles, and brain (`~/SourceRoot/brain`, commit there separately). Historical pages and
  archived plans keep their text.
- [ ] **agent-workflows `docs/factory-input.md`:** point "the factory re-plan (dotfiles `docs/factory/`…)" at
  `software-factory` (decisions, design, program) and drop wording that treats TDD v2.4 as current. Only if no
  agent in `rd agents` is `working` in `~/SourceRoot/agent-workflows`; otherwise write the exact edit into Left behind.
- [x] The gate, then close out per the `/wave` skill (orchestrated: do not spawn anything).

**Left behind:**
- Evidence is in `software-factory/docs/evidence/` (commit `bed3ff1`, pushed; worktree and branch removed). Moved: `README.md`,
  `DEFINITIONS.md`, `lib`, `golden`, `interventions`, `kpi`, plus `signals/topology.out.json` (the one file `golden/backtest.py`
  reads; no script edit needed, `HERE.parent.parent / "evidence"` resolves in the new home). Scripts are unchanged apart from
  three `Run:` docstring paths. Its README has a new Reproducibility section; software-factory `AGENTS.md` "Start here" names
  `docs/evidence/`. The archive in dotfiles keeps the full original evidence tree, including `snapshot.sh`, `signals/` etc.
- Re-run in the new home, `.out.*` diff clean: `golden/agreement.py`, `kpi/{baseline,decision_shadow,engine_policy,owner_pages,forecast}.py`,
  `kpi/run.sh` (baseline), `interventions.py report`. **Do not diff clean, and the original outputs were restored as the frozen
  record:** `golden/sample.py`/`chunk.py` (fewer local clones, so fix links resolve differently), `kpi/cost.py` (agent-gateway
  OpenCode store gone, priced share 96 % to 75 %), `kpi/{git_delivery,dora,quota,herdr_hygiene}.py` (live git/herdr, 3-day usage
  retention). `golden/backtest.py --verify` says DIFFERENT, and says so in the old home too: pre-existing, not a path issue.
- `lib/redact.py --check` is clean on every moved file except `lib/redact.py` itself, which matches its own `okta|epos`
  pattern line. It is the same file already public in dotfiles; software-factory is public too. Owner call whether to obfuscate
  the pattern or drop the line from the repo.
- Archive: `docs/archive/factory-v2.4/` (pure renames, 693 files) plus `README.md` and the four spike-05 logs a tracked
  report cites (redact-clean, added with `git add -f`). Deleted: `node_modules` (4 spike trees, `report/pele`), `.runtime/`,
  `__pycache__`.
- Repointed: `config/Caddyfile` comment; brain `wiki/engineering/{software-factories,opencode}.md` (brain commit `0cebbf7`, pushed).
- **agent-workflows edit NOT done**: `agent-workflows-w1` is `working` there. Exact edit for `docs/factory-input.md` lines 3-5,
  replace `re-plan (dotfiles `docs/factory/`, TDD v2.4, deferred by N1) starts from` with
  `re-plan (`software-factory`: `docs/decisions.md`, `docs/design.md`, `docs/program.md`) starts from`. The rest of that page
  does not call TDD v2.4 current.
- `rg 'docs/factory'` hits that remain, all history or program text (not edited): software-factory `docs/decisions.md` (9-10, 89),
  `docs/program.md` (46, 61) in the program lead's checkout; this PLAN.md; dotfiles `docs/agent-workflows/waves/P0-warden-off.md:14`
  (archived wave plan); agent-workflows `docs/waves/handoff/{mother.md,STOP}`, `docs/research/2026-10-28-research-three-way.md`,
  `docs/concept.md` (24, 26, 251, 461: dated status/input lines), `docs/spikes/opencode-wedge/scripts/replay-dotfiles.sh:3`,
  and the `docs/factory-input.md` hit above. Of these, `concept.md:251` and `research-three-way.md:7` cite files that now live at
  `dotfiles/docs/archive/factory-v2.4/...`; repoint in the same agent-workflows pass if wanted.
- Gate: `make -k check` fails only `architecture-check` (the `com.iu.*` agents); `agw check` stops there, `drift-check` raised nothing.
  Review: docs-only moves and comment edits, no `/review` run.
