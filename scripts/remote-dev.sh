#!/usr/bin/env bash
set -uo pipefail

# remote-dev — drive the mini's herdr workspaces and Claude agents.
#
# The three-layer model (Tailscale / herdr / Caddy) is about *getting a
# terminal*. This script is the layer above it: preparing and steering the work
# itself, without needing a terminal at all. That distinction is the whole point
# — `desk` is how you go and look; everything here you can do from
# the MacBook while attached to nothing.
#
# Routing is deliberate and invisible: every subcommand runs on the dev host,
# whether you are sitting at it or a hop away. There is one definition of "am I
# the dev host" (the secrets backend marker, same signal `git-headless` and
# `herdr-setup` key off) so the two machines can share one command surface.
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
  SPAWN_MODEL_FLAG=""; SPAWN_EFFORT_FLAG=""
  [[ -n $model ]] && SPAWN_MODEL_FLAG=" --model '$model'"
  if [[ -n $model || -n ${RD_WAVE_EFFORT:-} || -n $ROLE_EFFORT ]]; then
    SPAWN_EFFORT_FLAG=$(rd_effort_flag "$model" "$ROLE_EFFORT") || exit 1 # a bad RD_WAVE_EFFORT dies in the subshell: stop here too
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

# `herdr status | grep -q` reported a dead server against one that was plainly
# running. It is a RACE, not a determinism — measured at roughly half of runs on
# this machine, so it reproduces on demand but not on the first try. Do not
# conclude the fix is unnecessary because one attempt came back clean.
# grep -q exits on the first match, herdr takes the SIGPIPE mid-write and returns 101, and
# `set -o pipefail` hands that up as the pipeline's status. Capture first, match
# second — the pipe was the bug, not the check. (Same trap the AGENTS.md
# heartbeat notes call out; it costs a debugging cycle every time.)
#
# Nothing reached vs reached-but-down are separate messages because the fixes
# are: one is ssh/tailnet, the other is the brew service.
require_server() {
  local out
  out=$(host_run 'herdr status' 2>/dev/null)
  [[ -n $out ]] \
    || die "no answer from herdr on $HOST — nothing ran there at all; check the ssh hop with 'make doctor'"
  grep -q 'status: running' <<<"$out" \
    || die "herdr server is not running on $HOST — 'make herdr-restart YES=1' there, or run 'make doctor'"
}

# Repo names, not paths: the two roots live under a different $HOME on the mini
# ($USER differs), so resolution has to happen on the far side.
resolve_repo() {
  local name=$1 path
  path=$(host_run "for r in \"\$HOME/SourceRoot\" \"\$HOME/IuRoot\"; do
      if [ -d \"\$r/$name/.git\" ]; then echo \"\$r/$name\"; exit 0; fi
    done; exit 1") || return 1
  [[ -n $path ]] || return 1
  echo "$path"
}

# herdr validates agent names: a leading lowercase letter, then only
# [a-z0-9_-], 1-32 chars. Repo names are not so constrained — `work jkrumm.com`
# failed that check *after* the workspace had already been created, so the error
# was both cryptic and left an orphan workspace behind on the host.
agent_name() {
  local s
  s=$(printf %s "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  s=$(printf %s "$s" | sed 's/^[^a-z]*//')
  printf %s "${s:0:32}"
}

# The factory's session key (software-factory docs/design.md §3): the pane is born with
# FACTORY_SESSION=<agent name>, so the account-wide Claude hooks (config/settings.template.json) report
# for rd-spawned sessions and stay silent for every other one. Same spawn-time `--env` path as PICK_ENV.
# $1 = the herdr agent name; agent names are [a-z0-9_-], so no quoting beyond the single quotes.
# $2 = the role the session runs under (FACTORY_ROLE becomes the factory session's role); empty = none.
factory_env() { printf %s "--env FACTORY_SESSION='$1'${2:+ --env FACTORY_ROLE='$2'}"; }

# --- the factory ---------------------------------------------------------------
#
# `wave`, `fan`, `say` and `close` go through the software factory when it answers, and keep the herdr path
# below when it does not (docs/remote-dev.md §rd and the factory). A dead factory must never stop the waves
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
#   return 2  the factory could not create the spawn: the caller falls back to the herdr path
factory_spawn() { # <key> <repo> <prompt> <role> [space]
  local key=$1 repo=$2 prompt=$3 role=$4 space=${5:-} out rc=0 get="" state
  local -a extra=()
  [[ -n $space ]] && extra=(--space "$space")
  FSPAWN_STATE=""; FSPAWN_PANE=""; FSPAWN_ACCOUNT=""; FSPAWN_REASON=""; FSPAWN_ERR=""
  out=$(factory_host "$FACTORY_CALL_S" spawn create "$key" --repo "$repo" --prompt "$prompt" --role "$role" \
    ${extra[@]+"${extra[@]}"} --format json 2>&1) || rc=$?
  if (( rc != 0 )); then
    # Herdr takes over only when the create certainly did not happen: the call never ran (126/127) or the factory
    # answered with a structured error. A dropped hop or a timeout may come after the factory recorded the spawn
    # (or while it still does), so those look at `spawn get` and otherwise stop - a second pane under the same
    # name is worse than a visible error.
    if (( rc == 126 || rc == 127 )) || jq -e '.error | objects' <<<"$out" >/dev/null 2>&1; then
      echo "rd: factory spawn create failed (exit $rc: $(head -c 200 <<<"$out" | tr '\n' ' ')) - using the herdr path" >&2
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
  # Past this point the spawn exists: nothing below falls back to herdr, whatever the status is.
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

# --- herdr agent resolution ---------------------------------------------------
#
# Three states have to stay distinguishable from the error text alone, because
# the machine being debugged is the one with no screen attached:
#
#   herdr unreachable       → `herdr_agent_list`, which names the server
#   up, but token unknown   → `die_no_agent`, which prints the roster
#   token matches several   → `resolve_one_agent`, which lists the candidates
#
# `herdr_match` cannot tell the first two apart — both leave it with zero hits —
# so a dead server used to be reported as "no agent matches '<repo>'" next to an
# empty list, i.e. "your agent died" when the truth was "herdr died". That is the
# same misleading-error class this section exists to remove, just pointed the
# other way. Hence the fetch is validated ONCE, up front, by the function below;
# by the time anything reaches `herdr_match`, zero hits can only mean zero hits.

# Fetch the roster, or die naming the server rather than the agent.
#
# Two things the old `$(host_run 'herdr agent list' 2>/dev/null)` threw away are
# exactly the two that tell a transport failure from an empty tailnet-side
# roster: the exit status (lost inside the command substitution) and stderr
# (redirected to nothing). Both are kept here. A payload that is not
# `result.agents` counts as a failed fetch even when herdr exits 0 — an error
# object parses as JSON perfectly well, and is a worse thing to hand the matcher
# than a crash, because it silently means "no agents".
#
# `require_server` first, deliberately: it is the check with the actionable
# message and it already exists. The validation below is what covers the gap it
# cannot — an ssh hop that dies between the two calls, a herdr that answers
# `status` but not the API, a stale socket.
herdr_agent_list() {
  require_server

  local json rc errfile err line
  errfile=$(mktemp "${TMPDIR:-/tmp}/rd-agents.XXXXXX") || die "mktemp failed"
  json=$(host_run 'herdr agent list' 2>"$errfile"); rc=$?
  # On a screenless machine herdr's error text IS the diagnosis, so say when it
  # has been clipped rather than silently dropping the tail.
  err=$(head -3 "$errfile")
  if (( $(wc -l <"$errfile") > 3 )); then
    err+=$'\n'"  … ($(wc -l <"$errfile" | tr -d ' ') lines total, showing first 3)"
  fi
  rm -f "$errfile"

  if (( rc != 0 )) || ! printf '%s' "$json" | python3 -c '
import json, sys
sys.exit(0 if isinstance(json.load(sys.stdin).get("result", {}).get("agents"), list) else 1)
' 2>/dev/null; then
    {
      printf '\033[31merror:\033[0m could not read the agent roster from %s — the server, not the agent\n' "$HOST"
      if [[ -n $err ]]; then
        printf '  herdr said:\n'
        while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$err"
      fi
      printf "  'herdr agent list' exited %s with no usable roster\n" "$rc"
      printf "  check it: 'make doctor', or 'herdr status' on %s\n" "$HOST"
    } >&2
    exit 1
  fi

  printf '%s' "$json"
}

# ONE matcher for every caller, and it returns PANE IDS, not names.
#
# `herdr agent list` carries no `name` field at all for a hand-started agent —
# only `herdr agent start '<name>'` (what `work` does) assigns one. So the
# obvious `a['name']` was wrong in both directions at once: `agents` printed `?`
# for every row, and `work <repo>` raised KeyError on the first agent it looked
# at, found nothing, and stacked a SECOND claude on a checkout that already had
# one — the precise hazard its own comment says it prevents. Every agent always
# has a pane id, and the socket API accepts one wherever it accepts a name, so
# that is what this returns.
#
# Matches, in any order: a pane id (wG:p6), an agent name, a repo name (the
# basename of the agent's cwd), or a full cwd path. Prints one pane id per
# match, so the caller decides what more-than-one means — for `work` it means
# "already running, focus it", for `read`/`say` it means "say which one".
herdr_match() {
  local token=$1 json=$2
  TOKEN="$token" python3 -c '
import json, os, sys
t = os.environ["TOKEN"]
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    sys.exit(0)
for a in agents:
    cwd = a.get("cwd") or ""
    if t in (a.get("pane_id"), a.get("name"), cwd) or os.path.basename(cwd) == t:
        print(a.get("pane_id") or "")
' <<<"$json" 2>/dev/null | grep -v '^$'
}

# The roster an error message should print: pane id, repo name, task title —
# i.e. every string this script will match on. $2 restricts it to a set of pane
# ids (used when a token was ambiguous rather than unknown).
herdr_roster() {
  local json=$1
  ONLY="${2:-}" python3 -c '
import json, os, sys
only = set(os.environ.get("ONLY", "").split())
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    agents = []
for a in agents:
    pane = a.get("pane_id") or "?"
    if only and pane not in only:
        continue
    cwd = a.get("cwd") or ""
    title = a.get("name") or a.get("terminal_title_stripped") or "?"
    print("    %-8s %-22s %s" % (pane, os.path.basename(cwd) or "?", title))
' <<<"$json" 2>/dev/null
}

# herdr's own `agent_not_found` reads like the agent died. It almost never means
# that — it means the identifier was wrong, which until now you rediscovered by
# trial and error because `agents` printed `?` in the column you'd naturally
# reach for. Name the identifiers that DO work instead.
#
# An empty roster gets its own sentence rather than a heading over nothing. The
# caller has already proved the server is up, so "herdr is running and has no
# agents" is a fact worth stating — the alternative reads as a truncated list and
# sends you looking for a display bug.
die_no_agent() {
  local token=$1 json=$2 roster
  roster=$(herdr_roster "$json")
  {
    printf '\033[31merror:\033[0m no agent matches '\''%s'\''\n' "$token"
    if [[ -n $roster ]]; then
      printf '  address one by pane id or repo name:\n'
      printf '%s\n' "$roster"
    else
      printf "  herdr is running on %s with no agents at all — 'rd work <repo>' starts one\n" "$HOST"
    fi
  } >&2
  exit 1
}

# Resolve to exactly one pane id or exit. Ambiguity is normal here — two agents
# in one checkout happens — and steering the wrong one silently is worse than
# asking which.
resolve_one_agent() {
  local token=$1 json=$2 hits n
  hits=$(herdr_match "$token" "$json")
  n=$(printf '%s\n' "$hits" | grep -c . || true)
  (( n == 1 )) && { printf '%s' "$hits"; return 0; }
  if (( n > 1 )); then
    {
      printf '\033[31merror:\033[0m '\''%s'\'' matches %s agents — address one by pane id:\n' "$token" "$n"
      herdr_roster "$json" "$hits"
    } >&2
    exit 1
  fi
  die_no_agent "$token" "$json"
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
# Sets PICK_ENV (extra `herdr … create` args that put CLAUDE_CONFIG_DIR and the CLAUDE_ACCOUNT_PICKED marker
# into the pane at creation — `--env` repeats, verified live; the marker is set for every non-spill pick, iu
# included; CLAUDE_ACCOUNT_REASON, the picker's reason for the statusline, rides along), PICK_SPILL (1 = no Claude account has room: the caller pauses — never IU),
# PICK_NOTE (the pick reason, for the output line) and PICK_ID (the account id; the marker makes the pane's
# `claude` wrapper skip a second pick, so one spawn = one pick-log line). A failing picker means
# "default account", never a failed spawn.
pick_account() {
  local lane=$1 out line why
  PICK_ENV=""; PICK_SPILL=0; PICK_NOTE="default account (picker unavailable)"; PICK_ID=iu; PICK_REASON=""
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
      PICK_ENV="--env CLAUDE_CONFIG_DIR='$dir'"; PICK_NOTE="${why#\# }" ;;
    "unset CLAUDE_CONFIG_DIR")
      PICK_NOTE="${why:+${why#\# }}"; PICK_NOTE=${PICK_NOTE:-default account} ;;
  esac
  # Spawn-time, with CLAUDE_CONFIG_DIR: the pane's shell never races a typed `export`.
  (( PICK_SPILL )) && return 0
  PICK_ENV="${PICK_ENV:+$PICK_ENV }--env CLAUDE_ACCOUNT_PICKED='$PICK_ID'"
  [[ -n $PICK_REASON ]] && PICK_ENV="$PICK_ENV --env CLAUDE_ACCOUNT_REASON='$PICK_REASON'"
  return 0
}

# Pane-side setup: the claude agent takes the lane tag. `herdr agent start` types the binary
# into the pane shell, so the tag must already be exported there. (The account marker rides PICK_ENV.)
# $1 pane  $2 usage lane
agent_pane_setup() {
  local pane=$1 lane=${2:?agent_pane_setup needs a usage lane}
  host_run "herdr pane run '$pane' export USAGE_LANE='$lane'" >/dev/null 2>&1
}

# `work` is idempotent on purpose. Two Claude agents in one checkout race each
# other's edits — the same hazard the CLAUDE.md file-ownership rule describes,
# except across panes where you cannot see it happening. So a second `work argo`
# focuses the first rather than stacking a workspace on the same tree.
cmd_work() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  [[ -n $name ]] || die "usage: work <repo> [--kind claude] [--role R]   (see 'repos')"
  require_server

  local path
  path=$(resolve_repo "$name") \
    || die "no git repo named '$name' under ~/SourceRoot or ~/IuRoot on $HOST — try 'repos $name'"

  local existing
  existing=$(herdr_match "$path" "$(host_run 'herdr agent list' 2>/dev/null)" | head -1)

  if [[ -n $existing ]]; then
    host_run "herdr agent focus '$existing'" >/dev/null 2>&1
    echo "→ focused existing agent $existing  ($path)"
    note "   already running; 'rd read $existing' to see it, 'desk' to attach"
    return 0
  fi

  local agent
  agent=$(agent_name "$name")
  [[ -n $agent ]] || die "'$name' has no usable herdr agent name — rename the repo or start it by hand"

  # `work` passes a model and effort only when --role asks for them; otherwise today's bare start. Resolved
  # before anything is created: an unknown role is a usage error, not a half-made workspace.
  local start_cmd_tail=""
  if [[ -n $ROLE ]]; then
    rd_spawn_flags "" ""
    [[ -n $SPAWN_MODEL_FLAG$SPAWN_EFFORT_FLAG ]] && start_cmd_tail=" --$SPAWN_MODEL_FLAG$SPAWN_EFFORT_FLAG"
  fi

  local pane
  pane=$(host_run "herdr workspace create --cwd '$path' --label '$name' --no-focus $(factory_env "$agent" "$ROLE")" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
  [[ -n $pane ]] || die "herdr workspace create failed for $path"

  # `herdr workspace create` returns as soon as the pane exists, which is before
  # its shell is up — starting the agent immediately loses the race and reports
  # `agent_pane_busy: not an available shell`. It reads like the pane is
  # occupied, i.e. the exact opposite of the truth. One second is enough in
  # practice; the loop is there so a loaded host degrades into a wait rather
  # than a spurious failure.
  local out="" i=0
  while (( i < 10 )); do
    sleep 1; i=$((i+1))
    out=$(host_run "herdr agent start '$agent' --kind $AGENT_KIND --pane '$pane'$start_cmd_tail")
    echo "$out" | grep -q 'agent_pane_busy' || break
  done

  if echo "$out" | grep -q '"type":"agent_started"'; then
    echo "→ started $AGENT_KIND '$agent' in pane $pane  ($path)"
    note "   'desk' to attach · 'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
  else
    # Roll the workspace back. Leaving it costs a stale entry in every later
    # `herdr workspace list` and, worse, makes the next `work` look like it
    # half-succeeded.
    host_run "herdr workspace close '${pane%%:*}'" >/dev/null 2>&1
    die "agent start failed: $out"
  fi
}

# Hand a prompt to `herdr agent prompt`; prints herdr's body. Returns 0 sent, 2 herdr answered
# with an error body, 3 the transport failed (ssh/herdr exited non-zero — nothing says whether the
# text arrived). base64 carries the text across the ssh hop and herdr's argv handling
# byte-identical (quotes, newlines, a literal `$(...)`); a trailing sentinel keeps `$(…)` from
# stripping trailing newlines and is cut off again on the host. `herdr agent prompt` EXITS 0 ON FAILURE
# and reports it in the body (`{"error":{"code":"agent_not_found",…}}`), so for herdr's own
# answer the body is the signal; a non-zero exit is therefore the hop, not herdr.
# $1 pane  $2 prompt.
send_prompt() {
  local b64 sent rc
  b64=$(printf %sx "$2" | base64 | tr -d '\n')
  sent=$(host_run "rd_p=\$(echo '$b64' | base64 -d); herdr agent prompt '$1' \"\${rd_p%x}\"" 2>&1); rc=$?
  printf '%s' "$sent"
  (( rc == 0 )) || return 3
  grep -q '"error"' <<<"$sent" && return 2
  return 0
}

# "<status> <state_change_seq> <completion_seq>" for an agent, by NAME — the id `herdr agent get`
# is proven with (deliver_prompt has always addressed agents by name; pane ids churn). Returns 1
# when herdr did not answer or the answer carries no status: an unreadable state must never be
# read as idle.
agent_snapshot() {
  local out
  out=$(host_run "herdr agent get '$1'" 2>/dev/null) || return 1
  python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["result"]
    a = r["agent"] if isinstance(r.get("agent"), dict) else r
    status = a["agent_status"]
    assert isinstance(status, str) and status
    print(status, int(a.get("state_change_seq", 0)), int(a.get("completion_seq", 0)))
except Exception:
    sys.exit(1)
' <<<"$out" 2>/dev/null
}

# Delivery signal: ANY state change after the send. A prompt answered fast lands in `blocked`
# (a question) or a fresh `done` (completion_seq bumps) without a poll ever seeing `working`, and
# waiting for `working` alone calls that a loss and invites a duplicate.
# $1 agent id  $2 snapshot taken before the send  $3 window in seconds. Polls every RD_POLL_S
# (whole seconds, default 1); there is no sleep after the last poll.
# Returns 0 changed · 1 ran and saw no change · 2 the last snapshot failed — "no change" is then
# not an observation, and the caller must not treat it as one.
wait_state_change() {
  local now i seen=0 step=${RD_POLL_S:-1} polls=$3
  (( step > 0 )) && polls=$(( ($3 + step - 1) / step ))
  for ((i = 0; i < polls; i++)); do
    if now=$(agent_snapshot "$1"); then
      seen=1
      [[ $now != "$2" ]] && return 0
    else
      seen=0
    fi
    (( i < polls - 1 )) && sleep "$step"
  done
  (( seen )) && return 1
  return 2
}

# THE delivery primitive — `deliver_prompt` and `cmd_say` both go through it, so what counts as
# "delivered" cannot diverge between them. Snapshot, send, wait for a state change.
# $1 pane  $2 agent name  $3 prompt  $4 wait in seconds.
# Returns 0 picked up · 1 never picked up · 2 rejected · 3 transport failure (2 and 3 leave the
# reason in the global DELIVER_ERR) · 4 state unreadable BEFORE the send, nothing sent · 5 the
# agent was already working, so the prompt is queued behind its turn and cannot be proven · 6 sent,
# but the state became unreadable, so delivery is unconfirmed (a re-send could duplicate it).
prompt_attempt() {
  local base sent rc
  base=$(agent_snapshot "$2") || return 4
  sent=$(send_prompt "$1" "$3"); rc=$?
  case $rc in
    2) DELIVER_ERR="herdr rejected the prompt: $sent"; return 2 ;;
    3) DELIVER_ERR="transport failure — the text may or may not have arrived: $sent"; return 3 ;;
  esac
  [[ $base == working\ * ]] && return 5
  wait_state_change "$2" "$base" "$4"; rc=$?
  (( rc == 2 )) && return 6
  return "$rc"
}

# ONE place that words what a failed or unconfirmed deliver_prompt means, for `wave` and `fan`:
# rc 3 (transport failure) and 4 (state unreadable) are "the text may have arrived", so they must
# never advise a re-send. Prints a note; returns 1 only for rc 2 (rejected — definitely not
# delivered), so a caller that needs to stop can. $1 rc  $2 agent  $3 context (names the pane).
report_deliver_result() {
  case $1 in
    0) ;;
    1) note "   $3: $2 never changed state after two sends — 'rd read $2', then 'rd say $2 …'" ;;
    2) note "   $3: UNPROMPTED ($DELIVER_ERR) — recover with: rd say $2 '<the prompt>'"
       return 1 ;;
    *) note "   $3: delivery UNCONFIRMED ($DELIVER_ERR) — 'rd read $2' BEFORE any 'rd say': a re-send may duplicate it" ;;
  esac
  return 0
}

# Submit a prompt and PROVE it landed. Measured ~1 in 6 prompts is dropped when sent right
# after `agent start` (the pane exists, a fresh Claude sits in it, nothing ever told it what
# to do). A delivered prompt changes the agent's state within seconds, so no change inside 30 s
# means re-send, once — but only after an observed "no change": an unreadable state is reported,
# never answered with another send.
# $1 pane  $2 agent name  $3 prompt. Returns 0 delivered (or queued behind a running turn),
# 1 never picked up, 2 rejected, 3 transport failure, 4 state unreadable (delivery unverified).
# 2-4 leave the reason in the global DELIVER_ERR; for 4 it says whether anything was sent.
deliver_prompt() {
  local try rc=1 reached=0
  for try in 1 2; do
    prompt_attempt "$1" "$2" "$3" "${RD_DELIVER_WAIT_S:-30}"; rc=$?
    (( rc == 4 )) || reached=1
    case $rc in
      0|5) return 0 ;;
      2|3) return "$rc" ;;
      4) sleep "${RD_POLL_S:-1}" ;;  # nothing was sent in this try, so retrying cannot duplicate
      6) break ;;
      *) (( try == 1 )) && note "   no state change from $2 within ${RD_DELIVER_WAIT_S:-30}s — re-sending the prompt once" ;;
    esac
  done
  case $rc in
    4|6)
      if (( reached )); then DELIVER_ERR="the prompt was sent, but $2's state was unreadable afterwards — delivery unconfirmed"
      else DELIVER_ERR="could not read $2's state from herdr — nothing was sent"; fi
      return 4 ;;
  esac
  return 1
}

# The wave-chaining lane: near-twin of `work`, for an agent that has just
# finished a wave and needs to hand off to a fresh one rather than continue in
# its own (increasingly long) context. Four differences from `work`:
#
#   1. A TAB in the repo's existing space, not a new space. Every repo already
#      has one workspace and the sidebar is grouped by `herdr-groups.py`, so a
#      per-wave workspace does not read as "wave 2 of this repo" — it reads as a
#      second, unrelated entry in the sidebar, in the wrong group. Waves are
#      tabs inside the repo's space; a workspace is created only when the repo
#      has none at all.
#   2. Solo mode. `--dangerously-skip-permissions` rides the `-- [AGENT_ARG]`
#      tail into `herdr agent start`, because an unattended wave has no one to
#      answer a permission prompt. `work` deliberately omits it — that pane
#      has a human sitting in front of it.
#   3. It submits a prompt. `work` hands you an empty pane; `wave` is the
#      automated form of "open a tab, start claude solo, paste the handover".
#   4. It is bounded. See RD_WAVE_MAX below — a wave that can spawn its own
#      successor is exactly the shape of a chain with no natural end.
cmd_wave() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  local prompt="${REST[*]:1}"
  [[ -n $name && -n $prompt ]] || die "usage: wave <repo> [--kind claude] [--role R] <prompt…>"
  require_server

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
  gate_out=$(host_run "python3 \"\$HOME/SourceRoot/dotfiles/scripts/wave-gate.py\" $orch_flag '$path' '$plan_ref'" 2>&1) \
    || die "green gate failed for $path:"$'\n'"$gate_out"
  [[ -z $gate_out ]] || echo "$gate_out" >&2 # a pass can still say a check was skipped (the factory queue)

  # The repo's space is the one labelled with its bare name — the convention
  # `work` establishes and `herdr-groups.py` groups by. Waves live inside it as
  # tabs labelled `wave <n>`. The label carries the plan's wave number (below);
  # herdr's tab list is only the fallback counter and the spawn-depth record.
  local ws n
  ws=$(NAME="$name" python3 -c '
import json, os, sys
name = os.environ["NAME"]
try:
    workspaces = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    workspaces = []
for w in workspaces:
    if (w.get("label") or "").strip() == name:
        print(w["workspace_id"]); break
' <<<"$(host_run 'herdr workspace list' 2>/dev/null)" 2>/dev/null)

  if [[ -n $ws ]]; then
    n=$(host_run "herdr tab list --workspace '$ws'" 2>/dev/null | python3 -c '
import json, re, sys
try:
    tabs = json.load(sys.stdin)["result"]["tabs"]
except Exception:
    tabs = []
nums = [int(m.group(1)) for t in tabs
        for m in [re.match(r"^wave (\d+)$", (t.get("label") or "").strip())] if m]
print(len(nums) + 1, (max(nums) + 1) if nums else 1, ",".join(map(str, nums)))
' 2>/dev/null)
  fi
  # depth = live wave tabs + 1 (what RD_WAVE_MAX bounds); n = next free tab number.
  local depth taken=""
  read -r depth n taken <<<"${n:-}"
  [[ -n $n ]] || { n=1; depth=1; }

  # The label and agent name carry the PLAN's wave number ("Execute the active wave (Wave 7)"),
  # not the tab counter: closed tabs reset the counter, so every wave used to be `-w1`.
  # No "(Wave N)" in the prompt (an ad-hoc spawn) falls back to the counter. RD_WAVE_MAX still
  # bounds the counter (spawn depth), not the plan's numbering.
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
  # over) and herdr still reports it `working` because it is mid-turn — so an
  # unqualified check refuses the command's primary use case. The caller is
  # excluded by pane AND by tab: a Bash tool or subagent running inside the
  # orchestrator's tab is the same operator, not a second editor. Any OTHER live
  # agent in that checkout is still a hard stop; an idle or done predecessor is
  # what a finished wave looks like, so those were never the concern.
  local roster busy
  roster=$(herdr_agent_list) || exit 1
  busy=$(CWD="$path" SELF="${HERDR_PANE_ID:-}" python3 -c '
import json, os, sys
cwd, self_pane = os.environ["CWD"], os.environ.get("SELF") or None
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    agents = []
self_tab = next((a.get("tab_id") for a in agents if self_pane and a.get("pane_id") == self_pane), None)
for a in agents:
    if a.get("cwd") != cwd or a.get("pane_id") == self_pane:
        continue
    if self_tab and a.get("tab_id") == self_tab:
        continue
    if a.get("agent_status") in ("working", "blocked"):
        print("%s %s" % (a.get("pane_id") or "?", a.get("agent_status")))
        break
' <<<"$roster" 2>/dev/null)
  [[ -z $busy ]] \
    || die "another agent in $path is ${busy#* } (pane ${busy%% *}) — two agents editing one checkout race each other"

  # `agent_name` clips at 32 because that is herdr's cap — appending the wave
  # suffix afterwards pushes it back over, so the base gets clipped by the
  # suffix's width first. A name that overflows is rejected at `agent start`,
  # i.e. after the tab already exists.
  local agent live_names
  [[ ",$taken," == *",$wnum,"* ]] && die "a 'wave $wnum' tab already exists in this space — 'rd close' it (or 'rd read' it) before respawning"
  # Tab numbers say nothing about agent names: a spawn without "(Wave N)" (the fleet's mother and
  # lead) takes the next free TAB number, and `<repo>-w<n>` can already belong to a live agent whose
  # tab was closed or renamed. Two agents on one name make `rd say/read` hit the wrong one, so the
  # counter skips numbers whose name is live; the plan's explicit number is authoritative and dies.
  # Fail closed: an unreadable roster must not read as "no live agents" and let a duplicate name through.
  live_names=$(python3 -c '
import json, sys
agents = json.load(sys.stdin)["result"]["agents"]
if not isinstance(agents, list):
    sys.exit(1)
for a in agents:
    if a.get("name"):
        print(a["name"])
' <<<"$roster") || die "could not read the agent roster from $HOST — refusing to pick an agent name without it"
  wave_agent_name() { # <n>
    local s="-w$1" a
    a="$(agent_name "$name")"
    printf '%s' "${a:0:$((32 - ${#s}))}${s}"
  }
  if (( explicit )); then
    grep -qxF "$(wave_agent_name "$wnum")" <<<"$live_names" \
      && die "agent '$(wave_agent_name "$wnum")' is already live — 'rd read' it or 'rd close' its tab before respawning wave $wnum"
  else
    while grep -qxF "$(wave_agent_name "$wnum")" <<<"$live_names"; do wnum=$((wnum + 1)); done
  fi
  agent="$(wave_agent_name "$wnum")"

  # Model and effort before anything is created: an unknown --role is a usage error. A wave is the `wave`
  # role unless told otherwise; unattended work defaults to Sonnet when the role table is unreachable.
  rd_spawn_flags wave sonnet

  # The factory, when it answers, picks the account and queues what has no room; otherwise the account is
  # picked once per spawn here, and no room means pause, never IU.
  local use_factory=0
  [[ -z ${RD_DRY_RUN:-} ]] && factory_up && use_factory=1
  PICK_ENV=""; PICK_NOTE=""; PICK_SPILL=0
  if [[ $AGENT_KIND == claude ]] && (( ! use_factory )); then
    pick_account wave
  fi
  (( PICK_SPILL )) && die "paused: $PICK_NOTE. Retry after a reset; waves never spill to IU API tokens"

  # Everything above can be wrong before anything gets created — RD_DRY_RUN
  # stops here for the same reason `say` stops before the send.
  if [[ -n ${RD_DRY_RUN:-} ]]; then
    [[ -n $PICK_NOTE ]] && echo "account pick (wave): $PICK_NOTE${PICK_ENV:+ [$PICK_ENV]} -> kind $AGENT_KIND"
    if [[ -n $ws ]]; then
      echo "would add tab 'wave $wnum' to existing space $ws ($name) at $path"
    else
      echo "would create space '$name' at $path (no space exists yet) and use its first tab"
    fi
    echo "would start agent '$agent' solo in it and prompt it${SPAWN_MODEL_FLAG}${SPAWN_EFFORT_FLAG}"
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
    # The factory could not take it: the herdr path, with the pick the factory would have made.
    if [[ $AGENT_KIND == claude ]]; then pick_account wave; fi
    (( PICK_SPILL )) && die "paused: $PICK_NOTE. Retry after a reset; waves never spill to IU API tokens"
  fi

  local created json pane tab
  if [[ -n $ws ]]; then
    created=tab
    json=$(host_run "herdr tab create --workspace '$ws' --cwd '$path' --label 'wave $wnum' --no-focus $PICK_ENV $(factory_env "$agent" "${ROLE:-wave}")")
  else
    created=workspace
    json=$(host_run "herdr workspace create --cwd '$path' --label '$name' --no-focus $PICK_ENV $(factory_env "$agent" "${ROLE:-wave}")")
  fi
  pane=$(printf '%s' "$json" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
  tab=$(printf '%s' "$json" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['tab_id'])" 2>/dev/null)
  [[ -n $pane ]] || die "herdr $created create failed for $path: $json"

  # Roll back only what we made. Closing the WORKSPACE when we only added a tab
  # to an existing one would take the repo's other panes with it.
  rollback_wave() {
    if [[ $created == tab ]]; then
      host_run "herdr tab close '$tab'" >/dev/null 2>&1
    else
      host_run "herdr workspace close '${pane%%:*}'" >/dev/null 2>&1
    fi
  }

  # Same `agent_pane_busy` race `work` retries around — the pane exists before
  # its shell does.
  # Unattended work defaults to Sonnet (claude):
  # the settings.json model is whatever `/model` last left the interactive
  # session on (Fable today), and that is the wrong default exactly where no one
  # is watching. A chain that wants another model says so per chain
  # (`RD_WAVE_MODEL`). The pane setup (lane tag) runs in the
  # pane's shell first — `herdr agent start` types the agent command into that
  # same shell, so the agent inherits it.
  local start_cmd
  start_cmd="herdr agent start '$agent' --kind claude --pane '$pane' -- --dangerously-skip-permissions$SPAWN_MODEL_FLAG$SPAWN_EFFORT_FLAG"
  agent_pane_setup "$pane" wave

  local out="" i=0
  while (( i < 10 )); do
    sleep 1; i=$((i+1))
    out=$(host_run "$start_cmd")
    echo "$out" | grep -q 'agent_pane_busy' || break
  done

  if ! echo "$out" | grep -q '"type":"agent_started"'; then
    rollback_wave
    die "agent start failed: $out"
  fi

  deliver_prompt "$pane" "$agent" "$prompt"
  report_deliver_result $? "$agent" "wave $wnum (pane $pane)" \
    || die "wave $wnum started but the prompt was not delivered: $DELIVER_ERR"

  echo "→ wave $wnum started: $AGENT_KIND '$agent' in ${ws:+space $ws, }pane $pane  ($path)${PICK_NOTE:+  [$PICK_NOTE]}"
  note "   'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
}

# Fan-out: one worktree + one Claude tab per brief file, in the repo's EXISTING workspace.
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
  require_server

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

  local ws
  ws=$(NAME="$name" python3 -c '
import json, os, sys
try:
    workspaces = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    workspaces = []
for w in workspaces:
    if (w.get("label") or "").strip() == os.environ["NAME"]:
        print(w["workspace_id"]); break
' <<<"$(host_run 'herdr workspace list' 2>/dev/null)" 2>/dev/null)

  # One lookup per `rd fan`, before the first worktree: every worker is the `worker` role unless told otherwise.
  rd_spawn_flags worker sonnet

  local base_kind=$AGENT_KIND
  if [[ -n ${RD_DRY_RUN:-} ]]; then
    PICK_ENV=""; PICK_NOTE=""
    [[ $base_kind == claude ]] && pick_account fan
    for b in "${briefs[@]}"; do
      echo "would fan '$b' -> worktree + tab in ${ws:-<new space $name>}${SPAWN_MODEL_FLAG}${SPAWN_EFFORT_FLAG}${PICK_NOTE:+  [account pick (fan): $PICK_NOTE${PICK_ENV:+ $PICK_ENV}]}"
    done
    return 0
  fi

  local wt out base sha pane tab json tabname agent prompt rc fan_failed=0 frc
  for b in "${briefs[@]}"; do
    # One pick per spawn: each fan agent is a fresh context, so each is a re-pick point (invariant 1
    # only forbids switching a live session). No room pauses the spawn. A factory that answers picks the
    # account itself and queues what has no room, so the pick is only ours on the herdr path.
    AGENT_KIND=$base_kind; PICK_ENV=""; PICK_NOTE=""; PICK_SPILL=0
    if [[ $AGENT_KIND == claude ]] && ! factory_up; then
      pick_account fan
      if (( PICK_SPILL )); then
        die "paused: $PICK_NOTE. Not started: $b and every brief after it. fan never spills to IU API tokens"
      fi
    fi
    branch=$(sed -n 's/^Branch:[[:space:]]*\([A-Za-z0-9._/-]*\)[[:space:]]*$/\1/p' "$b" | head -1)
    out=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-worktree.sh\" '$path' '$branch'" 2>&1) \
      || die "worktree for '$branch' failed:"$'\n'"$out"
    wt=$(sed -n 1p <<<"$out"); base=$(sed -n 2p <<<"$out"); sha=$(sed -n 3p <<<"$out")
    host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-list.sh\" --mark '$path' '$wt'" >/dev/null 2>&1 \
      || note "   could not mark $wt as fan-made — 'rd fan --clean $name' will keep it"

    # The agent name is fixed before the tab exists: FACTORY_SESSION rides the create call.
    local leaf plen
    leaf=$(agent_name "${branch##*/}"); leaf=${leaf:0:20}
    plen=$((31 - ${#leaf})); (( plen < 1 )) && plen=1
    agent="$(agent_name "$name")"
    agent="${agent:0:$plen}-${leaf}"

    prompt="Base: $base @ $sha (fetched just now; your worktree is cut from it, ignore the live checkout's local state)."$'\n\n'"$(cat "$b")"

    # Through the factory: the space is the main checkout's, the worktree is where the session works.
    if factory_up; then
      [[ -z ${RD_WAVE_MODEL:-}${RD_WAVE_EFFORT:-} ]] \
        || echo "rd: RD_WAVE_MODEL / RD_WAVE_EFFORT do not reach a factory spawn - the role table decides" >&2
      frc=0
      factory_spawn "$agent" "$wt" "$prompt" "${ROLE:-worker}" "$path" || frc=$?
      case $frc in
        0) factory_spawn_report "fan $branch" "$agent" "$path" "$wt"; continue ;;
        1) note "   factory spawn '$agent' failed: $FSPAWN_ERR (worktree kept — 'factory spawn get $agent' first, then 'rd fan --clean $name' reclaims it)"
           fan_failed=1; continue ;;
      esac
      pick_account fan
      if (( PICK_SPILL )); then
        die "paused: $PICK_NOTE. Not started: $b and every brief after it. fan never spills to IU API tokens"
      fi
    fi

    tabname="fan ${branch##*/}"; tabname=${tabname:0:30}
    if [[ -n $ws ]]; then
      json=$(host_run "herdr tab create --workspace '$ws' --cwd '$wt' --label '$tabname' --no-focus $PICK_ENV $(factory_env "$agent" "${ROLE:-worker}")")
    else
      json=$(host_run "herdr workspace create --cwd '$wt' --label '$name' --no-focus $PICK_ENV $(factory_env "$agent" "${ROLE:-worker}")")
      ws=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['workspace']['workspace_id'])" 2>/dev/null)
    fi
    pane=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
    [[ -n $pane ]] || die "herdr tab create failed for $wt: $json (worktree kept — 'rd fan --clean $name' reclaims it)"

    local start_cmd i=0 started=""
    start_cmd="herdr agent start '$agent' --kind claude --pane '$pane' -- --dangerously-skip-permissions$SPAWN_MODEL_FLAG$SPAWN_EFFORT_FLAG"
    agent_pane_setup "$pane" fan
    while (( i < 10 )); do
      sleep 1; i=$((i+1))
      started=$(host_run "$start_cmd")
      echo "$started" | grep -q 'agent_pane_busy' || break
    done
    echo "$started" | grep -q '"type":"agent_started"' \
      || { note "   agent start failed for $branch: $started (tab and worktree kept)"; continue; }

    deliver_prompt "$pane" "$agent" "$prompt"; rc=$?
    if (( rc == 0 )); then
      echo "→ fan: $AGENT_KIND '$agent' on $branch  ($wt)${PICK_NOTE:+  [$PICK_NOTE]}"
    else
      report_deliver_result "$rc" "$agent" "fan $branch" || true
    fi
  done
  note "   'rd agents' to watch · 'rd merge $name <branch…>' to land · 'rd fan --clean $name' after"
  (( ! fan_failed )) || die "at least one factory spawn failed (above); the others were started"
}

# Reclaim fan worktrees whose branch is fully merged into origin's default and whose tree
# is clean: close the agent's tab, remove the worktree (through wtp when the repo has one),
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
  require_server
  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST"
  local roster
  roster=$(herdr_agent_list) || exit 1
  local rows wt br tab
  rows=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-list.sh\" $all '$path'" 2>&1) \
    || die "could not list worktrees of $path: $rows"
  [[ -n $rows ]] || { echo "no extra worktrees for $name"; return 0; }
  local verb reason st qwt qbr
  while IFS=$'\t' read -r verb wt br reason; do
    [[ -n $verb ]] || continue
    if [[ $reason == no-marker ]]; then echo "keep  $br (not created by rd fan, or made before the marker; --all overrides)  $wt"; continue; fi
    if [[ $verb == keep ]]; then echo "keep  $br ($reason)  $wt"; continue; fi
    read -r tab st <<<"$(WT="$wt" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("cwd") == os.environ["WT"]:
        print(a.get("tab_id") or "-", a.get("agent_status") or "-"); break
' <<<"$roster" 2>/dev/null)"
    # Same bar as `close`: an agent still working or blocked is not finished.
    if [[ ${st:-} == working || ${st:-} == blocked ]]; then echo "keep  $br (agent $st)  $wt"; continue; fi
    [[ -n ${RD_DRY_RUN:-} ]] && { echo "would remove $br  $wt"; continue; }
    [[ -n ${tab:-} && $tab != - ]] && host_run "herdr tab close '$tab'" >/dev/null 2>&1
    qwt=$(printf '%q' "$wt"); qbr=$(printf '%q' "$br")
    host_run "git -C $(printf '%q' "$path") worktree remove $qwt && git -C $(printf '%q' "$path") branch -D $qbr" >/dev/null 2>&1 \
      && echo "removed $br  $wt" || echo "keep  $br (remove failed)  $wt"
  done <<<"$rows"
}

# Merge train: scripts/merge-train.sh runs on the host (GitHub only, rebase/fast-forward only).
cmd_merge() {
  local name=${1:-}; shift || true
  [[ -n $name && $# -gt 0 ]] || die "usage: merge <repo> [--check '<cmd>'|--no-check] <branch…>"
  require_server
  local path args="" a
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST"
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/merge-train.sh\" '$path'$args"
}

# Close a finished wave's tab — the orchestrator's last step after reading the
# wave's close-out. Refuses unless it is provably finished: a `wave <n>` tab,
# agent not working/blocked, checkout clean, and nothing unpushed (a branch with
# no upstream counts as unpushed — the wave's commits would exist only in that
# checkout). The tab, never the workspace: the repo's other panes live there.
cmd_close() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: close <agent>   (a finished wave's tab)"

  local roster pane
  roster=$(herdr_agent_list) || exit 1
  pane=$(resolve_one_agent "$name" "$roster") || exit 1

  local info tab status cwd label
  info=$(PANE="$pane" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("pane_id") == os.environ["PANE"]:
        print(a.get("tab_id") or "", a.get("agent_status") or "", a.get("cwd") or "", sep="\t"); break
' <<<"$roster" 2>/dev/null)
  IFS=$'\t' read -r tab status cwd <<<"$info"
  [[ -n $tab ]] || die "could not resolve the tab of $pane"

  # Through the factory the tab is the one holding the session's pane, so a fan tab or a first tab named `1`
  # closes like a `wave <n>` tab. Without a factory answer, or without a session of that name, the tab must
  # be labelled `wave <n>` (today's rule).
  local sname fsess="" fpane ftab fstate via_factory=0
  sname=$(PANE="$pane" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("pane_id") == os.environ["PANE"]:
        print(a.get("name") or ""); break
' <<<"$roster" 2>/dev/null)
  if [[ -n $sname ]] && factory_up; then
    fsess=$(factory_host "$FACTORY_CALL_S" session get "$sname" --format json 2>/dev/null) || fsess=""
    ftab=$(factory_field "$fsess" '(.tab // empty) | s')
    if [[ -n $ftab ]]; then
      fpane=$(factory_field "$fsess" '(.pane // empty) | s')
      fstate=$(factory_field "$fsess" '.state // empty')
      [[ -z $fpane || $fpane == "$pane" ]] \
        || die "the factory has '$sname' in pane $fpane, herdr in $pane — a stale record; refusing to close"
      [[ $fstate == working || $fstate == blocked ]] && die "session $sname is $fstate — not finished"
      # Closing a tab closes every pane in it: another agent there is not ours to close.
      local others
      others=$(TAB="$tab" PANE="$pane" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("tab_id") == os.environ["TAB"] and a.get("pane_id") != os.environ["PANE"]:
        print(a.get("name") or a.get("pane_id") or "?")
' <<<"$roster" 2>/dev/null)
      [[ -z $others ]] || die "tab $tab also holds $(tr '\n' ' ' <<<"$others")— closing it would close them too"
      [[ $ftab == "$tab" ]] \
        || die "the factory has '$sname' in tab $ftab, herdr has pane $pane in tab $tab — a stale record; refusing to close"
      via_factory=1
    else
      echo "rd: the factory has no session '$sname' - resolving the tab through herdr" >&2
    fi
  fi

  label=$(host_run "herdr tab get '$tab'" 2>/dev/null | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin)["result"]["tab"].get("label") or "").strip())
except Exception:
    pass
' 2>/dev/null)
  if (( ! via_factory )); then
    [[ $label =~ ^wave\ [0-9]+$ ]] || die "tab $tab is '${label:-unlabelled}', not a 'wave <n>' tab — refusing to close it"
  fi
  [[ $status == working || $status == blocked ]] && die "agent $pane is $status — not finished"

  # Fail closed: an unreadable checkout (ssh failure, no cwd) is not a clean one.
  [[ -n $cwd ]] || die "agent $pane reports no cwd — cannot verify the checkout is clean, refusing to close"
  local dirty unpushed status_out
  status_out=$(host_run "git -C '$cwd' status --porcelain") \
    || die "could not read git status of $cwd — refusing to close"
  dirty=$(printf '%s' "$status_out" | grep -c . || true)
  (( dirty == 0 )) || die "$cwd has $dirty uncommitted path(s) — the wave's work is not committed"
  unpushed=$(host_run "git -C '$cwd' rev-list --count '@{u}..HEAD' 2>/dev/null || echo no-upstream")
  [[ $unpushed == 0 ]] || die "$cwd has unpushed commits ($unpushed) — push before closing the wave tab"

  local closed
  closed=$(host_run "herdr tab close '$tab'" 2>&1) || die "herdr tab close failed: $closed"
  # herdr reports failure in the body and exits 0 (same trap as `agent prompt`).
  echo "$closed" | grep -q '"error"' && die "herdr tab close rejected: $closed"
  echo "→ closed ${label:-tab} ($tab)"
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

# One view over both lanes, because "is my work still running" should not depend
# on remembering which lane you started it in.
cmd_agents() {
  local herdr_json claude_json
  herdr_json=$(host_run 'herdr agent list' 2>/dev/null)
  claude_json=$(claude_agents_json)

  HERDR_JSON="$herdr_json" CLAUDE_JSON="$claude_json" python3 <<'PY'
import json, os, datetime

def load(raw, path):
    try:
        d = json.loads(raw)
        for k in path:
            d = d[k]
        return d
    except Exception:
        return []

herdr = load(os.environ.get("HERDR_JSON", ""), ["result", "agents"])
claude = load(os.environ.get("CLAUDE_JSON", ""), [])

def short(p):
    return (p or "").replace("/Users/jkrumm/", "~/").replace(
        os.path.expanduser("~") + "/", "~/")

def clip(s, n):
    s = s or "?"
    return s if len(s) <= n else s[: n - 1] + "…"

# A Claude running in a herdr pane is ONE process that both lanes report — herdr
# by pane, the daemon by session. Deduping on the session id (herdr exposes it as
# agent_session.value) keeps it from looking like two agents fighting over one
# checkout, which is a scary thing to see and a wrong thing to believe.
in_herdr = {a.get("agent_session", {}).get("value") for a in herdr}

# NAME printed `?` for every herdr row until 2026-07-31: the list carries no
# `name` unless the agent was started BY name (`work` does; a hand-started one
# never is), and that is most of them. herdr does carry a readable task title,
# which is more use here than a name would have been — the CWD column already
# says which repo. Pane id last so the column is never empty.
def herdr_name(a):
    return a.get("name") or a.get("terminal_title_stripped") or a.get("pane_id")

rows = []
for a in herdr:
    rows.append(("herdr", clip(herdr_name(a), 24), a.get("agent_status", "?"),
                 short(a.get("cwd")), a.get("pane_id", "")))

for a in claude:
    if a.get("sessionId") in in_herdr:
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
    print(f"  {'LANE':<12} {'NAME':<26} {'STATUS':<9} {'CWD':<30} {'PANE / ID / SINCE'}")
    for lane, name, status, cwd, extra in rows:
        print(f"  {lane:<12} {name:<26} {status:<9} {cwd:<30} {extra}")

    if any(r[0] == "interactive" for r in rows):
        print()
        print("  \033[33mnote:\033[0m 'interactive' agents die with their connection.")
        print("        Long work belongs in 'rd wave' (a herdr tab that outlives the connection).")
PY
}

# Watch without attaching — the reason the socket API matters. Reading an agent
# from the MacBook costs nothing and does not disturb the pane.
cmd_read() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: read <agent>   (see 'agents')"

  # The two lanes need completely different read paths, and getting this wrong
  # was actively misleading: a `claude --bg` daemon hands you a session id, but that id is not
  # a herdr agent — the launcher pane is closed the moment the daemon exists —
  # so the socket API answered `agent_not_found` for an agent that was running
  # perfectly well.
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

  # Not a bg session, so it is a herdr pane — and a pane is addressable by repo
  # name here for the same reason `work` is: repo names are what you remember,
  # pane ids churn every time a workspace is rebuilt.
  #
  # The roster is fetched only once the bg lane has come up empty: a `--bg`
  # daemon is readable with herdr flat on its face (it reparented to PID 1 and
  # its transcript is a file), so gating the whole subcommand on the server would
  # break the one lane built to outlive it.
  local roster pane
  roster=$(herdr_agent_list) || exit 1
  pane=$(resolve_one_agent "$name" "$roster") || exit 1
  host_run "herdr agent read '$pane' --source ${2:-recent}"
}

# Claude Code modals that swallow a typed prompt while `herdr agent prompt` still answers
# `agent_prompted`. One "label|regex" per entry, regex matched case-insensitively against the
# visible pane. Only a modal whose text has been seen belongs here.
#   - compact earlier: agent-workflows Wave 2 — it swallowed four `rd say` messages; the lead
#     recovered with `herdr pane send-keys <pane> esc`
#     (agent-workflows docs/waves/handoff/lead.md, item 8).
RD_SAY_MODALS=(
  'the "compact earlier" prompt|compact earlier'
)

# Print the label of the first known modal showing in the pane; return 1 when none is. Only the
# bottom lines of the visible screen are searched (blank rows dropped): that is where Claude Code
# draws a modal, and the same words in the transcript above must not trigger a dismissal.
say_modal() {
  local text entry
  text=$(host_run "herdr pane read '$1' --source visible" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -n "${RD_SAY_MODAL_LINES:-12}")
  for entry in "${RD_SAY_MODALS[@]}"; do
    if grep -qiE -- "${entry#*|}" <<<"$text"; then
      printf '%s' "${entry%%|*}"; return 0
    fi
  done
  return 1
}

say_fail() { # $1 agent  $2 reason
  printf '\033[31mNOT delivered:\033[0m %s — check with: rd read %s\n' "$2" "$1" >&2
  exit 1
}

# One delivery attempt for `say`; exits on every outcome that is not a plain yes/no.
# $1 pane  $2 agent id  $3 text  $4 "1" when an earlier attempt already sent this text.
# Returns 0 picked up · 1 never picked up · 5 queued behind a turn.
say_attempt() {
  local rc
  prompt_attempt "$1" "$2" "$3" "${RD_SAY_WAIT_S:-20}"; rc=$?
  case $rc in
    2|3) say_fail "$2" "$DELIVER_ERR" ;;
    4) if [[ ${4:-} == 1 ]]; then
         say_fail "$2" "delivery unconfirmed: the first send went out, and its state was unreadable before the re-send (not re-sent)"
       fi
       say_fail "$2" "could not read its state from herdr, so nothing was sent" ;;
    6) say_fail "$2" "the text was sent, but its state became unreadable, so delivery is unconfirmed (not re-sent)" ;;
  esac
  return "$rc"
}

# Steer a running agent without attaching. `agent_prompted` only means herdr typed the text — a
# modal on screen can swallow it — so delivery is proven by the shared prompt_attempt: the
# agent's state must change after the send. An agent that was already working is a queued message
# and cannot be proven. An idle one that stays idle gets its pane read: a known modal is dismissed
# and the text re-sent once, anything else fails loudly rather than re-sending blind (a duplicate
# prompt is worse than a visible miss).
cmd_say() {
  local name="${1:-}"; shift || true
  local text="${*:-}"
  [[ -n $name && -n $text ]] || die "usage: say <agent> <text…>"

  local roster pane
  roster=$(herdr_agent_list) || exit 1
  pane=$(resolve_one_agent "$name" "$roster") || exit 1

  # Resolution is the whole risk surface here: this types into a live session, so
  # everything that can be wrong should be wrong BEFORE the send, not after it
  # landed in someone else's pane. RD_DRY_RUN stops exactly here — it is how the
  # resolver gets exercised without steering a running agent.
  [[ -n ${RD_DRY_RUN:-} ]] && { echo "$pane"; return 0; }

  local agent
  agent=$(PANE="$pane" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("pane_id") == os.environ["PANE"]:
        print(a.get("name") or ""); break
' <<<"$roster" 2>/dev/null)
  # A hand-started agent has no name, only a pane id — `herdr agent get|prompt` take either.
  [[ -n $agent ]] || agent=$pane

  # The factory holds a note while the agent works, types it at its next prompt and confirms it by the next
  # turn, which is what the herdr path below can only approximate. A nameless agent is no factory session.
  if [[ $agent != "$pane" ]] && factory_up; then
    local nrc=0 nout
    nout=$(factory_host "$FACTORY_CALL_S" session note "$agent" "$text" 2>&1) || nrc=$?
    case $nrc in
      0) echo "noted: the factory holds it while $agent works and types it at its next prompt"; return 0 ;;
    esac
    # Only a definite "no such session" falls back: any other failure may have recorded the note, and a
    # duplicate instruction is worse than a visible miss.
    if ! factory_not_found "$nout"; then
      say_fail "$agent" "the factory note failed (exit $nrc: $(head -c 200 <<<"$nout" | tr '\n' ' ')), so it may be recorded - not re-sent through herdr"
    fi
    echo "rd: the factory has no session '$agent' - sending through herdr" >&2
  fi

  local rc
  say_attempt "$pane" "$agent" "$text"; rc=$?
  case $rc in
    0) echo "delivered"; return 0 ;;
    5) echo "queued: agent busy — $agent was working, the message waits behind its turn"; return 0 ;;
  esac

  local modal keys
  modal=$(say_modal "$pane") \
    || say_fail "$agent" "it never changed state after the send and no known modal is blocking it"
  # Like `agent prompt`, herdr may answer an error body with exit 0 — check both.
  if ! keys=$(host_run "herdr pane send-keys '$pane' esc" 2>&1) || grep -q '"error"' <<<"$keys"; then
    say_fail "$agent" "$modal is blocking it and dismissing it failed: $keys"
  fi
  sleep "${RD_SAY_SETTLE:-1}"
  say_attempt "$pane" "$agent" "$text" 1; rc=$?
  case $rc in
    0) echo "delivered after dismissing $modal" ;;
    5) echo "queued after dismissing $modal — $agent was working, the message waits behind its turn" ;;
    *) say_fail "$agent" "dismissed $modal and re-sent, but it still never changed state" ;;
  esac
}

# The janitor: closes finished, clean, pushed tabs; messages dirty ones. All logic lives in
# herdr-reap.py (also what com.jkrumm.herdr-reap runs); this is the routing hop.
cmd_reap() {
  require_server
  local args="" a
  for a in "$@"; do
    case $a in
      --dry-run|-n) args+=" --dry-run" ;;
      *) die "usage: reap [--dry-run]   (REAP_IDLE_H=<hours> overrides the 12 h idle threshold)" ;;
    esac
  done
  # shellcheck disable=SC2016  # $HOME expands on the host
  host_run "REAP_IDLE_H='${REAP_IDLE_H:-12}' python3 \"\$HOME/SourceRoot/dotfiles/scripts/herdr-reap.py\"$args"
}

usage() {
  cat <<'EOF'

  rd — drive the mini's workspaces and agents from anywhere

    rd repos [filter]         repos on the dev host, with branch + dirty count
    rd work <repo> [--kind K] [--role R]   herdr workspace + claude for that repo (idempotent)
    rd wave <repo> [--kind K] [--role R] <prompt…>
                              fresh tab + solo agent + prompt — claude
    rd fan <repo> [--role R] <brief…>   worktree + tab + Claude per brief file (fan-out)
                              (fan --clean <repo> [--all] reclaims merged fan worktrees)
                              --role R: tier + effort from the factory role table (mother|lead|wave|worker|mechanical);
                              wave defaults to wave, fan to worker; RD_WAVE_MODEL / RD_WAVE_EFFORT win over it
    rd merge <repo> <br…>     merge train: rebase, check, merge by rebase, re-rebase (GitHub only)
    rd close <agent>          close a finished wave's tab (clean + pushed only)
    rd reap [--dry-run]       janitor: close finished clean+pushed tabs (idle > REAP_IDLE_H, default 12; a merged fan tab at once), message dirty ones
    rd agents                 every agent on the host, both lanes
    rd read <agent> [src]     read an agent's output without attaching
    rd say <agent> <text…>    send a prompt to a running agent

  <agent> is a repo name, a pane id (wG:p6) or a bg session id prefix —
  whichever of them 'agents' put in front of you.

  Shorthands (read/say stay subcommands — the bare names are a zsh
  builtin, a zsh builtin and /usr/bin/say respectively):

    repos · work · agents

  Two lanes for starting agent work (docs/agent-platform.md):
    @implementer  native subagent — the edit must land in this session's live tree
    wave tab      `rd wave <repo> '<prompt>'` — long work you watch or steer

  Getting a terminal is a different layer:
    desk   herdr --remote — local keybindings, dies on roam

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
