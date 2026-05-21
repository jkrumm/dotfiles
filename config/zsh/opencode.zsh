# OpenCode CLI — fallback coding agent on the IU unified endpoint.
#
# Use when the Claude Code Max subscription is exhausted. Same IU credential as
# the Agent SDK (op://common/anthropic), cached in Keychain by `make setup`.
#
# Secrets are injected into the OpenCode process ONLY (not the interactive
# shell), read just-in-time from Keychain. opencode.json contains no key and no
# hostname — only {env:IU_*} placeholders resolved here.
#
#   opencode                       launch TUI (default: iu-anthropic/claude-sonnet-4-6)
#   opencode -m iu/Kimi-K2.6       pick any model (provider/model)
#   opencode run "..."             one-shot prompt
#   oc / ocr                       short aliases (oc = opencode, ocr = opencode run)

export PATH="$HOME/.opencode/bin:$PATH"

opencode() {
  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)  # https://…/anthropic
  if [[ -z "$key" || -z "$base" ]]; then
    echo "opencode: IU credentials missing in Keychain — run 'make setup' in dotfiles" >&2
    return 1
  fi
  base="${base%/}"
  IU_API_KEY="$key" \
  IU_ANTHROPIC_BASE_URL="${base}/v1" \
  IU_OPENAI_BASE_URL="${base%/anthropic}/openai/v1" \
    command opencode "$@"
}

alias oc='opencode'
alias ocr='opencode run'
