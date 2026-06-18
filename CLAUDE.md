# dotfiles — Claude Code Instructions

## What This Repo Is

VCS source of truth for Johannes's Claude Code setup. Everything is symlinked
outward — edit at either end, git always sees the change here.

TTS/STT runs via the **audio-gateway** service (`~/SourceRoot/audio-gateway`,
OpenAI-compatible VPS container at `audio-gateway.jkrumm.com`, reached over the tailnet).
It fronts the IU unified audio endpoint (STT + expressive Gemini TTS). Hermes and Argo
point at it. LLM is also cloud — Hermes uses Sonnet 4.6 via the IU unified endpoint.

The `localai/` directory (per-machine `mlx-audio` STT + Fish S2 Pro TTS, :8000/:8001/:8002)
is **RETIRED** (2026-05-25): no longer in the `make setup` chain and not running. Files are
kept, not deleted, for an easy re-add. Tear down a live install with `make localai-teardown`.
See `localai/README.md` and the `/localai` skill (both marked retired).

**Companion repo: `~/SourceRoot/hermes-agent`** — Hermes Agent setup (Mac Mini-only).
Historically pulled the `localai-helper` plist template from
`localai/com.localai.helper.plist.template` here; now that Hermes consumes the VPS
audio-gateway, that helper is retired too — clean it up in hermes-agent's own setup. See
`hermes-agent/CLAUDE.md`.

**After any edit: commit here.**

## Docker runtime: Colima

The Docker runtime on every Mac is **Colima** (Lima + Apple Virtualization.Framework),
installed by `make setup` (`_setup-colima`) — it replaced OrbStack (commercial license
enforced via phone-home) and Docker Desktop (heavy). `make setup` brews
`colima docker docker-compose docker-credential-helper lazydocker` (the credential
helper supplies `docker-credential-osxkeychain`, which OrbStack used to provide and the
CLI needs for `"credsStore": "osxkeychain"`), wires the Compose plugin path into
`~/.docker/config.json`, creates the VM (`vz` + Rosetta amd64 emulation + virtiofs
mounts), pins the `colima` docker context, registers the **brew service**
(`RunAtLoad` + `KeepAlive`) so it's always-on and auto-starts at login, and installs the
`com.colima.docker-socket` LaunchDaemon (see **Docker socket** below).

Resources are set by `COLIMA_CPU` / `COLIMA_MEMORY` / `COLIMA_DISK` (defaults
**2 / 4 / 60**). These are **ceilings, not reservations**: idle VM holds ~1.3GB on the
host regardless of the cap, and CPU is time-shared (free when idle). Bump for heavy
stacks (e.g. ClickHouse + Redpanda): `COLIMA_MEMORY=10 make colima-restart`.

Manage with `make colima-{start,stop,restart,status}` — these wrap **`brew services`**,
not bare `colima stop` (KeepAlive would relaunch it). `colima-restart` also applies the
current `COLIMA_CPU/MEMORY` to the persisted config (disk only grows via recreate).

No GUI ships with Colima by design — use the **Raycast "Manage Docker" extension**
(start/stop/restart containers) and **`lazydocker`** (TUI: logs/stats/exec). The
`docker-makefile` rule still applies — drive containers via repo Makefile targets,
not raw `docker`/`compose`. Colima provides no auto-domains; local HTTPS routing is
handled by the existing Caddy + dnsmasq `*.test` setup.

**Docker socket:** Colima's engine socket is `~/.colima/default/docker.sock`. A root
**LaunchDaemon** (`com.colima.docker-socket`, template in `colima/`, installed to
`/Library/LaunchDaemons` by `_setup-colima`) maintains `/var/run/docker.sock` → that
socket at every boot — exactly what OrbStack's privileged helper did. This single
mechanism makes the standard default socket work for **everything**: the docker CLI, the
Raycast Docker extension (which sanitizes extension env vars, so `DOCKER_HOST`/context
*cannot* reach it — the `/var/run` socket is the only thing that does), IDEs,
Testcontainers, and scripts. The CLI additionally has the `colima` context pinned.
Reboot-, brew-upgrade-, and colima-restart-safe (the symlink target path is stable).
Installing the daemon needs sudo (like the Caddy step). A GUI app that was already running
during first install must be quit + relaunched once to retry the socket.

## Homebrew (Brewfile + supply-chain hardening)

All brew-managed packages are declared in **`Brewfile`** (repo root) — the single
source of truth (full machine manifest: taps + formulae + casks). `make setup`
installs from it in one `brew bundle install` step (`_setup-packages`), so the
per-tool `brew install` lines are gone from the Makefile; each `_setup-*` step now
only *configures* (links config, runs services, wires the VM). **npm-global and uv
tools stay Makefile-managed** (fallow, litellm, etc.) — they need Node/uv on PATH,
not ready that early in bootstrap — so the Brewfile is deliberately brew-native only.

Keep it honest (the Brewfile's **git history is the supply-chain audit trail** —
nothing joins the manifest without a reviewed diff):

- `make brew-check` — verify machine == Brewfile (read-only).
- `make brew-diff` — list installed-but-undeclared packages (dry-run).
- `make brew-dump` — regenerate from machine (brew-native only; preserves the header), then **review the git diff** before committing.

Adding a brew package: `brew install X` → `make brew-dump` → review diff → commit
(or edit `Brewfile` → `brew bundle install`). Source of truth is the **file**, not
the machine.

**Hardening** lives in `config/zsh/brew.zsh`: `HOMEBREW_REQUIRE_TAP_TRUST=1`
(refuse untrusted third-party taps). `_setup-packages` auto-runs `brew trust` on exactly
the taps the Brewfile declares **before** `brew bundle` — otherwise a declared-but-untrusted
tap makes bundle refuse and abort the whole manifest on a fresh machine (this once silently
skipped colima/docker). Self-maintaining: trust follows the vetted manifest, no hardcoded list.
Other hardening: `HOMEBREW_NO_INSECURE_REDIRECT=1`, `HOMEBREW_NO_ANALYTICS=1` (also `brew analytics
off`). Auto-*update* (metadata refresh) stays on; auto-*upgrade* is the npm-style
risk and is **never** enabled — upgrade one package at a time (`/upgrade-deps`).

## Symlink Map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions (single source — no per-workspace layer) |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | ai, aliases, brew, claude, git, keybindings, opencode, path, secrets, tools |
| `config/opencode/opencode.json` | `~/.config/opencode/opencode.json` | OpenCode CLI config — IU unified-endpoint providers (no secrets/hostnames; `{env:IU_*}` placeholders) |
| `config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` | OpenCode global preamble — defers to `~/.claude` config via `instructions` |
| `config/gitconfig` | `~/.gitconfig` | includeIf per workspace |
| `config/gitconfig-personal` | `~/.gitconfig-personal` | jkrumm@pm.me + 1Password signing |
| `config/gitconfig-work` | `~/.gitconfig-work` | johannes.krumm@iu.org + 1Password signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Global Bun config — supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/ghostty/config` | `~/.config/ghostty/config` | Shell integration + option key settings |
| `config/ghostty/config.cmux` | `~/Library/Application Support/com.mitchellh.ghostty/config` | Primary cmux config — font, theme, cursor, padding |
| `config/ghostty/themes/*` | `~/.config/ghostty/themes/` | Blueprint v6 light/dark terminal themes (copied, not symlinked — cmux symlink bug) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS reverse proxy — edit here, then `caddy reload` |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — runs `caddy reload` on wake |
| `hooks/notify.ts` | `~/.claude/hooks/notify.ts` | All 4 hook events |
| `hooks/protect-branches.ts` | `~/.claude/hooks/protect-branches.ts` | PreToolUse — blocks push to protected branches |
| `hooks/docker-makefile.ts` | `~/.claude/hooks/docker-makefile.ts` | PreToolUse — blocks raw docker commands when Makefile exists |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Single source of truth for PR-required repos — read by `protect-branches.ts` (hook) and `scripts/github-config.sh` (full vs lite ruleset tier). |
| `scripts/statusline.sh` | `~/.claude/statusline.sh` | 3-line statusline |
| `scripts/fetch_usage.py` | `~/.claude/fetch_usage.py` | Claude.ai usage % fetcher (uv script) |
| `rules/` | `~/.claude/rules/` (dir symlink) | Global rules (attribution, commit conventions, dependency hygiene, formatting, research-first, security, TypeScript, code style, docker-makefile, visx-charts) |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every Claude Code session. Each skill is symlinked individually. |

**Per-repo skills** (not symlinked — committed to the repo, load only when Claude is started inside that repo):
- `.claude/skills/localai/` — **RETIRED** (local mlx-audio / Fish S2 Pro stack, replaced by the VPS audio-gateway). Kept for an easy re-add.
- `.claude/skills/iu-endpoint/` — validate the IU unified endpoint + discover newer/better models for OpenCode and Hermes (`validate.sh` probes transports, health-checks configured models with backend-redundancy, diffs the live catalog).

**Generated (not symlinked):** `~/.ssh/config` — written by `_setup-ssh` from the `config/ssh_config` template; the `iumac` and `mac-mini` host aliases get their hostnames injected from `op://Private/{iumac,mac-mini}-server/hostname` (keeps tailnet names out of git). `mac-mini` sets `ForwardAgent yes` so the always-on Mac mini can do git/ssh ops with approval popping on the connecting machine's 1Password.

**Not symlinked:** `~/.claude/settings.json` — machine-specific permissions.
`make setup` creates from template if missing, otherwise jq-merges:
template wins on structural keys (hooks, statusLine, plugins, env); permissions + model/effortLevel/alwaysThinkingEnabled preserved from live file.

## Remote access (Mac mini, over Tailscale)

The Mac mini is the always-on home base (Hermes + Feuer run here), reached from the
MacBook over Tailscale — never the public internet. `make remote-access` (opt-in per
machine, **not** in the default `setup` chain — enabling an SSH server is a deliberate
per-host call) makes a Mac remotely controllable:

- Installs trusted public keys from `config/ssh/authorized_keys` into `~/.ssh/authorized_keys`
  (append-if-missing; public keys, safe to commit — served by the 1Password SSH agent).
- Installs the key-only sshd hardening drop-in (`config/sshd/200-hardening.conf.template`
  → `/etc/ssh/sshd_config.d/200-hardening.conf`, `__SSH_USER__` injected): no root, no
  passwords (both `PasswordAuthentication` and `KbdInteractiveAuthentication` off —
  required under macOS `UsePAM yes`), `AllowUsers <you>`, agent forwarding on. Guarded on
  `authorized_keys` being non-empty so it can't lock out SSH.
- Remote Login + Screen Sharing toggles are best-effort (TCC/SIP usually need System
  Settings → General → Sharing); set "Allow access for" to your user only, VNC password off.

Two boundaries gate access: the Tailscale ACL (`tag:mac → tag:mac` on 22/5900, in
`homelab-private`) restricts the source to your own Macs, and sshd is key-only. Keep the
router free of any WAN port-forward for 22/5900 — that would bypass both. **Work (Feuer)
secrets stay biometric-gated**: redeploy via Screen Sharing (unlock 1Password by account
password), not a token at rest. The personal-side Hermes path will use a scoped 1Password
service account (token in Keychain) — planned, not yet wired.

## Secrets Strategy

Two 1Password accounts are configured:
- **`tkrumm`** — personal account, used in `~/SourceRoot/`. Always pass `--account tkrumm` to `op` CLI.
- **`careerpartner`** — work account, used in `~/IuRoot/`. Always pass `--account careerpartner` to `op` CLI.

`make setup` uses `--account tkrumm` (biometric/session token via Touch ID).

`ANTHROPIC_API_KEY` is intentionally **not exported** — Claude Code falls back to the subscription when the key is absent. Exporting it would cause Claude Code to bill API credits instead.

**API keys** cached in macOS Keychain by `make setup`:
- `CLAUDE_SDK_API_KEY` + `CLAUDE_SDK_BASE_URL` — from `op://common/anthropic/API_KEY` and `BASE_URL`. Used for API offloading via `claude -p`.

**Chrome DevTools MCP** — registered globally with deferred tool loading (~400 tokens overhead). Used exclusively via `/browse` skill (haiku fork) to isolate expensive MCP responses from main context.

**MCP-per-project policy** — keep project MCPs minimal. Global servers are only `sideclaw`, `chrome-devtools`, and `research-gateway` (the remote research MCP), all deferred (names only in context, schemas via ToolSearch). The **only** repo running real project-level MCPs is `prometheus-scripts/jupyter` (db/datadog/marimo, in a git-ignored `.mcp.json`). `epos_fe.spa-orchestrator`'s `.mcp.json` (nitrox + Figma Desktop) is declarative IDE config, not always-on. No other repo has or needs project MCPs — don't add one without a deliberate reason. (Note: jupyter's datadog block hardcodes keys in the git-ignored file; the sibling `db` server uses `op run` — migrate datadog to `op run` when convenient.)

**CodeRabbit CLI** — requires one-time auth: `coderabbit auth login` (GitHub OAuth). Free tier: 3 reviews/hour. Used by `/review` and `/ship` skills.

**New machine setup:**
1. Install 1Password + enable CLI integration (Settings → Developer → Enable CLI)
2. `make setup` — will fail fast with instructions if 1Password isn't ready

## OpenCode (Claude Code fallback)

OpenCode CLI is wired as a fallback for when the Claude Code Max subscription is
exhausted. It runs against the **IU unified endpoint** using the same credential
as the Agent SDK (`op://common/anthropic`).

- **Two providers** in `config/opencode/opencode.json` (both keyed off one IU credential):
  - `iu` — OpenAI-compatible gateway (`…/openai/v1`). Holds the **default `iu/DeepSeek-V4-Pro`** (coding/smart, EU — Azure Spain) and **small `iu/DeepSeek-V4-Flash`** (fast/cheap, EU — Azure Spain), plus the zoo: Kimi-K2.6/K2.5, GPT-5.5, Gemini 3.1 Pro / 3.5 Flash / 2.5 Pro, GLM-5, MiniMax-M2.5, Qwen3-Coder-480B, DeepSeek-V3.2, and the EU/GDPR Claude aliases `claude-sonnet-4-6-eu` / `claude-haiku-4-5-eu`.
  - `iu-anthropic` — native Anthropic API (`…/anthropic/v1`), best Claude fidelity (prompt caching): `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`. Native routing is **not** EU-guaranteed — use the `iu/*-eu` aliases for GDPR.
- **Reliability — the model alias is the host selector.** Each id maps to one or more backend "sinks" (`owned_by`); more = more redundant. `claude-opus-4-6` (3 backends) > `claude-opus-4-7` (1, occasionally slow); `Kimi-K2.5` (2 backends) but **not EU**; `Kimi-K2.6` (1 backend, Sweden Central, throttle-prone) but **EU**. The current defaults `DeepSeek-V4-Pro`/`DeepSeek-V4-Flash` serve from Azure Spain (EU) — run `/iu-endpoint` for their live backend counts. The AI SDK auto-retries 429s. Run `/iu-endpoint` for live health + backend counts. There is **no** `/bedrock` passthrough (404) — Bedrock is only an internal backing; `/azure`, `/gemini`, `/replicate` transports exist but `/openai/v1` already fronts the richest catalog. `*-codex` models return empty over chat-completions (responses API only) — don't configure them.
- **EU data residency / GDPR.** Serving region is exposed in response headers (`x-ms-region`, `x-middleware-forwarded-server`); `/iu-endpoint` shows it as an EU/US column. Verified **EU**: `DeepSeek-V4-Pro` / `DeepSeek-V4-Flash` (Azure Spain Central), `Kimi-K2.6` (Azure Sweden Central), the `*-eu` Claude aliases **over the openai-compat transport** (route to the "GDPR ONLY" gateway), `gpt-5.5` (Sweden). **NOT EU-safe**: `Kimi-K2.5` (Nebius + Azure US-East-2), native `iu-anthropic` Claude (can route US), Nebius-served models (`GLM-5`, `DeepSeek-V3.2` — region not exposed, shown `?`). Default is `iu/DeepSeek-V4-Pro` so the fallback is EU by default. Hermes Kimi switch: `.claude/skills/iu-endpoint/hermes-kimi-handover.md` (K2.6 primary + `claude-sonnet-4-6-eu` fallback).
- **Secrets:** `opencode.json` contains no key and no hostname — only `{env:IU_*}` placeholders. The `opencode()` wrapper in `config/zsh/opencode.zsh` injects `IU_API_KEY` + both base URLs into the OpenCode process **only** (not the interactive shell), read just-in-time from the existing `claude-sdk-*` Keychain entries. Both base URLs are derived from `claude-sdk-base-url` (`…/anthropic` → `…/anthropic/v1` and `…/openai/v1`), so no new Keychain entry or 1Password field is needed.
- **Why `IU_*` and not `ANTHROPIC_*`:** exporting `ANTHROPIC_*` would push Claude Code itself onto IU API billing instead of the Max subscription. Distinct names keep Claude Code on the subscription; OpenCode is the deliberate fallback.
- **CLAUDE.md compatibility:** `instructions` loads `~/.claude/CLAUDE.md`, the always-on global rules listed individually, and per-project `.claude/rules/*.md`; per-project `CLAUDE.md` auto-loads via OpenCode's native fallback. A minimal global `AGENTS.md` takes control of the global slot (and disables the duplicate `~/.claude/CLAUDE.md` auto-fallback). OpenCode ignores `paths:` frontmatter, so the path-scoped framework rules (`react-best-practices`, `tanstack-*`, `elysia`) are deliberately excluded from the global list; put them in a project's `CLAUDE.md`/`.claude/rules/` when needed.
- **Usage:** `oc` (TUI) · `ocr "<prompt>"` (one-shot) · `opencode -m iu/DeepSeek-V4-Pro …` (pick model). Adding a model = edit `opencode.json`, no `make setup` needed (symlinked).

## Editing Rules

**Adding a global skill:** create `skills/{name}/SKILL.md` here, then `make setup` — it gets symlinked into `~/.claude/skills/{name}/` and loads in every session.

**Adding a per-repo (dotfiles-only) skill:** create `.claude/skills/{name}/SKILL.md` here directly (committed, no symlink). Loads only when Claude starts inside this repo. Used for skills that manage this repo's infrastructure (e.g. `iu-endpoint`).

**Adding a global rule:** create `rules/{name}.md` here. The entire `rules/` dir is symlinked to `~/.claude/rules/`. Rules without `paths:` frontmatter load every session. Rules with `paths:` load lazily.

**Skills scope:** global skills load everywhere (SourceRoot, IuRoot, anywhere) via `~/.claude/skills/`. Workspace-specific behavior (e.g. SourceRoot vs IuRoot 1Password account) is handled inside the skill via the `op_account_for_cwd` helper or explicit `$PWD` guards.

**settings.json changes:** update `config/settings.template.json`, then `make setup`
to merge into the live file. Never edit the live settings.json for persistent changes.

## Debug Logs

Structured JSONL logs at `~/.claude/logs/YYYY-MM-DD.jsonl`. Written by `hooks/notify.ts` and `scripts/fetch_usage.py`. 3-day auto-cleanup on every invocation.

**Query examples:**
```bash
# All events today
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq .

# Hook stop decisions only
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.event == "stop_decision")'

# fetch_usage errors
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.src == "fetch_usage")'
```

**Key events to check when debugging:**
- fetch_usage broken → `fetch_error` with `type` field shows which exception class failed
- Notification routing → `received` shows which event fired with cwd/session context

## Terminal Setup

**cmux** (`/Applications/cmux.app`) is the primary terminal — a macOS-native multiplexer built on top of Ghostty. It is **not tmux**. cmux reads `~/.config/ghostty/config` for terminal rendering (same syntax as Ghostty) and stores its own app preferences (appearance mode, sidebar, etc.) in macOS defaults under `com.cmuxterm.app`.

**Config files (two separate files, both managed in dotfiles):**
- `~/Library/Application Support/com.mitchellh.ghostty/config` — **primary cmux config** (font, theme, cursor, padding). This is what cmux actually reads.
- `~/.config/ghostty/config` — shell integration + option key settings only; lower priority

**Theme auto-switching:**
- cmux app chrome: `appearanceMode = system` (stored in plist — follows macOS appearance)
- Terminal colors: `theme = dark:basalt-ui-dark,light:basalt-ui-light` in the cmux config above
- Theme files: copied (not symlinked) to `~/.config/ghostty/themes/` — cmux has a bug where it skips symlinked theme files
- Claude Code: `c()` in `claude.zsh` writes `theme` key to `~/.claude.json` via `jq` on each launch

## Key Technical Facts

- Skills route via four modes: **inline** (no `model:` frontmatter — run on session model), **subprocess** (skill body shells `claude -p` with Keychain API key), **MCP/sideclaw** (registered tool with JSON schema + heartbeat + quota routing), **fork** (`context: fork` — wrap deferred MCP tools). See global CLAUDE.md `Token Efficiency` for the decision tree.
- `c()` in `config/zsh/claude.zsh`: writes Claude Code theme to `~/.claude.json`, then invokes `claude --dangerously-skip-permissions`. No `--plugin-dir` — global skills load from `~/.claude/skills/` automatically.
