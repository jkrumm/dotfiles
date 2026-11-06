#!/usr/bin/env bash
# secrets-rotate.test — hermetic regression suite for scripts/secrets-rotate.sh.
#
# The script's value is its failure ORDERING: what is rolled back, what is kept,
# and which recovery message it prints at each step. It runs from a SANDBOX COPY
# (lib/op-signed-in.sh stubbed) against a scratch HOME, a real scratch git repo
# standing in for dotfiles-private, and stub age-keygen / sops / op / secrets-seed.
# The stub "keys" are plain words (key file "oldkey" -> recipient age1oldkey), so
# every assertion is about which file holds which key. No real key, Keychain,
# 1Password or network is touched.
#
# Asserted per outcome: exit code, the die_* message, which key is live on disk,
# whether the old-key backup survives, whether .sops.yaml was changed/committed,
# and (success) that the private key reaches op via stdin and never argv.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/secrets-rotate.sh"
[ -f "$SRC" ] || { echo "✗ $SRC not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git required"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/secrets-rotate-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — missing '$3' in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — unexpected '$3' in: $2"; fi
}

ST="$TMP/st"; BIN="$TMP/bin"; SB="$TMP/sandbox"
export ST
mkdir -p "$BIN" "$SB/scripts/lib"
ln -s "$(command -v jq)" "$BIN/jq"
GITBIN=$(command -v git); ln -s "$GITBIN" "$BIN/git"
cp "$SRC" "$SB/scripts/secrets-rotate.sh"

cat > "$SB/scripts/lib/op-signed-in.sh" <<'EOF'
#!/bin/sh
[ -f "$ST/op_signed_out" ] && exit 1
exit 0
EOF
# age-keygen: `-o FILE` writes the next fresh key ("newkey"); `-y FILE` prints age1<word>.
cat > "$BIN/age-keygen" <<'EOF'
#!/bin/sh
if [ "$1" = "-o" ]; then
  [ -f "$ST/keygen_same" ] && cat "$ST/keygen_same" > "$2" || echo newkey > "$2"
  exit 0
fi
[ "$1" = "-y" ] || exit 2
echo "age1$(tr -dc 'a-z0-9' < "$2")"
EOF
cat > "$BIN/sops" <<'EOF'
#!/bin/sh
echo "sops $*" >> "$ST/sops.log"
[ -f "$ST/sops_fail" ] && exit 1
exit 0
EOF
# op: record argv (never stdin) separately from stdin.
cat > "$BIN/op" <<'EOF'
#!/bin/sh
echo "op $*" >> "$ST/op.argv.log"
case "$1 $2" in
  "item delete") exit 0 ;;
  "item create") cat > "$ST/op.stdin"; [ -f "$ST/op_create_fail" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
mkdir -p "$TMP/dotfiles/scripts"
cat > "$TMP/dotfiles/scripts/secrets-seed.sh" <<'EOF'
#!/bin/sh
echo "seed repo=$SECRETS_PRIVATE_REPO" >> "$ST/seed.log"
[ -f "$ST/seed_fail" ] && exit 1
exit 0
EOF
chmod +x "$BIN"/* "$SB/scripts/lib/op-signed-in.sh" "$TMP/dotfiles/scripts/secrets-seed.sh"

# /opt/homebrew/bin last: the script prepends it only when absent, and a real
# homebrew dir first would shadow the stubs above.
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export HOME="$TMP/home"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export DOTFILES_DIR="$TMP/dotfiles"
REPO="$TMP/private"; export SECRETS_PRIVATE_REPO="$REPO"
KEY="$HOME/.config/sops/age/keys.txt"

# reset: a mini on the cache backend with key "oldkey", .sops.yaml pinned to it,
# a committed repo, signed in to 1Password, every step succeeding.
reset() {
  rm -rf "$ST" "$HOME" "$REPO"
  mkdir -p "$ST" "$HOME/.config/secrets" "$HOME/.config/sops/age" "$REPO/cache"
  echo cache > "$HOME/.config/secrets/backend"
  echo oldkey > "$KEY"
  printf 'creation_rules:\n  - age: age1oldkey\n' > "$REPO/.sops.yaml"
  echo '{}' > "$REPO/cache/secrets.enc.json"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
}
OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SB/scripts/secrets-rotate.sh" 2>&1) || RC=$?; }
count_files() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
backups()   { count_files "$HOME"/.config/sops/age/keys.txt.rotated-*; }
backup_content() { cat "$HOME/.config/sops/age"/keys.txt.rotated-* 2>/dev/null; }
sops_recipient() { grep -Eo 'age1[0-9a-z]+' "$REPO/.sops.yaml"; }
commits()   { git -C "$REPO" rev-list --count HEAD; }
dirty()     { git -C "$REPO" status --porcelain .sops.yaml; }
leftover_tmp() { count_files "$HOME"/.config/sops/age/keys.txt.new.* "$REPO"/.sops.??????; }

echo "success"
reset; run
assert_eq "exit 0" "$RC" 0
assert_contains "announces completion" "$OUT" "age key rotated + cache re-sealed"
assert_eq "new private key is live" "$(cat "$KEY")" newkey
assert_eq ".sops.yaml points at the new recipient" "$(sops_recipient)" age1newkey
assert_eq "recipient change is committed" "$(commits)" 2
assert_contains "commit message" "$(git -C "$REPO" log -1 --format=%s)" "chore(secrets): rotate mini age recipient"
assert_eq "worktree is clean after commit" "$(dirty)" ""
assert_eq "old-key backup dropped only after the commit" "$(backups)" 0
assert_eq "seeded against the private repo" "$(cat "$ST/seed.log")" "seed repo=$REPO"
assert_contains "decrypt check used the live key file" "$(cat "$ST/sops.log")" "--decrypt"
assert_eq "no temp key / temp sops files left behind" "$(leftover_tmp)" 0
assert_eq "new private key reached op via stdin" "$(jq -r '.fields[0].value' "$ST/op.stdin" | tr -d '\n')" newkey
assert_eq "1Password item carries the public key" "$(jq -r '.fields[1].value' "$ST/op.stdin")" age1newkey
assert_not_contains "private key never on op's argv" "$(cat "$ST/op.argv.log")" newkey
assert_not_contains "private key never echoed (public recipient may be)" "${OUT//age1newkey/}" "newkey"
assert_eq "key file stays owner-only" "$(/usr/bin/stat -f %Lp "$KEY")" 600
assert_contains "old item is deleted before recreate" "$(sed -n 1p "$ST/op.argv.log")" "item delete mini age key"

echo "preflight: nothing is mutated"
check_untouched() {  # $1 label
  assert_eq "$1: old key still live" "$(cat "$KEY")" oldkey
  assert_eq "$1: .sops.yaml unchanged" "$(dirty)" ""
  assert_eq "$1: no backup created" "$(backups)" 0
  assert_eq "$1: no 1Password write" "$([ -e "$ST/op.argv.log" ] && echo yes || echo no)" no
  assert_eq "$1: no reseed" "$([ -e "$ST/seed.log" ] && echo yes || echo no)" no
}
reset; echo op > "$HOME/.config/secrets/backend"; run
assert_eq "wrong backend exits 1" "$RC" 1
assert_contains "wrong backend says mini only" "$OUT" "not the cache backend — secrets-rotate runs on the mini only"
check_untouched "wrong backend"
reset; rm "$HOME/.config/secrets/backend"; run
assert_contains "no backend marker is refused" "$OUT" "not the cache backend"
reset; touch "$ST/op_signed_out"; run
assert_eq "1Password not signed in exits 1" "$RC" 1
assert_contains "refuses instead of hanging on a prompt" "$OUT" "1Password is not signed in on this host"
check_untouched "not signed in"
reset; printf 'creation_rules:\n  - age: age1someoneelse\n' > "$REPO/.sops.yaml"; git -C "$REPO" commit -q -am other; run
assert_eq "recipient mismatch exits 1" "$RC" 1
assert_contains "mismatch names both keys" "$OUT" ".sops.yaml recipient (age1someoneelse) != current key (age1oldkey)"
check_untouched "recipient mismatch"
reset; rm "$KEY"; run
assert_contains "missing age key is refused" "$OUT" "age key missing at"
reset; rm "$REPO/cache/secrets.enc.json"; run
assert_contains "missing cache points at secrets-seed" "$OUT" "run 'make secrets-seed' first"
reset; touch "$ST/keygen_same"; echo oldkey > "$ST/keygen_same"; run
assert_eq "a new key equal to the old one aborts" "$RC" 1
assert_contains "equal-key message" "$OUT" "new key equals old key — aborting"
assert_eq "equal-key: live key untouched" "$(cat "$KEY")" oldkey
assert_eq "equal-key: temp key removed" "$(leftover_tmp)" 0

echo "die_post_swap: 1Password recreate fails (new key live, old key backed up)"
check_swapped() {  # $1 label
  assert_eq "$1: exit 1" "$RC" 1
  assert_eq "$1: NEW key is live on disk" "$(cat "$KEY")" newkey
  assert_eq "$1: OLD key backed up" "$(backup_content)" oldkey
  assert_eq "$1: .sops.yaml already points at the new recipient (uncommitted)" "$(sops_recipient)" age1newkey
  assert_eq "$1: nothing committed" "$(commits)" 1
  assert_contains "$1: says on-disk key is the NEW one" "$OUT" "On-disk key is the NEW one; the OLD key is backed up at:"
  assert_contains "$1: offers recover-forward" "$OUT" "RECOVER FORWARD:"
  assert_contains "$1: offers roll-back (restore key + checkout .sops.yaml)" "$OUT" "ROLL BACK:"
  assert_contains "$1: warns the cache is sealed to the old recipient" "$OUT" "cache is still sealed to the OLD recipient"
}
reset; touch "$ST/op_create_fail"; run
check_swapped "op create fails"
assert_contains "op create fails: names the item" "$OUT" "1Password item recreate failed (item 'mini age key' in Private)"
assert_eq "op create fails: reseed never attempted" "$([ -e "$ST/seed.log" ] && echo yes || echo no)" no

echo "die_post_swap: reseed fails"
reset; touch "$ST/seed_fail"; run
check_swapped "reseed fails"
assert_contains "reseed fails: reason" "$OUT" "reseed failed"
assert_eq "reseed fails: 1Password backup was already refreshed" "$([ -s "$ST/op.stdin" ] && echo yes)" yes
assert_eq "reseed fails: decrypt check never ran" "$([ -e "$ST/sops.log" ] && echo yes || echo no)" no

echo "die_verify_failed: reseed ran but the new cache does not open"
reset; touch "$ST/sops_fail"; run
assert_eq "verify fails: exit 1" "$RC" 1
assert_contains "verify fails: state is UNVERIFIED" "$OUT" "State is UNVERIFIED"
assert_contains "verify fails: tells you not to commit" "$OUT" "Do NOT commit .sops.yaml"
assert_contains "verify fails: offers retry and roll back" "$OUT" "RETRY the reseed"
assert_eq "verify fails: new key live" "$(cat "$KEY")" newkey
assert_eq "verify fails: old key still backed up" "$(backup_content)" oldkey
assert_eq "verify fails: nothing committed" "$(commits)" 1
assert_eq "verify fails: reseed did run" "$(cat "$ST/seed.log")" "seed repo=$REPO"
assert_not_contains "verify fails: not mistaken for a post-swap failure" "$OUT" "RECOVER FORWARD"

echo "die_post_reseed: only the commit fails — finish forward, keep the backup"
reset
mkdir -p "$REPO/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$REPO/.git/hooks/pre-commit"; chmod +x "$REPO/.git/hooks/pre-commit"
run
assert_eq "commit fails: exit 1" "$RC" 1
assert_contains "commit fails: reseed and verify are reported as good" "$OUT" "Reseed + decrypt-check SUCCEEDED"
assert_contains "commit fails: names the forward fix" "$OUT" "commit -m 'chore(secrets): rotate mini age recipient'"
assert_contains "commit fails: the reason" "$OUT" "git commit of .sops.yaml failed"
assert_not_contains "commit fails: no rollback offered" "$OUT" "ROLL BACK"
assert_eq "commit fails: new key live" "$(cat "$KEY")" newkey
assert_eq "commit fails: old-key backup KEPT" "$(backup_content)" oldkey
assert_eq "commit fails: .sops.yaml has the new recipient, staged but uncommitted" "$(sops_recipient):$(dirty | cut -c1-2)" "age1newkey:M "
assert_eq "commit fails: seeded exactly once" "$(wc -l < "$ST/seed.log" | tr -d ' ')" 1

echo
if [ "$fails" -eq 0 ]; then echo "secrets-rotate: all passed"; else echo "secrets-rotate: $fails failed"; exit 1; fi
