#!/usr/bin/env bash
# remote-dev-factory-env.test — every rd spawn (work, wave, fan) puts FACTORY_SESSION=<the agent name it
# gives the pane> into the pane at creation, through herdr's `--env` (the CLAUDE_CONFIG_DIR path), for both
# a new space and a new tab in an existing one. herdr is a stub that records each call; whatever happens
# after the create call (prompt delivery) is out of scope here, so the exit code is not asserted.
# The last section covers `--role` (the factory role table): a stub `factory` on the host PATH answers
# `role get`, and the recorded `agent start` call shows the model and effort the spawn used.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-factory-env-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }

S="$TMP/home/SourceRoot"
mkdir -p "$TMP/bin" "$TMP/state" "$S/dotfiles/scripts" "$S/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env python3\n' >"$S/dotfiles/scripts/wave-gate.py"
# fan's helpers: the worktree script answers path / base / sha, the marker script is a no-op
printf '#!/usr/bin/env bash\necho "%s/myrepo-wt"\necho origin/master\necho abc1234\n' "$S" >"$S/dotfiles/scripts/fan-worktree.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/fan-list.sh"
printf '#!/usr/bin/env bash\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/calls"
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") echo '{"result":{"agents":[]}}' ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") cat "$STATE/workspaces.json" ;;
  "tab create"|"workspace create")
    echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:1","tab_id":"t1"}}}' ;;
  "agent start") echo '{"type":"agent_started"}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$TMP/bin/herdr" "$TMP/home/.local/bin/claude-account" "$S/dotfiles/scripts/"*.sh
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_DELIVER_WAIT_S=0 RD_POLL_S=0
unset RD_DRY_RUN FACTORY_SESSION
printf 'Branch: feat/some-change\n\nDo the thing.\n' >"$TMP/brief.md"

# fsess: the FACTORY_SESSION value on the recorded create call (herdr sees it with the quotes already stripped)
fsess() { sed -n 's/.*--env FACTORY_SESSION=\([^ ]*\).*/\1/p' <<<"$create"; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }

# run <rd args…>: the create call herdr saw (tab/workspace create), with an empty or one-space roster
run() { # $1 = no-space|space, rest = rd args
  local shape=$1; shift
  : >"$STATE/calls"
  if [[ $shape == space ]]; then echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"myrepo"}]}}' >"$STATE/workspaces.json"
  else echo '{"result":{"workspaces":[]}}' >"$STATE/workspaces.json"; fi
  timeout 60 bash "$HERE/remote-dev.sh" "$@" >/dev/null 2>&1 </dev/null
  create=$(grep -E '^(tab|workspace) create' "$STATE/calls" | head -1)
}

echo "work"
run no-space work myrepo
is "workspace create carries FACTORY_SESSION=<agent>" "$(fsess)" "myrepo"

echo "wave"
run no-space wave myrepo "adhoc task"
has "new space: workspace create" "$create" "workspace create"
is "new space: FACTORY_SESSION is the wave agent name" "$(fsess)" "myrepo-w1"
run space wave myrepo "Execute the active wave (Wave 4)"
has "existing space: tab create" "$create" "tab create"
is "existing space: FACTORY_SESSION is the plan's wave agent name" "$(fsess)" "myrepo-w4"

echo "fan"
run no-space fan myrepo "$TMP/brief.md"
is "new space: FACTORY_SESSION is <repo>-<branch leaf>" "$(fsess)" "myrepo-some-change"
run space fan myrepo "$TMP/brief.md"
has "existing space: tab create" "$create" "tab create"
is "existing space: FACTORY_SESSION is <repo>-<branch leaf>" "$(fsess)" "myrepo-some-change"

echo "the agent that is started carries the same name"
start=$(grep -E '^agent start' "$STATE/calls" | head -1)
has "agent start uses the fan agent name" "$start" "agent start myrepo-some-change"

# --- role table (FL4) ---------------------------------------------------------------------------------
# No real `factory` may answer: drop every PATH dir that holds one, then install the stub in the scratch ~/.local/bin.
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$clean_path"
# factory stub: replies from $STATE/factory-reply with exit code $STATE/factory-rc; "sleep" hangs it.
cat >"$TMP/home/.local/bin/factory" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/factory-calls"
[ -f "$STATE/factory-sleep" ] && sleep 30
cat "$STATE/factory-reply" 2>/dev/null
exit "$(cat "$STATE/factory-rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$TMP/home/.local/bin/factory"
reply() { # <rc> <stdout…>
  rm -f "$STATE/factory-sleep"; : >"$STATE/factory-calls"; echo "$1" >"$STATE/factory-rc"; shift; printf '%s\n' "$*" >"$STATE/factory-reply"
}
role_json() { printf '{"role":"%s","tier":"%s","effort":"%s"}' "$1" "$2" "$3"; }

# spawn <rd args…>: combined output + exit code + the recorded agent-start call (empty when none)
spawn() {
  : >"$STATE/calls"; : >"$STATE/factory-calls"; echo '{"result":{"workspaces":[]}}' >"$STATE/workspaces.json"
  out=$(timeout 60 bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?
  start=$(grep -E '^agent start' "$STATE/calls" | head -1)
  asked=$(cat "$STATE/factory-calls" 2>/dev/null)
}
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }

echo "role: the table decides tier and effort"
reply 0 "$(role_json worker opus xhigh)"
spawn fan myrepo --role worker "$TMP/brief.md"
has "fan --role worker: asks the factory for that role" "$asked" "role get worker --format json"
has "fan --role worker: --model is the tier alias" "$start" "--model opus"
has "fan --role worker: effort from the table" "$start" "--effort xhigh"
reply 0 "$(role_json mechanical haiku low)"
spawn wave myrepo --role mechanical "adhoc task"
has "wave --role mechanical: tier" "$start" "--model haiku"
has "wave --role mechanical: effort" "$start" "--effort low"
reply 0 "$(role_json lead opus high)"
spawn work myrepo --role=lead
has "work --role=lead: tier and effort ride after --" "$start" "--pane w1:1 -- --model opus --effort high"

echo "role: verb defaults"
reply 0 "$(role_json wave opus max)"
spawn wave myrepo "adhoc task"
has "wave without --role asks for the wave role" "$asked" "role get wave --format json"
has "wave without --role uses its answer" "$start" "--model opus --effort max"
reply 0 "$(role_json worker sonnet medium)"
spawn fan myrepo "$TMP/brief.md"
has "fan without --role asks for the worker role" "$asked" "role get worker --format json"
has "fan without --role uses its answer" "$start" "--model sonnet --effort medium"
reply 0 "$(role_json wave opus max)"
spawn work myrepo
is "work without --role never asks the factory" "$asked" ""
lacks "work without --role starts bare (no model, no effort)" "$start" "--model"
lacks "work without --role has no flags after the pane" "$start" " -- "

echo "role: explicit env beats the role"
reply 0 "$(role_json worker opus xhigh)"
RD_WAVE_MODEL=sonnet spawn fan myrepo --role worker "$TMP/brief.md"
has "RD_WAVE_MODEL wins over the tier" "$start" "--model sonnet"
has "the role's effort still applies when only the model is set" "$start" "--effort xhigh"
RD_WAVE_EFFORT=low spawn fan myrepo --role worker "$TMP/brief.md"
has "RD_WAVE_EFFORT wins over the role's effort" "$start" "--effort low"
has "the role's tier still applies when only the effort is set" "$start" "--model opus"
RD_WAVE_MODEL=sonnet RD_WAVE_EFFORT=max spawn fan myrepo "$TMP/brief.md"
is "both env vars set, no --role: the factory is not asked" "$asked" ""
has "both env vars set: model" "$start" "--model sonnet"
has "both env vars set: effort" "$start" "--effort max"
RD_WAVE_MODEL=sonnet RD_WAVE_EFFORT=max spawn fan myrepo --role worker "$TMP/brief.md"
has "both env vars set, explicit --role: still asked (an unknown role stays an error)" "$asked" "role get worker"

echo "role: fail open to today's defaults (sonnet + the effort table)"
today="--model sonnet --effort high"
failopen() { # <label> <expected reason fragment>
  [ "$rc" -eq 0 ] && ok "$1: the spawn still succeeds" || bad "$1: rc=$rc — $out"
  has "$1: falls back to today's model and effort" "$start" "$today"
  has "$1: one stderr line says so" "$out" "rd: factory role 'worker' unavailable ($2)"
  [ "$(grep -c "rd: factory role" <<<"$out")" -eq 1 ] && ok "$1: exactly one line" || bad "$1: not exactly one line: $out"
}
# today's table: the repo has no claude-effort.json under the scratch HOME, so point at the real one
export CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"
reply 3 ""
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "non-zero exit" "factory exited 3"
reply 0 "not json"
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "garbage output" "its answer did not match the role schema"
reply 0 "$(role_json worker gpt-5 high)"
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "tier outside haiku|sonnet|opus" "its answer did not match the role schema"
reply 0 "$(role_json worker opus extreme)"
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "effort outside the enum" "its answer did not match the role schema"
reply 0 "$(role_json lead opus high)"
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "answer for another role" "its answer did not match the role schema"
reply 2 '{"error":{"kind":"usage","code":null,"message":"unknown command: role get worker","hint":"factory --help lists the commands","details":{}}}'
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "factory without the verb yet" "factory exited 2"
mv "$TMP/home/.local/bin/factory" "$TMP/factory.away"
spawn fan myrepo --role worker "$TMP/brief.md"; failopen "factory missing" "factory is not installed"
mv "$TMP/factory.away" "$TMP/home/.local/bin/factory"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  reply 0 "$(role_json worker opus high)"; touch "$STATE/factory-sleep"
  t0=$SECONDS
  spawn fan myrepo --role worker "$TMP/brief.md"; failopen "timeout" "no answer within 2 s"
  (( SECONDS - t0 < 20 )) && ok "timeout: gave up at the limit, not after the stub's 30 s" || bad "timeout: took $((SECONDS - t0)) s"
  rm -f "$STATE/factory-sleep"
fi
reply 2 "garbage"
spawn wave myrepo "adhoc task"
[ "$rc" -eq 0 ] && ok "wave default role, dead factory: still spawns" || bad "wave default role, dead factory: rc=$rc — $out"
has "wave default role, dead factory: today's defaults" "$start" "$today"

echo "role: unknown role is a usage error only when the factory says so"
reply 2 '{"error":{"kind":"not_found","code":null,"message":"role not found: nope","hint":"","details":{}}}'
spawn fan myrepo --role nope "$TMP/brief.md"
is "factory answers not_found: exit 2" "$rc" "2"
has "factory answers not_found: names the role" "$out" "unknown role 'nope'"
is "factory answers not_found: nothing was started" "$start" ""
lacks "factory answers not_found: no worktree/tab created" "$(cat "$STATE/calls")" "tab create"
reply 2 '{"error":{"kind":"usage","message":"Unknown role: nope"}}'
spawn work myrepo --role nope
is "message says unknown role: exit 2" "$rc" "2"
lacks "work with an unknown role created no workspace" "$(cat "$STATE/calls")" "workspace create"
reply 2 '{"error":{"kind":"usage","message":"unknown command: role get nope"}}'
spawn wave myrepo --role nope "adhoc task"
is "a factory that does not know the verb is NOT an unknown role: spawns" "$rc" "0"
spawn wave myrepo --role "Not A Role" "adhoc task"
is "malformed role name: exit 2 without asking" "$rc" "2"
spawn wave myrepo --role
[ "$rc" -ne 0 ] && ok "--role without a value is refused" || bad "--role without a value accepted"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
