#!/bin/bash
# Maturity and churn from GitHub and npm metadata (read-only). Usage: churn.sh > ../evidence/churn.txt
ASOF="${ASOF:-2026-10-22}"
repo() { # <owner/repo> <label>
  echo "== $2 ($1), as of $ASOF"
  gh api "repos/$1" --jq '"stars \(.stargazers_count), forks \(.forks_count), open issues \(.open_issues_count), licence field \(.license.spdx_id), pushed \(.pushed_at[0:10]), created \(.created_at[0:10])"'
  gh api "repos/$1/releases?per_page=100" --jq '.[] | "\(.published_at[0:10]) \(.tag_name)"' | python3 -I -c '
import sys, datetime as dt
asof = dt.date.fromisoformat(sys.argv[1]); rows = [l.split() for l in sys.stdin if l.strip()]
n = lambda d: sum(1 for r in rows if (asof - dt.date.fromisoformat(r[0])).days <= d)
print(f"releases listed {len(rows)}; last 7 d {n(7)}, 14 d {n(14)}, 30 d {n(30)}, 90 d {n(90)}; newest {rows[0][1]} on {rows[0][0]}, previous {rows[1][1]} on {rows[1][0]}")' "$ASOF"
  echo "top contributors by commits: $(gh api "repos/$1/contributors" --jq '[.[0:5][] | .contributions] | join(", ")')"
}
repo backnotprop/plannotator "plannotator"
echo "npm @plannotator/opencode: $(npm view @plannotator/opencode version license --json 2>/dev/null | jq -c .)"
repo petergyang/human-review "human-review"
echo "npm human-review: $(npm view human-review version license dependencies --json 2>/dev/null | jq -c .)"
