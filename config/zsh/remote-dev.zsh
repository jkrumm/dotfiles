# Remote dev — the front door to the Mac mini.
#
# The three-layer model (Tailscale / herdr-core / Caddy) is in dotfiles/docs/remote-dev.md. Getting a terminal is the
# Herdr app (MacBook) or `ssh -t mini hc`; this file holds the shorthands for steering work without one.

# `rd` — the layer above the transport: prepare and steer work on the mini
# WITHOUT a terminal into it. A script on PATH (~/.local/bin/rd, linked by
# `make setup`), so ssh remote commands and non-zsh callers resolve it too.
# It routes itself: on the mini it runs locally, from the MacBook it is one ssh
# hop. Full contract in scripts/remote-dev.sh and the /remote-dev skill.

# Shorthands for the three read-mostly verbs. Deliberately NOT defined for
# read/say — `bg` and `read` are zsh builtins and `say` is /usr/bin/say, and
# shadowing any of them to save four keystrokes is how you break unrelated
# scripts months later. Those stay `rd read` / `rd say`.
work()   { rd work "$@"; }
agents() { rd agents "$@"; }
repos()  { rd repos "$@"; }

# `se-stack status|up|down|restart-backend|logs` — thin CLI over the IU dev stack's
# dashboard on the mini (backend, FEs). The script lives in prometheus-scripts; on
# the mini it runs locally (hostname matches).
export STACK_REMOTE_HOST=mini
se-stack() { "$HOME/IuRoot/prometheus-scripts/bash/stack-remote.sh" "$@"; }
