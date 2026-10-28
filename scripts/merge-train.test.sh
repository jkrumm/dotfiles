#!/usr/bin/env bash
# merge-train.test — merge-train.sh against a scratch repo with `gh`, `bun` and the GitHub-host
# guard stubbed on PATH. Properties under test: the check is preceded by a lockfile-matched
# install (and a failed install is a red check), --no-check skips the install, a draft PR is
# readied before the merge, a failed merge reports gh's own error instead of "main moved", and CI
# on the pushed head gates the merge: pass → merged, fail/cancel → died naming the check, pending
# polled to green, nothing declared green before the grace or from a partial/skipping-only list,
# no checks → merged after the grace, pending past RD_CI_TIMEOUT → died, a stale head not trusted,
# a gh error retried, a hung gh bounded.
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
# gh: state in $STATE — isDraft (true|false), merge_err (text; non-empty = merge fails), log, and
# for `pr view --json headRefOid,statusCheckRollup,url`: ci_rollups (one rollup JSON array per line,
# line N on poll N, the last line repeats), ci_stale (N = the head is a stale sha for the first N
# polls; -1 = forever), ci_err (N = the first N polls exit 1), ci_hang (exists = sleeps 30).
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STATE/log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *isDraft*) cat "$STATE/isDraft" ;;
      *headRefOid*)
        [ -e "$STATE/ci_hang" ] && sleep 30
        seen=$(cat "$STATE/ci_seen"); echo $((seen + 1)) >"$STATE/ci_seen"
        if [ "$seen" -lt "$(cat "$STATE/ci_err")" ]; then echo "HTTP 502" >&2; exit 1; fi
        stale=$(cat "$STATE/ci_stale")
        if [ "$stale" -lt 0 ] || [ "$seen" -lt "$stale" ]; then head=0000000000000000000000000000000000000000
        else head=$(git rev-parse HEAD); fi
        lines=$(wc -l <"$STATE/ci_rollups"); line=$((seen + 1)); [ "$line" -gt "$lines" ] && line=$lines
        printf '{"headRefOid":"%s","url":"https://gh/pull/7","statusCheckRollup":%s}\n' "$head" "$(sed -n "${line}p" "$STATE/ci_rollups")" ;;
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
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x RD_CI_POLL=1 RD_CI_GRACE=1

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
# rollup entries as GitHub returns them
run()  { printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s","detailsUrl":"%s"}' "$1" "$2" "$3" "$4"; }
OK=$(run check COMPLETED SUCCESS https://ci/run/1)
SKIP=$(run CodeRabbit COMPLETED SKIPPED https://bot)
PEND=$(run check IN_PROGRESS "" https://ci/run/1)
reset() {
  : >"$STATE/log"; : >"$STATE/merge_err"; echo false >"$STATE/isDraft"; rm -f "$STATE/bun_fail" "$STATE/bun_hang" "$STATE/ci_hang"
  echo 0 >"$STATE/ci_stale"; echo 0 >"$STATE/ci_seen"; echo 0 >"$STATE/ci_err"; echo "[$OK,$SKIP]" >"$STATE/ci_rollups"
}
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

echo "CI gate"
reset; branch -; train --no-check "$br"
is "CI pass: merged" "$rc" "0"
has "CI pass: reported" "$out" "CI passed for $br"
has "CI pass: gh pr merge ran" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo "[$OK]" >"$STATE/ci_rollups"; t0=$(date +%s); RD_CI_GRACE=6 train --no-check "$br"; dt=$(($(date +%s) - t0))
is "green at once still waits out the grace: merged" "$rc" "0"
[ "$dt" -ge 5 ] && ok "green at once: not declared before the grace (${dt}s of a 6s grace)" || bad "green at once: merged after ${dt}s, before the 6s grace"

reset; branch -; echo "[$(run lint COMPLETED SUCCESS ''),$(run check COMPLETED FAILURE https://ci/run/9)]" >"$STATE/ci_rollups"; train --no-check "$br"
is "CI fail: red train" "$rc" "1"
has "CI fail: names the check and run url" "$out" "CI failed: check https://ci/run/9"
lacks "CI fail: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo "[$(run check COMPLETED FAILURE '')]" >"$STATE/ci_rollups"; train --no-check "$br"
has "CI fail without a link: falls back to the PR url" "$out" "CI failed: check https://gh/pull/7"
lacks "CI fail without a link: never prints null" "$out" "null"

reset; branch -; echo "[$(run check COMPLETED CANCELLED https://ci/run/3)]" >"$STATE/ci_rollups"; train --no-check "$br"
is "CI cancelled: red train" "$rc" "1"
has "CI cancelled: named" "$out" "CI failed: check"
lacks "CI cancelled: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo '[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE","targetUrl":"https://ci/s"}]' >"$STATE/ci_rollups"; train --no-check "$br"
has "commit status failure: named" "$out" "CI failed: ci/legacy https://ci/s"

reset; branch -; echo "[$PEND]" >"$STATE/ci_rollups"; RD_CI_TIMEOUT=3 train --no-check "$br"
is "CI pending past RD_CI_TIMEOUT: red train" "$rc" "1"
has "CI pending: timeout is the reason" "$out" "CI not finished"
lacks "CI pending: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; printf '%s\n' "[$PEND,$SKIP]" "[$PEND,$SKIP]" "[$OK,$SKIP]" >"$STATE/ci_rollups"; train --no-check "$br"
is "pending → pass across polls: merged" "$rc" "0"
has "pending → pass: CI passed" "$out" "CI passed for $br"

reset; branch -; echo "[$SKIP]" >"$STATE/ci_rollups"; t0=$(date +%s); RD_CI_GRACE=6 train --no-check "$br"; dt=$(($(date +%s) - t0))
is "skipping only: merged as no-CI after the grace" "$rc" "0"
has "skipping only: says no CI" "$out" "no CI checks"
[ "$dt" -ge 5 ] && ok "skipping only: not declared before the grace (${dt}s of a 6s grace)" || bad "skipping only: merged after ${dt}s, before the 6s grace"

reset; branch -; printf '%s\n' "[$SKIP]" "[$PEND,$SKIP]" >"$STATE/ci_rollups"; RD_CI_GRACE=30 RD_CI_TIMEOUT=3 train --no-check "$br"
is "skipping-only list, then a workflow registers pending: not merged early" "$rc" "1"
lacks "late workflow: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo '[]' >"$STATE/ci_rollups"; train --no-check "$br"
is "empty rollup: merged after the grace" "$rc" "0"
has "empty rollup: says no CI" "$out" "no CI checks"

reset; branch -; printf '%s\n' "[$OK]" "[$OK,$PEND]" >"$STATE/ci_rollups"; RD_CI_GRACE=30 RD_CI_TIMEOUT=3 train --no-check "$br"
is "partial list (one green, another appears pending): not merged" "$rc" "1"
lacks "partial list: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo -1 >"$STATE/ci_stale"; RD_CI_TIMEOUT=2 train --no-check "$br"
is "stale head: passing checks of an older sha are not trusted" "$rc" "1"
has "stale head: reason names the sha" "$out" "never became the pushed sha"
lacks "stale head: not merged" "$(cat "$STATE/log")" "pr merge"

reset; branch -; echo 2 >"$STATE/ci_stale"; train --no-check "$br"
is "head catching up: merged once it matches" "$rc" "0"
has "head catching up: CI passed" "$out" "CI passed for $br"

reset; branch -; echo 2 >"$STATE/ci_err"; train --no-check "$br"
is "gh error: retried, then merged" "$rc" "0"
has "gh error: retry is announced" "$out" "retrying"

reset; branch -; touch "$STATE/ci_hang"; RD_CI_GH_TIMEOUT=1 RD_CI_TIMEOUT=2 train --no-check "$br"
is "hung gh: bounded, red train" "$rc" "1"
has "hung gh: timeout reason" "$out" "CI not finished"

reset; branch -; echo "[$(run check COMPLETED FAILURE u)]" >"$STATE/ci_rollups"; train --no-check --no-ci "$br"
is "--no-ci: merged despite red CI" "$rc" "0"
lacks "--no-ci: checks never read" "$(cat "$STATE/log")" "headRefOid"

echo; [ "$fails" -eq 0 ] && echo "merge-train: all passed" || { echo "merge-train: $fails failed"; exit 1; }
