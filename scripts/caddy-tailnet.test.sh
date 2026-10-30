#!/usr/bin/env bash
# caddy-tailnet.test — proves the extra FQDN doors of scripts/caddy-tailnet.sh.
#
# Hermetic: every input and the output are scratch files (the generator's own
# overrides), tailscale is a stub, the Cloudflare token is a fake. Nothing real is
# read, written or reloaded — the same rule the generator's header spells out.
# The fake token has the 40-character shape the Cloudflare module checks at validate time.
# Needs `brew`, `caddy` and the cloudflare DNS module (`make caddy-dns-build`);
# without them the suite skips instead of failing, like caddy-registry.test.py.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/caddy-tailnet.sh"

if ! command -v brew >/dev/null 2>&1 || ! command -v caddy >/dev/null 2>&1 \
   || ! caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
  echo "skip: caddy-tailnet generator needs brew + caddy with dns.providers.cloudflare"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/caddy-tailnet-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$2" <<<"$3" && ok "$1" || bad "$1 — missing '$2'"; }
lacks() { grep -qF -- "$2" <<<"$3" && bad "$1 — found '$2'" || ok "$1"; }

cat > "$TMP/Caddyfile" <<'EOF'
plain.test {
	reverse_proxy localhost:7001
}
rew.test {
	reverse_proxy localhost:7002 {
		header_up Host localhost:7002
	}
}
audio.test {
	@door path /v1/audio/* /audio/*
	handle @door {
		reverse_proxy localhost:7003
	}
	handle {
		respond 404
	}
}
off.test {
	reverse_proxy localhost:7004
}
EOF
printf '# format: registry-v2\nexclude off\n' > "$TMP/ports"
printf 'DEV_DOMAIN=dev.example.com\nCF_TOKEN_FILE=%s\n' "$TMP/token" > "$TMP/conf"
printf 'FAKE0123456789abcdefghijklmnopqrstuvwxyz\n' > "$TMP/token"; chmod 600 "$TMP/token"

cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"status --json"*) cat <<'J'
{"Self":{"DNSName":"mini.example.ts.net.","HostName":"mini","TailscaleIPs":["100.64.0.9","fd7a::9"]},
 "Peer":{"a":{"Tags":["tag:vps"],"TailscaleIPs":["100.64.0.20"]},"b":{"Tags":["tag:mac"],"TailscaleIPs":["100.64.0.30"]}}}
J
  ;;
  *) echo null ;;
esac
EOF
chmod +x "$TMP/tailscale"

# gen <hosts-file> -> $rc, $log (combined output), $OUT (the include)
OUT="$TMP/out.caddy"
gen() {
  rm -f "$OUT"
  log=$(TAILSCALE_BIN="$TMP/tailscale" TAILSCALE_SOCKET="" \
    CADDY_TAILNET_CADDYFILE="$TMP/Caddyfile" CADDY_TAILNET_PORTS="$TMP/ports" \
    CADDY_TAILNET_CONF="$TMP/conf" CADDY_TAILNET_APPS="$TMP/none.apps" \
    CADDY_TAILNET_HOSTS="$1" CADDY_TAILNET_OUT="$OUT" \
    CADDY_TAILNET_PAGE_DIR="$TMP/page" CADDY_TAILNET_NO_RELOAD=1 \
    bash "$GEN" 2>&1)
  rc=$?
}
extra() { sed -n '/^# --- extra door/,$p' "$OUT"; }

dies() { # <label> <hosts line> <message fragment>
  printf '%s\n' "$2" > "$TMP/hosts"
  gen "$TMP/hosts"
  [ "$rc" != 0 ] && ok "$1 → dies" || bad "$1 → expected a non-zero exit"
  has "$1 → says why" "$3" "$log"
}

echo "extra FQDN doors"

printf '# comment\n\nweb.example.org plain\n' > "$TMP/hosts"
gen "$TMP/hosts"
[ "$rc" = 0 ] && ok "valid line → exit 0" || bad "valid line → rc=$rc: $log"
blk=$(extra)
has "block opens on the fqdn"       "web.example.org {" "$blk"
has "binds the tailnet IP"          "bind 100.64.0.9" "$blk"
has "own tls with the token"        "dns cloudflare FAKE0123456789abcdefghijklmnopqrstuvwxyz" "$blk"
has "resolvers pinned"              "resolvers 1.1.1.1" "$blk"
has "source guard for the peers"    "remote_ip 100.64.0.20" "$blk"
has "guard answers 403"             'respond "forbidden" 403' "$blk"
has "proxies to the app's port"     "reverse_proxy localhost:7001" "$blk"
lacks "no landing page fallback"    "file_server" "$blk"
lacks "no probe routes"             "/_up/" "$blk"
[ "$(stat -f '%Lp' "$OUT")" = 600 ] && ok "include stays chmod 600" || bad "include is not chmod 600"
has "summary lists the extra door"  "1 extra door(s)" "$log"
has "summary names it"              "https://web.example.org" "$log"
wild=$(grep -n '^\*\.dev\.example\.com, dev\.example\.com {' "$OUT" | cut -d: -f1)
door=$(grep -n '^web\.example\.org {' "$OUT" | cut -d: -f1)
[ -n "$wild" ] && [ -n "$door" ] && [ "$wild" -lt "$door" ] \
  && ok "block sits after the wildcard block" || bad "block is not after the wildcard block ($wild/$door)"
caddy validate --config "$OUT" --adapter caddyfile >/dev/null 2>&1 \
  && ok "caddy validate accepts the include" || bad "caddy validate rejects the include"

printf 'web.example.org rew\n' > "$TMP/hosts"; gen "$TMP/hosts"
has "rewrite app keeps header_up Host" "header_up Host localhost:7002" "$(extra)"

printf 'api.example.org audio\n' > "$TMP/hosts"; gen "$TMP/hosts"
blk=$(extra)
has "path-restricted app keeps its paths"  "@audio_paths path /v1/audio/* /audio/*" "$blk"
has "path-restricted app keeps the 404"    'respond "not found" 404' "$blk"

printf 'a.example.org plain\nb.example.org rew\n' > "$TMP/hosts"; gen "$TMP/hosts"
has "two lines → two blocks" "2 extra door(s)" "$log"
has "second block present"   "b.example.org {" "$(extra)"

: > "$TMP/hosts"; gen "$TMP/hosts"
[ "$rc" = 0 ] && ok "comment-free empty file → exit 0" || bad "empty file → rc=$rc"
lacks "empty file → no extra block" "extra door" "$(cat "$OUT")"
gen "$TMP/absent.hosts"
[ "$rc" = 0 ] && ok "missing file → exit 0" || bad "missing file → rc=$rc: $log"
lacks "missing file → no extra block" "extra door" "$(cat "$OUT")"
lacks "missing file → no summary line" "extra door" "$log"

dies "unknown app"            "web.example.org nosuch"        "unknown app 'nosuch'"
dies "excluded app"           "web.example.org off"           "excluded"
dies "under DEV_DOMAIN"       "x.dev.example.com plain"       "wildcard door already covers"
dies "equal to DEV_DOMAIN"    "dev.example.com plain"         "wildcard door already covers"
dies "landing page host"      "apps.dev.example.com plain"    "landing page"
dies "single label"           "localhost plain"               "at least two labels"
dies "uppercase"              "Web.Example.org plain"         "lowercase DNS name"
dies "wildcard name"          "*.example.org plain"           "lowercase DNS name"
dies "missing app column"     "web.example.org"               "expected '<fqdn> <app-name>'"
dies "extra column"           "web.example.org plain more"    "expected '<fqdn> <app-name>'"
dies "duplicate fqdn"         "$(printf 'web.example.org plain\nweb.example.org rew')" "listed twice"

[ "$fails" = 0 ] && { echo "caddy-tailnet generator: all passed"; exit 0; }
echo "caddy-tailnet generator: $fails failed"
exit 1
