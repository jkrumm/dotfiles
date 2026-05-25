# Handover: switch Hermes brain to Kimi K2.6 (EU / GDPR)

> **Decision rationale moved.** The Sonnet→Kimi switch decision and EU-safe fallback strategy now live in `modelpick/docs/decisions/hermes-brain.md`. This file retains the operational handover steps.

Paste the block below into a fresh Claude Code session started inside
`~/SourceRoot/hermes-agent`. It is GDPR-aware: Kimi-K2.6 is EU-resident (Azure
Sweden Central) and the fallback is the EU/GDPR-routed Claude alias — **not** Kimi
K2.5 (which can route to US East-US-2) and **not** native Claude (which can also
route US).

---

```
Switch Hermes's default brain to Kimi K2.6 served via the IU unified endpoint,
with an EU-compliant fallback. Hermes touches personal data (calendar, health,
email via argo), so EU data residency is required.

ENDPOINT (OpenAI-compatible, single key, same as the Agent SDK):
- POST https://<iu-unified-endpoint>/openai/v1/chat/completions
- Auth: `Authorization: Bearer <key>`
- Secret: op://common/anthropic (API_KEY; BASE_URL = ".../anthropic"). Derive the
  OpenAI-compat base by replacing the "/anthropic" suffix with "/openai/v1". On dev
  machines the same values are cached in Keychain (`claude-sdk-api-key` /
  `claude-sdk-base-url`). Never log or hardcode the key.

MODELS (verified EU-resident via response headers):
- PRIMARY  "Kimi-K2.6"           -> Azure Sweden Central (x-ms-region: Sweden Central),
                                    EU. Reasoning + function/tool calling, ~256k ctx,
                                    NO image input. Use standard `max_tokens`.
                                    CAVEAT: single backend -> throttle-prone (HTTP 429
                                    "Server at maximum concurrent capacity") + occasional 5xx.
- FALLBACK "claude-sonnet-4-6-eu" -> routes to "LiteLLM ... Claude Gateway GDPR ONLY"
                                    over the OpenAI-compat transport. EU/GDPR. 200k ctx.
                                    (Do NOT use Kimi-K2.5: routes Nebius + Azure US-East-2.
                                     Do NOT use native /anthropic Claude: can route US.)
- Optional small/util model: "claude-haiku-4-5-eu" (same GDPR-ONLY gateway, EU).

WHAT TO DO:
1. Find where Hermes selects its brain model (today: claude-sonnet-4-6 +
   claude-haiku-4-5-20251001 + gemini-2.5-flash via the IU endpoint). Locate the
   model config and the request layer.
2. Make "Kimi-K2.6" the default brain over the OpenAI-compat transport.
3. Resilience: on 429/5xx from Kimi-K2.6, retry with exponential backoff (2-3x),
   then fall back to "claude-sonnet-4-6-eu". Log which model actually served the
   response (never the key). Keep the whole chain EU-only.
4. Verify Kimi's tool/function-calling schema matches what Hermes's seven skill
   domains expect (tool_calls format); adjust the adapter if needed.
5. Behavior shift: Hermes was tuned on Sonnet 4.6. Re-test the skill domains and
   tune prompts where Kimi diverges (formatting, system-prompt adherence).
6. Run /hermes-validate (if present) + a live Slack smoke test before finalizing.
   Commit per hermes-agent conventions.

Confirm a brief plan before editing if the model wiring is non-trivial. Do not
change IU credential handling or expose secrets.
```

---

Re-run `/iu-endpoint` any time to re-check residency (the `EU/US` column) and to see
whether a newer Kimi or a better EU-resident model has appeared.
