# 1Password SSH agent for NON-INTERACTIVE local shells.
#
# conf.d/secrets.zsh already exports SSH_AUTH_SOCK, but .zshrc is not read by a
# command shell (launchd jobs, `zsh -c`), so those start with it UNSET. Every
# git remote on the MacBook is `git@github.com:` and the machine holds no
# private key on disk — every identity comes from 1Password — so a local job
# that runs git needs the agent socket exported here.
#
# An INCOMING ssh session never gets it. The mini's key into this machine runs
# only the verbs scripts/iumac-gate.sh allows, none of which needs a git
# identity; the session is cut off from the local agent by design (least
# privilege), and the gate unsets SSH_AUTH_SOCK itself as well.
#
# GATED ON THE `op` BACKEND, NOT ON THE SOCKET EXISTING. The socket path exists
# on the MINI too — the desktop app has run there — and exporting it on a
# headless machine is the documented hang: anything that consults that agent
# waits forever on a biometric prompt nobody can answer. That hazard is the
# whole reason `Host iumac` pins `IdentityAgent none` (config/ssh_config), so a
# socket-existence guard here would quietly reintroduce it.
#
# `read` + `<` is a zsh builtin: this file runs for every zsh spawned on the
# machine, so a `cat` would be one fork per shell.
() {
  local backend sock marker
  marker="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
  [[ -r "$marker" ]] || return 0
  read -r backend < "$marker" || return 0
  [[ "$backend" == "op" ]] || return 0

  # An incoming ssh session never gets the local 1Password agent socket.
  [[ -n "${SSH_CONNECTION:-}" ]] && return 0

  sock="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  [[ -S "$sock" ]] || return 0

  # Never clobber a live FORWARDED agent — same rule secrets.zsh expresses with
  # its $SSH_CONNECTION guard, stated as the condition it actually cares about.
  # Note the inherited-but-useless case is deliberately NOT handled here: launchd
  # points SSH_AUTH_SOCK at Apple's ssh-agent, a valid socket holding zero
  # identities (see scripts/opbackup-seed-auto.sh). Probing for that costs an
  # `ssh-add -l` fork in every shell on the machine; the jobs that need it
  # already prefer the 1Password socket themselves.
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]] && return 0

  export SSH_AUTH_SOCK="$sock"
}
