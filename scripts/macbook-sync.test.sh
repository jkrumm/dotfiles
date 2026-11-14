#!/usr/bin/env bash
# macbook-sync.test.sh — hermetic test for scripts/macbook-sync.sh, what `ssh iumac dotfiles-sync` runs.
#
# A temp "origin" repo, a clone standing in for the MacBook's checkout, and a stub Makefile whose targets record that
# they ran. No network, nothing outside the temp dir is touched.
#
# Usage: scripts/macbook-sync.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$HERE/macbook-sync.sh"
REAL_TABLE="$HERE/../config/macbook-sync.tsv"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/macbook-sync-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export HOME="$TMP/home"
mkdir -p "$HOME"
RAN="$TMP/ran"
export MACBOOK_SYNC_LOG="$TMP/sync.log" SYNC_TEST_RAN="$RAN"

ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
MAC="$TMP/mac"
export MACBOOK_SYNC_REMOTE="$ORIGIN"

git init -q --bare -b master "$ORIGIN"
git init -q -b master "$SEED"
mkdir -p "$SEED/scripts" "$SEED/config/herdr-app" "$SEED/docs"
cp "$REAL_SCRIPT" "$SEED/scripts/macbook-sync.sh"
cp "$REAL_TABLE" "$SEED/config/macbook-sync.tsv"
cat >"$SEED/Makefile" <<'MK'
herdr-app-setup:
	@echo "herdr-app-setup glance=$$HERDR_NO_MINI_GLANCE" >>"$$SYNC_TEST_RAN"
other-target:
	@echo "other-target" >>"$$SYNC_TEST_RAN"
broken-target:
	@echo "broken-target" >>"$$SYNC_TEST_RAN"; echo "boom" >&2; exit 2
MK
echo a >"$SEED/config/herdr-app/a"
echo a >"$SEED/docs/a"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m base
git -C "$SEED" remote add origin "$ORIGIN" && git -C "$SEED" push -q origin master
git clone -q "$ORIGIN" "$MAC"

origin_commit() { # <file> [<line>] — a commit on origin touching <file>
  mkdir -p "$(dirname "$SEED/$1")"
  echo "${2:-x}" >>"$SEED/$1"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m "touch $1" && git -C "$SEED" push -q origin master
}

OUT="" RC=0
sync_run() { OUT="$(bash "$MAC/scripts/macbook-sync.sh" "$@" 2>&1)"; RC=$?; }
ran() { cat "$RAN" 2>/dev/null; }
head_of() { git -C "$MAC" rev-parse HEAD; }

echo "== level"
rm -f "$RAN"
sync_run
assert_eq "up to date: rc" "0" "$RC"
assert_contains "up to date: says so" "up to date" "$OUT"
assert_eq "up to date: no target" "" "$(ran)"

echo "== arguments"
sync_run --run
assert_eq "--run without a range refused" "1" "$RC"
sync_run master
assert_eq "an argument refused" "1" "$RC"
assert_contains "an argument: reason" "takes no arguments" "$OUT"

echo "== a pulled range that touches a target"
origin_commit config/herdr-app/b
rm -f "$RAN"
sync_run
assert_eq "fast-forward: rc" "0" "$RC"
assert_eq "fast-forward: HEAD is origin's" "$(git -C "$SEED" rev-parse HEAD)" "$(head_of)"
assert_eq "target ran once, glance copy off" "herdr-app-setup glance=1" "$(ran)"
assert_contains "output names the range and the target" "✓ herdr-app-setup" "$OUT"
assert_contains "output says the glance copy is not refreshed" "jk-glance is not refreshed" "$OUT"

echo "== two prefixes of one target run it once"
origin_commit config/herdr-app/c
origin_commit scripts/herdr-app-keys.sh
rm -f "$RAN"
sync_run
assert_eq "one run for two matching prefixes" "herdr-app-setup glance=1" "$(ran)"

echo "== a range that touches no target"
origin_commit docs/b
rm -f "$RAN"
sync_run
assert_eq "docs only: rc" "0" "$RC"
assert_eq "docs only: no target" "" "$(ran)"
assert_contains "docs only: says so" "no target for this range" "$OUT"

echo "== refusals leave the checkout alone"
origin_commit config/herdr-app/d
before="$(head_of)"
echo dirty >>"$MAC/docs/a"
rm -f "$RAN"
sync_run
assert_eq "dirty tree: rc" "1" "$RC"
assert_contains "dirty tree: reason" "working tree is not clean" "$OUT"
assert_eq "dirty tree: HEAD unmoved" "$before" "$(head_of)"
git -C "$MAC" checkout -q -- docs/a

git -C "$MAC" checkout -q -b side
sync_run
assert_eq "other branch: rc" "1" "$RC"
assert_contains "other branch: reason" "on side, not master" "$OUT"
git -C "$MAC" checkout -q master

git -C "$MAC" checkout -q --detach
sync_run
assert_contains "detached HEAD: reason" "a detached HEAD, not master" "$OUT"
git -C "$MAC" checkout -q master

echo local >"$MAC/docs/local" && git -C "$MAC" add -A && git -C "$MAC" commit -q -m local
sync_run
assert_eq "diverged: rc" "1" "$RC"
assert_contains "diverged: reason" "diverged" "$OUT"
assert_eq "diverged: nothing ran" "" "$(ran)"
git -C "$MAC" reset -q --hard "HEAD~1"

echo "== local ahead of origin is level"
git -C "$MAC" fetch -q origin && git -C "$MAC" reset -q --hard origin/master
echo ahead >"$MAC/docs/ahead" && git -C "$MAC" add -A && git -C "$MAC" commit -q -m ahead
sync_run
assert_eq "ahead: rc" "0" "$RC"
assert_contains "ahead: up to date" "up to date" "$OUT"
git -C "$MAC" reset -q --hard origin/master

echo "== a failing target does not stop the later ones, and the exit is 1"
printf 'docs/\tbroken-target\nconfig/herdr-app/\tother-target\n' >"$SEED/config/macbook-sync.tsv"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m "table" && git -C "$SEED" push -q origin master
origin_commit docs/c
origin_commit config/herdr-app/e
rm -f "$RAN"
sync_run
assert_eq "broken target: rc" "1" "$RC"
assert_eq "broken target: both ran, in table order" "broken-target
other-target" "$(ran)"
assert_contains "broken target: shows its error" "boom" "$OUT"

echo "== the new table is the one read (the pulled copy re-execs)"
printf '# comment\n\nnot/a/row\tbad target name\nconfig/herdr-app/\tother-target\n' >"$SEED/config/macbook-sync.tsv"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m "table2" && git -C "$SEED" push -q origin master
origin_commit config/herdr-app/f
rm -f "$RAN"
sync_run
assert_eq "bad row: rc 1" "1" "$RC"
assert_contains "bad row: reported" "bad row in config/macbook-sync.tsv" "$OUT"
assert_eq "bad row: the good row still ran" "other-target" "$(ran)"

echo "== log"
assert_contains "log records the pulls" "pull " "$(cat "$MACBOOK_SYNC_LOG")"

echo "== the shipped table"
bad_rows="$(grep -v '^#' "$REAL_TABLE" | grep -v '^$' | grep -Ecv $'^[A-Za-z0-9._/-]+\t[a-z0-9][a-z0-9-]*$')"
assert_eq "every shipped row is <prefix><TAB><target>" "0" "$bad_rows"
for t in $(grep -v '^#' "$REAL_TABLE" | cut -f2 | sort -u); do
  if grep -q "^$t:" "$HERE/../Makefile"; then ok "target $t exists in the Makefile"; else bad "target $t exists in the Makefile"; fi
done

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
