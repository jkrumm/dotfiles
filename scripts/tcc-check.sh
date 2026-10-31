#!/usr/bin/env bash
set -u -o pipefail
# tcc-check — read-only: flag a LaunchAgent whose program macOS TCC cannot give a durable grant.
# docs/tcc.md. A Full Disk Access / Files-and-Folders grant is keyed on the program's resolved path plus its
# code requirement; an ad-hoc signature's requirement is its cdhash, so every new build silently loses the
# grant, and a versioned path (Cellar, Caskroom, claude/versions, releases/<sha>) moves on every upgrade.
# A flagged program must be classified in config/tcc-programs.json (launcher | no-grant) or the check fails.
# BASH 3.2 (doctor runs it on the system bash).

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LA_DIR="${TCC_CHECK_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
LIST="${TCC_CHECK_LIST:-$DOTFILES_DIR/config/tcc-programs.json}"
LAUNCHER="${TCC_CHECK_LAUNCHER:-$HOME/.local/libexec/herdr-core-launcher}"

launcher_real=$(realpath "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER")
fail=0
checked=0
flagged=0

classify() { jq -r --arg l "$1" '.programs[$l].class // empty' "$LIST" 2>/dev/null; }

for plist in "$LA_DIR"/*.plist; do
  [ -e "$plist" ] || continue
  label=$(basename "$plist" .plist)
  prog=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2>/dev/null)
  [ -n "$prog" ] || continue
  real=$(realpath "$prog" 2>/dev/null) || { printf '  · %s: program %s does not resolve (not checked)\n' "$label" "$prog"; continue; }
  checked=$((checked + 1))
  [ "$real" = "$launcher_real" ] && continue   # the launcher itself: the grant holder, never flagged
  why=""
  case "$real" in
    */Cellar/*|*/Caskroom/*|*/.local/share/claude/versions/*|*/releases/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) why="versioned path" ;;
  esac
  if [ -f "$real" ]; then
    # captured, not piped into grep -q: an early-exiting grep would SIGPIPE the producer and trip pipefail
    kind=$(file -b "$real" 2>/dev/null); sig=$(codesign -dv "$real" 2>&1)
    case "$kind" in *Mach-O*) case "$sig" in *Signature=adhoc*) why="${why:+$why, }ad-hoc signed" ;; esac ;; esac
  fi
  [ -n "$why" ] || continue
  flagged=$((flagged + 1))
  cls=$(classify "$label")
  if [ -z "$cls" ]; then
    printf '  ✗ %s: %s (%s) is not classified; add it to config/tcc-programs.json or run it through the launcher (docs/tcc.md)\n' "$label" "$real" "$why"
    fail=$((fail + 1))
  fi
done

# The core job must run through the launcher, and the launcher must exist.
core="$LA_DIR/com.jkrumm.herdr-core.plist"
if [ -f "$core" ]; then
  p0=$(/usr/libexec/PlistBuddy -c "Print :Program" "$core" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$core" 2>/dev/null)
  if [ "$p0" != "$LAUNCHER" ]; then
    printf '  ✗ com.jkrumm.herdr-core: program is %s, not the launcher (fix: make herdr-core-setup YES=1)\n' "$p0"
    fail=$((fail + 1))
  elif [ ! -x "$LAUNCHER" ]; then
    printf '  ✗ com.jkrumm.herdr-core: %s is missing (fix: make herdr-core-setup)\n' "$LAUNCHER"
    fail=$((fail + 1))
  fi
fi

# Jobs that run `op` must go through the launcher (its Full Disk Access supersedes the AppData prompt op raises).
OP_JOBS="com.jkrumm.opbackup"   # extend when another LaunchAgent starts calling op
for opjob in $OP_JOBS; do
  f="$LA_DIR/$opjob.plist"
  [ -f "$f" ] || continue
  p0=$(/usr/libexec/PlistBuddy -c "Print :Program" "$f" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$f" 2>/dev/null)
  if [ "$p0" != "$LAUNCHER" ]; then
    printf '  ✗ %s: runs op but its program is %s, not the launcher (fix: make opbackup-setup)\n' "$opjob" "$p0"
    fail=$((fail + 1))
  fi
done

if [ "$fail" -eq 0 ]; then
  printf '  ✓ tcc: %s LaunchAgent programs checked, %s flagged and all classified\n' "$checked" "$flagged"
  exit 0
fi
exit 1
