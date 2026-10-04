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

Two providers (2026-09-24): `iu` = `@ai-sdk/openai-compatible` on `{env:IU_OPENAI_BASE}`
(`oc` derives it from the Keychain base, `/anthropic` → `/openai/v1`) and
`anthropic` = the Anthropic route for Claude ids. `iu` declares the whole IU roster,
not just the default: `deepseek-v4.1-flash` stays the default (that id is **not**
served on the Anthropic route), with `DeepSeek-V4-Pro`, `glm-5.3-flash`, the
`gpt-5.6/6` line (`gpt-6.1-sol`, `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.6-terra`,
`gpt-6-luna`, `gpt-6-astra`), `gemini-3.{5,8}-flash`, `kimi-k2.7-code` and
`minimax-m3` alongside it — context windows, prices and `reasoningEffort` variants
come from **modelpick** (`bun run scripts/cap.ts --json --all` on the mini;
`metric_snapshot` for the frontier ids), so re-check there before editing a row.
`small_model` is `gpt-6-luna` (cheap) for title/summary generation. On `iu`,
`reasoningEffort` reaches the model (`--variant max|none`, default `high`) and prompt
caching works (95–98% hits in real episodes). Headless `opencode run` auto-**rejects**
any `ask` permission and that ends the session — workers must set every prompting
permission to `allow`/`deny` (`deny` returns an error and the run continues).
`--pure` hangs; don't use it. Concurrent starts can hit `database is locked` on the
shared `opencode.db` — retry. sideclaw's dispatch runs on this lane (its own per-run
config, not this file).

**sideclaw is wired in, mini-only.** `config/opencode/mini.json` declares the
`sideclaw` MCP (`bun run …/sideclaw/server/mcp.ts`, `timeout` 30 min so a `job_wait`
is not cut off at the default 5 s). It is deliberately *not* in the shared
`opencode.json`: `oc` layers it in with `OPENCODE_CONFIG` (merged over the global
config) only where the repo exists, so the MacBook stays sideclaw-free. External
skills load natively from `~/.claude/skills`, so `/check`, `/review` and friends
resolve to real tools on the mini.

**Yolo is the default here, deliberately** — `permission: "allow"`, so `oc`
never stops to ask. It is also what makes the lane usable headlessly: `run`
**ends the session** on an `ask` rather than prompting, so a worker with a
leftover `ask` rule is not slow, it is broken. This is the one config file
sideclaw does *not* share — its dispatch ships its own per-run permissions, so
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
