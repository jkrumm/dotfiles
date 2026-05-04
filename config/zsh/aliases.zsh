# Aliases and one-liners

# Shell
alias sz="source ~/.zshrc"                                # reload config
alias zh="awk '/OPENSPEC:END/{f=1;next} f&&/^for /{exit} f&&/^#/{sub(/^# ?/,\"\");print}' ~/.zshrc"  # print this help

# Git
alias gback="git reset --soft HEAD~1"                     # undo last commit, keep changes staged

# SSH
alias homelab="ssh homelab"
alias vps="ssh vps"

# Local dev proxy
alias caddy-reload="caddy reload --config $(brew --prefix)/etc/Caddyfile"

# Apps
alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
zed() { /opt/homebrew/bin/zed "${1:-.}" }                 # open dir (or cwd) in Zed

# 1Password backup
alias opbackup="~/SourceRoot/dotfiles/scripts/backup-1password.py"

# IU (work)
alias start-iu-fe="~/IuRoot/prometheus-scripts/bash/start-frontends.sh"
alias sync-iu-db="~/IuRoot/prometheus-scripts/bash/sync-dev-db.sh"

# AWS SSO (IU IDSS) — aws-login [Dev|Non-Prod|Prod|Shared], default Non-Prod; exports AWS_PROFILE
aws-login() {
  local env="${1:-Non-Prod}"
  local profile="aws.CP.IDSS.${env}"
  aws sso login --profile "$profile" || return 1
  export AWS_PROFILE="$profile"
  echo "AWS_PROFILE=$AWS_PROFILE"
}

# Node
alias npmplease="rm -rf node_modules/ && rm -f package-lock.json && npm install"
