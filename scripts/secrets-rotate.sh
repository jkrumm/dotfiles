#!/usr/bin/env bash
set +x                                   # NEVER xtrace — it would echo the private key
set -euo pipefail
umask 077
ulimit -c 0 2>/dev/null || true          # no core dumps (they capture decrypted key material)

# secrets-rotate — rotate the Mac mini's age key and re-seal the cache under a
# fresh recipient. Use when the current private key may be exposed (e.g. it leaked
# into a log or an agent transcript).
#
# Why key-rotation alone is sufficient here: the encrypted cache
# (cache/secrets.enc.json) is gitignored (no history) and lives ONLY on the mini's
# disk. Reseeding overwrites it (atomic mv) with a version sealed to the NEW
# recipient, so the old key then decrypts nothing that still exists — the sealed
# secrets do NOT need individual rotation.
#
# Never exposes the private key: `set +x` (no xtrace), and the 1Password write
# passes the key via a jq `--rawfile` → `op ... -` STDIN pipe — never on argv (so
# it can't surface in `ps`/`/proc/<pid>/cmdline`), never a temp file, output
# suppressed. Only the PUBLIC key (already in .sops.yaml, non-secret) is echoed.
#
# Runs on the mini (backend=cache), human present for the biometric `op` writes —
# the preflight refuses rather than hangs when nobody is (see the op_signed_in guard).
# See dotfiles-private/docs/runbook.md → "Rotation & recovery".

PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/SourceRoot/dotfiles}"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_YAML="$PRIVATE_REPO/.sops.yaml"
CACHE_FILE="$PRIVATE_REPO/cache/secrets.enc.json"
BACKEND_MARKER="$HOME/.config/secrets/backend"
OP_ACCOUNT="${OP_ACCOUNT:-tkrumm}"
ITEM_TITLE="mac-mini age key"
stamp=""

# Homebrew-first PATH so a headless invocation still finds age-keygen/sops/jq/op
# (mirrors secrets-run's self-sufficiency).
case ":$PATH:" in *":/opt/homebrew/bin:"*) : ;; *) PATH="/opt/homebrew/bin:$PATH" ;; esac
export PATH

# die() — failure before anything on disk is mutated (or only the uncommitted
# .sops.yaml working copy, which `git checkout` restores).
die() { echo "✗ $*" >&2; exit 1; }

# die_post_swap() — failure AFTER the new key is live on disk but BEFORE a
# successful reseed. The cache is still sealed to the OLD recipient (reseed is
# atomic), so 'secrets-run read' is temporarily broken until recovery.
die_post_swap() {
  echo "✗ $*" >&2
  echo "  On-disk key is the NEW one; the OLD key is backed up at:" >&2
  echo "    $AGE_KEY_FILE.rotated-$stamp" >&2
  echo "  The cache is still sealed to the OLD recipient → 'secrets-run read' is temporarily broken. Choose one:" >&2
  echo "    RECOVER FORWARD:  make -C $DOTFILES_DIR secrets-rotate    (re-run — it converges to a clean state)" >&2
  echo "    or ROLL BACK:     mv -f $AGE_KEY_FILE.rotated-$stamp $AGE_KEY_FILE \\" >&2
  echo "                      && git -C $PRIVATE_REPO checkout .sops.yaml     (then reset 1Password Private/'$ITEM_TITLE' to the old key)" >&2
  exit 1
}

# die_verify_failed() — the reseed ran but the new cache did NOT decrypt with the
# new key: state is UNVERIFIED (do not trust it, do not commit). The old key is
# still backed up, so recovery is possible either direction.
die_verify_failed() {
  echo "✗ $*" >&2
  echo "  State is UNVERIFIED — the just-sealed cache did not open with the new key. Do NOT commit .sops.yaml." >&2
  echo "  The OLD key is backed up at: $AGE_KEY_FILE.rotated-$stamp" >&2
  echo "  Investigate, then either RETRY the reseed:  make -C $DOTFILES_DIR secrets-seed" >&2
  echo "  or ROLL BACK to the old key + recipient:    mv -f $AGE_KEY_FILE.rotated-$stamp $AGE_KEY_FILE \\" >&2
  echo "                                              && git -C $PRIVATE_REPO checkout .sops.yaml && make -C $DOTFILES_DIR secrets-seed" >&2
  exit 1
}

# die_post_reseed() — the reseed SUCCEEDED and the new cache VERIFIED (key + cache
# consistent); only the trailing git commit failed. No rollback — finish forward.
die_post_reseed() {
  echo "✗ $*" >&2
  echo "  Reseed + decrypt-check SUCCEEDED — the new key and new cache are consistent. Finish forward:" >&2
  echo "    git -C $PRIVATE_REPO add .sops.yaml && git -C $PRIVATE_REPO commit -m 'chore(secrets): rotate mini age recipient'" >&2
  echo "  Keep the backup $AGE_KEY_FILE.rotated-$stamp until 'secrets-run read op://common/api/SECRET' is confirmed working." >&2
  exit 1
}

# --- preflight ---------------------------------------------------------------
[[ -f "$BACKEND_MARKER" && "$(tr -d '[:space:]' <"$BACKEND_MARKER")" == "cache" ]] \
  || die "not the cache backend — secrets-rotate runs on the mini only"
[[ -f "$AGE_KEY_FILE" ]] || die "age key missing at $AGE_KEY_FILE"
[[ -f "$SOPS_YAML" ]] || die "no .sops.yaml at $SOPS_YAML"
[[ -f "$CACHE_FILE" ]] || die "no cache at $CACHE_FILE — run 'make secrets-seed' first"
for t in age-keygen sops jq op git; do command -v "$t" >/dev/null 2>&1 || die "$t not installed"; done

# Rotation is biometric END TO END and can only run with a HUMAN AT THIS MACHINE:
# step 4 writes the new private key to 1Password, and step 5's secrets-seed.sh does
# its own `op signin` + one `op read` per ref. On a detached mini both hang forever
# on a prompt nobody can answer — `op signin` is not a fix there, it IS the hang.
# So probe non-blockingly (stdin closed, bounded when `timeout` exists) and refuse
# with the right machine named, mirroring scripts/tailscale-acl-sync.sh's guard.
# Deliberately NOT `op whoami`: under desktop-app integration it returns rc=1 on
# an unlocked app, so this preflight refused on the MacBook too — and then told
# you to go to the mini, which is the one machine where rotation genuinely cannot
# run. The shared probe carries the measurement.
op_signed_in() {
  "$(dirname "${BASH_SOURCE[0]}")/lib/op-signed-in.sh" "$OP_ACCOUNT"
}
if ! op_signed_in; then
  die "1Password is not signed in on this host, and rotation cannot proceed without it.
      Rotation is biometric end to end (the 1P key backup in step 4, then every
      'op read' inside secrets-seed.sh) — so it needs a HUMAN AT THIS MACHINE.
      Do NOT 'op signin' from a detached session: with no one to answer the prompt
      it hangs rather than fails. Get an interactive session on the mini first
      (Screen Sharing or an attached keyboard), then re-run:
        make -C $DOTFILES_DIR secrets-rotate
      There is no MacBook-only path today: the age key and the cache both live on
      this machine, and only the seed half can be driven remotely.
      See dotfiles-private/docs/runbook.md → 'Rotation & recovery'."
fi

old_pub="$(age-keygen -y "$AGE_KEY_FILE")" || die "cannot derive current public key"
sops_pub="$(grep -Eo 'age1[0-9a-z]+' "$SOPS_YAML" | sort -u)"
[[ "$sops_pub" == "$old_pub" ]] \
  || die ".sops.yaml recipient ($sops_pub) != current key ($old_pub) — resolve before rotating"

echo "  Rotating the mini age key."
echo "    current recipient: $old_pub"

# --- 1. new keypair into a temp (the live key is untouched until step 3) ------
# `age-keygen -o` REFUSES to overwrite an existing path (so mktemp — which creates
# the file — can't back it); we use a PID-suffixed name and guard that it does not
# pre-exist. Safe: the age dir is 0700 (owner-only), so no other user can plant a
# symlink there — the only writer is the same user, already the accepted-risk model.
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
newkey="$AGE_KEY_FILE.new.$$"
[[ -e "$newkey" ]] && die "temp key path already exists: $newkey"
age-keygen -o "$newkey" >/dev/null 2>&1 || die "age-keygen failed"
chmod 600 "$newkey"
new_pub="$(age-keygen -y "$newkey")" || { rm -f "$newkey"; die "cannot derive new public key"; }
[[ "$new_pub" != "$old_pub" ]] || { rm -f "$newkey"; die "new key equals old key — aborting"; }
echo "    new recipient:     $new_pub"

# --- 2. point .sops.yaml at the new recipient (public-only; committed in step 7) --
# age keys are [0-9a-z] only, so they are sed-metacharacter-free; `|` delimiter is safe.
sops_tmp="$(mktemp "${SOPS_YAML%/*}/.sops.XXXXXX")" || { rm -f "$newkey"; die "mktemp failed"; }
sed "s|$old_pub|$new_pub|g" "$SOPS_YAML" > "$sops_tmp" \
  || { rm -f "$newkey" "$sops_tmp"; die ".sops.yaml rewrite failed"; }
grep -q "$new_pub" "$sops_tmp" \
  || { rm -f "$newkey" "$sops_tmp"; die ".sops.yaml rewrite produced no new recipient"; }
mv "$sops_tmp" "$SOPS_YAML"

# --- 3. swap the private key into place (back up the old one first) -----------
cp -p "$AGE_KEY_FILE" "$AGE_KEY_FILE.rotated-$stamp" \
  || { git -C "$PRIVATE_REPO" checkout .sops.yaml; rm -f "$newkey"; die "could not back up the old key"; }
chmod 600 "$AGE_KEY_FILE.rotated-$stamp"
mv "$newkey" "$AGE_KEY_FILE"   # from here on, the NEW key is live → die_post_swap

# --- 4. refresh the 1Password backup — ARGV-SAFE (key via jq --rawfile → op stdin) --
# `op item edit` only takes field=value on argv (would expose the key in `ps`), so we
# delete + recreate from a STDIN template instead: jq reads the key straight from the
# file via --rawfile (never argv), emits the item JSON, and pipes it to `op item create -`.
# The key touches only the jq→op pipe; notesPlain carries it for recovery, the public-key
# field is what the seed's recipient-pinning reads. Brief window with no 1P backup copy —
# harmless: the key is on disk (new) plus the $stamp backup, so it is never lost.
op item delete "$ITEM_TITLE" --vault Private --account "$OP_ACCOUNT" </dev/null >/dev/null 2>&1 || true
jq -n --rawfile note "$AGE_KEY_FILE" --arg pub "$new_pub" --arg title "$ITEM_TITLE" \
  '{title:$title, category:"SECURE_NOTE", vault:{name:"Private"},
    fields:[{id:"notesPlain",type:"STRING",purpose:"NOTES",label:"notesPlain",value:$note},
            {label:"public key",type:"STRING",value:$pub}]}' \
  | op item create --account "$OP_ACCOUNT" - >/dev/null 2>&1 \
  || die_post_swap "1Password item recreate failed (item '$ITEM_TITLE' in Private)"
echo "    ✓ 1Password backup refreshed (key via stdin — never argv, never echoed)"

# --- 5. reseed: re-encrypt the cache to the new recipient ---------------------
# Recipient-pinning now enforces .sops.yaml (new) == the 1Password public-key field (new).
echo "    reseeding the cache to the new recipient..."
SECRETS_PRIVATE_REPO="$PRIVATE_REPO" "$DOTFILES_DIR/scripts/secrets-seed.sh" \
  || die_post_swap "reseed failed"

# --- 6. verify the new cache decrypts with the new key (in memory, suppressed) --
SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt --input-type json --output-type json \
  "$CACHE_FILE" >/dev/null 2>&1 \
  || die_verify_failed "post-reseed decrypt check FAILED — the new cache did not open with the new key"
echo "    ✓ new cache decrypts with the rotated key"

# --- 7. commit the recipient change + drop the old-key backup -----------------
if ! ( git -C "$PRIVATE_REPO" add .sops.yaml \
       && git -C "$PRIVATE_REPO" commit -q -m "chore(secrets): rotate mini age recipient ($stamp)" ); then
  die_post_reseed "git commit of .sops.yaml failed"
fi
rm -f "$AGE_KEY_FILE.rotated-$stamp"

echo ""
echo "  ✓ age key rotated + cache re-sealed. The previously-exposed key now decrypts nothing."
echo "    the new private key lives ONLY at $AGE_KEY_FILE and 1Password Private/'$ITEM_TITLE'."
echo ""
