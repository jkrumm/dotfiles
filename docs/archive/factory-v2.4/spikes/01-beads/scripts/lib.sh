#!/usr/bin/env bash
# Shared environment for every spike script. Source it, never execute it.
# Everything lives under $SPIKE; HOME is redirected so bd, dolt and git never read
# or write the real ~/.beads, ~/.dolt, ~/.config/beads, ~/.beads-planning or ~/.gitconfig.
SPIKE="${SPIKE:-$HOME/.local/share/factory/spikes/01-beads}"
export SPIKE
REAL_HOME="$HOME"
export REAL_HOME
export SPIKE_HOME="$SPIKE/home"
mkdir -p "$SPIKE"/{bin,data,logs,downloads,meta,results,home}
# a clean, per-command environment: only the scratch bin first, then system tools
spike_env() { # usage: spike_env <cmd...>
  env -i HOME="$SPIKE_HOME" PATH="$SPIKE/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TERM=dumb LANG=en_US.UTF-8 GIT_CONFIG_GLOBAL="$SPIKE_HOME/.gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
    GIT_TERMINAL_PROMPT=0 "$@"
}
# git identity for scratch repos only (email assembled so no address literal sits in a tracked file)
FAKE_DOMAIN="spike.invalid"
if [ ! -f "$SPIKE_HOME/.gitconfig" ]; then
  {
    echo "[user]"; echo "	name = Spike"; echo "	email = spike@${FAKE_DOMAIN}"
    echo "[commit]"; echo "	gpgsign = false"
    echo "[init]"; echo "	defaultBranch = main"
  } > "$SPIKE_HOME/.gitconfig"
fi
