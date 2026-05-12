# Local Development Setup — Caddy + dnsmasq + *.test

**TL;DR:**
```bash
make setup  # One-time (prompts for sudo on dnsmasq + Caddy services)
```

After setup, you can access all services via HTTPS with zero sudo:
- `https://sideclaw.test` → localhost:7705
- `https://hyperdx.test` → localhost:7707
- `https://basalt.test` → localhost:7710
- etc.

---

## What's Happening

Three moving parts work together:

| Component | Purpose | Sudo? |
|-|-|-|
| **dnsmasq** | Resolves `*.test` to `127.0.0.1` | One-time install (LaunchDaemon) |
| **Caddy** | Reverse proxy + HTTPS with local CA | One-time install + `caddy trust` |
| **Caddyfile** | Config (version-controlled here) | Never — edit + `caddy reload` |

---

## First-Time Setup

Run this once:

```bash
cd ~/SourceRoot/dotfiles
make setup
```

During setup, you'll be prompted for your password **twice**:
1. `sudo caddy trust` — installs Caddy's local CA to macOS Keychain (Touch ID works)
2. `sudo brew services restart caddy` — starts Caddy as a privileged service
3. `sudo mkdir /etc/resolver` — creates directory for macOS DNS configuration
4. `sudo brew services restart dnsmasq` — starts dnsmasq as a privileged service

After setup:

✅ All `*.test` domains resolve to `127.0.0.1`
✅ All services accessible via HTTPS (certificates auto-generated)
✅ HTTP automatically redirects to HTTPS
✅ No more `http://` prefixes needed in bookmarks

---

## Day-to-Day Usage

### Adding a new local service

1. Start your service on a port (e.g., `localhost:8000`)
2. Add one line to `config/Caddyfile`:
   ```caddyfile
   myapp.test { import local; reverse_proxy localhost:8000 }
   ```
3. Reload:
   ```bash
   caddy reload
   ```
4. Visit `https://myapp.test` — done!

### Editing the config

Always edit `config/Caddyfile` here in the repo:

```bash
vim ~/SourceRoot/dotfiles/config/Caddyfile
caddy reload
```

The symlink ensures `$(brew --prefix)/etc/caddy/Caddyfile` stays in sync.

### Reloading after changes

```bash
caddy reload
```

No sudo, no downtime. Caddy validates the config before applying.

---

## Testing It Works

```bash
# Check dnsmasq resolves *.test
nslookup sideclaw.test
# Expected: Address: 127.0.0.1

# Check Caddy is running
brew services list | grep caddy
# Expected: caddy ... started

# Test HTTPS with curl (will show Caddy local CA cert)
curl -v https://sideclaw.test
# Expected: HTTP/2 200 (or proxy error if the actual service isn't running)
```

---

## Troubleshooting

### `caddy reload` fails
```bash
caddy validate --config /opt/homebrew/etc/caddy/Caddyfile
```
Check the error message and fix the Caddyfile syntax.

### DNS not resolving (e.g., `nslookup sideclaw.test` returns nothing)
```bash
# Verify dnsmasq is running
pgrep dnsmasq
# Should print a PID

# Verify /etc/resolver/test exists
cat /etc/resolver/test
# Should print: nameserver 127.0.0.1

# Restart dnsmasq if it's not running
sudo brew services restart dnsmasq
```

### Certificate errors in browser
1. Verify Caddy CA is trusted:
   ```bash
   security find-certificate -c "Caddy Local Authority" /Library/Keychains/System.keychain
   ```
   If missing, run: `sudo caddy trust`

2. Restart browser to reload certificate cache (or open in private mode).

### Caddy service not running
```bash
sudo brew services restart caddy
```

### Debugging a specific service
```bash
# Check what Caddy is trying to do
caddy validate --config /opt/homebrew/etc/caddy/Caddyfile

# View Caddy logs (if launched manually, not as service)
caddy run --config /opt/homebrew/etc/caddy/Caddyfile
```

---

## On Sleep/Wake

`sleepwatcher` + `wakeup.sh` runs `caddy reload` when your Mac wakes from sleep.
This ensures Caddy picks up any port changes while sleeping.

No action needed — it's automatic.

---

## Why *.test?

- `.local` is mDNS (Bonjour) — macOS doesn't consult `/etc/hosts` or dnsmasq for HTTPS connections to `.local`
- `.dev` is a real TLD with HSTS preloading — browsers force HTTPS, breaking some local dev workflows
- `.test` is RFC 2606 reserved for testing — never in public DNS, no browser overrides

---

## Further Reading

- [Caddy docs](https://caddyserver.com/docs)
- [Caddy tls internal](https://caddyserver.com/docs/caddyfile/options#tls)
- [dnsmasq docs](http://www.thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [RFC 2606 — Reserved Domains](https://tools.ietf.org/html/rfc2606)
