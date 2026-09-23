# codex-config-managed-by-dotfiles
#
# Codex CLI — the OpenAI lane, on the IU unified endpoint.
#
# RENDERED (not symlinked) into ~/.codex/config.toml by `make setup`: the
# endpoint host is an internal IU URL and never enters git (rules/security.md),
# so `@@IU_OPENAI_V1@@` is substituted from the Keychain `claude-sdk-base-url`
# entry at setup time. Edit THIS file, then re-run `make setup`.
#
# Why Codex exists here at all, when Claude Code is the daily driver: OpenAI's
# reasoning models only carry reasoning items across tool calls over the
# *Responses* API, and Codex is the one harness whose wire protocol is
# Responses-only. Over chat-completions the model re-derives its plan on every
# tool round trip. A Claude-Code-through-an-OpenAI-proxy setup is strictly
# worse than this and is not worth building.
#
# Launch with `cx` / `cxa` (config/zsh/codex.zsh) — they inject the API key.

model = "gpt-5.6-sol"
model_provider = "iu"
model_reasoning_effort = "high"
model_reasoning_summary = "auto"
model_verbosity = "medium"

# Parity with how Claude Code runs here. Why not `workspace-write`, and the
# per-run escape hatch: dotfiles/AGENTS.md §Codex.
approval_policy = "never"
sandbox_mode = "danger-full-access"

# The default is the cheaper 5.6 flagship on purpose. GPT-6 Astra costs several
# times more per token, so it is opt-in via `cxa` (= `--profile astra`).
#
# `--profile NAME` loads $CODEX_HOME/NAME.config.toml — since codex 0.134 it is
# NOT the legacy `[profiles.NAME]` table, which still parses and does nothing.
[model_providers.iu]
name = "IU Unified Endpoint"
base_url = "@@IU_OPENAI_V1@@"
env_key = "IU_API_KEY"
wire_api = "responses"

# research-first applies in this lane too, so codex gets the same gateway Claude
# Code uses. Tailnet-only; the bearer never enters this file — `cx`/`cxa` resolve
# it into RESEARCH_GATEWAY_TOKEN the way they resolve the endpoint key.
#
# `tool_timeout_sec` is the load-bearing line: one `job_wait` blocks for a whole
# research job, which runs minutes, and the default would abort it mid-flight.
[mcp_servers.research-gateway]
url = "https://research.mini.jkrumm.com/mcp"
bearer_token_env_var = "RESEARCH_GATEWAY_TOKEN"
startup_timeout_sec = 30
tool_timeout_sec = 7200
