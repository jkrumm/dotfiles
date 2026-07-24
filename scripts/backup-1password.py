#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# ///
"""
1Password full vault backup — age-encrypted JSON to HomeLab.

Run manually: opbackup (alias)
Frequency: weekly (Uptime Kuma push monitor reminds if overdue at 8 days)

Vaults backed up: every vault `op vault list` returns, minus SKIP_VAULTS (Shared) —
                  a new vault is picked up with no code change
Archived items:   excluded automatically (op item list omits them by default)

How it works:
  1. First op call triggers Touch ID (session lasts ~10min)
  2. Lists all active items per vault — archived items are absent from this list
  3. Fetches full item details in parallel (WORKERS=8) — ~90s for ~370 items
  4. Serialises to JSON in memory — unencrypted data never written to disk
  5. Encrypts with age public key (private key in 1Password + paper backup)
  6. Rsyncs encrypted .json.age to homelab — temp file deleted in finally block
  7. Pushes heartbeat to Uptime Kuma (8-day window monitor alerts if overdue)

Security properties (validated 2026-04-02):
  - Unencrypted JSON lives only in memory (json_bytes); passed via stdin to age
  - Temp file holds only age-encrypted output (0o600 permissions, /tmp)
  - finally block deletes temp file on success, exception, and KeyboardInterrupt
  - SIGKILL is the only case where temp file might persist — it contains only
    encrypted data, so exposure risk is nil
  - Secrets (passwords, tokens) are captured from op stdout, never passed as
    subprocess argv — not visible in `ps`
  - Minor: Uptime Kuma push URL is passed as curl argv (visible in ps briefly);
    acceptable since it is a low-privilege heartbeat token, not account credentials
  - Item fetch failures propagate immediately and abort the backup (no silent
    partial exports)

Recovery (MUST run locally — age is not installed on homelab):
  # 1. Fetch file from homelab:
  rsync -az homelab:~/backups/1password/<file>.json.age .

  # 2a. Decrypt via op CLI (use item ID — avoids name-ambiguity if duplicates exist):
  op read "op://Private/362mxq2lw7s7jvly2lk6ozrb5e/PRIVATE_KEY" \\
    | age -d -i - -o backup.json <file>.json.age

  # 2b. Decrypt via paper key (same result — both methods verified identical output):
  echo "AGE-SECRET-KEY-..." | age -d -i - -o backup.json <file>.json.age

  # 3. Browse:
  cat backup.json | python3 -m json.tool | less

Pre-requisites:
  - 1Password desktop app installed + CLI enabled
  - age: brew install age
  - age keypair: private in op://Private/backup-age-key/PRIVATE_KEY (item 362mxq2l) + paper
  - Uptime Kuma push URL in op://homelab/config/1PASSWORD_BACKUP_PUSH_URL
  - Remote dir: ssh homelab "mkdir -p ~/backups/1password"

Known duplicates / gotchas:
  - backup-age-key had a duplicate item (archived 2026-04-02); always use item ID
    362mxq2lw7s7jvly2lk6ozrb5e in recovery to avoid ambiguity
  - age is not installed on homelab — do not attempt server-side decryption
"""

import json, subprocess, sys, os, tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date

RECIPIENT = "age1eg6cypgrjv48urgvmxe9wua9d8a7x9e6jxt6w2phcfg46gxzpqdq9f3jke"  # public key — not a secret
OP_ACCOUNT = ["--account", "tkrumm"]

# Archived items are excluded automatically (op item list omits them without --include-archive).
# To exclude a vault entirely, add its name here.
SKIP_VAULTS: set[str] = {"Shared"}

# Max parallel op item get calls — 1Password desktop app handles concurrency well
WORKERS = 8

def op_json(cmd: list[str]) -> ...:
    return json.loads(subprocess.check_output(["op"] + cmd + OP_ACCOUNT))

def fetch_item(item_id: str, vault_id: str) -> dict:
    return op_json(["item", "get", item_id, "--vault", vault_id, "--format", "json"])

def main():
    # Auth check — triggers biometric if 1Password desktop is unlocked
    try:
        subprocess.check_output(["op", "vault", "list"] + OP_ACCOUNT + ["--format", "json"], stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        print("1Password not unlocked — open the app and retry")
        sys.exit(1)

    # Export all vaults
    vaults = op_json(["vault", "list", "--format", "json"])
    backup = {}
    total = 0
    for vault in vaults:
        vid, vname = vault["id"], vault["name"]
        if vname in SKIP_VAULTS:
            print(f"  {vname}: skipped")
            continue
        items = op_json(["item", "list", "--vault", vid, "--format", "json"])
        if not items:
            backup[vname] = []
            print(f"  {vname}: 0 items")
            continue

        # Fetch all item details in parallel — archived items are absent from the list above
        vault_items: list[dict] = [None] * len(items)
        with ThreadPoolExecutor(max_workers=WORKERS) as executor:
            future_to_idx = {
                executor.submit(fetch_item, item["id"], vid): i
                for i, item in enumerate(items)
            }
            for future in as_completed(future_to_idx):
                vault_items[future_to_idx[future]] = future.result()

        backup[vname] = vault_items
        total += len(vault_items)
        print(f"  {vname}: {len(vault_items)} items")

    # Encrypt → temp file (JSON never on disk unencrypted)
    json_bytes = json.dumps(backup, indent=2, ensure_ascii=False).encode()
    filename = f"1password-{date.today().isoformat()}.json.age"

    fd, tmp_path = tempfile.mkstemp(suffix=".age")
    os.close(fd)
    try:
        subprocess.run(
            ["age", "--encrypt", "--recipient", RECIPIENT, "-o", tmp_path],
            input=json_bytes, check=True
        )
        # rsync to homelab
        subprocess.run(
            ["rsync", "-az", tmp_path, f"homelab:~/backups/1password/{filename}"],
            check=True
        )
        # Push to Uptime Kuma
        push_url = subprocess.check_output(
            ["op", "read", "op://homelab/config/1PASSWORD_BACKUP_PUSH_URL"] + OP_ACCOUNT
        ).decode().strip()
        subprocess.run(["curl", "-fsS", push_url], capture_output=True, check=True)

        size_kb = os.path.getsize(tmp_path) // 1024
        print(f"  Done: {total} items from {len(backup)} vaults ({size_kb} KB) → homelab")
    finally:
        os.unlink(tmp_path)

if __name__ == "__main__":
    main()
