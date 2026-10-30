#!/usr/bin/env bash
# Spike 1, step 1: install bd v1.3.1 and the Dolt CLI that beads pins (2.2.0) into the scratch
# prefix only. Versions and digests come from the release metadata (GitHub API), not memory.
# Output: results/install.json (wall-clock per step). Run: bash 01-install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
BD_VERSION=1.3.1; DOLT_VERSION=2.2.0
T0=$(python3 -c 'import time;print(time.time())'); STEPS=""
step() { # name, start
  local now; now=$(python3 -c 'import time;print(time.time())')
  STEPS="$STEPS{\"step\":\"$1\",\"seconds\":$(python3 -c "print(round($now-$2,2))")},"
  echo "step $1: $(python3 -c "print(round($now-$2,2))")s"
}
now() { python3 -c 'import time;print(time.time())'; }

s=$(now)
curl -fsSL 'https://api.github.com/repos/gastownhall/beads/releases/tags/v'$BD_VERSION -o "$SPIKE/meta/bd-release.json"
curl -fsSL 'https://api.github.com/repos/dolthub/dolt/releases/tags/v'$DOLT_VERSION -o "$SPIKE/meta/dolt-release.json"
step metadata "$s"

dl() { # url dest
  [ -f "$2" ] || curl -fsSL "$1" -o "$2"
}
s=$(now)
BD_TGZ="beads_${BD_VERSION}_darwin_arm64.tar.gz"
dl "https://github.com/gastownhall/beads/releases/download/v$BD_VERSION/$BD_TGZ" "$SPIKE/downloads/$BD_TGZ"
dl "https://github.com/gastownhall/beads/releases/download/v$BD_VERSION/checksums.txt" "$SPIKE/downloads/bd-checksums.txt"
step download_bd "$s"
s=$(now)
DOLT_TGZ="dolt-darwin-arm64.tar.gz"
dl "https://github.com/dolthub/dolt/releases/download/v$DOLT_VERSION/$DOLT_TGZ" "$SPIKE/downloads/dolt-$DOLT_VERSION-$DOLT_TGZ"
step download_dolt "$s"

s=$(now)
want_bd=$(awk -v f="$BD_TGZ" '$2==f{print $1}' "$SPIKE/downloads/bd-checksums.txt")
api_bd=$(python3 -I -c "import json,sys;d=json.load(open('$SPIKE/meta/bd-release.json'));print([a['digest'] for a in d['assets'] if a['name']=='$BD_TGZ'][0].split(':')[1])")
got_bd=$(shasum -a 256 "$SPIKE/downloads/$BD_TGZ" | awk '{print $1}')
api_dolt=$(python3 -I -c "import json;d=json.load(open('$SPIKE/meta/dolt-release.json'));print([a['digest'] for a in d['assets'] if a['name']=='$DOLT_TGZ'][0].split(':')[1])")
got_dolt=$(shasum -a 256 "$SPIKE/downloads/dolt-$DOLT_VERSION-$DOLT_TGZ" | awk '{print $1}')
[ "$want_bd" = "$got_bd" ] && [ "$api_bd" = "$got_bd" ] || { echo "bd checksum mismatch"; exit 1; }
[ "$api_dolt" = "$got_dolt" ] || { echo "dolt checksum mismatch"; exit 1; }
step verify_checksums "$s"

s=$(now)
# each archive in its own fresh, empty directory (untrusted data), nothing executed from inside it
rm -rf "$SPIKE/downloads/x-bd" "$SPIKE/downloads/x-dolt"; mkdir -p "$SPIKE/downloads/x-bd" "$SPIKE/downloads/x-dolt"
tar -xzf "$SPIKE/downloads/$BD_TGZ" -C "$SPIKE/downloads/x-bd"
tar -xzf "$SPIKE/downloads/dolt-$DOLT_VERSION-$DOLT_TGZ" -C "$SPIKE/downloads/x-dolt"
install -m 0755 "$SPIKE/downloads/x-bd/bd" "$SPIKE/bin/bd"
install -m 0755 "$SPIKE/downloads/x-dolt/dolt-darwin-arm64/bin/dolt" "$SPIKE/bin/dolt"
step extract_install "$s"

echo "--- versions"
spike_env bd version | tee "$SPIKE/logs/bd-version.txt"
spike_env dolt version | tee "$SPIKE/logs/dolt-version.txt"
codesign -dv "$SPIKE/bin/bd" 2>&1 | head -3 || true
ls -l "$SPIKE/bin"
T1=$(now)
python3 -I - <<PY
import json
steps=json.loads('[${STEPS%,}]')
json.dump({"bd_version":"$BD_VERSION","dolt_version":"$DOLT_VERSION","steps":steps,
  "total_seconds":round($T1-$T0,2),"bd_sha256":"$got_bd","dolt_sha256":"$got_dolt",
  "bd_tarball_bytes":$(stat -f%z "$SPIKE/downloads/$BD_TGZ"),"dolt_tarball_bytes":$(stat -f%z "$SPIKE/downloads/dolt-$DOLT_VERSION-$DOLT_TGZ"),
  "bd_binary_bytes":$(stat -f%z "$SPIKE/bin/bd"),"dolt_binary_bytes":$(stat -f%z "$SPIKE/bin/dolt")},
  open("$SPIKE/results/install.json","w"),indent=1)
PY
cat "$SPIKE/results/install.json"
