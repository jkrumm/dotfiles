#!/usr/bin/env bash
set -uo pipefail

# agent-dispatch — one durable-episode dispatch surface. <repo> is a NAME,
# never a path — resolution happens per-machine, same rule
# scripts/remote-dev.sh already enforces for `rd bg` / `rd work`.
#
#   agent-dispatch bg <repo> '<task>'    durable background episode
#   agent-dispatch work <repo>           herdr workspace + interactive claude
#
# ROUTING, decided by this machine's secrets backend
# (~/.config/secrets/backend) crossed with whether <repo> exists here:
#
#   backend=cache (the mini)             → exec scripts/remote-dev.sh, which
#     already spawns durable work through a herdr pane — the keychain-safe
#     path, since a bare `ssh mini 'claude --bg …'` cannot reach the login
#     keychain and silently falls back to API billing (see dotfiles AGENTS.md,
#     "Surviving independently ≠ launching independently").
#
#   backend=op (the MacBook) + <repo> present here (a sanctioned MacBook
#   repo) → `bg` runs `claude -p` LOCALLY, off the IU unified endpoint,
#     mirroring `claude_iu()`/`ca()` in config/zsh/claude.zsh (same Keychain
#     entries, same env shape) rather than hopping to the mini for work that
#     can run right here. `work` still hops to the mini via remote-dev.sh —
#     interactive work belongs on the dev host, not this laptop — and prints
#     a hint to attach with `desk`.
#
#   <repo> not present here (backend=op and it is not a sanctioned MacBook
#   repo, or any other case) → exec scripts/remote-dev.sh, which already
#     resolves it on the far side over ssh.
#
# --dry-run prints the resolved route and the command that would run, then
# exits 0 without running anything.
#
# SECRETS_BACKEND_OVERRIDE overrides the detected backend. --dry-run/test use
# only — it exists so the MacBook branch can be exercised from the mini (and
# vice versa) without faking the marker file.
#
# NESTING GUARD, on the local `claude -p` path only: refuses to run when
# CLAUDECODE is already set (Claude Code sets CLAUDECODE=1 in every tool
# shell it opens), because a `claude -p` spawned inside an interactive Claude
# Code session is an unsupervised nested agent, not a dispatch — use a
# subagent instead. The `rd bg` path is exempt: herdr spawns an independent
# process tree there, so it is never nested even when the caller happens to
# be running inside Claude Code.
#
# BASH 3.2-safe: no mapfile, no ${var,,}, arrays only ever appended to or
# indexed, never expanded with "${arr[@]}" while possibly empty.

# Installed as a symlink (~/.local/bin/agent-dispatch → this file), so resolve
# the link before deriving the repo root — dirname of the link would be ~/.local.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _target=$(readlink "$_self")
  case "$_target" in
    /*) _self="$_target" ;;
    *)  _self="$(dirname "$_self")/$_target" ;;
  esac
done
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "$_self")/.." && pwd)}"
REMOTE_DEV="$DOTFILES_DIR/scripts/remote-dev.sh"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: agent-dispatch [--dry-run] bg <repo> '<task>'
       agent-dispatch [--dry-run] work <repo>

  bg <repo> '<task>'   durable background episode against <repo>
  work <repo>          herdr workspace + interactive claude on the dev host

Three lanes for putting work on the mini:
  executor    sideclaw `dispatch` (MCP) — one bare episode, a typed verdict, no item
  lifecycle   `warden run <repo> '<brief>'` — opens an ITEM that rides the ledger:
              investigate → verdict → implement → review → merge, gated by policy
  colleague   this script's `bg` — a durable claude you can steer with `rd say`
              (`work` above is a terminal, not this lane)

<repo> is a NAME, never a path.

  --dry-run   print the resolved route + command, run nothing, exit 0

Env (test/dry-run only):
  SECRETS_BACKEND_OVERRIDE   override the detected secrets backend (cache/op)
USAGE
}

BACKEND_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
BACKEND="${SECRETS_BACKEND_OVERRIDE:-$(tr -d '[:space:]' < "$BACKEND_FILE" 2>/dev/null || echo "")}"

DRY_RUN=0
rest=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) rest+=("$a") ;;
  esac
done

verb="${rest[0]:-}"
repo="${rest[1]:-}"
task="${rest[2]:-}"

case "$verb" in
  bg)
    [ -n "$repo" ] || { usage; die "bg needs a <repo>"; }
    [ -n "$task" ] || { usage; die "bg needs a '<task>'"; }
    ;;
  work)
    [ -n "$repo" ] || { usage; die "work needs a <repo>"; }
    ;;
  ""|help)
    usage; exit 0 ;;
  *)
    usage; die "unknown subcommand '$verb'" ;;
esac

[ -x "$REMOTE_DEV" ] || [ -f "$REMOTE_DEV" ] || die "missing $REMOTE_DEV"

# Purely local filesystem check — never ssh, never mutates. Used only to
# decide ROUTING; scripts/remote-dev.sh does its own (server-side) resolution
# when this hands off to it.
resolve_local_repo() {
  local name="$1" r
  for r in "$HOME/SourceRoot" "$HOME/IuRoot"; do
    if [ -d "$r/$name/.git" ]; then printf '%s' "$r/$name"; return 0; fi
  done
  return 1
}

nesting_guard() {
  if [ -n "${CLAUDECODE:-}" ]; then
    {
      echo "agent-dispatch: refusing to nest a claude -p inside an interactive Claude Code session — use a subagent, or run from a plain shell"
      echo "  repo: $repo"
      echo "  cwd:  $1"
      echo "  task: $task"
    } >&2
    exit 1
  fi
}

# Context window + GLM thinking budget per gateway model id — the same
# case-statement functions config/zsh/claude.zsh's `ca()` reads for its own
# gateway tier, shared (not duplicated) because bash 3.2 has no assoc arrays:
# see config/zsh/iu-models.sh for `_ca_ctx`/`_ca_thinking` contracts and
# rationale. Update the table there, not here.
# shellcheck source=../config/zsh/iu-models.sh
source "$DOTFILES_DIR/config/zsh/iu-models.sh"

# Local `claude -p` path — backend=op, <repo> is a sanctioned MacBook repo.
# Mirrors claude_iu()/ca() in config/zsh/claude.zsh: same Keychain entries,
# same ANTHROPIC_AUTH_TOKEN/BASE_URL shape, ANTHROPIC_API_KEY unset (claude
# rejects it there). --dangerously-skip-permissions matches every other
# non-interactive launcher in this repo (ca, claude_iu callers) — a `claude
# -p` with no TTY to answer a permission prompt would otherwise hang forever.
#
# Default model is a cheap IU gateway model, not Sonnet: this path runs
# UNATTENDED against the IU key, billed per token with nobody watching a
# meter — the worst combination for a premium model. modelpick's 2026-09-20
# ccbench run moved this fleet off glm: DeepSeek-V4-Flash posts a 1.00
# composite at ~190 effective in-loop tok/s, 6m20s wall, $0.09, 4%
# tool-error and zero compactions, against glm-5.3-flash's 0.81, 38m24s,
# 13.3 tok/s and $0.035 — a little cost and index-capability traded for
# ~14x in-loop speed, which is what an unattended lane actually needs.
# `ANTHROPIC_MODEL` still overrides it exactly as before.
run_local_claude_p() {
  local path="$1"
  nesting_guard "$path"

  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
  if [ -z "$key" ] || [ -z "$base" ]; then
    die "IU credentials missing in Keychain — run 'make setup' in dotfiles"
  fi

  local model="${ANTHROPIC_MODEL:-DeepSeek-V4-Flash}"

  # Gateway tier (any non-Claude id, the default included) needs the same
  # extras config/zsh/claude.zsh's `ca()` sets for it: without the context/
  # timeout pair the CLI budgets a 1M-context model as if it were the 200k
  # first-party default and times out per request instead of the minutes these
  # models actually take; without MAX_THINKING_TOKENS, GLM defaults to `max`
  # thinking, its worst setting. A `claude-*` override skips all of it — that
  # tier is first-party and already handled by the CLI itself.
  local haiku_model="$model"
  local -a gateway_env=()
  local tool_search="true"
  if [[ "$model" != claude-* ]]; then
    local ctx thinking
    ctx=$(_ca_ctx "$model")
    thinking=$(_ca_thinking "$model")
    gateway_env=(CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx" CLAUDE_CODE_AUTO_COMPACT_WINDOW="$ctx" API_TIMEOUT_MS=3000000)
    # MAX_THINKING_TOKENS is the only reasoning-effort control that reaches
    # this leg (GLM) — --effort/reasoning_effort are no-ops here, so there is
    # nothing else to set for effort on a gateway id.
    [ -n "$thinking" ] && gateway_env+=(MAX_THINKING_TOKENS="$thinking")
    # ENABLE_TOOL_SEARCH stays unset on the gateway tier, matching ca()'s
    # gateway branch: Claude Code disables deferred tool search on a
    # non-first-party base URL anyway, and forcing it on only works when the
    # proxy serves `tool_reference` blocks — this gateway does not.
    tool_search=""
  else
    haiku_model="claude-haiku-4-5"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "route: local claude -p (backend=op, sanctioned repo)"
    echo "  cwd:     $path"
    echo "  model:   $model"
    echo "  command: claude -p '$task' --output-format json --dangerously-skip-permissions --model '$model'"
    exit 0
  fi

  local out rc
  out=$(cd "$path" && env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    ANTHROPIC_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku_model" \
    ANTHROPIC_DEFAULT_FABLE_MODEL="$model" \
    ${tool_search:+ENABLE_TOOL_SEARCH=true} \
    ${gateway_env[@]+"${gateway_env[@]}"} \
    claude -p "$task" --output-format json --dangerously-skip-permissions --model "$model")
  rc=$?

  local sid
  sid=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null) || sid=""
  if [ -n "$sid" ]; then
    echo "$sid"
  else
    printf '%s\n' "$out" >&2
  fi
  exit "$rc"
}

case "$verb" in
  bg)
    if [ "$BACKEND" = "op" ]; then
      path=$(resolve_local_repo "$repo") && run_local_claude_p "$path"
    fi
    # cache backend, or op with <repo> not local: remote-dev.sh routes it
    # (local exec on the mini, one ssh hop from the MacBook).
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "route: exec $REMOTE_DEV bg $repo '<task>' (backend=${BACKEND:-unset})"
      exit 0
    fi
    exec "$REMOTE_DEV" bg "$repo" "$task"
    ;;
  work)
    if [ "$BACKEND" = "op" ] && resolve_local_repo "$repo" >/dev/null 2>&1; then
      echo "→ hopping to the mini for interactive work; attach with 'desk' once it starts" >&2
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "route: exec $REMOTE_DEV work $repo (backend=${BACKEND:-unset})"
      exit 0
    fi
    exec "$REMOTE_DEV" work "$repo"
    ;;
esac
