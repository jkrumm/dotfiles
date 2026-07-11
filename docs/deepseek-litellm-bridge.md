# Claude Code ↔ DeepSeek-V4 via IU Endpoint

> **Decision rationale lives in modelpick.** Why DeepSeek-V4-Pro is the coding/worker
> model and DeepSeek-V4-Flash the fast/cheap one (cost, coding index, context), and the
> `claude-sonnet-4-6-eu` / `claude-haiku-4-5-eu` failovers, live in `modelpick`
> (`src/db/seed.ts` `MY_STACK`, decided 2026-06-02). This file is the operational bridge
> setup (config, keys, deployment) and the validation record for the non-obvious fixes.

> **Status: in production.** The bridge runs as a LaunchAgent installed by dotfiles
> `make setup` (or `make litellm-setup`). Source of truth:
> - `config/litellm/config.yaml` — model_list (`DeepSeek-V4-Pro`, `DeepSeek-V4-Flash`,
>   `claude-sonnet-4-6-eu`, `claude-haiku-4-5-eu`, plus a back-compat `Kimi-K2.6` alias),
>   `drop_params: true`, LiteLLM-native `fallbacks` (DeepSeek → Claude-eu).
> - `litellm/bin/start-litellm.sh` — wrapper: injects `IU_API_KEY` + derives
>   `IU_OPENAI_BASE_URL` from Keychain, sets `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true`, binds `127.0.0.1:4000`.
> - `litellm/com.litellm.proxy.plist.template` — always-on LaunchAgent (RunAtLoad + KeepAlive).
> - **Consumers:** **sideclaw** (`server/mcp/session-runner.ts`, `DEFAULT_MODEL = "DeepSeek-V4-Pro"`)
>   routes all `check`/`review` workers here. `claude_bridge` (dotfiles
>   `config/zsh/claude.zsh`) also defaults to `DeepSeek-V4-Pro` for headless `-p` offload.
>   **The interactive `ca` launcher no longer uses the bridge** — as of 2026-07-06 it goes
>   direct to the IU native Anthropic endpoint (real Claude models with prompt caching, no
>   translation tax). See the `ca()` comment block in `config/zsh/claude.zsh`.

> **Worker-model history.** The bridge mechanism below was validated on 2026-05-21 with
> **Kimi-K2.6** (Azure Sweden); the worker model was switched to **DeepSeek-V4-Pro** on
> 2026-06-02 (~4× cheaper output, ties Kimi on coding index, 1M context). The bridge
> translation is model-agnostic — only the `model_name` strings changed. The original Kimi
> POC is preserved below as the validation record for the three non-obvious fixes, which are
> baked into the production config and apply to any IU OpenAI-transport model.

> **Residency.** `config/litellm/config.yaml` records the DeepSeek tiers as **Azure Spain
> (EU/GDPR)**. modelpick's catalog still lists their residency as *unverified* — reconcile
> there. The failover aliases (`claude-sonnet-4-6-eu` / `claude-haiku-4-5-eu`) are
> EU-confirmed regardless.

## Problem

The IU unified endpoint exposes two isolated transports:

| Route | Format | Models | Client |
|-|-|-|-|
| `…/anthropic` | Anthropic Messages API | Claude only | `claude -p` |
| `…/openai` | OpenAI Chat Completions | All incl. DeepSeek, Kimi | OpenCode, OpenAI SDK |

`claude -p` speaks the Anthropic Messages API, but the worker models (DeepSeek-V4-Pro/Flash)
are only on the OpenAI transport. A direct `claude -p` against `…/anthropic` with a
non-Claude model → **404** (the IU Anthropic route doesn't shim non-Claude models). The
LiteLLM proxy bridges the gap.

## LiteLLM Proxy Bridge

The only path that gets `claude -p` talking to an OpenAI-transport model through IU.

### Architecture

```
claude -p → Anthropic /v1/messages → LiteLLM Proxy (:4000)
                                            ↓ (translates)
                          OpenAI /chat/completions → IU /openai/v1 → DeepSeek-V4-Pro
```

### The three non-obvious fixes (baked into the production config)

1. **Model name case is exact.** The IU `/models` endpoint lists models case-sensitively
   (`DeepSeek-V4-Pro`, not `deepseek-v4-pro`; this was first hit as the `Kimi-K2.6` vs
   `kimi-k2.6` gotcha). A wrong-case name → `No suitable backend server found` from the IU
   gateway.
2. **`LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true`.** LiteLLM's Anthropic
   `/v1/messages` passthrough **defaults to the OpenAI Responses API** (`/v1/responses`),
   which the IU gateway does not serve for these models. This env var forces routing to
   `chat/completions` instead. Set in `start-litellm.sh`.
3. **`drop_params: true`.** `claude -p` sends `reasoning_effort` and similar params some
   models reject (→ `UnsupportedParamsError`). LiteLLM drops them automatically with this flag.

Plus, at call time: **`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`** — required or the IU
gateway may 400 on Anthropic beta headers. And **`ANTHROPIC_AUTH_TOKEN`** must be non-empty
(the bridge runs unauthenticated on localhost, but `claude` requires a token) — send the
static `sk-litellm-master-key` the proxy ignores.

### Smoke test

```bash
env -u ANTHROPIC_API_KEY \
ANTHROPIC_AUTH_TOKEN=sk-litellm-master-key \
ANTHROPIC_BASE_URL=http://localhost:4000 \
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  claude --bare -p "Say exactly: pong" \
    --model DeepSeek-V4-Pro \
    --allowedTools "Read,Bash" \
    --output-format json
```

Or via the zsh helper: `claude_bridge -p "Say exactly: pong"` (defaults `--model
DeepSeek-V4-Pro`; pass `--model DeepSeek-V4-Flash` for the fast tier).

## Caveats to watch

| Issue | Detail |
|-|-|
| **Prompt caching** | Lost in translation — bridge calls have no IU-side prompt caching. Keep worker system prompts small (`--setting-sources project` by default in sideclaw). |
| **`structured_output` / `--json-schema`** | Models over the bridge ignore `--json-schema`; `structured_output` comes back empty. sideclaw validates extracted JSON with a Zod `zodValidator` instead. |
| **Empty `result` envelope** | Bridge workers routinely end a session on a tool call, leaving the `result` field empty on `subtype: "success"`. sideclaw's `session-runner` recovers JSON from the last assistant text; `implement` reconciles against `git status`. |
| **Single-backend throttling** | The worker tier is single-backend and intermittently 5xx/429s under burst; LiteLLM `fallbacks` transparently retry on the Claude-eu alias, and sideclaw caps angle concurrency. |
| **No `WebSearch`/`WebFetch`** | They make internal Anthropic-model calls the bridge can't serve, so bridge workers can't browse the web. (Web research now runs on the standalone `research-gateway` service, not over this bridge.) |
| **Subagent model tiers** | `--model`/`ANTHROPIC_MODEL` only sets the *main* model. Subagents (Explore, `@implementer`) and background tasks (title-gen, compaction) resolve by **tier** (opus/sonnet/haiku/fable); a custom main-model name can't be classified, so each tier falls back to its hardcoded Anthropic default (`claude-opus-4-8`, …) → `400 Invalid model name` the moment a subagent spawns. Fix: `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` pin every tier to a bridge-known name (set in `ca`/`claude_bridge` in `config/zsh/claude.zsh`). The main chat works without this, which is why the pong smoke test misses it — validate a subagent spawn, not just a turn. |
| **Context window (200k → 1M)** | Claude Code hardcodes a **200k** window for *any* model over a custom `ANTHROPIC_BASE_URL` — the `isFirstPartyAnthropicBaseUrl()` gate ([claude-code#46416](https://github.com/anthropics/claude-code/issues/46416)) only trusts `api.anthropic.com` to self-report a window, so it never reads one from the bridge (neither `/v1/models` transport carries a context field anyway). That throttled DeepSeek's real **1M** and auto-compacted at ~200k. Fix: **`CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000`** (set in `ca`) — proven via `-p --output-format json`: `modelUsage.DeepSeek-V4-Pro.contextWindow` goes `200000 → 1000000`. It's global (all tiers) but **keeps the DeepSeek model name**, so usage-tracker dedup is untouched — unlike the `[1m]` name-trick, which forces a `claude-*` id → classified Max-quota → double-count + misbill. Auto-compaction stays on; since the bridge has no prompt caching, you only pay for the bigger window when you actually fill it (a full uncached re-send each turn) — lower the number to bound cost. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` does **not** work here (capped at the model's *actual* window, which is the 200k default). |

## What does NOT work

| Approach | Why |
|-|-|
| Direct `claude -p` → IU OpenAI route | Format mismatch (Anthropic Messages vs OpenAI Chat Completions). |
| Wrong-case model name (e.g. `deepseek-v4-pro`) | IU gateway returns `No suitable backend server found`. Use the exact `/models` casing. |
| Without `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true` | LiteLLM routes to the OpenAI Responses API (`/v1/responses`), which IU does not support for these models. |
| Without `drop_params: true` | `reasoning_effort` from `claude -p` causes `UnsupportedParamsError`. |
| Existing OSS wrappers (`claude-wrapper`, `claude-code-openai-wrapper`) | All locked to Anthropic backends. |

## API key resolution

The `IU_API_KEY` for the proxy is sourced from the macOS Keychain (same credential as the
OpenCode wrapper in `config/zsh/opencode.zsh`; no new 1Password field needed):

```bash
security find-generic-password -s claude-sdk-api-key -w
```

---

## Appendix — original POC validation record (Kimi-K2.6, 2026-05-21)

The bridge was first validated end-to-end with Kimi-K2.6. Preserved here because it
established the three fixes above; the numbers are Kimi's, not DeepSeek's.

**Pong test:** `{"type":"result","subtype":"success","is_error":false,"result":"pong"}` —
model `Kimi-K2.6`, ~$0.005, input 883 / output 26 tokens.

**Multi-turn tool test:** a "find 3 most recently modified .zsh files, read + summarize the
newest" prompt completed `success`, `num_turns: 5`, correct `Bash → Glob/Grep → Read → answer`
sequence, clean JSON, no 400s on tool calls. ~$0.047, input 5398 / output 791 tokens.

**Latency observed:** ~4.2s TTFT simple, ~18.5s for the 5-turn test (LiteLLM hop on top of IU
routing). The original `/tmp/litellm-poc` venv + `~/litellm-config.yaml` were removed once the
dotfiles LaunchAgent took over; litellm is installed via `uv tool install 'litellm[proxy]'`.
