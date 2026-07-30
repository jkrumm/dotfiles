#!/usr/bin/env bash
set -euo pipefail

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
#   mosh — the macOS Application Firewall stores mosh-server's RESOLVED path
#   (`readlink -f`), which points into a version-stamped Cellar directory.
#   `brew upgrade mosh` moves the binary to a new Cellar path, so the ALF
#   entry silently stops matching. ssh still handshakes fine (that path is
#   unaffected), so mosh LOOKS like it connected — the client just times out
#   waiting for the first UDP datagram, which reads exactly like a missing
#   Tailscale ACL grant and sends the diagnosis the wrong way entirely. Fix:
#   `make mosh-firewall`.
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
# --pins-only exists for `make setup`/`_setup-packages`: a fresh machine needs
# caddy/mosh pinned from the very first `brew bundle install` — otherwise the
# very first bare `brew upgrade` anyone runs reverts the caddy DNS module
# before `make caddy-dns-build` has ever been run once.
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
HELD=(caddy mosh)

# Which `make` target repairs a held package after a deliberate manual
# upgrade (`brew unpin X && brew upgrade X && make <this> && brew pin X`).
fixup_for() {
  case "$1" in
    caddy) printf '%s' "caddy-dns-build" ;;
    mosh) printf '%s' "mosh-firewall" ;;
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
echo "  Pins (caddy/mosh — silent-config-revert guards, see header)..."
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
third_party_basenames=()
while IFS= read -r fn; do
  if [[ -n "$fn" && "$fn" == */* ]]; then
    third_party_basenames+=("${fn##*/}")
  fi
done <<<"$full_names_raw"

held_outdated=()
third_party_outdated=()
upgradable=()
for pkg in ${outdated_formulae[@]+"${outdated_formulae[@]}"}; do
  if in_array "$pkg" "${HELD[@]}"; then
    held_outdated+=("$pkg")
  elif in_array "$pkg" ${third_party_basenames[@]+"${third_party_basenames[@]}"}; then
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
    echo "      brew unpin $pkg && brew upgrade $pkg && make $fixup && brew pin $pkg"
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
# A dependency upgrade can relink a dependent, so verify the two fragile
# invariants directly rather than trusting that caddy/mosh were merely
# skipped. Both are dev-host-only concerns (the mini is the only machine
# running the tailnet Caddyfile include and the only one moshed INTO), gated
# the same way `caddy-dns-build` gates itself: on the secrets backend marker.
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

  mosh_bin="$(brew --prefix)/bin/mosh-server"
  real=$(readlink -f "$mosh_bin" 2>/dev/null || echo "$mosh_bin")
  apps=$(/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null) || true
  if grep -qF "$real" <<<"$apps"; then
    echo "  ✓ mosh-server still allowed through the Application Firewall"
  else
    echo "  ✗ mosh-server not in the Application Firewall allowlist (fix: make mosh-firewall)"
    assertion_failed=1
  fi
else
  echo "  · not the dev host (backend=${BACKEND:-unset}) — skipping caddy/mosh assertions"
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

(( ! assertion_failed )) || exit 1
