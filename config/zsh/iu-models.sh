# IU gateway model metadata, shared between config/zsh/claude.zsh's `ca()`
# (zsh) and scripts/agent-dispatch.sh's `run_local_claude_p()` (bash 3.2) — the
# one place both launchers get a gateway model's real context window and GLM
# thinking budget from. Case-statement functions, not an associative array:
# bash 3.2 has no assoc arrays, so this is the shape that parses under both
# interpreters. Update here only; the callers just source this file.
#
# _ca_ctx <model>       real context window, for CLAUDE_CODE_MAX_CONTEXT_TOKENS
#                       / CLAUDE_CODE_AUTO_COMPACT_WINDOW
# _ca_thinking <model>  MAX_THINKING_TOKENS budget, empty = don't set the var
#
# Claude Code only trusts api.anthropic.com to self-report a context window
# (isFirstPartyAnthropicBaseUrl, claude-code#46416) — over any other base URL
# it assumes 200k and auto-compacts there, throttling a model that accepts far
# more. CLAUDE_CODE_MAX_CONTEXT_TOKENS is the fix for gateway ids, and it is a
# CLIENT-SIDE compaction budget, not a capability claim: set it above the
# model's real window and a clean auto-compact becomes a hard mid-session
# rejection. Anything absent falls back to 200k, deliberately conservative —
# modelpick's `bun run pick` is what measures these; re-run it before adding a
# row.
#   glm-5.3-flash  1000000  measured — still accepted at a 1.1M probe ceiling
#   DeepSeek-V4-Flash / DeepSeek-V4-Pro / minimax-m3  1000000  measured
#                  2026-09-20 — each accepted at the 1.1M probe ceiling
#   kimi-k2.7-code  262144  measured 2026-09-20 — exact, named by the gateway
_CA_CTX_FALLBACK=200000
# Matched case-insensitively: the gateway accepts `deepseek-v4-pro` as readily
# as `DeepSeek-V4-Pro`, and a lookup that only knew the catalog spelling sent the
# lowercase form to the 200k fallback — five compactions in one hour, 2026-09-17.
# `tr`, not ${1:l} / ${1,,}: this file parses under zsh and bash 3.2 alike.
_ca_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

_ca_ctx() {
  case "$(_ca_lower "$1")" in
    glm-5.3-flash|deepseek-v4-flash|deepseek-v4-pro|minimax-m3) echo 1000000 ;;
    kimi-k2.7-code) echo 262144 ;;
    *) echo "$_CA_CTX_FALLBACK" ;;
  esac
}

# MAX_THINKING_TOKENS maps to Anthropic's thinking.budget_tokens — the ONLY
# reasoning-effort control that works on the gateway's Anthropic leg. `--effort`
# / `reasoning_effort` / `thinking:{type:disabled}` are all ignored by the
# Requesty hop; unset lets GLM default to `max`, its worst setting. 8192 is the
# agentic/implementation-lane value (modelpick docs/decisions/model-configs.md)
# — classify-type lanes (sideclaw check/overview/review_router) use 2048, but
# those don't run through a Claude Code launcher, so that value isn't here.
# The other rows carry 8192 because that is the budget their 2026-09-20 ccbench
# rows were measured under — the reproduced config, not a tuned one.
_ca_thinking() {
  case "$(_ca_lower "$1")" in
    glm-5.3-flash|deepseek-v4-flash|deepseek-v4-pro|minimax-m3|kimi-k2.7-code) echo 8192 ;;
    *) echo "" ;;
  esac
}
