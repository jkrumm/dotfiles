#!/usr/bin/env bash
# Vendored archify: update from upstream, keep our changes as one patch.
#
#   archify-vendor.sh update [<tag>]   replace skills/archify with upstream <tag> (default: stable
#                                      manifest), re-apply config/archify/basalt.patch, fail if it no longer applies
#   archify-vendor.sh apply            re-apply the patch to an unpatched tree (and rebuild the validators)
#   archify-vendor.sh save             rewrite the patch as (pristine upstream at .upstream-ref) -> (tree)
#   archify-vendor.sh check            exit 1 unless the tree still carries the patch exactly (hermetic)
#   archify-vendor.sh test             check + render a basalt architecture and workflow, assert the preset and tokens
#
# Docs: skills/AGENTS.md §archify.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/archify"
PATCH="$ROOT/config/archify/basalt.patch"
REPO="https://github.com/tt-a1i/archify"
MANIFEST="https://tt-a1i.github.io/archify/skill-updates/archify/stable.json"
# Trimmed on purpose: pre-rendered example HTML (12 MB), the lockfile, OS litter. The CLI reads none of it.
EXCLUDES=(--exclude '/examples/*.html' --exclude '/package-lock.json' --exclude '.DS_Store' --exclude node_modules)

die() { echo "archify-vendor: $*" >&2; exit 1; }

fetch_upstream() { # <tag> <dest> — shallow clone of the tag, prints the commit
  git clone -q --depth 1 --branch "$1" "$REPO" "$2/src" 2>/dev/null || die "cannot clone $REPO at $1"
  git -C "$2/src" rev-parse HEAD
}

# The patch never carries the generated validators (a 2 MB line diff): they are rebuilt from the
# patched schemas with ajv, installed into a scratch copy so the repo gains no node_modules.
GENERATED=renderers/shared/generated-validators.mjs
EXCLUDES+=(--exclude "/$GENERATED")

regen_validators() {
  local tmp; tmp="$(mktemp -d)"
  rsync -a "$SKILL/" "$tmp/skill/"
  (cd "$tmp/skill" && npm install --no-save --no-audit --no-fund --silent ajv@8.17.1 \
    && node scripts/generate-validators.mjs >/dev/null) || { rm -rf "$tmp"; die "validator regeneration failed (needs npm and network)"; }
  cp "$tmp/skill/$GENERATED" "$SKILL/$GENERATED"
  rm -rf "$tmp"
}

# patch paths are relative to the skill dir (a/…, b/…), applied from the repo root with --directory
apply_patch() {
  [ -s "$PATCH" ] || die "missing $PATCH"
  git -C "$ROOT" apply --check --directory=skills/archify "$PATCH" 2>/dev/null \
    || die "basalt.patch no longer applies to the vendored tree: re-do the change by hand in skills/archify, then 'make archify-patch-save'"
  git -C "$ROOT" apply --directory=skills/archify "$PATCH"
  regen_validators
}

cmd="${1:-}"
case "$cmd" in
  update)
    tag="${2:-}"
    if [ -z "$tag" ]; then
      ver="$(curl -fsS --max-time 20 "$MANIFEST" | jq -r '.version')" || die "cannot read $MANIFEST"
      tag="v$ver"
    fi
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    sha="$(fetch_upstream "$tag" "$tmp")"
    rsync -a --delete "${EXCLUDES[@]}" "$tmp/src/archify/" "$SKILL/"
    echo "$sha" > "$SKILL/.upstream-ref"
    echo "vendored archify $tag ($sha)"
    apply_patch
    echo "basalt.patch applied"
    ;;
  apply)
    apply_patch
    ;;
  save)
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    sha="$(tr -d '[:space:]' < "$SKILL/.upstream-ref")"
    git clone -q "$REPO" "$tmp/src" 2>/dev/null || die "cannot clone $REPO"
    git -C "$tmp/src" checkout -q "$sha" || die "ref $sha not found upstream"
    mkdir -p "$tmp/a" "$tmp/b"
    rsync -a "${EXCLUDES[@]}" "$tmp/src/archify/" "$tmp/a/"
    rsync -a "${EXCLUDES[@]}" --exclude /.upstream-ref "$SKILL/" "$tmp/b/"
    mkdir -p "$(dirname "$PATCH")"
    (cd "$tmp" && git diff --no-index --no-color a b || true) \
      | sed -e 's|^diff --git a/[ab]/|diff --git a/|; s| b/[ab]/| b/|; s|^--- a/a/|--- a/|; s|^+++ b/b/|+++ b/|' > "$PATCH"
    [ -s "$PATCH" ] || die "tree equals upstream: nothing to save"
    echo "saved $PATCH ($(wc -l < "$PATCH") lines)"
    ;;
  check)
    [ -s "$PATCH" ] || die "missing $PATCH"
    git -C "$ROOT" apply --reverse --check --directory=skills/archify "$PATCH" 2>/dev/null \
      || die "skills/archify does not carry basalt.patch exactly: edit the skill, then 'make archify-patch-save' (or 'make archify-update' after an upstream bump)"
    echo "archify: basalt.patch matches the vendored tree"
    ;;
  test)
    "${BASH_SOURCE[0]}" check
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    for type in architecture workflow; do
      spec="$(ls "$SKILL"/examples/*."$type".json | head -1)"
      jq '.meta.visual_preset = "basalt"' "$spec" > "$tmp/$type.json"
      node "$SKILL/bin/archify.mjs" deliver "$type" "$tmp/$type.json" "$tmp/$type.html" --quality showcase --json >/dev/null \
        || die "basalt $type does not validate and render"
      grep -q 'data-preset="basalt"' "$tmp/$type.html" || die "basalt $type: no data-preset=basalt in the output"
      grep -q 'id="basalt-tokens"' "$tmp/$type.html" || die "basalt $type: tokens not inlined"
      grep -q -- '--basalt-canvas' "$tmp/$type.html" || die "basalt $type: --basalt-* tokens missing"
    done
    # another preset must stay free of the tokens
    jq '.meta.visual_preset = "classic"' "$(ls "$SKILL"/examples/*.architecture.json | head -1)" > "$tmp/c.json"
    node "$SKILL/bin/archify.mjs" deliver architecture "$tmp/c.json" "$tmp/c.html" --json >/dev/null || die "classic render failed"
    ! grep -q 'id="basalt-tokens"' "$tmp/c.html" || die "classic output carries the basalt tokens"
    echo "archify: basalt preset renders (architecture, workflow); classic is untouched"
    ;;
  *)
    sed -n '2,11p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
