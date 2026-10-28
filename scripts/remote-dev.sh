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
# The MacBook's sanctioned repos are dotfiles/dotfiles-private/photo-flow/brain —
# no project repos. `repos` and `work` resolve paths ON the host, which
# is why none of them take a path — a MacBook-side project-repo path would be
# meaningless.

HOST="${REMOTE_DEV_HOST:-mini}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
# " --effort '<level>'" for a wave/fan agent: RD_WAVE_EFFORT wins, else the per-model default from
# config/claude-effort.json (Sonnet high, Opus/Fable medium); empty when neither applies.
rd_effort_flag() { # <model>
  local level
  if [[ -n "${RD_WAVE_EFFORT:-}" ]]; then
    level=$RD_WAVE_EFFORT
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
  [[ -n $name ]] || die "usage: work <repo> [--kind claude]   (see 'repos')"
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

  local pane
  pane=$(host_run "herdr workspace create --cwd '$path' --label '$name' --no-focus" \
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
    out=$(host_run "herdr agent start '$agent' --kind $AGENT_KIND --pane '$pane'")
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
# Hand a prompt to `herdr agent prompt`; prints herdr's body, returns 1 when the body is an error.
# base64 carries the text across the ssh hop and herdr's argv handling byte-identical (quotes,
# newlines, a literal `$(...)`). `herdr agent prompt` EXITS 0 ON FAILURE and reports it in the
# body (`{"error":{"code":"agent_not_found",…}}`), so the body is the signal.
# $1 pane  $2 prompt.
send_prompt() {
  local b64 sent
  b64=$(printf %s "$2" | base64 | tr -d '\n')
  sent=$(host_run "herdr agent prompt '$1' \"\$(echo $b64 | base64 -d)\"" 2>&1)
  printf '%s' "$sent"
  ! grep -q '"error"' <<<"$sent"
}

# Submit a prompt and PROVE it landed. Measured ~1 in 6 prompts is dropped when sent right
# after `agent start` (the pane exists, a fresh Claude sits in it, nothing ever told it what
# to do). A delivered prompt makes the agent leave idle within seconds, so no `working`
# state inside 30 s means re-send, once. base64 carries the text across the ssh hop and
# herdr's argv handling byte-identical (quotes, newlines, a literal `$(...)`).
# $1 pane  $2 agent name  $3 prompt. Returns 0 delivered, 1 never picked up, 2 rejected
# (the rejection body is left in the global DELIVER_ERR).
deliver_prompt() {
  local pane=$1 agent=$2 prompt=$3 sent try
  for try in 1 2; do
    sent=$(send_prompt "$pane" "$prompt") || { DELIVER_ERR=$sent; return 2; }
    # blocked/done count as delivered too: a prompt that went straight to a question or finished
    # fast must not be re-sent (duplicate execution).
    host_run "herdr agent wait '$agent' --until working --until blocked --until done --timeout 30000" >/dev/null 2>&1 && return 0
    (( try == 1 )) && note "   no 'working' from $agent within 30s — re-sending the prompt once"
  done
  return 1
}

cmd_wave() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  local prompt="${REST[*]:1}"
  [[ -n $name && -n $prompt ]] || die "usage: wave <repo> [--kind claude] <prompt…>"
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

  # The account is picked once per spawn; no room means pause, never IU.
  PICK_ENV=""; PICK_NOTE=""
  if [[ $AGENT_KIND == claude ]]; then
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
    echo "would start agent '$agent' solo in it and prompt it"
    return 0
  fi

  local created json pane tab
  if [[ -n $ws ]]; then
    created=tab
    json=$(host_run "herdr tab create --workspace '$ws' --cwd '$path' --label 'wave $wnum' --no-focus $PICK_ENV")
  else
    created=workspace
    json=$(host_run "herdr workspace create --cwd '$path' --label '$name' --no-focus $PICK_ENV")
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
  local model start_cmd effort
  model="${RD_WAVE_MODEL:-sonnet}"
  effort=$(rd_effort_flag "$model") || exit 1 # a bad RD_WAVE_EFFORT dies in the subshell: stop here too
  start_cmd="herdr agent start '$agent' --kind claude --pane '$pane' -- --dangerously-skip-permissions --model '$model'$effort"
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
  case $? in
    2) note "   pane $pane is live but UNPROMPTED — recover with:"
       note "     rd say $agent '<the handover prompt>'"
       die "wave $wnum started but the prompt was rejected: $DELIVER_ERR" ;;
    1) note "   pane $pane never left idle after two sends — check 'rd read $agent', then 'rd say $agent …'" ;;
  esac

  echo "→ wave $wnum started: $AGENT_KIND '$agent' in ${ws:+space $ws, }pane $pane  ($path)${PICK_NOTE:+  [$PICK_NOTE]}"
  note "   'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
}

# Fan-out: one worktree + one Claude tab per brief file, in the repo's EXISTING workspace.
# Each brief declares its branch on a `Branch: <name>` line (the brief template's "exact
# branch" field). Worktrees are cut from FETCHED origin state by scripts/fan-worktree.sh and
# the brief is prefixed with that base, so a stale or ahead local checkout cannot brief a
# worker against the wrong tree. `rd fan --clean <repo>` reclaims merged worktrees.
cmd_fan() {
  parse_kind "$@"
  local name="${REST[0]:-}"
  [[ -n $name ]] || die "usage: fan <repo> [--kind K] <brief-file…>   |   fan --clean <repo>"
  if [[ $name == --clean ]]; then fan_clean "${REST[1]:-}"; return; fi
  local briefs=("${REST[@]:1}")
  (( ${#briefs[@]} )) || die "usage: fan <repo> [--kind K] <brief-file…>"
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

  local base_kind=$AGENT_KIND
  if [[ -n ${RD_DRY_RUN:-} ]]; then
    PICK_ENV=""; PICK_NOTE=""
    [[ $base_kind == claude ]] && pick_account fan
    for b in "${briefs[@]}"; do
      echo "would fan '$b' -> worktree + tab in ${ws:-<new space $name>}${PICK_NOTE:+  [account pick (fan): $PICK_NOTE${PICK_ENV:+ $PICK_ENV}]}"
    done
    return 0
  fi

  local wt out base sha pane tab json tabname agent prompt rc
  for b in "${briefs[@]}"; do
    # One pick per spawn: each fan agent is a fresh context, so each is a re-pick point (invariant 1
    # only forbids switching a live session). No room pauses the spawn.
    AGENT_KIND=$base_kind; PICK_ENV=""; PICK_NOTE=""
    if [[ $AGENT_KIND == claude ]]; then
      pick_account fan
      if (( PICK_SPILL )); then
        die "paused: $PICK_NOTE. Not started: $b and every brief after it. fan never spills to IU API tokens"
      fi
    fi
    branch=$(sed -n 's/^Branch:[[:space:]]*\([A-Za-z0-9._/-]*\)[[:space:]]*$/\1/p' "$b" | head -1)
    out=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-worktree.sh\" '$path' '$branch'" 2>&1) \
      || die "worktree for '$branch' failed:"$'\n'"$out"
    wt=$(sed -n 1p <<<"$out"); base=$(sed -n 2p <<<"$out"); sha=$(sed -n 3p <<<"$out")

    tabname="fan ${branch##*/}"; tabname=${tabname:0:30}
    if [[ -n $ws ]]; then
      json=$(host_run "herdr tab create --workspace '$ws' --cwd '$wt' --label '$tabname' --no-focus $PICK_ENV")
    else
      json=$(host_run "herdr workspace create --cwd '$wt' --label '$name' --no-focus $PICK_ENV")
      ws=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['workspace']['workspace_id'])" 2>/dev/null)
    fi
    pane=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
    [[ -n $pane ]] || die "herdr tab create failed for $wt: $json (worktree kept — 'rd fan --clean $name' reclaims it)"

    local leaf plen
    leaf=$(agent_name "${branch##*/}"); leaf=${leaf:0:20}
    plen=$((31 - ${#leaf})); (( plen < 1 )) && plen=1
    agent="$(agent_name "$name")"
    agent="${agent:0:$plen}-${leaf}"
    local model start_cmd effort i=0 started=""
    model="${RD_WAVE_MODEL:-sonnet}"
    effort=$(rd_effort_flag "$model") || exit 1
    start_cmd="herdr agent start '$agent' --kind claude --pane '$pane' -- --dangerously-skip-permissions --model '$model'$effort"
    agent_pane_setup "$pane" fan
    while (( i < 10 )); do
      sleep 1; i=$((i+1))
      started=$(host_run "$start_cmd")
      echo "$started" | grep -q 'agent_pane_busy' || break
    done
    echo "$started" | grep -q '"type":"agent_started"' \
      || { note "   agent start failed for $branch: $started (tab and worktree kept)"; continue; }

    prompt="Base: $base @ $sha (fetched just now; your worktree is cut from it, ignore the live checkout's local state)."$'\n\n'"$(cat "$b")"
    deliver_prompt "$pane" "$agent" "$prompt"; rc=$?
    case $rc in
      0) echo "→ fan: $AGENT_KIND '$agent' on $branch  ($wt)${PICK_NOTE:+  [$PICK_NOTE]}" ;;
      1) echo "→ fan: '$agent' on $branch started but never left idle — 'rd read $agent'" ;;
      2) echo "→ fan: '$agent' on $branch UNPROMPTED ($DELIVER_ERR) — 'rd say $agent …'" ;;
    esac
  done
  note "   'rd agents' to watch · scripts/wave-watch.sh --agents … to block · 'rd merge $name <branch…>' to land · 'rd fan --clean $name' after"
}

# Reclaim fan worktrees whose branch is fully merged into origin's default and whose tree
# is clean: close the agent's tab, remove the worktree (through wtp when the repo has one),
# delete the branch. Anything unmerged or dirty is listed and left alone.
fan_clean() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: fan --clean <repo>"
  require_server
  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST"
  local roster
  roster=$(herdr_agent_list) || exit 1
  local rows wt br tab
  rows=$(host_run "bash \"\$HOME/SourceRoot/dotfiles/scripts/fan-list.sh\" '$path'" 2>&1) \
    || die "could not list worktrees of $path: $rows"
  [[ -n $rows ]] || { echo "no extra worktrees for $name"; return 0; }
  local verb reason st qwt qbr
  while IFS=$'\t' read -r verb wt br reason; do
    [[ -n $verb ]] || continue
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

  label=$(host_run "herdr tab get '$tab'" 2>/dev/null | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin)["result"]["tab"].get("label") or "").strip())
except Exception:
    pass
' 2>/dev/null)
  [[ $label =~ ^wave\ [0-9]+$ ]] || die "tab $tab is '${label:-unlabelled}', not a 'wave <n>' tab — refusing to close it"
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
  echo "→ closed $label ($tab)"
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
        print("        Unattended work belongs in 'agw-legacy dispatch'.")
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

# Print the label of the first known modal showing in the pane; return 1 when none is.
say_modal() {
  local text entry
  text=$(host_run "herdr pane read '$1' --source visible" 2>/dev/null)
  for entry in "${RD_SAY_MODALS[@]}"; do
    if grep -qiE -- "${entry#*|}" <<<"$text"; then
      printf '%s' "${entry%%|*}"; return 0
    fi
  done
  return 1
}

# True when the agent picked the prompt up: it enters `working` within the window.
say_picked_up() {
  host_run "herdr agent wait '$1' --until working --timeout ${RD_SAY_WAIT_MS:-20000}" >/dev/null 2>&1
}

say_fail() { # $1 agent  $2 reason
  printf '\033[31mNOT delivered:\033[0m %s — check with: rd read %s\n' "$2" "$1" >&2
  exit 1
}

# Steer a running agent without attaching. `agent_prompted` only means herdr typed the text — a
# modal on screen can swallow it — so delivery is proven the way deliver_prompt proves it: the
# agent must enter `working`. A busy agent is a queued message and cannot be proven; an idle one
# that stays idle gets its pane read: a known modal is dismissed and the text re-sent once, anything
# else fails loudly rather than re-sending blind (a duplicate prompt is worse than a visible miss).
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

  local status body
  status=$(PANE="$pane" python3 -c '
import json, os, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("pane_id") == os.environ["PANE"]:
        print(a.get("agent_status", "")); break
' <<<"$roster" 2>/dev/null)

  body=$(send_prompt "$pane" "$text") || say_fail "$name" "herdr rejected the prompt: $body"

  if [[ $status == working ]]; then
    echo "queued: agent busy — $name was working, the message waits in its input"
    return 0
  fi
  if say_picked_up "$pane"; then
    echo "delivered"
    return 0
  fi

  local modal
  modal=$(say_modal "$pane") \
    || say_fail "$name" "it never started working and no known modal is blocking it"
  host_run "herdr pane send-keys '$pane' esc" >/dev/null 2>&1
  sleep "${RD_SAY_SETTLE:-1}"
  body=$(send_prompt "$pane" "$text") || say_fail "$name" "herdr rejected the re-send after dismissing $modal: $body"
  say_picked_up "$pane" \
    || say_fail "$name" "dismissed $modal and re-sent, but it still never started working"
  echo "delivered after dismissing $modal"
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
    rd work <repo> [--kind K]   herdr workspace + claude for that repo (idempotent)
    rd wave <repo> [--kind K] <prompt…>
                              fresh tab + solo agent + prompt — claude
    rd fan <repo> <brief…>    worktree + tab + Claude per brief file (fan-out)
                              (fan --clean <repo> reclaims merged worktrees)
    rd merge <repo> <br…>     merge train: rebase, check, merge by rebase, re-rebase (GitHub only)
    rd close <agent>          close a finished wave's tab (clean + pushed only)
    rd reap [--dry-run]       janitor: close finished clean+pushed tabs, message dirty ones (REAP_IDLE_H, default 12)
    rd agents                 every agent on the host, both lanes
    rd read <agent> [src]     read an agent's output without attaching
    rd say <agent> <text…>    send a prompt to a running agent

  <agent> is a repo name, a pane id (wG:p6) or a bg session id prefix —
  whichever of them 'agents' put in front of you.

  Shorthands (read/say stay subcommands — the bare names are a zsh
  builtin, a zsh builtin and /usr/bin/say respectively):

    repos · work · agents

  Three lanes for starting agent work (docs/agent-platform.md):
    @implementer  native subagent — the edit must land in this session's live tree
    dispatch      agent-gateway `dispatch` (MCP/CLI) — settled bounded work → branch/PR or verdict
    wave tab      `rd wave <repo> '<prompt>'` — long work you watch or steer

  Getting a terminal is a different layer:
    desk   herdr --remote — local keybindings, dies on roam

  It persists on the mini regardless. You only need a terminal to watch.

EOF
}

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
