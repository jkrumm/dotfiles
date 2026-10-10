# Codex — the non-Anthropic lane

Claude Code stays the driver; this is the rare second opinion, and the whole
reason it is Codex and not a proxy is the **wire protocol**. OpenAI's reasoning
models only carry reasoning items across tool calls over the **Responses** API,
and Codex is the one harness whose `wire_api` is Responses-only. Chat-completions
drops them silently — the model re-derives its plan every tool round trip.
Routing Claude Code at an OpenAI model through a gateway is strictly worse
(double translation, thinking dropped, `reasoning_effort` ignored) and is not
worth building.

| Command | Model | Effort |
|-|-|-|
| `cx` | per `config/codex/config.toml.tpl` (`model`) | `high` |
| `cxa` | per `config/codex/astra.config.toml` (`model`) — several times the price, opt-in on purpose | `xhigh` |
| `astra '<question>'` | `MODEL` default in `scripts/astra.sh` (the `cxa` model), **no agent loop, no tools** | `xhigh` + `mode="pro"` |

- **`reasoning.mode = "pro"` is why `astra` exists.** The endpoint accepts it;
  codex has no config key for it (only `model_reasoning_effort`), so the
  strongest single shot the estate can fire is a bare Responses call. Take its
  plan, execute it in Claude Code.
- **`astra` has a ceiling, and it is the endpoint's front door, not `curl -m`.**
  `pro` + `xhigh` + a ~400-line `-f` attachment came back as an HTML `500 - The
  request timed out` after ~5 min; the same question at `-e high` returned a full
  answer in ~4 min. There is no knob for it — drop to `-e high`, drop `-m pro`, or
  send less. The script names this case explicitly now rather than printing markup.
- **Effort on this endpoint is `low|medium|high|xhigh|max`.** `none` and
  `minimal` are rejected for these models, and codex's own catalog lists
  `ultra`, which the endpoint rejects — don't set it.
- **`--profile NAME` loads `$CODEX_HOME/NAME.config.toml`**, not the legacy
  `[profiles.NAME]` table, which still parses and does nothing.
- **No prompts, no sandbox** — `approval_policy = "never"` +
  `sandbox_mode = "danger-full-access"`, parity with how `claude` runs here.
  `workspace-write` is not a middle ground: it keeps `.git` read-only and its
  network is off, so commits refuse and `bun outdated` dies on DNS. Per-run
  guardrails: `cx -s workspace-write -a on-request`.
- **The TUI probes the terminal background once, at startup**, and picks its
  colours from that (`terminal_bg` → a syntect theme, set through a `OnceLock`).
  It does not re-probe, and there is no documented `[tui]` theme key — so after
  `make theme` or an automatic light/dark flip, restart codex. herdr and Claude
  Code both switch live; this one doesn't.
- **`~/.codex/AGENTS.md` loads on every run** (verified: a marker planted in a
  scratch `CODEX_HOME` came back without any file read). It points codex at
  `AGENTS.md` and `rules/` for environment facts and explicitly tells it *not*
  to read `skills/`, `agents/` or the output style — importing the framing is
  how a second opinion turns into an echo.
- **That combination is its own trust boundary**, not an inherited one: an
  unsandboxed agent with no human in the loop, holding a tool that fetches
  arbitrary web pages. Text in a fetched page is reachable input to a shell it
  can run unrestricted. The same shape as Claude Code + WebFetch here, but a
  second instance of it — treat an unfamiliar repo or a research-heavy run as
  the case for `cx -s workspace-write -a on-request`.
- **research-gateway is wired into codex too** (`[mcp_servers]`, bearer via
  `RESEARCH_GATEWAY_TOKEN`, `tool_timeout_sec = 7200` because one `job_wait`
  blocks for the whole job). `cx mcp list` reports it. **An empty
  `bearer_token_env_var` is fatal to codex's MCP startup** — it refuses to
  start the client rather than taking a 401 — so `cx` disables the server for
  that launch when the bearer won't resolve. In practice that means a shell
  that hasn't `sz`'d since this landed. The bearer is resolved
  once per launch into an env var, where Claude Code's headers helper re-reads
  it on every reconnect — so a mid-session rotation needs a codex restart.
- **`codex exec` blocks on stdin** when it isn't a TTY and no prompt is piped —
  redirect `</dev/null` in scripts or it hangs with no output at all.
- **`codex --strict-config` is the validator**: it names the exact unknown key
  and line. Run it after any edit to `config/codex/`.
- The key never enters the config file — `cx`/`cxa` resolve it per call
  (Keychain, then the mini's cache) into `IU_API_KEY` by prefix assignment, so
  it stays out of `ps auxww`.
- Casks are never auto-upgraded: `make brew-upgrade` reports codex, `/upgrade-deps`
  applies it.
- **Spend is tracked**: usage-tracker's `codex` collector reads
  `~/.codex/sessions/**/rollout-*.jsonl` and pushes to Argo like every other
  lane. Local only — codex runs on the MacBook are invisible until that
  collector gains an iumac mirror.
