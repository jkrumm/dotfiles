# Claude Code launcher
#
# A bare `claude` typed into an interactive shell also picks the account (the `claude()` function in
# claude-auth.zsh, using the helpers below); c/cs/cf set CLAUDE_ACCOUNT_PICKED so it never picks twice.
#
# Usage: c  [--account <id>] [claude-args...]   — Max subscription; account from `claude-account pick`
#        cs [claude-args...]   — Max subscription, defaults to Sonnet model
#        cf [claude-args...]   — Max subscription, defaults to Fable model
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
_CLAUDE_ACCOUNTS_REGISTRY=${${(%):-%x}:A:h:h}/claude-accounts.json

# Every registry account has its own .claude.json (iu: ~/.claude.json, others: <dir>/.claude.json).
_claude_theme_auto() {
  local dir cj
  for dir in $(jq -r '.accounts[] | (.dir // "~")' "$_CLAUDE_ACCOUNTS_REGISTRY" 2>/dev/null || print '~'); do
    dir=${dir/#\~/$HOME}
    cj=$dir/.claude.json
    [[ $dir == $HOME ]] && cj=$HOME/.claude.json
    [[ -f $cj ]] || continue
    [[ "$(jq -r '.theme // ""' "$cj" 2>/dev/null)" == "auto" ]] && continue
    jq '.theme = "auto"' "$cj" > "$cj.tmp" && mv "$cj.tmp" "$cj"
  done
}

# The session id after `--resume|-r <id>` / `--resume=<id>` in the given args, or nothing. `--continue|-c`
# resumes the newest session in the cwd, so it resolves to that session's id (`claude-account latest`, from the
# shared projects/ transcripts); the first of the two flags wins. The lookup takes the physical path (`${PWD:A}`):
# Claude Code keys the transcript dir by the resolved cwd, so a symlinked $PWD would miss it.
_claude_resume_id() {
  while (( $# )); do
    case $1 in
      --continue|-c) claude-account latest "${PWD:A}" 2>/dev/null; return ;;
      --resume|-r) [[ ${2:-} == [A-Za-z0-9]*-* ]] && { print -r -- $2; return } ;;
      --resume=*) print -r -- ${1#--resume=}; return ;;
    esac
    shift
  done
}

# Account for an interactive launch (docs/claude-accounts.md). $1 = forced account id ("" = pick),
# $2 = pick lane (default interactive), $3 = session id being resumed (pins its account unless $1 is set).
# Prints three lines: an eval-safe env line (the picker's, or the forced account's), the account id for
# CLAUDE_ACCOUNT_PICKED and the routing reason for CLAUDE_ACCOUNT_REASON (the picker's `reason=`; `forced` /
# `resume` for an explicit or session-pinned account; empty when unknown). Any pick failure answers `unset CLAUDE_CONFIG_DIR` (account iu); an explicit
# override that fails answers nothing (rc 1).
_claude_account_line() {
  local forced=$1 lane=${2:-interactive} resume_id=${3:-} out line id reason="" rc=0
  # A resumed session stays on the account it ran on: the other account would re-send the whole
  # context cold. An explicit forced account wins; an unknown session falls through to the pick.
  if [[ -z $forced && -n $resume_id ]]; then
    forced=$(claude-account session "$resume_id" 2>/dev/null) || forced=""
    [[ -n $forced ]] && reason=resume
  fi
  if [[ -n $forced ]]; then
    line=$(claude-account env "$forced") || return 1
    id=$forced
    reason=${reason:-forced}
  else
    out=$(claude-account pick --lane "$lane" --why 2>/dev/null) || rc=$?
    line=${out%%$'\n'*}
    id=${${(M)${(f)out}:#\# picked=*}#\# picked=}; id=${id%% *}
    reason=${${(M)${(f)out}:#\# picked=*reason=*}#*reason=}; reason=${reason%% *}
    # exit 4: the registry was unreadable; the pick still answered `unset` (iu), but never silently
    (( rc == 4 )) && print -u2 "claude: claude-account registry unreadable — launching on the default account (iu)"
    # missing / crashing / silent picker: still non-blocking (iu), but never silent. `spill` is a real answer.
    case $line in
      "unset CLAUDE_CONFIG_DIR" | "export CLAUDE_CONFIG_DIR="* | spill) ;;
      *) print -u2 "claude: account picker failed (rc=$rc) - launching on iu" ;;
    esac
  fi
  case $line in
    "unset CLAUDE_CONFIG_DIR" | "export CLAUDE_CONFIG_DIR="*) ;;
    *) line="unset CLAUDE_CONFIG_DIR"; id=iu ;;
  esac
  [[ $id =~ ^[a-z][a-z0-9-]*$ ]] || id=iu
  [[ $reason =~ ^[a-z][a-z0-9-]*$ ]] || reason=""
  print -r -- $line
  print -r -- $id
  print -r -- $reason
}

# Enter an account chosen by `_claude_account_line` (call inside a subshell: it exports). The marker says
# "the account for this session is decided" — inherited by children, so neither `claude` nor `c` picks again;
# `rd` sets the same variable in its panes (remote-dev.sh agent_pane_setup). $1 = env line, $2 = account id,
# $3 = routing reason (CLAUDE_ACCOUNT_REASON, read by the statusline; unset when empty, never inherited).
_claude_enter_account() {
  eval "$1"
  export CLAUDE_ACCOUNT_PICKED=$2
  if [[ -n ${3-} ]]; then export CLAUDE_ACCOUNT_REASON=$3; else unset CLAUDE_ACCOUNT_REASON; fi
  # A non-default account must not inherit credentials meant for the default one.
  [[ $1 == "unset CLAUDE_CONFIG_DIR" ]] || unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
}

# Launch claude on the right account: $1 = model default ("" for none), rest = user args.
# The account is chosen once here and never changes for the session's life; the subshell keeps
# the pick out of the interactive shell's environment.
_claude_launch() {
  local model=$1; shift
  _claude_theme_auto

  local -a args=() plugin_args=()
  local account="" git_root pdir
  while (( $# )); do
    case $1 in
      --account) (( $# >= 2 )) || { print -u2 "c: --account needs one of: $(jq -r '.accounts | keys_unsorted | join(", ")' "$_CLAUDE_ACCOUNTS_REGISTRY" 2>/dev/null || print '<id>')"; return 1 }; account=$2; shift 2 ;;
      --account=*) account=${1#--account=}; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done

  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi
  [[ -n $model && " ${args[*]} " != *" --model "* ]] && args=(--model $model "${args[@]}")
  args+=(${(f)"$(_claude_effort_args "${args[@]}")"})

  local out line id reason
  local -a parts
  out=$(_claude_account_line "$account" interactive "$(_claude_resume_id "${args[@]}")") || return 1
  parts=("${(@f)out}"); line=$parts[1]; id=$parts[2]; reason=$parts[3]
  (
    _claude_enter_account "$line" "$id" "$reason"
    ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
  )
}

c() {
  _claude_launch "" "$@"
}

# Same as `c` (Max subscription, same config dir) but starts on Fable instead
# of whatever /model last left the session on.
cf() {
  _claude_launch "fable" "$@"
}

# Same as `c` (Max subscription, same config dir) but starts on Sonnet instead
# of whatever /model last left the session on — for when Opus is the default
# and this particular chat doesn't need it. `cs --model opus` overrides back.
cs() {
  _claude_launch "sonnet" "$@"
}

# `ca`, `cap`, `cdf`, `cdp` are gone (2026-10-24): Herdr sessions and waves run on the
# Max subscriptions only (`c`/`cs`/`cf`, account from `claude-account pick`). IU API tokens
# stay for gateways, OpenCode and Hermes (`oc`, `claude_iu`) — never for development sessions.

# ── Off-Max `claude -p` transport ─────────────────────────────────────────────
#
# So subprocess skills (analyze) don't
# copy-paste the IU credential plumbing. Runs `claude -p` off the Max
# subscription — billing is IU per-token, not Max quota. Pass any `claude -p`
# flags + a prompt (positional or via stdin), e.g.
#
#   claude_iu --model haiku --dangerously-skip-permissions < prompt.txt
#
# ANTHROPIC_API_KEY is stripped: claude v2.x rejects it ("Not logged in") and it
# would shadow ANTHROPIC_AUTH_TOKEN.

# IU unified endpoint, native Anthropic transport. Best Claude fidelity; NOT
# EU-residency-guaranteed (native routing can land in the US). Creds from the
# same Keychain entries `make setup` caches.
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

# `oc` — OpenCode on the IU endpoint, both routes. The third lane next to `ca`
# and `cx`: it reads the same AGENTS.md, ~/.claude/CLAUDE.md and ~/.claude/skills,
# and gets the always-on rules through `instructions` in config/opencode/opencode.json
# (→ ~/.config/opencode/opencode.json), which holds only {env:IU_*} placeholders —
# no key, no host. Pattern and measured load matrix: docs/agents-md.md.
#
# Creds resolve per call like `cx`: Keychain first, the time-boxed secrets shim
# second (`_codex_secret`, codex.zsh), exported only inside `oc`'s subshell (or
# a wave pane's own shell) — never `env VAR=…`, so they stay out of `ps auxww`.
#
# The two machine-dependent bits are gated at launch, not committed into the
# shared config: the light/dark re-theme (herdr panes only) and the mini-only
# agent-gateway MCP (config/opencode/mini.json via OPENCODE_CONFIG).
# The IU env opencode's `{env:…}` placeholders resolve against, as `export`
# lines. `oc` evals it; `rd wave --kind opencode` evals it inside the wave pane,
# so the key never rides argv or an ssh hop.
_oc_env() {
  local key base
  key=$(_codex_secret claude-sdk-api-key op://common/anthropic/API_KEY)
  base=$(_codex_secret claude-sdk-base-url op://common/anthropic/BASE_URL)
  if [[ -z "$key" || -z "$base" ]]; then
    print -ru2 "oc: IU credentials unresolvable — run 'make setup' in dotfiles"
    return 1
  fi
  base=${base%/}
  local openai="${base%/anthropic}/openai/v1"
  print -r -- "export IU_KEY=${(q)key} IU_ANTHROPIC_BASE=${(q)base} IU_OPENAI_BASE=${(q)openai}"
  # agent-gateway's MCP is stdio-only against a repo that lives on the mini, so layer
  # it in with OPENCODE_CONFIG (merged over the global config) only where it
  # exists — the MacBook stays agent-gateway-free.
  if [[ -f "$HOME/SourceRoot/agent-gateway/server/mcp.ts" ]]; then
    print -r -- "export OPENCODE_CONFIG=${(q)HOME}/SourceRoot/dotfiles/config/opencode/mini.json"
  fi
  # v2 attaches to ONE shared background service that never saw this shell's env, so the
  # {env:IU_*} placeholders resolve empty there. Hand it the values (env-only, idempotent).
  print -r -- "\"\$HOME/SourceRoot/dotfiles/scripts/opencode-service-env.sh\" || true"
}

oc() {
  local envs
  envs=$(_oc_env) || return 1
  # Re-theme this pane to the appearance the MacBook last pushed. herdr panes
  # only — a Ghostty client answers OpenCode's own terminal query. Mirrors
  # Claude's SessionStart hook; sends after the TUI is up.
  "$HOME/SourceRoot/dotfiles/scripts/claude-appearance.sh" session >/dev/null 2>&1 || true
  (eval "$envs"; command opencode "$@")
}
