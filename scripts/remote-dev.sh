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
# no project repos. `repos`, `work` and `bg` all resolve paths ON the host, which
# is why none of them take a path — a MacBook-side project-repo path would be
# meaningless.

HOST="${REMOTE_DEV_HOST:-mini}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }

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
# second — the pipe was the bug, not the check. (Same trap the CLAUDE.md
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
    || die "herdr server is not running on $HOST — 'brew services restart herdr' there, or run 'make doctor'"
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

# `work` is idempotent on purpose. Two Claude agents in one checkout race each
# other's edits — the same hazard the CLAUDE.md file-ownership rule describes,
# except across panes where you cannot see it happening. So a second `work argo`
# focuses the first rather than stacking a workspace on the same tree.
cmd_work() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: work <repo>   (see 'repos')"
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
    out=$(host_run "herdr agent start '$agent' --kind claude --pane '$pane'")
    echo "$out" | grep -q 'agent_pane_busy' || break
  done

  if echo "$out" | grep -q '"type":"agent_started"'; then
    echo "→ started claude '$agent' in pane $pane  ($path)"
    note "   'desk' to attach · 'rd read $agent' to watch · 'rd say $agent \"...\"' to steer"
  else
    # Roll the workspace back. Leaving it costs a stale entry in every later
    # `herdr workspace list` and, worse, makes the next `work` look like it
    # half-succeeded.
    host_run "herdr workspace close '${pane%%:*}'" >/dev/null 2>&1
    die "agent start failed: $out"
  fi
}

# The durable lane. A herdr crash restores the layout and loses every process in
# it, so anything that must survive goes here instead of into a pane.
#
# It is spawned THROUGH a throwaway herdr pane rather than directly over ssh, and
# that indirection is the whole reason this function exists. Claude Code's Max
# credentials live in the login keychain, which an ssh session cannot reach: a
# bare `ssh mini "claude --bg …"` starts, reports `Not logged in · Please run
# /login`, silently falls back to *API Usage Billing*, and still shows up in
# `claude agents` looking healthy. The herdr server is a brew service under
# launchd inside the user's GUI session, so anything it spawns inherits keychain
# access. Verified both ways on 2026-07-27.
#
# The pane is closed once the daemon exists — `--bg` reparents to PID 1, so it
# no longer needs the thing that launched it.
cmd_bg() {
  local name="${1:-}"; shift || true
  local task="${*:-}"
  [[ -n $name && -n $task ]] || die "usage: bg <repo> <task…>"
  require_server

  local path
  path=$(resolve_repo "$name") || die "no git repo named '$name' on $HOST — try 'repos $name'"

  local before
  before=$(host_run 'claude agents --json' | python3 -c \
    "import json,sys; print(' '.join(a['sessionId'] for a in json.load(sys.stdin)))" 2>/dev/null)

  local ws pane
  ws=$(host_run "herdr workspace create --cwd '$path' --label 'bg:$name' --no-focus")
  pane=$(echo "$ws" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
  [[ -n $pane ]] || die "could not create a launcher pane for $path"
  local wsid=${pane%%:*}

  # --bg takes the positional prompt and conflicts with -p.
  #
  # There are TWO shells between here and Claude, and the obvious quoting loses
  # to the second one silently. `herdr pane run` accepts argv but joins it back
  # into a line for the pane's shell to parse, so a prompt quoted for the ssh
  # hop arrives at the pane unquoted and word-splits: 'read the repo and
  # summarize…' reached Claude as the one-word prompt `read`. The daemon then
  # started, reported healthy in `agents`, and sat there asking what to read.
  #
  # base64 removes the problem rather than escaping around it — the alphabet has
  # no shell metacharacters, so the payload survives both parses byte-identical
  # no matter what the task contains. The literal double quotes inside the
  # single-quoted argv element are what keep the pane-side expansion one word.
  local b64
  b64=$(printf %s "$task" | base64 | tr -d '\n')
  host_run "herdr pane run '$pane' claude --bg '\"\$(echo $b64 | base64 -d)\"'" >/dev/null 2>&1

  local id="" i=0
  while (( i < 24 )); do
    sleep 1; i=$((i+1))
    id=$(BEFORE="$before" host_run 'claude agents --json' | BEFORE="$before" python3 -c "
import json,os,sys
before = set(os.environ.get('BEFORE','').split())
try: agents = json.load(sys.stdin)
except Exception: sys.exit(0)
for a in agents:
    if a['sessionId'] not in before and a.get('cwd') == '$path' and a.get('kind') == 'background':
        print(a['sessionId']); break
" 2>/dev/null)
    [[ -n $id ]] && break
  done

  if [[ -z $id ]]; then
    note "   launcher pane $pane left open for inspection ('rd read' won't see it — use herdr)"
    die "no background agent appeared for $path after ${i}s"
  fi

  host_run "herdr workspace close '$wsid'" >/dev/null 2>&1
  echo "→ backgrounded ${id:0:8}  ($path)"
  note "   survives ssh, herdr and lid-close · 'agents' to track"
  note "   on the host: claude logs ${id:0:8} · claude attach ${id:0:8} · claude stop ${id:0:8}"
}

# One view over both lanes, because "is my work still running" should not depend
# on remembering which lane you started it in.
cmd_agents() {
  local herdr_json claude_json
  herdr_json=$(host_run 'herdr agent list' 2>/dev/null)
  claude_json=$(host_run 'claude agents --json' 2>/dev/null)

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
        print("        Durable work belongs in 'bg' (claude --bg).")
PY
}

# Watch without attaching — the reason the socket API matters. Reading an agent
# from the MacBook costs nothing and does not disturb the pane.
cmd_read() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: read <agent>   (see 'agents')"

  # The two lanes need completely different read paths, and getting this wrong
  # was actively misleading: `rd bg` hands you a session id, but that id is not
  # a herdr agent — the launcher pane is closed the moment the daemon exists —
  # so the socket API answered `agent_not_found` for an agent that was running
  # perfectly well.
  #
  # `claude logs` is not the alternative. It attaches a full-screen TUI, so it
  # cannot be piped, read from another machine, or used by an agent. The
  # scriptable surface is the session transcript Claude Code already writes per
  # project, which is append-only and readable while the daemon runs.
  local sid
  sid=$(host_run 'claude agents --json' | TARGET="$name" python3 -c "
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

  if [[ -n $sid ]]; then
    # shellcheck disable=SC2016  # $HOME expands on the dev host, not here
    host_run "tail -n 300 \"\$HOME\"/.claude/projects/*/$sid.jsonl 2>/dev/null" | python3 -c '
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

# Steer a running agent without attaching.
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

  local esc=${text//\'/\'\\\'\'}
  host_run "herdr agent prompt '$pane' '$esc'"
}

usage() {
  cat <<'EOF'

  rd — drive the mini's workspaces and agents from anywhere

    rd repos [filter]      repos on the dev host, with branch + dirty count
    rd work <repo>         herdr workspace + claude for that repo (idempotent)
    rd bg <repo> <task…>   durable claude --bg daemon — survives everything
    rd agents              every agent on the host, both lanes
    rd read <agent> [src]  read an agent's output without attaching
    rd say <agent> <text…> send a prompt to a running agent

  <agent> is a repo name, a pane id (wG:p6) or a bg session id prefix —
  whichever of them 'agents' put in front of you.

  Shorthands (bg/read/say stay subcommands — the bare names are a zsh
  builtin, a zsh builtin and /usr/bin/say respectively):

    repos · work · agents

  Getting a terminal is a different layer:
    desk   herdr --remote — local keybindings, dies on roam

  It persists on the mini regardless. You only need a terminal to watch.

EOF
}

case "${1:-}" in
  repos)  shift; cmd_repos "$@" ;;
  work)   shift; cmd_work "$@" ;;
  bg)     shift; cmd_bg "$@" ;;
  agents) shift; cmd_agents "$@" ;;
  read)   shift; cmd_read "$@" ;;
  say)    shift; cmd_say "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand '$1' — run 'rd help'" ;;
esac
