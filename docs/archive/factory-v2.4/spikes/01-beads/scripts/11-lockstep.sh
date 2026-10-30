#!/usr/bin/env bash
# Spike 1, step 7: version lockstep and the schema-churn class of incident, reproduced on scratch data.
# A database created by bd 1.1.2 (schema v53, the line v1.2.2 re-released), then opened by bd 1.3.1
# (auto-migrates in place), then opened again by the older binary (schema-skew guard). Also shows the
# two-binaries-on-PATH hazard. Writes results/lockstep.json. Run: bash 11-lockstep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
OLD="$SPIKE/bin/old/bd"; V=1.1.2; TGZ="beads_${V}_darwin_arm64.tar.gz"
if [ ! -x "$OLD" ]; then
  curl -fsSL "https://github.com/gastownhall/beads/releases/download/v$V/$TGZ" -o "$SPIKE/downloads/$TGZ"
  want=$(python3 -I -c "import json;d=json.load(open('$SPIKE/meta/beads-releases.json'));print([a['digest'] for r in d if r['tag_name']=='v$V' for a in r['assets'] if a['name']=='$TGZ'][0].split(':')[1])")
  [ "$(shasum -a 256 "$SPIKE/downloads/$TGZ" | awk '{print $1}')" = "$want" ] || { echo checksum mismatch; exit 1; }
  rm -rf "$SPIKE/downloads/x-bd112"; mkdir -p "$SPIKE/downloads/x-bd112"
  tar -xzf "$SPIKE/downloads/$TGZ" -C "$SPIKE/downloads/x-bd112"; install -m 0755 "$SPIKE/downloads/x-bd112/bd" "$OLD"
fi
D="$SPIKE/data/lockstep"; rm -rf "$D"; mkdir -p "$D"; cd "$D" || exit 1
spike_env git init -q . && echo x > README.md && spike_env git add -A && spike_env git commit -qm i
now() { python3 -c 'import time;print(time.time())'; }
rec() { python3 -I -c "import json,sys;print(json.dumps({'step':sys.argv[1],'exit':int(sys.argv[2]),'seconds':round(float(sys.argv[3]),2),'output':' '.join(sys.argv[4].split())[:330]}))" "$@"; }
run() { # step cmd...
  local step="$1"; shift; local t0; t0=$(now); local out; out=$("$@" 2>&1); local rc=$?; local t1; t1=$(now)
  rec "$step" "$rc" "$(python3 -c "print($t1-$t0)")" "$out"
}
{
  echo "{\"old\":\"$(spike_env "$OLD" --version 2>&1)\",\"new\":\"$(spike_env bd --version 2>&1)\"}"
  spike_env "$OLD" metrics off >/dev/null 2>&1
  run old_init            spike_env "$OLD" init -p ls --non-interactive --quiet --skip-agents --skip-hooks
  run old_create          spike_env "$OLD" create "made by 1.1.2" -t task --json
  run old_version_schema  spike_env "$OLD" info --json
  run new_first_command   spike_env bd list --json
  run new_info            spike_env bd info --json
  run old_after_migration spike_env "$OLD" list --json
  run old_after_migration_with_skew_override env BD_IGNORE_SCHEMA_SKEW=1 HOME="$SPIKE_HOME" PATH="$SPIKE/bin/old:$PATH" "$OLD" list --json
  run new_still_fine      spike_env bd list --json
} > "$SPIKE/results/lockstep.jsonl"
python3 -I - <<PY
import json
rows=[json.loads(l) for l in open("$SPIKE/results/lockstep.jsonl") if l.strip()]
json.dump({"versions":rows[0],"steps":rows[1:]}, open("$HERE/../results/lockstep.json","w"), indent=1)
for r in rows[1:]: print(r["step"], "exit", r["exit"], f'{r["seconds"]}s', "|", r["output"][:200])
PY
