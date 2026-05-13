---
name: secrets
description: 1Password secrets management — vault structure, op:// references, .env.tpl patterns, adding/rotating secrets, cron setup, troubleshooting
---

# Secrets Management — 1Password

## Account Selection

Two 1Password accounts are configured:

| Workspace | Account |
|-|-|
| `~/SourceRoot/` (personal) | `tkrumm` |
| `~/IuRoot/` (work) | `careerpartner` |

**Preferred:** use the workspace-aware helpers from `~/.zsh/conf.d/secrets.zsh` (sourced by `~/.zshrc`). They resolve the account from `$PWD` and are worktree-safe via `git rev-parse --git-common-dir`:

```bash
op_account_for_cwd                # → "tkrumm" or "careerpartner"
op_run vault list                 # → op vault list --account <resolved>
op_run read "op://vault/item/field"
op_run run --env-file=.env.tpl -- bun test
```

If invoking `op` directly, always pass `--account` explicitly — without it, `op` may pick the wrong account or prompt interactively.

## Discovery First

Before answering questions about vault contents, **always query the live state** — don't rely on memorized vault structures:

```bash
# List vaults accessible to current session
op_run vault list

# List items in a vault
op_run item list --vault <vault>

# Show item fields
op_run item get <item> --vault <vault> --format=json | jq '.fields[] | select(.value != "") | .label'
```

Vault contents change over time. The patterns below are stable; the specific items are not.

## Core Pattern

```
.env.tpl (git-tracked)  →  op run --env-file=.env.tpl -- <command>
                                    ↓
                            1Password resolves op:// refs at runtime
                                    ↓
                            env vars injected into <command>
```

- `.env.tpl` committed to git — contains only `op://` references and plain config values, never actual secrets
- One `.env.tpl` per project root
- `homelab-private` shares `homelab/.env.tpl` via absolute path: `op run --env-file=$(HOME)/homelab/.env.tpl --`

## .env.tpl Syntax

```env
# Secrets — resolved by op run from 1Password
SECRET_VAR=op://vault/item/field

# Plain config — passed through as-is
CONFIG_VAR=some-value

# Comments start with #, empty lines are skipped
# Single/double quotes are stripped from values
# URLs with & must be stored in 1Password (not inline) to avoid shell expansion issues
```

## Reference Format

`op://vault/item/field` where:
- **vault**: lowercase name (`homelab`, `vps`, `common`)
- **item**: service name (`postgres`, `cloudflare`, `ntfy`)
- **field**: short descriptive name (`PASSWORD`, `TOKEN`, `API_KEY`)

## Reading a Single Secret

```bash
op_run read "op://vault/item/field"
```

## Vault Design Principles

- **Per-server vaults** hold server-specific secrets (DB passwords, tunnel tokens, service accounts)
- **Common vault** holds cross-server secrets (shared API tokens, notification credentials, backup keys)
- **Config items** (named `config`) in per-server vaults hold non-secret but sensitive values (Tailscale IPs, internal URLs, push URLs with tokens in the path)
- **Service account items** (named `service-account`) hold the `OP_SERVICE_ACCOUNT_TOKEN` for each server
- Field names are short (`PASSWORD`, `TOKEN`) — the item name provides context
- Only actual secrets go in vaults. Truly public config (emails, feature flags) can be plain values in `.env.tpl`

## Service Accounts

Each server has a dedicated service account with least-privilege vault access:
- SA tokens stored in `<vault>/service-account/TOKEN`
- On servers: `OP_SERVICE_ACCOUNT_TOKEN` in `~/.bashrc` and `~/.profile`
- `op vault list` shows which vaults a SA can access — use this to verify

## Adding a New Secret

1. Determine the correct vault (server-specific or common?)
2. Create or edit the item:
   ```bash
   # New item
   op item create --vault <vault> --category "API Credential" --title "<service>" \
     'FIELD_NAME[password]=<value>'

   # Add field to existing item
   op item edit <item> --vault <vault> 'NEW_FIELD[password]=<value>'
   ```
3. Clean template junk fields (API Credential category adds useless defaults):
   ```bash
   op item edit <item> --vault <vault> \
     'username[delete]' 'credential[delete]' 'type[delete]' \
     'filename[delete]' 'valid from[delete]' 'expires[delete]' \
     'hostname[delete]'
   ```
4. Add reference to `.env.tpl`:
   ```env
   ENV_VAR_NAME=op://vault/item/FIELD_NAME
   ```
5. Commit `.env.tpl` change
6. On server: `git pull` — the next `op run` picks it up automatically

## Rotating a Secret

1. Update the value in 1Password:
   ```bash
   op item edit <item> --vault <vault> 'FIELD[password]=<new-value>'
   ```
2. No file changes needed — `.env.tpl` references are stable
3. On server: next `op run` invocation picks up the new value automatically
4. For running containers: restart the service (`docker compose restart <svc>` via `op run`)

## Cron Jobs and Background Scripts

Cron does NOT source `.bashrc` or `.profile`. Two patterns:

**Pattern A — source profile in cron entry** (preferred for user crontabs):
```cron
*/2 * * * * . /home/jkrumm/.profile; op run --env-file=/path/.env.tpl -- /path/script.sh
```

**Pattern B — inline token in /etc/cron.d/** (for system cron files):
```cron
OP_SERVICE_ACCOUNT_TOKEN=<token>
0 3 * * * jkrumm cd /path && op run --env-file=.env.tpl -- ./script.sh
```
Note: crontab may strip env var lines on some systems. Use `/etc/cron.d/` files or the `. .profile;` pattern instead.

**Pattern C — op read in scripts** (for scripts that need specific secrets, not full env):
```bash
TOKEN=$(op read "op://vault/item/field")
```
The script's calling environment must have `OP_SERVICE_ACCOUNT_TOKEN` set.

## Remote Server Operations (SSH + OP_SERVICE_ACCOUNT_TOKEN)

Non-interactive SSH (`ssh server "command"`) needs `OP_SERVICE_ACCOUNT_TOKEN` available. The token must be at the **top of `~/.bashrc`**, before the interactive guard:

```bash
# MUST be ABOVE the "If not running interactively" guard in ~/.bashrc
export OP_SERVICE_ACCOUNT_TOKEN="<token>"

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac
```

**Why:** Ubuntu's default `.bashrc` exits early for non-interactive shells. Anything below the guard is invisible to `ssh server "command"`. Additionally, homelab uses **Tailscale SSH** (not OpenSSH), which does NOT support `~/.ssh/environment` or `PermitUserEnvironment`.

With the token at the top of `.bashrc`, SSH commands work directly:
```bash
ssh server "cd ~/repo && make up"
```

For sudo operations (homelab requires password):
```bash
# Root passwords are in Private vault (not accessible to server SAs — local only)
ROOT_PW=$(op read "op://Private/homelab-server/password")
ssh homelab "echo '$ROOT_PW' | sudo -S <command>"
```

## Cloudflare Integration

Cloudflare tokens are split by purpose:
- **DNS API token** — in `common` vault, used by Caddy (homelab) and Traefik (VPS) for ACME DNS-01 challenges
- **Manage API token** — in `common` vault, used for Cloudflare API operations (DNS records, tunnel config)
- **Tunnel tokens** — in per-server vaults, one per tunnel (server-specific)

Query zones and tunnel IDs dynamically via the manage token — don't store zone/tunnel IDs.

## Troubleshooting

| Symptom | Cause | Fix |
|-|-|-|
| `No accounts configured` | `OP_SERVICE_ACCOUNT_TOKEN` not in environment | Export it or source `.profile` |
| Token empty in `ssh server "cmd"` | Token export below `.bashrc` interactive guard | Move export to top of `.bashrc`, before `case $-` |
| `~/.ssh/environment` not working | Tailscale SSH ignores `PermitUserEnvironment` | Use `.bashrc` top-of-file approach instead |
| `could not resolve secret reference` | Wrong vault/item/field name in `.env.tpl` | Check with `op item get <item> --vault <vault>` |
| `authorization timeout` | Biometric prompt not answered (local op) | Retry — Touch ID prompt may be behind windows |
| Caddy rejects `cfut_` token | Old caddy-dns/cloudflare plugin | Rebuild caddy: `docker compose build caddy` |
| Cron job not firing | Missing `OP_SERVICE_ACCOUNT_TOKEN` in cron env | Use `. .profile;` prefix or inline token |
| `More than one vault matches` | Vault name ambiguity (e.g. `shared` vs `Shared`) | Use vault ID instead of name |
| Docker compose "variable not set" warnings on `down` | Normal — `docker compose down` doesn't need env vars | Harmless, can ignore |

## Security Rules

- **NEVER** create `.env` files with actual secret values
- **NEVER** commit actual secret values to any git-tracked file
- **NEVER** log or echo secret values in scripts
- All secrets flow through `.env.tpl` → `op run` at runtime
- Server auth: `OP_SERVICE_ACCOUNT_TOKEN` is the only secret on disk
- Tailscale IPs and internal URLs go in 1Password config items, not plain in `.env.tpl`
- Root passwords in `Private` vault (local-only, not accessible to server SAs) — use `sudo -S` pattern, never SSH as root
