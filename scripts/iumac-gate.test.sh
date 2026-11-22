#!/usr/bin/env bash
# iumac-gate.test.sh — regression harness for scripts/iumac-gate.sh, the forced
# command behind the mini->iumac key, plus the ssh-agent.zsh rule that an
# incoming ssh session never gets the local 1Password socket.
#
# Hermetic: IUMAC_GATE_HOME points at a temp tree of stub scripts that record
# their argv, cwd, stdin and SSH_AUTH_SOCK; IUMAC_GATE_RSYNC and PATH stubs
# stand in for rsync, osascript and open. No network, no real ssh, nothing
# outside the temp dir is touched.
#
# Usage: scripts/iumac-gate.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/iumac-gate.sh"
AGENT_ZSH="$HERE/../config/zsh/ssh-agent.zsh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

[[ -x "$GATE" ]] || { echo "✗ $GATE not found/executable"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/iumac-gate-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

H="$TMP/home"
REC="$TMP/rec"
BIN="$TMP/bin"
MARK="$TMP/M"
mkdir -p "$H" "$REC" "$BIN"

# A stub records "<name>|arg|arg..." in calls, its cwd, stdin and SSH_AUTH_SOCK.
mkstub() { # <path> <name>
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<STUB
#!/bin/bash
{ printf '%s' '$2'; for a in "\$@"; do printf '|%s' "\$a"; done; printf '\n'; } >>"$REC/calls"
pwd -P >"$REC/$2.cwd"
printf '%s' "\${SSH_AUTH_SOCK-unset}" >"$REC/$2.sock"
cat >"$REC/$2.stdin"
exit \${STUB_RC:-0}
STUB
  chmod +x "$1"
}

SC="$H/SourceRoot/dotfiles/scripts"
mkstub "$SC/human-queue.sh" human-queue
mkstub "$SC/ask-human.sh" ask-human
mkstub "$SC/claude-relogin.sh" relogin
mkstub "$SC/claude-account-snapshot.sh" snapshot
mkstub "$SC/lib/core-up.sh" core-up
mkstub "$SC/macbook-sync.sh" macbook-sync
mkstub "$SC/herdr-glance-sync.sh" glance-sync
mkstub "$SC/claude-account-sync.sh" account-sync
mkstub "$SC/agent-note.sh" agent-note
mkstub "$H/.local/bin/claude-account" claude-account
mkstub "$H/.local/bin/hc" hc
mkstub "$H/.bun/bin/bun" bun
mkstub "$BIN/osascript" osascript
mkstub "$BIN/open" open
mkstub "$BIN/rsync-stub" rsync
mkdir -p "$H/.local/share/iu-portal/tool"

reset() { rm -f "$REC"/* "$MARK"; }

RC=0
ERR=""
# run_gate <command> [stdin text] — sets RC, ERR; stubs' records are in $REC
run_gate() {
  reset
  ERR="$(printf '%s' "${2:-}" | SSH_AUTH_SOCK=/tmp/fake-agent.sock SSH_ORIGINAL_COMMAND="$1" IUMAC_GATE_HOME="$H" \
    IUMAC_GATE_RSYNC="$BIN/rsync-stub" PATH="$BIN:$PATH" /bin/bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}
calls() { cat "$REC/calls" 2>/dev/null; }

expect_allowed() { # <label> <command> <expected calls> [stdin]
  run_gate "$2" "${4:-}"
  assert_eq "$1: rc" "0" "$RC"
  assert_eq "$1: calls" "$3" "$(calls)"
}

expect_refused() { # <label> <command> [stdin]
  run_gate "$2" "${3:-}"
  assert_eq "refused rc 126: $1" "126" "$RC"
  if [[ ! -e "$REC/calls" && ! -e "$MARK" ]]; then ok "nothing executed: $1"; else bad "nothing executed: $1" "calls=[$(calls)]"; fi
  case "$ERR" in refused*) ok "stderr says refused: $1" ;; *) bad "stderr says refused: $1" "[$ERR]" ;; esac
}

echo "== allowed verbs"
run_gate "true"; assert_eq "true: rc" "0" "$RC"
assert_eq "true: runs nothing" "" "$(calls)"

expect_allowed "gui-run" "gui-run" "human-queue|gui-run" "payload-1"
assert_eq "gui-run: stdin passthrough" "payload-1" "$(cat "$REC/human-queue.stdin")"
assert_eq "gui-run: SSH_AUTH_SOCK empty inside" "unset" "$(cat "$REC/human-queue.sock")"

LONGT="$(printf 'T%.0s' $(seq 1 150))"
LONGX="$(printf 'x%.0s' $(seq 1 500))"
expect_allowed "notify" "notify" "osascript|-|Hello|body one body two" $'Hello\nbody one\nbody two'
assert_contains "notify: fixed script on stdin" "display notification (item 2 of argv) with title (item 1 of argv)" "$(cat "$REC/osascript.stdin")"
run_gate "notify" "$LONGT"$'\n'"$LONGX"
T="$(calls | cut -d'|' -f3)"; X="$(calls | cut -d'|' -f4)"
assert_eq "notify: title truncated to 100" "100" "${#T}"
assert_eq "notify: text truncated to 400" "400" "${#X}"
run_gate "notify" $'Ti\atle\x1b\nte\x01xt'
assert_eq "notify: control chars stripped" "osascript|-|Title|text" "$(calls)"

expect_allowed "open-url with app" "open-url" "open|-a|Google Chrome|https://example.com/a?b=1&c=2" $'Google Chrome\nhttps://example.com/a?b=1&c=2'
expect_allowed "open-url without app" "open-url" "open|https://example.com/x" $'\nhttps://example.com/x'

expect_allowed "relogin" "relogin acct_1-b" "relogin|acct_1-b|--machine|macbook"
expect_allowed "relogin --visible" "relogin acct_1-b --visible" "relogin|acct_1-b|--machine|macbook|--visible"
expect_allowed "account-usage" "account-usage" "claude-account|usage|--json"
expect_allowed "account-snapshot" "account-snapshot" "snapshot"
expect_allowed "account-snapshot-core" "account-snapshot-core" "core-up
hc|exec|--timeout|30|bash|$SC/claude-account-snapshot.sh"
expect_allowed "herdr-glance-sync" "herdr-glance-sync" "glance-sync"
expect_allowed "claude-account-sync" "claude-account-sync" "account-sync"
expect_allowed "account-version" "account-version" "claude-account|--version"
expect_allowed "hc-version" "hc-version" "hc|--version"
expect_allowed "term-ls" "term-ls" "agent-note|ls-local"
expect_allowed "term-note" "term-note" "agent-note|deliver" $'t7\nmini:t31z\nhello'
assert_eq "term-note: stdin passthrough" $'t7\nmini:t31z\nhello' "$(cat "$REC/agent-note.stdin")"
assert_eq "term-note: SSH_AUTH_SOCK empty inside" "unset" "$(cat "$REC/agent-note.sock")"
expect_allowed "dotfiles-sync" "dotfiles-sync" "macbook-sync"
assert_eq "dotfiles-sync: SSH_AUTH_SOCK empty inside" "unset" "$(cat "$REC/macbook-sync.sock")"

expect_allowed "iu-portal scrape" 'cd ~/.local/share/iu-portal/tool && bun scrape.ts daily monthly' "bun|scrape.ts|daily|monthly" "in-scrape"
assert_eq "iu scrape: cwd" "$H/.local/share/iu-portal/tool" "$(cat "$REC/bun.cwd")"
assert_eq "iu scrape: stdin passthrough" "in-scrape" "$(cat "$REC/bun.stdin")"
expect_allowed "iu-portal scrape --no-latest" 'cd ~/.local/share/iu-portal/tool && bun scrape.ts daily monthly --no-latest' "bun|scrape.ts|daily|monthly|--no-latest"

echo "== rsync pulls"
# Argv as captured from openrsync (macOS /usr/bin/rsync, protocol 29) and as rsync 3.x sends it.
expect_allowed "rsync openrsync form" "rsync --server --sender --delete-before -g -l -o -p -D -r -t --dirs . .claude/projects/" \
  "rsync|--server|--sender|--delete-before|-g|-l|-o|-p|-D|-r|-t|--dirs|.|.claude/projects/"
assert_eq "rsync: runs from HOME" "$H" "$(cat "$REC/rsync.cwd")"
expect_allowed "rsync openrsync with -z" "rsync --server --sender --numeric-ids -g -l -o -p -D -r -t -z --dirs --ignore-errors . .claude/logs/" \
  "rsync|--server|--sender|--numeric-ids|-g|-l|-o|-p|-D|-r|-t|-z|--dirs|--ignore-errors|.|.claude/logs/"
expect_allowed "rsync 3.x bundle" "rsync --server --sender -logDtpre.iLsfxCIvu --delete --timeout=60 . .codex/sessions/2026/11/" \
  "rsync|--server|--sender|-logDtpre.iLsfxCIvu|--delete|--timeout=60|.|.codex/sessions/2026/11/"
expect_allowed "rsync 3.x bundle with -z" "rsync --server --sender -vlogDtprze.iLsfxCIvu . .local/share/usage-tracker/" \
  "rsync|--server|--sender|-vlogDtprze.iLsfxCIvu|.|.local/share/usage-tracker/"
expect_allowed "rsync codex sessions root" "rsync --server --sender -vlogDtpr . .codex/sessions/" "rsync|--server|--sender|-vlogDtpr|.|.codex/sessions/"

echo "== report"
mkdir -p "$H/SourceRoot/dotfiles/config"
printf '%s\n' '# comment' '' \
  "say-hi	echo hello" \
  "both-streams	echo out; echo err >&2" \
  "fails	echo bad; exit 3" \
  "big	head -c 100000 /dev/zero | tr '\\0' x" \
  "no-newline	printf x" \
  "silent	true" \
  "slow	sleep 30" \
  "home-tilde	echo ~/x" \
  >"$H/SourceRoot/dotfiles/config/macbook-reports.tsv"
OUT=""
# run_gate_out <command> [env...] — stdout+stderr of the gate in OUT, exit code in RC
run_gate_out() {
  local c="$1"
  shift
  reset
  OUT="$(env "$@" SSH_ORIGINAL_COMMAND="$c" IUMAC_GATE_HOME="$H" PATH="$BIN:$PATH" /bin/bash "$GATE" 2>&1 </dev/null)"
  RC=$?
}
run_gate_out "report say-hi";       assert_eq "report: exit 0" "0" "$RC"; assert_eq "report: output then [exit 0]" "hello
[exit 0]" "$OUT"
run_gate_out "report both-streams"; assert_eq "report: stderr merged into stdout" "out
err
[exit 0]" "$OUT"
run_gate_out "report fails";        assert_eq "report: exit 0 whatever the command exited with" "0" "$RC"; assert_eq "report: the command's own exit is the last line" "bad
[exit 3]" "$OUT"
run_gate_out "report no-newline";  assert_eq "report: [exit N] starts its own line" "x
[exit 0]" "$OUT"
run_gate_out "report silent";      assert_eq "report: no output, just the exit line" "[exit 0]" "$OUT"
run_gate_out "report home-tilde";   assert_eq "report: ~ is the gate's home" "$H/x
[exit 0]" "$OUT"
run_gate_out "report big"
assert_eq "report: output cut to 64 KB, the exit line still follows" "65545" "${#OUT}"
SECS0=$SECONDS
run_gate_out "report slow" IUMAC_GATE_REPORT_TIMEOUT=1
assert_eq "report: a slow command still exits 0" "0" "$RC"
assert_eq "report: the time limit reports 124" "[exit 124]" "$OUT"
assert_eq "report: stopped at the limit, not after 30 s" "yes" "$([ $((SECONDS - SECS0)) -lt 10 ] && echo yes || echo no)"
expect_refused "report unknown name" "report nope"
expect_refused "report no name" "report"
expect_refused "report two names" "report say-hi fails"
expect_refused "report upper-case" "report Say-hi"
expect_refused "report path name" "report ../x"
expect_refused "report name with dot" "report say.hi"
expect_refused "report leading dash" "report -x"
expect_refused "report chained" "report say-hi; id"
run_gate "report nope"; assert_contains "report unknown: stderr names the verb" "refused: report" "$ERR"
mv "$H/SourceRoot/dotfiles/config/macbook-reports.tsv" "$H/SourceRoot/dotfiles/config/macbook-reports.tsv.off"
expect_refused "report with no table" "report say-hi"
mv "$H/SourceRoot/dotfiles/config/macbook-reports.tsv.off" "$H/SourceRoot/dotfiles/config/macbook-reports.tsv"
# The shipped table: well-formed rows, the three the factory knows.
REAL="$HERE/../config/macbook-reports.tsv"
names="$(awk -F'\t' '!/^#/ && NF { print $1 }' "$REAL" | tr '\n' ' ')"
assert_contains "shipped table: smb-mounts" "smb-mounts " "$names"
assert_contains "shipped table: ntfy-mac-update-check" "ntfy-mac-update-check " "$names"
assert_contains "shipped table: iumac-gate-log" "iumac-gate-log " "$names"
bad_rows="$(awk -F'\t' '!/^#/ && NF && ($1 !~ /^[a-z0-9][a-z0-9-]*$/ || $2 == "") { print $1 }' "$REAL")"
assert_eq "shipped table: every row is a valid name and a command" "" "$bad_rows"

echo "== repo-pull"
command -v git >/dev/null 2>&1 || { echo "  skip: git missing"; }
GITENV=(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)
g() { env "${GITENV[@]}" git "$@"; }
SRCROOT="$H/SourceRoot"
ORIGIN="$TMP/origin.git"
g init -q --bare -b master "$ORIGIN"
g clone -q "$ORIGIN" "$TMP/pusher" 2>/dev/null
( cd "$TMP/pusher" && echo one >f && g add f && g commit -q -m one && g push -q origin HEAD:master )
g clone -q "$ORIGIN" "$SRCROOT/alpha" 2>/dev/null
( cd "$TMP/pusher" && echo two >>f && g add f && g commit -q -m two && g push -q origin HEAD:master )
run_gate_out "repo-pull alpha" "${GITENV[@]}"
assert_eq "repo-pull: fast-forward exits 0" "0" "$RC"
assert_eq "repo-pull: the checkout is level" "$(g -C "$TMP/pusher" rev-parse HEAD)" "$(g -C "$SRCROOT/alpha" rev-parse HEAD)"
run_gate_out "repo-pull alpha" "${GITENV[@]}"
assert_eq "repo-pull: already level exits 0" "0" "$RC"
assert_contains "repo-pull: says so" "Already up to date" "$OUT"
# dirty tree that the pull would touch -> git refuses, non-zero
( cd "$TMP/pusher" && echo three >>f && g add f && g commit -q -m three && g push -q origin HEAD:master )
echo local >>"$SRCROOT/alpha/f"
run_gate_out "repo-pull alpha" "${GITENV[@]}"
assert_eq "repo-pull: a dirty tree is git's non-zero" "1" "$([ "$RC" -ne 0 ] && [ "$RC" -ne 126 ] && echo 1 || echo 0)"
assert_contains "repo-pull: git's error is in the output" "error" "$OUT"
g -C "$SRCROOT/alpha" checkout -q -- f
# diverged branch
echo diverge >"$SRCROOT/alpha/g" && g -C "$SRCROOT/alpha" add g && g -C "$SRCROOT/alpha" commit -q -m diverge
run_gate_out "repo-pull alpha" "${GITENV[@]}"
assert_eq "repo-pull: a diverged branch is non-zero" "1" "$([ "$RC" -ne 0 ] && [ "$RC" -ne 126 ] && echo 1 || echo 0)"
# no ssh identity, no prompt: the env the pull runs with
mkdir -p "$TMP/fakegit"
printf '%s\n' '#!/bin/bash' 'printf "%s|%s|%s|%s\n" "$GIT_SSH_COMMAND" "$GIT_TERMINAL_PROMPT" "${SSH_AUTH_SOCK-unset}" "$*" >"'"$REC"'/git.env"' >"$TMP/fakegit/git"
chmod +x "$TMP/fakegit/git"
mkdir -p "$SRCROOT/beta/.git"
reset
SSH_ORIGINAL_COMMAND="repo-pull beta" IUMAC_GATE_HOME="$H" SSH_AUTH_SOCK=/tmp/fake-agent.sock IUMAC_GATE_GIT="$TMP/fakegit/git" /bin/bash "$GATE" >/dev/null 2>&1
assert_contains "repo-pull: no ssh command" "/usr/bin/false|0|unset|-C $SRCROOT/beta pull --ff-only" "$(cat "$REC/git.env" 2>/dev/null)"
# the file-form .git of a worktree or submodule counts too
mkdir -p "$SRCROOT/gamma" && echo "gitdir: elsewhere" >"$SRCROOT/gamma/.git"
reset
SSH_ORIGINAL_COMMAND="repo-pull gamma" IUMAC_GATE_HOME="$H" IUMAC_GATE_GIT="$TMP/fakegit/git" /bin/bash "$GATE" >/dev/null 2>&1; assert_eq "repo-pull: a .git file is a checkout" "0" "$?"
# a time limit
printf '%s\n' '#!/bin/bash' 'sleep 30' >"$TMP/fakegit/git"
SECS0=$SECONDS
SSH_ORIGINAL_COMMAND="repo-pull beta" IUMAC_GATE_HOME="$H" IUMAC_GATE_PULL_TIMEOUT=1 IUMAC_GATE_GIT="$TMP/fakegit/git" /bin/bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "repo-pull: the time limit is non-zero" "124" "$rc"
assert_eq "repo-pull: stopped at the limit" "yes" "$([ $((SECONDS - SECS0)) -lt 10 ] && echo yes || echo no)"
mkdir -p "$SRCROOT/nogit"
expect_refused "repo-pull no such checkout" "repo-pull missing"
expect_refused "repo-pull a directory without .git" "repo-pull nogit"
expect_refused "repo-pull dotfiles" "repo-pull dotfiles"
expect_refused "repo-pull dotted traversal" "repo-pull .."
expect_refused "repo-pull name with .." "repo-pull a..b"
expect_refused "repo-pull path" "repo-pull ../alpha"
expect_refused "repo-pull slash" "repo-pull alpha/x"
expect_refused "repo-pull upper-case" "repo-pull Alpha"
expect_refused "repo-pull leading dot" "repo-pull .git"
expect_refused "repo-pull leading dash" "repo-pull -x"
expect_refused "repo-pull no name" "repo-pull"
expect_refused "repo-pull two names" "repo-pull alpha beta"
expect_refused "repo-pull chained" "repo-pull alpha; id"

echo "== refused"
expect_refused "empty command" ""
expect_refused "id" "id"
expect_refused "true; touch" "true; touch $MARK"
expect_refused "true && touch" "true && touch $MARK"
expect_refused "true | cat" "true | cat"
expect_refused "command substitution" 'true $(touch '"$MARK"')'
expect_refused "backticks" 'true `touch '"$MARK"'`'
expect_refused "redirect" "true > $MARK"
expect_refused "quotes" "true 'x'"
expect_refused "backslash" 'true \x'
expect_refused "newline" $'true\ntouch '"$MARK"
expect_refused "scrape lookalike" 'cd ~/.local/share/iu-portal/tool && bun scrape.ts daily monthly --other'
expect_refused "true extra arg" "true x"
expect_refused "gui-run extra" "gui-run extra"
expect_refused "notify extra" "notify x"
expect_refused "open-url arg" "open-url https://example.com"
expect_refused "open-url file://" "open-url" $'Safari\nfile:///etc/passwd'
expect_refused "open-url javascript:" "open-url" $'\njavascript:alert(1)'
expect_refused "open-url http" "open-url" $'\nhttp://example.com'
expect_refused "open-url url with space" "open-url" $'\nhttps://example.com/a b'
expect_refused "open-url bad app" "open-url" $'Saf;ari\nhttps://example.com'
expect_refused "open-url app starting with dash" "open-url" $'-a\nhttps://example.com'
expect_refused "relogin no id" "relogin"
expect_refused "relogin machine override" "relogin x --machine mini"
expect_refused "relogin upper-case id" "relogin ABC"
expect_refused "relogin path id" "relogin ../x"
expect_refused "account-usage extra" "account-usage --raw"
expect_refused "hc-version extra" "hc-version x"
expect_refused "dotfiles-sync argument" "dotfiles-sync --run"
expect_refused "dotfiles-sync branch argument" "dotfiles-sync main"
expect_refused "dotfiles-sync chained" "dotfiles-sync; id"
expect_refused "herdr-glance-sync argument" "herdr-glance-sync now"
expect_refused "herdr-glance-sync chained" "herdr-glance-sync; id"
expect_refused "claude-account-sync argument" "claude-account-sync now"
expect_refused "claude-account-sync chained" "claude-account-sync; id"
expect_refused "account-version argument" "account-version --json"
expect_refused "term-ls argument" "term-ls --all"
expect_refused "term-ls chained" "term-ls; id"
expect_refused "term-note target as argument" "term-note t7"
expect_refused "term-note chained" "term-note; id"
expect_refused "term-note substitution" 'term-note $(id)'
expect_refused "term-read is not a verb" "term-read t7"
expect_refused "hc send over the gate" "hc send t7 id"
expect_refused "bash -c" "bash -c id"
expect_refused "sh" "sh"
expect_refused "op read" "op read x"
expect_refused "git pull" "git pull"
expect_refused "cat authorized_keys" "cat .ssh/authorized_keys"
expect_refused "rsync --log-file" "rsync --server --sender -logDtpre.iLsfxCIvu --log-file=/tmp/x . .claude/projects/"
expect_refused "rsync --files-from" "rsync --server --sender -logDtpr --files-from=/etc/passwd . .claude/projects/"
expect_refused "rsync --copy-links" "rsync --server --sender --copy-links -r . .claude/projects/"
expect_refused "rsync --rsync-path" "rsync --server --sender --rsync-path=id -r . .claude/projects/"
expect_refused "rsync --temp-dir" "rsync --server --sender --temp-dir=/tmp -r . .claude/projects/"
expect_refused "rsync --partial-dir" "rsync --server --sender --partial-dir=.x -r . .claude/projects/"
expect_refused "rsync --write-batch" "rsync --server --sender --write-batch=/tmp/b -r . .claude/projects/"
expect_refused "rsync bad timeout" "rsync --server --sender --timeout=1x -r . .claude/projects/"
expect_refused "rsync source .ssh/" "rsync --server --sender -logDtpr . .ssh/"
expect_refused "rsync source /etc/" "rsync --server --sender -logDtpr . /etc/"
expect_refused "rsync source traversal" "rsync --server --sender -logDtpr . .claude/projects/../../.ssh/"
expect_refused "rsync source without trailing slash" "rsync --server --sender -logDtpr . .claude/projects"
expect_refused "rsync source codex bad date" "rsync --server --sender -logDtpr . .codex/sessions/2026/1/"
expect_refused "rsync two sources" "rsync --server --sender -logDtpr . .claude/projects/ .claude/logs/"
expect_refused "rsync no source" "rsync --server --sender -logDtpr ."
expect_refused "rsync -L bundle" "rsync --server --sender -vLogDtpr . .claude/projects/"
expect_refused "rsync -k bundle" "rsync --server --sender -vlkr . .claude/projects/"
expect_refused "rsync -K bundle" "rsync --server --sender -vlKr . .claude/projects/"
expect_refused "rsync -f bundle" "rsync --server --sender -vlfr . .claude/projects/"
expect_refused "rsync -T bundle" "rsync --server --sender -vlTr . .claude/projects/"
expect_refused "rsync bare -e" "rsync --server --sender -vlr -e . .claude/projects/"
expect_refused "rsync receiver form" "rsync --server -logDtpre.iLsfxCIvu . .claude/projects/"
expect_refused "rsync wrong suffix" "rsync --server --sender -logDtpre.i-Lsf . .claude/projects/"
expect_refused "rsync extra option after path" "rsync --server --sender -logDtpr . .claude/projects/ --log-file=/tmp/x"
expect_refused "rsync glob source" "rsync --server --sender -logDtpr . .claude/*"

echo "== decision log"
echo "== auto-run"
mkdir -p "$H/SourceRoot/dotfiles/config" "$H/.config"
ln -sf "$HERE/lib/human-queue-json.sh" "$SC/lib/human-queue-json.sh"
mkstub "$H/.local/bin/git" git
CAT="$H/SourceRoot/dotfiles/config/macbook-auto-classes.tsv"
cp "$HERE/../config/macbook-auto-classes.tsv" "$CAT"
printf '%s\t%s\t%s\t%s\n' \
  "echo-class" "echo ran-<N>" "none" "5" \
  "bad-slot" "echo <X>" "none" "5" \
  "bad-needs" "echo needs" "maybe" "5" >>"$CAT"
CONSENT="$H/.config/jk/auto-run.consent"
OFFSW="$H/.config/jk/auto-run.off"
IOREG_UNLOCKED="$BIN/ioreg-unlocked"
IOREG_LOCKED="$BIN/ioreg-locked"
IOREG_BROKEN="$BIN/ioreg-broken"
printf '#!/bin/sh\necho "<dict><key>CGSSessionScreenIsLocked</key><false/><key>kCGSSessionOnConsoleKey</key><true/></dict>"\n' >"$IOREG_UNLOCKED"
printf '#!/bin/sh\necho "<dict><key>CGSSessionScreenIsLocked</key>\n\t<true/></dict>"\n' >"$IOREG_LOCKED"
printf '#!/bin/sh\nexit 1\n' >"$IOREG_BROKEN"
chmod +x "$IOREG_UNLOCKED" "$IOREG_LOCKED" "$IOREG_BROKEN"
grant() { mkdir -p "$H/.config/jk"; printf '%s\n' "$@" >"$CONSENT"; chmod 600 "$CONSENT"; rm -f "$OFFSW"; }

AUTO_OUT=""
# run_auto <command> [ioreg stub] — the request JSON on stdin; AUTO_OUT = stdout, RC = exit code
run_auto() {
  local req
  req="$(jq -cn --arg id "20261119T000000-1" --arg text "unseal the vault" --arg cmd "$1" '{id: $id, text: $text, cmd: $cmd}')"
  reset
  AUTO_OUT="$(printf '%s' "$req" | SSH_ORIGINAL_COMMAND=auto-run IUMAC_GATE_HOME="$H" IUMAC_GATE_IOREG="${2:-$IOREG_UNLOCKED}" \
    PATH="$BIN:$PATH" /bin/bash "$GATE" 2>"$TMP/auto.err")"
  RC=$?
}
expect_auto_refused() { # <label> <expected rc> <command> [ioreg stub]
  run_auto "$3" "${4:-}"
  assert_eq "auto-run $1: rc $2" "$2" "$RC"
  assert_eq "auto-run $1: no stdout" "" "$AUTO_OUT"
  if [[ ! -e "$REC/calls" && ! -e "$MARK" ]]; then ok "auto-run $1: nothing executed"; else bad "auto-run $1: nothing executed" "calls=[$(calls)]"; fi
}
ran() { calls | grep -v '^osascript'; }

SEED="cd ~/SourceRoot/dotfiles && hc run --timeout 900 'make secrets-seed'"
rm -rf "$H/.config/jk"
expect_auto_refused "no consent file" 77 "$SEED"
assert_eq "auto-run: a refusal never creates the consent file" "no" "$([[ -e "$CONSENT" ]] && echo yes || echo no)"

grant secrets-seed
run_auto "$SEED"
assert_eq "auto-run granted: rc 0" "0" "$RC"
assert_eq "auto-run granted: the command ran" "hc|run|--timeout|900|make secrets-seed" "$(ran)"
assert_eq "auto-run granted: one result line" "1" "$(printf '%s\n' "$AUTO_OUT" | wc -l | tr -d ' ')"
assert_eq "auto-run granted: status" "done" "$(jq -r .status <<<"$AUTO_OUT")"
assert_eq "auto-run granted: id echoed" "20261119T000000-1" "$(jq -r .id <<<"$AUTO_OUT")"
assert_eq "auto-run granted: exit 0" "0" "$(jq -r .exit <<<"$AUTO_OUT")"
assert_eq "auto-run granted: result carries via" "auto-run" "$(jq -r .via <<<"$AUTO_OUT")"
assert_eq "auto-run granted: result carries the class" "secrets-seed" "$(jq -r .class <<<"$AUTO_OUT")"
assert_eq "auto-run granted: notification names class and request" "osascript|-|iumac auto-run|ran secrets-seed for unseal the vault" "$(grep '^osascript' "$REC/calls" 2>/dev/null)"
run_auto "git -C ~/SourceRoot/dotfiles-private pull --ff-only && $SEED"
assert_eq "auto-run pull && variant: runs" "git|-C|$H/SourceRoot/dotfiles-private|pull|--ff-only
hc|run|--timeout|900|make secrets-seed" "$(ran)"
run_auto "git -C ~/SourceRoot/dotfiles-private pull -q --ff-only; $SEED"
assert_eq "auto-run pull ; variant: runs" "git|-C|$H/SourceRoot/dotfiles-private|pull|-q|--ff-only
hc|run|--timeout|900|make secrets-seed" "$(ran)"
run_auto "${SEED/900/30}"
assert_eq "auto-run: another <N> runs" "hc|run|--timeout|30|make secrets-seed" "$(ran)"
STUB_RC=3 run_auto "$SEED"
assert_eq "auto-run failing command: gate still exits 0" "0" "$RC"
assert_eq "auto-run failing command: status failed" "failed" "$(jq -r .status <<<"$AUTO_OUT")"
assert_eq "auto-run failing command: its own exit" "3" "$(jq -r .exit <<<"$AUTO_OUT")"
assert_eq "auto-run failing command: result carries via and class" "auto-run secrets-seed" "$(jq -r '.via + " " + .class' <<<"$AUTO_OUT")"
# a terminal still running at hc's timeout is pending, not failed
cat >"$H/.local/bin/hc" <<'STUB'
#!/bin/bash
echo "Password:"
echo "[hc] still running as t9zz: hc wait t9zz" >&2
exit 124
STUB
run_auto "$SEED"
assert_eq "auto-run still running: status pending" "pending" "$(jq -r .status <<<"$AUTO_OUT")"
assert_eq "auto-run still running: terminal id" "t9zz" "$(jq -r .terminal <<<"$AUTO_OUT")"
assert_eq "auto-run still running: result carries via and class" "auto-run secrets-seed" "$(jq -r '.via + " " + .class' <<<"$AUTO_OUT")"
assert_eq "auto-run still running: hc's own note is not output" "Password:" "$(jq -r .output_tail <<<"$AUTO_OUT" | tr -d '\n')"
mkstub "$H/.local/bin/hc" hc

echo "== auto-run refusals: nothing runs"
touch "$OFFSW"
expect_auto_refused "kill switch" 77 "$SEED"
rm -f "$OFFSW"
grant echo-class
expect_auto_refused "ungranted class" 77 "$SEED"
grant secrets-seed
expect_auto_refused "one byte more (trailing space)" 77 "$SEED "
expect_auto_refused "one byte less" 77 "${SEED%?}"
expect_auto_refused "one byte different (seeds)" 77 "${SEED/secrets-seed/secrets-seeds}"
expect_auto_refused "other directory" 77 "${SEED/dotfiles/dotfile}"
expect_auto_refused "five digits" 77 "${SEED/900/90000}"
expect_auto_refused "empty slot" 77 "${SEED/900/}"
expect_auto_refused "letters in the slot" 77 "${SEED/900/9a0}"
expect_auto_refused "negative slot" 77 "${SEED/900/-9}"
expect_auto_refused "command appended with ;" 77 "$SEED; touch $MARK"
expect_auto_refused "command appended with &&" 77 "$SEED && touch $MARK"
expect_auto_refused "command substitution" 77 "${SEED/900/\$(touch $MARK)}"
expect_auto_refused "backticks in the slot" 77 "${SEED/900/`touch $MARK`}"
expect_auto_refused "newline appended" 77 "$SEED"$'\n'"touch $MARK"
expect_auto_refused "newline inside" 77 "${SEED/ && /&&$'\n'}"
expect_auto_refused "carriage return" 77 "$SEED"$'\r'
expect_auto_refused "escape byte" 77 "${SEED/make/ma$'\033'ke}"
expect_auto_refused "pipe prefix" 77 "true | $SEED"
expect_auto_refused "metacharacter in the slot" 77 "${SEED/900/9;9}"
expect_auto_refused "a different command" 77 "id"
expect_auto_refused "a class name is not a command" 77 "secrets-seed"
expect_auto_refused "row with an unknown slot is inert" 77 "echo <X>"
expect_auto_refused "row with an unknown needs is inert" 77 "echo needs"
grant bad-slot bad-needs
expect_auto_refused "granted but inert rows" 77 "echo needs"
grant secrets-seed
run_auto ""
assert_eq "auto-run: no command (informational): rc 77" "77" "$RC"
assert_eq "auto-run: no command: nothing executed" "no" "$([[ -e "$REC/calls" ]] && echo yes || echo no)"
reset; printf 'not json' | SSH_ORIGINAL_COMMAND=auto-run IUMAC_GATE_HOME="$H" PATH="$BIN:$PATH" /bin/bash "$GATE" >/dev/null 2>&1; assert_eq "auto-run: malformed stdin: rc 77" "77" "$?"
chmod 660 "$CONSENT"
expect_auto_refused "group-writable consent file" 77 "$SEED"
chmod 666 "$CONSENT"
expect_auto_refused "world-writable consent file" 77 "$SEED"
chmod 600 "$CONSENT"
expect_refused "auto-run with an argument" "auto-run now"
expect_refused "auto-run chained" "auto-run; id"

echo "== auto-run: the screen"
expect_auto_refused "locked screen, biometric class" 75 "$SEED" "$IOREG_LOCKED"
assert_contains "auto-run locked: stderr says so" "locked" "$(cat "$TMP/auto.err")"
expect_auto_refused "unreadable screen state, biometric class" 75 "$SEED" "$IOREG_BROKEN"
expect_auto_refused "needs none, not granted" 77 "echo ran-7" "$IOREG_LOCKED"
grant secrets-seed echo-class
run_auto "echo ran-7" "$IOREG_LOCKED"
assert_eq "auto-run needs none, locked screen: still runs" "0" "$RC"
assert_eq "auto-run needs none: output carried back" "ran-7" "$(jq -r .output_tail <<<"$AUTO_OUT")"
run_auto "$SEED" "$IOREG_LOCKED"
LOGTXT="$(cat "$H/Library/Logs/iumac-gate.log")"
assert_contains "auto-run log: the ran line has class and exit" "auto-run ran:echo-class exit=0" "$LOGTXT"
assert_contains "auto-run log: refusals have a reason word" "auto-run refuse:locked" "$LOGTXT"
case "$LOGTXT" in *"make secrets"*|*unseal*|*20261119T000000*) bad "auto-run log: never the command, text or id" ;; *) ok "auto-run log: never the command, text or id" ;; esac

echo "== auto-run: no gate verb writes consent"
grant secrets-seed
CK0="$(cksum <"$CONSENT") $(stat -f %m "$CONSENT")"
for c in "$SEED" "echo ran-1" "id"; do run_auto "$c"; done
touch "$OFFSW"; run_auto "$SEED"; rm -f "$OFFSW"
for v in true gui-run notify report auto-run dotfiles-sync "report smb-mounts"; do run_gate "$v" "x"; done
assert_eq "consent file unchanged by every gate verb" "$CK0" "$(cksum <"$CONSENT") $(stat -f %m "$CONSENT")"
assert_eq "kill switch not created or lifted by a verb" "no" "$([[ -e "$OFFSW" ]] && echo yes || echo no)"
rm -rf "$H/.config" "$H/SourceRoot/dotfiles/config/macbook-auto-classes.tsv"

LOGF="$H/Library/Logs/iumac-gate.log"
run_gate "true"
run_gate "gui-run topsecret-id-123"
if [[ -f "$LOGF" ]]; then
  case "$(cat "$LOGF")" in *topsecret-id-123*) bad "log: no arguments" ;; *) ok "log: no arguments" ;; esac
  assert_contains "log: refusals recorded" "refuse" "$(cat "$LOGF")"
else
  bad "log file written" "missing $LOGF"
fi
for i in $(seq 1 2100); do echo "line $i"; done >"$LOGF"
run_gate "true"
assert_eq "log: capped to <=501 lines when over 2000" "1" "$([ "$(wc -l <"$LOGF")" -le 501 ] && echo 1 || echo 0)"
chmod 000 "$H/Library/Logs" 2>/dev/null
run_gate "true"
assert_eq "log failure never fails the command" "0" "$RC"
chmod 755 "$H/Library/Logs"

echo "== in-use and the active class"
IOREG_ACTIVE="$BIN/ioreg-active"; IOREG_IDLE="$BIN/ioreg-idle"; IOREG_ACTIVE_LOCKED="$BIN/ioreg-active-locked"; IOREG_NOHID="$BIN/ioreg-nohid"
mkioreg() { # <path> <idle ns or -> <locked true|false>
  { printf '#!/bin/sh\ncase "$*" in\n'
    if [ "$2" = "-" ]; then printf '  *IOHIDSystem*) exit 1 ;;\n'; else printf '  *IOHIDSystem*) echo "    | |   \\"HIDIdleTime\\" = %s" ;;\n' "$2"; fi
    printf '  *) echo "<dict><key>CGSSessionScreenIsLocked</key><%s/></dict>" ;;\nesac\n' "$3"; } >"$1"
  chmod +x "$1"
}
mkioreg "$IOREG_ACTIVE" 5000000000 false
mkioreg "$IOREG_IDLE" 900000000000 false
mkioreg "$IOREG_ACTIVE_LOCKED" 1000000000 true
mkioreg "$IOREG_NOHID" - false
GOUT=""
# gate_out <command> <ioreg stub> [stdin] — GOUT = stdout, RC = exit code
gate_out() {
  reset
  GOUT="$(printf '%s' "${3:-}" | SSH_ORIGINAL_COMMAND="$1" IUMAC_GATE_HOME="$H" IUMAC_GATE_IOREG="$2" PATH="$BIN:$PATH" /bin/bash "$GATE" 2>/dev/null)"
  RC=$?
}
gate_out "in-use" "$IOREG_ACTIVE"; assert_eq "in-use: unlocked, input 5 s ago: active" "0/active" "$RC/$GOUT"
gate_out "in-use" "$IOREG_IDLE"; assert_eq "in-use: unlocked, 15 min without input: idle" "0/idle" "$RC/$GOUT"
gate_out "in-use" "$IOREG_ACTIVE_LOCKED"; assert_eq "in-use: locked screen: locked" "0/locked" "$RC/$GOUT"
gate_out "in-use" "$IOREG_NOHID"; assert_eq "in-use: idle time unreadable: idle, never active" "0/idle" "$RC/$GOUT"
gate_out "in-use" "$IOREG_BROKEN"; assert_eq "in-use: nothing readable: locked, never active" "0/locked" "$RC/$GOUT"
reset; GOUT="$(SSH_ORIGINAL_COMMAND=in-use IUMAC_GATE_HOME="$H" IUMAC_GATE_IOREG="$IOREG_IDLE" IUMAC_GATE_ACTIVE_MAX=1000 PATH="$BIN:$PATH" /bin/bash "$GATE" 2>/dev/null)"
assert_eq "in-use: the threshold is IUMAC_GATE_ACTIVE_MAX" "active" "$GOUT"
expect_refused "in-use with an argument" "in-use now"
expect_refused "in-use chained" "in-use; id"

CAT="$H/SourceRoot/dotfiles/config/macbook-auto-classes.tsv"
mkdir -p "$H/SourceRoot/dotfiles/config" "$H/.config/jk"
cp "$HERE/../config/macbook-auto-classes.tsv" "$CAT"
printf '%s\t%s\t%s\t%s\n' "echo-active" "echo active-<ID>" "active" "5" >>"$CAT"
CONSENT="$H/.config/jk/auto-run.consent"
grant() { mkdir -p "$H/.config/jk"; printf '%s\n' "$@" >"$CONSENT"; chmod 600 "$CONSENT"; rm -f "$H/.config/jk/auto-run.off"; }
run_auto() { # <command> [ioreg stub]
  local req
  req="$(jq -cn --arg id "20261119T000000-2" --arg text "renew the login" --arg cmd "$1" '{id: $id, text: $text, cmd: $cmd}')"
  reset
  AUTO_OUT="$(printf '%s' "$req" | SSH_ORIGINAL_COMMAND=auto-run IUMAC_GATE_HOME="$H" IUMAC_GATE_IOREG="${2:-$IOREG_ACTIVE}" PATH="$BIN:$PATH" /bin/bash "$GATE" 2>"$TMP/auto.err")"
  RC=$?
}
grant echo-active
run_auto "echo active-me" "$IOREG_ACTIVE"
assert_eq "active class, MacBook in use: runs" "0/active-me" "$RC/$(jq -r .output_tail <<<"$AUTO_OUT")"
run_auto "echo active-me" "$IOREG_IDLE"
assert_eq "active class, no input for 15 min: 75, nothing runs, no output" "75/" "$RC/$AUTO_OUT"
assert_contains "...the reason word is idle" "idle" "$(cat "$TMP/auto.err")"
run_auto "echo active-me" "$IOREG_ACTIVE_LOCKED"
assert_eq "active class, screen locked: 75" "75/" "$RC/$AUTO_OUT"
assert_contains "...the reason word is locked" "locked" "$(cat "$TMP/auto.err")"
run_auto "echo active-me" "$IOREG_NOHID"
assert_eq "active class, idle time unreadable: 75" "75" "$RC"
run_auto "echo active-Me" "$IOREG_ACTIVE"; assert_eq "<ID> takes no upper case" "77" "$RC"
run_auto "echo active-" "$IOREG_ACTIVE"; assert_eq "<ID> is not empty" "77" "$RC"
run_auto "echo active-$(printf 'a%.0s' $(seq 1 33))" "$IOREG_ACTIVE"; assert_eq "<ID> is at most 32 characters" "77" "$RC"
run_auto "echo active-a b" "$IOREG_ACTIVE"; assert_eq "<ID> takes no space" "77" "$RC"
run_auto "echo active-a;id" "$IOREG_ACTIVE"; assert_eq "<ID> takes no metacharacter" "77" "$RC"
run_auto "echo active-a_b-9" "$IOREG_ACTIVE"; assert_eq "<ID> takes digits, _ and -" "0" "$RC"

RELOGIN_CMD='bash "$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh"'
grant claude-relogin
run_auto "$RELOGIN_CMD me --machine mini" "$IOREG_ACTIVE"
assert_eq "claude-relogin <id> --machine mini: runs the script with exactly those arguments" "0/relogin|me|--machine|mini" "$RC/$(calls | grep '^relogin')"
assert_eq "...result carries via and class" "auto-run claude-relogin" "$(jq -r '.via + " " + .class' <<<"$AUTO_OUT")"
run_auto "$RELOGIN_CMD iu --machine macbook" "$IOREG_ACTIVE"
assert_eq "claude-relogin <id> --machine macbook: runs" "0/relogin|iu|--machine|macbook" "$RC/$(calls | grep '^relogin')"
run_auto "$RELOGIN_CMD me --machine mini" "$IOREG_IDLE"
assert_eq "claude-relogin with the MacBook idle: nothing runs, 75" "75/no" "$RC/$([[ -e "$REC/calls" ]] && echo yes || echo no)"
for bad in "$RELOGIN_CMD me --machine laptop" "$RELOGIN_CMD me --machine mini --visible" "$RELOGIN_CMD me" "$RELOGIN_CMD Me --machine mini" "$RELOGIN_CMD me --machine mini; id" "$RELOGIN_CMD me --ask --machine mini" "bash $H/SourceRoot/dotfiles/scripts/claude-relogin.sh me --machine mini"; do
  run_auto "$bad" "$IOREG_ACTIVE"
  assert_eq "claude-relogin class refuses: $bad" "77/no" "$RC/$([[ -e "$REC/calls" ]] && echo yes || echo no)"
done
grant echo-active
run_auto "$RELOGIN_CMD me --machine mini" "$IOREG_ACTIVE"
assert_eq "claude-relogin not granted: 77 (the dialog)" "77" "$RC"
rm -rf "$H/.config" "$CAT"

echo "== login-forward: one loopback port of one login"
FSSH="$BIN/fwd-ssh"; FLSOF="$BIN/fwd-lsof"; FPID="$TMP/fwd-ssh.pid"
cat >"$FSSH" <<STUB
#!/bin/bash
{ printf 'ssh'; for a in "\$@"; do printf '|%s' "\$a"; done; printf '\n'; } >>"$REC/calls"
echo \$\$ >"$FPID"
exec sleep 30
STUB
cat >"$FLSOF" <<'STUB'
#!/bin/bash
case " $* " in
  *" -a "*) [ "${STUB_LSOF_UP:-1}" = 1 ] ;;
  *) [ "${STUB_LSOF_BUSY:-0}" = 1 ] ;;
esac
STUB
chmod +x "$FSSH" "$FLSOF"
FURL='https://claude.com/cai/oauth/authorize?code=true&client_id=abc&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback&scope=user%3Ainference&state=x%y'
# run_fwd <stdin> [command] — GOUT = stdout, RC; the ssh and lsof stubs stand in, PATH has the open stub
run_fwd() {
  reset; rm -f "$FPID"
  GOUT="$(printf '%s' "$1" | SSH_ORIGINAL_COMMAND="${2:-login-forward}" IUMAC_GATE_HOME="$H" IUMAC_GATE_SSH="$FSSH" IUMAC_GATE_LSOF="$FLSOF" IUMAC_GATE_FORWARD_MAX=5 PATH="$BIN:$PATH" /bin/bash "$GATE" 2>/dev/null)"
  RC=$?
}
fwd_in() { printf '%s\n%s\n%s\n' "$1" "$2" "$3"; } # app port url
nothing_ran() { [[ -e "$REC/calls" ]] && echo no || echo yes; }
run_fwd "$(fwd_in Helium 58876 "$FURL")"
assert_eq "login-forward: rc 0, answers forwarded" "0/forwarded" "$RC/$GOUT"
assert_eq "...forward of exactly 127.0.0.1:<port> to the mini's 127.0.0.1:<port>, nothing else" "ssh|-N|-o|BatchMode=yes|-o|ConnectTimeout=8|-o|ExitOnForwardFailure=yes|-o|ServerAliveInterval=15|-o|ServerAliveCountMax=3|-o|ControlMaster=no|-o|ControlPath=none|-L|127.0.0.1:58876:127.0.0.1:58876|mini" "$(grep '^ssh' "$REC/calls")"
assert_eq "...the ORIGINAL URL is opened in the account's browser" "open|-a|Helium|$FURL" "$(grep '^open' "$REC/calls")"
if [[ -s "$FPID" ]] && ! kill -0 "$(cat "$FPID")" 2>/dev/null; then ok "...the forward is closed when the verb ends"; else bad "...the forward is closed when the verb ends"; fi
run_fwd "$(fwd_in "" 58876 "$FURL")"
assert_eq "no app: the default browser" "forwarded/open|$FURL" "$GOUT/$(grep '^open' "$REC/calls")"
run_fwd "$(fwd_in Helium 58876 "$FURL")" "login-forward now"
assert_eq "an argument is refused" "126/yes" "$RC/$(nothing_ran)"
refuse_fwd() { # <label> <app> <port> <url>
  run_fwd "$(fwd_in "$2" "$3" "$4")"
  assert_eq "login-forward refuses ($1): rc 126, nothing started" "126/yes" "$RC/$(nothing_ran)"
}
refuse_fwd "http URL" Helium 58876 "http://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback"
refuse_fwd "no URL" Helium 58876 ""
refuse_fwd "URL with a space" Helium 58876 "https://x/a b?redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback"
refuse_fwd "non-numeric port" Helium abc "$FURL"
refuse_fwd "port with a suffix" Helium 58876x "$FURL"
refuse_fwd "port with a leading zero" Helium 058876 "$FURL"
refuse_fwd "port 443" Helium 443 "$FURL"
refuse_fwd "port 1023" Helium 1023 "https://c/a?redirect_uri=http%3A%2F%2Flocalhost%3A1023%2Fcallback"
refuse_fwd "port above 65535" Helium 70000 "https://c/a?redirect_uri=http%3A%2F%2Flocalhost%3A70000%2Fcallback"
refuse_fwd "empty port" Helium "" "$FURL"
refuse_fwd "a port that differs from the redirect_uri" Helium 58877 "$FURL"
refuse_fwd "port only a prefix of the redirect_uri's" Helium 5887 "$FURL"
refuse_fwd "no redirect_uri" Helium 58876 "https://claude.com/cai/oauth/authorize?client_id=abc"
refuse_fwd "redirect_uri on another host" Helium 58876 "https://claude.com/a?redirect_uri=http%3A%2F%2Fevil.example%3A58876%2Fcallback"
refuse_fwd "redirect_uri on https" Helium 58876 "https://claude.com/a?redirect_uri=https%3A%2F%2Flocalhost%3A58876%2Fcallback"
refuse_fwd "app with a metacharacter" "Hel;ium" 58876 "$FURL"
refuse_fwd "app with a path" "../Helium" 58876 "$FURL"
run_fwd "$(fwd_in Helium 58876 'https://claude.com/a?x=1&redirect_uri=http://localhost:58876/callback&y=2')"
assert_eq "a raw (unescaped) loopback redirect_uri of the same port is accepted" "0/forwarded" "$RC/$GOUT"
STUB_LSOF_BUSY=1 run_fwd "$(fwd_in Helium 58876 "$FURL")"
assert_eq "port already taken on the MacBook: failed: port-busy, rc 1, no ssh, nothing opened" "1/failed: port-busy/yes" "$RC/$GOUT/$(nothing_ran)"
STUB_LSOF_UP=0 run_fwd "$(fwd_in Helium 58876 "$FURL")"
assert_eq "forward that does not come up: failed: forward, rc 1, nothing opened" "1/failed: forward/0" "$RC/$GOUT/$(grep -c '^open' "$REC/calls")"
if [[ -s "$FPID" ]] && ! kill -0 "$(cat "$FPID")" 2>/dev/null; then ok "...and the ssh is killed again"; else bad "...and the ssh is killed again"; fi
STUB_RC=1 run_fwd "$(fwd_in Helium 58876 "$FURL")"
assert_eq "open fails: failed: open, rc 1" "1/failed: open" "$RC/$(printf '%s' "$GOUT" | tail -n 1)"
case "$(cat "$H/Library/Logs/iumac-gate.log")" in *58876*|*claude.com*|*Helium*) bad "log: no port, URL or app" ;; *) ok "log: no port, URL or app" ;; esac
assert_contains "log: the verb is recorded" "login-forward allow" "$(cat "$H/Library/Logs/iumac-gate.log")"
assert_contains "log: refusals are recorded" "login-forward refuse" "$(cat "$H/Library/Logs/iumac-gate.log")"
# the verb holds while its stdin is open and ends with it; a helper timeout ends it otherwise
reset; rm -f "$FPID"; SECONDS=0
( fwd_in Helium 58876 "$FURL"; sleep 4 ) | SSH_ORIGINAL_COMMAND=login-forward IUMAC_GATE_HOME="$H" IUMAC_GATE_SSH="$FSSH" IUMAC_GATE_LSOF="$FLSOF" IUMAC_GATE_FORWARD_MAX=60 PATH="$BIN:$PATH" /bin/bash "$GATE" >/dev/null 2>&1
held=$SECONDS
if (( held >= 3 && held <= 9 )); then ok "login-forward holds while stdin is open and ends when it closes (${held} s)"; else bad "login-forward holds while stdin is open and ends when it closes" "took ${held} s"; fi
reset; rm -f "$FPID"
( fwd_in Helium 58876 "$FURL"; sleep 8 ) | { t0=$(date +%s); SSH_ORIGINAL_COMMAND=login-forward IUMAC_GATE_HOME="$H" IUMAC_GATE_SSH="$FSSH" IUMAC_GATE_LSOF="$FLSOF" IUMAC_GATE_FORWARD_MAX=2 PATH="$BIN:$PATH" /bin/bash "$GATE" >/dev/null 2>&1; echo $(($(date +%s) - t0)) >"$TMP/held"; }
held=$(cat "$TMP/held")
if (( held <= 6 )); then ok "...and the helper timeout ends it with stdin still open (${held} s)"; else bad "...and the helper timeout ends it with stdin still open" "took ${held} s"; fi

echo "== login-code: the dialog on the MacBook"
cat >"$BIN/osascript" <<'STUB'
#!/bin/bash
{ printf 'osascript'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >>"$REC_DIR/calls"
cat >/dev/null
[ "${STUB_CANCEL:-0}" = 1 ] && exit 1
printf '%b' "${STUB_ANSWER-}"
STUB
chmod +x "$BIN/osascript"
# run_code <stdin> [command] — GOUT = stdout, RC
run_code() {
  reset
  GOUT="$(printf '%s' "$1" | REC_DIR="$REC" SSH_ORIGINAL_COMMAND="${2:-login-code}" IUMAC_GATE_HOME="$H" PATH="$BIN:$PATH" /bin/bash "$GATE" 2>/dev/null)"
  RC=$?
}
STUB_ANSWER='abcdef123456#zzstate99\n' run_code "me
"
assert_eq "login-code: what was typed comes back, nothing else" "0/abcdef123456#zzstate99" "$RC/$GOUT"
assert_eq "...the dialog is titled with the account and says where the code goes" "osascript|-|Claude login me: paste the code from the page|Approve in the browser, then paste the code the approval page shows here.|900" "$(calls)"
STUB_CANCEL=1 run_code "me
"; assert_eq "cancelled: rc 1, nothing printed" "1/" "$RC/$GOUT"
STUB_ANSWER='\n' run_code "me
"; assert_eq "empty: rc 1, nothing printed" "1/" "$RC/$GOUT"
STUB_ANSWER='ab\001cd\033ef\n' run_code "me
"; assert_eq "control characters are stripped" "0/abcdef" "$RC/$GOUT"
STUB_ANSWER="$(printf 'x%.0s' $(seq 1 700))" run_code "me
"; assert_eq "an answer is cut at 600 characters" "600" "$(printf '%s' "$GOUT" | wc -c | tr -d ' ')"
for badid in "Me" "a b" "x;y" "" "$(printf 'a%.0s' $(seq 1 33))" '$(id)'; do
  STUB_ANSWER='abc\n' run_code "$badid
"
  assert_eq "login-code refuses the account '$badid'" "126/yes" "$RC/$(nothing_ran)"
done
STUB_ANSWER='abc\n' run_code "me
" "login-code now"; assert_eq "login-code with an argument is refused" "126" "$RC"
STUB_ANSWER='secretcode12345\n' run_code "me
"
case "$(cat "$H/Library/Logs/iumac-gate.log")" in *secretcode12345*) bad "log: never the answer" ;; *) ok "log: never the answer" ;; esac
assert_contains "log: the verb is recorded" "login-code allow" "$(cat "$H/Library/Logs/iumac-gate.log")"
mkstub "$BIN/osascript" osascript

echo "== ssh-agent.zsh: incoming ssh session gets no 1Password socket"
if ! command -v zsh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: zsh or python3 missing"
else
  ZH="$TMP/zhome"
  SOCKDIR="$ZH/Library/Group Containers/2BUA8C4S2C.com.1password/t"
  mkdir -p "$SOCKDIR" "$ZH/.config/secrets"
  echo op >"$ZH/.config/secrets/backend"
  # bind relative to the dir: unix socket paths are limited to ~104 bytes
  (cd "$SOCKDIR" && python3 -I -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind("agent.sock")' 2>/dev/null)
  if [[ ! -S "$SOCKDIR/agent.sock" ]]; then
    echo "  skip: could not create a unix socket in the temp tree (negative case still checked)"
  fi
  zsh_sock() { env -u SSH_AUTH_SOCK -u SSH_CONNECTION HOME="$ZH" XDG_CONFIG_HOME="$ZH/.config" "$@" zsh -f -c 'source "$1"; print -r -- "${SSH_AUTH_SOCK-unset}"' _ "$AGENT_ZSH"; }
  assert_eq "ssh session: SSH_AUTH_SOCK stays unset" "unset" "$(zsh_sock SSH_CONNECTION='1 2 3 4')"
  if [[ -S "$SOCKDIR/agent.sock" ]]; then
    assert_eq "local shell (positive control): socket exported" "$SOCKDIR/agent.sock" "$(zsh_sock)"
  fi
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
