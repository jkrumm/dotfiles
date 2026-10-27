#!/usr/bin/env bash
# merge-train.test — merge-train.sh against a scratch repo with `gh`, `bun` and the GitHub-host
# guard stubbed on PATH. Properties under test: the check is preceded by a lockfile-matched
# install (and a failed install is a red check), --no-check skips the install, a draft PR is
# readied before the merge, and a failed merge reports gh's own error instead of "main moved".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/merge-train-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
REAL_GIT=$(command -v git)
g() { "$REAL_GIT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

mkdir "$TMP/bin" "$TMP/state"
# git: the train refuses non-GitHub origins, so fake only `remote get-url`; the remote itself
# stays a local bare repo.
cat >"$TMP/bin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = get-url ] && { echo https://github.com/t/r.git; exit 0; }; done
exec "$REAL_GIT" "\$@"
STUB
# gh: state in \$STATE — isDraft (true|false), merge_err (text; non-empty = merge fails), log.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STATE/log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *isDraft*) cat "$STATE/isDraft" ;;
      *) echo 7 ;;
    esac ;;
  "pr ready") echo false >"$STATE/isDraft" ;;
  "pr merge")
    if [ "$(cat "$STATE/isDraft")" = true ]; then echo "Pull request #7 is still a draft" >&2; exit 1; fi
    if [ -s "$STATE/merge_err" ]; then cat "$STATE/merge_err" >&2; exit 1; fi ;;
esac
STUB
# bun: records the call; fails when $STATE/bun_fail exists.
cat >"$TMP/bin/bun" <<'STUB'
#!/usr/bin/env bash
echo "bun $*" >>"$STATE/log"
[ -e "$STATE/bun_hang" ] && sleep 30
[ -e "$STATE/bun_fail" ] && { echo "lockfile had changes" >&2; exit 1; }
exit 0
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x

g init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
echo a >"$TMP/repo/f"; g -C "$TMP/repo" add f; g -C "$TMP/repo" commit -qm one; g -C "$TMP/repo" push -q origin master

n=0
# branch <lockfile|-> : a committed worktree on a fresh branch; sets $br
branch() {
  n=$((n + 1)); br="t/b$n"
  g -C "$TMP/repo" worktree add -q -b "$br" "$TMP/wt$n" origin/master 2>/dev/null
  [ "$1" != - ] && echo '{}' >"$TMP/wt$n/$1"
  echo "$n" >"$TMP/wt$n/work"
  g -C "$TMP/wt$n" add -A; g -C "$TMP/wt$n" commit -qm "work $n"
}
reset() { : >"$STATE/log"; : >"$STATE/merge_err"; echo false >"$STATE/isDraft"; rm -f "$STATE/bun_fail" "$STATE/bun_hang"; }
train() { out=$("$HERE/merge-train.sh" "$TMP/repo" "$@" 2>&1); rc=$?; }

echo "install before check"
reset; branch bun.lock; train --check "echo check >>$STATE/log" "$br"
is "bun repo: train succeeds" "$rc" "0"
log=$(cat "$STATE/log")
has "bun.lock → bun install --frozen-lockfile" "$log" "bun install --frozen-lockfile"
is "install runs before the check" "$(grep -n -E '^(bun install|check)' "$STATE/log" | cut -d: -f2 | cut -d' ' -f1 | paste -sd, -)" "bun,check"

reset; branch bun.lock; echo 1 >"$STATE/bun_fail"; train --check "echo check >>$STATE/log" "$br"
is "failed install is a red train" "$rc" "1"
has "failed install is named" "$out" "dependency install failed"
lacks "check not run after a failed install" "$(cat "$STATE/log")" "check"
lacks "nothing merged after a failed install" "$(cat "$STATE/log")" "pr merge"

reset; branch bun.lock; echo 1 >"$STATE/bun_hang"; RD_INSTALL_TIMEOUT=1 train --check "echo check >>$STATE/log" "$br"
is "hung install is a red train" "$rc" "1"
has "hung install is named" "$out" "dependency install timed out after 1s"
lacks "check not run after a hung install" "$(cat "$STATE/log")" "check"

reset; branch -; train --check "echo check >>$STATE/log" "$br"
is "no lockfile: train succeeds" "$rc" "0"
lacks "no lockfile: no install" "$(cat "$STATE/log")" "install"

reset; branch bun.lock; train --no-check "$br"
is "--no-check: train succeeds" "$rc" "0"
lacks "--no-check skips the install" "$(cat "$STATE/log")" "bun "

echo "draft PRs"
reset; branch -; echo true >"$STATE/isDraft"; train --no-check "$br"
is "draft: train succeeds" "$rc" "0"
has "draft: gh pr ready ran" "$(cat "$STATE/log")" "gh pr ready 7"
has "draft: readying is logged" "$out" "ready for review (it was a draft)"
lacks "draft: no re-rebase churn" "$out" "re-rebasing"

reset; branch -; train --no-check "$br"
lacks "ready PR: gh pr ready not called" "$(cat "$STATE/log")" "pr ready"

echo "merge failure message"
reset; branch -; echo "GraphQL: Merge conflict not by main" >"$STATE/merge_err"; train --no-check "$br"
is "persistent merge failure: train fails" "$rc" "1"
has "failure prints gh's own error" "$out" "GraphQL: Merge conflict not by main"
lacks "failure does not assume main moved" "$out" "main probably moved"

echo; [ "$fails" -eq 0 ] && echo "merge-train: all passed" || { echo "merge-train: $fails failed"; exit 1; }
