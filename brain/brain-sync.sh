#!/usr/bin/env bash
# Continuous sync of the brain vault through GitHub — every 5 minutes under
# launchd (com.jkrumm.brain-sync) on BOTH the mini and the MacBook.
#
# GitHub is the hub and this script is the ONLY thing that pushes to it. The
# obsidian-git plugin is deliberately not installed: a plugin auto-committing on
# its own timer alongside a LaunchAgent doing the same is two committers racing
# for .git/index.lock, which is obsidian-git's single most-reported failure. One
# mechanism, one lock, one place to look when it breaks.
#
# Two roles, auto-detected from the secrets-backend marker (`cache` = the mini,
# `op` = the MacBook) — the same signal remote-dev.sh routes off, so there is
# exactly one definition of "which machine am I" across this setup:
#
#   source (mini)     pull --rebase --autostash, then push if the branch is
#                     ahead. It NEVER commits. Committing on the mini stays
#                     deliberate: Claude Code sessions commit their own work and
#                     the nightly brain-backup.sh (03:30) sweeps whatever they
#                     left dirty. The pull is what makes MacBook edits show up;
#                     the conditional push rescues a session that committed and
#                     never pushed.
#   mirror (MacBook)  pull, commit any dirty tree, push. Nothing else on this
#                     machine tends the vault, so if this does not commit,
#                     nothing does.
#
# Conflicts are never auto-resolved — the rebase is aborted and a human picks
# the side. Full access model: ~/SourceRoot/brain/docs/brain-access.md.
set -euo pipefail

# launchd hands agents a minimal PATH — make sure git/security/curl resolve
# either way. ~/.local/bin is where `claude` and `secrets-run` live (neither is
# Homebrew-managed); without it the claude call below silently misses and every
# commit gets the literal fallback message instead of a generated one. This is
# the same export brain-backup.sh needs, for the same reason.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# A credential prompt under launchd is a hang, not a question: there is no
# terminal to answer it and the job would sit there holding the lock until the
# next reboot. Fail fast instead.
export GIT_TERMINAL_PROMPT=0

# GIT_TERMINAL_PROMPT only covers HTTPS credential prompts, and this vault's
# remote is SSH — so a stalled handshake or a black-holed route hangs git
# forever. launchd does not kill StartInterval jobs, so that one process would
# hold the lock and every later tick would quietly skip with no heartbeat at
# all: dead sync, no red light, until the missed-beat alert. BatchMode kills the
# passphrase prompt, ConnectTimeout kills the black hole.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}"

# This MacBook has NO key files in ~/.ssh — GitHub auth goes through the
# 1Password SSH agent. launchd hands agents the *system* ssh-agent socket
# (/var/run/com.apple.launchd.*/Listeners), which holds none of those keys, so
# every tick died with "Please make sure you have the correct access rights"
# until this was added. Point at 1Password's socket when it exists; machines
# that use an ordinary key (the mini) have no such socket and keep whatever
# launchd gave them.
OP_AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
if [ -S "$OP_AGENT_SOCK" ]; then
  export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
fi

# Belt to that braces: bound the network calls themselves. `timeout` is
# coreutils, not macOS base, so degrade to running them bare when it is absent.
NET=()
command -v timeout >/dev/null 2>&1 && NET=(timeout 120)

# Resolved BEFORE the cd into the vault, because $BASH_SOURCE is relative when
# the script is invoked by a relative path and dirname would then point at the
# vault instead of at dotfiles/brain.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One line every 5 minutes into an append-only log is unreadable without a
# timestamp — unlike the nightly backup, "which run was this?" is a real question here.
log()  { printf '%s brain-sync: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
warn() { log "$*" >&2; }

# --- arguments ---------------------------------------------------------------

ROLE=""
for arg in "$@"; do
  case "$arg" in
    --role=source|--role=mirror) ROLE="${arg#--role=}" ;;
    *) warn "unknown argument '$arg' (expected --role=source|--role=mirror)"; exit 2 ;;
  esac
done

# --- vault guards ------------------------------------------------------------
#
# Quiet exit 0, not an error: `make setup` may run on a machine that has no
# vault, and a LaunchAgent that reports failure every 5 minutes on such a
# machine trains you to ignore the log.

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
cd "$VAULT" 2>/dev/null || { log "vault not found at $VAULT — skipping"; exit 0; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { log "$VAULT is not a git work tree — skipping"; exit 0; }

GIT_DIR="$(git rev-parse --git-dir)"

# --- heartbeat ---------------------------------------------------------------
#
# Third caller of the shared lib — exactly what it was extracted for. Unlike the
# health-check scripts a missing push URL is NOT an error here: sync must work on
# a machine that never got a Kuma monitor. The URL file is the established
# mini-local convention (chmod 600, outside the secrets cache: a monitor must not
# depend on the thing it monitors).
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/kuma-push.sh
source "$SCRIPT_DIR/../scripts/lib/kuma-push.sh"

PUSH_URL_FILE="${BRAIN_SYNC_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/brain-sync-push-url}"
push_url=""
if [ -n "${BRAIN_SYNC_PUSH_URL:-}" ] || [ -f "$PUSH_URL_FILE" ]; then
  push_url="$(kuma_resolve_push_url "${BRAIN_SYNC_PUSH_URL:-}" "$PUSH_URL_FILE")" || push_url=""
fi

# Non-fatal on purpose: a heartbeat that cannot be delivered must not take the
# sync down with it. Kuma's own missed-heartbeat alert covers the silence.
beat() { [ -n "$push_url" ] && kuma_push "$push_url" "$1" "$2" >/dev/null 2>&1 || true; }

# Set by fail() and by the final success beat, and read by the EXIT trap so a
# specific message is never clobbered by the trap's generic one.
beat_sent=""

fail() { warn "$*"; beat down "$*"; beat_sent="yes"; exit 1; }

# --- single instance ---------------------------------------------------------
#
# launchd coalesces StartInterval firings for a running job, but a manual run,
# a `launchctl kickstart`, or a run that outlives its interval are all real —
# and two of these pushing at once is a force-push argument nobody wants to have.
# mkdir is the atomic primitive here; flock is Linux-only and shlock's PID file
# has the same reuse problem without the liveness check.

LOCK_DIR="${BRAIN_SYNC_LOCK_DIR:-$HOME/Library/Caches/brain-sync.lock}"

# `mkdir` is the atomic primitive: it fails if the directory exists, and unlike
# a PID file it cannot half-exist. Do NOT be tempted to build the lock elsewhere
# and `mv` it into place to close the write-the-pid-afterwards window — `mv` of
# a directory ONTO an existing directory succeeds by moving it INSIDE, so the
# lock silently never detects a held lock at all. (Found by testing exactly
# that: a live holder was ignored and two runs proceeded together.)
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  # `kill -0` returns EPERM — not ESRCH — for a live pid owned by another user,
  # and cannot tell the two apart. A pid absent from `ps` is genuinely gone,
  # whoever owns it.
  if [ -n "$holder" ] && ps -p "$holder" >/dev/null 2>&1; then
    # Not a failure and deliberately not a DOWN beat: the run that holds the
    # lock is alive and will beat for both of us.
    log "another run (pid $holder) still going — skipping this tick"
    exit 0
  fi
  # A lock with no pid file is ambiguous: either a run that died between mkdir
  # and the write, or one that is *mid-publish right now*. Age decides. Treating
  # a fresh pidless lock as abandoned is how two runs end up sharing it — and
  # then the first one's EXIT trap deletes the second's lock and admits a third.
  lock_born="$(stat -f %m "$LOCK_DIR" 2>/dev/null || true)"
  lock_age=$(( $(date +%s) - ${lock_born:-0} ))
  if [ -z "$holder" ] && [ "$lock_age" -lt 60 ]; then
    log "$LOCK_DIR has no pid yet and is only ${lock_age}s old — another run is claiming it; skipping this tick"
    exit 0
  fi
  warn "reclaiming the lock left by pid ${holder:-unknown} (${lock_age}s old) — no such process, so the previous run was killed mid-flight"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || { warn "lost the race for $LOCK_DIR — another run took it; skipping this tick"; exit 0; }
fi
printf '%s' "$$" >"$LOCK_DIR/pid"
# Any death under `set -e` — a rejected commit hook, a full disk, an unreadable
# file — would otherwise exit non-zero having sent NO heartbeat, which on Kuma
# is indistinguishable from a MacBook with a closed lid. Only a NON-ZERO exit
# beats DOWN, so the deliberate quiet exits above (no vault, not a work tree,
# lock held by a live run) stay silent; and `fail` sets beat_sent so its
# specific message is not immediately overwritten by this generic one.
on_exit() {
  local st=$?
  if [ "$st" -ne 0 ] && [ -z "$beat_sent" ]; then
    beat down "unexpected failure (exit $st) — see ~/Library/Logs/brain-sync.log"
  fi
  rm -rf "$LOCK_DIR"
}
trap on_exit EXIT
trap 'warn "aborting on an unhandled error at line $LINENO"' ERR

# --- role --------------------------------------------------------------------
#
# Hard error rather than a default. Guessing wrong in one direction turns the
# mini into a committer (the thing this design exists to avoid); guessing wrong
# in the other leaves MacBook edits uncommitted and invisible until someone
# notices weeks of work never left the laptop.

if [ -z "$ROLE" ]; then
  MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
  case "$(cat "$MARKER" 2>/dev/null || true)" in
    cache) ROLE="source" ;;
    op)    ROLE="mirror" ;;
    *)     fail "cannot determine role: $MARKER is missing or holds an unknown backend — pass --role=source|mirror" ;;
  esac
fi

# --- stale index.lock --------------------------------------------------------
#
# A crashed git leaves .git/index.lock behind and every later run fails on it
# until someone clears it by hand — which for a 5-minute agent means silence
# until the missed-heartbeat alert. Clearing it is only safe when the owner is
# gone, and there is no owner recorded in the file, so age is the proxy: any git
# operation on this vault finishes in well under a second, so a five-minute-old
# lock is a corpse. A FRESH one is never touched — that would corrupt a live
# commit from brain-backup's 03:30 sweep or a Claude Code session.

INDEX_LOCK="$GIT_DIR/index.lock"
if [ -e "$INDEX_LOCK" ]; then
  lock_mtime="$(stat -f %m "$INDEX_LOCK" 2>/dev/null || true)"
  lock_age=$(( $(date +%s) - ${lock_mtime:-$(date +%s)} ))
  if [ "$lock_age" -gt 300 ]; then
    warn "clearing a stale $INDEX_LOCK (${lock_age}s old — left behind by a crashed git)"
    rm -f "$INDEX_LOCK"
  else
    log "$INDEX_LOCK is only ${lock_age}s old — a live git owns it; skipping this tick"
    exit 0
  fi
fi

# --- pull --------------------------------------------------------------------

git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
  || fail "no upstream branch configured for $(git rev-parse --abbrev-ref HEAD) — this clone cannot sync"

pull_rc=0
pull_out="$("${NET[@]}" git pull --rebase --autostash 2>&1)" || pull_rc=$?

# THE trap in this script. `git pull --rebase --autostash` exits ZERO when the
# rebase succeeds but re-applying the autostash conflicts — git reports it as a
# warning, not a failure. Trusting the exit code alone means the mirror walks
# straight into `git add -A`, commits a file full of <<<<<<< markers, pushes it
# to origin and beats UP; and the source leaves the same wreckage in place with
# a green monitor and an orphan stash nobody is told about. Unmerged paths are
# the ground truth, so ask git for them directly rather than reading its prose.
if [ -n "$(git ls-files --unmerged)" ]; then
  unmerged="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  # --abort only applies while a rebase is actually in progress. After a clean
  # rebase whose autostash failed to re-apply, the conflict lives in the working
  # tree with the stash still on the stack — nothing to abort, and throwing the
  # tree away would discard the local edit. Leave it for hands, and say where.
  if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
    git rebase --abort 2>/dev/null \
      || warn "git rebase --abort failed — $VAULT is stuck mid-rebase and needs hands"
    fail "REBASE CONFLICT against origin — aborted, tree untouched. Resolve by hand in $VAULT: ${unmerged}"
  fi
  stashes="$(git stash list | head -1)"
  warn "$pull_out"
  fail "AUTOSTASH CONFLICT — the rebase landed but your local edits could not be re-applied. NOT committing. Fix by hand in $VAULT: ${unmerged}${stashes:+ (parked: $stashes)}"
fi

if [ "$pull_rc" -ne 0 ]; then
  pull_tail="$(printf '%s' "$pull_out" | tail -3 | tr '\n' ' ')"
  if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
    # Never attempt auto-resolution. Both sides are somebody's prose and a
    # machine picking one is data loss that looks like a successful sync.
    # --abort restores the autostash too, so the tree is left exactly as it was.
    git rebase --abort 2>/dev/null \
      || warn "git rebase --abort failed — $VAULT is stuck mid-rebase and needs hands"
    # The CONFLICT lines name the files, which is the only part of git's output
    # worth carrying into a 60-character Kuma message; `tail` alone lands on
    # git's advice hints.
    conflicts="$(printf '%s\n' "$pull_out" | grep '^CONFLICT' | tr '\n' ' ' || true)"
    fail "REBASE CONFLICT against origin — aborted, tree untouched. Resolve by hand in $VAULT: ${conflicts:-$pull_tail}"
  fi
  # No rebase in progress: offline, auth, or the autostash failed to re-apply
  # after an otherwise clean rebase — in that last case the work is safe but
  # parked, hence the pointer at the stash list.
  fail "git pull failed (offline? auth? check 'git stash list' for a parked autostash): $pull_tail"
fi

# --- commit (mirror only) ----------------------------------------------------

# The login keychain is unreadable to a launchd job whose GUI session is locked
# or absent, and `security` then just fails. Fall back to `secrets-run read` on
# the same op:// refs `make setup` cached these entries from. Missing credentials
# stay non-fatal: a generated commit message is a nicety, and refusing to sync
# the vault over it would be the worse failure. Deliberately duplicated from
# brain-backup.sh rather than shared — six lines beats a third file that both
# LaunchAgents would then depend on.
keychain_or_cache() {
  local v
  v=$(security find-generic-password -s "$1" -w 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  command -v secrets-run >/dev/null 2>&1 || return 0
  v=$(secrets-run read "$2" 2>/dev/null) && printf '%s' "$v"
}

# A hung `claude -p` would hold the single-instance lock indefinitely and stall
# every later tick, so the call is bounded when a timeout binary exists. It is
# coreutils, not macOS base, hence the graceful degrade — and the runner is
# never an empty array, because launchd resolves `env bash` against ITS PATH and
# lands on bash 3.2, where "${empty[@]}" trips `set -u`.
commit_message() {
  local key base prompt msg runner=(env)
  command -v timeout >/dev/null 2>&1 && runner=(timeout 90 env)

  key="$(keychain_or_cache claude-sdk-api-key op://common/anthropic/API_KEY || true)"
  base="$(keychain_or_cache claude-sdk-base-url op://common/anthropic/BASE_URL || true)"

  if [ -z "$key" ] || [ -z "$base" ]; then
    warn "IU credential unresolvable (Keychain claude-sdk-* and secrets-run both failed) — using the fallback commit message"
    printf '%s' "chore(brain): vault sync"
    return 0
  fi

  prompt="Write ONE git commit message line, conventional-commits format
'type(scope): description' (imperative mood, no trailing period, no AI
attribution), summarizing this diff to a personal Obsidian vault. Scope is
usually 'brain'. Output ONLY the commit message line, nothing else.

$(git diff --cached --stat)

$(git diff --cached | head -c 20000 || true)"

  msg="$(printf '%s' "$prompt" | "${runner[@]}" -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    claude -p --model haiku --dangerously-skip-permissions 2>/dev/null \
    | tail -1 | tr -d '\r' || true)"

  if [ -z "$msg" ]; then
    warn "claude produced no message (is 'claude' on PATH? did the call time out?) — using the fallback"
    msg="chore(brain): vault sync"
  fi
  printf '%s' "$msg"
}

summary="pulled"

if [ "$ROLE" = "mirror" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    # git add -A respects .gitignore, so plugin data.json files and anything
    # else excluded there stay out of the commit.
    git add -A
    if git diff --cached --quiet; then
      log "only ignored or empty changes — nothing to commit"
    else
      msg="$(commit_message)"
      git commit -q -m "$msg"
      log "committed: $msg"
      summary="$summary, committed"
    fi
  fi
elif [ -n "$(git status --porcelain)" ]; then
  # Source role never commits — say so rather than looking like it missed something.
  log "tree is dirty; leaving it for a session commit or the 03:30 brain-backup sweep"
fi

# --- push --------------------------------------------------------------------

ahead="$(git rev-list --count '@{u}..HEAD')"
if [ "$ahead" -gt 0 ]; then
  "${NET[@]}" git push -q || fail "push failed with $ahead commit(s) waiting — origin unreachable or the branch diverged"
  log "pushed $ahead commit(s)"
  summary="$summary, pushed $ahead"
else
  summary="$summary, nothing to push"
fi

log "$ROLE: $summary"
beat up "$ROLE: $summary"
beat_sent="yes"
