---
name: git-cleanup
description: Semantically group and squash branch commits before PR — eliminates noise commits, proposes logical groupings, executes via pure git soft reset. Use before /pr create when branch has multiple commits or noisy history.
---

# Git Cleanup Skill

Analyze all commits on the current branch ahead of the default branch. Detect noise commits ("fix TypeScript", "fix lint", "WIP", etc.), propose semantic groupings, show the plan before executing, then squash via `git reset --soft` + re-staged commits.

**Platform:** GitHub (SourceRoot projects)

## Arguments

- (none) — analyze and propose groupings for current branch
- `--dry-run` — show analysis and proposal only, do not execute any git commands

## Phase 1: Pre-flight Checks

```bash
# Detect default branch
default_branch=$(git remote show origin | grep "HEAD branch" | cut -d: -f2 | xargs)

# Get current branch
current_branch=$(git branch --show-current)

# Detect base commit where branch diverged
base_commit=$(git merge-base HEAD origin/$default_branch)

# Count commits on branch
commit_count=$(git rev-list --count $base_commit..HEAD)
```

**Abort conditions (stop immediately with clear message):**

| Condition | Message |
|-|-|
| On default branch (`$current_branch == $default_branch`) | "On default branch. Nothing to clean up." |
| Detached HEAD (no branch) | "Not on a branch. Check out a branch first." |
| 0 commits | "No commits on this branch ahead of $default_branch." |
| 1 commit | "Only 1 commit on this branch. Nothing to clean up." |
| Uncommitted changes | "Uncommitted changes detected. Run `/commit` first." |

**Warnings (continue but flag prominently):**

```bash
# Check if branch is already on remote
remote_exists=$(git ls-remote --heads origin $current_branch 2>/dev/null | wc -l)
if [[ $remote_exists -gt 0 ]]; then
  # WARN: cleanup will require force push
fi

# Check for merge commits
merge_commits=$(git log --merges $base_commit..HEAD --oneline | wc -l)
if [[ $merge_commits -gt 0 ]]; then
  # WARN: merge commits complicate soft reset — ask to abort
fi
```

If merge commits found:
```
⚠️  Merge commit detected in history. Soft reset doesn't handle merge commits cleanly.
Abort cleanup? [y/N]
```
Default: abort (y). Only continue if user explicitly says N.

## Phase 2: Full Analysis

Gather all data needed before proposing anything:

```bash
# Full commit list with file details
git log --name-only --format="%H %s" $base_commit..HEAD

# High-level change surface
git diff $base_commit HEAD --stat

# Full diff for understanding semantic groups
git diff $base_commit HEAD
```

### Noise Commit Detection

Classify a commit as **noise** if its subject (case-insensitive) contains any of:
- `fix typescript`, `fix type`, `fix types`, `fix ts`
- `fix lint`, `fix linting`, `eslint fix`, `lint fix`
- `formatting`, `format fix`, `fix formatting`, `prettier`
- `address coderabbit`, `coderabbit`, `sonarqube`
- `add missing`, `missing export`, `missing import`, `missing type`
- `wip`, `work in progress`
- Subject is ≤ 4 words AND starts with `fix` AND has no scope (no parentheses)

### Grouping Logic

1. Group commits by **logical feature or concern** — NOT by file type, layer (frontend/backend), or app
2. Noise commits are **absorbed** into the logical commit they were fixing (group them with the nearest non-noise commit that touched the same files)
3. A file touched by multiple commits belongs to the **last logical group** that introduced that concern (not the noise fix commit)
4. `packages/basalt-ui/` files → **always their own group**, always committed first
5. If only noise commits exist with no clear parent: merge them all into one clean commit

## Phase 3: Propose Groupings

**ALWAYS show the full proposal before executing anything.** Format:

```
Branch: feat/auth (7 commits → 2 clean commits)

CURRENT STATE:
  abc1234 feat(auth): add login page
  def5678 fix TypeScript errors in login
  ghi9012 fix lint
  jkl3456 feat(api): add auth endpoints
  mno7890 fix type errors in auth service
  pqr1234 add missing export
  stu5678 refactor(api): clean up endpoint handlers

PROPOSED GROUPINGS:

Group 1: feat(auth): add login page with auth endpoints
  Absorbs commits: abc1234, def5678, ghi9012, jkl3456, mno7890, pqr1234
  Files: src/auth/login.tsx, src/auth/LoginForm.tsx, src/api/auth.ts,
         src/api/auth.service.ts

Group 2: refactor(api): clean up auth endpoint handlers
  Absorbs commits: stu5678
  Files: src/api/routes.ts

⚠️  Branch is pushed to remote — cleanup will require:
    git push --force-with-lease

Confirm this plan? [y/N/edit]
```

**Special case — history already looks clean:**
```
Branch 'feat/auth' has 2 commits with clean conventional commit messages.
History looks well-organized already.

Current commits:
  abc1234 feat(auth): add login page
  def5678 feat(api): add auth endpoints

Reorganize anyway? [y/N]
```

**User responses:**
- `y` → proceed to Phase 4
- `N` → abort: "Cleanup cancelled. History unchanged."
- `edit` → ask user to describe changes (e.g., "rename group 1 to feat(auth): add user authentication"), then re-display updated proposal
- `--dry-run` flag → stop here, do not execute

## Phase 4: Execute

After user confirmation:

```bash
# 1. Soft reset all branch commits
#    All changes land as staged (index) from the latest state of each file
git reset --soft $base_commit
```

Then for each group **in order** (basalt-ui group always first if present):

```bash
# Stage exactly the files in this group
git add <file1> <file2> ...

# Commit with the confirmed message
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject>

<body if meaningful — explain why, not what>
EOF
)"
```

**Last group:** use `git add -A` to catch any remaining unstaged files (handles cross-group file accumulation from soft reset).

**Critical rules:**
- NO AI attribution in commit messages
- Conventional commits format: `type(scope): subject`
- Subject: imperative mood, max 50 chars, no period
- Body: explain WHY (only if adds meaning beyond the subject)
- Never `--no-verify`

## Phase 5: Result

```bash
# Show clean final state
git log --oneline origin/$default_branch..HEAD
git status
```

**Output format:**
```
Done. Branch cleaned: 7 commits → 2 commits.

  abc1234 feat(auth): add login page with auth endpoints
  def5678 refactor(api): clean up auth endpoint handlers
```

**If force push is needed:**
```
Branch was previously pushed to remote.

Next steps:
  git push --force-with-lease
  /pr create
```

**If dry run:**
```
Dry run complete. No git commands were executed.
Run '/git-cleanup' (without --dry-run) to apply.
```

## Error Handling

| Situation | Action |
|-|-|
| On default branch | Error out immediately |
| 0 or 1 commits | Skip with message, suggest next step |
| Uncommitted changes | Error: "Run `/commit` first" |
| Merge commit in history | Warn, ask to abort (default: abort) |
| `git reset --soft` fails | Show error verbatim — state is unchanged (no commits yet) |
| Commit fails mid-way | Stop immediately, show which group failed, instruct to resolve manually |
| Force push refused | Show error, remind `--force-with-lease` is safer than `--force` |

## Integration Notes

- Called from `/pr create` Phase 2 when branch has ≥3 commits (user offered y/N/skip)
- Suggested by `/commit` Phase 6 when branch is ≥3 commits ahead of default
- Pure git only — no jj, no interactive rebase, no external tools
- Never uses `--no-verify`
- After cleanup: remind user to force push if branch was previously on remote
