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
# A repo named in `mergeMethod` of config/pr-required-repos.json gets squash-only
# instead (software-factory: its leads `gh pr merge --squash`, the PR number sits
# in every subject). The FULL ruleset needs no approval and bypasses for the
# owner's admin role, so a lead's merge of a green PR passes without --admin.
#
# ADDING A PR-REQUIRED REPO:
#   Add its name to config/pr-required-repos.json. That one file drives BOTH the
#   Claude hook (blocks your pushes) and this script (applies FULL). Re-run.
#
# ADDING A SHARED SECRET:
#   Append to config/github-secrets.json {name, op_ref}. Values read live from
#   1Password (account: tkrumm); only op:// refs live in git. Re-run.
#
# TIGHTEN-ONLY MODE (--tighten-only, TIGHTEN_ONLY=1; always on when FACTORY_SESSION
# is set, i.e. in every factory session — `make github-config` there IS this mode):
#   Per repo, compare the wanted ruleset with the one GitHub holds and write only if
#   every difference adds or strengthens protection (ruleset created, rule added,
#   approvals raised, enforcement raised, bypass actor removed, refs added). A repo
#   where anything loosens — a rule or ref dropped, approvals lowered, enforcement
#   lowered, a bypass actor added — or that cannot be compared (read failure, a rule
#   parameter this script does not know) is SKIPPED, nothing written for it, and the
#   run exits 3: that is the owner's `make github-config` by hand (a factory lead
#   raises an Errand), because dotfiles is direct-to-master and a lead could
#   otherwise edit the list and remove its own review gate. Merge settings (the
#   merge method, never a merge commit) are not protection and apply to every repo
#   not skipped. Shared secrets are skipped. A repo already as wanted is not written.
#
# Usage:
#   ./scripts/github-config.sh              # all repos for jkrumm
#   GITHUB_OWNER=other ./scripts/github-config.sh
#   DRY_RUN=1 ./scripts/github-config.sh    # preview tiers without applying
#   ./scripts/github-config.sh --tighten-only   # `make github-config-tighten`
#   DRY_RUN=1 ./scripts/github-config.sh --tighten-only   # the verdict per repo, no writes
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
TIGHTEN_ONLY="${TIGHTEN_ONLY:-0}"
for arg in "$@"; do
  [ "$arg" = --tighten-only ] && TIGHTEN_ONLY=1
done
# A factory session never runs the loosening sync: no flag turns this off.
[ -n "${FACTORY_SESSION:-}" ] && TIGHTEN_ONLY=1

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

# The one merge method left allowed on a repo: `mergeMethod` in the same file
# (squash|rebase), default rebase. Anything else falls back to rebase.
merge_method() {
  local m
  m=$(jq -r --arg r "$1" '.mergeMethod[$r] // "rebase"' "$PR_REQUIRED_FILE" 2>/dev/null || echo rebase)
  [ "$m" = squash ] && echo squash || echo rebase
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

# Is applying the wanted ruleset ($2, a file) to a repo ($1) a tightening? Reads
# GitHub's current "protect-default-branch" ruleset and echoes "verdict|reasons":
#   same        nothing to write
#   tighten     every difference adds or strengthens protection (or no ruleset yet)
#   loosen      something drops or weakens
#   undecidable GitHub could not be read, or a difference this does not know how to rank
# Only `same` and `tighten` may be applied in tighten-only mode; the rest fail closed.
# A rule parameter GitHub returns beyond the file's (its own defaults) counts as
# unchanged when it holds that default, since the PUT would reset it to exactly that.
RULESET_VERDICT='
def rk: {"active":2,"evaluate":1,"disabled":0}[.] // -1;
def dflt: {"required_reviewers":[],"allowed_merge_methods":["merge","squash","rebase"],"require_extra_approval_for_unattributed_changes":true};
def prbool: ["dismiss_stale_reviews_on_push","require_code_owner_review","require_last_push_approval","required_review_thread_resolution"];
def prknown: prbool + ["required_approving_review_count"];
def prloose($l; $w):
  [ if ($w.required_approving_review_count // 0) < ($l.required_approving_review_count // 0) then "required approvals drop" else empty end ]
  + [ prbool[] as $k | select(($l[$k] // false) and (($w[$k] // false) | not)) | "pull_request.\($k) turned off" ]
  + [ ($l | keys[]) as $k | select($k | IN(prknown[]) | not) | select($w | has($k) | not)
      | select($l[$k] != (dflt[$k] // "unknown")) | "pull_request.\($k) would be reset" ]
  + [ ($l | keys[]) as $k | select($k | IN(prknown[]) | not) | select($w | has($k))
      | select($l[$k] != $w[$k]) | "pull_request.\($k) differs (cannot compare)" ];
def proj($x; $w):
  { enforcement: $x.enforcement, target: $x.target,
    include: (($x.conditions.ref_name.include // []) | sort),
    exclude: (($x.conditions.ref_name.exclude // []) | sort),
    bypass: (($x.bypass_actors // []) | map({actor_id, actor_type, bypass_mode}) | sort_by([.actor_type, .actor_id])),
    rules: (($x.rules // []) | map(. as $r
      | {type: $r.type, parameters: (($r.parameters // {}) | with_entries(select(.key as $k
          | (($w.rules // []) | map(select(.type == $r.type)) | first | .parameters // {} | has($k)))))})
      | sort_by(.type)) };
def loosen($l; $w):
  [ if ($w.enforcement | rk) < ($l.enforcement | rk) then "enforcement \($l.enforcement) -> \($w.enforcement)" else empty end ]
  + [ if $w.target != $l.target then "target \($l.target) -> \($w.target)" else empty end ]
  + [ if (($l.conditions // {}) | keys) != ["ref_name"] then "conditions beyond ref_name (cannot compare)" else empty end ]
  + [ (($l.conditions.ref_name.include // []) - ($w.conditions.ref_name.include // []))[] | "stops protecting \(.)" ]
  + [ (($w.conditions.ref_name.exclude // []) - ($l.conditions.ref_name.exclude // []))[] | "newly excludes \(.)" ]
  + [ ($w.bypass_actors // [])[] as $b
      | (($l.bypass_actors // []) | map(select(.actor_id == $b.actor_id and .actor_type == $b.actor_type)) | first) as $lb
      | if $lb == null then "adds bypass actor \($b.actor_type) \($b.actor_id)"
        elif $b.bypass_mode == $lb.bypass_mode or ($b.bypass_mode == "pull_request" and $lb.bypass_mode == "always") then empty
        else "bypass mode of \($b.actor_type) \($b.actor_id): \($lb.bypass_mode) -> \($b.bypass_mode)" end ]
  + [ ($l.rules // [])[] as $lr
      | (($w.rules // []) | map(select(.type == $lr.type)) | first) as $wr
      | if $wr == null then "rule \($lr.type) removed"
        elif $lr.type == "pull_request" then prloose($lr.parameters // {}; $wr.parameters // {})[]
        elif ($lr.parameters // null) != ($wr.parameters // null) then "rule \($lr.type) parameters differ (cannot compare)"
        else empty end ];
. as $live | $want[0] as $w
| if proj($live; $w) == proj($w; $w) then {verdict: "same", reasons: []}
  else loosen($live; $w) as $loose
  | if ($loose | length) > 0 then {verdict: "loosen", reasons: $loose}
    else {verdict: "tighten", reasons: ["adds or strengthens protection"]} end end
| "\(.verdict)|\(.reasons | join("; "))"
'

classify_ruleset() {
  local repo="$1" file="$2" id live
  if ! id=$(gh api "repos/$OWNER/$repo/rulesets" \
      --jq '[.[] | select(.name=="protect-default-branch") | .id] | first // empty' 2>/dev/null); then
    echo "undecidable|could not list the rulesets"; return
  fi
  if [ -z "$id" ]; then echo "tighten|create the ruleset"; return; fi
  if ! live=$(gh api "repos/$OWNER/$repo/rulesets/$id" 2>/dev/null); then
    echo "undecidable|could not read ruleset $id"; return
  fi
  printf '%s' "$live" | jq -r --slurpfile want "$file" "$RULESET_VERDICT" 2>/dev/null \
    || echo "undecidable|could not compare ruleset $id"
}

echo ""
echo "  GitHub Config — $OWNER"
[ "$DRY_RUN" = "1" ] && echo "  DRY RUN — no changes will be made"
[ "$TIGHTEN_ONLY" = "1" ] && echo "  TIGHTEN-ONLY — writes only what adds or strengthens protection"
echo ""

# Resolve shared secrets from 1Password once, up front. The values land in a
# tempfile cleaned up on exit. Skipping the whole feature is fine — branch
# protection + merge settings still apply.
#
# Reads go through `secrets-run` when it exists (same shim as everywhere else:
# passthrough to biometric `op` on the MacBook, offline cache on the headless mini,
# where a bare `op read` would hang on a prompt nobody can answer). `secrets-run`
# defaults to the tkrumm account, matching the `--account tkrumm` below. A ref that
# is not in the mini's cache fails closed in ~0s and the loop reports it, which is
# the wanted headless behaviour — this whole block is optional.
op_read() {  # $1 = op:// ref
  if command -v secrets-run >/dev/null 2>&1; then
    secrets-run read "$1" </dev/null 2>/dev/null
  else
    op read "$1" --account tkrumm </dev/null 2>/dev/null
  fi
}

SECRETS_TMP=""
have_secrets=0
if [ "$TIGHTEN_ONLY" = "1" ]; then
  echo "  Tighten-only: shared secret sync skipped (the owner's full \`make github-config\`)"
  echo ""
elif [ -f "$SECRETS_FILE" ]; then
  if ! command -v secrets-run >/dev/null 2>&1 && ! command -v op >/dev/null 2>&1; then
    echo "  ⚠ neither secrets-run nor op found — secret sync skipped"
    echo ""
  else
    secret_count=$(jq '.secrets | length' "$SECRETS_FILE")
    if [ "$secret_count" -gt 0 ]; then
      echo "  Resolving $secret_count secret(s) from 1Password..."
      SECRETS_TMP=$(mktemp)
      trap 'rm -f "$SECRETS_TMP"' EXIT

      resolve_failed=0
      while IFS=$'\t' read -r name op_ref; do
        if value=$(op_read "$op_ref") && [ -n "$value" ]; then
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
skipped=0

while IFS=" " read -r repo is_private; do
  if [ "$DRY_RUN" = "1" ]; then
    if [ "$is_private" = "true" ]; then
      echo "  [dry] $OWNER/$repo — PRIVATE (no ruleset; free-tier gap, hook only)"
    else
      sel=$(choose_tier "$repo"); tier="${sel%%|*}"; reason="${sel#*|}"
      echo "  [dry] $OWNER/$repo — $(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]') ($reason)"
      if [ "$TIGHTEN_ONLY" = "1" ]; then
        file="$RULESET_LITE"; [ "$tier" = "full" ] && file="$RULESET_FULL"
        verdict_line=$(classify_ruleset "$repo" "$file")
        echo "         ${verdict_line%%|*}: ${verdict_line#*|}"
        case "${verdict_line%%|*}" in same|tighten) ;; *) ((skipped++)) || true ;; esac
      fi
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
    verdict="tighten"; verdict_reasons=""
    if [ "$TIGHTEN_ONLY" = "1" ]; then
      verdict_line=$(classify_ruleset "$repo" "$file")
      verdict="${verdict_line%%|*}"; verdict_reasons="${verdict_line#*|}"
    fi
    if [ "$verdict" = "same" ]; then
      echo "    · ${tier} ruleset already as wanted"
      ((ok++)) || true
    elif [ "$verdict" != "tighten" ]; then
      echo "    ✗ SKIPPED — ${verdict}: ${verdict_reasons}" >&2
      ((skipped++)) || true
      continue
    elif apply_ruleset "$repo" "$file"; then
      echo "    ✓ ${tier} ruleset ($reason)"
      ((ok++)) || true
    else
      echo "    ✗ ${tier} ruleset failed" >&2
      ((failed++)) || true
    fi
  fi

  # Apply merge strategy regardless of protection method
  method=$(merge_method "$repo")
  allow_squash=false; allow_rebase=true
  [ "$method" = squash ] && { allow_squash=true; allow_rebase=false; }
  if gh api "repos/$OWNER/$repo" -X PATCH \
      --field allow_merge_commit=false \
      --field allow_squash_merge="$allow_squash" \
      --field allow_rebase_merge="$allow_rebase" \
      --field delete_branch_on_merge=true \
      --silent 2>/dev/null; then
    echo "    ✓ ${method}-only merge, auto-delete branches"
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
if [ "$TIGHTEN_ONLY" = "1" ]; then
  echo "  Done: $ok configured, $failed failed, $skipped skipped"
else
  echo "  Done: $ok configured, $failed failed"
fi
echo ""
if [ "$skipped" -gt 0 ]; then
  echo "  $skipped repo(s) skipped: applying the wanted state would loosen protection or cannot be compared." >&2
  echo "  That is the owner's \`make github-config\` by hand. A factory lead raises an Errand" >&2
  echo "  (\`factory errand raise … --need hands\`) naming the repos above; it never edits around this." >&2
  echo "" >&2
  exit 3
fi
