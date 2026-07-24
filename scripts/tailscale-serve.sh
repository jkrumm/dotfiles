#!/usr/bin/env bash
# Declarative `tailscale serve` / `funnel` bindings for this machine.
#
# Why this exists: serve config is imperative CLI state that lives only in
# tailscaled, and it PINS THE MACHINE'S MagicDNS NAME. Renaming the device
# silently orphans every binding — the old name stays in the config and nothing
# is reachable under the new one. Nothing in git recorded what was supposed to
# be exposed, so a rename or a disk loss meant reconstructing it from memory.
#
# The declared state lives in the PRIVATE repo (it is an exposure map: which
# local ports this machine publishes, and which of them go to the public
# internet via Funnel). This script is the generic applier and stays public.
#
#   $SECRETS_PRIVATE_REPO/tailscale-serve.<machine>.conf
#     # port  target                  funnel
#     7730    http://127.0.0.1:4050   no
#     8443    http://localhost:5173   yes
#
# <machine> is the tailnet name (`tailscale status` → Self), not the OS
# hostname, so the file follows the device identity that the bindings key off.
#
# Usage: tailscale-serve.sh [--check]
#   (default)  apply the declared state if it differs from what is live
#   --check    report drift and exit 1 without touching anything
set -euo pipefail

PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

command -v tailscale >/dev/null 2>&1 || { echo "✗ tailscale CLI not found"; exit 2; }

MACHINE=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["HostName"])')
CONF="$PRIVATE_REPO/tailscale-serve.$MACHINE.conf"

if [ ! -f "$CONF" ]; then
    echo "· no declared serve bindings for '$MACHINE' ($CONF) — nothing to do"
    exit 0
fi

# Desired state, normalised to sorted "port|target|funnel" lines.
desired=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" \
    | awk '{ printf "%s|%s|%s\n", $1, $2, ($3 == "yes" ? "yes" : "no") }' \
    | sort)

# Live state, same shape. Web keys are "<magicdns-name>:<port>", so the port is
# the last colon-separated field; funnel is a separate AllowFunnel map.
live=$(tailscale serve status --json 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
cfg = json.loads(raw) if raw and raw != "null" else {}
funnel = cfg.get("AllowFunnel") or {}
rows = []
for hostport, web in (cfg.get("Web") or {}).items():
    port = hostport.rsplit(":", 1)[-1]
    proxy = ((web.get("Handlers") or {}).get("/") or {}).get("Proxy", "")
    rows.append("%s|%s|%s" % (port, proxy, "yes" if funnel.get(hostport) else "no"))
print("\n".join(sorted(rows)))
')

if [ "$desired" = "$live" ]; then
    echo "✓ tailscale serve in sync with $(basename "$CONF") ($(echo "$desired" | grep -c .) bindings)"
    exit 0
fi

echo "  drift on '$MACHINE':"
diff <(echo "$live") <(echo "$desired") | sed 's/^/    /' || true

if $CHECK_ONLY; then
    echo "✗ declared serve config not applied (run: make tailscale-serve)"
    exit 1
fi

# Apply. `reset` first because a rename leaves bindings keyed to the old name
# that no per-port `off` can address. Brief interruption is intentional and the
# only way to converge; everything is re-added immediately below.
echo "  applying..."
tailscale serve reset
while IFS='|' read -r port target funnel; do
    [ -n "$port" ] || continue
    if [ "$funnel" = "yes" ]; then
        tailscale funnel --bg "--https=$port" "$target" >/dev/null
        echo "    ✓ :$port → $target (Funnel — public internet)"
    else
        tailscale serve --bg "--https=$port" "$target" >/dev/null
        echo "    ✓ :$port → $target (tailnet only)"
    fi
done <<< "$desired"

echo "✓ applied — verify with: tailscale serve status"
