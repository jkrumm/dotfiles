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
# It used to ask "restart the remote server now? [y/N]" on EVERY launch, and
# the only correct answer was N — y restarts the server outside brew services
# and kills every process in every pane. Root cause, measured rather than
# guessed: herdr derives `detached_server_daemon` from `getsid(0) == getpid()`,
# and a launchd job is not a session leader (the mini's server ran pid 671,
# pgid 671, sid 1). The warning is true as asked and false as meant — launchd
# owns the job and no ssh disconnect can reach it.
#
# Fixed by herdr/herdr-server-start.py, which forks + setsid()s before exec'ing
# the server; `make _herdr-supervise` pins it into the brew plist and
# `brew-upgrade.sh` asserts it (brew regenerates that plist silently). If the
# prompt ever comes back, that assertion is what to run — and still answer N.
desk() {
  local session="${1:-}"
  local -a args=(--remote mini)
  [[ -n "$session" ]] && args+=(--session "$session")
  herdr "${args[@]}"
}

# `rd` — the layer above the transport: prepare and steer work on the mini
# WITHOUT a terminal into it.
#
# `dev`/`desk` answer "how do I go look at the mini". `rd` answers "how do I put
# work on the mini and check on it", which is the thing you actually do most and
# the thing that used to require attaching first. It routes itself: on the mini
# it runs locally, from the MacBook it is one ssh hop, so the same words work on
# both machines. Full contract in scripts/remote-dev.sh and the /remote-dev skill.
rd() { "$HOME/SourceRoot/dotfiles/scripts/remote-dev.sh" "$@"; }

# Shorthands for the three read-mostly verbs. Deliberately NOT defined for
# bg/read/say — `bg` and `read` are zsh builtins and `say` is /usr/bin/say, and
# shadowing any of them to save four keystrokes is how you break unrelated
# scripts months later. Those stay `rd bg` / `rd read` / `rd say`.
work()   { rd work "$@"; }
agents() { rd agents "$@"; }
repos()  { rd repos "$@"; }
