# dotfiles — Agent Instructions

This file stays under 12,000 bytes (`make context-load` measures it). A new fact goes where `rules/writing-for-agents.md` puts it, almost never here.

## What this repo is

The source of truth for Johannes's Claude Code setup and both Macs' bootstrap. Everything is symlinked outward: edit at either end, git sees the change here, so commit here after every edit. What links where, and what is rendered or copied instead: `docs/symlink-map.md`.

The MacBook (`iumac`) is a thin client: editing, the Herdr app, biometric 1Password, a few Mac-only apps and repos. The Mac mini is the always-on dev host (agents, LaunchAgents, Docker, dev servers), reached through the Herdr app and `rd`.

`docs/architecture.md` is the map of every machine, repo, launchd job, inbound door and secrets flow. Anything that runs on a machine appears there, or `scripts/architecture-check.sh` (run by `make doctor`) exits 1.

A nested `AGENTS.md` loads only when you Read a file in its directory, not on an Edit or a shell command: Read the one for a directory before you change anything in it: `hooks/`, `scripts/`, `config/`, `config/mini/`, `config/postgres/`, `config/zsh/`, `colima/`, `kuma-door/`, `skills/`.

## Validate

`make check` runs every target in `check:`. All are hermetic except `cli-refs`, which asks the installed CLIs for `--help` and fails on a quoted command or flag they lack, on a `rules/clis.md` row whose CLI or list command is gone, and on a skill's injected `!` command that fails with or without its CLI. Mark a deliberate historical mention `<!-- cli-refs: ignore -->`. `make -k check` runs every suite and lists all failures; `make check-linux` is the subset CI runs.

- After any edit to `hooks/`, run `make hooks-test`.
- After any edit to `scripts/secrets-run`, run the full guardrail in §Secrets.
- The repo contract for `AGENTS.md` sections: `docs/agents-md.md`.

## Deploy

`make deploy` is `make setup`: idempotent, run it on both machines. Nothing deploys from CI (it only runs `make check-linux`) and there is no release: a merged commit is live once symlinked. On the mini it then runs `scripts/gate-pin-notice.sh` (`scripts/AGENTS.md` §Deploy gate pins). Every make target: `make help`, `docs/make-targets.md`.

## Verify & Monitor

`make verify` is `make doctor` with host conditions and other leads' drift as WARN, so it fails only on what a change to this repo can break; `make doctor` fails all of it. `make logs` prints a bounded log tail. This repo runs no service: no health URL and no OTel `service.name`. Kuma: `MacMini Dev Host - Push` (liveness: tailnet, sshd, core socket; mini only) and `MacMini Secret Seed - Push` (8-day mtime). Detail: `docs/devhost-health.md`.

## Gotchas

- Edit symlinked files at either end, but never the live `~/.claude/settings.json`: it is merged from `config/settings.template.json` (`config/AGENTS.md`).
- A new always-on rule also goes into `config/opencode/opencode.json` `instructions`.
- Logs go to `~/Library/Logs/<name>.{log,err}`, never `/tmp`: macOS sweeps `/tmp` and launchd opens a log once, so a sweep silently loses the output (`docs/background-jobs.md` §Agent logs).
- `op read` and `op run` hang on the mini: use `secrets-run`.

## Machines & remote dev

Agents run on the mini and outlive the MacBook. The stack is Tailscale (reach), herdr-core (persistence, the Herdr app is its UI) and Caddy (service exposure); no layer substitutes for another. Detail: `docs/remote-dev.md`, `docs/herdr-core.md`, skill `/remote-dev`.

- Never run `ssh mini 'claude …'` and never start a core from ssh. The Max credential lives in the login keychain, which ssh cannot reach: claude comes up `Not logged in`, falls back to API billing, and still looks healthy. `rd work` spawns through the launchd core to avoid this.
- Never restart, stop or update the core outside `make herdr-core-update` (the owner, by hand, in a quiet window). A core restart keeps terminals; a reboot or `kill -9` loses them. `hooks/herdr-core-guard.ts` denies the commands.
- Choose the Claude account on the command (`CLAUDE_CONFIG_DIR`, unset means `iu`), never by inheritance: a core's env is every terminal's env and `hc run` forwards nothing.
- Commands take a repo name, never a path; the host resolves it.
- Work that needs a present human (biometric `op`, an ACL push): `ask-human ask "…" [--cmd … | --need secret|hands|place]`, which pushes a dialog to the MacBook. `ssh iumac` runs fixed verbs only. Detail: `docs/remote-dev.md` §human-queue.
- Changing `scripts/ask-human.sh`, `scripts/human-queue.sh`, `scripts/lib/human-queue-json.sh` or `scripts/human-queue-notify-hook.sh` needs the owner's re-pin of the IuRoot deploy gate: `scripts/AGENTS.md` §Deploy gate pins.
- Work for another repo goes through `factory issue new` (skill `factory`); an edit in this tree goes to `@implementer`.

## Secrets

Two 1Password accounts: `tkrumm` (personal, `~/SourceRoot/`) and `careerpartner` (work, `~/IuRoot/`). Always pass `--account`; `op_account_for_cwd` and `op_run` in `config/zsh/secrets.zsh` resolve it from the cwd. `secrets-run` is a drop-in `op` shim whose backend differs per machine (`~/.config/secrets/backend`, injected each session by `hooks/machine-role.ts`): `op` on the MacBook, a SOPS+age cache on the mini that fails closed on a missing ref.

```bash
secrets-run read op://vault/item/field
secrets-run run [--env-file=<tpl>]... -- <cmd>
```

- Never export `ANTHROPIC_API_KEY`: Claude Code then bills API credits instead of the Max subscription.
- A ref the cache lacks: `make secrets-reseal-request`, never a hand-written ask. The seed, reseal rules and 1Password traps: `scripts/AGENTS.md` §Secrets.
- Any edit to `scripts/secrets-run` is the sole secret path on the mini, so it takes `make secrets-test`, `make secrets-lint` (shellcheck), `design.md` and `security-review.md` updated in the same change, and an adversarial `/review`.
- The data half (`headless.refs`, the encrypted cache, `.sops.yaml`, ACL and serve declarations) lives in `~/SourceRoot/dotfiles-private`. Operations: skill `/secrets`.

## Claude Code launchers

`config/zsh/claude.zsh`. An open shell keeps what it loaded at startup: `source ~/.zshrc` after an edit.

- `c` / `ch`: Opus on the Max subscription, effort medium / high. `cs`: Sonnet high. `cf`: Fable medium, on the account every other pick holds back. Bare `claude` picks the account with `claude-account pick`.
- `oc`: OpenCode, through the inference gateway on the mini (IU direct on the MacBook). `cx` / `cxa`: Codex on the IU endpoint; `astra '<q>'` is one `pro`-mode call.
- The full table, `CLAUDE_ACCOUNT_PICKED`, the orchestrator principal and the token fallback: `config/zsh/AGENTS.md`. Model-choice rationale: `brain/wiki/engineering/model-routing.md`.

## Host topics

Each row holds the rule that applies before you read the file.

| Working on | Rule | Read |
|-|-|-|
| Caddy, `.test` doors, tailnet ACL, Codex and OpenCode config | `config/Caddyfile` is the one app registry; `make caddy-dns-build` after any `brew upgrade caddy`, which reverts the DNS module silently | `config/AGENTS.md` |
| A job, container or door on the mini | Register it in the same commit as its plist; `make mini-ps` and `make doctor` fail on a breach | `config/mini/AGENTS.md`, `rules/run-on-mini.md`, skill `mini-service` |
| Colima | `make colima-*` only, never bare `colima stop` or `brew services restart colima` | `colima/AGENTS.md` |
| Postgres | One bare Homebrew server, never Docker; converge with `make pg-plan` / `make pg-apply` | `config/postgres/AGENTS.md`, `docs/postgres.md` |
| Brewfile | `brew install X`, `make brew-dump`, review the diff; auto-upgrade stays off | `docs/homebrew.md` |
| Heartbeat, drift, boot posture | The doctor and heartbeat are read-only views; `pmset -a autorestart 1` must stay on, its absence is silent | `docs/devhost-health.md`, `docs/make-targets.md` |
| The Kuma door | Monitors are generated, never hand-edited | `kuma-door/AGENTS.md` |
| Collie | It is remote shell access by design: treat its URL like a root login | `docs/collie.md` |
| MacBook-only jobs (opbackup, battery, db-tunnel, smb-keepalive) | They cost every mini agent context for no benefit, so they stay out of mini docs | `docs/macbook.md` |
| Disk, external volume, storage, HomeLab files (`hl`) | Never format or erase the external drive; one home per data class | `docs/disk.md`, `docs/external-ssd.md`, `docs/storage.md` |
| Theme | Zinc `#1f1f23` / `#f2f2f5`, never black or white; `make theme` | `docs/theme.md` |
| Obsidian on the mini | It must keep running, or `/brain` and Hermes lose their door | `docs/brain-access.md` |
| MCP servers | None at user scope: each costs an `npx` and `node` pair in every session; the browser is `shared-chrome` | `docs/browser.md` §MCP servers |
| Host waste | `make host-waste-check` WARNs only | `docs/host-waste.md` |
| Hooks, debug logs | Hooks apply on the next tool call; `make hooks-test` | `hooks/AGENTS.md` |
