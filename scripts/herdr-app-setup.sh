#!/usr/bin/env bash
# Converge the Herdr desktop app (herdr-core evaluation, MacBook) onto the tracked
# config: the `jk` layout (space folders, no agents list, CPU/MEM status bar), the
# pinned third-party space-folders mod, the folder seed, and one space per repo.
# Idempotent. docs/herdr-core.md §Desktop layout.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DOTFILES_DIR/config/herdr-app"
HOME_DIR="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"

# jankeesvw/herdr-space-folders has no license: cloned and linked, never vendored here.
# Bumping the pin = read the diff of main.js first (it runs trusted JS with exec).
FOLDERS_REPO="https://github.com/jankeesvw/herdr-space-folders.git"
FOLDERS_PIN="cb83ff4aeed32b674fb8fe66b183ae60fe8944f6"
FOLDERS_DIR="$HOME/.local/share/herdr-app-vendor/herdr-space-folders"

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

say "space-folders mod @ ${FOLDERS_PIN:0:7}"
[ -d "$FOLDERS_DIR/.git" ] || git clone -q "$FOLDERS_REPO" "$FOLDERS_DIR"
git -C "$FOLDERS_DIR" fetch -q origin "$FOLDERS_PIN" 2>/dev/null || git -C "$FOLDERS_DIR" fetch -q origin
git -C "$FOLDERS_DIR" -c advice.detachedHead=false checkout -q "$FOLDERS_PIN"

link "$FOLDERS_DIR/mods/space-folders" "$HOME_DIR/mods/space-folders"
link "$SRC/mods/jk-status" "$HOME_DIR/mods/jk-status"
link "$SRC/layouts/jk.json" "$HOME_DIR/layouts/jk.json"

# Seeded, not linked: the mod rewrites the file with tmp+mv, which would replace a symlink.
if [ -e "$HOME/.config/herdr-space-folders.json" ]; then say "· herdr-space-folders.json (kept, live wins)"
else cp "$SRC/space-folders.json" "$HOME/.config/herdr-space-folders.json"; say "✓ herdr-space-folders.json (seeded)"; fi

for mod in space-folders jk-status; do
  herdr-app check "$HOME_DIR/mods/$mod" >/dev/null || { echo "✗ herdr-app check $mod failed:"; herdr-app check "$HOME_DIR/mods/$mod"; exit 1; }
  say "✓ check $mod"
done

if ! herdr-app status >/dev/null 2>&1; then
  say "window not running — open Herdr and re-run to switch the layout and open the spaces"; exit 0
fi

herdr-app "do" layout.switch --name jk >/dev/null && say "✓ layout jk"

open_folders=$(herdr-app ls | /usr/bin/python3 -c 'import json,sys; [print(s["folder"]) for s in json.load(sys.stdin)["spaces"] if not s.get("machine")]')
for entry in "${SPACES[@]}"; do
  name=${entry%%|*} folder=${entry#*|}
  [ -d "$folder" ] || { say "- $name: $folder missing, skipped"; continue; }
  if grep -qxF "$folder" <<<"$open_folders"; then say "· space $name (open)"; continue; fi
  herdr-app "do" space.new --name "$name" --folder "$folder" >/dev/null && say "✓ space $name"
done
