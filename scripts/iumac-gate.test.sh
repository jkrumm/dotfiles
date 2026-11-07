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

expect_allowed "ask-push" "ask-push 20261107T101500-abc.1_x" "ask-human|push|20261107T101500-abc.1_x"

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
expect_allowed "hc-version" "hc-version" "hc|--version"

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
expect_refused "ask-push no id" "ask-push"
expect_refused "ask-push ../x" "ask-push ../x"
expect_refused "ask-push a;b" "ask-push a;b"
expect_refused "ask-push .." "ask-push .."
expect_refused "ask-push two ids" "ask-push a b"
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
LOGF="$H/Library/Logs/iumac-gate.log"
run_gate "ask-push topsecret-id-123"
if [[ -f "$LOGF" ]]; then
  assert_contains "log: verb + allow" "ask-push allow" "$(cat "$LOGF")"
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
