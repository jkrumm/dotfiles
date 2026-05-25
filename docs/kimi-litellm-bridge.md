# Claude Code ↔ Kimi K2.6 via IU Endpoint

> **Decision rationale moved.** Why Kimi-K2.6 is the EU/GDPR worker model, the non-obvious bridge fixes as lessons, and the `claude-sonnet-4-6-eu` fallback now live in `modelpick/docs/decisions/kimi-bridge.md`. This file retains the operational bridge setup (config, keys, deployment).

> **Status: in production.** The bridge now runs as a LaunchAgent installed by dotfiles
> `make setup` (or `make litellm-setup`), not the manual `/tmp` venv this doc first
> documented. Source of truth:
> - `config/litellm/config.yaml` — model_list (`Kimi-K2.6`, `claude-sonnet-4-6-eu`,
>   `gpt-5-mini`), `drop_params: true`, LiteLLM-native `fallbacks` (Kimi → sonnet-eu).
> - `litellm/bin/start-litellm.sh` — wrapper: injects `IU_API_KEY` + derives
>   `IU_OPENAI_BASE_URL` from Keychain, sets `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true`, binds `127.0.0.1:4000`.
> - `litellm/com.litellm.proxy.plist.template` — always-on LaunchAgent (RunAtLoad + KeepAlive).
> - Consumer: **sideclaw** (`server/mcp/session-runner.ts`) routes all `check`/`review`/`research`/`implement` workers here. `make litellm-restart` / `make litellm-logs` to operate.
>
> The POC walkthrough below is retained as the validation record and rationale for the
> three non-obvious fixes — they are baked into the production config above.

Handover prompt for the next agent. Everything below was validated on 2026-05-21.

## Problem

Your IU unified endpoint exposes two isolated transports:

| Route | Format | Models | Client |
|-------|--------|--------|--------|
| `…/anthropic` | Anthropic Messages API | Claude only | `claude -p` |
| `…/openai` | OpenAI Chat Completions | All incl. Kimi | OpenCode, OpenAI SDK |

Tested & confirmed: `claude -p` with `ANTHROPIC_BASE_URL=…/anthropic` + `kimi-k2.6` → **404**. The IU Anthropic route does not shim Kimi.

## Validated Working Options

| Option | Command | Status |
|--------|---------|--------|
| Claude via IU (offload quota) | `claude -p --bare` + `ANTHROPIC_AUTH_TOKEN` + base URL | ✅ Works (Haiku/Sonnet/Opus) |
| Kimi via OpenCode | `ocr -m iu/Kimi-K2.6 "prompt"` | ✅ Works today |
| **Kimi via `claude -p`** | **LiteLLM Proxy bridge** | ✅ **This POC — works end-to-end** |

---

## POC: LiteLLM Proxy Bridge

This is the only documented path to get `claude -p` talking to Kimi through your IU OpenAI route.

### Architecture

```
claude -p → Anthropic /v1/messages → LiteLLM Proxy (:4000)
                                            ↓ (translates)
                          OpenAI /chat/completions → IU /openai/v1 → Kimi K2.6
```

### Setup

#### 1. Install

```bash
# Using uv (preferred, already installed on this machine)
uv venv /tmp/litellm-poc
uv pip install --python /tmp/litellm-poc/bin/python 'litellm[proxy]'
```

#### 2. Config file (`~/litellm-config.yaml`)

```yaml
model_list:
  - model_name: Kimi-K2.6
    litellm_params:
      model: openai/Kimi-K2.6
      api_base: https://<iu-unified-endpoint>/openai/v1
      api_key: os.environ/IU_API_KEY

litellm_settings:
  drop_params: true
```

**Critical: three fixes discovered during POC (not in original spec):**

1. **Model name case:** `Kimi-K2.6` (capital K). The IU `/models` endpoint lists it as `Kimi-K2.6`. Lowercase `kimi-k2.6` → `No suitable backend server found` from the IU gateway.
2. **Env var `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true`:**
   LiteLLM's Anthropic `/v1/messages` passthrough **defaults to the OpenAI Responses API** (`/v1/responses`), not Chat Completions. The IU gateway does not serve Kimi through the Responses API backend. This env var forces LiteLLM to route to `chat/completions` instead.
3. **Config `drop_params: true`:** `claude -p` sends `reasoning_effort`, which Kimi rejects. LiteLLM drops it automatically with this flag.

#### 3. Start proxy

```bash
export IU_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w)
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true
source /tmp/litellm-poc/bin/activate
litellm --config ~/litellm-config.yaml
```

#### 4. In another terminal — test

```bash
env -u ANTHROPIC_API_KEY \
ANTHROPIC_AUTH_TOKEN=sk-litellm-master-key \
ANTHROPIC_BASE_URL=http://localhost:4000 \
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  claude --bare -p "Say exactly: pong" \
    --model Kimi-K2.6 \
    --allowedTools "Read,Bash,Edit" \
    --output-format json
```

**`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`** — required or IU gateway may 400 on Anthropic beta headers.

**`ANTHROPIC_AUTH_TOKEN=sk-litellm-master-key`** — LiteLLM uses this static master key for proxy auth. No relation to your actual IU API key.

---

## Test Results

### Pong test

```json
{"type":"result","subtype":"success","is_error":false,"result":"pong"}
```

- Model: `Kimi-K2.6`, cost: ~$0.005, input tokens: 883, output: 26

### Multi-turn tool test

```bash
env -u ANTHROPIC_API_KEY \
ANTHROPIC_AUTH_TOKEN=sk-litellm-master-key \
ANTHROPIC_BASE_URL=http://localhost:4000 \
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  claude --bare -p "Find the 3 most recently modified .zsh files in the current directory tree, read the first 20 lines of the most recent one, and report its filename plus a one-line summary of what it does." \
    --model Kimi-K2.6 \
    --allowedTools "Read,Glob,Grep,Bash" \
    --output-format json
```

- Result: success, `num_turns: 5`
- Correctly executed `Bash` → `Glob`/`Grep` → `Read` → final answer
- JSON output clean, no 400s on tool calls, no translation errors in LiteLLM logs
- Cost: ~$0.047, input tokens: 5398, output: 791, cache read: 674

---

## Caveats to Watch

| Issue | Detail |
|-------|--------|
| **Prompt caching** | Lost in translation. The test showed `cache_read_input_tokens: 674` in the Claude output, but this is likely Claude Code's local accounting, not actual IU cache hits. |
| **Thinking blocks** | Not stress-tested. Pong and file-analysis prompts don't trigger reasoning. Test with an explicit reasoning prompt to see if Kimi's thinking blocks survive Anthropic-format translation. |
| **Tool schema translation** | Works for basic Read/Bash/Grep/Glob. Edge cases on complex multi-turn loops (e.g., `Edit` with patches) not validated. |
| **`--bare` flag** | This POC always uses `--bare`. Interactive `claude` (TUI mode) via the bridge is untested. |
| **Latency** | ~4.2s TTFT for simple prompts, ~18.5s for the 5-turn tool test. Adds LiteLLM hop overhead on top of IU routing. |

## What Does NOT Work

| Approach | Why |
|----------|-----|
| Direct `claude -p` → IU OpenAI route | Format mismatch (Anthropic Messages vs OpenAI Chat Completions). |
| `kimi-k2.6` lowercase | IU gateway returns `No suitable backend server found`. Must use `Kimi-K2.6`. |
| Without `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true` | LiteLLM routes to OpenAI Responses API (`/v1/responses`), which IU does not support for Kimi. |
| Without `drop_params: true` | `reasoning_effort` from `claude -p` causes `UnsupportedParamsError`. |
| Existing open-source wrappers (`claude-wrapper`, `claude-code-openai-wrapper`) | All locked to Anthropic backends. |
| Direct Moonshot key (`api.moonshot.ai/anthropic`) | Works, but bypasses IU entirely and requires separate billing. |

## Key Files

| Path | Purpose |
|------|---------|
| `~/litellm-config.yaml` | LiteLLM Proxy config (model list + `drop_params`) |
| `/tmp/litellm-poc/` | uv venv with `litellm[proxy]` installed |
| `/tmp/litellm.log` | Proxy logs |
| `/tmp/litellm.pid` | Proxy PID |

## POC cleanup (done)

The original `/tmp/litellm-poc` venv + `~/litellm-config.yaml` POC has been removed and
superseded by the dotfiles LaunchAgent (see the production banner at the top). litellm is
now installed via `uv tool install litellm[proxy]` at `~/.local/share/uv/tools/litellm/`.

## API Key Resolution

The `IU_API_KEY` environment variable for the proxy is sourced from macOS Keychain:

```bash
security find-generic-password -s claude-sdk-api-key -w
```

This is the same credential used by the OpenCode wrapper (`config/zsh/opencode.zsh`). No new 1Password field or Keychain entry is needed.
