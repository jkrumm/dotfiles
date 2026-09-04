# Warp-like text input for Ghostty
# Ghostty config: ~/.config/ghostty/config sets macos-option-as-alt = left
#
# Active bindings:
#   Ctrl+A / Ctrl+E     beginning / end of line
#   Ctrl+U              clear line
#   Ctrl+W              delete word before cursor
#   Ctrl+K              delete to end of line
#   Option+Left/Right   jump word (requires macos-option-as-alt = left in Ghostty)

autoload -U select-word-style
select-word-style bash          # natural word boundaries (/, -, _ are separators)
bindkey -e                      # emacs line editing

bindkey '\e[1;3D' backward-word # Option+Left
bindkey '\e[1;3C' forward-word  # Option+Right
bindkey '\eb'     backward-word # Alt+b fallback
bindkey '\ef'     forward-word  # Alt+f fallback
