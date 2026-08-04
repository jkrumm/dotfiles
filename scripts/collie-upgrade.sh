#!/usr/bin/env bash
set +x
set -euo pipefail

# collie-upgrade — resolve the newest collie release, SHOW IT, then (on your y)
# bump the pin, reinstall, assert, and commit.
#
# WHY THIS IS NOT AN AUTO-UPGRADER, even though collie releases weekly and is
# "just the phone UI". Collie is remote shell access: one bridge call types
# arbitrary keystrokes into a live pane, and upstream's own README says to treat
# the URL like a root login. `herdr plugin install` re-clones and REBUILDS the
# whole repo, so applying a release runs unreviewed third-party code on the host
# that runs every agent. A path-scope gate ("only web/ changed, apply it") is
# weaker than it looks, because the PWA *is* the control surface — malicious
# web/ code reads the snapshot and sends keys just as well as malicious bridge/
# code. So the scope verdict below is DECISION SUPPORT, not a safety boundary:
# it tells you whether the hardening surface moved, and you still press y.
#
# What it does remove is the tedium that let the pin sit five releases behind
# (0.17.0 → 0.22.0, two security fixes) until it was found by accident. Noticing
# is scripts/drift-check.sh's job; this is the other half — applying, with the
# review kept and the eleven mechanical steps gone.
#
# Sibling of scripts/brew-upgrade.sh: converge, then ASSERT rather than assume.
# collie-setup re-checks the DNS-rebinding guard (spoofed Host must 403) and
# fails otherwise, so a release that silently breaks the hardening rolls the pin
# straight back instead of landing.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAKEFILE="${COLLIE_UPGRADE_MAKEFILE:-$DOTFILES_DIR/Makefile}"
STATE_DIR="${COLLIE_UPGRADE_STATE_DIR:-$HOME/.local/state/collie-upgrade}"
REPO_DIR="$STATE_DIR/repo"

GIT_BIN="${GIT_BIN:-/usr/bin/git}"

# Paths a release may touch without moving the hardening surface. Everything
# else — bridge/, scripts/, .github/ — is called out by name in the verdict.
# bun.lock is deliberately NOT here: a changed lockfile is a changed dependency,
# which is the one thing in a UI-only release worth stopping to look at.
SAFE_PATHS="web/ CHANGELOG.md README.md package.json herdr-plugin.toml"

# shellcheck source=lib/github-tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/github-tags.sh"

ROLLBACK_REF=""
cleanup() {
  gh_tags_cleanup
  # Only fires if we bumped the pin and then failed before clearing this.
  if [ -n "$ROLLBACK_REF" ]; then
    echo ""
    echo "  ✗ upgrade failed — rolling back to $ROLLBACK_REF"
    pin_write "$ROLLBACK_PIN_REF" "$ROLLBACK_PIN_VERSION"
    herdr plugin install "$SOURCE" --ref "$ROLLBACK_PIN_REF" -y >/dev/null 2>&1 \
      && echo "    ✓ pin and plugin restored to $ROLLBACK_PIN_VERSION" \
      || echo "    ✗ plugin restore FAILED — run: make collie-setup"
  fi
}
trap cleanup EXIT

die() { echo "  ✗ $*" >&2; exit 1; }

# Rewrite both pin lines, then PROVE it. A silently non-matching sed would
# reinstall the version already installed and commit a no-op as an upgrade.
pin_write() {
  local ref="$1" version="$2"
  /usr/bin/sed -i '' \
    -e "s|^COLLIE_REF     := .*|COLLIE_REF     := $ref|" \
    -e "s|^COLLIE_VERSION := .*|COLLIE_VERSION := $version|" \
    "$MAKEFILE"
  [ "$(makefile_var COLLIE_REF)" = "$ref" ] \
    || die "pin rewrite did not take — COLLIE_REF in $MAKEFILE is not $ref"
  [ "$(makefile_var COLLIE_VERSION)" = "$version" ] \
    || die "pin rewrite did not take — COLLIE_VERSION in $MAKEFILE is not $version"
}

# --- Gate --------------------------------------------------------------------
# Same dev-host marker collie-setup and git-headless use. Collie only exists
# where the herdr server does.
BACKEND=$(/usr/bin/tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")
if [ "$BACKEND" != "cache" ]; then
  echo "    · not the dev host (backend=${BACKEND:-unset}) — collie-upgrade skipped"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || die "herdr not installed — run: brew bundle install"

SOURCE=$(makefile_var COLLIE_SOURCE)
CUR_REF=$(makefile_var COLLIE_REF)
CUR_VERSION=$(makefile_var COLLIE_VERSION)
[ -n "$SOURCE" ] && [ -n "$CUR_REF" ] || die "could not read COLLIE_SOURCE/COLLIE_REF from $MAKEFILE"

# Refuse on a dirty Makefile: this script commits that file, and sweeping an
# unrelated in-flight edit into a "chore(collie)" commit is not ours to do.
if ! "$GIT_BIN" -C "$DOTFILES_DIR" diff --quiet -- "$MAKEFILE" 2>/dev/null; then
  die "$MAKEFILE has uncommitted changes — commit or stash them first"
fi

# --- Resolve -----------------------------------------------------------------
echo ""
echo "  collie-upgrade"
LATEST=$(latest_tag "$SOURCE") || die "GitHub unreachable — nothing resolved, nothing changed"
[ -n "$LATEST" ] || die "no release tags found on $SOURCE"
NEW_REF=$(tag_commit "$SOURCE" "$LATEST") || die "could not resolve $LATEST to a commit"
NEW_VERSION="${LATEST#v}"

if [ "$NEW_REF" = "$CUR_REF" ]; then
  echo "    ✓ collie $CUR_VERSION is current ($LATEST)"
  exit 0
fi

echo "    collie $CUR_VERSION → $NEW_VERSION (${CUR_REF:0:7} → ${NEW_REF:0:7})"
echo ""

# --- Review material ---------------------------------------------------------
# Blobless clone kept in the state dir: the diff is the whole point, and
# re-cloning a repo on every upgrade to throw it away is wasteful. Lazily
# fetches the blobs the diff actually needs.
/bin/mkdir -p "$STATE_DIR"
if [ -d "$REPO_DIR/.git" ]; then
  "$GIT_BIN" -C "$REPO_DIR" fetch --quiet --tags origin 2>/dev/null \
    || die "could not fetch $SOURCE into $REPO_DIR"
else
  "$GIT_BIN" clone --quiet --filter=blob:none "https://github.com/$SOURCE" "$REPO_DIR" \
    || die "could not clone $SOURCE into $REPO_DIR"
fi

"$GIT_BIN" -C "$REPO_DIR" cat-file -e "${CUR_REF}^{commit}" 2>/dev/null \
  || die "current pin $CUR_REF is not a commit in $SOURCE — pin is wrong, fix it by hand"

CHANGED=$("$GIT_BIN" -C "$REPO_DIR" diff --name-only "$CUR_REF" "$NEW_REF")

# Scope verdict. Decision support, not a safety boundary — see the header.
UNSAFE=""
for f in $CHANGED; do
  ok=""
  for p in $SAFE_PATHS; do
    case "$f" in
      "$p"*) ok=1; break ;;
    esac
  done
  [ -n "$ok" ] || UNSAFE="${UNSAFE}${f}
"
done

if [ -n "$UNSAFE" ]; then
  echo "    scope: TOUCHES MORE THAN THE UI — read these before saying yes:"
  echo "$UNSAFE" | /usr/bin/grep -v '^$' | /usr/bin/sed 's/^/             /'
else
  echo "    scope: web/ + metadata only ✓ (no bridge/, no scripts/)"
fi
echo ""

# Changelog section for the new version only.
NOTES=$("$GIT_BIN" -C "$REPO_DIR" show "$NEW_REF:CHANGELOG.md" 2>/dev/null \
  | /usr/bin/awk -v v="$NEW_VERSION" '
      $0 ~ "^## \\[" v "\\]" { on=1; next }
      on && /^## \[/         { exit }
      on                     { print }
    ' | /usr/bin/sed 's/^/    /' || true)
if [ -n "$NOTES" ]; then
  echo "$NOTES" | /usr/bin/head -40
else
  echo "    (no CHANGELOG section for $NEW_VERSION)"
fi

echo "    diffstat:"
"$GIT_BIN" -C "$REPO_DIR" diff --stat "$CUR_REF" "$NEW_REF" | /usr/bin/tail -1 | /usr/bin/sed 's/^/     /'
echo ""

# --- Confirm -----------------------------------------------------------------
# No TTY and no explicit yes means someone wired this into automation. That is
# the one thing this script exists to not be, so it refuses rather than guesses.
if [ "${COLLIE_UPGRADE_YES:-}" != "1" ]; then
  [ -t 0 ] || die "not a terminal and COLLIE_UPGRADE_YES is unset — refusing to upgrade unattended"
  printf "    apply? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "    · aborted, nothing changed"; exit 0 ;;
  esac
  echo ""
fi

# --- Apply -------------------------------------------------------------------
ROLLBACK_PIN_REF="$CUR_REF"
ROLLBACK_PIN_VERSION="$CUR_VERSION"
ROLLBACK_REF="$CUR_VERSION"

pin_write "$NEW_REF" "$NEW_VERSION"

# collie-setup does the install AND the assertions: liveness, launchd
# supervision, and the spoofed-Host 403. A release that breaks the rebind guard
# fails here and trips the rollback above.
/usr/bin/make -C "$DOTFILES_DIR" --no-print-directory collie-setup

ROLLBACK_REF=""

# --- Commit ------------------------------------------------------------------
# Only the Makefile, only locally. Pushing is left to the human: this runs on
# the mini, and a script that pushes to master is a bigger promise than "bump a
# pin". `git diff --quiet` guarded that the file was clean on entry.
SCOPE_NOTE="web/ + metadata only — bridge/ and scripts/ untouched"
[ -n "$UNSAFE" ] && SCOPE_NOTE="touches more than web/ — see the diff"

"$GIT_BIN" -C "$DOTFILES_DIR" add -- "$MAKEFILE"
"$GIT_BIN" -C "$DOTFILES_DIR" commit --quiet -m "chore(collie): upgrade to $NEW_VERSION" -m \
"Pin moves $CUR_VERSION → $NEW_VERSION (${NEW_REF:0:7}). Scope: $SCOPE_NOTE.

Installed and asserted by make collie-setup: launchd supervision, bridge
liveness, and the DNS-rebinding guard (spoofed Host → 403)."

echo ""
echo "  ✓ collie $NEW_VERSION pinned, installed, asserted and committed"
echo "    push when ready:  git -C $DOTFILES_DIR push"
