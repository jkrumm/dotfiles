# Secrets — 1Password personal account (biometric / session token via op signin)
# Switch back to service account: uncomment OP_SERVICE_ACCOUNT_TOKEN and comment out the signin block

# [SERVICE ACCOUNT — disabled] export OP_SERVICE_ACCOUNT_TOKEN=$(security find-generic-password -a "$USER" -s "op-service-account-token" -w 2>/dev/null)

# 1Password SSH agent — required for op-ssh-sign (git commit signing) and SSH key auth
export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

# ANTHROPIC_* intentionally not exported — Claude Code would prefer API credits over subscription if set
# export ANTHROPIC_API_KEY=$(security find-generic-password -a "$USER" -s "anthropic-api-key" -w 2>/dev/null)
# export ANTHROPIC_BASE_URL=$(security find-generic-password -a "$USER" -s "anthropic-base-url" -w 2>/dev/null)

# ──────────────────────────────────────────────────────────────────────────────
# 1Password account routing (workspace-aware, worktree-safe)
#
#   SourceRoot/  → tkrumm        (personal)
#   IuRoot/      → careerpartner (work)
#   elsewhere    → tkrumm        (default)
#
# Worktrees resolve to their main repo via `git rev-parse --git-common-dir`
# before matching, so a worktree placed outside the workspace still picks the
# right account.
# ──────────────────────────────────────────────────────────────────────────────

op_account_for_cwd() {
  local check repo_dir
  if check=$(git rev-parse --git-common-dir 2>/dev/null); then
    repo_dir=$(cd "$check/.." 2>/dev/null && pwd -P)
  fi
  : ${repo_dir:=$PWD}
  case "$repo_dir" in
    "$HOME/IuRoot"/*|"$HOME/IuRoot")         echo "careerpartner" ;;
    "$HOME/SourceRoot"/*|"$HOME/SourceRoot") echo "tkrumm" ;;
    *)                                       echo "tkrumm" ;;
  esac
}

# Convenience wrapper — invokes `op` with the workspace-appropriate account.
# Examples:
#   op_run vault list
#   op_run read "op://Private/foo/password"
#   op_run run --env-file=.env.tpl -- bun test
op_run() {
  command op --account "$(op_account_for_cwd)" "$@"
}
