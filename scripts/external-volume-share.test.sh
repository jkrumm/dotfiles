#!/usr/bin/env bash
set -u
# Hermetic test for scripts/external-volume-share.sh: stub gate, sharing, dscl and dseditgroup, a temp dir as the
# volume. No real share point, group or disk is touched.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/external-volume-share.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ext-share-test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

ROOT="$T/vol/EXT"
printf '{"name":"EXT"}\n' > "$T/cfg.json"
echo present > "$T/state"; echo '{}' > "$T/shares.json"; printf 'com.apple.sharepoint.group.1\n' > "$T/groups"

cat > "$T/gate" <<STUB
#!/bin/bash
case "\$1" in
  state) cat "$T/state" ;;
  root) [ "\$(cat "$T/state")" = present ] && echo "$ROOT" || exit 1 ;;
esac
STUB
cat > "$T/sharing" <<STUB
#!/bin/bash
echo "\$*" >> "$T/sharing.calls"
case "\$1" in
  -l) cat "$T/shares.json" ;;
  -a) printf '{"EXT":{"path":"%s","smb_name":"EXT"}}\n' "\$2" > "$T/shares.json" ;;
  -r) echo '{}' > "$T/shares.json" ;;
esac
STUB
# dscl models the directory: the group list, a share point's sharepoint_group_id, a group's GeneratedUID.
cat > "$T/dscl" <<STUB
#!/bin/bash
echo "\$*" >> "$T/dscl.calls"
case "\$2" in
  -list) cat "$T/groups" ;;
  -read)
    case "\$3" in
      /SharePoints/EXT) [ -f "$T/gid" ] && echo "sharepoint_group_id: \$(cat "$T/gid")" ;;
      /Groups/*) echo "GeneratedUID: UID-\${3##*/}" ;;
    esac ;;
  -create) [ "\$3" = /SharePoints/EXT ] && echo "\$5" > "$T/gid" ;;
esac
exit 0
STUB
cat > "$T/dseditgroup" <<STUB
#!/bin/bash
echo "\$*" >> "$T/dsedit.calls"
[ "\$2" = create ] && echo "\${@: -1}" >> "$T/groups"
exit 0
STUB
chmod +x "$T/gate" "$T/sharing" "$T/dscl" "$T/dseditgroup"

run() { # run <uid> <args...>; prints output, sets rc
  local uid=$1; shift
  out=$(EXT_SHARE_UID="$uid" SUDO_USER=owner EXT_SHARE_GATE="$T/gate" EXT_SHARE_SHARING="$T/sharing" EXT_SHARE_DSCL="$T/dscl" \
    EXT_SHARE_DSEDITGROUP="$T/dseditgroup" VOLUME_GATE_CONFIG="$T/cfg.json" bash "$SCRIPT" "$@" 2>&1); rc=$?
}

run 501 add;                  eq "add as a non-root user is refused" 1 "$rc"
[ ! -s "$T/sharing.calls" ] && ok "... and calls nothing" || bad "refused add called sharing"
for s in absent locked unreadable; do
  echo $s > "$T/state"; run 0 add
  eq "add with the volume $s is refused" 1 "$rc"
  case "$out" in *"nothing shared"*) ok "... and says nothing is shared" ;; *) bad "... message" "$out" ;; esac
done
if grep -q -- '^-a' "$T/sharing.calls" 2>/dev/null; then bad "a share point was created without a present volume"; else ok "no share point without a present volume"; fi

echo present > "$T/state"; run 0 add
eq "add with the volume present succeeds" 0 "$rc"
eq "sharing -a names the volume's mount point, the name, smb only, no guest" "-a $ROOT -S EXT -n EXT -s 001 -g 000" "$(grep -- '^-a' "$T/sharing.calls")"
eq "an access group is created after the highest existing one (RealName = the share)" "-o create -r EXT -i 702 com.apple.sharepoint.group.2" "$(sed -n 1p "$T/dsedit.calls")"
eq "the share point is linked to it" "UID-com.apple.sharepoint.group.2" "$(cat "$T/gid")"
eq "the invoking admin joins the new access group" "-o edit -a owner -t user com.apple.sharepoint.group.2" "$(sed -n 2p "$T/dsedit.calls")"
run 0 add;                    eq "add is idempotent" 0 "$rc"
eq "... and creates no second share point" 1 "$(grep -c -- '^-a' "$T/sharing.calls")"
eq "... and no second group" 2 "$(wc -l < "$T/dsedit.calls" | tr -d ' ')"
# a share point made earlier without a group (the 2026-11-15 state) is repaired by a re-run
rm "$T/gid"; : > "$T/dsedit.calls"; printf 'com.apple.sharepoint.group.1\ncom.apple.sharepoint.group.2\n' > "$T/groups"
run 0 add;                    eq "re-run repairs a share point that has no access group" 0 "$rc"
eq "... a group 3 is created and linked" "UID-com.apple.sharepoint.group.3" "$(cat "$T/gid")"
eq "... and the share point was not re-created" 1 "$(grep -c -- '^-a' "$T/sharing.calls")"
run 501 status;              eq "status needs no root" 0 "$rc"
case "$out" in *"share point: EXT"*) ok "status shows the share" ;; *) bad "status" "$out" ;; esac
printf '{"EXT":{"path":"/elsewhere","smb_name":"EXT"}}\n' > "$T/shares.json"
run 0 add;                    eq "a share point at another path is refused" 1 "$rc"
printf '{"EXT":{"path":"%s","smb_name":"EXT"}}\n' "$ROOT" > "$T/shares.json"
run 0 remove;                 eq "remove succeeds" 0 "$rc"
run 0 status
case "$out" in *"share point: none"*) ok "status shows none after remove" ;; *) bad "status after remove" "$out" ;; esac
run 0 remove;                 eq "remove is idempotent" 0 "$rc"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
