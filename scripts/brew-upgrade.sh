#!/usr/bin/env bash
set -euo pipefail

# Both boot-path invariants below live in a Homebrew-generated plist, and
# Homebrew 6 renamed those from homebrew.mxcl.<name> to sh.brew.<name> — on the
# next start/restart, not at upgrade time, so both names are live across these
# machines. Resolve by service name; a hardcoded path would print "not
# registered here — skipping" over a service that IS registered and HAS just
# been reverted, which is the one thing this script exists to catch.
# shellcheck source=lib/brew-service.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/brew-service.sh"

# brew-upgrade — guarded `brew upgrade`, safe to run unattended or by hand.
#
# Usage: brew-upgrade.sh [--dry-run] [--pins-only]
#
# WHY BLANKET brew upgrade IS NOT THE npm-STYLE SUPPLY-CHAIN RISK HERE. Every
# outdated formula/cask on these two machines comes from homebrew/core or
# homebrew/cask — reviewed PRs, built into bottles by Homebrew's own CI, not a
# maintainer publishing a tarball directly the way npm/pnpm packages do. That
# is a fundamentally different trust model from `dependency-hygiene.md`'s
# concern, and it is why this script does not gate core formulae behind any
# review step (third-party taps and casks are a different story — see below).
#
# THE REAL HAZARD IN THIS REPO IS SILENT CONFIG REVERT, not a compromised
# release, and it is specific to exactly two packages:
#
#   caddy — `brew upgrade caddy` replaces the xcaddy-built binary
#   (scripts/caddy-tailnet.sh + `make caddy-dns-build`) with the stock
#   Homebrew build, and `dns.providers.cloudflare` just vanishes. Nothing
#   errors at upgrade time. The wildcard cert for the clean
#   https://<app>.$DEV_DOMAIN door keeps working on its existing lease and
#   only fails to RENEW roughly 60 days later — by which point the upgrade
#   that caused it is long forgotten. Fix: `make caddy-dns-build`.
#
#   colima — same class, DIFFERENT remedy, and the difference is why it is not
#   in HELD. `brew upgrade colima` regenerates
#   colima's brew-service plist (sh.brew.colima.plist, or the pre-Homebrew-6
#   homebrew.mxcl.colima.plist) from the formula's
#   `service` block, throwing away the supervised boot path
#   (`make _colima-supervise`: bare `KeepAlive => true` + colima/colima-start.sh
#   instead of Homebrew's inverted `{ SuccessfulExit => true }`). Nothing errors;
#   the VM keeps running and only the next FAILED start goes unretried — i.e.
#   Docker stays down after a power cut on a headless box. A PIN WOULD NOT FIX
#   THIS: `brew services start|restart colima` regenerates the same plist, and no
#   pin gates those. The invariant simply cannot be held by pinning, so it is
#   held by convergence (`_colima-supervise` runs after every colima target and
#   from `make setup`) plus assertion — here on the upgrade path, and every 300s
#   in devhost-health-check.sh's probe_colima. Fix: `make _colima-supervise`.
#
# `brew pin` IS THE ENFORCEMENT — this script's own HELD list is a convenience
# for reporting, not the actual guard. `brew upgrade` (with no arguments,
# typed by hand, on a machine six months from now) skips every pinned formula
# outright, and a named `brew upgrade caddy` refuses while caddy is pinned.
# That is what makes the guard hold for someone who has forgotten this script
# exists — not just for the `make brew-upgrade` path.
#
# THIRD-PARTY TAPS (oven-sh/bun, satococoa/tap, jkrumm/tap, peterldowns/tap,
# ...) are excluded from the automatic upgrade set even though they are not
# pinned. A tap maintainer publishing directly, with no Homebrew-CI review
# gate, is exactly the risk profile `dependency-hygiene.md` describes — those
# get reported and left for `/upgrade-deps`, which does the research pass a
# non-core formula deserves.
#
# CASKS are vendor binaries (Homebrew ships the metadata, not the bits — the
# download comes straight from the vendor), which is where the release-age
# cooldown argument in dependency-hygiene.md actually applies. Also left to
# `/upgrade-deps`, never auto-upgraded here.
#
# BE HONEST ABOUT WHAT THAT LAST PARAGRAPH BUYS: unlike the caddy guard, it is
# NOT enforced. A bare `brew upgrade` upgrades casks too (verified — it even
# volunteers "Homebrew will now attempt to upgrade casks with
# `auto_updates true`"), and casks are deliberately NOT pinned here. So the
# cask cooldown holds only on THIS path, not machine-wide. That asymmetry is a
# choice, not an oversight: pinning every cask would mean hand-maintaining a
# list that silently stops receiving security updates, which is a worse trade
# than a soft preference honoured by the command you normally reach for. The
# pinned formula is pinned because its failure mode is silent config revert,
# which no amount of care at the keyboard can catch afterward.
#
# --pins-only exists for `make setup`/`_setup-packages`: a fresh machine needs
# caddy pinned from the very first `brew bundle install` — otherwise the very
# first bare `brew upgrade` anyone runs reverts the caddy DNS module before
# `make caddy-dns-build` has ever been run once.
#
# Idioms carried over from scripts/devhost-health-check.sh and
# scripts/caddy-tailnet.sh, both learned the hard way there:
#   - capture command output into a variable FIRST, match second. Piping
#     straight into `grep -q` under `set -o pipefail` lets grep exit on its
#     first match, SIGPIPEs the producer, and reports a healthy result as a
#     failure (check_sshd's comment in devhost-health-check.sh).
#   - `${arr[@]+"${arr[@]}"}` guards every expansion of an array that might
#     be empty. macOS ships bash 3.2, and bash before 4.4 throws
#     "unbound variable" expanding an empty array under `set -u` — plain
#     `"${arr[@]}"` is not safe here the way it would be on a modern bash.

# The declared hold list. `brew pin` is what actually protects these (see
# above) — this array only drives what this script reports and asserts.
#
# tailscale is held for a DIFFERENT reason than caddy, and it is not silent
# config revert. On the dev host Tailscale is not one network path among
# several, it is the ONLY one: `ssh mini` resolves to the tailnet address and
# the LAN address does not answer — measured 2026-09-20, ARP for the mini's
# 192.168.1.x never completes from the MacBook, the two Macs are not on the
# same L2 despite both showing a 192.168.1.0/24 address. So the formula whose
# daemon carries every inbound connection must not ride an unattended batch
# that nobody is watching: 2026-08-05 already cost an outage by forcing a
# Tailscale update on this host (drift-check.sh's check_tailscale header says
# so, and then told you to fix the drift with `make brew-upgrade` — which, up
# to here, would have done exactly the forcing that incident warned about).
#
# Upgrading the FORMULA is in fact harmless on its own: the running daemon
# keeps its old inode until something restarts it, so the door stays open. It
# is the restart that is the risk, and the restart is what the repair command
# below makes explicit and human-timed. The post-assertion further down
# reports the in-between state (new binary on disk, old daemon serving) rather
# than letting it pass for "upgraded".
HELD=(caddy tailscale)

# The command that repairs a held package after a deliberate manual upgrade:
#   brew unpin X && brew upgrade X && <this> && brew pin X
# It is a COMMAND, not a make target — `make caddy-dns-build` is a target and
# tailscale's repair is a launchctl call, and printing a half-line the reader
# has to assemble is how a follow-up gets skipped.
fixup_for() {
  case "$1" in
    caddy) printf '%s' "make caddy-dns-build" ;;
    tailscale) printf '%s' "sudo launchctl kickstart -k system/homebrew.mxcl.tailscale" ;;
    *) printf '%s' "" ;;
  esac
}

# True if $1 is among the remaining args. Safe to call with a possibly-empty
# haystack via the `${arr[@]+"${arr[@]}"}` guard at each call site.
in_array() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

DRY_RUN=0
PINS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --pins-only) PINS_ONLY=1 ;;
    *)
      echo "usage: $(basename "$0") [--dry-run] [--pins-only]" >&2
      exit 1
      ;;
  esac
done

command -v brew >/dev/null 2>&1 \
  || { echo "✗ brew not found — this script requires Homebrew" >&2; exit 1; }

if (( ! PINS_ONLY )); then
  echo "  brew update..."
  brew update --quiet
fi

# --- converge pins (idempotent) ----------------------------------------------
echo "  Pins (${HELD[*]} — see the HELD comment for why each one is held)..."
pinned_raw=$(brew list --pinned 2>/dev/null) || true

for f in "${HELD[@]}"; do
  if ! brew list --formula --versions "$f" >/dev/null 2>&1; then
    echo "  · $f not installed (skip)"
    continue
  fi
  if grep -qxF "$f" <<<"$pinned_raw"; then
    echo "  · $f pinned"
  elif (( DRY_RUN )); then
    # --dry-run must be a TRUE no-op preview. Converging pins here is cheap and
    # idempotent, which is exactly why it is tempting to just do it anyway — but
    # a `-dry` target that mutates machine state is the surprise this repo's
    # Makefile conventions exist to prevent, and `make brew-upgrade-dry` is the
    # command someone reaches for precisely because they are not ready to touch
    # anything yet. The real convergence paths are `make brew-upgrade` and
    # `--pins-only` from `_setup-packages`.
    echo "  · $f would be pinned (dry-run)"
  else
    brew pin "$f" && echo "  ✓ pinned $f"
  fi
done

# Report, never touch: a pin this script did not put there is a deliberate
# human decision, and silently unpinning it would be worse than leaving a
# line in the output.
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  in_array "$p" "${HELD[@]}" \
    || echo "  ! $p is pinned but not in HELD=(${HELD[*]}) — leaving it as-is"
done <<<"$pinned_raw"

if (( PINS_ONLY )); then
  exit 0
fi

# --- partition the outdated set -----------------------------------------------
# brew's auto-update progress lines land on stderr and would otherwise pollute
# a machine-parsed list — redirected away, and captured into a variable before
# any matching happens (see the pipefail note in the header).
outdated_formulae_raw=$(brew outdated --formula --quiet 2>/dev/null) || true
outdated_casks_raw=$(brew outdated --cask --quiet 2>/dev/null) || true
full_names_raw=$(brew list --formula --full-name 2>/dev/null) || true

outdated_formulae=()
while IFS= read -r line; do
  [[ -n "$line" ]] && outdated_formulae+=("$line")
done <<<"$outdated_formulae_raw"

outdated_casks=()
while IFS= read -r line; do
  [[ -n "$line" ]] && outdated_casks+=("$line")
done <<<"$outdated_casks_raw"

# A non-core tap reports its full name as `owner/tap/formula`
# (`oven-sh/bun/bun`) where a homebrew/core formula reports bare (`jq`) — the
# presence of a `/` IS the signal, not a maintained allowlist of taps.
#
# COMPARE FULL NAME TO FULL NAME. This used to collect BASENAMES here
# (`bun`) and match them against what `brew outdated --quiet` prints, which is
# the FULL name (`oven-sh/bun/bun`) — so the comparison could never be true and
# the third-party bucket was always empty. The stated policy ("tap maintainers
# publish directly, no Homebrew-CI review gate — report, never auto-upgrade")
# silently did not hold: measured 2026-09-20, a run that reported
# `skipped: 0 third-party` had just upgraded `oven-sh/bun/bun` inside the
# automatic set on both machines. A guard that reports zero is indistinguishable
# from a guard that has nothing to guard, which is why this went unnoticed.
#
# HELD IS STILL MATCHED BARE, deliberately: every held formula is a
# homebrew/core one, and `brew pin`/`brew unpin` take the bare name.
third_party_fullnames=()
while IFS= read -r fn; do
  if [[ -n "$fn" && "$fn" == */* ]]; then
    third_party_fullnames+=("$fn")
  fi
done <<<"$full_names_raw"

held_outdated=()
third_party_outdated=()
upgradable=()
for pkg in ${outdated_formulae[@]+"${outdated_formulae[@]}"}; do
  if in_array "$pkg" "${HELD[@]}"; then
    held_outdated+=("$pkg")
  elif in_array "$pkg" ${third_party_fullnames[@]+"${third_party_fullnames[@]}"}; then
    third_party_outdated+=("$pkg")
  else
    upgradable+=("$pkg")
  fi
done

# --- report every skipped bucket, with the exact deliberate follow-up --------
# No silent caps: whatever is not in `upgradable` is named here, along with
# what to do about it, so nothing just quietly stays outdated.
if (( ${#held_outdated[@]} > 0 )); then
  echo "  ! held & outdated — deliberate follow-up, not run automatically:"
  for pkg in "${held_outdated[@]}"; do
    fixup=$(fixup_for "$pkg")
    echo "      brew unpin $pkg && brew upgrade $pkg && $fixup && brew pin $pkg"
  done
fi

if (( ${#third_party_outdated[@]} > 0 )); then
  names=$(IFS=', '; echo "${third_party_outdated[*]}")
  echo "  · review manually (third-party tap): $names — use /upgrade-deps"
fi

if (( ${#outdated_casks[@]} > 0 )); then
  names=$(IFS=', '; echo "${outdated_casks[*]}")
  echo "  · vendor binaries, release-age cooldown applies: $names — use /upgrade-deps"
fi

if (( DRY_RUN )); then
  if (( ${#upgradable[@]} > 0 )); then
    echo "  would upgrade (dry-run): ${upgradable[*]}"
  else
    echo "  · nothing to upgrade (dry-run)"
  fi
  exit 0
fi

# --- upgrade -------------------------------------------------------------
if (( ${#upgradable[@]} == 0 )); then
  echo "  · nothing to upgrade — every outdated formula is held, third-party, or a cask"
else
  echo "  upgrading: ${upgradable[*]}"
  brew upgrade --formula "${upgradable[@]}" \
    || { echo "  ✗ brew upgrade failed" >&2; exit 1; }
  echo "  ✓ upgraded ${#upgradable[@]} formula(e)"
fi

# --- post-assertions — assert, don't assume the hold list protected anything -
# A dependency upgrade can relink a dependent, so verify the fragile
# invariant directly rather than trusting that caddy was merely skipped. This
# is a dev-host-only concern (the mini is the only machine running the
# tailnet Caddyfile include), gated the same way `caddy-dns-build` gates
# itself: on the secrets backend marker.
assertion_failed=0
BACKEND=$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")
if [[ "$BACKEND" == "cache" ]]; then
  modules=$(caddy list-modules 2>/dev/null) || true
  if grep -q 'dns.providers.cloudflare' <<<"$modules"; then
    echo "  ✓ caddy: dns.providers.cloudflare present"
  else
    echo "  ✗ caddy: dns.providers.cloudflare missing (fix: make caddy-dns-build)"
    assertion_failed=1
  fi
else
  echo "  · not the dev host (backend=${BACKEND:-unset}) — skipping caddy assertion"
fi

# tailscale: ASK THE DAEMON, NEVER THE CLI. `brew upgrade tailscale` replaces
# the binary behind /opt/homebrew/opt/tailscale; the running tailscaled keeps
# its old inode until something restarts it, so right after an upgrade the
# machine is serving traffic from a version that is no longer installed. Plain
# `tailscale version` reports the CLI's own version and so goes green at that
# exact moment — a confident wrong answer of the same shape lib/tailscale-cli.sh
# exists to prevent (there: the dormant macsys daemon answering for the live
# one). `version --daemon` prints both; the `Daemon:` line is the only one that
# says what is actually carrying the tunnel.
#
# This is a REPORT, not a repair. The restart is `sudo launchctl kickstart -k`,
# it needs root the unattended path does not have, and on the dev host it
# briefly drops the only door in (see the HELD comment). The daemon plist is
# KeepAlive=true + RunAtLoad=true, so the gap self-heals — but it is still a
# gap, and choosing when to open it is the human's call. Left outdated it is
# the 2026-08-05 blind spot again, which is why silence is not an option either.
if [[ -x /opt/homebrew/bin/tailscale && -S /var/run/tailscaled.socket ]]; then
  # THE OPT SYMLINK, not `brew list --versions`. Homebrew keeps old kegs around
  # (the mini had `tailscale 1.102.3 1.102.2` listed side by side), so picking a
  # field out of that line compares the daemon against whichever keg happens to
  # sort there. `/opt/homebrew/opt/tailscale` is the LINKED one, and it is also
  # the exact path the LaunchDaemon's ProgramArguments resolves through — so it
  # is what the next restart will actually start.
  ts_installed=$(basename "$(readlink /opt/homebrew/opt/tailscale 2>/dev/null)" 2>/dev/null)
  # `Daemon: 1.102.3-t53a0d659a` → 1.102.3. The -t<commit> suffix is build
  # metadata the formula version never carries, so it is stripped, not matched.
  ts_daemon=$(/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket \
    version --daemon 2>/dev/null | awk -F': ' '/^Daemon:/{print $2}' | cut -d- -f1)
  if [[ -z "$ts_installed" || -z "$ts_daemon" ]]; then
    echo "  · tailscale: version unreadable (installed='${ts_installed:-?}' daemon='${ts_daemon:-?}') — skipping assertion"
  elif [[ "$ts_installed" == "$ts_daemon" ]]; then
    echo "  ✓ tailscale: daemon $ts_daemon matches the installed keg"
  else
    echo "  ✗ tailscale: daemon still runs $ts_daemon, $ts_installed is installed — the tunnel is on a version no longer on disk"
    echo "      fix (drops the tailnet for a moment; launchd brings it back): sudo launchctl kickstart -k system/homebrew.mxcl.tailscale"
    assertion_failed=1
  fi
else
  echo "  · tailscale: no brew tailscaled here — skipping assertion"
fi

# colima is asserted on BOTH machines, gated on its own plist rather than the
# backend marker — unlike caddy there is no dev-host asymmetry here.
# `_setup-colima` converges the supervised boot path wherever colima is
# installed, so wherever the plist exists the invariant is supposed to hold. A
# machine that never registered the brew service simply has nothing to check.
COLIMA_PLIST=$(brew_service_plist colima) || COLIMA_PLIST=""
COLIMA_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/colima/colima-start.sh"
if [[ -z "$COLIMA_PLIST" ]] && brew services info colima --json 2>/dev/null | grep -q '"loaded": *true'; then
  # Loaded with no file under either name is not "not installed here" — it is
  # the DISARMED state: nothing can converge the boot path and launchd is
  # running from a cached definition that dies at the next reboot. Fail.
  echo "  ✗ colima: brew service is loaded but has NO plist under either name (sh.brew.colima / homebrew.mxcl.colima) — boot path unassertable (fix: make colima-restart)"
  assertion_failed=1
elif [[ -n "$COLIMA_PLIST" ]]; then
  keepalive=$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$COLIMA_PLIST" 2>/dev/null) || keepalive=""
  program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$COLIMA_PLIST" 2>/dev/null) || program=""
  # The reverted form prints multi-line as `Dict { SuccessfulExit = true }`;
  # flatten it so the diagnosis is one readable line. `true` is untouched.
  keepalive=${keepalive//$'\n'/ }
  loaded=$(launchctl print "$(brew_service_launchctl_target colima 2>/dev/null)" 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*program = /{ print $2; exit }') || loaded=""
  if [[ "$keepalive" == "true" && "$program" == "$COLIMA_WRAPPER" && ( -z "$loaded" || "$loaded" == "$COLIMA_WRAPPER" ) ]]; then
    echo "  ✓ colima: supervised boot path intact (bare KeepAlive + retry wrapper)"
  elif [[ "$keepalive" == "true" && "$program" == "$COLIMA_WRAPPER" ]]; then
    echo "  ✗ colima: file converged but launchd still runs '$loaded' — bootout+bootstrap needed (fix: make colima-restart)"
    assertion_failed=1
  else
    echo "  ✗ colima: boot path reverted by the upgrade — KeepAlive='${keepalive:-unreadable}', ProgramArguments:0='${program:-unreadable}' (fix: make _colima-supervise)"
    assertion_failed=1
  fi
else
  echo "  · colima brew service not registered here — skipping boot-path assertion"
fi

# herdr, same trap in a different plist: `brew upgrade herdr` regenerates
# herdr's brew-service plist from the formula and strips the session-leader
# wrapper. Nothing errors — the server comes up fine and only the next `desk`
# launch starts asking "restart the remote server now? [y/N]" again, which
# reads as a herdr quirk rather than as a reverted config. Asserted wherever
# the service is registered, gated on the plist like colima's.
HERDR_PLIST=$(brew_service_plist herdr) || HERDR_PLIST=""
HERDR_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/herdr/herdr-server-start.py"
if [[ -z "$HERDR_PLIST" ]] && brew services info herdr --json 2>/dev/null | grep -q '"loaded": *true'; then
  echo "  ✗ herdr: brew service is loaded but has NO plist under either name (sh.brew.herdr / homebrew.mxcl.herdr) — boot path unassertable (fix: brew services start herdr && make _herdr-supervise)"
  assertion_failed=1
elif [[ -n "$HERDR_PLIST" ]]; then
  program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$HERDR_PLIST" 2>/dev/null) || program=""
  loaded=$(launchctl print "$(brew_service_launchctl_target herdr 2>/dev/null)" 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*program = /{ print $2; exit }') || loaded=""
  if [[ "$program" == "$HERDR_WRAPPER" && ( -z "$loaded" || "$loaded" == "$HERDR_WRAPPER" ) ]]; then
    echo "  ✓ herdr: session-leader boot path intact"
  elif [[ "$program" == "$HERDR_WRAPPER" ]]; then
    echo "  ✗ herdr: file converged but launchd still runs '$loaded' (fix: make herdr-restart YES=1)"
    assertion_failed=1
  else
    echo "  ✗ herdr: boot path reverted by the upgrade — ProgramArguments:0='${program:-unreadable}' (fix: make _herdr-supervise, then make herdr-restart YES=1)"
    assertion_failed=1
  fi
else
  echo "  · herdr brew service not registered here — skipping boot-path assertion"
fi

# op, the same silent-revert class with no plist in it. macOS records a TCC
# grant against the BINARY PATH, and 1password-cli is a cask, so that path
# carries the version (…/Caskroom/1password-cli/<ver>/op). An upgrade moves the
# binary out from under the grant, nothing announces it, and the next
# `make secrets-seed` simply puts "op möchte auf Daten aus anderen Apps
# zugreifen" back on screen — a dialog a present human has to click before the
# reseal proceeds, on top of the biometric prompt. This script never causes it
# (op is a cask, reported not upgraded); `/upgrade-deps` does, which is why the
# check belongs on the path that reports casks. Observed 2026-09-12, macOS
# 26.6.2 with op 2.38.1.
#
# TWO services, and either one covering the CURRENT path is enough:
# SystemPolicyAllFiles (Full Disk Access) supersedes the SystemPolicyAppData
# check that op's desktop-app handshake actually trips. They live in different
# databases — FDA in the system one, AppData in the user's — so both are asked.
# auth_value: 0 denied, 2 allowed (FDA), 5 allowed (AppData, macOS 26).
#
# Reading either db itself needs FDA for THIS process. From a Ghostty shell it
# holds; from inside a Claude Code chain it does not, because claude's TCC
# client is its per-version directory (~/.local/share/claude/versions/<ver>)
# and every auto-update mints a fresh one no grant covers. An unreadable db is
# therefore reported as unassertable, never as a missing grant — the opposite
# would fire this alert on every agent-run upgrade.
tcc_allows() {  # $1=db  $2=service  $3=client path ; rc 0 granted, 1 absent, 2 db unreadable
  local rows
  rows=$(sqlite3 "$1" "select auth_value||'|'||client from access where service='$2';" 2>/dev/null) || return 2
  grep -qxF -e "2|$3" -e "5|$3" <<<"$rows"
}

if [[ "$BACKEND" != "op" ]]; then
  echo "  · op: not the present-human machine (backend=${BACKEND:-unset}) — skipping TCC assertion"
elif ! command -v op >/dev/null 2>&1; then
  echo "  · op: 1password-cli not installed here — skipping TCC assertion"
else
  op_real=$(readlink -f "$(command -v op)")
  op_tcc=0
  tcc_allows "/Library/Application Support/com.apple.TCC/TCC.db" \
    kTCCServiceSystemPolicyAllFiles "$op_real" || op_tcc=$?
  if (( op_tcc == 1 )); then
    op_tcc=0
    tcc_allows "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
      kTCCServiceSystemPolicyAppData "$op_real" || op_tcc=$?
  fi
  case "$op_tcc" in
    0) echo "  ✓ op: TCC grant covers $op_real" ;;
    2) echo "  · op: TCC db unreadable from here (this process has no Full Disk Access) — re-run from a plain terminal to assert" ;;
    *) echo "  ✗ op: no TCC grant for $op_real — the next secrets-seed re-prompts for app data (fix: open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles', then open -R '$op_real' and drag it in)"
       assertion_failed=1 ;;
  esac
fi

pinned_after=$(brew list --pinned 2>/dev/null) || true
for f in "${HELD[@]}"; do
  brew list --formula --versions "$f" >/dev/null 2>&1 || continue
  if grep -qxF "$f" <<<"$pinned_after"; then
    echo "  ✓ $f still pinned"
  else
    echo "  ✗ $f is installed but no longer pinned (fix: brew pin $f)"
    assertion_failed=1
  fi
done

# --- summary -------------------------------------------------------------
echo ""
echo "  upgraded ${#upgradable[@]}, skipped: ${#held_outdated[@]} held, ${#third_party_outdated[@]} third-party, ${#outdated_casks[@]} cask(s)"

# Success stamp for scripts/drift-check.sh. It deliberately does NOT alert on
# "something is outdated" — homebrew/core moves daily, so that is true almost
# always and a monitor red on it permanently is a nag nobody reads. The
# alertable fact is that this guarded upgrader has not been RUN, which is a
# timestamp, not a package list. Written even when the assertions below fail:
# the upgrade DID happen, and a reverted caddy module is a different alert with
# a different fix — conflating them would hide the second one behind the first.
# Not written on --dry-run; that path exits long before here.
BREW_UPGRADE_STAMP="${BREW_UPGRADE_STAMP:-$HOME/.local/state/brew-upgrade/last-success}"
mkdir -p "$(dirname "$BREW_UPGRADE_STAMP")" 2>/dev/null || true
: >"$BREW_UPGRADE_STAMP" 2>/dev/null || true

(( ! assertion_failed )) || exit 1
