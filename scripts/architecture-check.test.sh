#!/bin/bash
# Hermetic suite for architecture-check.sh: fake launchctl, fake map, fake plist
# dirs. Proves both directions — live-but-unmapped and mapped-but-absent — on both
# machine backends.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/architecture-check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/agents" "$TMP/daemons" "$TMP/docs"
cat > "$TMP/launchctl" <<'EOS'
#!/bin/sh
printf 'PID\tStatus\tLabel\n'
printf -- '-\t0\tcom.jkrumm.alpha\n'
printf -- '-\t0\tcom.apple.ignored\n'
EOS
chmod +x "$TMP/launchctl"
: > "$TMP/agents/com.jkrumm.alpha.plist"
: > "$TMP/daemons/sh.brew.caddy.plist"

write_map() { # $1 = extra mini row, $2 = extra MacBook row
  cat > "$TMP/docs/architecture.md" <<EOS
# map
## LaunchAgents — mini (gui/501 unless noted)

| Label | What |
|-|-|
| \`com.jkrumm.alpha\` | live, loaded |
| \`homebrew.mxcl.caddy\` | root daemon, other brew generation, on disk only |
$1

\`com.radiosilenceapp.agent\` and \`sh.brew.<name>\` are prose, not rows.

## LaunchAgents — MacBook

\`com.jkrumm.laptop-only\` $2

## Doors
EOS
}

run() { # $1 = backend
  echo "$1" > "$TMP/backend"
  DOTFILES_DIR="$TMP" BACKEND_FILE="$TMP/backend" LAUNCHCTL_BIN="$TMP/launchctl" \
    LAUNCHD_AGENT_DIRS="$TMP/agents $TMP/daemons" bash "$CHECK" 2>&1
}

fails=0
expect() { # name, want-rc, want-substring, got-rc, out
  if [[ "$4" != "$2" ]] || ! grep -qF -- "$3" <<<"$5"; then
    echo "✗ $1 (rc=$4, want $2, want '$3')"; echo "$5"; fails=$((fails + 1))
  else
    echo "✓ $1"
  fi
}

write_map "" ""
out=$(run cache); expect "clean mini map passes" 0 "mapped mini labels exist" $? "$out"

write_map '| `com.jkrumm.gone` | stale row |' ""
out=$(run cache); expect "stale mini row fails" 1 "mapped-but-absent (mini): com.jkrumm.gone" $? "$out"

write_map "" ""
out=$(run cache); expect "MacBook-only label is not asserted on the mini" 0 "mini label" $? "$out"

out=$(run op); expect "MacBook label absent here fails on the MacBook backend" 1 "mapped-but-absent (MacBook): com.jkrumm.laptop-only" $? "$out"

: > "$TMP/agents/com.jkrumm.beta.plist"
write_map "" ""
out=$(run cache); expect "on-disk label missing from the map still fails" 1 "on-disk-but-unmapped: com.jkrumm.beta" $? "$out"
rm "$TMP/agents/com.jkrumm.beta.plist"

# Fail closed: a renamed section heading must not read as a green pass.
sed -i '' 's/^## LaunchAgents — mini/## Agents — mini/' "$TMP/docs/architecture.md"
out=$(run cache); rc=$?; expect "renamed heading fails closed" 1 "heading renamed?" "$rc" "$out"

# A plist whose filename differs from its Label key counts by its Label.
write_map '| `com.jkrumm.renamed` | label differs from filename |' ""
/usr/libexec/PlistBuddy -c 'Add :Label string com.jkrumm.renamed' "$TMP/agents/other-name.plist" >/dev/null
out=$(run cache); rc=$?; expect "plist matched by Label key, not filename" 0 "mapped mini labels exist" "$rc" "$out"
rm "$TMP/agents/other-name.plist"

# Unknown backend skips the map-to-machine assertion rather than guessing mini.
write_map '| `com.jkrumm.gone` | stale |' ""
out=$(run weird); rc=$?; expect "unknown backend skips the reverse check" 0 "skipping the map-to-machine" "$rc" "$out"

# launchctl with no output (no GUI session) fails closed.
printf '#!/bin/sh\nexit 1\n' > "$TMP/launchctl"
out=$(run cache); rc=$?; expect "empty launchctl fails closed" 1 "no GUI session" "$rc" "$out"

[[ $fails -eq 0 ]] && echo "architecture-check: all passed" || { echo "architecture-check: $fails failed"; exit 1; }
