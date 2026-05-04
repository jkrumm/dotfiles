---
name: ship
description: Full deployment flow — auto-detects state, runs check/review/commit/PR/CodeRabbit iteration/merge/release. Smart direct-to-master vs PR detection.
model: haiku
---

# Ship — Full Deployment Orchestrator

Smart skill that detects current git/PR state and runs the appropriate steps to get code shipped.

## State Detection

Run these checks in order to determine where we are:

```bash
# 1. Any uncommitted changes?
git status --porcelain

# 2. Current branch
git rev-parse --abbrev-ref HEAD

# 3. Commits ahead of remote
git log @{u}..HEAD --oneline 2>/dev/null

# 4. Existing PR for this branch
gh pr view --json state,statusCheckRollup,reviews,url 2>/dev/null
```

## Flow Decision

### Direct-to-Master Repos
If the repo name matches: `homelab`, `homelab-private`, `vps`, `dotfiles`, `sideclaw` — OR if on the default branch with small changes:
1. Run `/check` (skip for `homelab`, `homelab-private`, `vps`, `dotfiles` — config/infra repos with no lint/typecheck)
2. Run `/commit` (if uncommitted changes)
3. `git push`
4. Done

### PR Flow (all other repos)
Based on detected state, pick up from the right step:

**Step 1 — Uncommitted changes exist:**
- Run `/check`
- If check fails → fix errors, re-run
- Run `/commit`

**Step 2 — Committed but no PR:**
- Run `/review` (CodeRabbit CLI + Claude review)
- If review finds issues → ask user: implement fixes? (default: yes for clear fixes, ask for subjective ones)
- If fixes made → amend commit (`git reset --soft HEAD~1 && git commit --amend`)
- Run `/git-cleanup` if ≥3 commits on branch
- Run `/pr create`

**Step 3 — PR exists, awaiting review:**
- Run `/pr status` to check CI + CodeRabbit
- If CI failing → diagnose, fix, amend, push
- If CodeRabbit has findings → proceed to Step 4

**Step 4 — CodeRabbit iteration:**
- Read all CodeRabbit findings
- **Challenge each finding first:** Is it a real issue or pedantic? Check if CodeRabbit is wrong.
- For valid findings: search for ALL occurrences of the same pattern across the codebase, fix everywhere
- For subjective/wrong findings: dismiss with a brief explanation
- Amend commit, push
- Wait and re-check: use `sleep 60` then re-check CI/CodeRabbit, or use the `/loop` skill (`/loop 1m /pr status`) to poll continuously
- Repeat until CodeRabbit is satisfied or only subjective items remain

**Step 5 — PR approved + CI green:**
- Ask user: "Ready to merge?"
- Run `/pr merge`

**Step 6 — Merged, release:**
- Discover release flow: check for GitHub Actions (`release.yml`, `deploy.yml`), `package.json` release scripts
- Ask user: "Trigger release?" (always ask unless `--auto` flag)
- If yes → trigger GitHub Action or run release script
- Monitor release status via `gh run watch`

## Human-in-the-Loop Triggers

Always ask the user when:
- Uncertain about a CodeRabbit finding (subjective vs real)
- About to trigger release
- Force push needed
- CI failure not clearly related to our changes
- `/review` found architectural concerns (not just style)

## Rules

- Never skip `/check` — it must pass before any commit
- Always amend for follow-up fixes (never create "fix lint" commits)
- When fixing a CodeRabbit finding, grep for the same pattern everywhere — don't leave other instances
- Keep the user informed of progress: "Step 3/6: PR exists, checking CI..."
- If any step fails and you can't resolve it, stop and explain — don't loop
