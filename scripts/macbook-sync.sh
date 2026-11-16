#!/bin/bash
# macbook-sync.sh — what the `dotfiles-sync` verb of scripts/iumac-gate.sh runs on the MacBook.
#
# Brings this dotfiles checkout level with origin/master and converges the config the pulled commits touched:
#   1. refuses unless the checkout is on master with a clean tree (the owner edits here; nothing is stashed);
#   2. fetches the public repo over https (no SSH identity: `ssh iumac` carries none) and fast-forwards only;
#   3. re-execs the pulled copy of this script (`--run <old> <new>`), which reads config/macbook-sync.tsv and runs
#      each `make` target whose path prefix the pulled range changed, once, in table order.
# No arguments. Exit 0 when the checkout is level and every target that ran passed; 1 on a refusal or a failed
# target (a failed target does not stop the later ones).
#
# Test seams (tests only; sshd never sets them): MACBOOK_SYNC_REMOTE replaces the https remote, MACBOOK_SYNC_LOG the
# log file. The checkout is the one this script sits in.
#
# Runs on the MacBook under /bin/bash 3.2: no associative arrays, no mapfile.
set -u

DOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${MACBOOK_SYNC_REMOTE:-https://github.com/jkrumm/dotfiles.git}"
LOG="${MACBOOK_SYNC_LOG:-$HOME/Library/Logs/macbook-sync.log}"
TABLE="$DOT/config/macbook-sync.tsv"

die() {
  printf 'macbook-sync: refused: %s\n' "$*" >&2
  exit 1
}

log() { # best effort, never fails the sync
  {
    mkdir -p "$(dirname "$LOG")"
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"
  } >/dev/null 2>&1 || true
}

# --- phase 2: converge what the range touched --------------------------------
if [ "${1:-}" = "--run" ]; then
  old="${2:-}"
  new="${3:-}"
  [[ "$old" =~ ^[0-9a-f]{40}$ && "$new" =~ ^[0-9a-f]{40}$ && $# -eq 3 ]] || die "bad range"
  [ -f "$TABLE" ] || die "no $TABLE"

  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:$PATH"

  changed="$(git -C "$DOT" diff --name-only "$old" "$new")"
  printf 'dotfiles %s..%s\n' "${old:0:7}" "${new:0:7}"
  log "pull ${old:0:7}..${new:0:7}"

  seen=" "
  rc=0
  while IFS=$'\t' read -r prefix target _; do
    case "$prefix" in '' | '#'*) continue ;; esac
    [[ "$prefix" =~ ^[A-Za-z0-9._/-]+$ && "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
      printf '  ! bad row in config/macbook-sync.tsv: %s\n' "$prefix"
      rc=1
      continue
    }
    case "$seen" in *" $target "*) continue ;; esac
    hit=""
    while IFS= read -r path; do
      case "$path" in "$prefix"*) hit=1 && break ;; esac # the prefix has no glob characters (checked above)
    done <<<"$changed"
    [ -n "$hit" ] || continue
    seen="$seen$target "
    printf '  make %s ...\n' "$target"
    if make -C "$DOT" "$target" >"${TMPDIR:-/tmp}/macbook-sync.$$.out" 2>&1; then
      printf '  ✓ %s\n' "$target"
      log "target $target ok"
    else
      printf '  ✗ %s (last lines):\n' "$target"
      tail -n 8 "${TMPDIR:-/tmp}/macbook-sync.$$.out" | sed 's/^/      /'
      log "target $target failed"
      rc=1
    fi
    rm -f "${TMPDIR:-/tmp}/macbook-sync.$$.out"
  done <"$TABLE"

  [ "$seen" != " " ] || printf '  no target for this range\n'
  exit "$rc"
fi

[ $# -eq 0 ] || die "takes no arguments"

# --- phase 1: refuse, fetch, fast-forward ---------------------------------------
cd "$DOT" || die "no checkout at $DOT"
branch="$(git symbolic-ref --short -q HEAD || true)"
[ "$branch" = "master" ] || die "the checkout is on ${branch:-a detached HEAD}, not master"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"

old="$(git rev-parse HEAD)"
git fetch --quiet "$REMOTE" master || die "fetch failed"
new="$(git rev-parse FETCH_HEAD)"

if [ "$old" = "$new" ] || git merge-base --is-ancestor "$new" "$old"; then
  printf 'dotfiles %s up to date\n' "${old:0:7}"
  exit 0
fi
git merge-base --is-ancestor "$old" "$new" || die "local master has commits origin/master lacks (diverged)"
git merge --ff-only --quiet "$new" || die "fast-forward failed"

# The pulled copy of this script does the rest: it may be newer than the one running.
exec bash "$DOT/scripts/macbook-sync.sh" --run "$old" "$new"
