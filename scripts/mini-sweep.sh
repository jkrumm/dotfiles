#!/usr/bin/env bash
# mini-sweep.sh — one read-only picture of the dev host, from the MacBook.
#
# The pieces already existed (devhost-health-check, drift-check, collie-status,
# the Kuma monitors); what did not was one command that puts them side by side.
# Assembling that by hand is how a maintenance round starts, and doing it by hand
# is how a red component gets missed.
#
# THE KUMA SECTION COMES FIRST, AND IT IS NOT DECORATION. It is read straight
# from Uptime Kuma's SQLite on homelab, which is reached over Tailscale SSH —
# keyless, so it works when the mini is down AND when 1Password is locked (the
# 1Password agent signs `ssh mini`, so a lock takes the whole host away from you;
# that happened three times while this script's own lessons were being learned).
# It is the only view of the dev host that survives the dev host.
#
# Read-only by construction: sqlite3 is opened `-readonly`, every remote command
# is a report, and nothing here upgrades, restarts or writes. The appliers are
# separate and attended — brew-upgrade, mini-macos-update, collie-upgrade.

set -uo pipefail   # NOT -e: a section that cannot run must degrade, not abort

HOST="${MINI_HOST:-mini}"
KUMA_HOST="${KUMA_HOST:-homelab}"
KUMA_DB="${KUMA_DB:-/home/jkrumm/ssd/uptime-kuma/kuma.db}"
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes)

rc=0
hdr() { printf '\n  \033[1m%s\033[0m\n' "$1"; }
bad() { rc=1; }

# --- 1. monitors (survives a dead mini / locked 1Password) --------------------
hdr "Uptime Kuma — MacMini monitors (via $KUMA_HOST, keyless)"
kuma_sql='SELECT m.name || "|" ||
  CASE h.status WHEN 1 THEN "UP  " ELSE "DOWN" END || "|" ||
  datetime(h.time) || "|" || substr(coalesce(h.msg,""),1,84)
  FROM monitor m JOIN heartbeat h
    ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1)
  WHERE m.name LIKE "%MacMini%" ORDER BY m.name;'
# shellcheck disable=SC2029  # both expand HERE on purpose: the db path and the query
kuma_out="$(ssh "${SSH_OPTS[@]}" "$KUMA_HOST" "sqlite3 -readonly '$KUMA_DB' '$kuma_sql'" 2>/dev/null)"
if [ -z "$kuma_out" ]; then
  echo "    · unavailable ($KUMA_HOST unreachable or sqlite3 missing) — not a dev-host fault"
else
  echo "$kuma_out" | while IFS='|' read -r name status when msg; do
    printf '    %-28s %s  %s utc  %s\n' "$name" "$status" "$when" "$msg"
  done
  # The `while` above runs in a subshell, so a bad() inside it could never reach
  # us. Tested here instead — and with `case`, not `grep -q`: under `pipefail` a
  # grep that exits early turns the writer's SIGPIPE into a false failure, a trap
  # this repo has already paid for twice.
  case "$kuma_out" in *"|DOWN|"*) bad ;; esac
fi

# --- 2. is the host even there ------------------------------------------------
hdr "Host"
if ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; then
  echo "    ✗ $HOST unreachable over ssh."
  echo "      Usually 1Password is LOCKED, not a network fault: its agent signs this key,"
  echo "      and it fails as 'signing failed … agent refused operation' → 'Permission denied"
  echo "      (publickey)'. Unlock it and re-run. The monitor rows above still told you"
  echo "      whether the host itself is healthy."
  bad
  exit "$rc"
fi
ssh "${SSH_OPTS[@]}" "$HOST" 'printf "    macOS %s, %s\n" "$(sw_vers -productVersion)" "$(uptime | sed "s/^ *//")"'
outdated="$(ssh "${SSH_OPTS[@]}" "$HOST" 'brew outdated --quiet 2>/dev/null | wc -l' | tr -d ' ')"
echo "    ${outdated:-?} outdated formula(e)/cask(s) — apply with: make brew-upgrade (on $HOST)"

# --- 3. the composite health check --------------------------------------------
hdr "devhost-health-check (on $HOST)"
health="$(ssh "${SSH_OPTS[@]}" "$HOST" 'cd ~/SourceRoot/dotfiles && make devhost-health-check 2>&1')"
health_rc=$?
echo "$health" | sed 's/^/    /' | grep -vE 'make(\[[0-9]+\])?: \*\*\*' | head -20
[ "$health_rc" -eq 0 ] || bad

# --- 4. drift (pins, brew recency, macOS) -------------------------------------
hdr "drift-check (on $HOST)"
drift="$(ssh "${SSH_OPTS[@]}" "$HOST" 'cd ~/SourceRoot/dotfiles && make drift-check 2>&1')"
drift_rc=$?
echo "$drift" | sed 's/^/    /' | grep -vE 'make(\[[0-9]+\])?: \*\*\*' | head -20
[ "$drift_rc" -eq 0 ] || bad

# --- verdict ------------------------------------------------------------------
echo ""
if [ "$rc" -eq 0 ]; then
  echo "  ✓ dev host clean"
else
  echo "  ✗ something above is red — the appliers are attended, one per fault:"
  echo "      brew/tailscale drift  → make brew-upgrade        (on $HOST)"
  echo "      macOS update pending  → make mini-macos-update    (here; never force the reboot)"
  echo "      collie pin drift      → make collie-upgrade       (on $HOST, needs a TTY)"
  echo "      xcaddy pin drift      → bump XCADDY_VERSION, make caddy-dns-build (on $HOST)"
  echo "      stale secrets cache   → make secrets-seed         (here, biometric)"
fi
exit "$rc"
