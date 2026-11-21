# Symlink map

What links where, and what is rendered or copied instead. Edit at either end of a symlink; git sees the change in the repo. `make status` checks link health.

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global instructions (single source — no per-workspace layer). Claude Code and OpenCode both load it; the per-repo file is `AGENTS.md` alone, no `CLAUDE.md` — `docs/agents-md.md` |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | aliases, brew, claude, claude-auth, codex, git, keybindings, path, prompt, remote-dev, secrets, secrets-cache, ssh-agent, tools |
| `config/gitconfig{,-personal,-work}` | `~/.gitconfig*` | `includeIf` per workspace; 1Password commit signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/codex/astra.config.toml` | `~/.codex/astra.config.toml` | The `cxa` profile. `config/codex/config.toml.tpl` is **rendered**, not linked (below) |
| `config/codex/AGENTS.md` | `~/.codex/AGENTS.md` | Codex's global brief — environment facts only, deliberately **not** the Claude method |
| `config/opencode/opencode.json` | `~/.config/opencode/opencode.json` | The **file** only — the dir holds opencode's plugin `node_modules`. Rules via `instructions`, IU provider via `{env:IU_*}`, yolo via `permission` |
| `config/opencode/tui.json` | `~/.config/opencode/tui.json` | TUI-only keys. `theme` lives **here**, not in `opencode.json` |
| `config/opencode/themes/` | `~/.config/opencode/themes/` (dir symlink) | `one-zinc.json` — the dark/light palette shared with Ghostty + the Herdr app |
| `config/opencode/plugins/protect-branches.js` | `~/.config/opencode/plugins/` (the **file**) | Runs `hooks/protect-branches.ts` on every bash call: one branch-protection policy for both harnesses |
| `config/opencode/plugins/claude-hooks.js` | `~/.config/opencode/plugins/` (the **file**) | Runs a repo's `.claude/settings.json` Pre/PostToolUse command hooks after OpenCode's edit, write and patch (`docs/opencode.md`) |
| `agents/*.md` | `~/.config/opencode/agent/*.md` — **rendered**, not linked | `scripts/opencode-agents.py` rewrites Claude's frontmatter (OpenCode rejects `tools: A, B` and `color: green`, and one bad file fails the whole config) |
| `config/herdr-app/` | `~/.config/herdr-app/` (per item, by `make herdr-app-setup`) | Layout `jk`, mods, themes `one-zinc-*`, `groups.json` (sidebar folders, one line per repo); link per item, never the dir (it holds the app's shipped mods) |
| `config/herdr-core/config.toml` | `~/.config/herdr-core/config.toml` | Core settings (`restore_screen`); linked by `make herdr-core-setup`, read at the next core start |
| `config/ghostty/config` | `~/.config/ghostty/config` | The one terminal config. Themes under `config/ghostty/themes/` are **copied**, not symlinked (Ghostty theme names are exact filenames) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS proxy + the single app registry — edit here, then `caddy reload` |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Source of truth for PR-required repos — read by `protect-branches.ts` **and** `scripts/github-config.sh` |
| `rules/` | `~/.claude/rules/` (dir symlink) | All global rules. No `paths:` frontmatter → always on; with `paths:` → lazy. Roster in the global file's *Config hierarchy*. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`, `verifier.md`, `browser.md` (playwright-cli plus the `chrome-devtools` CLI; no MCP), `Explore.md` and `general-purpose.md` (replace the built-ins; the Explore one inherits the caller's model otherwise), and the read-only `reviewer.md` + `review-verifier.md` that `/review` calls (`Agent(type)` restrictions are ignored in subagents, so "spawn only review-verifier" is prose). Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md`, activated by `outputStyle` in settings.json |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every session, symlinked individually |
| `hooks/{session-env,protect-branches,docker-makefile,broad-kill-guard,review-bypass-guard,herdr-core-guard,launchd-env-guard,test-slot,permission-allow,machine-role,model-discipline,iu-model-guard,nested-agents}.ts` | `~/.claude/hooks/` | Live symlinks — an edit applies on the next tool call |
| `config/settings.template.json` | merged into `~/.claude/settings.json` | Never edit the live file (`config/AGENTS.md` §settings.json merge) |
| `scripts/statusline.sh` · `scripts/fetch_usage.py` | `~/.claude/` | Statusline · usage adapter over `claude-account` (uv script, no API calls) — `docs/statusline.md` |
| `scripts/shared-chrome.ts` | `~/.local/bin/shared-chrome` | `ensure`/`devtools`/`status`/`stop` for the one headless Chrome behind `/browse` (and the one chrome-devtools daemon on it); its supervisor is `com.jkrumm.shared-chrome` (`make shared-chrome-setup`, in `make setup`) |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim (`AGENTS.md` §Secrets, `scripts/AGENTS.md` §Secrets) |
| `scripts/remote-dev.sh` | `~/.local/bin/rd` | Place work on the mini — `rd work\|agents\|read\|say` (`AGENTS.md` §Machines & remote dev) |
| `scripts/ask-human-local.sh` | `~/.local/bin/ask-human` | Queue / push a request that needs a present human; `ask-human.sh` on the mini, the dialog local on the MacBook (`docs/remote-dev.md` §human-queue) |
| `scripts/agent-note.sh` | `~/.local/bin/agent-note` | Agent to agent across the mini and the MacBook (`docs/remote-dev.md` §Agent notes) |
| `scripts/astra.sh` | `~/.local/bin/astra` | One-shot Responses call at `reasoning.mode="pro"` — `docs/codex.md` |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run it in a **bare** terminal. |
| `skills/img/scripts/imgcli` | `~/.local/bin/imgcli` | `/img` CLI |
| `scripts/hl` | `~/.local/bin/hl` | HomeLab files over S3 — rclone with an env-defined `homelab:` remote + `presign`/`mount`; key per machine (`docs/storage.md` §HomeLab files) |
| `scripts/cargo-target-seed.sh` | `~/.local/bin/cargo-target-seed` | The one warm-cargo-`target/` tool for every Rust repo (`key`/`clone`/`build`/`jobs`; seeds under `~/cache/<repo>/seed`; the touch rule lives only here) — `docs/cargo-target-seed.md` |
| `~/.software-factory/current/packages/accounts/bin/claude-account.ts` (mini) · `~/.local/share/claude-account/claude-account` (MacBook, `scripts/claude-account-sync.sh`) | `~/.local/bin/claude-account` | The factory's accounts package: account picker + quota cache over the registry; `make claude-account-rollback` points the link back at `scripts/claude-account.ts`, `make claude-account-forward` undoes it — `docs/claude-accounts.md` §Package |
| `config/claude-accounts.json` | `~/.config/claude-accounts/registry.json` | The registry path the package reads (both machines; the rollback copy reads the dotfiles path directly) |
| `scripts/claude-account.ts` | rollback target only | The pre-package picker, kept until subs-cleanup-dotfiles; `make claude-accounts-setup` builds `~/.claude-me`; `make claude-accounts-verify` (in `make doctor`) and `make claude-accounts-e2e` prove routing + attribution; the hourly keepalive agent keeps logins alive; `claude-account expiry` says when each login ends — `docs/claude-accounts.md` §Operate |
| `scripts/claude-relogin.sh` (+ `claude-login-browser.sh`) | `~/.local/bin/claude-relogin` | One-click re-login on the machine that owns the credential: `claude-relogin <id> [--machine mini\|macbook] [--ask] [--visible] [--dry-run]`; the owner only approves in the account's browser (never automated) — `docs/claude-accounts.md` §Re-login |
| `scripts/jobrun.ts` · `scripts/lib/jobs-grade.ts` | `~/.local/bin/jobrun` · `~/.local/bin/jobs-grade` | bun/TS job recorder and the only job-grading logic (`docs/background-jobs.md` §Pattern; alerts in `docs/ops-signals.md`); `make jobs-test`; the 300 s `com.jkrumm.jobrun-canary` is the chain probe; the dotfiles jobs run under `jobrun` in their plists |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — `caddy reload`, Colima socket heal, and (MacBook) `jobs-grade --notify` 2 min after wake, staleness judged against awake time |

**Not symlinked:** `~/.codex/config.toml` (rendered by `_setup-codex` from
`config/codex/config.toml.tpl` — it needs the IU endpoint host, which never
enters git) · `~/.ssh/config` (copied from `config/ssh_config` — colima
appends its own `Include`; all four hosts are MagicDNS short names, so it installs
identically on a headless machine, no secret and no `op` call) ·
`config/tinycast/defaults.json` (applied to Tinycast's defaults domain by
`scripts/tinycast-config.py`, never on the mini; live wins, `make tinycast-check`) ·
`~/.claude/settings.json` (merged, `config/AGENTS.md`) · `~/.gitconfig-headless` (written only
by `make git-headless` on the mini) · `scripts/doctor.sh` (invoked by `make
doctor`).

**Per-repo skills** are committed, not symlinked, and load only inside their repo.
This repo ships one: `.claude/skills/iu-endpoint/` — validates the IU unified
endpoint and diffs the live catalog against `models.txt`.
