#!/usr/bin/env bash
set +x
set -euo pipefail

# drift-check — reports what on this machine has fallen behind upstream, and
# fixes NOTHING. Pushed to its own Uptime Kuma monitor (`MacMini Drift - Push`).
#
# WHY THIS EXISTS. Two halves of the update story were already built and the
# middle was missing. `make brew-upgrade` is a guarded upgrader that asserts its
# own invariants afterwards; devhost-health-check.sh is a 300s heartbeat that
# fails loudly. Neither ever says "a pin has drifted" — so the collie plugin sat
# FIVE releases behind (0.17.0 → 0.22.0, two of them security fixes on a
# shell-equivalent surface) and was found by hand, months later, by accident.
# That is the gap this closes: notice, not repair.
#
# WHY IT DOES NOT SELF-HEAL, DELIBERATELY. The hazard on this machine is not a
# compromised release — scripts/brew-upgrade.sh spends forty lines establishing
# that, and it is right. The hazard is SILENT CONFIG REVERT: caddy loses its DNS
# module and nothing fails for ~60 days; colima's plist reverts and nothing fails
# until the next power cut. An unattended upgrader on the host that runs herdr,
# colima, sideclaw, Hermes and every dev door is a mechanism for introducing
# exactly that class of fault at 3am with nobody watching. So this reports and a
# human applies — the same trade the caddy pin already makes, and the same one
# the runaway reaper in devhost-health-check.sh makes when it refuses to kill.
#
# WHY ITS OWN SCHEDULER, when "one scheduler, N monitors" is the house rule that
# gave collie and secrets-freshness their monitors without a second LaunchAgent:
# every check in here is a NETWORK call — GitHub for the pins, Apple's own scan
# results for the OS. devhost-health-check.sh runs every 300s with maxretries 0
# and deliberately refuses to call GitHub for exactly this reason (see its
# check_git_push comment): a GitHub outage or a flaky link would page as "dev
# host down". Drift moves on a scale of days, so it gets a daily agent instead,
# and a network failure here degrades to "skipped", never to a page.
#
# WHY AGE GRACE RATHER THAN A BARE "IS IT BEHIND". A monitor that goes red the
# day upstream tags a release, for something you will look at next week, is a
# NAG — and this repo has already paid for that lesson once: the 1Password
# backup monitor "had spent large stretches red as a nag, which is how you train
# yourself to ignore it". So a drifted pin is reported in the msg immediately and
# only FAILS once it has been drifted for DRIFT_GRACE_DAYS. The clock is keyed on
# the component, not on the version, so a fast-releasing upstream cannot keep
# resetting it back to zero.
#
# BASH 3.2. Same constraint as devhost-health-check.sh and for the same reason:
# the plist sets no PATH, launchd hands over /usr/bin:/bin:/usr/sbin:/sbin, and
# `/usr/bin/env bash` there is Apple's 3.2. No mapfile, no ${var,,}, no
# "${arr[@]}" on a possibly-empty array under `set -u`. Newline-delimited strings
# instead of arrays throughout.

# --no-push: for an on-demand caller (scripts/doctor.sh) that wants the same
# report without touching Kuma — the daily agent is still the only thing that
# pushes on a schedule. No other flags exist; anything else is a usage error.
NO_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --no-push) NO_PUSH=1 ;;
    *) echo "usage: $(basename "$0") [--no-push]" >&2; exit 1 ;;
  esac
done

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Read by makefile_var() in lib/github-tags.sh, not directly here.
# shellcheck disable=SC2034
MAKEFILE="${DRIFT_MAKEFILE:-$DOTFILES_DIR/Makefile}"

# Absolute paths: a LaunchAgent has no shell profile, and `tailscale`-style
# aliases do not exist for it. brew in particular is NOT on launchd's PATH.
GIT_BIN="${GIT_BIN:-/usr/bin/git}"
BREW_BIN="${BREW_BIN:-/opt/homebrew/bin/brew}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
DATE_BIN="${DATE_BIN:-/bin/date}"
DEFAULTS_BIN="${DEFAULTS_BIN:-/usr/bin/defaults}"

STATE_DIR="${DRIFT_STATE_DIR:-$HOME/.local/state/drift-check}"
FIRST_SEEN_FILE="$STATE_DIR/first-seen"
BREW_UPGRADE_STAMP="${BREW_UPGRADE_STAMP:-$HOME/.local/state/brew-upgrade/last-success}"

DRIFT_GRACE_DAYS="${DRIFT_GRACE_DAYS:-14}"
BREW_UPGRADE_MAX_AGE_DAYS="${BREW_UPGRADE_MAX_AGE_DAYS:-30}"

PUSH_URL_FILE="${DRIFT_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/drift-push-url}"

# shellcheck source=lib/kuma-push.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/kuma-push.sh"

NOW=$("$DATE_BIN" -u +%s)

# Accumulators. Newline-delimited (bash 3.2), each entry `key<TAB>description`.
DRIFTED=""
SKIPPED=""
INFO=""

drift_add() { DRIFTED="${DRIFTED}${1}	${2}
"; }
skip_add()  { SKIPPED="${SKIPPED}${1}
"; }
info_add()  { INFO="${INFO}${1}
"; }

# --- Makefile pin readers + remote tag resolution ----------------------------
# makefile_var / remote_tags / latest_tag / tag_commit live in the shared lib,
# because scripts/collie-upgrade.sh needs the same annotated-tag peel to APPLY
# what this file REPORTS — and two implementations of that peel is two chances
# to get it backwards. See the lib header for why that failure is invisible.
# shellcheck source=lib/github-tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/github-tags.sh"
# shellcheck source=lib/tailscale-cli.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tailscale-cli.sh"
trap 'gh_tags_cleanup' EXIT

# --- Checks ------------------------------------------------------------------

# A commit-pinned herdr plugin. There is no `plugin update` — upgrading is a
# reviewed diff of the pin — so nothing anywhere notices these moving.
check_pinned_commit() {
  local key="$1" repo="$2" pinned="$3" fixup="$4" latest sha
  [[ -n "$pinned" ]] || { skip_add "$key (pin unreadable in Makefile)"; return; }
  latest=$(latest_tag "$repo") || { skip_add "$key (github unreachable)"; return; }
  [[ -n "$latest" ]] || { skip_add "$key (no tags found)"; return; }
  sha=$(tag_commit "$repo" "$latest") || { skip_add "$key (tag $latest unresolvable)"; return; }
  if [[ "$sha" == "$pinned" ]]; then
    info_add "$key current ($latest)"
  else
    drift_add "$key" "$key → $latest (pin ${pinned:0:7}, fix: $fixup)"
  fi
}

# A version-pinned Go module built into the caddy binary by `make caddy-dns-build`.
# Compared by tag name, since these pins are versions rather than commits.
check_pinned_version() {
  local key="$1" repo="$2" pinned="$3" fixup="$4" latest
  [[ -n "$pinned" ]] || { skip_add "$key (pin unreadable in Makefile)"; return; }
  latest=$(latest_tag "$repo") || { skip_add "$key (github unreachable)"; return; }
  [[ -n "$latest" ]] || { skip_add "$key (no tags found)"; return; }
  if [[ "$latest" == "$pinned" ]]; then
    info_add "$key current ($latest)"
  else
    drift_add "$key" "$key $pinned → $latest (fix: $fixup)"
  fi
}

# NOT "is anything outdated" — homebrew/core moves daily, so that is true almost
# always and would sit red permanently, which is the nag failure this file's
# header rejects. The alertable fact is that the guarded upgrader has not been
# RUN. Counts still ride along in the msg as context.
check_brew() {
  local outdated casks_n core_n age mtime
  if [[ ! -x "$BREW_BIN" ]]; then skip_add "brew (not installed)"; return; fi
  outdated=$("$BREW_BIN" outdated --quiet 2>/dev/null) || { skip_add "brew (outdated query failed)"; return; }
  core_n=$(echo "$outdated" | /usr/bin/grep -c . || true)
  casks_n=$("$BREW_BIN" outdated --cask --quiet 2>/dev/null | /usr/bin/grep -c . || true)
  info_add "brew: ${core_n} outdated (${casks_n} cask)"

  if [[ -f "$BREW_UPGRADE_STAMP" ]]; then
    mtime=$(/usr/bin/stat -f %m "$BREW_UPGRADE_STAMP" 2>/dev/null) || mtime=0
  else
    mtime=0
  fi
  if (( mtime == 0 )); then
    drift_add "brew-upgrade" "brew-upgrade has never run (fix: make brew-upgrade)"
    return
  fi
  age=$(( (NOW - mtime) / 86400 ))
  if (( age > BREW_UPGRADE_MAX_AGE_DAYS )); then
    drift_add "brew-upgrade" "brew-upgrade ${age}d ago (max ${BREW_UPGRADE_MAX_AGE_DAYS}d, fix: make brew-upgrade)"
  else
    info_add "brew-upgrade ${age}d ago"
  fi
}

# Reads macOS's OWN cached scan results, not `softwareupdate -l`. That command
# takes tens of seconds and hits Apple; the background scan already ran (the
# LastSuccessfulBackgroundMSUScanDate key), so the answer is sitting in a plist
# and costs nothing. Read-only either way.
check_macos() {
  local out
  out=$("$DEFAULTS_BIN" read /Library/Preferences/com.apple.SoftwareUpdate RecommendedUpdates 2>/dev/null) || {
    info_add "macOS: no pending updates"
    return
  }
  local names
  names=$(echo "$out" | /usr/bin/sed -n 's/.*"Display Name" = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' \
    | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//; s/\\\{1,\}U00a0/ /g')
  if [[ -z "$names" ]]; then
    info_add "macOS: no pending updates"
  else
    drift_add "macos" "macOS update pending: $names (needs a restart window)"
  fi
}

# Tailscale version drift. The mini's client was in a blind spot that only
# became visible on 2026-08-05: it ran the STANDALONE (macsys) build, which
# `brew outdated` never saw and macOS software update never saw, while the two
# apt-managed Linux servers surfaced in their own tooling. Nothing reported that
# it sat two minor versions behind through five SSH CVEs.
#
# On 2026-08-06 that host moved to the brew tailscaled daemon precisely so its
# updates ride `brew upgrade` like everything else. Both variants are still
# handled here, because the MacBook remains on the App Store build and a check
# that only understood one shape would silently skip on the other.
#
# THE INSTALLED VERSION COMES FROM THE RUNNING CLI, never from a bundle plist.
# Reading Info.plist was correct only while the app WAS the daemon; on the mini
# that bundle is now dormant-but-present (kept for rollback) and would report
# 1.98.9 forever on a host actually running 1.102.2. Ask the thing that serves
# traffic, not the thing that happens to be on disk.
#
# It REPORTS and never applies, and the 14-day grace is what makes that
# tolerable. For the Sparkle variant a release can legitimately be days out
# before this host's rollout cohort is reached; forcing past that on the one
# machine whose only access path IS Tailscale cost an outage and changed no
# version (2026-08-05). Silent while a rollout is in progress, alerting once it
# is genuinely stuck.
check_tailscale() {
  local installed latest key
  [[ -n "$TAILSCALE_BIN" ]] || { skip_add "tailscale (no CLI found)"; return; }

  installed=$(ts_run version 2>/dev/null | /usr/bin/head -1 | /usr/bin/tr -d ' ')
  [[ -n "$installed" ]] || { skip_add "tailscale (running version unreadable)"; return; }

  # The App Store build updates on Apple's schedule and cannot be advanced
  # locally, so comparing it against any channel here would report drift no
  # action can resolve. Report the version, do not police it.
  if [[ -d /Applications/Tailscale.app/Contents/_MASReceipt \
        && "$TAILSCALE_BIN" != "/opt/homebrew/bin/tailscale" ]]; then
    info_add "tailscale $installed (App Store build — updates via the App Store)"
    return
  fi

  # MacZipsVersion is the standalone (macsys) channel; `Version` is the
  # cross-platform headline that the brew formula tracks. Picking the wrong key
  # reports drift on a host already current for its own channel.
  if [[ "$TAILSCALE_BIN" == "/opt/homebrew/bin/tailscale" ]]; then
    key="Version"
  else
    key="MacZipsVersion"
  fi

  latest=$(/usr/bin/curl -fsS --max-time 8 "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null \
    | "$PYTHON_BIN" -c "import json,sys; d=json.load(sys.stdin); print(d.get('$key') or d.get('Version') or '')" 2>/dev/null) || latest=""
  [[ -n "$latest" ]] || { skip_add "tailscale (pkgs.tailscale.com unreachable)"; return; }

  if [[ "$installed" == "$latest" ]]; then
    info_add "tailscale current ($installed, $TAILSCALE_VARIANT)"
  elif [[ "$TAILSCALE_BIN" == "/opt/homebrew/bin/tailscale" ]]; then
    drift_add "tailscale" "tailscale $installed → $latest (fix: make brew-upgrade)"
  else
    drift_add "tailscale" "tailscale $installed → $latest (Sparkle auto-update has not applied it; if this persists the rollout cohort is stuck — apply via scripts/detached-run.sh, NEVER a bare ssh command)"
  fi
}

# --- Run ---------------------------------------------------------------------
check_pinned_commit  collie       AltanS/collie             "$(makefile_var COLLIE_REF)"      "bump COLLIE_REF + COLLIE_VERSION, then make collie-setup"
check_pinned_version xcaddy       caddyserver/xcaddy        "$(makefile_var XCADDY_VERSION)"  "bump XCADDY_VERSION, then make caddy-dns-build"
check_pinned_version caddy-dns    caddy-dns/cloudflare      "$(makefile_var CADDY_DNS_MODULE_VERSION)" "bump CADDY_DNS_MODULE_VERSION, then make caddy-dns-build"
check_brew
check_macos
check_tailscale

# --- Age grace ---------------------------------------------------------------
# first-seen is rewritten each run: entries for keys that are no longer drifted
# are dropped, so resolving a drift resets its clock. Keyed on the COMPONENT,
# never the version — keying on the version would let a fast-releasing upstream
# reset the clock to zero forever and the grace would never expire.
/bin/mkdir -p "$STATE_DIR" 2>/dev/null || true
NEW_FIRST_SEEN=""
STALE=""
FRESH=""

while IFS=$'\t' read -r key desc; do
  [[ -n "$key" ]] || continue
  seen=""
  if [[ -f "$FIRST_SEEN_FILE" ]]; then
    seen=$(/usr/bin/awk -F'\t' -v k="$key" '$1==k {print $2}' "$FIRST_SEEN_FILE" | /usr/bin/head -1)
  fi
  [[ -n "$seen" ]] || seen="$NOW"
  NEW_FIRST_SEEN="${NEW_FIRST_SEEN}${key}	${seen}
"
  age_d=$(( (NOW - seen) / 86400 ))
  if (( age_d >= DRIFT_GRACE_DAYS )); then
    STALE="${STALE}${desc} [${age_d}d]
"
  else
    FRESH="${FRESH}${desc} [${age_d}d]
"
  fi
done <<EOF
$DRIFTED
EOF

printf '%s' "$NEW_FIRST_SEEN" >"$FIRST_SEEN_FILE" 2>/dev/null || true

# --- Report ------------------------------------------------------------------
join_lines() { printf '%s' "$1" | /usr/bin/grep -v '^$' | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//; s/;/; /g'; }

stale_n=$(printf '%s' "$STALE" | /usr/bin/grep -c . || true)
fresh_n=$(printf '%s' "$FRESH" | /usr/bin/grep -c . || true)
skip_n=$(printf '%s' "$SKIPPED" | /usr/bin/grep -c . || true)

summary=""
(( stale_n > 0 )) && summary="STALE: $(join_lines "$STALE")"
if (( fresh_n > 0 )); then
  [[ -n "$summary" ]] && summary="$summary | "
  summary="${summary}drifting: $(join_lines "$FRESH")"
fi
if (( skip_n > 0 )); then
  [[ -n "$summary" ]] && summary="$summary | "
  summary="${summary}skipped: $(join_lines "$SKIPPED")"
fi
[[ -n "$summary" ]] || summary="everything current"

# The informational line is for a human reading the terminal, not for the push
# msg — Kuma truncates, and the drift itself is what belongs in the alert.
echo "  drift-check ($("$DATE_BIN" '+%Y-%m-%d %H:%M'))"
printf '%s' "$INFO" | /usr/bin/grep -v '^$' | /usr/bin/sed 's/^/    · /' || true
if (( fresh_n > 0 )); then printf '%s' "$FRESH" | /usr/bin/grep -v '^$' | /usr/bin/sed 's/^/    ~ /'; fi
if (( stale_n > 0 )); then printf '%s' "$STALE" | /usr/bin/grep -v '^$' | /usr/bin/sed 's/^/    ✗ /'; fi
if (( skip_n > 0 )); then printf '%s' "$SKIPPED" | /usr/bin/grep -v '^$' | /usr/bin/sed 's/^/    ? /'; fi

# The push URL file is optional and its absence is silent — same contract as the
# collie and secrets monitors. A machine that never wired this must not fail.
push_rc=0
if (( NO_PUSH )); then
  : # --no-push: report only, requested by an on-demand caller
elif [[ -f "$PUSH_URL_FILE" ]]; then
  url=$(kuma_resolve_push_url "${DRIFT_PUSH_URL:-}" "$PUSH_URL_FILE") || url=""
  if [[ -n "$url" ]]; then
    if (( stale_n > 0 )); then
      kuma_push "$url" down "$summary" || push_rc=$?
    else
      kuma_push "$url" up "$summary" || push_rc=$?
    fi
  fi
fi

(( stale_n == 0 )) && (( push_rc == 0 ))
