# Track D: the factory's v2.4 material leaves dotfiles

**Goal:** `docs/factory/` is archived, the evidence the factory still uses (golden set, intervention KPIs) lives in
`software-factory/docs/evidence/` and runs from there, and no live doc in dotfiles, agent-workflows or brain points at
the old path as if it were current.
**Gate:** `make check` in dotfiles fails only on the known pre-existing items (`architecture-check`: the `com.iu.*`
agents; `drift-check`: collie pin, tailscale daemon); the moved evidence scripts re-run in their new home and their
`.out.json` files diff clean; `rg -n 'docs/factory' ~/SourceRoot --glob '!**/archive/**' --glob '!**/node_modules/**'`
has no hit outside history, each remaining one listed in Left behind.

Program: `software-factory/docs/program.md`, track D. The program lead reviews the close-out and spawns nothing after it.

## Wave 1 — Archive and move            <!-- status: active -->
Sonnet. Read `software-factory/docs/decisions.md` ("Smaller", last bullet) and `docs/factory/evidence/README.md` first.

- [ ] **Move the evidence into software-factory, in its own worktree** (never edit `~/SourceRoot/software-factory`'s
  main checkout: the program lead commits there). `git -C ~/SourceRoot/software-factory fetch` then
  `git -C ~/SourceRoot/software-factory worktree add .claude/worktrees/evidence -b evidence origin/master`. Copy
  `docs/factory/evidence/{README.md,DEFINITIONS.md,lib,golden,interventions,kpi}` to `docs/evidence/` there, plus any
  other `evidence/*` directory a golden or KPI script imports (find out by running them, not by guessing). Fix paths
  so every script runs from its new home (`python3 -I`), re-run each one and confirm its `.out.json` diffs clean or
  only by the paths. software-factory is public: run `lib/redact.py --check` on every moved file. Add one line
  to software-factory's `AGENTS.md` "Start here" for `docs/evidence/`. Commit there (`docs: the golden set and the
  intervention KPIs move here from dotfiles`), `git -C <worktree> rebase origin/master`, push to master, remove the
  worktree and the branch.
- [ ] **Archive the rest:** `git mv docs/factory docs/archive/factory-v2.4`. Untracked and ignored weight under it
  (`node_modules`, `.runtime/`, `__pycache__`, the spike `*.log` files): list it, keep any log a tracked doc cites by
  moving it as tracked, delete the rest. Write a three-line `docs/archive/factory-v2.4/README.md`: what this was, that
  `software-factory` superseded it (`docs/decisions.md` there), where the evidence went.
- [ ] **Repoint references:** `config/Caddyfile` comment (the plannotator block cites an ADR path), every live
  doc/skill/rule in dotfiles, and brain (`~/SourceRoot/brain`, commit there separately). Historical pages and
  archived plans keep their text.
- [ ] **agent-workflows `docs/factory-input.md`:** point "the factory re-plan (dotfiles `docs/factory/`…)" at
  `software-factory` (decisions, design, program) and drop wording that treats TDD v2.4 as current. Only if no
  agent in `rd agents` is `working` in `~/SourceRoot/agent-workflows`; otherwise write the exact edit into Left behind.
- [ ] The gate, then close out per the `/wave` skill (orchestrated: do not spawn anything).

**Left behind:**
