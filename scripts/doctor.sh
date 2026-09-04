#!/usr/bin/env bash
set -u -o pipefail   # NOT -e: one section failing must not abort the rest

# doctor — read-only health of this machine, and (from the MacBook) the mini
# too. Collapses four standalone diagnostics that used to answer overlapping
# questions with overlapping output: scripts/remote-dev-doctor.sh (MacBook →
# mini path), scripts/mini-sweep.sh (Kuma + a remote devhost/drift roundup),
# scripts/launchagents-check.sh (this machine's own LaunchAgents), and the
# on-demand half of scripts/drift-check.sh (its daily-push half stays a
# separate LaunchAgent — see below). One command, one place to look.
#
# Nothing here writes, restarts, or pushes to Uptime Kuma. The daily drift
# push, the 300s devhost heartbeat, and every applier (brew-upgrade,
# mini-macos-update, collie-upgrade, caddy-tailnet) stay separate and
# attended — this is read-only by construction, not by discipline.
#
# Self-routes on ~/.config/secrets/backend, same signal remote-dev.sh and
# human-queue.sh key off:
#   cache (the mini)   → LaunchAgents, architecture map, brew, drift (no push),
#                         devhost heartbeat (named, not run — it always pushes)
#   op    (the MacBook) → LaunchAgents, architecture map, brew, the MacBook→mini
#                         remote path, Kuma monitor states, then (unless
#                         --local) recurse into 'ssh mini make doctor'
#
# BASH 3.2. No mapfile, no ${var,,}, no "${arr[@]}" on a possibly-empty array
# under `set -u` — same constraint as devhost-health-check.sh and drift-check.sh,
# for the same reason: this is invoked via `make doctor` on a machine whose
# system bash is 3.2, and the LaunchAgent-safe idioms are the ones that also
# work interactively.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKEND_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
BACKEND=$(tr -d '[:space:]' < "$BACKEND_FILE" 2>/dev/null || echo "")
HOST="${REMOTE_DEV_HOST:-mini}"
KUMA_HOST="${KUMA_HOST:-homelab}"
KUMA_DB="${KUMA_DB:-/home/jkrumm/ssd/uptime-kuma/kuma.db}"

LOCAL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL_ONLY=1 ;;
    *) echo "usage: $(basename "$0") [--local]" >&2; exit 1 ;;
  esac
done

pass=0
fail=0
skipped=0

ok()   { printf '  \033[32m✓\033[0m %-30s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %-30s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
skip() { printf '  \033[33m·\033[0m %-30s %s\n' "$1" "${2:-}"; skipped=$((skipped + 1)); }
hdr()  { printf '\n  \033[1m%s\033[0m\n' "$1"; }

echo ""
echo "  doctor — $(hostname -s 2>/dev/null || echo "this machine") (backend=${BACKEND:-unset})"

# --- LaunchAgents (both machines) --------------------------------------------
# Harvested from scripts/launchagents-check.sh — same detection logic,
# unchanged: a missing program/WorkingDirectory, a down KeepAlive job, /tmp
# logs, and a plaintext credential in EnvironmentVariables. See that history
# in dotfiles CLAUDE.md ("The MacBook has no heartbeat") for why each check
# exists — two agents once accumulated 40,000+ failed spawns with nothing
# reporting it.
section_launchagents() {
  hdr "LaunchAgents"
  local agent_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
  local prefix="${LAUNCHAGENTS_PREFIX:-com.jkrumm.}"
  local uid
  uid=$(id -u)

  local plist
  for plist in "$agent_dir/$prefix"*.plist; do
    if [ ! -e "$plist" ]; then
      skip "LaunchAgents" "no $prefix* agents in $agent_dir"
      return
    fi
    local label prog wd detail exitcode runs keepalive running issues k
    label=$(basename "$plist" .plist)

    prog=$(/usr/bin/plutil -extract Program raw -o - "$plist" 2>/dev/null || true)
    [ -n "$prog" ] || prog=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || true)
    wd=$(/usr/bin/plutil -extract WorkingDirectory raw -o - "$plist" 2>/dev/null || true)

    # launchctl print is the only place the last exit code lives; a missing
    # job is not an error here (an agent can be legitimately unloaded).
    detail=$(launchctl print "gui/$uid/$label" 2>/dev/null || true)
    exitcode=$(printf '%s\n' "$detail" | sed -n 's/.*last exit code = \([0-9]*\).*/\1/p' | head -1)
    runs=$(printf '%s\n' "$detail" | sed -n 's/.*runs = \([0-9]*\).*/\1/p' | head -1)

    issues=""
    case "$prog" in
      /*) [ -x "$prog" ] || issues="$issues; program missing: $prog" ;;
    esac
    [ -z "$wd" ] || [ -d "$wd" ] || issues="$issues; WorkingDirectory missing: $wd"

    # Exit codes are graded: 78 (EX_CONFIG) always matters (launchd never even
    # started the job); any other non-zero exit matters only if KeepAlive says
    # the job should be up and it is not (db-tunnel exits 255 on every lid
    # close by design and must not flag on that).
    keepalive=$(/usr/bin/plutil -extract KeepAlive raw -o - "$plist" 2>/dev/null || true)
    running=0
    printf '%s\n' "$detail" | grep -q 'state = running' && running=1
    if [ "${exitcode:-0}" = "78" ]; then
      issues="$issues; last exit 78 (EX_CONFIG — never started)${runs:+ after $runs runs}"
    elif [ "${exitcode:-0}" != "0" ] && [ "$keepalive" = "true" ] && [ "$running" -eq 0 ]; then
      issues="$issues; KeepAlive job is down, last exit $exitcode${runs:+ after $runs runs}"
    fi

    for k in StandardOutPath StandardErrorPath; do
      case "$(/usr/bin/plutil -extract "$k" raw -o - "$plist" 2>/dev/null || true)" in
        /tmp/*|/private/tmp/*) issues="$issues; $k is in /tmp (swept; use ~/Library/Logs)" ;;
      esac
    done

    if /usr/bin/plutil -extract EnvironmentVariables xml1 -o - "$plist" 2>/dev/null \
        | grep -qiE '<key>[^<]*(TOKEN|SECRET|PASSWORD|API_?KEY)[^<]*</key>'; then
      issues="$issues; plaintext credential in EnvironmentVariables (move to op:// + a wrapper)"
    fi

    if [ -n "$issues" ]; then
      bad "$label" "${issues#; }"
    else
      ok "$label" ""
    fi
  done
}

# --- Architecture map (both machines) ----------------------------------------
# Every launchd label loaded/on-disk on this machine must appear in
# docs/architecture.md. The script itself already covers both machines (the
# MacBook's agent list was inventoried into the map 2026-08-30) — nothing to
# extend here, just run it.
section_architecture() {
  hdr "Architecture map (docs/architecture.md)"
  local out rc
  out=$(bash "$DOTFILES_DIR/scripts/architecture-check.sh" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    ok "architecture map" "every loaded/on-disk label is mapped"
  else
    bad "architecture map" "unmapped labels — see above"
  fi
}

# --- Homebrew (both machines) -------------------------------------------------
# Report-only, informational — not a pass/fail gate. homebrew/core moves daily,
# so "N outdated" is true almost always; the applier is `make brew-upgrade`,
# never this. Pin drift is reported the same way: the enforcement is `brew pin`
# itself (see scripts/brew-upgrade.sh's header), this just names a surprise.
section_brew() {
  hdr "Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    skip "brew" "not installed"
    return
  fi
  local outdated pinned
  outdated=$(brew outdated --quiet 2>/dev/null | grep -c . || true)
  skip "outdated formula(e)/cask(s)" "${outdated:-0} (apply with: make brew-upgrade)"
  pinned=$(brew list --pinned 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  if [ "$pinned" = "caddy" ]; then
    skip "pinned" "caddy (as expected)"
  else
    skip "pinned" "expected exactly 'caddy', got '${pinned:-<none>}'"
  fi
}

# --- Drift (mini only, no push) -----------------------------------------------
# scripts/drift-check.sh --no-push: same report the daily agent would push to
# Uptime Kuma, without touching Kuma. Never applies anything — see that
# script's header for why an unattended upgrader on this host is the wrong
# trade.
section_drift() {
  hdr "Drift (pins, brew recency, macOS) — no push"
  local out rc
  out=$(bash "$DOTFILES_DIR/scripts/drift-check.sh" --no-push 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    ok "drift-check" "clean"
  else
    bad "drift-check" "drifted — see above"
  fi
}

# --- devhost heartbeat, named not run (mini only) -----------------------------
# scripts/devhost-health-check.sh has no print-only mode — every run pushes to
# `MacMini Dev Host - Push` if the push URL file exists. Running it here would
# violate this script's own read-only contract, so it is named instead of
# invoked; `make devhost-health-check` or the Kuma dashboard is the live read.
section_devhost_heartbeat() {
  hdr "devhost-health-check"
  skip "devhost-health-check" "always pushes to Uptime Kuma (no print-only mode) — run 'make devhost-health-check' by hand, or check the Kuma dashboard"
}

# --- Remote path — MacBook -> mini (MacBook only) -----------------------------
# Harvested from scripts/remote-dev-doctor.sh, layers 1/2/4 plus the GitHub
# credential + push-rights checks. Layer 3 (the mosh path) is dropped — mosh
# is retired. The reverse mini->iumac leg is dropped too: it is only
# meaningful running ON the mini (gated on backend=cache there), which this
# section by definition is not.
section_remote_path() {
  hdr "Remote path — MacBook → $HOST"

  # shellcheck source=lib/tailscale-cli.sh
  source "$DOTFILES_DIR/scripts/lib/tailscale-cli.sh"
  if [ -n "${TAILSCALE_BIN:-}" ]; then
    local ping_out
    ping_out=$(ts_run ping --c=1 "$HOST" 2>&1 | head -1)
    case "$ping_out" in
      *"via DERP"*) ok "tailscale reachable" "via DERP relay — slower than it should be" ;;
      pong*)        ok "tailscale reachable" "direct" ;;
      *)            bad "tailscale reachable" "$ping_out" ;;
    esac
  else
    skip "tailscale reachable" "Tailscale.app not found"
  fi

  if ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    ok "ssh $HOST" "$(ssh "$HOST" 'echo $USER@$(hostname -s)' 2>/dev/null)"
  else
    bad "ssh $HOST" "cannot connect — check 'ssh -v $HOST'"
  fi

  if ssh -O check "$HOST" >/dev/null 2>&1; then
    ok "ControlMaster" "multiplexing live (one handshake, one biometric approval)"
  else
    skip "ControlMaster" "no master socket — next connection creates one"
  fi

  if ssh "$HOST" 'ssh-add -l' >/dev/null 2>&1; then
    ok "agent forwarding" "mini can use this machine's keys"
  else
    bad "agent forwarding" "forwarded agent has no usable keys"
  fi

  local running
  running=$(ssh "$HOST" 'herdr status --json 2>/dev/null' 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("server",{}).get("running"))' 2>/dev/null)
  if [ "$running" = "True" ]; then
    ok "herdr server" "running on $HOST"
  else
    bad "herdr server" "down — 'brew services restart herdr' on $HOST"
  fi

  if ssh "$HOST" 'test -f "$HOME/.claude/hooks/herdr-agent-state.sh"' 2>/dev/null; then
    ok "herdr agent-state hook" "panes report real agent status"
  else
    bad "herdr agent-state hook" "run 'make herdr-setup' on $HOST"
  fi

  if ! ssh "$HOST" 'printf "protocol=https\nhost=github.com\n\n" | "$HOME/.local/bin/git-credential-secrets-cache" get 2>/dev/null | grep -q "^password=."' 2>/dev/null; then
    bad "github credential" "unresolvable — 'make git-headless' / 'make secrets-seed'"
  else
    ok "github credential" "resolves from the secrets cache"

    # A resolvable token that lacks Contents:write fails only on a real push —
    # exactly how a read-only PAT hid before. --dry-run performs the same
    # git-receive-pack authorization check GitHub does, without writing.
    local probe
    probe=$(ssh "$HOST" 'cd "$HOME/SourceRoot/dotfiles" 2>/dev/null \
      && GIT_TERMINAL_PROMPT=0 git push --dry-run origin HEAD:refs/heads/doctor-push-probe 2>&1' 2>/dev/null)
    case "$probe" in
      *"[new branch]"*|*"Everything up-to-date"*)
        ok "github push rights" "verified by dry-run (nothing written)" ;;
      *denied*|*403*|*"Authentication failed"*)
        bad "github push rights" "token resolves but cannot push — needs Contents: read and write" ;;
      *)
        skip "github push rights" "inconclusive — ${probe:-no output from git}" ;;
    esac
  fi
}

# --- Kuma monitor states (MacBook only) ---------------------------------------
# Read straight from Uptime Kuma's SQLite on homelab, over keyless Tailscale
# SSH — the one view of the dev host that survives the dev host being down or
# 1Password being locked. Harvested from scripts/mini-sweep.sh.
section_kuma() {
  hdr "Uptime Kuma — MacMini monitors (via $KUMA_HOST, keyless)"
  local kuma_sql kuma_out
  kuma_sql='SELECT m.name || "|" ||
    CASE h.status WHEN 1 THEN "UP  " ELSE "DOWN" END || "|" ||
    datetime(h.time) || "|" || substr(coalesce(h.msg,""),1,84)
    FROM monitor m JOIN heartbeat h
      ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1)
    WHERE m.name LIKE "%MacMini%" ORDER BY m.name;'
  # shellcheck disable=SC2029  # both expand HERE on purpose: db path + query
  kuma_out=$(ssh -o ConnectTimeout=6 -o BatchMode=yes "$KUMA_HOST" "sqlite3 -readonly '$KUMA_DB' '$kuma_sql'" 2>/dev/null)
  if [ -z "$kuma_out" ]; then
    skip "kuma monitors" "unavailable ($KUMA_HOST unreachable or sqlite3 missing) — not a dev-host fault"
    return
  fi
  printf '%s\n' "$kuma_out" | while IFS='|' read -r name status when msg; do
    printf '    %-28s %s  %s utc  %s\n' "$name" "$status" "$when" "$msg"
  done
  # `case`, not `grep -q`: under pipefail a grep that exits early on its first
  # match turns the writer's SIGPIPE into a false failure.
  case "$kuma_out" in
    *"|DOWN|"*) bad "kuma monitors" "at least one MacMini monitor is DOWN — see above" ;;
    *)          ok "kuma monitors" "all up" ;;
  esac
}

# --- Run -----------------------------------------------------------------------

section_launchagents
section_architecture
section_brew

if [ "$BACKEND" = "cache" ]; then
  section_drift
  section_devhost_heartbeat
elif [ "$BACKEND" = "op" ]; then
  section_remote_path
  section_kuma

  if [ "$LOCAL_ONLY" -eq 0 ]; then
    hdr "Recursing into the mini (make doctor, 120s timeout)"
    TIMEOUT_BIN="${TIMEOUT_BIN:-}"
    if [ -z "$TIMEOUT_BIN" ]; then
      command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
    fi
    if [ -z "$TIMEOUT_BIN" ]; then
      command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
    fi

    mini_rc=0
    if [ -n "$TIMEOUT_BIN" ]; then
      "$TIMEOUT_BIN" 120 ssh "$HOST" 'cd ~/SourceRoot/dotfiles && make doctor'
      mini_rc=$?
    else
      skip "mini doctor" "no 'timeout'/'gtimeout' on PATH — running unbounded"
      ssh "$HOST" 'cd ~/SourceRoot/dotfiles && make doctor'
      mini_rc=$?
    fi

    if [ "$mini_rc" -eq 0 ]; then
      ok "mini doctor" "clean"
    elif [ "$mini_rc" -eq 124 ]; then
      bad "mini doctor" "timed out after 120s"
    else
      bad "mini doctor" "exit $mini_rc — see output above"
    fi
  else
    skip "mini doctor" "--local: not recursing into $HOST"
  fi
else
  skip "backend" "unrecognised secrets backend '${BACKEND:-<empty>}' in $BACKEND_FILE — mini/MacBook-only sections skipped"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "  $pass passed, $skipped skipped — clean."
  exit 0
fi
echo "  $pass passed, $fail FAILED, $skipped skipped."
exit 1
