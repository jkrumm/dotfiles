#!/usr/bin/env bash
# Converge the Herdr desktop app (herdr-core evaluation, MacBook) onto the tracked
# config: the `jk` layout (One Zinc theme, jk-spaces folders from config/herdr/groups.json,
# no agents list, jk-status bar), and one space per daily repo.
# Idempotent. docs/herdr-core.md §Desktop layout.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DOTFILES_DIR/config/herdr-app"
HOME_DIR="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
MODS=(jk-spaces jk-status jk-details)

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

for mod in "${MODS[@]}"; do link "$SRC/mods/$mod" "$HOME_DIR/mods/$mod"; done
# jk-spaces reads its folders from here: one taxonomy with classic herdr's sidebar.
link "$DOTFILES_DIR/config/herdr/groups.json" "$HOME_DIR/groups.json"
for theme in "$SRC"/themes/*.json; do link "$theme" "$HOME_DIR/themes/$(basename "$theme")"; done
link "$SRC/layouts/jk.json" "$HOME_DIR/layouts/jk.json"

for mod in "${MODS[@]}"; do
  herdr-app check "$HOME_DIR/mods/$mod" >/dev/null || { echo "✗ herdr-app check $mod failed:"; herdr-app check "$HOME_DIR/mods/$mod"; exit 1; }
  say "✓ check $mod"
done

if ! herdr-app status >/dev/null 2>&1; then
  say "window not running — open Herdr and re-run to switch the layout and open the spaces"; exit 0
fi

# Switching away and back reloads the layout and its mods: edits inside a symlinked mod folder go unnoticed otherwise.
herdr-app "do" layout.switch --name main >/dev/null
for _ in $(seq 20); do herdr-app status | grep -q '"layout": "main"' && break; sleep 0.25; done
herdr-app "do" layout.switch --name jk >/dev/null || { echo "✗ layout.switch jk failed — herdr-app status:"; herdr-app status; exit 1; }
say "✓ layout jk (reloaded)"

open_folders=$(herdr-app ls | /usr/bin/python3 -c 'import json,sys; [print(s["folder"]) for s in json.load(sys.stdin)["spaces"] if not s.get("machine")]')
for entry in "${SPACES[@]}"; do
  name=${entry%%|*} folder=${entry#*|}
  [ -d "$folder" ] || { say "- $name: $folder missing, skipped"; continue; }
  if grep -qxF "$folder" <<<"$open_folders"; then say "· space $name (open)"; continue; fi
  herdr-app "do" space.new --name "$name" --folder "$folder" >/dev/null && say "✓ space $name"
done

# The mini: one space per repo classic herdr has open there, so the core mirrors the
# working set; jk-spaces files them into groups.json's folders. Spaces only — every
# agent stays in classic herdr until the move (docs/herdr-core.md §Decision).
if ! hc machine ls --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; sys.exit(not any(m["name"] == "mini" and m["state"] == "connected" for m in json.load(sys.stdin)["machines"]))'; then
  say "- mini not connected (hc machine ls) — mini spaces skipped"; exit 0
fi
mini_open=$(herdr-app ls | /usr/bin/python3 -c 'import json,sys; [print(s["folder"]) for s in json.load(sys.stdin)["spaces"] if s.get("machine") == "mini"]')
# label<TAB>path for each classic workspace that is a repo under ~/SourceRoot or ~/IuRoot.
mini_repos=$(ssh -o BatchMode=yes mini 'herdr workspace list' | /usr/bin/python3 -c 'import json,sys; [print(w["label"]) for w in json.load(sys.stdin)["result"]["workspaces"] if not w["label"].startswith("──")]' \
  | ssh -o BatchMode=yes mini 'while read -r l; do for r in "$HOME/SourceRoot" "$HOME/IuRoot"; do if [ -d "$r/$l/.git" ]; then printf "%s\t%s\n" "$l" "$r/$l"; break; fi; done; done')
while IFS=$'\t' read -r name folder; do
  [ -n "$name" ] || continue
  if grep -qxF "$folder" <<<"$mini_open"; then say "· mini space $name (open)"; continue; fi
  herdr-app "do" space.new --name "$name" --machine mini --folder "$folder" >/dev/null && say "✓ mini space $name"
done <<<"$mini_repos"

