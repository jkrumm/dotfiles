# OpenCode — the third lane

`oc` = OpenCode on the IU endpoint, re-added 2026-09-23 after
the 2026-09-04 subtraction because AGENTS.md made it a zero-maintenance reader
of the same instructions. It loads `<repo>/AGENTS.md` (nested lazily),
`~/.claude/CLAUDE.md` and every skill natively; the always-on rules come from
`instructions` in `config/opencode/opencode.json` — list only global rules
without `paths:`; the per-repo `.claude/rules/*.md` glob is a known tradeoff
(OpenCode ignores `paths:`, so a repo's lazy rules load on every turn there).
Adding an always-on global rule means adding it to that list too. `@imports`
do **not** resolve there.
Creds resolve per call like `cx`. Matrix: `docs/agents-md.md`.

Three providers: `iu` = `@ai-sdk/openai-compatible` (Chat Completions) on
`{env:IU_OPENAI_BASE}` (`oc` derives it from the Keychain base, `/anthropic` →
`/openai/v1`); `iu-responses` = `@ai-sdk/openai` (the **Responses** wire) on the
same base, carrying every GPT id — they are Responses-only for agent loops
(reasoning items must survive tool calls), so `-m iu-responses/<gpt id>` (ids: `agw routing`), not
`iu/…`; and `anthropic` = the Anthropic route for Claude ids. Names and the
wire split mirror agent-gateway's registry (`server/lib/models.ts`, `wire`), which
generates the same blocks for its workers. **This file's rows are hand-written
and can drift from the registry** — agent-gateway owns ids, limits and verification
(`GET /api/routing`); re-check there before editing a row, and an id the
registry marks unverified is not a recommendation. `iu` declares the rest of the
roster: the default model is the `model` key in `config/opencode/opencode.json`
(a DeepSeek id, **not** served on the Anthropic route), with the other DeepSeek,
GLM, Gemini, Kimi and MiniMax ids declared alongside it;
`iu-responses` holds the GPT ids (`agw routing` lists them) — context windows, prices and `reasoningEffort` variants
come from **modelpick** (`bun run scripts/cap.ts --json --all` on the mini;
`metric_snapshot` for the frontier ids), so re-check there before editing a row.
`agents.title.model` (a cheap `iu-responses` id, set in `config/opencode/opencode.json`; v1's `small_model` still loads) is for title/summary generation. On `iu`,
`reasoningEffort` reaches the model (`--variant max|none`, default `high`) and prompt
caching works (95–98% hits in real episodes). Headless `opencode run` auto-**rejects**
any `ask` permission and that ends the session — workers must set every prompting
permission to `allow`/`deny` (`deny` returns an error and the run continues).
`--pure` hangs; don't use it. Concurrent starts can hit `database is locked` on the
shared `opencode.db` — retry. agent-gateway's dispatch is NOT on this lane: it drives its own
shared server (`com.jkrumm.agent-gateway-opencode`) over HTTP, config on that server process
(`agent-gateway/docs/opencode-v2.md`), with no db-lock retry.

**Parity with Claude Code (2026-10-04).** Same tools, same guard, same agents:
`research-gateway` (remote MCP; `oc` exports `RESEARCH_GATEWAY_AUTH` from the same
helper Claude Code's `headersHelper` runs — Keychain first, `secrets-run` second —
so no token sits in the config) and `chrome-devtools` (local, `--isolated
--headless`; reach for it only for browser work) in `opencode.json`'s `mcp`;
`plugins/protect-branches.js` throws on whatever `hooks/protect-branches.ts` denies;
`agent/{implementer,verifier}.md` are rendered from `agents/` (frontmatter differs,
body is verbatim). Instructions stay the always-on rules plus the four small
stack-agnostic lazy ones — the stack rules (`dockerfile`, `elysia`, `react-*`,
`tanstack-*`, `visx-charts`, `makefile-conventions`, ~40k chars) are **not** listed
because OpenCode ignores `paths:` and would load them on every turn of every repo;
a repo that wants one ships it in its own `.claude/rules/`.

**Waves on OpenCode:** `rd wave|work <repo> --kind opencode` starts it in a herdr
tab; the pane evals `_oc_env` (claude.zsh) first so `IU_*` and the gateway bearer
are in its shell without touching argv. Default model is the `model` key in `config/opencode/opencode.json`,
`RD_WAVE_MODEL` overrides (`provider/id`).

**The shared service needs the credentials too (2026-10-14).** OpenCode v2 attaches `oc` and
`opencode run` to one per-user background service (`opencode serve --service`) that is started
*without* the pane's environment, so every `{env:IU_*}` placeholder resolved empty there and the
first message failed with `Route.model(openai-compatible-chat) requires an endpoint baseURL`.
`_oc_env` now ends by running `scripts/opencode-service-env.sh`, which merges `IU_KEY`,
`IU_OPENAI_BASE`, `IU_ANTHROPIC_BASE` and `RESEARCH_GATEWAY_AUTH` into the service's own
`~/.config/opencode/service.json` (`env` map, mode 0600, local — that directory is not the
symlinked `config/opencode`) and restarts the service when a value changed and no session is
running. Values travel by environment only; `opencode service set env K V` would put the key
on argv. Re-running is a no-op. agent-gateway episodes do not depend on this: they run on
agw's own server (`docs/opencode-v2.md` in agent-gateway).

**One OpenCode build on the machine (2026-10-15).** Homebrew's `opencode` is uninstalled (it
lagged the npm releases and a `brew upgrade` once broke every dispatch). `~/.local/bin/opencode`
is agent-gateway's shim (`make install-cli` there), which execs the pinned npm build under
`~/.local/share/agent-gateway/opencode-bin/current` — the same binary agw's server runs. `oc`,
`rd wave|work|fan --kind opencode`, herdr agent panes and the shared per-user service
(`opencode service restart` after a pin bump) therefore all run one version. A pin bump:
`make install-cli install-opencode-agent` in agent-gateway (`docs/opencode-v2.md` § Version pin).
The first start on a new version shows a one-time release-notes dialog that swallows the pane's
initial prompt — press Enter once, then `rd say` it again.

**agent-gateway is wired in, mini-only.** `config/opencode/mini.json` declares the
`agent-gateway` MCP (`bun run …/agent-gateway/server/mcp.ts`, `timeout` 30 min so a `job_wait`
is not cut off at the default 5 s). It is deliberately *not* in the shared
`opencode.json`: `oc` layers it in with `OPENCODE_CONFIG` (merged over the global
config) only where the repo exists, so the MacBook stays agent-gateway-free. External
skills load natively from `~/.claude/skills`, so `/check`, `/review` and friends
resolve to real tools on the mini.

**Yolo is the default here, deliberately** — `permission: "allow"` (normalized by v2 into an allow-all `permissions` rule), so `oc`
never stops to ask. It is also what makes the lane usable headlessly: `run`
**ends the session** on an `ask` rather than prompting, so a worker with a
leftover `ask` rule is not slow, it is broken. This is the one config file
agent-gateway does *not* share — its dispatch uses two permission agents (`agw-readonly`, `agw-implement`) in its own server config, so
widening this one cannot loosen a dispatch worker.

**Config is two files, and the split is enforced.** `opencode.json` is
`additionalProperties: false`, so `theme` there is a `ConfigInvalidError` — and
`tui-migrate.ts` silently *moves* a `theme`/`keybinds`/`tui` key into a sibling
`tui.json` instead, which is how a hand-written `theme` vanishes rather than
fails. TUI keys go in `tui.json`; themes are `themes/*.json`, globbed with
`symlink: true` (hence the dir symlink) and parsed with strict `JSON.parse` —
**no comments in a theme file**, unlike every other config here.

**One theme, both modes.** `one-zinc.json` holds the Ghostty palette as `defs`
(`d*`/`l*` = dark/light, ANSI-indexed so it stays auditable against
`config/ghostty/themes/one-zinc-*`), each token a `{dark, light}` pair — so
`/theme`'s Dark/Light/Auto toggle switches the whole UI, and opencode persists
that pick, so it **overrides** `tui.json` on later launches. Panels invert
(lighter than the dark bg, darker than the light one): on a near-white surface a
lifted panel is invisible and a white one glares — why this repo never uses
`#ffffff`.

**It follows the system appearance — via the same push Claude Code uses.** The
dual mode only selects when opencode hears the terminal's mode; herdr answers
neither DEC mode 2031 nor OSC 11 for a pane, so on the mini it sat dark forever.
`scripts/claude-appearance.sh` now pushes the `CSI ?997;Nn` report (plus the
OSC 11 answer) to every `claude` **and** `opencode` pane, and `oc` re-themes its
own pane on launch — so a new pane starts in the MacBook's current mode. A
`/theme` Dark/Light/Auto pick still persists into `theme_mode_lock` and wins, so
leave it on **Auto** to follow the host.

**A missing `opencode.json` is a silent failure, not an error** — 2026-09-30: the
symlink was gone, `opencode.jsonc` held only `$schema`, and opencode started
happily with no model, no provider, no rules. `make status` lists all three
opencode links for exactly this; run it when `oc` looks unconfigured.

**v2 schema (2026-10-14).** `opencode.json` and `mini.json` use the v2 keys (`providers` with `package`/`settings`, model `cost.cache.read`, variants as an array, `mcp.servers`, `agents.title`). The `providers` block is generated from agent-gateway's model registry: `bun scripts/sync-opencode-config.ts ~/SourceRoot/dotfiles/config/opencode/opencode.json` in agent-gateway, re-run after a registry change. `iu-anthropic` (Haiku 5.5 EU, native `/anthropic` leg) appends `/v1` to the `IU_ANTHROPIC_BASE` that `_oc_env` exports.
