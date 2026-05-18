---
name: commit
description: Smart git commit with conventional commits, OpenSpec awareness, and intelligent splitting for GitHub
---

# Smart Commit Skill (GitHub)

Generate conventional commit messages with intelligent analysis of changes, OpenSpec awareness, and automatic splitting when appropriate.

**Platform:** GitHub (SourceRoot projects)

## Arguments

- `--amend` - Amend last commit + force push (for follow-up fixes)
- `--split` - Force splitting analysis for multiple commits
- `--no-split` - Force single commit
- `--dry-run` - Preview only, no execution

## Context Detection

**SourceRoot personal projects do not use ticket numbers.** All scopes are module/component names (e.g. `auth`, `booking`, `basalt-ui`) — never ticket IDs.

If a SourceRoot scope ever needs a ticket reference (e.g. cross-linking an upstream issue), put it in the body as plain text — not in the scope, not as `Refs:` footer. The `Refs:` convention is for ticketed IuRoot work only.

**OpenSpec context** (if `.openspec/changes/` directory exists):
- Match changed files to any spec that might be relevant
- Extract the change purpose if found
- Do NOT extract a ticket reference for SourceRoot — even if a proposal contains one

**Special Handling:**
- `basalt-ui` package changes → ALWAYS separate commit(s) (NPM published)
- Full-stack feature changes → Keep together (don't split by frontend/backend)
- Mono-repo apps → Feature-based splitting, not app-based
- Direct main/master commits → Valid for small fixes (no branch needed)

## Workflow

### Phase 1: Analysis

Analyze git changes for commit preparation:

1. Run `git status` to see overall state
2. Run `git diff --cached --stat` for staged files overview
3. Run `git diff --cached` for full staged diff content
4. If unstaged changes exist, run `git diff` to understand full context

5. Check for OpenSpec context (if `.openspec/changes/` directory exists):
   - Look in `.openspec/changes/` for active specifications
   - Match changed files to any spec that might be relevant
   - Extract the change purpose (not a ticket — SourceRoot has none)

6. Analyze the changes:
   - Identify the primary purpose (feat/fix/refactor/docs/test/chore/build/ci/perf/style)
   - Determine appropriate scope (module/component name only — never a ticket ID)
   - Check if changes span multiple logical concerns
   - Identify if basalt-ui package is involved (check file paths)

7. Evaluate splitting need:
   - Multiple unrelated features/fixes?
   - basalt-ui changes mixed with app code?
   - Refactoring mixed with new features?
   - Test additions separate from implementation?

### Phase 2: Commit Strategy Decision

Based on analysis and options, decide:

**Amend Commit** (when `--amend` passed):
- ONLY on feature branches (never on main/master)
- For small follow-up fixes (CodeRabbit, SonarQube, linting, formatting)
- Amends the previous commit instead of creating a new one
- Force pushes to update the PR

**Single Commit** (default when):
- All changes serve one logical purpose
- No basalt-ui mixed with app code
- User passed `--no-split`

**Multiple Commits** (when):
- basalt-ui changes present alongside other changes (ALWAYS split)
- Multiple distinct features/fixes detected
- Refactoring mixed with feature work
- User passed `--split`

### Amend Workflow (`--amend`)

**Use case:** Small fixes after CodeRabbit/SonarQube feedback on an open PR.

**Requirements:**
- MUST be on a feature branch (not main/master)
- Previous commit should be yours (not merged from others)
- Changes should be related to the previous commit

**Execution:**
```bash
# Stage changes
git add <files>

# Amend the previous commit (keep message)
git commit --amend --no-edit

# Force push to update PR
git push --force-with-lease
```

**When NOT to use amend:**
- On main/master branch → Error: "Cannot amend on default branch"
- Substantial new functionality → Create new commit instead
- Unrelated changes → Create new commit instead
- If unsure → Ask: "These changes seem substantial. Amend or new commit?"

### Phase 3: Message Generation

**Format (Conventional Commits):**
```
<type>(<scope>): <subject>

<body>

<footer>
```

**Rules:**
- **Subject**: Max 50 chars, imperative mood, no period, lowercase after colon
- **Type**: feat|fix|docs|style|refactor|perf|test|build|ci|chore
- **Scope**: Module/component name, lowercase, hyphenated if multi-word. Omit entirely if the change spans the whole repo or there's no natural scope. SourceRoot personal projects do not use ticket IDs as scope
- **Body**: Explain WHY (diff shows what), wrap at 72 chars, bullet points for multiple points
- **Footer**: `BREAKING CHANGE:` if applicable. No `Refs:` footer — SourceRoot has no ticket tracker

**CRITICAL: NO AI ATTRIBUTION**
- Do NOT add `Co-Authored-By: Claude...` or similar
- Do NOT add `Generated with Claude Code` footer
- Keep commits clean and professional

### Phase 4: Execution

**For single commit:**
1. Show commit message preview
2. Ask for confirmation or edits
3. Execute using heredoc:
   ```bash
   git commit -m "$(cat <<'EOF'
   <message>
   EOF
   )"
   ```
4. Show `git log -1` result

**For multiple commits:**
1. Show commit sequence with file groupings
2. For each commit (in dependency order):
   a. Show which files will be included
   b. Unstage all: `git reset HEAD`
   c. Stage specific files: `git add <files>`
   d. Show commit message preview
   e. Execute commit on confirmation
   f. Move to next commit
3. Show final `git log --oneline -n <count>` result

### Phase 5: Validation

After committing:
- Run `git status` to confirm clean state (or show remaining changes)
- If any validation scripts exist (pre-commit hooks), confirm they passed

### Phase 6: Branch State & PR Suggestion

After successful commit, check branch state:

```bash
# Get current branch
current_branch=$(git branch --show-current)

# Get default branch
default_branch=$(git remote show origin | grep "HEAD branch" | cut -d: -f2 | xargs)

# Detect if in worktree
in_worktree=false
if [ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]; then
  in_worktree=true
fi

# Check if on feature branch and ahead of default
if [[ "$current_branch" != "$default_branch" ]]; then
  commits_ahead=$(git rev-list --count origin/$default_branch..$current_branch 2>/dev/null || echo 0)
fi
```

**PR Suggestion Logic:**
- On feature branch with commits ahead → check count:
  - `commits_ahead >= 3` → Suggest:
    ```
    Branch '$current_branch' is $commits_ahead commits ahead of $default_branch.
    Consider '/git-cleanup' to group commits before creating a PR.
    Run '/git-cleanup' or '/pr create'?
    ```
  - `commits_ahead == 1 or 2` → Suggest:
    ```
    Branch '$current_branch' is $commits_ahead commit(s) ahead of $default_branch.
    Run '/pr create' to open a PR?
    ```
- On main/master with small fix → No suggestion (direct commit workflow)
- If in worktree → Note: "Working in worktree - /pr merge will suggest cleanup"

**Example output:**
```
Commit created successfully.

Branch 'feat/user-auth' is 3 commits ahead of main.
📂 Working in worktree (created via wtp)

Run `/pr create` to create a PR?
```

## basalt-ui Splitting Rules

When `basalt-ui` package files are detected:

1. **Identify basalt-ui files**: Any path containing `packages/basalt-ui/` or `@basalt-ui`
2. **ALWAYS separate** into dedicated commit(s)
3. **Commit basalt-ui first** (dependency order)
4. **Message format**: `feat(basalt-ui): ...` or appropriate type
5. **Reasoning**: NPM published package needs clean changelog, separate versioning

## Commit Message Examples

**Feature with module scope:**
```
feat(auth): add refresh token rotation

Implement automatic token refresh when access token expires.
Tokens are rotated on each refresh to prevent replay attacks.

- Add TokenRotationService with configurable intervals
- Update AuthMiddleware to handle expired tokens gracefully
- Store refresh token family for revocation tracking
```

**Bug fix:**
```
fix(api): handle null response from external service

External payment API occasionally returns null on timeout.
Previously caused unhandled exception in OrderService.
```

**basalt-ui component (breaking change):**
```
feat(basalt-ui): add DateRangePicker component

New compound component for date range selection.
Supports presets, custom ranges, and timezone awareness.

BREAKING CHANGE: DatePicker prop `range` removed, use DateRangePicker instead
```

**Refactoring:**
```
refactor(booking): extract validation logic to dedicated service

Reduces BookingService complexity from 450 to 180 lines.
Validation rules now testable in isolation.
```

**Repo-wide change (no scope):**
```
chore: bump dependency lockfile

Routine `npm update` to pick up patch versions.
No code changes; nothing semver-major.
```

## Dry Run Mode

When `--dry-run` is passed:
- Perform full analysis
- Generate commit message(s)
- Show what would be committed
- Do NOT execute any git commands
- Useful for reviewing before actual commit

## Error Handling

- **No staged changes**: Inform user, suggest `git add` or show unstaged changes
- **Merge conflict markers**: Warn and abort, conflicts must be resolved first
- **Pre-commit hook failure**: Show error, do NOT auto-fix, let user decide
- **Empty commit**: Warn if commit would be empty after staging
- **Amend on default branch**: Error: "Cannot amend on default branch (main/master)"

## Conflict Resolution (from git operations)

### Safe to Auto-resolve:
- Whitespace/formatting only
- Import additions (non-overlapping)
- Package.json version field
- Lock files (regenerate after)
- Additive changes in different sections

### Require User Decision:
- Logic in same function
- API contracts/schemas
- Security-related code
- Both sides have semantic changes
- Test assertions changed

## Integration Notes

- Works with OpenSpec: Reads `.openspec/changes/*/proposal.md` for context (if directory exists)
- Works with /check: Does NOT auto-run validation (user's preference)
- Respects git hooks: Never uses `--no-verify`
- Works with `/pr`: Suggests PR creation after commit
