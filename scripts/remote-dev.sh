#!/usr/bin/env bash
set -uo pipefail

# remote-dev — drive the mini's herdr workspaces and Claude agents.
#
# The four-layer model (Tailscale / mosh / herdr / Caddy) is about *getting a
# terminal*. This script is the layer above it: preparing and steering the work
# itself, without needing a terminal at all. That distinction is the whole point
# — `dev` and `desk` are how you go and look; everything here you can do from
# the MacBook while attached to nothing.
#
# Routing is deliberate and invisible: every subcommand runs on the dev host,
# whether you are sitting at it or a hop away. There is one definition of "am I
# the dev host" (the secrets backend marker, same signal `git-headless` and
# `herdr-setup` key off) so the two machines can share one command surface.
#
# The MacBook holds no repos any more. `repos`, `work` and `bg` all resolve
# paths ON the host, which is why none of them take a path — a MacBook-side
# path would be meaningless.

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

require_server() {
  host_run 'herdr status' 2>/dev/null | grep -q 'status: running' \
    || die "herdr server is not running on $HOST — 'brew services restart herdr' there, or run 'make remote-dev-doctor'"
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
  existing=$(host_run 'herdr agent list' | python3 -c "
import json,sys
try: agents = json.load(sys.stdin)['result']['agents']
except Exception: sys.exit(0)
for a in agents:
    if a.get('cwd') == '$path':
        print(a['name']); break
" 2>/dev/null)

  if [[ -n $existing ]]; then
    host_run "herdr agent focus '$existing'" >/dev/null 2>&1
    echo "→ focused existing agent '$existing'  ($path)"
    note "   already running; 'rd read $existing' to see it, 'dev' to attach"
    return 0
  fi

  local pane
  pane=$(host_run "herdr workspace create --cwd '$path' --label '$name' --no-focus" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" 2>/dev/null)
  [[ -n $pane ]] || die "herdr workspace create failed for $path"

  local out
  out=$(host_run "herdr agent start '$name' --kind claude --pane '$pane'")
  if echo "$out" | grep -q '"type":"agent_started"'; then
    echo "→ started claude '$name' in pane $pane  ($path)"
    note "   'dev' to attach · 'rd read $name' to watch · 'rd say $name \"...\"' to steer"
  else
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
  local esc=${task//\'/\'\\\'\'}
  host_run "herdr pane run '$pane' claude --bg '$esc'" >/dev/null 2>&1

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

rows = []
for a in herdr:
    rows.append(("herdr", clip(a.get("name"), 24), a.get("agent_status", "?"),
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
  host_run "herdr agent read '$name' --source ${2:-recent}"
}

# Steer a running agent without attaching.
cmd_say() {
  local name="${1:-}"; shift || true
  local text="${*:-}"
  [[ -n $name && -n $text ]] || die "usage: say <agent> <text…>"
  local esc=${text//\'/\'\\\'\'}
  host_run "herdr agent prompt '$name' '$esc'"
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

  Shorthands (bg/read/say stay subcommands — the bare names are a zsh
  builtin, a zsh builtin and /usr/bin/say respectively):

    repos · work · agents

  Getting a terminal is a different layer:
    dev    mosh in, land in herdr — roams, survives lid-close, no reattach
    desk   herdr --remote — local keybindings, dies on roam

  Both lanes persist on the mini. You only need a terminal to watch.

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
