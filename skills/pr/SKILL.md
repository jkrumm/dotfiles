---
name: pr
description: GitHub PR workflow - create, status, merge with intelligent conflict handling
---

# PR Skill (GitHub)

Manage GitHub Pull Requests with intelligent branch management, conflict resolution, CodeRabbit integration, and full review iteration loop.

**Platform:** GitHub (SourceRoot projects)

## Arguments

- `action` - Action to perform: create (default), status, merge, update
- `ticket` - Optional ticket number (JK-XX). Auto-detected if not provided.
- `--draft` - Create as draft PR

## Actions

| Action | Description |
|-|-|
| `create` | Create new PR (default action) |
| `update` | Update existing PR description |
| `status` | Fetch PR status, CI, CodeRabbit findings, and offer to fix issues |
| `merge` | Merge PR via rebase (trunk-based) |

## PR Iteration Workflow

When iterating on an existing PR after review feedback:

1. Make changes based on feedback
2. `/commit --amend` (amends last commit + force push)
3. `/pr status` (re-check CI + CodeRabbit, offer to fix remaining issues)
4. `/pr update` if implementation approach changed substantively
5. Continue review cycle until clean

**When to update PR description:**
- Substantive changes to implementation approach
- Additional features added during review
- Scope changes based on feedback

**When NOT to update:**
- Minor formatting/linting fixes (CodeRabbit/SonarQube)
- Typo corrections
- Small refactorings within same scope

---

## Workflow: `/pr create`

### Phase 1: Branch Validation

```bash
default_branch=$(git remote show origin | grep "HEAD branch" | cut -d: -f2 | xargs)
current_branch=$(git branch --show-current)
```

**Check: On default branch or detached HEAD?**
- On default branch → **error out**: "You're on `$default_branch`. Create a feature branch first: `git checkout -b feat/description`"
- Detached HEAD → **error out**: "Not on a branch. Check out a branch first."

**Check: Branch name relevance**

Fetch branch context:
```bash
git log --oneline origin/$default_branch..HEAD
git diff origin/$default_branch..HEAD --stat
```

Analyze whether the branch name reflects the actual changes:
- Flag if branch name doesn't start with: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `test/`, `build/`, `ci/`, `perf/`
- Flag if branch name content is clearly unrelated to the commits (e.g., branch is `feat/user-settings` but all commits are about auth)

If mismatch detected:
```
Branch name 'feat/user-settings' may not match your changes.
Commits suggest this is auth-related work.

Suggested rename: feat/auth-login
Commands:
  git branch -m feat/user-settings feat/auth-login
  git push origin --delete feat/user-settings  (if already pushed)
  git push -u origin feat/auth-login

Rename now? [y/N]
```

If user confirms: execute the rename. Continue with the new branch name.

### Phase 2: Ensure All Changes Committed

```bash
# Check for uncommitted/unstaged changes
git status --short

# Count commits ahead of default
commit_count=$(git rev-list --count origin/$default_branch..HEAD 2>/dev/null || echo 0)
```

**If uncommitted changes exist:**
```
Uncommitted changes detected. Running /commit first...
```
Invoke `/commit` skill:
```
Skill({ skill: "commit" })
```
Wait for commit to complete, then continue.

**If `commit_count >= 3`:**
```
Branch is $commit_count commits ahead of $default_branch.
Consider '/git-cleanup' to group commits into logical units before creating the PR.

Run '/git-cleanup' now? [y/N/skip]
```
- `y` → `Skill({ skill: "git-cleanup" })`, wait for completion, then continue
- `N` or `skip` → continue without cleanup

### Phase 3: Pre-flight Validation

**ALWAYS run /check skill:**

```
Skill({ skill: "check" })
```

**CRITICAL: Abort if validation fails.** Show errors and suggest fixes. Do not proceed with PR creation on failing code.

### Phase 4: Ticket Detection

**Priority order:**
1. Explicit argument: `/pr create JK-123`
2. OpenSpec: Check `.openspec/changes/*/proposal.md` for ticket reference
3. Branch name: Extract from `feat/JK-123-*` pattern
4. Recent commits: Look for `Refs: JK-XX` in commit messages
5. None: Proceed without ticket (quick fix)

### Phase 5: Rebase onto Default Branch

1. Fetch latest: `git fetch origin`
2. Attempt rebase: `git rebase origin/$default_branch`
3. If conflicts:
   a. Categorize each conflicted file (safe vs complex)
   b. Auto-resolve safe conflicts (report what was resolved)
   c. For complex conflicts, present both versions and ask user
   d. After each resolution: `git add <file> && git rebase --continue`
4. Push updated branch: `git push` (or `git push -u origin $current_branch` if first push)

### Phase 6: Check for Existing PR

```bash
gh pr list --head $(git branch --show-current) --json number,url,title
```

- **PR exists** → update description with new commit summary (ask first if description has changed), then skip to Phase 8
- **No PR** → proceed to Phase 7

### Phase 7: Create PR

**CRITICAL: NO AI ATTRIBUTION**
- Do NOT add "Created by Claude Code" or similar footer
- Do NOT add "Generated with AI" disclaimers
- Keep PR description professional and focused on the changes

**PR Title:** Derived from the most significant commit message on the branch, or synthesized from the commit sequence. Follows conventional commits format. Max 70 chars.

**Generate PR body** by analyzing `git log origin/$default_branch..HEAD` + `git diff origin/$default_branch..HEAD`:

```bash
gh pr create \
  --title "<type>(<scope>): <subject>" \
  --body "$(cat <<'EOF'
## Summary
[1-2 sentences explaining WHY this is being done — the problem solved or value added.
Write for a teammate who hasn't followed this implementation.

NOT: "Updated auth module"
YES: "Token refresh was silently failing on long sessions — this implements automatic
rotation to prevent 401s in long-lived user flows."]

## What Changed
- [Impact-focused bullet: WHAT changed + WHY it matters — not file-focused]
- [Another change + its impact on users or the system]

## Technical Notes
[DELETE this section entirely if no meaningful architecture decisions, tradeoffs, or
reviewer attention points. Do not include if there's nothing genuinely useful to say.
Delete the section header too.]
- [Architecture choice + rationale]
- [Non-obvious implementation decision]
- [Breaking change implications]

## Testing
- [x] Code quality validation passed (format + lint + types)
- [ ] [Specific manual test scenario derived from what actually changed]
EOF
)"
[--draft]  # if --draft flag passed
```

**Generation rules:**
- **Summary**: explain the problem/need being addressed, not just what the code does. Synthesize from commit messages and diff. One or two sentences max.
- **What Changed**: translate file changes into impact-focused bullets. "Updated TokenService" → "Access tokens now auto-rotate on expiry, preventing silent session failures for long-lived users"
- **Technical Notes**: ONLY include if there is a real tradeoff, architecture decision, or thing a reviewer genuinely needs to know. If nothing meaningful, delete the section and its header entirely.
- **Testing**: derive the manual scenario from the actual changes — not a generic "test the feature"

### Phase 8: Report

Show:
- PR URL
- Draft status
- Next steps: "Run `/pr status` to check CI and reviews"

---

## CodeRabbit Comment Parsing

Whenever a PR exists, ALWAYS fetch and parse ALL CodeRabbit feedback. CodeRabbit posts as user `coderabbitai[bot]`.

**MANDATORY:** Run all three API calls below — every time, without exception. Never skip or abbreviate. Use `--paginate` to retrieve all pages.

### Fetch Commands

```bash
# Get repo info for API calls
owner=$(gh repo view --json owner -q .owner.login)
repo=$(gh repo view --json name -q .name)

# 1. Issue comments (CodeRabbit summary/overview posts) — ALL pages
gh api --paginate "repos/$owner/$repo/issues/$pr_number/comments" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]")]'

# 2. Inline review comments (line-by-line code feedback) — ALL pages
gh api --paginate "repos/$owner/$repo/pulls/$pr_number/comments" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]")]'

# 3. PR reviews (approval status and review body from CodeRabbit) — ALL pages
gh api --paginate "repos/$owner/$repo/pulls/$pr_number/reviews" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]") | {state, body, submitted_at}]'
```

### Parsing Rules

**From issue comments (summary post):**
- Show the FULL body of every CodeRabbit issue comment — do not truncate or summarize
- Include the actionable comments count, walkthrough table, and all change details
- Highlight any items marked with ⚠️, `[BLOCKER]`, or "must fix"

**From inline review comments:**
- Include EVERY inline comment — do not skip any, including those with `in_reply_to_id` set
- Group by file (`path`)
- For each comment show: file path, line number, the `diff_hunk` context (trimmed to 5 lines), and full comment `body`
- Classify severity:
  - **Blocking:** body contains "security", "bug", "crash", "incorrect", "breaks", "must", "wrong"
  - **Suggestion:** body contains "consider", "suggest", "could", "optional", "nit", "style"
  - **Info:** everything else

**From reviews:**
- If `state == "CHANGES_REQUESTED"` → flag as blocking merge
- If `state == "APPROVED"` → note approval
- Show the full review `body` if non-empty (not truncated)

### Output Format

```markdown
### CodeRabbit
**Review:** Approved | Changes Requested | Pending

**Summary:**
[Full text of the CodeRabbit summary issue comment, untruncated]

**Inline Comments (N total):**

#### `src/auth/token.ts`
- **Line 42** [Blocking] — Potential null dereference when `refreshToken` is undefined.
  > diff_hunk context (trimmed)
  Full comment body here.

- **Line 55** [Suggestion] — Variable name `t` is unclear, prefer `token`.
  > diff_hunk context (trimmed)
  Full comment body here.

#### `src/api/routes.ts`
- **Line 18** [Blocking] — Missing input validation on `userId` parameter.
  Full comment body here.
```

If no CodeRabbit comments found on any of the three endpoints: `**CodeRabbit:** No review yet`

---

## Workflow: `/pr status`

### Fetch All Data

```bash
# Get PR number and repo info
pr_number=$(gh pr view --json number -q .number)
owner=$(gh repo view --json owner -q .owner.login)
repo=$(gh repo view --json name -q .name)

# Check for local uncommitted changes or unpushed commits
git status --short
unpushed=$(git rev-list --count origin/$(git branch --show-current)..HEAD 2>/dev/null || echo 0)

# Get PR details
gh pr view $pr_number --json state,mergeable,mergeStateStatus,reviewDecision,body

# Get all CI checks
gh pr checks $pr_number

# MANDATORY: Load ALL CodeRabbit comments — run all three calls (see section above)

# Load ALL user (non-bot) PR comments — always, same as CodeRabbit
gh api --paginate "repos/$owner/$repo/issues/$pr_number/comments" \
  --jq '[.[] | select(.user.type != "Bot")] | map({user: .user.login, id, created_at, body})'

gh api --paginate "repos/$owner/$repo/pulls/$pr_number/comments" \
  --jq '[.[] | select(.user.type != "Bot")] | map({user: .user.login, id, path, line, diff_hunk, body})'

# Include top-level human PR reviews (state + review body)
gh api --paginate "repos/$owner/$repo/pulls/$pr_number/reviews" \
  --jq '[.[] | select(.user.type != "Bot")] | map({user: .user.login, id, state, submitted_at, body})'
```

### Pre-check: Local State

**If uncommitted changes exist:**
```
You have uncommitted changes.
Run `/check` + `/commit` before checking PR status? [y/N]
```

**If unpushed commits exist:**
```
You have $unpushed unpushed commit(s).
Run `/check` and push first? [y/N]
```

### Present Summary

**Format:**

```markdown
## PR #123: feat(auth): add token refresh

**Status:** Draft | Ready for Review | Approved | Changes Requested
**Mergeable:** Yes | No (reason)

### CI Checks (X/Y passed)
- [pass/fail] Check name
  - If failed: Error details

### CodeRabbit
[Parsed output per "CodeRabbit Comment Parsing" section]

### PR Discussion Comments (by user)
[Top-level issue comments (no file path). Include: user, created_at, body. Present every comment.]

### Inline File Comments (by user)
[All non-bot inline comments grouped by `path`. Include: user, file path, line, body. Present every comment — do not skip.]

### Actions Available
- Fix blocking issues (see below)
- Mark ready: `/pr update --ready` (if draft)
- Merge: `/pr merge` (if all checks pass)
```

### CodeRabbit Feedback Loop

After presenting the full status, process CodeRabbit feedback interactively:

**If CHANGES_REQUESTED review state:**
```
⚠️  CodeRabbit requested changes — address all blocking issues before merging.
```

**Blocking items** — ask for each one in sequence:
```
CodeRabbit found 2 blocking issues:

1. [Blocking] src/auth/token.ts:42 — Potential null dereference when refreshToken is undefined
2. [Blocking] src/api/routes.ts:18 — Missing input validation on userId parameter

Implement fix for item 1? [y/N]
```
- User says `y` → implement the fix in the main thread, run `/check`, fold into last commit with `/commit --amend`, then ask for next blocking item
- User says `N` → skip that item, ask for next
- After all blocking items addressed: "All blocking issues resolved. Run `/pr merge` once CI passes."

**Suggestions (non-blocking)** — show as numbered list, ask once:
```
CodeRabbit has 3 suggestions (non-blocking):

1. [Suggestion] src/auth/token.ts:55 — Variable name 't' is unclear, prefer 'token'
2. [Suggestion] src/api/auth.ts:23 — Consider extracting validation to a helper function
3. [Suggestion] src/api/routes.ts:44 — Add JSDoc comment for this public method

Implement any of these? (enter numbers like "1 3", or "none")
```
- User enters numbers → implement selected suggestions, run `/check`, `/commit --amend`
- User enters `none` → proceed

### Auto-update PR Description

Check if new commits have been added to the branch since PR creation (compare PR body creation date vs latest commit):

```bash
gh pr view --json commits,body
```

If new commits pushed since last description update:
```
New commits detected since PR description was last written.
Update PR description to reflect current state? [y/N]
```
- `y` → regenerate description using the improved template (WHY-focused summary, impact bullets), show diff, ask to confirm before applying

---

## Workflow: `/pr update`

Update PR title, description, or status.

**ALWAYS run /check first:**

```
Skill({ skill: "check" })
```

If /check fails → abort, show errors. Do not update PR on failing code.

If passes → regenerate PR description using the improved template, show diff of old vs new, ask for confirmation before applying:

```bash
# Update description
gh pr edit --body "updated description"

# Mark as ready (remove draft)
gh pr ready

# Add comment
gh pr comment --body "Additional context..."
```

---

## Workflow: `/pr merge`

### Pre-merge: Worktree Detection & Switch

**CRITICAL: Must run merge from main worktree, not feature worktree.**

```bash
main_wt=$(git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2)
current_dir=$(pwd)

if [[ "$current_dir" != "$main_wt" ]]; then
  feature_branch=$(git branch --show-current)
  echo "Detected feature worktree. Switching to main worktree..."
  cd "$main_wt"
fi
```

### Pre-merge Checks

1. Verify all CI checks passed
2. Verify no merge conflicts
3. Run ALL three CodeRabbit API calls (see "CodeRabbit Comment Parsing" section) — mandatory
   - If blocking items found: list all of them and ask "Merge anyway or fix first?"
   - If only suggestions: show them all, then proceed with merge
4. (No approval needed — solo dev workflow)

### Execute Merge

**No confirmation needed** — solo dev workflow with admin privileges.

```bash
gh pr merge --rebase --delete-branch --admin
```

**Why `--admin`?** Branch protection requires approvals, but as a solo dev with all checks passing, we bypass this to streamline the workflow.

### Post-merge: Worktree Cleanup

```bash
if [[ -n "$feature_branch" ]]; then
  echo "Removing feature worktree and branch..."
  wtp remove "$feature_branch" --with-branch || {
    git worktree remove "$feature_branch" --force
    git branch -D "$feature_branch"
  }
fi

# Update main worktree ONLY if clean
if git diff-index --quiet HEAD --; then
  git pull --rebase
else
  echo "Main worktree has uncommitted changes — skipping pull."
  echo "Run 'git pull --rebase' manually when ready."
fi
```

### Post-merge: Release Check

```
# If basalt-ui package was changed
"basalt-ui package was updated. Run `/release` to publish?"

# If significant feature merged
"Feature merged. Consider `/release` if ready for users."
```

---

## Conflict Resolution

### Safe to Auto-resolve (notify user):

| Conflict Type | Resolution Strategy |
|-|-|
| Whitespace/formatting only | Take the formatted version |
| Import additions (non-overlapping) | Keep both imports |
| Package.json version field | Take newer version |
| Lock files | Regenerate after rebase |
| Additive changes in different sections | Keep both additions |

### Require User Decision:

| Conflict Type | How to Present |
|-|-|
| Logic in same function | Show both versions with surrounding context |
| Database migrations | NEVER auto-resolve, show both with timestamps |
| API contracts/schemas | Highlight breaking change implications |
| Security-related code | Emphasize security implications |
| Test assertions changed | Show expected vs actual changes |

---

## Human-in-the-Loop Summary

| Action | Auto | Ask |
|-|-|-|
| Branch validation (on default branch) | | Error out |
| Branch name mismatch detection | | Ask to rename |
| Run /commit for uncommitted changes | | Invoke, wait |
| git-cleanup suggestion (≥3 commits) | | Ask y/N/skip |
| Run /check validation | Auto (abort on fail) | |
| Rebase (no conflicts) | Auto | |
| Auto-resolve safe conflicts | Auto (report) | |
| Complex conflict resolution | | Ask |
| Create branch (ticket found) | Auto | |
| Create branch (no ticket) | | Ask |
| Create PR | | Preview first |
| Update PR description (new commits) | | Ask |
| Mark PR ready | Auto | |
| Implement CodeRabbit blocking fix | | Ask per item |
| Implement CodeRabbit suggestions | | Ask (numbered list) |
| Merge PR (checks pass) | Auto (--admin) | |
| Merge PR (checks fail) | | Report & ask |

---

## Error Handling

| Error | Action |
|-|-|
| On default branch | Abort: "Create a feature branch first" |
| Detached HEAD | Abort: "Not on a branch. Check out a branch first." |
| /check fails | Abort, show errors, suggest fixes |
| Not on git repo | Error: "Not in a git repository" |
| No GitHub remote | Error: "No GitHub remote found" |
| gh not authenticated | Prompt: "Run `gh auth login`" |
| Rebase conflicts (complex) | Present both versions, ask user |
| PR creation fails | Check branch pushed, show error |
| Merge blocked | Show blocking reason, suggest action |

---

## Examples

```bash
# Create PR for current branch
/pr create

# Create PR with explicit ticket
/pr create JK-123

# Create draft PR
/pr create --draft

# Check PR status with all feedback + CodeRabbit loop
/pr status

# Merge approved PR
/pr merge
```

---

## Integration Notes

- Works with OpenSpec: Checks `.openspec/changes/*/proposal.md` for context (if directory exists)
- Uses `/commit` skill: Invoked automatically if uncommitted changes found on create
- Uses `/git-cleanup` skill: Offered when branch has ≥3 commits on create
- Uses `/check` skill: Validates before PR create and update
- Trunk-based workflow: Rebase strategy, no merge commits
- Solo dev workflow: No approval required, uses `--admin` bypass
