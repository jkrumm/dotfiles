#!/usr/bin/env bash
# Guarded auto-trigger for the 1Password vault backup (scripts/backup-1password.py).
#
# WHY A GUARD AND NOT JUST A SCHEDULE. The backup's first `op` call raises a
# biometric approval dialog — by design. There is no unattended path that does
# not involve minting an op service-account token or a long-lived OP_SESSION_*,
# i.e. putting a credential capable of exporting every vault onto a laptop's
# disk. So this never removes the human; it removes having to REMEMBER. The
# agent fires hourly, does nothing 23 times out of 24, and on the one fire that
# matters it asks — while you are demonstrably sitting there.
#
# WHY HOURLY AND NOT DAILY. A daily calendar fire lands at one fixed clock time.
# launchd does coalesce a fire missed while asleep into one run on wake, but a
# single daily fire that arrives at a locked screen is skipped and the next
# chance is 24h out — so a laptop that is shut on a given morning can drift red
# despite being open for hours that afternoon. StartCalendarInterval treats
# missing keys as wildcards, so a bare Minute means "every hour at :NN" with the
# same wake catch-up. Cost of a no-op fire is one stat(2).
#
# TWO STAMPS, TWO DIFFERENT JOBS.
#   last-success  gates freshness      (default 5 days — under the 8-day Kuma window)
#   last-attempt  gates re-prompting   (default 6 hours)
# The attempt stamp is the one that makes this tolerable to live with: a real
# attempt costs a Touch ID prompt, so declining one must not mean being asked
# again in 60 minutes, forever. Without it a single decline turns the agent into
# a nag and you learn to dismiss 1Password dialogs — the exact habit that makes
# automating this a net security LOSS rather than a gain.
#
# The same hourly agent also runs opbackup-seed-auto.sh. That guard checks the
# remote Mac mini cache independently (default max age 5 days), so a fresh full
# vault backup cannot suppress a due secrets-cache reseed.
#
# Every precondition below is ordered cheapest-first and exits 0, not 1: a
# skipped run is the normal case, not a failure, and launchd should not see it
# as one.

set -euo pipefail

STAMP_DIR="${OPBACKUP_STATE_DIR:-$HOME/.local/state/opbackup}"
SUCCESS_STAMP="$STAMP_DIR/last-success"
ATTEMPT_STAMP="$STAMP_DIR/last-attempt"

MAX_AGE_DAYS="${OPBACKUP_MAX_AGE_DAYS:-5}"
RETRY_HOURS="${OPBACKUP_RETRY_HOURS:-6}"
BACKUP_SCRIPT="${OPBACKUP_SCRIPT:-$HOME/SourceRoot/dotfiles/scripts/backup-1password.py}"
SEED_AUTO_SCRIPT="${OPBACKUP_SEED_AUTO_SCRIPT:-$HOME/SourceRoot/dotfiles/scripts/opbackup-seed-auto.sh}"
REMOTE_HOST="${OPBACKUP_REMOTE_HOST:-homelab}"
SEED_FAILED=0

FORCE=0
SEED_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--force)      FORCE=1 ;;
		--seed-stamp) SEED_ONLY=1 ;;
		*) echo "usage: $(basename "$0") [--force] [--seed-stamp]" >&2; exit 2 ;;
	esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') opbackup: $*"; }

skip() {
	log "skip — $*"
	if [ "$SEED_FAILED" -ne 0 ]; then
		exit "$SEED_FAILED"
	fi
	exit 0
}

notify() {
	# Best-effort. A LaunchAgent runs inside the Aqua session, so this reaches
	# Notification Center; it is deliberately non-fatal if it does not.
	/usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

age_seconds() {
	# mtime age of $1, or a very large number when the file is absent.
	local mtime now
	mtime=$(/usr/bin/stat -f '%m' "$1" 2>/dev/null || echo 0)
	now=$(date +%s)
	echo $(( now - mtime ))
}

screen_locked() {
	# No pipe on purpose: `set -o pipefail` plus a `grep -q` that exits early
	# turns the producer's SIGPIPE into a false failure (a trap this repo has
	# already paid for once, see CLAUDE.md). The key is absent entirely while
	# unlocked, and reads `= Yes` while locked.
	local out
	out=$(/usr/sbin/ioreg -n Root -d1 -k CGSSessionScreenIsLocked 2>/dev/null || true)
	case "$out" in
		*'"CGSSessionScreenIsLocked" = Yes'*) return 0 ;;
	esac
	return 1
}

# --- seed mode -------------------------------------------------------------
# Backdate the success stamp to the newest backup already on the remote, so
# installing the agent on a machine that is merely a few days stale does not
# fire a surprise prompt within the hour. Same prompt-hygiene reasoning as the
# attempt stamp.
if [ "$SEED_ONLY" -eq 1 ]; then
	mkdir -p "$STAMP_DIR"
	newest=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
		"ls -1 ~/backups/1password 2>/dev/null" 2>/dev/null \
		| sed -n 's/^1password-\([0-9-]\{10\}\)\.json\.age$/\1/p' | sort | tail -1) || true
	if [ -z "${newest:-}" ]; then
		log "seed — no remote backup found, leaving stamp unset (first run will trigger)"
		exit 0
	fi
	/usr/bin/touch -t "$(echo "$newest" | tr -d '-')1200" "$SUCCESS_STAMP"
	log "seed — success stamp backdated to $newest"
	exit 0
fi

# --- secrets-cache guard ---------------------------------------------------
# This is deliberately separate from the full-vault freshness gate above:
# either job being due is enough to justify one present-human run.
if [ -x "$SEED_AUTO_SCRIPT" ]; then
	if "$SEED_AUTO_SCRIPT"; then
		:
	else
		SEED_FAILED=$?
		log "secrets-cache seed failed (exit $SEED_FAILED); continuing with vault backup"
	fi
else
	log "secrets-cache guard missing: $SEED_AUTO_SCRIPT"
fi

# --- preconditions ---------------------------------------------------------

# 1. Present-human machine only. The cache backend means no interactive `op`,
#    so this agent has nothing to prompt and must never run there.
backend=$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")
[ "$backend" = "op" ] || skip "secrets backend is '${backend:-unset}', not 'op' (not a present-human machine)"

if [ "$FORCE" -eq 0 ]; then
	# 2. Still fresh — the overwhelmingly common case, and the only one that
	#    needs to be cheap.
	fresh_for=$(age_seconds "$SUCCESS_STAMP")
	if [ "$fresh_for" -lt $(( MAX_AGE_DAYS * 86400 )) ]; then
		skip "last backup $(( fresh_for / 86400 ))d old (< ${MAX_AGE_DAYS}d)"
	fi

	# 3. Backoff since the last real attempt.
	tried_ago=$(age_seconds "$ATTEMPT_STAMP")
	if [ "$tried_ago" -lt $(( RETRY_HOURS * 3600 )) ]; then
		skip "attempted $(( tried_ago / 60 ))m ago (backoff ${RETRY_HOURS}h)"
	fi

	# 4. Do not raise a modal at a lock screen — nobody is there to approve it,
	#    and a queued dialog waiting behind the lock is worse than no dialog.
	! screen_locked || skip "screen is locked"
fi

# 5. 1Password desktop must be running; `op` is a client of it.
/usr/bin/pgrep -x "1Password" >/dev/null 2>&1 || skip "1Password desktop is not running"

# 6. Reachability BEFORE the prompt. Failing at the rsync leg would mean having
#    spent a Touch ID approval and ~90s of op calls for nothing.
ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" true >/dev/null 2>&1 \
	|| skip "$REMOTE_HOST unreachable"

# --- run -------------------------------------------------------------------

mkdir -p "$STAMP_DIR"
: > "$ATTEMPT_STAMP"

log "running — last success $(( $(age_seconds "$SUCCESS_STAMP") / 86400 ))d ago"
notify "1Password backup" "Starting — approve the Touch ID prompt."

if "$BACKUP_SCRIPT"; then
	: > "$SUCCESS_STAMP"
	log "done"
	notify "1Password backup" "Complete — encrypted copy sent to $REMOTE_HOST."
	if [ "$SEED_FAILED" -ne 0 ]; then
		log "vault backup succeeded, but secrets-cache seed failed"
		exit "$SEED_FAILED"
	fi
	exit 0
fi

log "FAILED — see above; will retry after ${RETRY_HOURS}h"
notify "1Password backup failed" "Run 'opbackup' by hand, or see ~/Library/Logs/opbackup.log"
exit 1
