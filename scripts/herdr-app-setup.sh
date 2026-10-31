#!/usr/bin/env bash
# Converge the Herdr desktop app (herdr-core evaluation, MacBook) onto the tracked
# config: the `jk` layout (One Zinc theme, jk-spaces folders from config/herdr/groups.json,
# no agents list, jk-status bar), and one space per daily repo.
# Idempotent. docs/herdr-core.md §Desktop layout.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DOTFILES_DIR/config/herdr-app"
HOME_DIR="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"

# name|folder — the spaces this machine opens. A space already working in the folder is kept.
SPACES=(
  "shutterflow|$HOME/SourceRoot/shutterflow"
  "ShutterflowOps|$HOME/SourceRoot/ShutterflowOps"
  "tinycast-extensions|$HOME/SourceRoot/tinycast-extensions"
  "finances|$HOME/SourceRoot/finances"
  "dotfiles|$HOME/SourceRoot/dotfiles"
)

say() { printf '  %s\n' "$*"; }

command -v herdr-app >/dev/null || { echo "herdr-app not installed — curl -fsSL https://releases.herdr.dev/app/install.sh | sh"; exit 1; }
[ -d "$HOME_DIR/mods" ] || { echo "$HOME_DIR not initialised — open Herdr once first"; exit 1; }

link() { # src dst
  if [ -L "$2" ] && [ "$(readlink "$2")" = "$1" ]; then say "· $(basename "$2") (ok)"; return; fi
  [ -e "$2" ] && [ ! -L "$2" ] && mv "$2" "$2.bak" && say "backed up $2 → $2.bak"
  ln -sfn "$1" "$2"; say "✓ $(basename "$2")"
}

for mod in jk-spaces jk-status; do link "$SRC/mods/$mod" "$HOME_DIR/mods/$mod"; done
for theme in "$SRC"/themes/*.json; do link "$theme" "$HOME_DIR/themes/$(basename "$theme")"; done
link "$SRC/layouts/jk.json" "$HOME_DIR/layouts/jk.json"

for mod in jk-spaces jk-status; do
  herdr-app check "$HOME_DIR/mods/$mod" >/dev/null || { echo "✗ herdr-app check $mod failed:"; herdr-app check "$HOME_DIR/mods/$mod"; exit 1; }
  say "✓ check $mod"
done

if ! herdr-app status >/dev/null 2>&1; then
  say "window not running — open Herdr and re-run to switch the layout and open the spaces"; exit 0
fi

# Switching away and back reloads the layout and its mods: edits inside a symlinked mod folder go unnoticed otherwise.
herdr-app "do" layout.switch --name main >/dev/null; sleep 1
herdr-app "do" layout.switch --name jk >/dev/null && say "✓ layout jk (reloaded)"

open_folders=$(herdr-app ls | /usr/bin/python3 -c 'import json,sys; [print(s["folder"]) for s in json.load(sys.stdin)["spaces"] if not s.get("machine")]')
for entry in "${SPACES[@]}"; do
  name=${entry%%|*} folder=${entry#*|}
  [ -d "$folder" ] || { say "- $name: $folder missing, skipped"; continue; }
  if grep -qxF "$folder" <<<"$open_folders"; then say "· space $name (open)"; continue; fi
  herdr-app "do" space.new --name "$name" --folder "$folder" >/dev/null && say "✓ space $name"
done
