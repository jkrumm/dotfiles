# config

## settings.json merge

The template wins on structural keys (hooks, statusLine,
plugins, env) and on `permissions.deny` + `permissions.defaultMode`
(`bypassPermissions`, so resumed and `rd work` terminals come back
in bypass, not manual); `permissions.allow` and
`model`/`effortLevel`/`alwaysThinkingEnabled` are preserved from the live file.

**Code Mode is on for every session** (`env.CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`, an experimental Claude Code
feature). Each tool call from a script still passes the PreToolUse hooks under its usual tool name; the script itself
is the `REPL` tool.

- **Off for one launch:** `CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=0 c` (a `0` anywhere wins).
- **Off for good:** delete the line and re-render. A session started in Code Mode then resumes only with the variable
  set to `1` in its shell, so let those sessions finish first or resume them by hand.
- **A new account or machine:** the first Code Mode launch shows a consent dialog (stored as
  `codeModeCaveatsAcceptedV1` in that account's `.claude.json`). Accept it once in an interactive `c --account <id>`
  before unattended work lands there, because an unattended launch waits at the dialog.


## Output style

**Changing how Claude *talks* is `config/output-styles/Direct.md`, not this file:**

| Concern | Lives in | Why |
|-|-|-|
| Response shape, autonomy, question budget, delegation posture | `output-styles/Direct.md` | Appended at the *end* of the system prompt and survives `/clear` |
| Project/machine facts, routing, conventions | `AGENTS.md` (alone — a `CLAUDE.md` would suppress it) | Reference material to look things up in |

`keep-coding-instructions: true` is load-bearing (`false` drops the built-in
coding prompt). Read at session start (`/clear` to apply), never reaches
subagents (tone lives in `agents/*.md`), and carries the standing delegation
authorization.


## Dev-server doors

**`config/Caddyfile` is the single app registry.** Every
`<name>.test { reverse_proxy localhost:PORT }` block automatically gets a clean
tailnet door — a new app needs nothing else. A block with more than one `reverse_proxy` handler, or upstreams on different ports (a path split, such as `fpp-next.test`), is skipped by `scripts/lib/caddy-registry.py`: no tailnet door.

| Door | URL | Scope |
|-|-|-|
| Local | `https://<name>.test` | this machine only (`bind 127.0.0.1`, dnsmasq wildcards `*.test`) |
| Clean | `https://<name>.mini.jkrumm.com` | tailnet — one wildcard site block, Cloudflare DNS-01 cert, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` |

`make caddy-tailnet` regenerates + validates + reloads (dev host only).
`make caddy-dns-build` rebuilds Caddy with the Cloudflare DNS module — one-time
and **after any `brew upgrade caddy`**, which silently reverts it.

Gotchas (opt-out ports file, `caddy adapt` registry reads, `localhost` vs
`127.0.0.1` upstreams, one site block per app, 502-vs-403, HTTP/3 off, DNS
negative-caching at two layers): `docs/remote-dev.md` §Dev-server doors. The apps page starts and stops registry
services and a stopped dev server's door wakes it: `docs/mini-registry.md` §Apps page.


## Codex, OpenCode, tailnet

- **Codex** (`cx`/`cxa`/`astra`) is the rare second opinion; Responses-only wire
  protocol is why it is Codex and not a proxy. `codex --strict-config` validates
  any edit to `config/codex/`; `codex exec` needs `</dev/null` in scripts.
  Everything else: `docs/codex.md`.
- **OpenCode** (`oc`) reads `AGENTS.md`, `~/.claude/CLAUDE.md` and every skill
  natively; always-on global rules come from `instructions` in
  `config/opencode/opencode.json` (a new always-on rule must be added there too).
  Headless `run` ends on any `ask` permission; `theme` lives in `tui.json`; a
  missing `opencode.json` is a silent failure — `make status` lists the links.
  Everything else: `docs/opencode.md`.
- **Tailnet ACL and serve** are declared in `dotfiles-private` and apply **from
  the MacBook**: `make tailscale-acl-diff` (always first) · `-acl-pull` ·
  `-acl-push` · `make tailscale-serve` / `-check`. **Updates, every machine:** `make tailscale-status` / `make tailscale-upgrade [HOST=]`. Every listening port needs a
  grant and the failure is silent; `:8443` is the machine's entire public surface
  (Funnel). Everything else: `docs/tailnet.md`.
