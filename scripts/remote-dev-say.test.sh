#!/usr/bin/env bash
# remote-dev-say.test — `rd say` on hc (fake `hc`, remote-dev-fake-hc.sh). Property under test: a message that did not
# land can never look delivered, and one that did land is never reported lost (which would invite a duplicate). A target
# hc does not know is an error, never a fallback.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-say-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
calls() { grep -c -- "$1" "$STATE/calls.log" 2>/dev/null || true; }
expect_calls() { [ "$(calls "$2")" -eq "$3" ] && ok "$1" || bad "$1 — '$2' called $(calls "$2")×, want $3"; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home/.local/bin" "$TMP/xdg/secrets"
echo cache >"$TMP/xdg/secrets/backend"
cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
# launchd runs the core unless $STATE/no_core exists
cat >"$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
[ -f "$STATE/no_core" ] && exit 113
echo "state = running"
STUB
chmod +x "$TMP/bin/launchctl" "$TMP/home/.local/bin/hc"
# No real `factory` may answer (the mini has one in ~/.local/bin): drop every PATH dir that holds one.
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
unset RD_DRY_RUN

say() { out=$(bash "$HERE/remote-dev.sh" say worker "$@" 2>&1); rc=$?; }
ends_ok()   { [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"; }
ends_fail() { [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success: $out"; has "says NOT delivered" "$out" "NOT delivered"; }

# --- the target lives in herdr-core -------------------------------------------------------------------------
roster() { # <status-or-null> [name]
  local st=$1 name=${2:-worker}
  [ "$st" = null ] || st="{\"app\":\"claude-code\",\"state\":\"$st\"}"
  echo "[{\"address\":\"t5\",\"name\":\"$name\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":$st,\"labels\":{}}]" >"$STATE/terminals.json"
}
hcreset() { rm -rf "${STATE:?}"/*; }
sent() { cat "$STATE/last_args" 2>/dev/null; }

echo "hc: idle agent gets the text through hc send"
hcreset; roster idle
say "go on"; ends_ok
has "says delivered" "$out" "delivered"
has "sent to its address" "$(cat "$STATE/calls.log")" "send -- t5 go on"
lacks "never forced past a dialog" "$(cat "$STATE/calls.log")" "--force"

echo "hc: working agent: the message is queued behind its turn"
hcreset; roster working
say "go on"; ends_ok
has "says queued" "$out" "queued: agent busy"
has "still sent once" "$(cat "$STATE/calls.log")" "send -- t5 go on"

echo "hc: a blocked agent is refused (the text would answer its dialog)"
hcreset; roster blocked
say "go on"; ends_fail
has "says why" "$out" "blocked on a dialog"
has "points at rd read" "$out" "rd read worker"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into a blocked agent: $(sent)"

echo "hc: hc itself refuses -> NOT delivered"
hcreset; roster idle; touch "$STATE/send_fail"
say "go on"; ends_fail
has "says hc send failed" "$out" "hc send failed"

echo "hc: exact bytes, leading dash, quotes, newlines"
hcreset; roster idle
text=$'-dash \'quoted\' "dq" $(echo no) `no`\n\nlast line\n\n\n'
say "$text"; ends_ok
want=$(printf '%s\n%s\n%s\n' "--" "t5" "$text")
[ "$(sent)" = "${want%$'\n'}" ] && ok "arrives byte-identical after the address" || bad "bytes differ: $(sent | od -c | head -3)"

echo "hc: a send that times out is unconfirmed, never 'NOT delivered'"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  hcreset; roster idle; touch "$STATE/send_hang"
  out=$(RD_HC_TIMEOUT_S=1 bash "$HERE/remote-dev.sh" say worker "go on" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success"
  has "says delivery unconfirmed" "$out" "delivery unconfirmed"
  has "advises rd read before retrying" "$out" "'rd read worker' before retrying"
  lacks "not claimed as undelivered" "$out" "NOT delivered"
fi

echo "hc: no status yet is not a prompt"
hcreset; roster null
say "go on"; ends_fail
has "says so" "$out" "not at a prompt yet"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into an agent that has not reported"

echo "hc: never types into a shell"
hcreset
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
out=$(bash "$HERE/remote-dev.sh" say t5 "go on" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a shell with a status: refused" || bad "typed into a shell: $out"
has "says so" "$out" "not claude"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into a shell"
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"foreground\":{\"argv\":[\"claude\"]},\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
say "go on"; ends_ok

echo "hc: a send that ends without an error answer is unconfirmed"
hcreset; roster idle; touch "$STATE/send_crash"
say "go on"; [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success"
has "unconfirmed" "$out" "delivery unconfirmed"
lacks "not claimed as undelivered" "$out" "NOT delivered"

echo "hc: resolves by repo name, address and cwd; a shell is no agent"
hcreset; roster idle
out=$(bash "$HERE/remote-dev.sh" say nope "go" 2>&1); rc=$?; [ "$rc" -ne 0 ] && ok "unknown token: error" || bad "unknown token accepted"
has "unknown token: lists the roster" "$out" "t5"
for tok in t5 worker /x x; do
  out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say "$tok" "go" 2>&1)
  [ "$tok" = x ] && { has "'x' (the cwd's basename) resolves" "$out" "t5"; continue; }
  [ "$out" = "t5" ] && ok "'$tok' resolves to t5" || bad "'$tok' -> $out"
done
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say worker "go" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a plain shell is not an agent" || bad "a shell resolved: $out"
echo "[{\"address\":\"t5\",\"name\":\"a\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}},{\"address\":\"t6\",\"name\":\"b\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say x "go" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "two agents in one checkout: ask which" || bad "ambiguous token resolved: $out"
has "ambiguity lists both" "$out" "t6"

echo "hc: an address-like name (t7app) resolves through its escaped terminal name"
hcreset
esc="f-$(printf %s t7app | shasum -a 256 | cut -c1-12 | cut -c1-6)-t7app"
echo "[{\"address\":\"t5\",\"name\":\"$esc\",\"cwd\":\"/y\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say t7app "go" 2>&1)
[ "$out" = "t5" ] && ok "resolved" || bad "t7app -> $out"

echo "hc: a target hc does not know is an error"
hcreset; roster idle
out=$(bash "$HERE/remote-dev.sh" say ghost "go on" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "refused" || bad "accepted an unknown target: $out"
has "says no agent matches" "$out" "no agent matches 'ghost'"
has "lists the agents hc does know" "$out" "t5"
lacks "nothing sent" "$(cat "$STATE/calls.log")" "send "

echo "hc: an empty core says so"
hcreset
out=$(bash "$HERE/remote-dev.sh" say ghost "go on" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "refused" || bad "accepted an unknown target: $out"
has "says the core has no agents" "$out" "no agents at all"

echo "no core: error, hc is not called"
hcreset; touch "$STATE/no_core"
say "go on"; [ "$rc" -ne 0 ] && ok "refused" || bad "ran without a core"
has "names the fix" "$out" "launchctl kickstart"
[ ! -e "$STATE/hc-called" ] && ok "hc was not called" || bad "hc was called"

echo; [ "$fails" -eq 0 ] && echo "remote-dev-say: all passed" || { echo "remote-dev-say: $fails failed"; exit 1; }
