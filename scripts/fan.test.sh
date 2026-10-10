#!/usr/bin/env bash
# fan.test — fan-worktree.sh against scratch repos. The property under test: the worktree is
# cut from FETCHED origin state even when the local checkout is stale or ahead.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fan-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }
g()   { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

g init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
echo a > "$TMP/repo/f"; g -C "$TMP/repo" add f; g -C "$TMP/repo" commit -qm one; g -C "$TMP/repo" push -q origin master
# a second clone advances origin; the local checkout stays stale
g clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
echo b > "$TMP/other/f"; g -C "$TMP/other" commit -qam two; g -C "$TMP/other" push -q origin master
want=$(g -C "$TMP/other" rev-parse HEAD)
# and the stale checkout carries an unpushed commit that must NOT leak into the worktree
echo local > "$TMP/repo/g"; g -C "$TMP/repo" add g; g -C "$TMP/repo" commit -qm unpushed

out=$("$HERE/fan-worktree.sh" "$TMP/repo" fan/one) || { bad "fan-worktree failed"; exit 1; }
path=$(sed -n 1p <<<"$out"); base=$(sed -n 2p <<<"$out"); sha=$(sed -n 3p <<<"$out")
is "base ref is origin/master" "$base" "origin/master"
is "base sha is the fetched origin tip" "$sha" "$want"
is "worktree HEAD is the fetched origin tip" "$(g -C "$path" rev-parse HEAD)" "$want"
[ ! -e "$path/g" ] && ok "unpushed local commit absent from worktree" || bad "unpushed local commit leaked"
is "branch has no upstream" "$(g -C "$path" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo none)" "none"
"$HERE/fan-worktree.sh" "$TMP/repo" fan/one >/dev/null 2>&1 && bad "duplicate branch accepted" || ok "duplicate branch refused"
"$HERE/merge-train.sh" "$TMP/repo" fan/one >/dev/null 2>&1 && bad "train accepted a non-GitHub origin" || ok "train refuses a non-GitHub origin"

# fan-list: unmerged worktree is kept; after its branch lands on origin it is dropped; dirty is kept
echo x > "$path/new"; g -C "$path" add new; g -C "$path" commit -qm work
is "unmerged worktree is kept" "$("$HERE/fan-list.sh" "$TMP/repo" | cut -f1,4)" "$(printf 'keep\tunmerged')"
# GitHub rebase-merge rewrites SHAs: land the same patch on origin/master as a NEW commit
g -C "$path" push -q origin fan/one
g -C "$TMP/other" pull -q origin master 2>/dev/null
g -C "$TMP/other" fetch -q origin fan/one
GIT_COMMITTER_DATE="2001-01-01T00:00:00" g -C "$TMP/other" cherry-pick "$(g -C "$path" rev-parse HEAD)" >/dev/null 2>&1
g -C "$TMP/other" push -q origin master
is "merged worktree is dropped" "$("$HERE/fan-list.sh" "$TMP/repo" | cut -f1,4)" "$(printf 'drop\tmerged')"
echo dirt > "$path/dirt"
is "dirty worktree is kept" "$("$HERE/fan-list.sh" "$TMP/repo" | cut -f1,4)" "$(printf 'keep\tdirty')"

# main-default repo without origin/HEAD: the scripts must find origin/main
g init -q --bare -b main "$TMP/m.git"
g clone -q "$TMP/m.git" "$TMP/mrepo" 2>/dev/null
echo a > "$TMP/mrepo/f"; g -C "$TMP/mrepo" add f; g -C "$TMP/mrepo" commit -qm one; g -C "$TMP/mrepo" push -q origin HEAD:main
g -C "$TMP/mrepo" remote set-head origin -d >/dev/null 2>&1 || true
mo=$("$HERE/fan-worktree.sh" "$TMP/mrepo" fan/m) || bad "main-default fan-worktree failed"
is "main-default: base is origin/main" "$(sed -n 2p <<<"$mo")" "origin/main"
is "fresh worktree is kept, not dropped" "$("$HERE/fan-list.sh" "$TMP/mrepo" | cut -f1,4)" "$(printf 'keep\tfresh')"

echo; [ "$fails" -eq 0 ] && echo "fan: all passed" || { echo "fan: $fails failed"; exit 1; }
