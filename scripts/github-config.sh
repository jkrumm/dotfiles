#!/usr/bin/env bash
# Apply consistent branch protection, merge settings, and shared secrets to all
# GitHub repos.
#
# Two ruleset tiers, chosen per repo so the GitHub layer matches the Claude hook
# (hooks/protect-branches.ts) instead of blanketing every repo with require-PR:
#
#   FULL (github-ruleset-full.json) — require PR to master.
#     Applied to: repos in config/pr-required-repos.json (the real apps) AND any
#     repo that has a collaborator (so others can't push to master).
#
#   LITE (github-ruleset-lite.json) — no PR rule, just no-force / no-deletion /
#     linear-history. Applied to every other PUBLIC repo (direct-to-master, solo).
#     A normal push violates no rule, so there is NO admin-bypass warning — clean
#     direct pushes, and the GitHub layer agrees with the hook.
#
# Both tiers share the ruleset name "protect-default-branch", so flipping a repo
# full<->lite updates it in place.
#
# WHY the split: a require-PR rule with admin bypass prints
# "Bypassed rule violations ... Changes must be made through a pull request" on
# every successful direct push. On direct-to-master repos that warning is noise
# that confuses tooling. LITE removes the PR rule there, so the warning is gone.
#
# SECURITY MODEL:
#   - Random people can never push to your repos at all (basic GitHub access
#     control) — the ruleset is irrelevant to them.
#   - Collaborators (write access you granted) are blocked from master only on
#     FULL-tier repos. That's why any repo with a collaborator auto-gets FULL.
#   - You (RepositoryRole/Admin, actor_id 5) bypass always — direct push + the
#     release-CI PAT keep working.
#
# PRIVATE REPOS — free-tier gap:
#   Rulesets and classic branch protection on PRIVATE repos require GitHub Pro.
#   Nothing can be applied via API on the free tier. While you are the sole
#   collaborator this is fine. If you ever add a collaborator to a private repo,
#   they could push to master with nothing stopping them server-side — upgrade to
#   Pro or keep private repos solo. The Claude hook only runs on your machine, so
#   it protects against nobody else.
#
# CI that pushes to master (e.g. semantic-release on FULL-tier repos):
#   Must authenticate as you via a PAT (RELEASE_TOKEN secret), not the default
#   GITHUB_TOKEN — github-actions[bot] has no bypass rights on personal repos.
#   Fine-grained PAT, contents:write on the target repo, owned by jkrumm.
#
# Enforced merge settings (all public repos): rebase-only, auto-delete branches.
#
# ADDING A PR-REQUIRED REPO:
#   Add its name to config/pr-required-repos.json. That one file drives BOTH the
#   Claude hook (blocks your pushes) and this script (applies FULL). Re-run.
#
# ADDING A SHARED SECRET:
#   Append to config/github-secrets.json {name, op_ref}. Values read live from
#   1Password (account: tkrumm); only op:// refs live in git. Re-run.
#
# Usage:
#   ./scripts/github-config.sh              # all repos for jkrumm
#   GITHUB_OWNER=other ./scripts/github-config.sh
#   DRY_RUN=1 ./scripts/github-config.sh    # preview tiers without applying
#
# Prerequisites: gh CLI authenticated (gh auth status); jq; op CLI (for secrets)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULESET_FULL="$SCRIPT_DIR/../config/github-ruleset-full.json"
RULESET_LITE="$SCRIPT_DIR/../config/github-ruleset-lite.json"
PR_REQUIRED_FILE="$SCRIPT_DIR/../config/pr-required-repos.json"
SECRETS_FILE="$SCRIPT_DIR/../config/github-secrets.json"
OWNER="${GITHUB_OWNER:-jkrumm}"
DRY_RUN="${DRY_RUN:-0}"

for f in "$RULESET_FULL" "$RULESET_LITE" "$PR_REQUIRED_FILE"; do
  if [ ! -f "$f" ]; then
    echo "Error: required config not found at $f" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required (ruleset processing + denylist lookup)." >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "Error: not authenticated with gh CLI. Run: gh auth login" >&2
  exit 1
fi

# Repo is in the PR-required denylist (config/pr-required-repos.json).
is_pr_required() {
  jq -e --arg r "$1" '.repos | index($r)' "$PR_REQUIRED_FILE" >/dev/null 2>&1
}

# Repo has at least one collaborator other than the owner.
has_collaborator() {
  local count
  count=$(gh api "repos/$OWNER/$1/collaborators" \
    --jq "[.[] | select(.login != \"$OWNER\")] | length" 2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ]
}

# Decide tier for a public repo. Echoes "tier|reason" (parsed by the caller —
# can't use a global because callers invoke this in a command substitution).
choose_tier() {
  if is_pr_required "$1"; then echo "full|PR-required (denylist)"; return; fi
  if has_collaborator "$1"; then echo "full|has collaborator"; return; fi
  echo "lite|direct-to-master"
}

# Apply a ruleset file to a repo, creating or updating the "protect-default-branch"
# ruleset in place. $comment is stripped before sending (GitHub rejects it).
apply_ruleset() {
  local repo="$1" file="$2" body existing_id
  body=$(jq 'del(.["$comment"])' "$file")
  existing_id=$(gh api "repos/$OWNER/$repo/rulesets" \
    --jq '.[] | select(.name=="protect-default-branch") | .id' 2>/dev/null | head -1 || echo "")
  if [ -n "$existing_id" ]; then
    printf '%s' "$body" | gh api "repos/$OWNER/$repo/rulesets/$existing_id" \
      -X PUT --input - --silent 2>/dev/null
  else
    printf '%s' "$body" | gh api "repos/$OWNER/$repo/rulesets" \
      -X POST --input - --silent 2>/dev/null
  fi
}

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
    if [ "$is_private" = "true" ]; then
      echo "  [dry] $OWNER/$repo — PRIVATE (no ruleset; free-tier gap, hook only)"
    else
      sel=$(choose_tier "$repo"); tier="${sel%%|*}"; reason="${sel#*|}"
      echo "  [dry] $OWNER/$repo — $(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]') ($reason)"
    fi
    if [ "$have_secrets" = "1" ]; then
      while IFS=$'\t' read -r name _value; do
        echo "         would sync secret: $name"
      done < "$SECRETS_TMP"
    fi
    continue
  fi

  echo "  → $OWNER/$repo"

  if [ "$is_private" = "true" ]; then
    echo "    ⚠ private repo — server-side protection needs GitHub Pro (free-tier gap)"
    echo "    · solo here, so OK; Claude hook still blocks your pushes if PR-required"
    ((ok++)) || true
  else
    sel=$(choose_tier "$repo"); tier="${sel%%|*}"; reason="${sel#*|}"
    file="$RULESET_LITE"
    [ "$tier" = "full" ] && file="$RULESET_FULL"
    if apply_ruleset "$repo" "$file"; then
      echo "    ✓ ${tier} ruleset ($reason)"
      ((ok++)) || true
    else
      echo "    ✗ ${tier} ruleset failed" >&2
      ((failed++)) || true
    fi
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
