---
name: cloudflare
description: Cloudflare API operations across VPS and HomeLab — DNS records, tunnel ingress, multi-zone. Single skill for both servers; uses op://common/cloudflare for shared bits and per-server vaults for tunnel TOKEN/ID. Never exposes the API token to Claude Code directly.
---

# Cloudflare API Skill

Source of truth: `~/SourceRoot/dotfiles/skills/cloudflare/`. Symlinked into `~/.claude/skills/cloudflare/` by `dotfiles/Makefile` so it's globally available.

Handles DNS + tunnel operations for **both** the VPS and the HomeLab from a single skill. Pick a target — `vps` or `homelab` — based on the user's request or the current repo (`cwd` under `~/SourceRoot/vps/` → vps; under `~/SourceRoot/homelab/` → homelab).

**Paths:** `--env-file=$HOME/<target>/.env.tpl`, never `~/…` — `~` is not expanded after `=`, and `op run` fails with `open ~/vps/.env.tpl: no such file`.

**Execution model:** Every API call runs *on the target server* via `ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'…'"'"''`. The API token (`CLOUDFLARE_MANAGE_TOKEN`) stays in 1Password — never passed as a CLI argument, never visible to Claude Code, never logged.

---

## 1Password Layout

Shared values live in **`common`** (used by both servers). Per-server bits live in their respective vault. The two servers run **separate Cloudflare Tunnels** — each has its own `TUNNEL_ID` and tunnel `TOKEN`, but they share API token + account + zone IDs.

| Env var | 1Password ref | Notes |
|-|-|-|
| `CLOUDFLARE_MANAGE_TOKEN` | `op://common/cloudflare/MANAGE_API_TOKEN` | Dashboard name **cf-manage**. Zone.DNS + Account.Cloudflare Tunnel + Zone.Cache Rules:Edit, all zones. **Every snippet in this skill uses it.** |
| `CLOUDFLARE_API_TOKEN` | `op://common/cloudflare/DNS_API_TOKEN` | Dashboard name **dns-acme**. Zone.DNS only — Traefik (as `CF_DNS_API_TOKEN`) / Caddy ACME DNS-01. Not for this skill: it cannot read tunnels or rulesets. |
| — | `op://common/cloudflare/CACHE_PURGE_TOKEN` | Dashboard name **CACHE_PURGE_TOKEN**. Zone.Zone:Read + Zone.Cache Purge, all zones. CI only — GitHub secret `CLOUDFLARE_PURGE_TOKEN`. |
| `CLOUDFLARE_ACCOUNT_ID` | `op://common/cloudflare/ACCOUNT_ID` | Account ID — same across all zones/tunnels. |
| `CLOUDFLARE_ZONE_ID` | `op://common/cloudflare/ZONE_ID_JKRUMM_COM` | Zone ID for `jkrumm.com`. Other zones (`basalt-ui.com`, `rollhook.com`, `shutterflow.app`) are looked up on demand. |
| `CLOUDFLARE_TUNNEL_ID` | `op://vps/cloudflare-tunnel/TUNNEL_ID` *(VPS)*<br>`op://homelab/config/CLOUDFLARE_TUNNEL_ID` *(HomeLab)* | Per-server tunnel UUID. |
| `CLOUDFLARE_TUNNEL_TOKEN` | `op://vps/cloudflare-tunnel/TOKEN` *(VPS)*<br>`op://homelab/cloudflare-tunnel/TOKEN` *(HomeLab)* | Per-server cloudflared auth token. |

---

## Per-Target Architecture

| | **VPS** | **HomeLab** |
|-|-|-|
| Repo | `~/SourceRoot/vps/` | `~/SourceRoot/homelab/` |
| SSH | `ssh vps` | `ssh homelab` |
| `.env.tpl` location | `~/vps/.env.tpl` | `~/homelab/.env.tpl` |
| Tunnel ingress model | `*.jkrumm.com → https://traefik:443` plus **one explicit entry per apex/other-zone host** (`jkrumm.com`, `basalt-ui.com`, `www.basalt-ui.com`, `rollhook.com`, …) — a wildcard never matches its own apex. Subdomain of jkrumm.com = CNAME only. Apex or another zone = CNAME **and** an ingress entry (GET → insert before the catch-all → PUT). | Per-subdomain entries with a `http_status:404` catch-all. Adding a public subdomain = (1) Caddyfile site block, (2) DNS CNAME, (3) tunnel ingress entry **before** the catch-all. |
| Reverse proxy | Traefik v3 (Docker labels) | Caddy (manual `Caddyfile`) |

**Both** tunnels evaluate independently — adding a hostname to one does not affect the other. Each VPS/HomeLab subdomain has a CNAME pointing to **its** tunnel via `${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com`.

---

## Authentication Pattern

Use single-quote wrapping so `${VAR}` references are expanded by the **remote** shell (after 1Password injects them), not by the local shell:

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'
  curl -s "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" \
    | python3 -m json.tool
'"'"''
```

**Why:** Double-quoting the SSH command lets the local shell expand `${CLOUDFLARE_MANAGE_TOKEN}` to an empty string before it ever reaches the remote shell, producing an auth error. The `'…' '"'"' …'"'"' '…'` pattern passes the inner string literally to the remote, where `op run` has injected the secret.

---

## Common Operations

Substitute `<target>` with `vps` or `homelab` in each command.

### List all zones

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(z[\"name\"],z[\"id\"]) for z in r[\"result\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### List DNS records for a zone

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?per_page=100" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(rec[\"type\"],rec[\"name\"],\"->\",rec[\"content\"]) for rec in r[\"result\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### Add a DNS CNAME record (subdomain → tunnel, proxied)

For HTTP services routed through the target's Cloudflare Tunnel.

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"CNAME\",\"name\":\"SUBDOMAIN\",\"content\":\"${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK:\",r[\"result\"][\"name\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

Replace `SUBDOMAIN` with the bare subdomain label (e.g. `myapp`).

### Add a DNS A record (grey cloud — `proxied:false`)

For services that bypass Cloudflare:
- **Raw TCP** that Cloudflare doesn't proxy on non-Enterprise plans (e.g. MySQL/MariaDB on `fpp-db.jkrumm.com`)
- **Tailscale-only** services (point at the Tailscale IP — public internet can't reach CGNAT)

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"SUBDOMAIN\",\"content\":\"PUBLIC_OR_TAILSCALE_IP\",\"proxied\":false}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK:\",r[\"result\"][\"name\"],\"->\",r[\"result\"][\"content\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

Replace `SUBDOMAIN` and `PUBLIC_OR_TAILSCALE_IP`.

### Delete a DNS record

List first, find the record's ID, then:

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/RECORD_ID" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK\" if r[\"success\"] else r[\"errors\"])"'"'"''
```

### Look up Zone ID for a secondary domain

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones?name=other-domain.com" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"result\"]; print(r[0][\"id\"],r[0][\"name\"]) if r else print(\"not found\")"'"'"''
```

### Inspect current tunnel ingress config

```bash
ssh <target> 'op run --env-file=$HOME/<target>/.env.tpl -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(i.get(\"hostname\",\"catch-all\"),\"->\",i[\"service\"]) for i in r[\"result\"][\"config\"][\"ingress\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### Insert one VPS ingress entry (preserves the rest)

```bash
ssh vps 'op run --env-file=$HOME/vps/.env.tpl -- bash -c '"'"'
E="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations"
CUR=$(curl -s "$E" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}")
BODY=$(NEW_HOST=HOSTNAME python3 -c "
import json,os,sys
cfg=json.loads(sys.argv[1])[\"result\"][\"config\"]; ing=cfg[\"ingress\"]; h=os.environ[\"NEW_HOST\"]
if not any(i.get(\"hostname\")==h for i in ing):
    ing.insert(len(ing)-1,{\"hostname\":h,\"service\":\"https://traefik:443\",\"originRequest\":{\"noTLSVerify\":True}})
print(json.dumps({\"config\":cfg}))" "$CUR")
curl -s -X PUT "$E" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "$BODY" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK version\",r[\"result\"][\"version\"]) if r[\"success\"] else print(\"ERR\",r[\"errors\"])"
'"'"''
```

### Update tunnel ingress config

PUT replaces the **entire** ingress list. The list must end with `{"service":"http_status:404"}`. GET first, edit, then PUT.

**VPS** (wildcard model — usually only the wildcard rule changes for new TLS targets):

```bash
ssh vps 'op run --env-file=$HOME/vps/.env.tpl -- bash -c '"'"'curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "{\"config\":{\"ingress\":[{\"hostname\":\"*.${DOMAIN}\",\"service\":\"https://traefik:443\",\"originRequest\":{\"noTLSVerify\":true}},{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK - version\",r[\"result\"][\"version\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

**HomeLab** (per-subdomain model — append the new hostname before the catch-all). Example adding `newapp.jkrumm.com`:

```bash
ssh homelab 'op run --env-file=$HOME/homelab/.env.tpl -- bash -c '"'"'curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "{\"config\":{\"ingress\":[{\"hostname\":\"glance.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"hostname\":\"immich.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"hostname\":\"uptime.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"hostname\":\"public.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"hostname\":\"books.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"hostname\":\"newapp.jkrumm.com\",\"service\":\"http://caddy:80\"},{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK - version\",r[\"result\"][\"version\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

---

## Workflow: Add a new public app on **VPS**

1. Deploy the app's compose (it joins the `proxy` network, has `traefik.http.routers.<name>.rule=Host(\`<sub>.<DOMAIN>\`)` labels)
2. Add DNS CNAME record (subdomain → VPS tunnel)
3. Verify: `curl -I https://<sub>.<DOMAIN>/health`

No tunnel ingress change for a `*.jkrumm.com` subdomain. An **apex** (`jkrumm.com`, `example.com`) or a host in another zone needs an ingress entry too — without it cloudflared answers `404` with `cf-cache-status: DYNAMIC` and an empty body. Insert it programmatically so the other entries survive (see *Insert one VPS ingress entry* below).

## Workflow: Add a new public app on **HomeLab**

1. Update `Caddyfile` with the new site block (HTTPS + HTTP variant)
2. Update `docker-compose.yml` — add the service, attach to `cloudflared` network
3. Add DNS CNAME record (subdomain → HomeLab tunnel)
4. Update tunnel ingress config — full PUT with the new hostname before `http_status:404`
5. Push + redeploy:
   ```bash
   git push && ssh homelab "cd ~/homelab && git pull && op run --env-file=.env.tpl -- docker compose up -d --force-recreate caddy <newapp>"
   ```
6. Verify: `curl -I https://<sub>.jkrumm.com`
7. Add to `uptime-kuma/monitors.yaml` and run the sync (see homelab README).

## Workflow: Add a Tailscale-only or raw-TCP service

1. Add an A record with `proxied:false` (grey cloud) → Tailscale IP or VPS public IP
2. No tunnel ingress change — traffic doesn't flow through Cloudflare at all
3. For raw TCP exposure (e.g. MariaDB), open the host port at the firewall level and rely on app-level TLS + auth — see `vps/AGENTS.md` Security Invariants for the documented exception pattern.

---

## Edge cache for static sites (Cache Rule + purge on deploy)

Full pattern and rationale: `vps/docs/edge-cache.md`. Origin nginx sets the headers (HTML: `Cache-Control: public, max-age=0, must-revalidate` + `Cloudflare-CDN-Cache-Control: max-age=31536000`; hashed assets `immutable`); Cloudflare only needs **one Cache Rule per hostname** making it eligible and deferring to origin. Purge happens in CI via `jkrumm/rollhook-action@v1` (`cloudflare_purge_hosts` + `cloudflare_api_token`) — never here, never `purge_everything` (the jkrumm.com zone also fronts the image CDN).

**Token split:** rules are set with `CLOUDFLARE_MANAGE_TOKEN` (1Password + servers only); the purge runs in CI with `CACHE_PURGE_TOKEN`, which sits in public repos' GitHub secrets and so stays Zone:Read + Cache Purge only. Seed it without printing it — the VPS service account reads `common/`:

```bash
ssh vps "op read 'op://common/cloudflare/CACHE_PURGE_TOKEN'" | gh secret set CLOUDFLARE_PURGE_TOKEN --repo jkrumm/<repo>
```

### Add/replace the Cache Rule for a hostname

Cache Rules live in the zone's `http_request_cache_settings` entrypoint ruleset. `PUT …/entrypoint` **replaces every rule** — GET first, keep the others, then PUT. Set `ZONE` (look it up by name) and `HOST`:

```bash
ssh vps 'op run --env-file=$HOME/vps/.env.tpl -- bash -c '"'"'
ZONE=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=jkrumm.com" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"result\"][0][\"id\"])")
HOST=jkrumm.com
E="https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/http_request_cache_settings/entrypoint"
EXISTING=$(curl -s "$E" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}")
BODY=$(HOST=$HOST python3 -c "
import json,os,sys
r=json.loads(sys.argv[1]); host=os.environ[\"HOST\"]
rules=[x for x in ((r.get(\"result\") or {}).get(\"rules\") or []) if x.get(\"description\")!=f\"edge-cache {host}\"]
rules=[{k:v for k,v in x.items() if k in (\"expression\",\"action\",\"action_parameters\",\"description\",\"enabled\")} for x in rules]
rules.append({\"description\":f\"edge-cache {host}\",\"expression\":f\"(http.host eq \\\"{host}\\\")\",\"action\":\"set_cache_settings\",\"enabled\":True,
  \"action_parameters\":{\"cache\":True,\"edge_ttl\":{\"mode\":\"respect_origin\"},\"browser_ttl\":{\"mode\":\"respect_origin\"}}})
print(json.dumps({\"rules\":rules}))" "$EXISTING")
curl -s -X PUT "$E" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "$BODY" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print([x[\"description\"] for x in r[\"result\"][\"rules\"]]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"
'"'"''
```

A 404 on the GET just means the zone has no cache rules yet — the PUT creates the entrypoint. Free plan: 10 Cache Rules per zone.

### Manual purge of one hostname (CI normally does this)

```bash
ssh vps 'op run --env-file=$HOME/vps/.env.tpl -- bash -c '"'"'curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" -H "Authorization: Bearer ${CLOUDFLARE_MANAGE_TOKEN}" -H "Content-Type: application/json" --data "{\"hosts\":[\"HOST\"]}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK\" if r[\"success\"] else r[\"errors\"])"'"'"''
```

`cf-manage` has no Cache Purge — swap in `$(op read op://common/cloudflare/CACHE_PURGE_TOKEN)` for the bearer.

### Verify

`curl -sI https://HOST/ | grep -i cf-cache-status` twice → `MISS` then `HIT`; after a deploy → `MISS` again.

---

## Useful Reference

CF API base: `https://api.cloudflare.com/client/v4`

| Endpoint | Method | Purpose |
|-|-|-|
| `/zones` | GET | List zones (filter: `?name=domain.com`) |
| `/zones/{zone_id}/dns_records` | GET / POST | List / create DNS records |
| `/zones/{zone_id}/dns_records/{id}` | PUT / DELETE | Update / delete DNS record |
| `/accounts/{account_id}/cfd_tunnel` | GET | List tunnels |
| `/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations` | GET / PUT | Get / replace tunnel ingress config |
| `/zones/{zone_id}/rulesets/phases/http_request_cache_settings/entrypoint` | GET / PUT | Get / replace Cache Rules |
| `/zones/{zone_id}/purge_cache` | POST | Purge (`{"hosts":[…]}` — all plans) |

All responses: `{"success": bool, "result": …, "errors": [...]}`.
