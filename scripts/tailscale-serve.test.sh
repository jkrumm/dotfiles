#!/usr/bin/env bash
# tailscale-serve.test — hermetic suite for scripts/tailscale-serve.sh.
#
# TAILSCALE_BIN is a stub that logs its argv and answers status/serve status from
# fixtures, so the suite proves the script never touches a bare `tailscale` (the
# stub is the only CLI on a PATH that has none) and always passes the CLI's
# explicit --socket when one is set. The private repo is a scratch dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/tailscale-serve.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-serve-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/priv"

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$2" <<<"$3" && ok "$1" || bad "$1 — missing '$2'"; }

cat > "$TMP/ts" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TS_LOG"
case "$*" in
  *"serve status --json"*) cat "$TS_SERVE_JSON" ;;
  *"status --json"*) echo '{"Self":{"HostName":"testbox"}}' ;;
esac
STUB
chmod +x "$TMP/ts"

printf '# port target funnel\n7730 http://127.0.0.1:4050 no\n8443 http://localhost:5173 yes\n' > "$TMP/priv/tailscale-serve.testbox.conf"
echo '{"Web":{"testbox.ts.net:7730":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4050"}}},"testbox.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:5173"}}}},"AllowFunnel":{"testbox.ts.net:8443":true}}' > "$TMP/sync.json"
echo '{}' > "$TMP/empty.json"

run() { # <serve-json> [args...]
  local json="$1"; shift
  : > "$TMP/log"
  PATH="/usr/bin:/bin" TAILSCALE_BIN="$TMP/ts" TAILSCALE_SOCKET="" TS_LOG="$TMP/log" TS_SERVE_JSON="$json" \
    SECRETS_PRIVATE_REPO="$TMP/priv" /bin/bash "$SCRIPT" "$@" 2>&1
}

echo "tailscale-serve"
out=$(run "$TMP/sync.json" --check); rc=$?
[ "$rc" = 0 ] && ok "in sync: exit 0" || bad "in sync: exit $rc"
has "in sync: reported" "in sync" "$out"

out=$(run "$TMP/empty.json" --check); rc=$?
[ "$rc" = 1 ] && ok "drift: exit 1" || bad "drift: exit $rc"
has "drift: reported" "drift on 'testbox'" "$out"
grep -qE 'serve (reset|--bg)|funnel' "$TMP/log" && bad "--check mutated" || ok "--check never mutates"

out=$(run "$TMP/empty.json"); rc=$?
[ "$rc" = 0 ] && ok "apply: exit 0" || bad "apply: exit $rc"
log=$(cat "$TMP/log")
has "apply: reset" "serve reset" "$log"
has "apply: serve" "serve --bg --https=7730 http://127.0.0.1:4050" "$log"
has "apply: funnel" "funnel --bg --https=8443 http://localhost:5173" "$log"

# Brew variant (socket set, not root): reads go straight to the CLI with --socket,
# mutating calls go through sudo with --socket. The stub sudo only logs and execs.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\necho "sudo $*" >> "$TS_LOG"\nexec "$@"\n' > "$TMP/bin/sudo"
  chmod +x "$TMP/bin/sudo"
  : > "$TMP/log"
  PATH="$TMP/bin:/usr/bin:/bin" TAILSCALE_BIN="$TMP/ts" TAILSCALE_SOCKET="/sock" TS_LOG="$TMP/log" \
    TS_SERVE_JSON="$TMP/empty.json" SECRETS_PRIVATE_REPO="$TMP/priv" /bin/bash "$SCRIPT" >/dev/null 2>&1
  log=$(cat "$TMP/log")
  has "socket: status read carries --socket" "--socket=/sock status --json" "$log"
  has "socket: reset via sudo + --socket" "sudo $TMP/ts --socket=/sock serve reset" "$log"
  has "socket: funnel via sudo + --socket" "sudo $TMP/ts --socket=/sock funnel --bg --https=8443" "$log"
  grep -q "^sudo .*status" "$TMP/log" && bad "read-only call used sudo" || ok "read-only calls skip sudo"
else
  echo "  - SKIP sudo branch (running as root)"
fi

# Missing CLI: exit 2, no traceback.
out=$(PATH="/usr/bin:/bin" TAILSCALE_BIN="" SECRETS_PRIVATE_REPO="$TMP/priv" /bin/bash -c "
  # force the probe to find nothing: re-source with no known paths
  export HOME=$TMP; source <(sed 's#/var/run/tailscaled.socket#/nonexistent#; s#/Applications/Tailscale.app#/nonexistent#' \"$HERE/lib/tailscale-cli.sh\"); echo bin=[\$TAILSCALE_BIN]" 2>&1)
has "no CLI resolves empty" "bin=[]" "$out"

[ "$fails" = 0 ] && { echo "✓ tailscale-serve: all passed"; exit 0; }
echo "✗ tailscale-serve: $fails failed"; exit 1
