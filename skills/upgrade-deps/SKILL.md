---
name: upgrade-deps
description: Dependency upgrade assistant with research and validation phases — npm/bun projects, plus machine mode for Homebrew casks and third-party taps on the MacBook and mini
---

# Upgrade Dependencies Skill

Analyze, validate, upgrade npm/bun dependencies, run validation, and commit changes. Machine upgrades (Homebrew casks, taps): see *Machine mode* below.

## Skill Architecture (Token Efficiency)

**Principle:** Keep main thread focused on coordination. Delegate heavy operations to `agw`-routed skills.

### Available Skills

| Skill | Use For | Mode |
|-------|---------|------|
| **`/research`** | Major version research, breaking changes, migration guides | `agw research` |
| **`/check`** | Post-upgrade validation (format, lint, tsc, build) | `agw check` |

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

`/research` and `/check` route through `agw` (agent-workflows, synchronous with the exit-10 resume). Verbose work stays off the main thread; only the structured result returns.

---

## Machine mode — Homebrew casks and third-party taps

`make brew-upgrade` upgrades homebrew/core formulae only and routes the rest
here ("use /upgrade-deps"). When the ask is a machine upgrade rather than a
project, skip Phases 1–6 and run this instead, on **both** Macs (the mini over
`ssh mini '… </dev/null'` — a cask upgrade that reads stdin hangs headless).

1. **Formulae first:** `make brew-upgrade-dry`, then `make brew-upgrade`. A
   `brew link` failure aborts the assertions: `brew link --overwrite --dry-run X`
   names the conflict — a stray non-brew file (vendor installer binary, pip
   leftovers in `site-packages`); move it aside, `brew link --overwrite X`,
   re-run `make brew-upgrade` until it prints its assertions.
2. **Cooldown, per cask:** `brew outdated --cask --greedy --json=v2`. Big
   vendors (1Password, OpenAI, Spotify, Zed, …) go now. A third-party tap or
   single-maintainer cask waits until its release is older than
   `minimumReleaseAge` in `~/.bunfig.toml` (3 days) —
   `gh api repos/<owner>/<repo>/releases/tags/<tag> --jq .published_at`. The
   same rule holds for the `oven-sh/bun` tap formula. Name the casks explicitly:
   `brew upgrade --cask --greedy <list>`; never a bare `brew upgrade --cask`.
3. **Fixups after casks:**
   - `1password-cli` → re-add `/opt/homebrew/Caskroom/1password-cli/<ver>/op`
     to Full Disk Access **by hand** on the MacBook (`docs/homebrew.md`).
   - Obsidian on the mini → `pgrep -x Obsidian || open -a Obsidian`; it is an
     agent door.
   - Checksum mismatch → never `--no-quarantine`/skip the check; retry later.
   - A cask whose app is gone and that the Brewfile does not declare →
     `brew uninstall --cask --force X`. That also autoremoves orphaned deps.
   - A cask whose `/Applications` bundle is root-owned needs `sudo` — hand it
     to the human; the MacBook has no passwordless sudo.
4. **Held formulae** print their own follow-up. caddy on the mini needs sudo:
   `brew unpin caddy && brew upgrade caddy </dev/null` over ssh, then
   `op read "op://Private/mac-mini-server/password" --account tkrumm | ssh mini 'cd ~/SourceRoot/dotfiles && make caddy-dns-build'`,
   then `brew pin caddy`.
5. **Never unattended on the mini:** the `tailscale` follow-up (its restart is
   the ssh session you are using — run it only with a human able to reach the
   mini another way), macOS majors, `make herdr-upgrade` from inside a herdr
   pane (it refuses).
6. **Agent tooling, and what is *running*.** Installed ≠ running; check both.
   - **Cooldown override** only on the owner's explicit ask for "recent agent
     tooling" — per command (`brew upgrade --cask <name>`), never by editing
     `minimumReleaseAge` or `brew-upgrade.sh`.
   - **Hermes: never a bare `hermes update`.** It autostashes the local
     patches and restarts the gateway unpatched. Run it through the
     `hermes-update` skill in an agent in the mini's `hermes-agent` workspace
     (`rd work hermes-agent` + `rd say`); `make patch-check` must end green.
   - **herdr server:** compare the running keg
     (`lsof -p $(pgrep -f 'bin/herdr server') | grep txt`) with the installed
     one. Mini: `make herdr-upgrade` / `make herdr-restart YES=1` (human-timed).
     A server hosting your own session is restarted by the human.
   - **collie:** `make collie-upgrade` (mini). Read the scope it prints;
     unattended needs `COLLIE_UPGRADE_YES=1`. A new pairing rule means
     `collie pair` on the phone.
   - **Pinned npm/binary tools** (`FALLOW_VERSION`, `OCR_VERSION` in the
     Makefile): bump the pin, `make _setup-tools` on the mini, install the
     same version on the MacBook.
   - **Bun services:** agent-workflows `make install-opencode` (pinned OpenCode), then `make deploy` (rolls both LaunchAgents to the new release).
   - **macOS:** majors are held by policy; drift-check reports them as info.
     Same-major companions (CLT, Safari) install with the exact label from
     `softwareupdate -l` (e.g. `Command Line Tools for Xcode 27.0-27.0`).
7. **Verify:** `make doctor` from the MacBook (recurses into the mini). Compare
   failures against their `persisted N runs` count before blaming the upgrade.

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

**⏸️ Proceed with upgrades?** (one package at a time, each with a reason — never a blind tree-wide update; see `rules/dependency-hygiene.md`)
- [ ] Patch + minor upgrades, package by package
- [ ] Those plus low-risk majors
- [ ] All upgrades (with code changes)
```

---

## Phase 4: Execute Upgrades

**IMPORTANT:** All commands run from project root. Never cd.

### One package at a time, deliberately (`rules/dependency-hygiene.md`)

Never a tree-wide `--target minor -u` / `bun update` / `npm update`: that
mass-update reflex is exactly what supply-chain attacks count on, and the
release-age cooldown (`~/.bunfig.toml` → `minimumReleaseAge`) only protects an
install that was chosen. Name each package, keep the exact-version pin, and
install after each one so a break is attributable:

```bash
# patch / minor — per package, in the order listed in the plan
npx npm-check-updates -u --target minor <package> [--packageManager bun] && [npm|bun] install

# major — only after research confirmed the migration
npx npm-check-updates -u <package> [--packageManager bun] && [npm|bun] install
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
# Named packages, always:
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
# Patch/minor, per package:
npx npm-check-updates -u --target minor react-dom --packageManager bun && bun install

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
