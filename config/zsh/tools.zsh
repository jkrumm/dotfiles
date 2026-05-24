# Tool init — cached where possible to keep shell startup fast

# zoxide — smart directory jumping (replaces cd)
#   j <dir>     jump to best match
#   ji          interactive selection with fzf
eval "$(zoxide init zsh --cmd j)"

# fzf — fuzzy finder
#   Ctrl+R      fuzzy history search
#   Ctrl+T      fuzzy file picker (inserts path)
#   Alt+C       fuzzy cd into subdirectory
_fzf_cache="$HOME/.cache/zsh/fzf-init.zsh"
if [[ ! -f "$_fzf_cache" || /opt/homebrew/bin/fzf -nt "$_fzf_cache" ]]; then
  mkdir -p "${_fzf_cache:h}"
  fzf --zsh >| "$_fzf_cache"
fi
source "$_fzf_cache"

# wtp — git worktree manager
#   wtp add <branch>              create worktree + run post_create hooks
#   wtp cd <name>                 navigate to worktree
#   wtp list                      list all worktrees
#   wtp remove <name>             remove worktree
#   wtp remove <name> --with-branch  remove worktree + branch
_wtp_cache="$HOME/.cache/zsh/wtp-init.zsh"
if [[ ! -f "$_wtp_cache" || $(command -v wtp) -nt "$_wtp_cache" ]]; then
  mkdir -p "${_wtp_cache:h}"
  wtp shell-init zsh >| "$_wtp_cache"
fi
source "$_wtp_cache"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"
