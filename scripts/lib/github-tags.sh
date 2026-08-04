#!/usr/bin/env bash
# github-tags.sh — resolve the newest release tag of a GitHub repo, and the
# commit it actually points at. Sourced by scripts/drift-check.sh (which reports
# pin drift) and scripts/collie-upgrade.sh (which applies it).
#
# WHY THIS IS A LIB AND NOT COPIED INTO BOTH. tag_commit's annotated-tag peel is
# the subtle part: `herdr plugin install --ref` pins the DEREFERENCED commit, so
# reading the tag object's own sha instead reports drift that can never be
# resolved — the pin would disagree with upstream forever, at every version. A
# second implementation of that is a second chance to get it backwards, in the
# one place where being wrong looks exactly like being right.
#
# BASH 3.2. drift-check.sh runs from a LaunchAgent with no PATH, where
# `/usr/bin/env bash` is Apple's 3.2 — so no mapfile, no ${var,,}, no arrays.
# Absolute binary paths for the same reason: launchd hands over a bare PATH.
#
# Contract for callers:
#   - set MAKEFILE before calling makefile_var
#   - GIT_BIN may be overridden (tests point it at /usr/bin/false to force the
#     network-failure path)
#   - call gh_tags_cleanup from your own EXIT trap; this file installs no trap
#     of its own, so it cannot clobber the caller's

GIT_BIN="${GIT_BIN:-/usr/bin/git}"

# The Makefile is the single source of truth for every pin, so it is parsed
# rather than duplicated. `:=` and `?=` both appear in it.
makefile_var() {
  /usr/bin/sed -n "s/^${1}[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$MAKEFILE" \
    | /usr/bin/head -1
}

# --- Remote tag resolution ---------------------------------------------------
# One ls-remote per repo, cached to a temp file so the tag name and its commit
# come from ONE view of the remote. `^{}` rows are the dereferenced commit of an
# annotated tag — the thing `herdr plugin install --ref` actually pins — so they
# are the rows we want the sha from, while the tag NAME comes from the plain row.
#
# A network failure returns 1 and the caller decides. It must never read as
# drift: "GitHub was unreachable" and "you are five releases behind" are opposite
# conclusions and only one of them is your problem.
GH_TAGS_TMPDIR=""

gh_tags_cleanup() {
  [ -n "$GH_TAGS_TMPDIR" ] && /bin/rm -rf "$GH_TAGS_TMPDIR"
  GH_TAGS_TMPDIR=""
}

remote_tags() {
  local repo="$1"
  local cache
  [ -n "$GH_TAGS_TMPDIR" ] || GH_TAGS_TMPDIR=$(/usr/bin/mktemp -d)
  cache="$GH_TAGS_TMPDIR/$(echo "$repo" | /usr/bin/tr / _)"
  if [ ! -f "$cache" ]; then
    "$GIT_BIN" ls-remote --tags "https://github.com/$repo" >"$cache" 2>/dev/null || return 1
    [ -s "$cache" ] || return 1
  fi
  /bin/cat "$cache"
}

# Highest tag by version sort. Filters pre-releases (anything with a `-`), which
# `sort -V` would otherwise rank above the release it precedes.
latest_tag() {
  local repo="$1" out
  out=$(remote_tags "$repo") || return 1
  echo "$out" \
    | /usr/bin/sed -n 's|.*refs/tags/\(v\{0,1\}[0-9][^^]*\)$|\1|p' \
    | /usr/bin/grep -v -- '-' \
    | /usr/bin/sort -V \
    | /usr/bin/tail -1
}

# Commit a tag resolves to: the `^{}` row if the tag is annotated, else the tag
# row itself. Getting this backwards silently reports permanent phantom drift.
tag_commit() {
  local repo="$1" tag="$2" out sha
  out=$(remote_tags "$repo") || return 1
  sha=$(echo "$out" | /usr/bin/awk -v t="refs/tags/$tag^{}" '$2==t {print $1}')
  [ -n "$sha" ] || sha=$(echo "$out" | /usr/bin/awk -v t="refs/tags/$tag" '$2==t {print $1}')
  [ -n "$sha" ] || return 1
  printf '%s' "$sha"
}
