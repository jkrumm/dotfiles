# sideclaw — Product Requirements Document

## Problem

The `cqueue` app is a useful dev sidebar but lives embedded inside `dotfiles`, making it awkward to evolve independently and impossible to open-source. The LaunchAgent runs the app directly from the `dotfiles` worktree, so any `git` operation on that repo can destabilize the running process. The app has outgrown its original scope and deserves a proper home.

## Goals

- Extract the entire `cqueue` app into a new standalone public repo `~/SourceRoot/sideclaw`
- Rename everything: app, files, CLI entry points, plist label, localias proxy
- Clean up all references in `dotfiles` (hook, config, CLAUDE.md, aliases)
- Stability improvement: the LaunchAgent points to `sideclaw/` — changes to `dotfiles` no longer affect the running process

## Non-Goals

- Feature additions (actions, GitHub panel, new routes) — out of scope
- UI framework migration (stays BlueprintJS)
- Moving the Stop hook out of `dotfiles`
- Packaging as Electron/Tauri

## Rename Map

| Before | After |
|-|-|
| repo dir | `dotfiles/cqueue/` → `~/SourceRoot/sideclaw/` |
| app name | cqueue → sideclaw |
| plist label | `com.jkrumm.cqueue` → `com.jkrumm.sideclaw` |
| plist filename | `com.jkrumm.cqueue.plist` → `com.jkrumm.sideclaw.plist` |
| WorkingDirectory in plist | `.../dotfiles/cqueue` → `.../sideclaw` |
| queue file | `cqueue.md` → `sc-queue.md` |
| notes file | `cnotes.md` → `sc-note.md` |
| localias proxy | `cqueue.local → 7705` → `sideclaw.local → 7705` |
| CLI script | `scripts/queue.ts` → **deleted** (never used) |
| `cq` alias comments | removed from `aliases.zsh` |

Port stays **7705**.

## Technical Approach

### 1. Create new repo

```
~/SourceRoot/sideclaw/
```

Copy all files from `dotfiles/cqueue/` with renames applied. Initialize as a new git repo, push to GitHub as `jkrumm/sideclaw` (public).

### 2. Code-level renames

- All string occurrences of `cqueue` → `sideclaw` in source files
- All string occurrences of `cnotes.md` → `sc-note.md`
- All string occurrences of `cqueue.md` → `sc-queue.md`
- `com.jkrumm.cqueue` → `com.jkrumm.sideclaw` in plist
- `package.json` name field → `sideclaw`
- Page `<title>` and any UI text referencing "cqueue" → "sideclaw"

### 3. LaunchAgent swap

- Unload old agent: `launchctl unload ~/Library/LaunchAgents/com.jkrumm.cqueue.plist`
- Remove old plist from `~/Library/LaunchAgents/`
- `make install-agent` from new sideclaw repo installs and loads new plist

### 4. File migration

One-time rename across both workspaces:
```bash
find ~/SourceRoot ~/IuRoot -maxdepth 2 -name "cqueue.md" -exec sh -c 'mv "$1" "$(dirname "$1")/sc-queue.md"' _ {} \;
find ~/SourceRoot ~/IuRoot -maxdepth 2 -name "cnotes.md" -exec sh -c 'mv "$1" "$(dirname "$1")/sc-note.md"' _ {} \;
```

### 5. `dotfiles` cleanup

- `hooks/notify.ts`: update `cqueue.md` → `sc-queue.md` (lines 191, 797)
- `config/localias.yaml`: `cqueue.local` → `sideclaw.local`
- `config/zsh/aliases.zsh`: remove `cq` comment block
- `scripts/queue.ts`: delete
- `scripts/statusline.sh`: check for any cqueue references
- `CLAUDE.md` files: update all references to cqueue/cnotes/cq
- `config/gitignore_global`: update `cqueue.md` → `sc-queue.md`, `cnotes.md` → `sc-note.md`
- `cqueue/` dir: keep temporarily, remove in follow-up commit

### 6. sideclaw CLAUDE.md

New `CLAUDE.md` in sideclaw repo covering: stack, Makefile targets, LaunchAgent pattern, `.env` setup.

## Success Criteria

- `sideclaw.local` opens the app in the browser
- LaunchAgent starts on boot from `~/SourceRoot/sideclaw/`
- `make reload` (from sideclaw) rebuilds and restarts without touching `dotfiles`
- `hooks/notify.ts` pops tasks from `sc-queue.md` correctly
- No stale references to `cqueue` or `cnotes` in `dotfiles`
- GitHub repo `jkrumm/sideclaw` is public and has a clean initial commit
