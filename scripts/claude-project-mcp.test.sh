#!/bin/bash
# Hermetic suite for claude-project-mcp.sh: fixture .claude.json files, a fake `claude` on PATH.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/claude-project-mcp.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/bin"; mkdir -p "$FAKE" "$TMP/proj-a" "$TMP/proj-b"
export PATH="$FAKE:$PATH"

# Fake claude: `mcp remove chrome-devtools --scope local` drops the entry for $PWD from $FAKE_CLAUDE_JSON,
# the way the real CLI does, and records the call. FAKE_CLAUDE_NOOP=1 leaves the file alone (a CLI that fails).
cat > "$FAKE/claude" <<'FAKE_EOF'
#!/bin/bash
echo "$PWD $*" >> "$FAKE_CLAUDE_CALLS"
[ "${FAKE_CLAUDE_NOOP:-}" = 1 ] && exit 1
tmp=$(mktemp "$FAKE_CLAUDE_JSON.XXXXXX")
jq --arg p "$PWD" 'del(.projects[$p].mcpServers["chrome-devtools"])' "$FAKE_CLAUDE_JSON" > "$tmp" && mv "$tmp" "$FAKE_CLAUDE_JSON"
FAKE_EOF
chmod +x "$FAKE/claude"
export FAKE_CLAUDE_CALLS="$TMP/calls"

fail=0
check() { local name=$1; shift; if "$@" >/dev/null; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi; }
fixture() { # $1 = file
  P1=$(cd "$TMP/proj-a" && pwd -P); P2=$(cd "$TMP/proj-b" && pwd -P)
  jq -n --arg a "$P1" --arg b "$P2" --arg gone "$TMP/gone" '{
    numStartups: 3,
    mcpServers: {keep: {command: "x"}},
    projects: {
      ($a): {mcpServers: {"chrome-devtools": {command: "npx", args: ["-y", "chrome-devtools-mcp@latest"]}, other: {type: "sse", url: "http://x"}}},
      ($b): {mcpServers: {"other": {command: "y"}}},
      ($gone): {mcpServers: {"chrome-devtools": {command: "npx"}}}
    }}' > "$1"
  chmod 600 "$1"
}

F="$TMP/claude.json"; fixture "$F"; export FAKE_CLAUDE_JSON="$F"

out=$("$SCRIPT" check "$F" me2); rc=$?
check "check fails on a project-local entry" [ $rc -eq 1 ]
check "check names the account" grep -q "for me2 in $P1" <<<"$out"
check "check names every affected project" grep -q "$TMP/gone" <<<"$out"
check "check leaves the clean project alone" bash -c '! grep -q proj-b <<<"$1"' _ "$out"

out=$("$SCRIPT" clean "$F" me2); rc=$?
check "clean exits 0" [ $rc -eq 0 ]
check "clean calls the CLI in the project dir with --scope local" grep -q "^$P1 mcp remove chrome-devtools --scope local" "$FAKE_CLAUDE_CALLS"
check "clean does not call the CLI for a missing dir" bash -c '! grep -q "/gone " "$1"' _ "$FAKE_CLAUDE_CALLS"
check "no entry survives" bash -c '[ "$(jq "[.projects[].mcpServers | has(\"chrome-devtools\")] | any" "$1")" = false ]' _ "$F"
check "other servers and keys survive" bash -c '[ "$(jq -r "[.mcpServers.keep.command, .projects[\"$1\"].mcpServers.other.type, .projects[\"$2\"].mcpServers.other.command, (.numStartups|tostring)] | join(\",\")" "$3")" = "x,sse,y,3" ]' _ "$P1" "$P2" "$F"
check "the gone dir took the jq path with a backup" [ -f "$F.bak-chrome-devtools" ]
"$SCRIPT" check "$F" me2 >/dev/null; check "check passes after clean" [ $? -eq 0 ]

# A CLI that does nothing: the jq path still removes the entry.
F2="$TMP/claude2.json"; fixture "$F2"; export FAKE_CLAUDE_JSON="$F2" FAKE_CLAUDE_NOOP=1
"$SCRIPT" clean "$F2" default >/dev/null
check "a failing CLI falls back to jq" "$SCRIPT" check "$F2" default
check "the fallback keeps a backup" [ -f "$F2.bak-chrome-devtools" ]
check "the fallback keeps the file mode" [ "$(stat -f %Lp "$F2")" = 600 ]

# Missing file and file without projects are clean, not errors.
check "missing file passes" "$SCRIPT" check "$TMP/none.json" x
echo '{}' > "$TMP/empty.json"
check "file without projects passes" "$SCRIPT" check "$TMP/empty.json" x

exit $fail
