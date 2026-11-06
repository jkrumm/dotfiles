#!/usr/bin/env bash
# remote-dev-factory-env.test — the hc-direct rd spawn (`work`) puts FACTORY_SESSION=<the agent name it gives the terminal>
# into the terminal's `env` at creation (the account-wide Claude hooks key off it). hc is a fake that records each
# terminal.run; whatever happens after the spawn is out of scope here, so the exit code is not asserted. The last
# section covers `--role` (the factory role table): a stub `factory` on the host PATH answers `role get`, and the
# recorded terminal.run's argv shows the model and effort used.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-factory-env-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }

# the real host's marker, read before HOME is pointed at the scratch dir (dev host = cache)
dev_backend=$(cat "${DOTFILES_SECRETS_BACKEND_FILE:-$HOME/.config/secrets/backend}" 2>/dev/null)
S="$TMP/home/SourceRoot"
mkdir -p "$TMP/bin" "$TMP/state" "$S/dotfiles/scripts" "$S/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env bash\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/claude-pretrust.sh"
cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
chmod +x "$TMP/home/.local/bin/claude-account" "$TMP/home/.local/bin/hc" "$S/dotfiles/scripts/"*.sh
# a launchd-born core exists (lib/core-up.sh's first half) unless $STATE/no_core exists; PS_BIN keeps the real ps out
printf '#!/usr/bin/env bash\n[ -f "${STATE:-/nonexistent}/no_core" ] || echo "    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/hc-launchd-1/ready"\n' >"$TMP/bin/ps"; chmod +x "$TMP/bin/ps"; export PS_BIN="$TMP/bin/ps"
# the core's socket answers (lib/core-up.sh's second half; no real nc may probe a socket)
printf '#!/usr/bin/env bash\n[ ! -f "${STATE:-/nonexistent}/sock_down" ]\n' >"$TMP/bin/nc"; chmod +x "$TMP/bin/nc"
# No real `factory` may answer (the mini has one in ~/.local/bin): drop every PATH dir that holds one.
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
unset RD_DRY_RUN FACTORY_SESSION HC_SESSION HC_TERMINAL_ID

# fsess: the FACTORY_SESSION value in the recorded terminal.run (env)
fsess() { jq -r '.env.FACTORY_SESSION // empty' <<<"$create"; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }

# run <rd args…>: the first terminal.run the fake hc saw ($create; empty when none was made), with an empty roster
run() {
  rm -rf "${STATE:?}"/*
  timeout 60 bash "$HERE/remote-dev.sh" "$@" >/dev/null 2>&1 </dev/null
  create=$(sed -n 1p "$STATE/runs.jsonl" 2>/dev/null)
}

echo "work"
run work myrepo
is "terminal.run carries FACTORY_SESSION=<agent>" "$(fsess)" "myrepo"
is "a tab: labelled" "$(jq -r '.labels | has("herdr.tab")' <<<"$create")" "true"
is "no FACTORY_ROLE without --role" "$(jq -r '.env | has("FACTORY_ROLE")' <<<"$create")" "false"

# --- role table (FL4) ---------------------------------------------------------------------------------
# The scratch ~/.local/bin holds the stub `factory` (the PATH above carries no real one).
# factory stub: replies from $STATE/factory-reply with exit code $STATE/factory-rc; "sleep" hangs it.
cat >"$TMP/home/.local/bin/factory" <<'STUB'
#!/usr/bin/env bash
# `health` is not answering here (rd then spawns on hc directly, which this suite inspects); the factory path has its own suite.
[ "$1" = health ] && exit 1
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

# spawn <rd args…>: combined output + exit code + the first spawned argv, joined (empty when none)
spawn() {
  rm -f "$STATE"/runs.jsonl "$STATE"/calls.log; : >"$STATE/factory-calls"
  out=$(timeout 60 bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?
  start=$(jq -r '.argv | join(" ")' < <(sed -n 1p "$STATE/runs.jsonl" 2>/dev/null) 2>/dev/null)
  asked=$(cat "$STATE/factory-calls" 2>/dev/null)
}
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }

echo "role: the table decides tier and effort"
reply 0 "$(role_json implementer opus xhigh)"
spawn work myrepo --role implementer
has "work --role implementer: asks the factory for that role" "$asked" "role get implementer --format json"
has "work --role implementer: --model is the tier alias" "$start" "--model opus"
has "work --role implementer: effort from the table" "$start" "--effort xhigh"
reply 0 "$(role_json Explore haiku low)"
spawn work myrepo --role Explore
has "work --role Explore: tier" "$start" "--model haiku"
has "work --role Explore: effort" "$start" "--effort low"
reply 0 "$(role_json lead opus high)"
spawn work myrepo --role=lead
has "work --role=lead: tier and effort ride in argv" "$start" "claude --model opus --effort high"

echo "role: work without --role"
reply 0 "$(role_json lead opus max)"
spawn work myrepo
is "work without --role never asks the factory" "$asked" ""
lacks "work without --role starts bare (no model, no effort)" "$start" "--model"
is "work without --role: bare claude" "$start" "claude"

echo "role: explicit env beats the role"
reply 0 "$(role_json implementer opus xhigh)"
RD_MODEL=sonnet spawn work myrepo --role implementer
has "RD_MODEL wins over the tier" "$start" "--model sonnet"
has "the role's effort still applies when only the model is set" "$start" "--effort xhigh"
RD_EFFORT=low spawn work myrepo --role implementer
has "RD_EFFORT wins over the role's effort" "$start" "--effort low"
has "the role's tier still applies when only the effort is set" "$start" "--model opus"
RD_MODEL=sonnet RD_EFFORT=max spawn work myrepo
RD_MODEL=sonnet RD_EFFORT=max spawn work myrepo
is "both env vars set, no --role: work stays bare and the factory is not asked" "$asked$start" "claude"
RD_MODEL=sonnet RD_EFFORT=max spawn work myrepo --role implementer
has "both env vars set, explicit --role: still asked (an unknown role stays an error)" "$asked" "role get implementer"

echo "role: fail open to today's defaults (work: a bare claude)"
failopen() { # <label> <expected reason fragment>
  [ "$rc" -eq 0 ] && ok "$1: the spawn still succeeds" || bad "$1: rc=$rc — $out"
  is "$1: falls back to a bare claude" "$start" "claude"
  has "$1: one stderr line says so" "$out" "rd: factory role 'implementer' unavailable ($2)"
  [ "$(grep -c "rd: factory role" <<<"$out")" -eq 1 ] && ok "$1: exactly one line" || bad "$1: not exactly one line: $out"
}
# today's table: the repo has no claude-effort.json under the scratch HOME, so point at the real one
export CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"
reply 3 ""
spawn work myrepo --role implementer; failopen "non-zero exit" "factory exited 3"
reply 0 "not json"
spawn work myrepo --role implementer; failopen "garbage output" "its answer did not match the role schema"
reply 0 "$(role_json implementer gpt-5 high)"
spawn work myrepo --role implementer; failopen "tier outside haiku|sonnet|opus" "its answer did not match the role schema"
reply 0 "$(role_json implementer opus extreme)"
spawn work myrepo --role implementer; failopen "effort outside the enum" "its answer did not match the role schema"
reply 0 "$(role_json lead opus high)"
spawn work myrepo --role implementer; failopen "answer for another role" "its answer did not match the role schema"
reply 2 '{"error":{"kind":"usage","code":null,"message":"unknown command: role get implementer","hint":"factory --help lists the commands","details":{}}}'
spawn work myrepo --role implementer; failopen "factory without the verb yet" "factory exited 2"
mv "$TMP/home/.local/bin/factory" "$TMP/factory.away"
spawn work myrepo --role implementer; failopen "factory missing" "factory is not installed"
mv "$TMP/factory.away" "$TMP/home/.local/bin/factory"
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null \
   && [ "$dev_backend" = cache ]; then
  bad "timeout: neither timeout nor gtimeout on the dev host: brew install coreutils"
elif command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  reply 0 "$(role_json implementer opus high)"; touch "$STATE/factory-sleep"
  t0=$SECONDS
  spawn work myrepo --role implementer; failopen "timeout" "no answer within 2 s"
  (( SECONDS - t0 < 20 )) && ok "timeout: gave up at the limit, not after the stub's 30 s" || bad "timeout: took $((SECONDS - t0)) s"
  rm -f "$STATE/factory-sleep"
fi
echo "role: unknown role is a usage error only when the factory says so"
reply 2 '{"error":{"kind":"not_found","code":null,"message":"role not found: nope","hint":"","details":{}}}'
spawn work myrepo --role nope
is "factory answers not_found: exit 2" "$rc" "2"
has "factory answers not_found: names the role" "$out" "unknown role 'nope'"
is "factory answers not_found: nothing was started" "$start" ""
is "factory answers not_found: no terminal run" "$([ -e "$STATE/runs.jsonl" ] && echo ran)" ""
reply 2 '{"error":{"kind":"usage","message":"Unknown role: nope"}}'
spawn work myrepo --role nope
is "message says unknown role: exit 2" "$rc" "2"
is "work with an unknown role ran nothing" "$([ -e "$STATE/runs.jsonl" ] && echo ran)" ""
reply 2 '{"error":{"kind":"usage","message":"unknown command: role get nope"}}'
spawn work myrepo --role nope
is "a factory that does not know the verb is NOT an unknown role: spawns" "$rc" "0"
spawn work myrepo --role "Not A Role"
is "malformed role name: exit 2 without asking" "$rc" "2"
spawn work myrepo --role
[ "$rc" -ne 0 ] && ok "--role without a value is refused" || bad "--role without a value accepted"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
