# Prompt — starship.
#
# Sorts after path.zsh (alphabetical source order in ~/.zsh/conf.d), so
# Homebrew is already on PATH by the time this runs.
#
# The config lives in config/starship.toml and is deliberately palette-neutral
# (ANSI color names, not hex) so it follows the one-dark/one-light switch along
# with the terminal and herdr. See that file's header.

# Guarded rather than assumed: conf.d is symlinked as a whole, so this file
# lands on a machine the moment `make setup` links the directory — which can be
# BEFORE `brew bundle install` has put starship on PATH. An unguarded eval
# there breaks every new shell with a 127 and makes bootstrap look wedged.
if [[ -o interactive ]] && command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$HOME/.config/starship.toml"
  eval "$(starship init zsh)"
fi
