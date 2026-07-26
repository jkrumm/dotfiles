# Remote dev — one command to land in a persistent session on the Mac mini.
#
# The four-layer model (Tailscale / mosh / herdr / Caddy) is in
# dotfiles/docs/remote-dev.md; this file is only the front door. The design goal
# is that reaching the dev host costs one word, and that the word picks the
# right transport instead of making you remember which one you wanted.

# `dev` — mosh in, herdr there. The durable path.
#
# Why mosh is the default rather than `herdr --remote`: mosh moves the session
# to UDP, so a lid-close or a network change does not end it and there is
# nothing to reattach — you reopen the laptop and the session is simply still
# there. `herdr --remote` is TCP and dies on a roam, which is a worse default
# even though it feels nicer at the desk. Use `desk` for that.
#
# --experimental-remote-ip=remote is load-bearing, not a curiosity. mosh's
# DEFAULT (`proxy`) passes `-S none` to ssh (see /opt/homebrew/bin/mosh:407),
# which disables multiplexing — so every single `mosh mini` opens a fresh
# connection and pops its own 1Password biometric approval, exactly the friction
# ssh_config's ControlMaster block exists to remove. `remote` mode skips the
# ProxyCommand and reuses the master socket. Verified 2026-07-26.
dev() {
  local session="${1:-}"
  local -a herdr_cmd=(herdr)
  [[ -n "$session" ]] && herdr_cmd+=(--session "$session")

  command -v mosh >/dev/null 2>&1 || {
    print -u2 "dev: mosh not installed — run 'make setup' (Brewfile), or use 'desk' for the ssh path"
    return 127
  }

  mosh --experimental-remote-ip=remote mini -- "${herdr_cmd[@]}"
}

# `desk` — herdr's native attach over ssh. The client runs HERE.
#
# Buys local keybindings and local image paste, which matter when you are
# actually sitting at the laptop. Costs roaming: this is TCP, so a lid-close
# ends the connection and you re-run it. The herdr SERVER and every pane live on
# the mini either way — this is a client-experience choice, not a persistence
# one.
#
# Note it will ask "restart the remote server now? [y/N]", warning the server
# "may not survive SSH connection loss". Answer N. That is a false positive
# here: the server is the brew service under launchd (PPID 1), which no ssh
# disconnect can reach. Answering y restarts it OUTSIDE brew services and kills
# every process in every pane.
desk() {
  local session="${1:-}"
  local -a args=(--remote mini)
  [[ -n "$session" ]] && args+=(--session "$session")
  herdr "${args[@]}"
}
