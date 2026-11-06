#!/bin/zsh
# MacBook: restart the core so its holder gets a clean environment. Ends the programs in every terminal (they come back as
# shells; `claude --resume` by hand). For a core that inherited an agent's environment: `hc-responsible.py` names it.
# Why env -i on everything: a core's environment becomes every terminal's (upstream #86), and `open` hands the caller's
# environment to the app it launches, so an agent running `open -a Herdr` poisons every terminal with its CLAUDE_* markers.
[[ "$(tr -d '[:space:]' < "$HOME/.config/secrets/backend")" == op ]] || { echo "MacBook only" >&2; exit 2; }
if [[ -z "${_CLEAN_RESTART:-}" ]]; then
  # Detached and clean: running this from a Herdr terminal ends that terminal.
  nohup env -i HOME="$HOME" USER="$USER" PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" _CLEAN_RESTART=1 /bin/zsh "$0" >/dev/null 2>&1 </dev/null &
  disown
  echo "restarting in the background (log: ~/Library/Logs/herdr-core-clean-restart.log)"
  exit 0
fi
exec >>"$HOME/Library/Logs/herdr-core-clean-restart.log" 2>&1
set -x
date
HC="$HOME/.local/bin/hc"
pids=$("$HC" server status | jq -r '.holders[].pid')
osascript -e 'tell application "Herdr" to quit' || true
sleep 3
"$HC" server stop
sleep 2
for p in ${(f)pids}; do kill -TERM "$p" 2>/dev/null; done
sleep 3
# launchd's own environment, exactly what a Dock click gets.
env -i HOME="$HOME" USER="$USER" /usr/bin/open -a "$HOME/Applications/Herdr.app"
for i in {1..40}; do bash "$HOME/SourceRoot/dotfiles/scripts/lib/core-up.sh" >/dev/null 2>&1 && break; sleep 1; done
python3 "$HOME/SourceRoot/dotfiles/scripts/hc-responsible.py"
date
