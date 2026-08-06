---
name: iu-endpoint
description: Validate the IU unified endpoint and discover better models. Probes every transport, health-checks the models configured in OpenCode (opencode.json), reports per-model backend redundancy + live latency, and diffs the live catalog to surface newer/hotter models worth adopting — for OpenCode and for the Hermes Agent (especially Kimi). Use when checking endpoint health, picking a reliable model/host, or deciding whether to upgrade configured models.
---

# IU Unified Endpoint — validate & discover

The IU unified endpoint (`op://common/anthropic`, host derived from `BASE_URL`)
fronts many model backends through several transports. This skill answers three
questions: **what's up right now**, **which alias gives the most reliable host**,
and **are there newer/better models I should switch to** (OpenCode + Hermes).

## Key facts (the mental model)

- **The model alias is the host selector.** Each id maps to one or more backend
  "sinks" (`owned_by` in the catalog). More backends = more redundant = less
  likely to 429/timeout. The validator prints `backends=N` per model.
  - Examples: `Kimi-K2.5` (2: Nebius + Azure) is steadier than `Kimi-K2.6`
    (1: Sweden Central, throttle-prone). `gpt-5` (9) is the most redundant GPT.
    Don't hardcode a Claude example here — the configured aliases move (the old
    `claude-opus-4-7` example outlived the model). Read the live counts.
- **Transports** on the same host: `/anthropic/v1`, `/openai/v1` (rich catalog),
  `/azure/openai/...`, `/gemini/v1beta`, `/replicate/v1`. There is **no**
  `/bedrock` passthrough (404) — Bedrock is only an internal backing.
- **Resilience in OpenCode**: the AI SDK auto-retries `429`s with backoff. For
  hard failover across models, switch alias (or, in Hermes, code a primary→fallback).
- **Probe quirks**: `gpt-5*` reasoning models need `max_completion_tokens` (not
  `max_tokens`); `*-codex` models return empty over chat-completions (responses
  API only) — don't configure them for OpenCode. The validator handles the first.
- Auth: `/openai` + `/replicate` use `Authorization: Bearer`; `/anthropic` uses
  `x-api-key` + `anthropic-version`; `/azure` uses `api-key`; `/gemini` uses
  `x-goog-api-key`. Same single key for all. **Never print the key.**

## How to run

```bash
bash .claude/skills/iu-endpoint/validate.sh          # full: transports + health + catalog diff + Hermes
bash .claude/skills/iu-endpoint/validate.sh --quick  # transports + configured-model health only
```

The script reads the key from Keychain (`claude-sdk-api-key`) and never prints it.
Full run takes ~30–60s (it sends a tiny completion per configured model).

## What to do with the output

1. **Health triage.** Call out any configured model that is not `ok`:
   - `THROTTLED` (429) → transient capacity; prefer a higher-`backends` sibling.
   - `TIMEOUT`/`ERR(503)` → backend down or saturated; note it, suggest alias.
   - High latency on a 1-backend model → flag as slow-prone.
2. **Reliability advice.** When two aliases serve the same model tier, recommend
   the higher-`backends` one as default (e.g. opus-4-6 over opus-4-7 for daily use).
3. **Discover upgrades.** In the `NOTABLE` list, find `[NEW]` ids that are a newer
   version or stronger sibling of a configured `[cfg]` model (e.g. a newer Gemini
   preview, a higher GPT-5.x, a newer Kimi). For each genuinely better one,
   propose the exact `opencode.json` edit (under provider `iu` or `iu-anthropic`),
   with `tool_call`/`reasoning`/`attachment`/`limit`. Verify it actually completes
   first with a one-shot curl (use `max_completion_tokens` for `gpt-5*`). Only
   recommend models that return real text.
4. **Hermes advice.** Compare the models grepped from `~/SourceRoot/hermes-agent`
   against the best available. Be specific about Kimi (the user runs Kimi in
   Hermes): K2.6 is single-backend/throttle-prone, K2.5 is dual-backend/steadier
   — recommend a primary + fallback (e.g. K2.6 primary, K2.5 fallback) and point
   at where in hermes-agent the model is wired. Flag any newer Claude/Gemini brain
   worth switching to. Do not edit hermes-agent from here unless asked.
5. **Report concisely.** A short health summary, a ranked "consider adopting"
   list with backend counts, and any concrete config edits. No key, no raw catalog dump.

## Updating OpenCode config

`config/opencode/opencode.json` (symlinked to `~/.config/opencode/opencode.json`)
holds the curated model set. Editing it needs no `make setup` (it's a symlink).
Keep the set lean and current; this skill is the mechanism for keeping it so.
After any edit here, commit in dotfiles.
