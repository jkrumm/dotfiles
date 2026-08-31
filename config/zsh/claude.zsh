# Claude Code launcher
#
# Usage: c  [claude-args...]   — Max subscription (default)
#        cs [claude-args...]   — Max subscription, defaults to Sonnet model
#        cf [claude-args...]   — Max subscription, defaults to Fable model
#        ca [model] [claude-args...]
#                              — IU unified endpoint (NOT the LiteLLM bridge).
#                                No model  → claude-sonnet-5[1m], as before.
#                                claude-*  → that Claude model, [1m] auto-appended.
#                                anything else → treated as a gateway model id
#                                (DeepSeek-V4-Flash, glm-5.3-flash, …); see _ca_ctx.
#
# Skills load from ~/.claude/skills/ (global) and <repo>/.claude/skills/ (per-repo)
# automatically. Additionally, if the current git repo ships local plugins under
# plugins/*/.claude-plugin (e.g. basalt-ui), they're loaded live via --plugin-dir so
# skill edits apply without publishing — a no-op in repos without them. Workspace
# detection lives in skills themselves (e.g. SourceRoot/IuRoot 1Password routing).

# Pin Claude Code's own theme to `auto` — its enum is
# ["auto","dark","light","light-daltonized","dark-daltonized","light-ansi",
# "dark-ansi"] and auto is labelled "(match terminal)": it asks the terminal
# for its colour scheme and re-themes live when that changes.
#
# THIS REPLACED A `defaults read -g AppleInterfaceStyle` GUESS, and the guess
# was reading the wrong machine. An agent runs on the headless mini and is
# looked at from the MacBook, so the mini's appearance decided how the
# MacBook's terminal rendered — light-mode MacBook, dark-themed Claude Code,
# near-white text on a near-white background. The terminal is the only party
# that knows, and `auto` is the only value that asks it.
#
# There is no `auto-ansi`, so this gives up the ANSI-only palette the old
# `*-ansi` values pinned. Correct polarity beats palette purity: the failure it
# replaces was unreadable text, not a slightly-off hue.
#
# It CONVERGES rather than writes. ~/.claude.json is also written by every
# running Claude Code session, so the old unconditional rewrite-per-launch
# could clobber a concurrent update; and the temp file is a sibling, because
# mv across filesystems is not atomic.
_claude_theme_auto() {
  [[ -f ~/.claude.json ]] || return 0
  [[ "$(jq -r '.theme // ""' ~/.claude.json 2>/dev/null)" == "auto" ]] && return 0
  jq '.theme = "auto"' ~/.claude.json > ~/.claude.json.tmp \
    && mv ~/.claude.json.tmp ~/.claude.json
}

c() {
  _claude_theme_auto

  # Local Claude Code plugin dev: load any plugins this repo ships under
  # plugins/*/.claude-plugin live from disk, so SKILL.md edits apply without
  # publishing. No-op outside such repos. (/N) = dirs-only + nullglob.
  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "$@"
}

# Same as `c` (Max subscription, same config dir) but starts on Fable instead
# of whatever /model last left the session on.
cf() {
  _claude_theme_auto

  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model fable "${args[@]}")

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
}

# Same as `c` (Max subscription, same config dir) but starts on Sonnet instead
# of whatever /model last left the session on — for when Opus is the default
# and this particular chat doesn't need it. `cs --model opus` overrides back.
cs() {
  _claude_theme_auto

  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model sonnet "${args[@]}")

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
}

# Same launcher as `c` — same skills/agents/hooks/CLAUDE.md, since it's the same
# ~/.claude config dir — but routed through the IU unified endpoint's native
# Anthropic transport (real Claude models, API-billed per-token) instead of the
# Max subscription. Default model: claude-sonnet-5 (latest Sonnet tier). To use a
# different model permanently, change the --model default below; a one-off
# `ca --model claude-opus-4-8` also works for any model the IU Anthropic endpoint
# serves (run /iu-endpoint for the live catalog).
#
# Full Anthropic protocol fidelity — no LiteLLM translation tax. Prompt caching
# works (first turn builds the cache, subsequent turns read at ~10% cost), tool
# use is native, WebSearch/WebFetch work, and tier differentiation is real.
#
# Default effort: high (matches --model, overridable with `ca --effort xhigh`).
# Effort is a plain request parameter (`claude --help` lists --effort), not
# gated by account/auth — it works the same over this custom base URL as it
# does on the Max subscription.
#
# Subagents/background tasks resolve by TIER (opus/sonnet/haiku/fable). A custom
# main-model name can't be classified into a tier, so each tier falls back to its
# hardcoded Anthropic default (claude-opus-4-8, …) which the IU endpoint may not
# serve. ANTHROPIC_DEFAULT_*_MODEL below pins every tier to the IU catalog:
# sonnet-5 for the workhorse tiers, haiku-4-5 for background (title-gen,
# compaction, fast reads). No opus/fable override — the sonnet fallback is cheap
# enough and those tiers are rarely invoked.
#
# Context window: over any non-api.anthropic.com ANTHROPIC_BASE_URL, Claude Code
# can't verify 1M support and budgets Sonnet 5 at 200k, even though it natively
# has 1M (docs: code.claude.com/docs/en/model-config#sonnet-5-context-window).
# CLAUDE_CODE_MAX_CONTEXT_TOKENS is not a real Claude Code env var — don't
# reintroduce it. The documented fix is the `[1m]` suffix (stripped before the
# model ID reaches the provider): --model claude-sonnet-5[1m], plus the same
# suffix on every ANTHROPIC_DEFAULT_*_MODEL tier that resolves to Sonnet 5.
#
# claude v2.x rejects ANTHROPIC_API_KEY in this flow ("Not logged in") — must
# be ANTHROPIC_AUTH_TOKEN. Env auth takes precedence over the cached claude.ai
# OAuth login for this process only — `c` and `ca` don't fight each other.
#
# IU creds are read from the macOS Keychain (same as claude_iu / opencode).
# The LiteLLM bridge is NOT used here — it's only for sideclaw workers
# (claude_bridge / mcp__sideclaw__*). ToolSearch stays on (ENABLE_TOOL_SEARCH)
# because the IU endpoint isn't api.anthropic.com and ToolSearch is off by
# default on non-first-party hosts.
#
# After editing this file: `source ~/.zshrc` (or open a new terminal). An
# already-open shell keeps running whatever `ca` it loaded at startup.
# Real context window per gateway model id, for CLAUDE_CODE_MAX_CONTEXT_TOKENS.
#
# Claude Code only trusts api.anthropic.com to self-report a window
# (isFirstPartyAnthropicBaseUrl, claude-code#46416), so over any custom base URL
# it assumes 200k and auto-compacts there — throttling a model that accepts far
# more. CLAUDE_CODE_MAX_CONTEXT_TOKENS is the fix for *gateway* ids; the `[1m]`
# name-trick is NOT, because it forces a claude-* id, which usage-tracker then
# classifies as Max quota → double-count + misbill. `[1m]` stays correct for the
# real Claude models, which is why the two branches of `ca` differ.
#
# This is a client-side budget, not a server limit: set it HIGHER than the real
# window and you trade a clean auto-compact for a hard API rejection mid-session.
# So 1M is not a safe blanket default — kimi-k2.7-code hard-caps at 262144.
#
# Anything absent falls back to 200k — NOT measured, deliberately conservative.
# `modelpick`'s `bun run pick` is what measures these; re-run it when adding a row.
#   glm-5.3-flash     1000000  measured — still accepted at a 1.1M probe ceiling
#   DeepSeek-V4-Flash 1000000  measured — still accepted at a 1.1M probe ceiling
#   DeepSeek-V4-Pro   1000000  documented (IU portal catalog), not yet probed
#   kimi-k2.7-code     262144  measured — the gateway names the number in its 400
#
# Keys are quoted and the notes live up here: an unquoted `[foo-bar]` inside
# `=( … )` is a glob pattern to zsh and fails to match at source time.
typeset -gA _CA_CTX=(
  'glm-5.3-flash'     1000000
  'DeepSeek-V4-Pro'   1000000
  'DeepSeek-V4-Flash' 1000000
  'kimi-k2.7-code'     262144
)
_ca_ctx() { print -r -- "${_CA_CTX[$1]:-200000}" }

# `cap` — pick a model, then launch `ca` against it.
#
# The comparison and the picklist live in modelpick (`bun run cap`), which reads
# only its local SQLite file: measured ccbench results, the ArtificialAnalysis
# intelligence index, solved per-token rates and the route residency survey. No
# API calls, no secrets, no network — so this is safe to run anywhere.
#
# The contract that makes this a one-liner: modelpick's picker writes the table
# and the prompt to stderr and the chosen model id, alone, to stdout. Anything
# that breaks that split breaks this function.
#
#   cap                 pick interactively, then exec `ca <model>`
#   cap --list          print the comparison and stop
#   cap -- <ca args>    pick, then pass the rest through to `ca`
cap() {
  local mp="$HOME/SourceRoot/modelpick"
  [[ -d "$mp" ]] || { print -ru2 "cap: modelpick not found at $mp"; return 1 }

  if [[ "$1" == "--list" || "$1" == "-l" ]]; then
    (cd "$mp" && bun run scripts/cap.ts "${@:2}" >/dev/null)
    return
  fi

  # Passthrough args for `ca` come after a bare `--`.
  local -a rest=()
  if [[ "$1" == "--" ]]; then rest=("${@:2}"); else rest=("$@"); fi

  local model
  model=$(cd "$mp" && bun run scripts/cap.ts) || return
  [[ -n "$model" ]] || { print -ru2 "cap: no model chosen"; return 1 }

  print -ru2 "cap: launching ca $model"
  ca "$model" "${rest[@]}"
}

ca() {
  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
  if [[ -z "$key" || -z "$base" ]]; then
    print -ru2 "ca: IU credentials missing in Keychain — run 'make setup' in dotfiles"
    return 1
  fi

  _claude_theme_auto

  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  # Optional leading model id: `ca DeepSeek-V4-Flash -p "…"`. Only consumed when
  # it doesn't look like a flag, so every existing `ca --resume`-style call is
  # untouched.
  local model=""
  if [[ -n "$1" && "$1" != -* ]]; then
    model="$1"; shift
  fi

  local -a args=("$@")
  [[ " $* " == *" --effort "* ]] || args=(--effort high "${args[@]}")

  if [[ -z "$model" || "$model" == claude-* ]]; then
    # Claude tier: `[1m]` is the documented window fix, stripped before the id
    # reaches the provider, and applied to every ANTHROPIC_DEFAULT_* tier too or
    # a subagent silently drops back to a 200k budget. Not for Haiku 4.5 though —
    # that really is a 200k model, and budgeting it at 1M trades a clean
    # auto-compact for a hard API rejection.
    local m="${model:-claude-sonnet-5}"
    if [[ "$m" != *"[1m]" && "$m" != *haiku* ]]; then
      m="${m}[1m]"
    fi
    [[ " $* " == *" --model "* ]] || args=(--model "$m" "${args[@]}")

    env -u ANTHROPIC_API_KEY \
      ANTHROPIC_AUTH_TOKEN="$key" \
      ANTHROPIC_BASE_URL="$base" \
      ANTHROPIC_DEFAULT_OPUS_MODEL="$m" \
      ANTHROPIC_DEFAULT_SONNET_MODEL="$m" \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5 \
      ANTHROPIC_DEFAULT_FABLE_MODEL="$m" \
      ENABLE_TOOL_SEARCH=true \
      claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
    return
  fi

  # Gateway tier (DeepSeek / GLM / Kimi / MiniMax / …). Every ANTHROPIC_DEFAULT_*
  # tier is pinned to the SAME id on purpose: leave one on a claude-* default and
  # a spawned subagent asks the gateway for a model it doesn't serve — that is
  # the classic "main session works, subagents 400" failure (claude-code#5680).
  #
  # Three settings this tier needs and the Claude tier does not:
  #  - AUTO_COMPACT_WINDOW matched to the model's real window. Compacting early
  #    rewrites history, which busts the prefix cache and re-pays full fresh-input
  #    price — the dominant cost term in an agent loop, not a nicety.
  #  - API_TIMEOUT_MS raised: these models legitimately take minutes per turn
  #    (glm-5.3-flash was measured at 280–737s on one benchmark task), and the
  #    default timeout turns slow-but-correct into a spurious failure.
  #  - ENABLE_TOOL_SEARCH deliberately NOT set. Claude Code disables deferred tool
  #    search on a non-first-party base URL anyway, and forcing it on only works
  #    if the proxy serves `tool_reference` blocks — this gateway does not.
  [[ " $* " == *" --model "* ]] || args=(--model "$model" "${args[@]}")

  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    ANTHROPIC_DEFAULT_FABLE_MODEL="$model" \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$(_ca_ctx "$model")" \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW="$(_ca_ctx "$model")" \
    API_TIMEOUT_MS=3000000 \
    claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
}

# ── Off-Max `claude -p` transports ────────────────────────────────────────────
#
# Two helpers so subprocess skills (otel, analyze, read-drawing, ralph cleanup)
# don't copy-paste the IU credential plumbing. Both run `claude -p` off the Max
# subscription — billing is IU per-token, not Max quota. Pass any `claude -p`
# flags + a prompt (positional or via stdin), e.g.
#
#   claude_iu     --model haiku --dangerously-skip-permissions < prompt.txt
#   claude_bridge --model DeepSeek-V4-Pro --dangerously-skip-permissions < prompt.txt
#
# ANTHROPIC_API_KEY is stripped: claude v2.x rejects it ("Not logged in") and it
# would shadow ANTHROPIC_AUTH_TOKEN.

# IU unified endpoint, native Anthropic transport. Best Claude fidelity; NOT
# EU-residency-guaranteed (native routing can land in the US — use claude_bridge
# for GDPR-bound data). Creds from the same Keychain entries `make setup` caches.
claude_iu() {
  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
  if [[ -z "$key" || -z "$base" ]]; then
    print -ru2 "claude_iu: IU credentials missing in Keychain — run 'make setup' in dotfiles"
    return 1
  fi
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    claude -p "$@"
}

# Local LiteLLM bridge (LaunchAgent on :4000) → DeepSeek-V4-Pro (EU/GDPR, Azure Spain),
# with native failover to claude-sonnet-4-6-eu. Defaults --model to DeepSeek-V4-Pro if
# the caller omits it (the bridge 404s on an unmapped model name). Pass
# --model DeepSeek-V4-Flash for the fast/cheap tier. The bridge derives its own IU
# creds; the token here is a dummy claude v2.x requires. Constraint: no
# WebSearch/WebFetch (they make internal Anthropic calls the bridge can't serve).
# See dotfiles/docs/deepseek-litellm-bridge.md.
claude_bridge() {
  local url="${LITELLM_BRIDGE_URL:-http://127.0.0.1:4000}"
  if ! curl -fsS -m 3 "${url}/health/liveliness" >/dev/null 2>&1; then
    print -ru2 "claude_bridge: LiteLLM bridge unreachable at ${url} — run 'make litellm-restart' in dotfiles"
    return 1
  fi
  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model DeepSeek-V4-Pro "${args[@]}")
  # Pin subagent/background tiers to bridge-known names (see `ca` above) so any
  # -p flow that spawns a subagent can't fall back to an unmapped claude-* default.
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="${LITELLM_BRIDGE_TOKEN:-sk-litellm-master-key}" \
    ANTHROPIC_BASE_URL="$url" \
    ANTHROPIC_DEFAULT_OPUS_MODEL=DeepSeek-V4-Pro \
    ANTHROPIC_DEFAULT_SONNET_MODEL=DeepSeek-V4-Pro \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=DeepSeek-V4-Flash \
    ANTHROPIC_DEFAULT_FABLE_MODEL=DeepSeek-V4-Pro \
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
    claude -p "${args[@]}"
}
