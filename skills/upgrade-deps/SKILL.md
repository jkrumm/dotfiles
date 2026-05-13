---
name: upgrade-deps
description: Dependency upgrade assistant with research and validation phases
---

# Upgrade Dependencies Skill

Analyze, validate, upgrade npm/bun dependencies, run validation, and commit changes.

## Skill Architecture (Token Efficiency)

**Principle:** Keep main thread focused on coordination. Delegate heavy operations to MCP-routed skills.

### Available Skills

| Skill | Use For | Mode |
|-------|---------|------|
| **`/research`** | Major version research, breaking changes, migration guides | MCP (sideclaw) |
| **`/check`** | Post-upgrade validation (format, lint, tsc, build) | MCP (sideclaw) |

### Delegation Rules

**ALWAYS delegate:**
- Major version research → `/research` skill
- OpenSpec migration research (major/minor changes) → `/research` skill
- Post-upgrade validation → `/check` skill

**Keep in main thread:**
- Git operations (status, add, commit)
- npm-check-updates commands
- Package manager install commands
- OpenSpec CLI commands (update, version checks)
- User communication and approval flows

### Token Savings

Both `/research` and `/check` route through sideclaw — verbose output stays in the worker subprocess, only structured JSON returns to the main thread. Quota-aware (Max → IU at ≥70% utilization).

---

## Pre-flight Checks (MANDATORY)

**1. Check git state:**
```bash
git status --porcelain
```
If ANY output: **STOP immediately** and tell user:
```
⚠️  Uncommitted changes detected. Please commit or stash before upgrading dependencies.
```

**2. Identify base branch:**
```bash
git remote show origin 2>/dev/null | grep 'HEAD branch' | cut -d: -f2 | tr -d ' '
```

**3. Stay in project root - NEVER cd to subfolders**

---

## Phase 1: Project Detection

Detect package manager by checking lockfiles in project root:
- `bun.lock` or `bun.lockb` → **bun**
- `package-lock.json` → **npm**
- `yarn.lock` → **yarn**
- `pnpm-lock.yaml` → **pnpm**

Check for workspace setup:
```bash
grep -q '"workspaces"' package.json && echo "WORKSPACE"
```

**Project Types:**
1. **Single npm project**: No workspaces, has package-lock.json
2. **Single bun project**: No workspaces, has bun.lock
3. **Bun workspace**: Has workspaces + bun.lock → use `--deep`
4. **npm workspace**: Has workspaces + package-lock.json → use `--deep`

---

## Phase 1.5: OpenSpec Update (If Installed)

Check if OpenSpec is installed and update instruction files.

**1. Detection:**
```bash
# Check if OpenSpec CLI is available
command -v openspec >/dev/null 2>&1 && echo "OPENSPEC_INSTALLED"

# Check current version
openspec --version 2>/dev/null
```

**2. Check for updates:**
```bash
# Get current installed version
CURRENT=$(openspec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

# Get latest version from npm
LATEST=$(npm view openspec version 2>/dev/null)

echo "Current: $CURRENT"
echo "Latest: $LATEST"
```

**3. If update available:**
```bash
# Update OpenSpec globally
npm update -g openspec
```

**4. Update instruction files:**
```bash
# Update OpenSpec templates and instruction files in project
openspec update
```

**5. Version change analysis:**

If there's a **major or minor version change**, delegate research:

```
/research OpenSpec CLI migration [old-version] to [new-version] Claude Code setup changes
```

Research should cover:
- Breaking changes in CLI commands
- Changes to instruction file formats
- Updates to Claude Code integration patterns
- New features relevant for spec-driven development

**Present results:**

```markdown
## 🔧 OpenSpec Update

| Item | Value |
|------|-------|
| Previous version | X.Y.Z |
| New version | A.B.C |
| Instruction files | Updated ✅ |

### Version Changes (if major/minor)
**Breaking changes:** [via /research skill]
- [Change 1]
- [Change 2]

**New features for Claude Code:**
- [Feature 1]
- [Feature 2]

**⏸️ Continue with npm/bun dependency upgrades?**
```

**Skip OpenSpec phase if:**
- `openspec` command not found
- No `.openspec/` directory in project
- User explicitly skips with `--skip-openspec`

---

## Phase 2: Check Outdated Dependencies

Use npm-check-updates (ncu) to check versions. Run from project root.

**For single project (npm):**
```bash
npx npm-check-updates
```

**For single project (bun):**
```bash
npx npm-check-updates --packageManager bun
```

**For workspace (npm/bun):**
```bash
npx npm-check-updates --deep [--packageManager bun]
```

**Present results:**

```markdown
## 📊 Outdated Dependencies

| Category | Count | Action |
|----------|-------|--------|
| 🟢 Patch | X | Safe to upgrade |
| 🔵 Minor | Y | Generally safe |
| 🔴 Major | Z | Research required |

### Major Upgrades Requiring Research:
- `package-a`: 2.x → 3.x
- `package-b`: 4.x → 5.x

**⏸️ Shall I research breaking changes for the major upgrades?**
```

---

## Phase 3: Research Major Updates → `/research` Skill

**⚠️ ALWAYS use /research skill for major version research.**

```
/research docs:[package-name] migration [old-version] to [new-version]
```

Research for each major upgrade:
1. Breaking changes list
2. Required code modifications
3. Peer dependency changes
4. Migration guide (if exists)
5. Risk assessment: low/medium/high

**After research returns:**

```markdown
## 🔴 Major Upgrades Analysis

### [package-a] 2.x → 3.x
**Risk:** [low/medium/high]
**Breaking changes:**
- [Change 1]
- [Change 2]
**Code changes needed:**
- [File/area affected]
**Peer deps:** [Updates required]

---

**⏸️ Proceed with upgrades?**
- [ ] Safe upgrades only (patch + minor)
- [ ] Safe + low-risk majors
- [ ] All upgrades (with code changes)
```

---

## Phase 4: Execute Upgrades

**IMPORTANT:** All commands run from project root. Never cd.

### Safe upgrades (patch + minor only):

```bash
# npm
npx npm-check-updates --target minor -u && npm install

# bun
npx npm-check-updates --target minor -u --packageManager bun && bun install

# With --deep for workspaces
npx npm-check-updates --target minor -u --deep [--packageManager bun] && [npm|bun] install
```

### Major upgrades (after research confirms safe):
```bash
npx npm-check-updates -u <package1> <package2> [--packageManager bun] && [npm|bun] install
```

---

## Phase 5: Validation → `/check` Skill

**⚠️ ALWAYS use /check skill for validation.**

```
/check
```

The skill will:
1. Detect runtime and package manager
2. Run format, lint, typecheck, build
3. Report any failures with specific errors

**After validation:**

```markdown
## ✅ Validation Results

| Check | Status | Details |
|-------|--------|---------|
| Format | ✅/❌ | [Details] |
| Lint | ✅/❌ | [Details] |
| Types | ✅/❌ | [Details] |
| Build | ✅/❌ | [Details] |

**⏸️ Ready to commit?** / **⏸️ Fix issues first?**
```

**NEVER run:** `dev`, `start`, `serve`, or any server-starting commands.

If validation fails: Report which step failed, suggest fixes, do NOT commit.

---

## Phase 6: Commit

If all validations pass:

```bash
git add package.json package-lock.json bun.lock 2>/dev/null
git add "**/package.json" 2>/dev/null  # For workspaces
```

Commit message format:
```bash
# For patch/minor only:
git commit -m "chore: upgrade dependencies"

# For specific packages:
git commit -m "chore: upgrade <package1>, <package2>"

# For major version:
git commit -m "chore: upgrade <package> to v<version>"
```

---

## Output Format

```markdown
📦 Dependency Upgrade Report
============================

🔍 Pre-flight
-------------
Git status: ✅ Clean
Base branch: main
Package manager: bun
Project type: workspace

🔧 OpenSpec Update
------------------
Status: ✅ Updated (1.2.0 → 1.3.0)
Instruction files: ✅ Refreshed
Migration research: ✅ (via /research skill - new Claude Code patterns)

📊 Outdated Dependencies
------------------------
🟢 Patch: 3 packages
🔵 Minor: 5 packages
🔴 Major: 2 packages

🔴 Major Upgrades Analysis (via /research skill)
------------------------------------------------
## react 18.x → 19.x
Risk: medium
Breaking changes:
- Concurrent features now default
- useEffect cleanup timing changed
Peer deps: react-dom must also upgrade

⚡ Upgrade Commands
-------------------
# Safe (patch+minor):
npx npm-check-updates --target minor -u --deep --packageManager bun && bun install

✅ Validation Results (via /check skill)
-----------------------------------------------
format:check: ✅
lint: ✅
type-check: ✅
build: ✅

📝 Ready to Commit
------------------
git commit -m "chore: upgrade dependencies"
```

---

## Quick Reference: Skill Delegation

| Phase | Operation | Skill |
|-------|-----------|-------|
| Pre-flight | Git checks | Main thread |
| Phase 1 | Project detection | Main thread |
| Phase 1.5 | OpenSpec update | Main thread |
| Phase 1.5 | OpenSpec migration research | `/research` (if major/minor) |
| Phase 2 | Check outdated | Main thread |
| Phase 3 | Research majors | `/research` |
| Phase 4 | Execute upgrades | Main thread |
| Phase 5 | Validation | `/check` |
| Phase 6 | Commit | Main thread |
