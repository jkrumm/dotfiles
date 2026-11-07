#!/bin/bash
# authorized-keys-sync.sh <target authorized_keys> <source file>...
# authorized-keys-sync.sh --rollback <target authorized_keys>
# authorized-keys-sync.sh --rollback-to <backup file> <target authorized_keys>
#
# Installs the key lines of each source file into the target, keyed on the key
# blob (the base64 token after the key type), not on the whole line: every
# target line carrying the same blob — whatever its options or comment — is
# replaced by the source line. A key whose options change (for example a bare
# key becoming a forced-command key) therefore never leaves the old line
# behind. Unrelated target lines and comments are kept untouched.
#
# Safety: the new file is built beside the target, every key in it must parse
# (`ssh-keygen -l -f`) before it is moved into place atomically, and the
# previous file is kept as <target>.bak-<timestamp> (newest 5 kept). Any
# failure leaves the target untouched (exit 1). A run that changes nothing
# makes no backup. --rollback restores the newest backup, --rollback-to exactly
# the named one; both keep the replaced file as <target>.pre-rollback.
#
# AUTHORIZED_KEYS_SYNC_RESULT=<file> records what THIS run did, for a caller
# that must undo exactly it: `unchanged`, `backup <path>` (the backup made by
# this run) or `created` (the target did not exist before).
set -u
LC_COLLATE=C # glob order of the timestamped backups must be byte order
export LC_COLLATE

KEY_LINE_RE='^(ssh-|ecdsa-|sk-|restrict|command=|no-|from=|cert-authority|port-forwarding|permit|environment|expiry|principals|tunnel)'
KEEP_BACKUPS=5

die() { printf 'authorized-keys-sync: %s\n' "$*" >&2; exit 1; }

newest_backup() { # <target> — path of the newest backup, empty when none
  local f newest=""
  for f in "$1".bak-*; do
    [ -f "$f" ] && newest="$f"
  done
  printf '%s' "$newest"
}

restore() { # <backup> <target> — replaces target with backup, keeps the replaced file
  local backup="$1" target="$2" tmp
  umask 077
  [ -f "$target" ] && cp -p "$target" "$target.pre-rollback"
  tmp="$(mktemp "$target.XXXXXX")" || die "cannot create temp file next to $target"
  cp "$backup" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$target" || { rm -f "$tmp"; die "rollback failed"; }
  echo "authorized-keys-sync: restored $backup"
  exit 0
}

record() { # <result> — what this run did, when the caller asked
  [ -n "${AUTHORIZED_KEYS_SYNC_RESULT:-}" ] && printf '%s\n' "$1" >"$AUTHORIZED_KEYS_SYNC_RESULT"
  return 0
}

if [ "${1:-}" = "--rollback" ]; then
  target="${2:-}"
  [ -n "$target" ] || die "usage: --rollback <target>"
  backup="$(newest_backup "$target")"
  [ -n "$backup" ] || die "no backup for $target"
  restore "$backup" "$target"
fi

if [ "${1:-}" = "--rollback-to" ]; then
  backup="${2:-}"
  target="${3:-}"
  [ -n "$backup" ] && [ -n "$target" ] || die "usage: --rollback-to <backup> <target>"
  [ -f "$backup" ] || die "no such backup: $backup"
  restore "$backup" "$target"
fi

target="${1:-}"
[ -n "$target" ] && [ "$#" -ge 2 ] || die "usage: $0 <target> <source>... | --rollback <target> | --rollback-to <backup> <target>"
shift
for src in "$@"; do [ -r "$src" ] || die "cannot read source $src"; done

umask 077
mkdir -p "$(dirname "$target")" || die "cannot create $(dirname "$target")"
tmp="$(mktemp "$target.XXXXXX")" || die "cannot create temp file next to $target"
work="$(mktemp "$target.XXXXXX")" || { rm -f "$tmp"; die "cannot create temp file next to $target"; }
trap 'rm -f "$tmp" "$work"' EXIT

if [ -f "$target" ]; then cp "$target" "$tmp"; else : >"$tmp"; fi

# the blob of a key line: the field after the first key-type field
blob_of() {
  awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }' <<<"$1"
}

while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ $KEY_LINE_RE ]] || continue
  blob="$(blob_of "$line")"
  [ -n "$blob" ] || die "no key blob in a source line: ${line:0:40}"
  awk -v b="$blob" '/^#/ { print; next } index($0, b) == 0 { print }' "$tmp" >"$work" || die "filter failed"
  printf '%s\n' "$line" >>"$work"
  cp "$work" "$tmp"
done < <(cat "$@")

# validation: every non-comment line must be one parsable key
want="$(grep -cvE '^[[:space:]]*(#|$)' "$tmp")"
got="$(ssh-keygen -l -f "$tmp" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$want" != "$got" ] || ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
  die "validation failed ($got of $want key lines parse); $target left untouched"
fi

if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
  chmod 600 "$target"
  record unchanged
  echo "authorized-keys-sync: $target unchanged ($got key(s))"
  exit 0
fi

if [ -f "$target" ]; then
  # sorts after every existing backup, even when pruning freed a same-second name
  stamp="$(date +%Y%m%d%H%M%S)"
  newest="$(newest_backup "$target")"
  n=0
  bak="$target.bak-$stamp-$(printf '%03d' "$n")"
  while [ -e "$bak" ] || { [ -n "$newest" ] && [[ ! "$bak" > "$newest" ]]; }; do
    n=$((n + 1))
    bak="$target.bak-$stamp-$(printf '%03d' "$n")"
  done
  cp -p "$target" "$bak" && chmod 600 "$bak" || die "backup failed; $target left untouched"
  result="backup $bak"
else
  result="created"
fi
chmod 600 "$tmp"
mv "$tmp" "$target" || die "install failed"
record "$result"

# keep the newest backups only
count=0
for f in "$target".bak-*; do [ -f "$f" ] && count=$((count + 1)); done
for f in "$target".bak-*; do
  [ "$count" -gt "$KEEP_BACKUPS" ] || break
  [ -f "$f" ] || continue
  rm -f "$f"
  count=$((count - 1))
done
echo "authorized-keys-sync: $target updated ($got key(s))"
