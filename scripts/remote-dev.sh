#!/usr/bin/env bash
set -uo pipefail

# remote-dev — drive the mini's herdr-core terminals and Claude agents.
#
# The three-layer model (Tailscale / herdr-core / Caddy) is about *getting a
# terminal*. This script is the layer above it: preparing and steering the work
# itself, without needing a terminal at all. That distinction is the whole point
# — the Herdr app is how you go and look; everything here you can do from
# the MacBook while attached to nothing.
#
# Routing is deliberate and invisible: every subcommand runs on the dev host,
# whether you are sitting at it or a hop away. There is one definition of "am I
# the dev host" (the secrets backend marker, same signal `git-headless`
# keys off) so the two machines can share one command surface.
#
# The MacBook's sanctioned repos are dotfiles/dotfiles-private/brain —
# no project repos. `repos` and `work` resolve paths ON the host, which
# is why none of them take a path — a MacBook-side project-repo path would be
# meaningless.

HOST="${REMOTE_DEV_HOST:-mini}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
# " --effort '<level>'" for a spawned agent: RD_WAVE_EFFORT wins, then the factory role's effort ($2),
# else the per-model default from config/claude-effort.json (Sonnet high, Opus/Fable medium); empty
# when none applies.
rd_effort_flag() { # <model> [role-effort]
  local level
  if [[ -n "${RD_WAVE_EFFORT:-}" ]]; then
    level=$RD_WAVE_EFFORT
  elif [[ -n "${2:-}" ]]; then
    level=$2
  else
    level=$(jq -r --arg m "$(printf %s "$1" | tr '[:upper:]' '[:lower:]')" 'del(._note) | if $m == "" then .default else (to_entries | map(select(.key as $k | $k != "default" and ($m | contains($k)))) | .[0].value) end // empty' \
      "${CLAUDE_EFFORT_TABLE:-$HOME/SourceRoot/dotfiles/config/claude-effort.json}" 2>/dev/null) || level=""
    [[ -z "$level" ]] && return 0
  fi
  case "$level" in
    low|medium|high|xhigh|max) printf " --effort '%s'" "$level" ;;
    *) die "RD_WAVE_EFFORT must be low|medium|high|xhigh|max (got '$level')" ;;
  esac
}

# --- role table (FL4) ---------------------------------------------------------
# `--role <role>` reads tier + effort from the factory's role table (`factory role get`). It is a
# client lookup that fails open: a dead, missing, slow or off-schema factory costs one stderr line and the
# spawn keeps today's defaults. Only a factory that ANSWERS "no such role" (or a malformed role name)
# is a usage error, exit 2.
ROLE=""            # --role given on the command line
ROLE_TIER=""       # resolved tier alias (haiku|sonnet|opus), empty when the lookup failed open
ROLE_EFFORT=""     # resolved effort, empty when the lookup failed open
ROLE_TIMEOUT_S=2
SPAWN_MODEL=""; SPAWN_EFFORT=""; SPAWN_MODEL_FLAG=""; SPAWN_EFFORT_FLAG=""
PICK_ENV=()

role_usage_error() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }

# True when a factory reply says the role does not exist: error.kind "not_found" or an "unknown role"
# message. A bare "unknown command" (a factory without the verb yet) is NOT this — that fails open.
role_not_found() { # <text>
  jq -e '(try (.error | objects) catch null // {}) | (.kind == "not_found") or ((.message // "") | test("unknown role|no such role"; "i"))' \
    <<<"$1" >/dev/null 2>&1
}

rd_role_resolve() { # <role>
  local role=$1 out err efile rc=0 why=""
  ROLE_TIER=""; ROLE_EFFORT=""
  [[ $role =~ ^[a-z][a-z0-9_-]*$ ]] || role_usage_error "invalid role name '$role' — mother|lead|wave|worker|mechanical"
  efile=$(mktemp "${TMPDIR:-/tmp}/rd-role.XXXXXX") || efile=/dev/null
  # The timeout binary is resolved on the host (coreutils is `timeout` or Homebrew's `gtimeout`); without one the
  # lookup runs unbounded rather than failing.
  out=$(host_run "PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:\$HOME/.bun/bin:\$PATH\"; t=\$(command -v timeout || command -v gtimeout); \${t:+\$t $ROLE_TIMEOUT_S} factory role get '$role' --format json" 2>"$efile") || rc=$?
  err=$(cat "$efile" 2>/dev/null); [[ $efile == /dev/null ]] || rm -f "$efile"

  if (( rc == 0 )); then
    if jq -e --arg r "$role" '.role == $r and (.tier | IN("haiku","sonnet","opus")) and (.effort | IN("low","medium","high","xhigh","max"))' \
         <<<"$out" >/dev/null 2>&1; then
      ROLE_TIER=$(jq -r .tier <<<"$out"); ROLE_EFFORT=$(jq -r .effort <<<"$out")
      return 0
    fi
    why="its answer did not match the role schema"
  elif role_not_found "$out" || role_not_found "$err"; then
    role_usage_error "unknown role '$role' — mother|lead|wave|worker|mechanical"
  elif (( rc == 124 )); then why="no answer within ${ROLE_TIMEOUT_S} s"
  elif (( rc == 127 )); then why="factory is not installed"
  else why="factory exited $rc"
  fi
  echo "rd: factory role '$role' unavailable ($why) - using the default model and effort" >&2
  return 0
}

# True only when a factory reply is the structured answer "this does not exist" (error.kind "not_found"). Message
# text is not matched: "config not found" is a fault, not an answer about the spawn or session asked for.
factory_not_found() { # <text>
  jq -e '(try (.error | objects) catch null // {}) | .kind == "not_found"' <<<"$1" >/dev/null 2>&1
}

# Model and effort for a spawn: RD_WAVE_MODEL / RD_WAVE_EFFORT, then the --role (or the verb's default
# role, $1), then today's defaults ($2: the fallback model, empty for `work`). Sets SPAWN_MODEL_FLAG
# and SPAWN_EFFORT_FLAG (empty or " --model '<m>'" / " --effort '<l>'"). The lookup is skipped only when
# both env vars already decide everything and no --role was asked for.
rd_spawn_flags() { # <default-role> <fallback-model>
  local role=${ROLE:-${1:-}} model
  ROLE_TIER=""; ROLE_EFFORT=""
  if [[ -n $role ]] && { [[ -n $ROLE ]] || [[ -z ${RD_WAVE_MODEL:-} || -z ${RD_WAVE_EFFORT:-} ]]; }; then
    rd_role_resolve "$role"
  fi
  model=${RD_WAVE_MODEL:-${ROLE_TIER:-${2:-}}}
  SPAWN_MODEL_FLAG=""; SPAWN_EFFORT_FLAG=""; SPAWN_MODEL=""; SPAWN_EFFORT=""
  [[ -n $model ]] && { SPAWN_MODEL_FLAG=" --model '$model'"; SPAWN_MODEL=$model; }
  if [[ -n $model || -n ${RD_WAVE_EFFORT:-} || -n $ROLE_EFFORT ]]; then
    SPAWN_EFFORT_FLAG=$(rd_effort_flag "$model" "$ROLE_EFFORT") || exit 1 # a bad RD_WAVE_EFFORT dies in the subshell: stop here too
    SPAWN_EFFORT=${SPAWN_EFFORT_FLAG#* \'}; SPAWN_EFFORT=${SPAWN_EFFORT%\'} # the bare level, for claude's argv
  fi
}

# --- routing -----------------------------------------------------------------

on_dev_host() {
  [[ "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null)" == "cache" ]]
}

# Run a command string on the dev host. Local exec when we are already there,
# one ssh hop otherwise. ControlMaster makes the hop ~free and, more to the
# point, keeps it to a single biometric approval per 10 minutes.
host_run() {
  if on_dev_host; then
    bash -c "$1"
  else
    # SC2029: remote-side expansion is the intent — $HOME differs between the
    # two machines ($USER differs), so these must expand THERE, not here.
    # shellcheck disable=SC2029
    ssh "$HOST" "$1"
  fi
}

# --- herdr-core (hc) -----------------------------------------------------------
#
# Every agent lives in herdr-core (docs/herdr-core.md §Port design). Three rules hold for all of it:
#  - Nothing here may START a core. Any `hc` call, `hc connect` included, auto-starts one when none runs, and a core
#    born in an ssh session has no keychain. So `require_core` asks launchd first, and nothing calls `hc update`,
#    `hc server restart|stop` or `hc machine update`.
#  - A spawn goes over the API (`hc connect`, JSON-RPC `terminal.run`), because the CLI's `hc run` cannot pass `env`
#    and a core's own environment is every terminal's environment (docs/herdr-core.md §Spawn contract).
#  - `hc` runs on the dev host: the MacBook hops over ssh like for everything else.
CORE_LABEL=com.jkrumm.herdr-core
APP_DOC=herdr-app
HC_PRE='PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH";'
CORE_OK=""

# `hc <args…>` on the dev host; every argument is quoted for the far shell, so text arrives byte-identical. Bounded by
# the host's `timeout`/`gtimeout` (RD_HC_TIMEOUT_S, default 30 s; the discovery factory_host uses): rc 124 = timed out.
# A host with neither runs it unbounded rather than not at all: hc is the only path left.
hc_host() {
  local args="" a
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  host_run "$HC_PRE t=''; for c in ${RD_TIMEOUT_CMDS:-timeout gtimeout}; do t=\$(command -v \$c) && break; done; \${t:+\$t ${RD_HC_TIMEOUT_S:-30}} hc$args"
}

# Die unless launchd has the core running. HC_SESSION names another core (a scratch one in tests): the caller owns it,
# but only on the dev host itself: a MacBook's HC_SESSION is not forwarded over ssh, so the mini's core is still the one.
require_core() {
  [[ -z $CORE_OK ]] || return 0
  if [[ -z ${HC_SESSION:-} ]] || ! on_dev_host; then
    local out rc=0
    out=$(host_run "launchctl print \"gui/\$(id -u)/$CORE_LABEL\" 2>&1") || rc=$?
    (( rc == 255 )) \
      && die "no answer from $HOST — nothing ran there at all; check the ssh hop with 'make doctor'"
    if (( rc != 0 )) || ! grep -q 'state = running' <<<"$out"; then
      die "herdr-core is not running on $HOST (any hc call would start a stray one). Start it with: launchctl kickstart -k gui/\$(id -u)/$CORE_LABEL — or run 'make doctor'"
    fi
  fi
  CORE_OK=1
}

# One JSON-RPC call over `hc connect`. Prints the answer line ({result} or {error}); rc 1 when nothing usable came back
# (HC_RPC_RC = the transport's exit code, 124 when the call timed out).
HC_RPC_RC=0
hc_rpc() { # <method> [params-json]
  local params=${2:-} req out rc=0
  [[ -n $params ]] || params='{}'
  req=$(jq -nc --arg m "$1" --argjson p "$params" '{jsonrpc:"2.0",id:1,method:$m,params:$p}') || return 1
  out=$(printf '%s\n' "$req" | hc_host connect 2>/dev/null) || rc=$?
  HC_RPC_RC=$rc
  (( rc == 0 )) || return 1
  out=$(jq -c 'select(.id == 1)' <<<"$out" 2>/dev/null | head -1)
  [[ -n $out ]] || return 1
  printf '%s' "$out"
}
# The kind of an error answer ("conflict", "not_found", …); empty for a result.
rpc_kind() { jq -r 'if .error then (.error.data.kind // "error") else empty end' <<<"$1" 2>/dev/null; }
rpc_message() { jq -r '.error.message // "no reason given"' <<<"$1" 2>/dev/null; }

# The live terminals as a JSON array (full records: labels, parent, status, argv, cwd). Dies naming the core.
# HC_ROSTER holds the dev host's own terminals: a linked machine's (`mini/t3`, `macbook/t1`) is not ours to close, read,
# steer or count. HC_ROSTER_ALL keeps them, for the listing.
HC_ROSTER="[]"
HC_ROSTER_ALL="[]"
hc_roster() {
  local resp
  if ! resp=$(hc_rpc terminal.list) || ! jq -e '.result.terminals | arrays' <<<"$resp" >/dev/null 2>&1; then
    die "could not read the terminal roster from $HOST — the core, not the agent ('hc ls' there, or 'make doctor')"
  fi
  HC_ROSTER_ALL=$(jq -c '.result.terminals' <<<"$resp")
  HC_ROSTER=$(jq -c '[.[] | select((.address | tostring | contains("/")) | not)]' <<<"$HC_ROSTER_ALL")
}

# True when the terminal record ($1) carries an rd/factory ownership marker: a `factory.key` label, or the name rd gives
# an agent (a tab's `herdr.tab` label is `tb-<hash of its name>`; a hidden worker is a named child). A Claude somebody
# started by hand has none of these, and rd never ends or types into what it did not start.
hc_owned() {
  local rec=$1 name key tab par
  name=$(jq -r '.name // ""' <<<"$rec"); key=$(jq -r '.labels["factory.key"] // ""' <<<"$rec")
  tab=$(jq -r '.labels["herdr.tab"] // ""' <<<"$rec"); par=$(jq -r '.parent // ""' <<<"$rec")
  [[ -n $key ]] && return 0
  [[ -n $name ]] || return 1
  [[ -n $par ]] && return 0
  [[ -n $tab && $tab == "tb-$(sha12 "$name")" ]]
}

# True in an owner's own session on the dev host: a calling terminal but no FACTORY_SESSION. Its children are its to
# `hc wait --children` on, which a factory spawn (a parentless tab) would not be.
owner_session() { on_dev_host && [[ -n ${HC_TERMINAL_ID:-} && -z ${FACTORY_SESSION:-} ]]; }

# True when status $1 is a known finished one: idle or done. Null, unknown, starting, working and blocked are not.
is_finished_status() { [[ $1 == "idle" || $1 == "done" ]]; }

# An agent is a terminal that reports a status or runs claude itself: a plain shell is not.
HC_JQ_DEFS='def prog: ((.foreground.argv // .argv // [])[0] // "") | split("/") | last;
def agent: ((.status // null) != null) or (prog == "claude");
def base: (.cwd // "") | split("/") | last;'

# hc refuses a terminal name that reads like an address (`t7`); such a name is escaped with a short hash of itself
# (HcRunner's terminalName, so the factory and rd agree).
sha12() { printf %s "$1" | shasum -a 256 | cut -c1-12; }
hc_terminal_name() {
  case $1 in
    t[0-9]*) printf 'f-%s-%s' "$(sha12 "$1" | cut -c1-6)" "${1:0:22}" ;;
    *) printf %s "$1" ;;
  esac
}

# Addresses of the live agents a token names: an address (t7), a terminal name, a repo name (the basename of the
# agent's cwd), a full cwd path, or a factory key. $1 token  $2 roster JSON.
hc_match() {
  jq -r --arg t "$1" --arg e "$(hc_terminal_name "$1")" "$HC_JQ_DEFS"'.[] | select(agent)
    | select(.address == $t or .name == $t or .name == $e or .cwd == $t or base == $t or (.labels["factory.key"] // "") == $t)
    | .address' <<<"$2" 2>/dev/null
}

# The roster an error message prints: address, repo, name, status. $2 restricts it to a set of addresses.
hc_roster_text() { # <roster> [addresses…]
  local json=$1; shift
  jq -r --arg only "$*" "$HC_JQ_DEFS"'($only | split(" ") | map(select(length > 0))) as $o
    | .[] | select(agent) | select(($o | length) == 0 or (.address as $a | $o | index($a)))
    | "    \(.address)  \(base)  \(.name // "?")  \(.status.state // "?")"' <<<"$json" 2>/dev/null
}

# The Herdr app's space for a repo, HcRunner's rule (software-factory hc-runner.ts spaceId) so that rd-direct spawns and
# the factory's land in the same one: the app's own `herdr-app` doc entry whose folder is the repo root, else a stable
# id from the full root (so ~/SourceRoot/x and ~/IuRoot/x differ). Dies when the doc cannot be read: a space is never
# made up on the strength of a call that told nothing.
hc_space_id() { # <repo path>
  local root doc id
  root=$(host_run "cd $(printf '%q' "$1") 2>/dev/null && pwd -P") || root=""
  [[ -n $root ]] || root=$1
  if ! doc=$(hc_rpc doc.get "$(jq -nc --arg n "$APP_DOC" '{name:$n}')"); then
    die "could not read the $APP_DOC document from $HOST — refusing to guess a space"
  fi
  if [[ -n $(rpc_kind "$doc") && $(rpc_kind "$doc") != not_found ]]; then
    die "could not read the $APP_DOC document from $HOST ($(rpc_message "$doc")) — refusing to guess a space"
  fi
  id=$(jq -r --arg a "$1" --arg b "$root" '((.result.value | objects | .spaces | arrays) // [])
    | map(select(type == "object" and ((.folder // "") | . == $a or . == $b))) | .[0].id // empty' <<<"$doc" 2>/dev/null)
  if [[ -n $id ]]; then printf %s "$id"; return 0; fi
  printf 'sp-%s-%s' "$(basename "$root")" "$(sha12 "$root")"
}

# Name a tab we made once the app has an entry for it: compare-and-set on the doc, retried on `conflict`. Best effort,
# never failing the spawn (HcRunner's nameTab): the app adopts a tab only after it has seen the terminal, so often there
# is no entry yet and the tab stays numbered.
hc_name_tab() { # <tab id> <name>
  local i doc version value resp
  for i in 1 2 3; do
    doc=$(hc_rpc doc.get "$(jq -nc --arg n "$APP_DOC" '{name:$n}')") || return 0
    [[ -z $(rpc_kind "$doc") ]] || return 0
    version=$(jq -r '.result.version // empty' <<<"$doc")
    [[ -n $version ]] || return 0
    value=$(jq -c --arg id "$1" --arg n "$2" '.result.value
      | if type == "object" and ((.spaces | type) == "array")
           and any(.spaces[] | objects | .tabs | arrays | .[] | objects; .id == $id and .name != $n)
        then .spaces |= map(if type == "object" and ((.tabs | type) == "array")
                             then .tabs |= map(if type == "object" and .id == $id then .name = $n else . end) else . end)
        else empty end' <<<"$doc" 2>/dev/null)
    [[ -n $value ]] || return 0
    resp=$(hc_rpc doc.set "$(jq -nc --arg n "$APP_DOC" --argjson v "$value" --argjson ver "$version" '{name:$n,version:$ver,value:$v}')") || return 0
    [[ -n $(rpc_kind "$resp") ]] || return 0
    [[ $(rpc_kind "$resp") == conflict ]] || return 0
  done
  return 0
}

# claude's argv as a JSON array: ["claude", flags…, "<prompt>"] (the prompt is the last argument; nothing is typed later).
# Model and effort come from rd_spawn_flags (SPAWN_MODEL / SPAWN_EFFORT).
claude_argv() { # <skip-permissions 1|0> [prompt]
  local -a a=(claude)
  (( $1 )) && a+=(--dangerously-skip-permissions)
  [[ -n $SPAWN_MODEL ]] && a+=(--model "$SPAWN_MODEL")
  [[ -n $SPAWN_EFFORT ]] && a+=(--effort "$SPAWN_EFFORT")
  [[ -n ${2:-} ]] && a+=("$2")
  jq -nc '$ARGS.positional' --args -- "${a[@]}"
}

# The spawn's environment, as JSON. The core's own environment is every terminal's, so the account is chosen here:
# CLAUDE_CONFIG_DIR is set for a Claude account and ABSENT for iu (never empty, never inherited). FACTORY_SESSION turns
# the account-wide hooks on for this session; PICK_ENV (pick_account) carries the account and its marker.
spawn_env() { # <agent> <role> <usage lane>
  {
    printf 'FACTORY_SESSION=%s\n' "$1"
    [[ -n $2 ]] && printf 'FACTORY_ROLE=%s\n' "$2"
    [[ -n $3 ]] && printf 'USAGE_LANE=%s\n' "$3"
    (( ${#PICK_ENV[@]} )) && printf '%s\n' "${PICK_ENV[@]}"
  } | jq -Rn '[inputs | select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}] | add // {}'
}

# Start Claude in a new hc terminal (rd's hc-direct spawn, §Spawn contract). Sets SPAWNED_ADDR (and SPAWNED_SPACE for a tab);
# returns 1 with HC_START_ERR set when it did not start (a timeout is "uncertain": never retried here).
#   $1 agent  $2 cwd  $3 role (FACTORY_ROLE, may be empty)  $4 usage lane (may be empty)  $5 skip-permissions 1|0  $6 prompt (may be empty)
#   $7 placement: tab        a labelled tab of the repo's space, no parent (work, wave, a chain's next wave)
#                 tab-child  the same, but a child of the caller (an orchestrated wave: the notes and `hc wait --children` need the parent)
#                 child      a hidden child of the caller, no labels (a fan worker); a tab when there is no caller terminal
#   $8 the repo whose space a tab goes in
hc_start_agent() {
  local agent=$1 cwd=$2 role=$3 lane=$4 skip=$5 prompt=$6 where=$7 spath=$8
  local argv env name labels place tab parent="" resp kind
  HC_START_ERR=""
  [[ $prompt != -* ]] || die "a prompt cannot start with '-' (claude would read it as an option)"
  # The caller's terminal is a parent only on the dev host: a MacBook terminal's id is another core's.
  if [[ $where != tab ]] && on_dev_host && [[ ${HC_TERMINAL_ID:-} =~ ^t[0-9a-z]+$ ]]; then parent=$HC_TERMINAL_ID; fi
  [[ $where == tab-child && -z $parent ]] && where=tab
  [[ $where == child && -z $parent ]] && where=tab
  argv=$(claude_argv "$skip" "$prompt") || { HC_START_ERR="could not build claude's argv"; return 1; }
  env=$(spawn_env "$agent" "$role" "$lane") || { HC_START_ERR="could not build the spawn environment"; return 1; }
  name=$(hc_terminal_name "$agent")
  hc_pretrust "$cwd"

  while :; do
    SPAWNED_SPACE=""; tab=""
    if [[ $where == child ]]; then
      labels='{}'; place=$(jq -nc --arg p "$parent" '{parent:$p,outlive_parent:true}')
    else
      SPAWNED_SPACE=$(hc_space_id "$spath") || { HC_START_ERR="could not resolve the space of $spath (above)"; return 1; }
      tab="tb-$(sha12 "$agent")"
      labels=$(jq -nc --arg s "$SPAWNED_SPACE" --arg t "$tab" '{"herdr.space":$s,"herdr.tab":$t}')
      place='{"no_parent":true}'
      [[ $where == tab-child ]] && place=$(jq -nc --arg p "$parent" '{parent:$p,outlive_parent:true}')
    fi
    resp=$(hc_rpc terminal.run "$(jq -nc --arg name "$name" --arg cwd "$cwd" --argjson argv "$argv" --argjson env "$env" \
      --argjson labels "$labels" --argjson place "$place" \
      '{argv:$argv,cwd:$cwd,env:$env,labels:$labels,keep:true,name:$name} + $place')") \
      || {
        if (( HC_RPC_RC == 124 )); then
          HC_START_ERR="uncertain — hc did not answer within ${RD_HC_TIMEOUT_S:-30} s while starting '$agent' on $HOST; 'rd agents' shows whether it exists. Not retrying"
        else
          HC_START_ERR="uncertain — no answer from hc while starting '$agent' on $HOST; 'rd agents' shows whether it exists. Not retrying"
        fi
        return 1
      }
    kind=$(rpc_kind "$resp")
    # The parent is gone: this one becomes a tab instead.
    if [[ $kind == not_found && $where == child ]]; then where=tab; continue; fi
    [[ -z $kind ]] || { HC_START_ERR="hc could not start '$agent': $(rpc_message "$resp")"; return 1; }
    break
  done
  SPAWNED_WHERE=$where # the placement that held: a child falls back to a tab when its parent is gone
  SPAWNED_ADDR=$(jq -r '.result.address // empty' <<<"$resp")
  [[ -n $SPAWNED_ADDR ]] || { HC_START_ERR="hc started '$agent' but returned no address: $resp"; return 1; }
  [[ -z $tab ]] || hc_name_tab "$tab" "$agent"
}

# The folder-trust dialog blocks a fresh account's first start in a path; accept it everywhere first. Best effort.
hc_pretrust() { # <path>
  host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/claude-pretrust.sh\" $(printf '%q' "$1")" >/dev/null 2>&1 \
    || note "   could not pre-accept the folder-trust dialog for $1 — a fresh account may stop at it"
}


# Repo names, not paths: the two roots live under a different $HOME on the mini
# ($USER differs), so resolution has to happen on the far side.
resolve_repo() {
  local name=$1 path
  # A repo name is interpolated into the far shell's command: only plain names are repos.
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  path=$(host_run "for r in \"\$HOME/SourceRoot\" \"\$HOME/IuRoot\"; do
      if [ -d \"\$r/$name/.git\" ]; then echo \"\$r/$name\"; exit 0; fi
    done; exit 1") || return 1
  [[ -n $path ]] || return 1
  echo "$path"
}

# hc validates terminal names: 1-32 of [a-z0-9_-] (and not one that reads like an address,
# see hc_terminal_name). Repo names are not so constrained — `work jkrumm.com` is
# normalised here, before anything is created.
agent_name() {
  local s
  s=$(printf %s "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  s=$(printf %s "$s" | sed 's/^[^a-z]*//')
  printf %s "${s:0:32}"
}

# --- the factory ---------------------------------------------------------------
#
# `wave`, `fan`, `say` and `close` go through the software factory when it answers, and spawn onto hc directly
# when it does not (docs/remote-dev.md §rd and the factory). A dead factory must never stop the waves
# that would repair it, so every call is bounded and every failure before a spawn exists falls back.
FACTORY_HEALTH_S=3
FACTORY_CALL_S=15
FACTORY_UP=""

# Run `factory <args…>` on the dev host, bounded by <secs>. rc 124 = timed out, 127 = not installed, 126 = the host
# has no timeout binary (`timeout` or Homebrew's `gtimeout`; RD_TIMEOUT_CMDS overrides the names): an unbounded call
# could hang a wave that would repair the factory, so without a bound there is no factory path.
factory_host() { # <secs> <args…>
  local secs=$1 args="" a; shift
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  host_run "PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:\$HOME/.bun/bin:\$PATH\"; t=''; for c in ${RD_TIMEOUT_CMDS:-timeout gtimeout}; do t=\$(command -v \$c) && break; done; [ -n \"\$t\" ] || exit 126; \$t $secs ${FACTORY_NO_PARENT:+env -u FACTORY_SESSION }factory$args </dev/null"
}

# True when the factory answers `factory health` within FACTORY_HEALTH_S. Asked once per command; RD_NO_FACTORY=1
# skips it (the escape hatch for a factory that answers but misbehaves).
factory_up() {
  if [[ -z $FACTORY_UP ]]; then
    FACTORY_UP=0
    [[ ${RD_NO_FACTORY:-} == 1 ]] || ! factory_host "$FACTORY_HEALTH_S" health >/dev/null 2>&1 || FACTORY_UP=1
  fi
  [[ $FACTORY_UP == 1 ]]
}

# jq over a `factory … --format json` body. Ids may come as strings or {id|name} objects.
FACTORY_JQ_DEFS='def s: if type == "object" then (.id // .name // empty) else . end | tostring;'
factory_field() { # <json> <jq expression>
  jq -r "$FACTORY_JQ_DEFS $2" <<<"$1" 2>/dev/null
}
# Why a spawn failed: `.error` is a string, or an object with a message.
factory_error() { # <json>
  factory_field "$1" '(.error | strings) // (.error | objects | .message) // "no reason given"'
}

# Create a spawn through the factory (idempotent by key) and wait, bounded by RD_FACTORY_WAIT_S (120 s), until
# it has started. The factory picks the account and starts the pane; it also delivers the prompt.
#   return 0  handled — FSPAWN_STATE = started | queued (held: FSPAWN_REASON) | starting (claimed, not
#             started within the wait); FSPAWN_PANE / FSPAWN_ACCOUNT filled when the factory reports them
#   return 1  the spawn failed (FSPAWN_ERR), or the factory went silent after creating it
#   return 2  the factory could not create the spawn: the caller falls back to hc directly
factory_spawn() { # <key> <repo> <prompt> <role> [space]
  local key=$1 repo=$2 prompt=$3 role=$4 space=${5:-} out rc=0 get="" state
  local -a extra=()
  [[ -n $space ]] && extra=(--space "$space")
  FSPAWN_STATE=""; FSPAWN_PANE=""; FSPAWN_ACCOUNT=""; FSPAWN_REASON=""; FSPAWN_ERR=""
  out=$(factory_host "$FACTORY_CALL_S" spawn create "$key" --repo "$repo" --prompt "$prompt" --role "$role" \
    ${extra[@]+"${extra[@]}"} --format json 2>&1) || rc=$?
  if (( rc != 0 )); then
    # hc takes over only when the create certainly did not happen: the call never ran (126/127) or the factory
    # answered with a structured error. A dropped hop or a timeout may come after the factory recorded the spawn
    # (or while it still does), so those look at `spawn get` and otherwise stop - a second pane under the same
    # name is worse than a visible error.
    if (( rc == 126 || rc == 127 )) || jq -e '.error | objects' <<<"$out" >/dev/null 2>&1; then
      echo "rd: factory spawn create failed (exit $rc: $(head -c 200 <<<"$out" | tr '\n' ' ')) - using hc directly" >&2
      return 2
    fi
    local gout
    gout=$(factory_host "$FACTORY_CALL_S" spawn get "$key" --format json 2>&1) || true
    if [[ -z $(factory_field "$gout" '.status // empty') ]]; then
      FSPAWN_ERR="spawn create exited $rc without an answer and the factory did not say whether '$key' exists - 'factory spawn get $key' shows it; not starting a second pane under that name"
      return 1
    fi
  fi

  local deadline=$((SECONDS + ${RD_FACTORY_WAIT_S:-120}))
  while :; do
    get=$(factory_host "$FACTORY_CALL_S" spawn get "$key" --format json 2>/dev/null) || get=""
    state=$(factory_field "$get" '.status // empty')
    case $state in
      started|failed|waiting) break ;;
      queued) [[ -z $(factory_field "$get" '.hold // empty') ]] || break ;; # held; a plain queued spawn is claimed on the next tick
    esac
    (( SECONDS >= deadline )) && break
    sleep "${RD_FACTORY_POLL_S:-2}"
  done
  FSPAWN_PANE=$(factory_field "$get" '(.pane // empty) | s')
  FSPAWN_ACCOUNT=$(factory_field "$get" '(.account // empty) | s')
  # Past this point the spawn exists: nothing below falls back to hc, whatever the status is.
  case $state in
    started) FSPAWN_STATE=started ;;
    queued) FSPAWN_STATE=queued; FSPAWN_REASON=$(factory_field "$get" '.hold // empty'); FSPAWN_REASON=${FSPAWN_REASON:-not claimed yet} ;;
    waiting) FSPAWN_STATE=queued
             FSPAWN_REASON="no capacity$(factory_field "$get" '(.resumeAt // empty) | tostring | " until " + .')" ;;
    starting) FSPAWN_STATE=starting ;;
    failed) FSPAWN_ERR=$(factory_error "$get"); return 1 ;;
    "") FSPAWN_ERR="the factory gave no status for spawn '$key' - 'factory spawn get $key' shows what became of it"; return 1 ;;
    *) FSPAWN_ERR="the factory reported an unknown status '$state' for spawn '$key' - 'factory spawn get $key' shows it"; return 1 ;;
  esac
  return 0
}

# One line for a handled spawn. $1 = what started ("wave 4" / "fan <branch>"), $2 agent, $3 space, $4 path.
factory_spawn_report() {
  local what=$1 agent=$2 space=$3 path=$4
  case $FSPAWN_STATE in
    started) echo "→ $what started: claude '$agent' via the factory, space $space${FSPAWN_PANE:+, pane $FSPAWN_PANE}  ($path)${FSPAWN_ACCOUNT:+  [account $FSPAWN_ACCOUNT]}" ;;
    queued) echo "queued: $FSPAWN_REASON"
            note "   the factory starts '$agent' when it releases the hold · 'factory spawn get $agent' to look" ;;
    *) echo "→ $what claimed by the factory, not started yet: '$agent' in space $space  ($path)"
       note "   'factory spawn get $agent' to look" ;;
  esac
}

# --- agent resolution ----------------------------------------------------------
#
# A token (address, name, repo name, cwd, factory key) resolves to exactly one agent, or the command stops: steering the
# wrong one silently is worse than asking which. A token hc does not know is an error, never a guess. Three states stay
# distinguishable from the error text alone:
#
#   core unreachable        → `require_core` / `hc_roster`, which name the core
#   up, but token unknown   → `die_no_agent`, which prints the roster
#   token matches several   → `resolve_target`, which lists the candidates

die_no_agent() { # <token>
  local token=$1 hc
  hc=$(hc_roster_text "$HC_ROSTER")
  {
    printf '\033[31merror:\033[0m no agent matches '\''%s'\''\n' "$token"
    if [[ -n $hc ]]; then
      printf '  address one by id or repo name:\n'
      printf '%s\n' "$hc"
    else
      printf "  herdr-core is running on %s with no agents at all — 'rd work <repo>' starts one\n" "$HOST"
    fi
  } >&2
  exit 1
}

# Resolve to exactly one hc agent or exit. Sets TARGET (an hc address) and leaves HC_ROSTER behind for the caller.
resolve_target() { # <token>
  local token=$1 hits n
  hc_roster
  hits=$(hc_match "$token" "$HC_ROSTER")
  n=$(printf '%s\n' "$hits" | grep -c . || true)
  if (( n == 1 )); then TARGET=$hits; return 0; fi
  if (( n > 1 )); then
    { printf '\033[31merror:\033[0m '\''%s'\'' matches %s agents — address one by id:\n' "$token" "$n"
      hc_roster_text "$HC_ROSTER" $hits; } >&2
    exit 1
  fi
  die_no_agent "$token"
}

# --- subcommands -------------------------------------------------------------

cmd_repos() {
  local filter="${1:-}"
  # shellcheck disable=SC2016  # $HOME/$d/$n expand on the dev host, not here
  host_run 'for r in "$HOME/SourceRoot" "$HOME/IuRoot"; do
      [ -d "$r" ] || continue
      for d in "$r"/*/; do
        [ -d "$d/.git" ] || continue
        n=$(basename "$d")
        b=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
        dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d " ")
        printf "%-14s %-30s %-22s %s\n" "$(basename "$r")" "$n" "$b" \
          "$([ "$dirty" != 0 ] && echo "±$dirty" || echo "")"
      done
    done' | if [[ -n $filter ]]; then grep -i -- "$filter"; else cat; fi
}

# `--kind claude` (opencode is rejected) for `work` and `wave`: sets AGENT_KIND and leaves the
# remaining words in REST. Flags are consumed only in the two slots the usage
# lines allow — before the repo and right after it. The first word after that
# starts the prompt, so a prompt that itself contains `--kind` stays intact.
AGENT_KIND=claude
REST=()
# Consume leading --kind flags from "$@"; sets FLAGS_USED to the words eaten.
parse_kind_flags() {
  FLAGS_USED=0
  while (( $# )); do
    case $1 in
      --kind)   [[ -n ${2:-} ]] || die "--kind needs a value (claude)"; AGENT_KIND=$2; shift 2; FLAGS_USED=$((FLAGS_USED+2)) ;;
      --kind=*) AGENT_KIND=${1#--kind=}; shift; FLAGS_USED=$((FLAGS_USED+1)) ;;
      --role)   [[ -n ${2:-} ]] || die "--role needs a value (mother|lead|wave|worker|mechanical)"; ROLE=$2; shift 2; FLAGS_USED=$((FLAGS_USED+2)) ;;
      --role=*) ROLE=${1#--role=}; [[ -n $ROLE ]] || die "--role needs a value (mother|lead|wave|worker|mechanical)"; shift; FLAGS_USED=$((FLAGS_USED+1)) ;;
      *)        break ;;
    esac
  done
}
parse_kind() {
  REST=()
  parse_kind_flags "$@"
  shift "$FLAGS_USED"
  if (( $# )); then
    REST+=("$1"); shift
    parse_kind_flags "$@"
    shift "$FLAGS_USED"
    (( $# )) && REST+=("$@")
  fi
  case $AGENT_KIND in
    claude) ;;
    opencode) die "--kind opencode is gone: Herdr agents run on the Max subscriptions only, never IU API tokens" ;;
    *) die "unknown --kind '$AGENT_KIND' — only claude" ;;
  esac
}

# Account for a bulk spawn (docs/claude-accounts.md): `claude-account pick --lane <lane>` on the host.
# Sets PICK_ENV (an array of KEY=VALUE pairs for the spawn's `env`: CLAUDE_CONFIG_DIR for a Claude account, absent for iu;
# the CLAUDE_ACCOUNT_PICKED marker, set for every non-spill pick, iu included, makes a `claude` wrapper skip a second
# pick so one spawn = one pick-log line; CLAUDE_ACCOUNT_REASON, the picker's reason for the statusline, rides along),
# PICK_SPILL (1 = no Claude account has room: the caller pauses — never IU),
# PICK_NOTE (the pick reason, for the output line) and PICK_ID (the account id). A failing picker means
# "default account", never a failed spawn.
pick_account() {
  local lane=$1 out line why
  PICK_ENV=(); PICK_SPILL=0; PICK_NOTE="default account (picker unavailable)"; PICK_ID=iu; PICK_REASON=""
  local rc=0
  out=$(host_run "PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:\$HOME/.bun/bin:\$PATH\" claude-account pick --lane '$lane' --why" 2>/dev/null) || rc=$?
  line=$(sed -n 1p <<<"$out"); why=$(sed -n 2p <<<"$out")
  PICK_ID=$(sed -n 's/^# picked=\([a-z][a-z0-9-]*\).*/\1/p' <<<"$why"); PICK_ID=${PICK_ID:-iu}
  PICK_REASON=$(sed -n 's/^# picked=[a-z][a-z0-9-]* reason=\([a-z][a-z0-9-]*\).*/\1/p' <<<"$why")
  # exit 4: registry unreadable. The pick still answered iu, but the line says why.
  (( rc == 4 )) && { why="# reason=registry-error"; PICK_REASON=registry-error; }
  case $line in
    spill)
      PICK_SPILL=1; PICK_NOTE="no Claude account has room (${why#\# })" ;;
    "export CLAUDE_CONFIG_DIR="*)
      local dir=${line#export CLAUDE_CONFIG_DIR=}; dir=${dir#\'}; dir=${dir%\'}
      PICK_ENV=("CLAUDE_CONFIG_DIR=$dir"); PICK_NOTE="${why#\# }" ;;
    "unset CLAUDE_CONFIG_DIR")
      PICK_NOTE="${why:+${why#\# }}"; PICK_NOTE=${PICK_NOTE:-default account} ;;
  esac
  (( PICK_SPILL )) && return 0
  PICK_ENV+=("CLAUDE_ACCOUNT_PICKED=$PICK_ID")
  [[ -n $PICK_REASON ]] && PICK_ENV+=("CLAUDE_ACCOUNT_REASON=$PICK_REASON")
  return 0
}

# `work` is idempotent on purpose. Two Claude agents in one checkout race each
# other's edits — the same hazard the CLAUDE.md file-ownership rule describes,
# except across terminals where you cannot see it happening. So a second `work argo`
# reports the first rather than stacking a terminal on the same tree.
cmd_work() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  [[ -n $name ]] || die "usage: work <repo> [--kind claude] [--role R]   (see 'repos')"
  require_core

  local path
  path=$(resolve_repo "$name") \
    || die "no git repo named '$name' under ~/SourceRoot or ~/IuRoot on $HOST — try 'repos $name'"

  local existing
  hc_roster
  existing=$(hc_match "$path" "$HC_ROSTER" | head -1)

  if [[ -n $existing ]]; then
    echo "→ already running: agent $existing  ($path)"
    note "   'rd read $existing' to see it, or open the Herdr app"
    return 0
  fi

  local agent
  agent=$(agent_name "$name")
  [[ -n $agent ]] || die "'$name' has no usable agent name — rename the repo or start it by hand"

  # `work` passes a model and effort only when --role asks for them; otherwise today's bare start. Resolved
  # before anything is created: an unknown role is a usage error, not a half-made terminal.
  if [[ -n $ROLE ]]; then rd_spawn_flags "" ""; fi

  # A human sits in front of this one, so no --dangerously-skip-permissions and no prompt.
  pick_account interactive
  (( PICK_SPILL )) && die "paused: $PICK_NOTE. Retry after a reset; work never spills to IU API tokens"
  hc_start_agent "$agent" "$path" "$ROLE" "" 0 "" tab "$path" || die "$HC_START_ERR"
  echo "→ started $AGENT_KIND '$agent' as $SPAWNED_ADDR in space $SPAWNED_SPACE  ($path)${PICK_NOTE:+  [$PICK_NOTE]}"
  note "   'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
}

# The wave-chaining lane: near-twin of `work`, for an agent that has just
# finished a wave and needs to hand off to a fresh one rather than continue in
# its own (increasingly long) context. Four differences from `work`:
#
#   1. A TAB in the repo's existing space, not a new space: the labels
#      `herdr.space` + `herdr.tab` place the terminal (docs/herdr-core.md §Spawn
#      contract) and a wave reads as "wave N of this repo". The tab has no
#      parent: a child would end with the wave that spawned it, so a chain's
#      next wave must not be one. (An orchestrated wave keeps the caller as
#      parent: its lead waits on it with `hc wait --children`.)
#   2. Solo mode. `--dangerously-skip-permissions` is in claude's argv, because
#      an unattended wave has no one to answer a permission prompt. `work`
#      deliberately omits it — that terminal has a human sitting in front of it.
#   3. It submits a prompt. `work` hands you an empty terminal; `wave` is the
#      automated form of "open a tab, start claude solo, paste the handover" —
#      the prompt is claude's last argument, so there is nothing to type later.
#   4. It is bounded. See RD_WAVE_MAX below — a wave that can spawn its own
#      successor is exactly the shape of a chain with no natural end.
cmd_wave() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  local prompt="${REST[*]:1}"
  [[ -n $name && -n $prompt ]] || die "usage: wave <repo> [--kind claude] [--role R] <prompt…>"
  require_core

  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST — try 'repos $name'"

  # The green gate, mechanical half (scripts/wave-gate.py owns the rest of the
  # rationale). A cross-repo chain's prompt names its shared plan by absolute
  # path (the estate-review chain's own convention) — pull that out of the
  # prompt if present, otherwise the plan lives at the default in-repo
  # location the skill documents. Expansion of `~` and relative-to-$path both
  # happen ON THE HOST inside wave-gate.py, since $HOME differs there.
  local plan_ref
  plan_ref=$(grep -oE '[~/][^[:space:]]*docs/waves/PLAN\.md' <<<"$prompt" | head -1)
  [[ -n $plan_ref ]] || plan_ref="docs/waves/PLAN.md"
  # plan_ref comes out of free-text prompt content, not a resolved path — unlike
  # $path (a directory resolve_repo already proved exists), it is not safe to
  # trust into a quoted string that host_run hands to a shell. Restricting it to
  # a safe character set before it ever reaches host_run closes that off, rather
  # than relying on the single-quoting alone.
  [[ $plan_ref =~ ^[A-Za-z0-9~/_.-]+$ ]] \
    || die "plan reference extracted from the wave prompt has unsafe characters: $plan_ref"
  # Orchestrated only on exactly `=1` — `RD_ORCHESTRATED=0` or an empty-ish
  # leftover must not silently drop the gate's outward-facing keyword stop.
  local gate_out orch_flag=""
  [[ ${RD_ORCHESTRATED:-} == 1 ]] && orch_flag="--orchestrated"
  gate_out=$(host_run "python3 \"\$HOME/SourceRoot/dotfiles/scripts/wave-gate.py\" $orch_flag $(printf '%q' "$path") $(printf '%q' "$plan_ref")" 2>&1) \
    || die "green gate failed for $path:"$'\n'"$gate_out"
  [[ -z $gate_out ]] || echo "$gate_out" >&2 # a pass can still say a check was skipped (the factory queue)

  # The roster: it is read ONCE and fails closed. An unreadable one must not read as "no live agents" and let a
  # duplicate name through (hc_roster dies when the core does not answer).
  hc_roster

  # Wave numbers in use = live terminals whose name is the one `<repo>-w<n>` would get. Each candidate number is turned
  # into its terminal name (hc_terminal_name hashes the FULL key, so a repo starting `t<digit>`, whose name hc makes
  # unrecognisable, is still counted) and looked up among the live names, instead of parsing names back. depth (what
  # RD_WAVE_MAX bounds) = the numbers in use + 1; n = the next free one. Numbers above 99 are not looked at.
  wave_agent_name() { # <n> — `agent_name` clips at 32 (the terminal name cap); the wave suffix is clipped for first
    local s="-w$1"
    printf '%s' "${WAVE_BASE:0:$((32 - ${#s}))}${s}"
  }
  WAVE_BASE="$(agent_name "$name")"
  wave_live() { # <n> — is that wave's terminal name a live one? (live_names: dynamic scope)
    grep -qxF "$(hc_terminal_name "$(wave_agent_name "$1")")" <<<"$live_names"
  }
  local live_names num depth=1 n=1 max=0
  live_names=$(jq -r '.[] | .name // empty' <<<"$HC_ROSTER")
  for num in $(seq 1 99); do
    wave_live "$num" || continue
    depth=$((depth + 1)); max=$num
  done
  n=$((max + 1))

  # The label and agent name carry the PLAN's wave number ("Execute the active wave (Wave 7)"),
  # not the counter. No "(Wave N)" in the prompt (an ad-hoc spawn) falls back to the counter.
  # RD_WAVE_MAX still bounds the counter (spawn depth), not the plan's numbering.
  local wnum=$n explicit=0
  if [[ $prompt =~ \(Wave\ ([0-9]+)\) ]]; then wnum=${BASH_REMATCH[1]}; explicit=1; fi

  # An agent that can spawn its own successor is exactly the shape of a chain
  # with no natural end. RD_WAVE_MAX is the backstop — the failure mode this
  # guards against is not "one wave too many", it is "did not stop".
  local wave_max=${RD_WAVE_MAX:-10}
  (( depth <= wave_max )) \
    || die "wave $depth would exceed RD_WAVE_MAX=$wave_max — refusing to keep an unbounded self-spawning chain going"

  # Same hazard `work`'s comment describes: two agents editing one checkout race
  # each other. But the CALLER is the orchestrator (or a finishing wave handing
  # over) and hc still reports it `working` because it is mid-turn — so an
  # unqualified check refuses the command's primary use case. The caller's own
  # terminal is excluded (a Bash tool or subagent running inside it is the same
  # operator, not a second editor). Any OTHER live agent in that checkout is still a
  # hard stop; an idle or done predecessor is what a finished wave looks like.
  local busy
  local self_hc=""
  if on_dev_host; then self_hc=${HC_TERMINAL_ID:-}; fi # another machine's ids are not ours
  busy=$(jq -r --arg cwd "$path" --arg self "$self_hc" "$HC_JQ_DEFS"'[.[] | select(agent and .cwd == $cwd and .address != $self
      and ((.status.state // "") | IN("idle", "done") | not))] | .[0] | select(. != null) | "\(.address) \(.status.state // "unknown")"' <<<"$HC_ROSTER" 2>/dev/null)
  [[ -z $busy ]] \
    || die "another agent in $path is ${busy#* } (${busy%% *}) — two agents editing one checkout race each other"

  # Two agents on one name make `rd say/read` hit the wrong one, so the counter skips numbers whose name is live;
  # the plan's explicit number is authoritative and dies.
  local agent
  if (( explicit )); then
    wave_live "$wnum" \
      && die "agent '$(wave_agent_name "$wnum")' is already live — 'rd read' it or 'rd close' it before respawning wave $wnum"
  else
    while wave_live "$wnum"; do wnum=$((wnum + 1)); done
  fi
  agent="$(wave_agent_name "$wnum")"

  # Model and effort before anything is created: an unknown --role is a usage error. A wave is the `wave`
  # role unless told otherwise; unattended work defaults to Sonnet when the role table is unreachable.
  rd_spawn_flags wave sonnet

  # The factory, when it answers, picks the account and queues what has no room; otherwise the account is
  # picked once per spawn here, and no room means pause, never IU.
  local use_factory=0
  # An orchestrated wave from an owner's own session goes hc-direct, like fan: the lead must be its child to wait on it.
  [[ -z ${RD_DRY_RUN:-} ]] && ! { [[ ${RD_ORCHESTRATED:-} == 1 ]] && owner_session; } && factory_up && use_factory=1
  PICK_ENV=(); PICK_NOTE=""; PICK_SPILL=0
  if [[ $AGENT_KIND == claude ]] && (( ! use_factory )); then
    pick_account wave
  fi
  (( PICK_SPILL )) && die "paused: $PICK_NOTE. Retry after a reset; waves never spill to IU API tokens"

  # Everything above can be wrong before anything gets created — RD_DRY_RUN
  # stops here for the same reason `say` stops before the send.
  if [[ -n ${RD_DRY_RUN:-} ]]; then
    [[ -n $PICK_NOTE ]] && echo "account pick (wave): $PICK_NOTE${PICK_ENV[*]:+ [${PICK_ENV[*]}]} -> kind $AGENT_KIND"
    local dry_space
    dry_space=$(hc_space_id "$path") || exit 1
    echo "would add tab 'tb-$(sha12 "$agent")' ($agent) to space $dry_space ($name) at $path"
    echo "would start agent '$agent' solo in it with the prompt as claude's argument${SPAWN_MODEL_FLAG}${SPAWN_EFFORT_FLAG}"
    return 0
  fi

  if (( use_factory )); then
    [[ -z ${RD_WAVE_MODEL:-}${RD_WAVE_EFFORT:-} ]] \
      || echo "rd: RD_WAVE_MODEL / RD_WAVE_EFFORT do not reach a factory spawn - the role table decides" >&2
    # A chain wave's successor is not its worker: with the caller as parent, the send-back would hold the finishing
    # wave's Stop until its successor ends. Orchestrated waves are the orchestrator's workers and keep the parent.
    local frc=0 no_parent=1
    [[ ${RD_ORCHESTRATED:-} == 1 ]] && no_parent=""
    FACTORY_NO_PARENT=$no_parent factory_spawn "$agent" "$path" "$prompt" "${ROLE:-wave}" || frc=$?
    case $frc in
      0) factory_spawn_report "wave $wnum" "$agent" "$path" "$path"; return 0 ;;
      1) die "factory spawn '$agent' failed: $FSPAWN_ERR" ;;
    esac
    # The factory could not take it: hc directly, with the pick the factory would have made.
    if [[ $AGENT_KIND == claude ]]; then pick_account wave; fi
    (( PICK_SPILL )) && die "paused: $PICK_NOTE. Retry after a reset; waves never spill to IU API tokens"
  fi

  # Unattended work defaults to Sonnet (claude): the settings.json model is whatever `/model` last left the interactive
  # session on (Fable today), and that is the wrong default exactly where no one is watching. A chain that wants another
  # model says so per chain (`RD_WAVE_MODEL`).
  local where="tab"
  if [[ ${RD_ORCHESTRATED:-} == 1 ]]; then where="tab-child"; fi
  hc_start_agent "$agent" "$path" "${ROLE:-wave}" wave 1 "$prompt" "$where" "$path" || die "$HC_START_ERR"
  echo "→ wave $wnum started: $AGENT_KIND '$agent' as $SPAWNED_ADDR in space $SPAWNED_SPACE  ($path)${PICK_NOTE:+  [$PICK_NOTE]}"
  note "   'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
  [[ $where == tab-child ]] && note "   a child of this terminal: its notes arrive as input, 'hc wait --children all' waits for it"
  return 0
}

# Fan-out: one worktree + one Claude per brief file, each a hidden child of the calling terminal ($HC_TERMINAL_ID:
# no labels, so the app lists it as a sub-agent of the orchestrator, not as a tab; the orchestrator gets the workers'
# notes and waits with `hc wait --children`). Without a calling terminal on the dev host a worker is a tab of the repo's space.
# Each brief declares its branch on a `Branch: <name>` line (the brief template's "exact
# branch" field). Worktrees are cut from FETCHED origin state by scripts/fan-worktree.sh and
# the brief is prefixed with that base, so a stale or ahead local checkout cannot brief a
# worker against the wrong tree. `rd fan --clean <repo>` reclaims merged worktrees rd fan
# created (marked at creation); `--all` also judges worktrees without the marker.
cmd_fan() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  [[ -n $name ]] || die "usage: fan <repo> [--kind K] [--role R] <brief-file…>   |   fan --clean <repo> [--all]"
  if [[ $name == --clean ]]; then fan_clean "${REST[@]:1}"; return; fi
  local briefs=("${REST[@]:1}")
  (( ${#briefs[@]} )) || die "usage: fan <repo> [--kind K] [--role R] <brief-file…>"
  require_core

  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST — try 'repos $name'"

  # Validate every brief before anything is created: a typo in the third must not leave
  # two worktrees and two running agents behind.
  local b branch seen=" "
  for b in "${briefs[@]}"; do
    [[ -r $b ]] || die "brief '$b' is not readable"
    branch=$(sed -n 's/^Branch:[[:space:]]*\([A-Za-z0-9._/-]*\)[[:space:]]*$/\1/p' "$b" | head -1)
    [[ -n $branch ]] || die "brief '$b' has no 'Branch: <name>' line"
    [[ $seen == *" $branch "* ]] && die "two briefs claim branch '$branch'"
    seen+="$branch "
  done

  # One lookup per `rd fan`, before the first worktree: every worker is the `worker` role unless told otherwise.
  rd_spawn_flags worker sonnet

  # An owner's own session on the dev host (a calling terminal, no FACTORY_SESSION) fans out hc-direct: the workers are
  # its hidden children, which it can `hc wait --children` on. The factory would make them parentless tabs.
  local direct=0 n_factory=0 n_direct=0
  local -a tab_addrs=()
  if owner_session; then direct=1; fi
  factory_ok() { (( ! direct )) && factory_up; }

  local base_kind=$AGENT_KIND parent_note
  parent_note="a hidden child of ${HC_TERMINAL_ID:-<no calling terminal: a tab>}"
  if [[ -n ${RD_DRY_RUN:-} ]]; then
    PICK_ENV=(); PICK_NOTE=""
    [[ $base_kind == claude ]] && pick_account fan
    for b in "${briefs[@]}"; do
      echo "would fan '$b' -> worktree + $parent_note${SPAWN_MODEL_FLAG}${SPAWN_EFFORT_FLAG}${PICK_NOTE:+  [account pick (fan): $PICK_NOTE${PICK_ENV[*]:+ ${PICK_ENV[*]}}]}"
    done
    return 0
  fi

  local wt out base sha agent prompt fan_failed=0 frc
  for b in "${briefs[@]}"; do
    # One pick per spawn: each fan agent is a fresh context, so each is a re-pick point (invariant 1
    # only forbids switching a live session). No room pauses the spawn. A factory that answers picks the
    # account itself and queues what has no room, so the pick is only ours on the hc path.
    AGENT_KIND=$base_kind; PICK_ENV=(); PICK_NOTE=""; PICK_SPILL=0
    if [[ $AGENT_KIND == claude ]] && ! factory_ok; then
      pick_account fan
      if (( PICK_SPILL )); then
        die "paused: $PICK_NOTE. Not started: $b and every brief after it. fan never spills to IU API tokens"
      fi
    fi
    branch=$(sed -n 's/^Branch:[[:space:]]*\([A-Za-z0-9._/-]*\)[[:space:]]*$/\1/p' "$b" | head -1)
    out=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-worktree.sh\" $(printf '%q' "$path") $(printf '%q' "$branch")" 2>&1) \
      || die "worktree for '$branch' failed:"$'\n'"$out"
    wt=$(sed -n 1p <<<"$out"); base=$(sed -n 2p <<<"$out"); sha=$(sed -n 3p <<<"$out")
    host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-list.sh\" --mark $(printf '%q' "$path") $(printf '%q' "$wt")" >/dev/null 2>&1 \
      || note "   could not mark $wt as fan-made — 'rd fan --clean $name' will keep it"

    # The agent name is fixed before the terminal exists: FACTORY_SESSION rides the spawn.
    local leaf plen
    leaf=$(agent_name "${branch##*/}"); leaf=${leaf:0:20}
    plen=$((31 - ${#leaf})); (( plen < 1 )) && plen=1
    agent="$(agent_name "$name")"
    agent="${agent:0:$plen}-${leaf}"

    prompt="Base: $base @ $sha (fetched just now; your worktree is cut from it, ignore the live checkout's local state)."$'\n\n'"$(cat "$b")"

    # Through the factory: the space is the main checkout's, the worktree is where the session works.
    if factory_ok; then
      [[ -z ${RD_WAVE_MODEL:-}${RD_WAVE_EFFORT:-} ]] \
        || echo "rd: RD_WAVE_MODEL / RD_WAVE_EFFORT do not reach a factory spawn - the role table decides" >&2
      frc=0
      factory_spawn "$agent" "$wt" "$prompt" "${ROLE:-worker}" "$path" || frc=$?
      case $frc in
        0) factory_spawn_report "fan $branch" "$agent" "$path" "$wt"; n_factory=$((n_factory + 1)); continue ;;
        1) note "   factory spawn '$agent' failed: $FSPAWN_ERR (worktree kept — 'factory spawn get $agent' first, then 'rd fan --clean $name' reclaims it)"
           fan_failed=1; continue ;;
      esac
      pick_account fan
      if (( PICK_SPILL )); then
        die "paused: $PICK_NOTE. Not started: $b and every brief after it. fan never spills to IU API tokens"
      fi
    fi

    # One failed spawn is reported and the next brief still goes; the exit code says so at the end.
    if ! hc_start_agent "$agent" "$wt" "${ROLE:-worker}" fan 1 "$prompt" child "$path"; then
      note "   $HC_START_ERR (worktree kept — 'rd agents' first, then 'rd fan --clean $name' reclaims it)"
      fan_failed=1; continue
    fi
    if [[ $SPAWNED_WHERE == child ]]; then n_direct=$((n_direct + 1)); else tab_addrs+=("$SPAWNED_ADDR"); fi
    echo "→ fan: $AGENT_KIND '$agent' on $branch as $SPAWNED_ADDR  ($wt)${PICK_NOTE:+  [$PICK_NOTE]}"
  done
  # The wait differs per group: a held factory spawn has no hc terminal yet, so hc would return before it starts.
  # A worker that became a tab (no calling terminal, or its parent was gone) is nobody's child: `hc wait <addr>`.
  local -a hints=()
  (( n_factory )) && hints+=("'factory session wait --on workers' (factory spawns)")
  (( n_direct )) && hints+=("'hc wait --children all' (hc-direct children)")
  local ta
  for ta in ${tab_addrs[@]+"${tab_addrs[@]}"}; do hints+=("'hc wait $ta' (a tab, not a child)"); done
  local wait_hint="'rd agents'" h first=1
  for h in ${hints[@]+"${hints[@]}"}; do
    if (( first )); then wait_hint=$h; first=0; else wait_hint+=" · $h"; fi
  done
  note "   'rd agents' to watch · $wait_hint to wait · 'rd merge $name <branch…>' to land · 'rd fan --clean $name' after"
  (( ! fan_failed )) || die "at least one spawn failed (above); the others were started"
}

# Reclaim fan worktrees whose branch is fully merged into origin's default and whose tree
# is clean: end the agent's terminal, remove the worktree (through wtp when the repo has one),
# delete the branch. Anything unmerged or dirty is listed and left alone, and so is every
# worktree rd fan did not create (no marker) unless --all.
fan_clean() {
  local name="" all="" a
  for a in "$@"; do
    case $a in
      --all) all=--all ;;
      *) [[ -z $name ]] || die "usage: fan --clean <repo> [--all]"; name=$a ;;
    esac
  done
  [[ -n $name ]] || die "usage: fan --clean <repo> [--all]"
  require_core
  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST"
  hc_roster
  local rows wt br addr st prog qwt qbr verb reason
  rows=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-list.sh\" $all $(printf '%q' "$path")" 2>&1) \
    || die "could not list worktrees of $path: $rows"
  [[ -n $rows ]] || { echo "no extra worktrees for $name"; return 0; }
  while IFS=$'\t' read -r verb wt br reason; do
    [[ -n $verb ]] || continue
    if [[ $reason == no-marker ]]; then echo "keep  $br (not created by rd fan, or made before the marker; --all overrides)  $wt"; continue; fi
    if [[ $verb == keep ]]; then echo "keep  $br ($reason)  $wt"; continue; fi
    # EVERY agent in the worktree is judged, not the first one: finished means a known idle/done status. Null, unknown,
    # starting, working and blocked all keep the worktree.
    local -a addrs=()
    local unfinished="" killfail=0
    local rec
    while IFS= read -r rec; do
      [[ -n $rec ]] || continue
      addr=$(jq -r .address <<<"$rec"); st=$(jq -r '.status.state // "unknown"' <<<"$rec"); prog=$(jq -r "$HC_JQ_DEFS"'prog' <<<"$rec")
      # Only an rd/factory agent (claude is its own or its foreground program, with an ownership marker) may be ended;
      # anything else in the worktree is somebody's shell or hand-started session and keeps it.
      [[ $prog == claude ]] || unfinished+="${unfinished:+, }$addr runs ${prog:-nothing}, not claude"
      if [[ $prog == claude ]] && ! hc_owned "$rec"; then unfinished+="${unfinished:+, }$addr is not an rd agent"; fi
      is_finished_status "$st" || unfinished+="${unfinished:+, }$addr $st"
      addrs+=("$addr")
    done < <(jq -c --arg wt "$wt" '.[] | select(.cwd == $wt)' <<<"$HC_ROSTER" 2>/dev/null)
    if [[ -n $unfinished ]]; then echo "keep  $br (agent not finished: $unfinished)  $wt"; continue; fi
    [[ -n ${RD_DRY_RUN:-} ]] && { echo "would remove $br  $wt"; continue; }
    # The worktree goes only once every terminal in it is gone: an already-finished one may refuse the kill, but its rm must work.
    for addr in ${addrs[@]+"${addrs[@]}"}; do
      hc_host kill -- "$addr" >/dev/null 2>&1
      hc_host rm -- "$addr" >/dev/null 2>&1 || killfail=1
    done
    if (( killfail )); then echo "keep  $br (could not end every terminal in it — 'rd agents')  $wt"; continue; fi
    qwt=$(printf '%q' "$wt"); qbr=$(printf '%q' "$br")
    host_run "git -C $(printf '%q' "$path") worktree remove $qwt && git -C $(printf '%q' "$path") branch -D $qbr" >/dev/null 2>&1 \
      && echo "removed $br  $wt" || echo "keep  $br (remove failed)  $wt"
  done <<<"$rows"
}

# Merge train: scripts/merge-train.sh runs on the host (GitHub only, rebase/fast-forward only).
cmd_merge() {
  local name=${1:-}; shift || true
  [[ -n $name && $# -gt 0 ]] || die "usage: merge <repo> [--check '<cmd>'|--no-check] <branch…>"
  local path args="" a
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST"
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/merge-train.sh\" $(printf '%q' "$path")$args"
}

# Close a finished agent — the orchestrator's last step after reading a wave's close-out. Refuses unless it is provably
# finished: started by rd or the factory (claude is the terminal's own program, not something typed into a shell), not
# working/blocked, checkout clean, and nothing unpushed (a branch with no upstream counts as unpushed — the commits would
# exist only in that checkout). Then `hc kill` + `hc rm`: the terminal goes, the repo's other terminals stay.
cmd_close() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: close <agent>   (a finished wave's terminal)"
  require_core
  resolve_target "$name"

  local rec status cwd program
  rec=$(jq -c --arg a "$TARGET" '.[] | select(.address == $a)' <<<"$HC_ROSTER")
  status=$(jq -r '.status.state // ""' <<<"$rec")
  cwd=$(jq -r '.cwd // ""' <<<"$rec")
  program=$(jq -r "$HC_JQ_DEFS"'prog' <<<"$rec") # the foreground program where there is one: a resumed session sits in a kept login shell
  [[ $program == claude ]] \
    || die "$TARGET runs '${program:-nothing}', not claude itself - it was not started by rd or the factory; close it by hand"
  hc_owned "$rec" || die "$TARGET is not an rd agent (no factory key, no rd name) — hc kill it yourself"
  is_finished_status "$status" || die "agent $TARGET is '${status:-unknown}', not idle or done — not known to be finished"

  # Fail closed: an unreadable checkout (ssh failure, no cwd) is not a clean one.
  [[ -n $cwd ]] || die "agent $TARGET reports no cwd — cannot verify the checkout is clean, refusing to close"
  local dirty unpushed status_out
  local qcwd
  qcwd=$(printf '%q' "$cwd")
  status_out=$(host_run "git -C $qcwd status --porcelain") \
    || die "could not read git status of $cwd — refusing to close"
  dirty=$(printf '%s' "$status_out" | grep -c . || true)
  (( dirty == 0 )) || die "$cwd has $dirty uncommitted path(s) — the agent's work is not committed"
  unpushed=$(host_run "git -C $qcwd rev-list --count '@{u}..HEAD' 2>/dev/null || echo no-upstream")
  [[ $unpushed == 0 ]] || die "$cwd has unpushed commits ($unpushed) — push before closing"

  local out
  out=$(hc_host kill -- "$TARGET" 2>&1) || die "hc kill $TARGET failed: $out"
  out=$(hc_host rm -- "$TARGET" 2>&1) || die "hc rm $TARGET failed (still live after the kill?): $out"
  echo "→ closed $(jq -r '.name // .address' <<<"$rec") ($TARGET)"
}

# `claude agents --json` across every enabled Claude account, merged into one JSON array: a background
# daemon is bound to one identity (docs/claude-accounts.md), so one query sees one account's sessions.
# Runs on the dev host (the registry and the claude binary live there).
claude_agents_json() {
  host_run 'python3 - <<"PY"
import json, os, subprocess, sys
reg = os.path.expanduser("~/SourceRoot/dotfiles/config/claude-accounts.json")
try:
    dirs = [a.get("dir") for a in json.load(open(reg))["accounts"].values() if a.get("enabled")]
except Exception as e:
    print(f"rd: claude-accounts registry unreadable ({e}); listing the default account only", file=sys.stderr)
    dirs = [None]
out = []
for d in dirs:
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    if d is not None:
        for k in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
            env.pop(k, None)  # credentials for the default account must not follow another account dir
        env["CLAUDE_CONFIG_DIR"] = os.path.expanduser(d)
    label = d or "default account"
    try:
        r = subprocess.run(["claude", "agents", "--json"], capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(f"rd: claude agents --json failed for {label}: {(r.stderr or r.stdout).strip()[:160]}", file=sys.stderr)
            continue
        out += json.loads(r.stdout)
    except Exception as e:
        print(f"rd: claude agents --json failed for {label}: {e}", file=sys.stderr)
print(json.dumps(out))
PY'
}

# One view over every lane, because "is my work still running" should not depend
# on remembering which lane you started it in. One line per agent: name and status word
# (`working`, `idle`, `done`, `blocked`, …). Tooling greps this text (iris' mother-watch.sh looks for the
# agent names and the word `blocked`), so the shape is a contract: tests pin it.
cmd_agents() {
  require_core
  local hc_json claude_json
  hc_roster
  hc_json=$HC_ROSTER_ALL # the listing includes linked machines (`mini/t3`); every verb that acts does not
  claude_json=$(claude_agents_json)

  HC_JSON="$hc_json" CLAUDE_JSON="$claude_json" python3 <<'PY'
import json, os, datetime

def load(raw, path):
    try:
        d = json.loads(raw)
        for k in path:
            d = d[k]
        return d
    except Exception:
        return []

hc = load(os.environ.get("HC_JSON", ""), [])
claude = load(os.environ.get("CLAUDE_JSON", ""), [])

def short(p):
    return (p or "").replace("/Users/jkrumm/", "~/").replace(
        os.path.expanduser("~") + "/", "~/")

def clip(s, n):
    s = s or "?"
    return s if len(s) <= n else s[: n - 1] + "…"

def is_agent(t):
    # The foreground program first: a Claude resumed inside a kept login shell (argv = zsh) is still an agent.
    argv = (t.get("foreground") or {}).get("argv") or t.get("argv") or [""]
    return t.get("status") is not None or os.path.basename(argv[0] or "") == "claude"

# A Claude running in a hc terminal is ONE process that several lanes report. Deduping on the session id (the
# jk.claude.session label the SessionStart hook sets) keeps it from looking like two agents fighting over one
# checkout, which is a scary thing to see and a wrong thing to believe.
seen = {t.get("labels", {}).get("jk.claude.session") for t in hc}
seen.discard(None)

rows = []
for t in hc:
    if not is_agent(t):
        continue
    status = (t.get("status") or {}).get("state") or ("done" if t.get("turn") else "?")
    rows.append(("hc", clip(t.get("name") or t.get("title") or t.get("address"), 24), status,
                 short(t.get("cwd")), t.get("address", "")))

for a in claude:
    if a.get("sessionId") in seen:
        continue
    bg = a.get("kind") == "background"
    ts = datetime.datetime.fromtimestamp(a["startedAt"] / 1000).strftime("%m-%d %H:%M")
    # A --bg agent is named after its prompt, which is unusable as a column and
    # is not what you address it by anyway — `claude stop` wants the short id.
    ref = (a.get("sessionId") or "")[:8] if bg else ts
    rows.append(("bg" if bg else "interactive", clip(a.get("name"), 24),
                 a.get("status", "?"), short(a.get("cwd")), ref))

if not rows:
    print("  no agents running on the dev host")
else:
    print(f"  {'SOURCE':<12} {'NAME':<26} {'STATUS':<9} {'CWD':<30} {'ID / SINCE'}")
    for lane, name, status, cwd, extra in rows:
        print(f"  {lane:<12} {name:<26} {status:<9} {cwd:<30} {extra}")

    if any(r[0] == "interactive" for r in rows):
        print()
        print("  \033[33mnote:\033[0m 'interactive' agents die with their connection.")
        print("        Long work belongs in 'rd wave' (an hc terminal that outlives the connection).")
PY
}

# Watch without attaching — the reason the socket API matters. Reading an agent
# from the MacBook costs nothing and does not disturb the pane.
cmd_read() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: read <agent>   (see 'agents')"

  # The two lanes need completely different read paths, and getting this wrong
  # was actively misleading: a `claude --bg` daemon hands you a session id, but that id is not
  # an hc terminal — the launcher terminal is gone the moment the daemon exists —
  # so the core answered not-found for an agent that was running perfectly well.
  #
  # `claude logs` is not the alternative. It attaches a full-screen TUI, so it
  # cannot be piped, read from another machine, or used by an agent. The
  # scriptable surface is the session transcript Claude Code already writes per
  # project, which is append-only and readable while the daemon runs.
  local sid
  sid=$(claude_agents_json | TARGET="$name" python3 -c "
import json, os, sys
t = os.environ['TARGET']
try: agents = json.load(sys.stdin)
except Exception: sys.exit(0)
for a in agents:
    if a.get('kind') != 'background':
        continue
    if a.get('id') == t or (a.get('sessionId') or '').startswith(t):
        print(a['sessionId']); break
" 2>/dev/null)

  # $sid is interpolated into a remote shell command below: only a bare session uuid may pass.
  [[ -z $sid || $sid =~ ^[0-9a-f-]{36}$ ]] || die "refusing malformed session id from 'claude agents': '${sid:0:60}'"

  if [[ -n $sid ]]; then
    # shellcheck disable=SC2016  # $HOME expands on the dev host, not here
    host_run "tail -n 300 \"\$(ls -1 \"\$HOME\"/.claude*/projects/*/$sid.jsonl 2>/dev/null | head -1)\" 2>/dev/null" | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") != "assistant": continue
    for b in d.get("message", {}).get("content", []):
        if b.get("type") == "text" and b.get("text", "").strip():
            out.append(b["text"].strip())
        elif b.get("type") == "tool_use":
            out.append("\033[2m· " + str(b.get("name")) + "\033[0m")
print("\n\n".join(out[-12:]) if out else "  (no assistant output yet)")
'
    return 0
  fi

  # Not a bg session, so it is an hc terminal — addressable by repo name here for the same reason `work` is: repo
  # names are what you remember, addresses churn.
  #
  # Resolved only once the bg lane has come up empty: a `--bg` daemon is readable with the core flat on its face (it
  # reparented to PID 1 and its transcript is a file), so gating the whole subcommand on the core would break the
  # one lane built to outlive it.
  require_core
  resolve_target "$name"
  # [src]: a number of history lines above the screen, `visible` for the screen alone, else a default.
  local lines=200
  case ${2:-recent} in
    visible) lines=0 ;;
    ''|*[!0-9]*) ;;
    *) lines=$2 ;;
  esac
  hc_host read --lines "$lines" -- "$TARGET"
}

say_fail() { # $1 agent  $2 reason
  printf '\033[31mNOT delivered:\033[0m %s — check with: rd read %s\n' "$2" "$1" >&2
  exit 1
}

# Steer a running agent without attaching. For an hc terminal the text goes in with `hc send`, which pastes it and
# presses Enter once nobody is typing; a blocked program is refused, because the text would answer its dialog instead
# of reaching the agent. A working agent takes the text as a queued message.
cmd_say() {
  local name="${1:-}"; shift || true
  local text="${*:-}"
  [[ -n $name && -n $text ]] || die "usage: say <agent> <text…>"

  require_core
  resolve_target "$name"

  # Resolution is the whole risk surface here: this types into a live session, so
  # everything that can be wrong should be wrong BEFORE the send, not after it
  # landed in someone else's terminal. RD_DRY_RUN stops exactly here — it is how the
  # resolver gets exercised without steering a running agent.
  [[ -n ${RD_DRY_RUN:-} ]] && { echo "$TARGET"; return 0; }

  local agent key rec status program
  rec=$(jq -c --arg a "$TARGET" '.[] | select(.address == $a)' <<<"$HC_ROSTER")
  agent=$(jq -r '.name // .address' <<<"$rec")
  key=$(jq -r '.labels["factory.key"] // .name // ""' <<<"$rec")
  status=$(jq -r '.status.state // ""' <<<"$rec")

  # The state is checked BEFORE either delivery path (the factory note or hc send): a blocked program would read the text
  # as the answer to its dialog, and one that has not reported is not at a prompt yet. No --force, ever.
  program=$(jq -r "$HC_JQ_DEFS"'prog' <<<"$rec")
  [[ $program == claude ]] \
    || say_fail "$agent" "$TARGET runs '${program:-nothing}', not claude — rd never types prompt text into a shell"
  if [[ $status == blocked ]]; then
    say_fail "$agent" "it is blocked on a dialog, and the text would answer the dialog - 'rd read $agent', answer it by hand"
  fi
  case $status in
    idle|done|working) ;;
    *) say_fail "$agent" "not at a prompt yet (status '${status:-none}') — 'rd read $agent', then say it again" ;;
  esac

  # The factory holds a note while the agent works, types it at its next prompt and confirms it by the next
  # turn, which is what the direct path below can only approximate. An agent without a name is no factory session.
  if [[ -n $key ]] && factory_up; then
    local nrc=0 nout
    nout=$(factory_host "$FACTORY_CALL_S" session note "$key" "$text" 2>&1) || nrc=$?
    case $nrc in
      0) echo "noted: the factory holds it while $agent works and types it at its next prompt"; return 0 ;;
    esac
    # Only a definite "no such session" falls back: any other failure may have recorded the note, and a
    # duplicate instruction is worse than a visible miss.
    if ! factory_not_found "$nout"; then
      say_fail "$agent" "the factory note failed (exit $nrc: $(head -c 200 <<<"$nout" | tr '\n' ' ')), so it may be recorded - not re-sent directly"
    fi
    echo "rd: the factory has no session '$key' - sending directly" >&2
  fi

  local out hrc=0
  out=$(hc_host send -- "$TARGET" "$text" 2>&1) || hrc=$?
  if (( hrc != 0 )); then
    # Only an explicit error answer from the core says nothing was typed. A timeout, a dropped hop or any other exit may
    # come after the text was pasted: never advise a plain retry.
    local ekind
    ekind=$(jq -r '.error.kind // empty' <<<"$out" 2>/dev/null | head -1)
    case $ekind in
      refused|not_found|blocked|status_mismatch|finished)
        say_fail "$agent" "hc send failed: $(head -c 300 <<<"$out" | tr '\n' ' ')" ;;
    esac
    printf '\033[31mdelivery unconfirmed:\033[0m hc send %s — '"'"'rd read %s'"'"' before retrying (a re-send may duplicate it)\n' \
      "$( ((hrc == 124)) && echo "did not answer within ${RD_HC_TIMEOUT_S:-30} s" || echo "ended with exit $hrc and no error answer")" "$agent" >&2
    exit 1
  fi
  if [[ $status == working ]]; then
    echo "queued: agent busy — $agent was working, the message waits behind its turn"
  else
    echo "delivered"
  fi
}

# The janitor: closes finished, clean, pushed terminals; messages dirty ones. All logic lives in
# hc-reap.py (also what com.jkrumm.hc-reap runs); this is the routing hop.
cmd_reap() {
  local args="" a
  for a in "$@"; do
    case $a in
      --dry-run|-n) args+=" --dry-run" ;;
      *) die "usage: reap [--dry-run]   (REAP_IDLE_H=<hours> overrides the 12 h idle threshold)" ;;
    esac
  done
  # shellcheck disable=SC2016  # $HOME expands on the host
  host_run "d=\"\$HOME/SourceRoot/dotfiles/scripts\"; export REAP_IDLE_H='${REAP_IDLE_H:-12}'; \
    python3 \"\$d/hc-reap.py\"$args"
}

usage() {
  cat <<'EOF'

  rd — drive the mini's herdr-core agents from anywhere

    rd repos [filter]         repos on the dev host, with branch + dirty count
    rd work <repo> [--kind K] [--role R]   labelled tab + claude for that repo (idempotent)
    rd wave <repo> [--kind K] [--role R] <prompt…>
                              fresh tab + solo agent, the prompt as claude's argument — claude
    rd fan <repo> [--role R] <brief…>   worktree + hidden child terminal + Claude per brief file (fan-out)
                              (fan --clean <repo> [--all] reclaims merged fan worktrees)
                              --role R: tier + effort from the factory role table (mother|lead|wave|worker|mechanical);
                              wave defaults to wave, fan to worker; RD_WAVE_MODEL / RD_WAVE_EFFORT win over it
    rd merge <repo> <br…>     merge train: rebase, check, merge by rebase, re-rebase (GitHub only)
    rd close <agent>          end a finished agent's terminal (clean + pushed only)
    rd reap [--dry-run]       janitor: close finished clean+pushed tabs (idle > REAP_IDLE_H, default 12; a merged fan tab at once), message dirty ones
    rd agents                 every agent on the host: SOURCE NAME STATUS CWD ID (hc, bg, interactive)
    rd read <agent> [src]     read an agent's output without attaching (src: history lines, or 'visible')
    rd say <agent> <text…>    send a prompt to a running agent (refused while it is blocked on a dialog)

  <agent> is a repo name, an hc address or terminal name (t7, iris-w3) or a bg session id prefix —
  whichever of them 'agents' put in front of you. A name hc does not know is an error.

  Workers started by 'rd fan' are children of the calling terminal: 'hc wait --children all' waits for them
  and their notes arrive as input. A 'rd wave' tab has no parent (a chain's next wave must outlive its
  predecessor); with RD_ORCHESTRATED=1 it keeps the caller as parent.

  Shorthands (read/say stay subcommands — the bare names are a zsh
  builtin, a zsh builtin and /usr/bin/say respectively):

    repos · work · agents

  Two lanes for starting agent work (docs/agent-platform.md):
    @implementer  native subagent — the edit must land in this session's live tree
    wave tab      `rd wave <repo> '<prompt>'` — long work you watch or steer

  Getting a terminal is a different layer:
    the Herdr app (MacBook) · `ssh -t mini hc` as a terminal-only fallback

  It persists on the mini regardless. You only need a terminal to watch.

EOF
}

# Sourced (by the test suite) rather than run: define the functions, dispatch nothing.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

case "${1:-}" in
  repos)  shift; cmd_repos "$@" ;;
  work)   shift; cmd_work "$@" ;;
  wave)   shift; cmd_wave "$@" ;;
  fan)    shift; cmd_fan "$@" ;;
  merge)  shift; cmd_merge "$@" ;;
  close)  shift; cmd_close "$@" ;;
  agents) shift; cmd_agents "$@" ;;
  reap)   shift; cmd_reap "$@" ;;
  read)   shift; cmd_read "$@" ;;
  say)    shift; cmd_say "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand '$1' — run 'rd help'" ;;
esac
