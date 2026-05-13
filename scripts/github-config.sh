#!/usr/bin/env bash
# Apply consistent branch protection, merge settings, and shared secrets to all
# GitHub repos.
#
# Strategy:
#   Public repos → GitHub Rulesets (modern, supports bypass actors)
#   Private repos on free tier → No API protection available (requires GitHub Pro)
#                                 Claude Code hook (protect-branches.ts) still applies
#
# Enforces per repo:
#   - Pull request required to merge to main/master (0 approvals — solo dev)
#   - No force pushes (Rulesets: admin bypass; Classic: enforce_admins=false)
#   - Linear history required before merge
#   - No branch deletion
#   - Rebase merge only (no merge commits, no squash)
#   - Auto-delete merged branches
#   - Shared secrets (config/github-secrets.json) synced from 1Password
#
# Bypass actors (see github-ruleset.json):
#   - RepositoryRole/Admin (actor_id: 5) — you, pushing directly from terminal
#
#   NOTE: Integration/GitHub Actions bypass is NOT available for personal account
#   repos — only orgs/enterprise. CI workflows that push to master (e.g. semantic-
#   release) must authenticate as you via a PAT (RELEASE_TOKEN secret) rather than
#   the default GITHUB_TOKEN (github-actions[bot] has no bypass rights).
#   PAT requirements: fine-grained, contents:write on the target repo, owned by
#   jkrumm so it carries admin bypass rights.
#
# WHEN ADDING COLLABORATORS:
#   Bump required_approving_review_count from 0 to 1 in github-ruleset.json,
#   then re-run this script. PR review gates all workflow changes before they
#   land. The PAT approach is safe with collaborators — they cannot push to
#   master directly, and PR review prevents them from landing workflow changes
#   that abuse a PAT secret.
#
# ADDING A SHARED SECRET:
#   Append an entry to config/github-secrets.json with {name, op_ref}. Values are
#   read live from 1Password at runtime (account: tkrumm); only op:// refs live
#   in git. Re-run `make github-config` to fan it out to every repo. Rotating a
#   secret = update the field in 1P, re-run, done.
#
# Usage:
#   ./scripts/github-config.sh              # all repos for jkrumm
#   GITHUB_OWNER=other ./scripts/github-config.sh
#   DRY_RUN=1 ./scripts/github-config.sh   # preview without applying
#
# Prerequisites: gh CLI authenticated (gh auth status); op CLI signed into tkrumm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULESET_FILE="$SCRIPT_DIR/../config/github-ruleset.json"
SECRETS_FILE="$SCRIPT_DIR/../config/github-secrets.json"
OWNER="${GITHUB_OWNER:-jkrumm}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$RULESET_FILE" ]; then
  echo "Error: ruleset file not found at $RULESET_FILE" >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "Error: not authenticated with gh CLI. Run: gh auth login" >&2
  exit 1
fi

echo ""
echo "  GitHub Config — $OWNER"
[ "$DRY_RUN" = "1" ] && echo "  DRY RUN — no changes will be made"
echo ""

# Resolve shared secrets from 1Password once, up front. The values land in a
# tempfile cleaned up on exit. Skipping the whole feature is fine — branch
# protection + merge settings still apply.
SECRETS_TMP=""
have_secrets=0
if [ -f "$SECRETS_FILE" ]; then
  if ! command -v op >/dev/null 2>&1; then
    echo "  ⚠ op CLI not found — secret sync skipped"
    echo ""
  elif ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — secret sync skipped"
    echo ""
  else
    secret_count=$(jq '.secrets | length' "$SECRETS_FILE")
    if [ "$secret_count" -gt 0 ]; then
      echo "  Resolving $secret_count secret(s) from 1Password..."
      SECRETS_TMP=$(mktemp)
      trap 'rm -f "$SECRETS_TMP"' EXIT

      resolve_failed=0
      while IFS=$'\t' read -r name op_ref; do
        if value=$(op read "$op_ref" --account tkrumm 2>/dev/null) && [ -n "$value" ]; then
          printf '%s\t%s\n' "$name" "$value" >> "$SECRETS_TMP"
          echo "    ✓ $name ← $op_ref"
        else
          echo "    ✗ $name ← $op_ref (read failed)" >&2
          resolve_failed=1
        fi
      done < <(jq -r '.secrets[] | "\(.name)\t\(.op_ref)"' "$SECRETS_FILE")

      if [ -s "$SECRETS_TMP" ]; then
        have_secrets=1
      fi
      [ "$resolve_failed" = "1" ] && echo "  ⚠ some secrets failed to resolve — continuing with the rest"
      echo ""
    fi
  fi
fi

repos=$(gh repo list "$OWNER" \
  --limit 200 \
  --no-archived \
  --json name,isPrivate \
  --jq '.[] | "\(.name) \(.isPrivate)"')

total=$(echo "$repos" | wc -l | xargs)
echo "  Found $total non-archived repos"
echo ""

ok=0
failed=0

while IFS=" " read -r repo is_private; do
  if [ "$DRY_RUN" = "1" ]; then
    [ "$is_private" = "true" ] \
      && echo "  [dry] $OWNER/$repo (private → hook only, no API on free tier)" \
      || echo "  [dry] $OWNER/$repo (public → ruleset)"
    if [ "$have_secrets" = "1" ]; then
      while IFS=$'\t' read -r name _value; do
        echo "         would sync secret: $name"
      done < "$SECRETS_TMP"
    fi
    continue
  fi

  echo "  → $OWNER/$repo"

  if [ "$is_private" = "true" ]; then
    # Private repos: GitHub Rulesets AND classic branch protection both require
    # GitHub Pro on private repos. Nothing can be applied via API on free tier.
    # Protection is provided solely by the Claude Code hook (hooks/protect-branches.ts).
    echo "    ⚠ private repo — GitHub API protection requires Pro subscription"
    echo "    · Claude Code hook (protect-branches.ts) still blocks pushes to main/master"
    ((ok++)) || true
  else
    # Public repo: use Rulesets
    existing_id=$(gh api "repos/$OWNER/$repo/rulesets" \
      --jq '.[] | select(.name=="protect-default-branch") | .id' 2>/dev/null || echo "")

    ruleset_ok=false
    if [ -n "$existing_id" ]; then
      if gh api "repos/$OWNER/$repo/rulesets/$existing_id" \
          -X PUT --input "$RULESET_FILE" --silent 2>/dev/null; then
        echo "    ✓ ruleset updated (id: $existing_id)"
        ruleset_ok=true
      else
        echo "    ✗ ruleset update failed" >&2
      fi
    else
      new_id=$(gh api "repos/$OWNER/$repo/rulesets" \
        -X POST --input "$RULESET_FILE" --jq '.id' 2>/dev/null || echo "")
      if [ -n "$new_id" ]; then
        echo "    ✓ ruleset created (id: $new_id)"
        ruleset_ok=true
      else
        echo "    ✗ ruleset creation failed" >&2
      fi
    fi
    if $ruleset_ok; then ((ok++)) || true; else ((failed++)) || true; fi
  fi

  # Apply merge strategy regardless of protection method
  if gh api "repos/$OWNER/$repo" -X PATCH \
      --field allow_merge_commit=false \
      --field allow_squash_merge=false \
      --field allow_rebase_merge=true \
      --field delete_branch_on_merge=true \
      --silent 2>/dev/null; then
    echo "    ✓ rebase-only merge, auto-delete branches"
  else
    echo "    ✗ merge settings update failed" >&2
  fi

  if [ "$have_secrets" = "1" ]; then
    while IFS=$'\t' read -r name value; do
      if printf '%s' "$value" | gh secret set "$name" --repo "$OWNER/$repo" >/dev/null 2>&1; then
        echo "    ✓ secret: $name"
      else
        echo "    ✗ secret: $name (set failed)" >&2
      fi
    done < "$SECRETS_TMP"
  fi

done <<< "$repos"

echo ""
echo "  Done: $ok configured, $failed failed"
echo ""
