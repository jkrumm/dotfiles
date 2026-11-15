#!/usr/bin/env bash
set -u -o pipefail   # NOT -e: one section failing must not abort the rest

# doctor — read-only health of this machine, and (from the MacBook) the mini
# too. One command, one place to look: this machine's LaunchAgents, the
# architecture map, brew, the on-demand half of scripts/drift-check.sh (its
# daily-push half stays a separate LaunchAgent — see below), and from the
# MacBook the whole remote path plus the Kuma view of the mini.
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
# Two grades of the same sections:
#   doctor (default)  every finding fails the run — the owner's full view of the machine
#   --verify          what `make verify` runs, the factory's Watch of a dotfiles change. It fails only on
#                     what a change to this repo can break and WARNs on host conditions and other leads'
#                     drift: another owner's agent not in the map or the registry, a stale map row, a
#                     LaunchAgent not pointing into this checkout, an unclassified TCC program, a DOWN Kuma
#                     monitor. Still FAIL there: herdr-core, Claude account routing, an agent whose plist
#                     points into this checkout, an unmapped label of this checkout, a registry rule breach.
#                     (Pending OS/tailscale/collie updates, failing jobs and storage are WARN in both.)
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
VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL_ONLY=1 ;;
    --verify) VERIFY=1 ;;
    *) echo "usage: $(basename "$0") [--local] [--verify]" >&2; exit 1 ;;
  esac
done

# The main checkout of this repo (a worktree shares its .git): a LaunchAgent whose plist names a path in it is this repo's.
OWN_ROOT=$(dirname "$(git -C "$DOTFILES_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")

pass=0
fail=0
skipped=0

ok()   { printf '  \033[32m✓\033[0m %-30s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %-30s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
skip() { printf '  \033[33m·\033[0m %-30s %s\n' "$1" "${2:-}"; skipped=$((skipped + 1)); }
# A finding no change to this repo causes: a FAIL in doctor, a WARN in --verify.
host_bad() { if [ "$VERIFY" -eq 1 ]; then skip "$1" "WARN: ${2:-} (doctor fails this; not this repo's change)"; else bad "$1" "${2:-}"; fi; }
hdr()  { printf '\n  \033[1m%s\033[0m\n' "$1"; }

echo ""
echo "  $([ "$VERIFY" -eq 1 ] && echo verify || echo doctor) — $(hostname -s 2>/dev/null || echo "this machine") (backend=${BACKEND:-unset})"

# --- LaunchAgents (both machines) --------------------------------------------
# A missing program/WorkingDirectory, a down KeepAlive job, /tmp logs, and a
# plaintext credential in EnvironmentVariables. Each check exists because it
# once went unreported — two agents accumulated 40,000+ failed spawns with
# nothing saying so (docs/devhost-health.md).
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
      if grep -qF "$OWN_ROOT/" "$plist" 2>/dev/null; then bad "$label" "${issues#; }"; else host_bad "$label" "${issues#; }"; fi
    else
      ok "$label" ""
    fi
  done
}

# --- herdr-core (both machines) ----------------------------------------------
# The same grader the mini's heartbeat runs (scripts/lib/core-health.sh): the core is up
# (lib/core-up.sh: the socket answers AND a launchd-born core exists, else FAIL, a stray included), `hc server
# status` answers, core and holders are attributed to Herdr Core.app (hc-responsible.py, WARN), version parity
# with the other machine (WARN). core_up runs before any `hc` call, because `hc` auto-starts a stray core.
section_core() {
  hdr "herdr-core"
  # shellcheck source=lib/core-health.sh
  source "$DOTFILES_DIR/scripts/lib/core-health.sh"
  local msg rc=0
  msg=$(core_health_check) || rc=$?
  case "$rc" in
    0) ok "herdr-core" "$msg" ;;
    2) skip "herdr-core" "WARN: $msg" ;;
    *) bad "herdr-core" "$msg" ;;
  esac
}

# --- Architecture map (both machines) ----------------------------------------
# Every launchd label loaded/on-disk on this machine must appear in
# docs/architecture.md. The script itself already covers both machines (the
# MacBook's agent list was inventoried into the map 2026-08-30) — nothing to
# extend here, just run it.
section_architecture() {
  hdr "Architecture map (docs/architecture.md)"
  local out rc
  local soft=""
  [ "$VERIFY" -eq 1 ] && soft="--soft"
  out=$(bash "$DOTFILES_DIR/scripts/architecture-check.sh" $soft 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    ok "architecture map" "every loaded/on-disk label is mapped, every mapped label exists"
  else
    bad "architecture map" "map drift (unmapped or stale labels) — see above"
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

# --- Worktrees (both machines) ------------------------------------------------
# Nudge only, never fails: reclaimable git worktrees across SourceRoot +
# IuRoot. scripts/worktree-audit.sh --count does the actual scan/classify;
# this just surfaces the one-line result.
section_worktrees() {
  hdr "Worktrees"
  local line
  line=$(bash "$DOTFILES_DIR/scripts/worktree-audit.sh" --count 2>/dev/null) || line="worktrees: check failed"
  skip "worktrees" "${line#worktrees: }"
}

# --- Drift (mini only, no push) -----------------------------------------------
# scripts/drift-check.sh --no-push: same report the daily heartbeat side job pushes to
# Uptime Kuma, without touching Kuma. Never applies anything — see that
# script's header for why an unattended upgrader on this host is the wrong
# trade.
section_drift() {
  hdr "Drift (pins, brew recency, macOS) — no push"
  local out rc
  out=$(bash "$DOTFILES_DIR/scripts/drift-check.sh" --no-push 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  # Stale drift (a pending OS update, a Tailscale release) is maintenance that waits for the
  # owner's window, not a broken host. The `MacMini Drift - Push` monitor already pages it;
  # failing verify as well turned every factory Watch red for changes that cannot move it
  # (Issue 737). So stale entries (`✗` lines) are a WARN. An exit 1 without one is a crashed
  # script, and that stays a FAIL.
  if [ "$rc" -eq 0 ]; then
    ok "drift-check" "clean"
  elif [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^ *✗ '; then
    skip "drift-check" "WARN: stale drift past its grace — see above (the Drift monitor pages it)"
  else
    bad "drift-check" "drift-check failed (exit $rc) — see above"
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

# --- Claude accounts (mini) ---------------------------------------------------
# claude-accounts-verify is the only grader (docs/claude-accounts.md §Operate): FAIL rows fail this section, WARN rows don't.
section_claude_accounts() {
  hdr "Claude accounts (claude-accounts-verify)"
  local out rc=0
  # Over ssh the login keychain is invisible (every account reads "NOT logged in"). Outside a core terminal, run the
  # verify through the running herdr-core, whose children see the keychain. Never `hc` when no core runs: it would start a stray one.
  # shellcheck source=lib/core-up.sh
  source "$DOTFILES_DIR/scripts/lib/core-up.sh"
  if [ -z "${HC_TERMINAL_ID:-}" ] && command -v hc >/dev/null 2>&1 && core_up; then
    out=$(hc exec --timeout 120 /bin/bash "$DOTFILES_DIR/scripts/claude-accounts-verify.sh" 2>&1) || rc=$?
  else
    out=$(/bin/bash "$DOTFILES_DIR/scripts/claude-accounts-verify.sh" 2>&1) || rc=$?
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    ok "claude accounts" "$(printf '%s\n' "$out" | tail -n 1)"
  else
    bad "claude accounts" "verify reported FAIL rows — see above (make claude-accounts-verify)"
  fi
}

# --- Remote path — MacBook -> mini (MacBook only) -----------------------------
# Tailscale, ssh, ControlMaster, agent isolation + forwarding (mini-fwd), then the GitHub
# credential + push rights. The reverse mini->iumac leg is not probed here: it
# is only meaningful running ON the mini, which this section by definition is
# not.
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

  # Plain `ssh mini` must never touch the 1Password agent (macOS AppData dialog).
  local cfg
  cfg=$(ssh -G "$HOST" 2>/dev/null)
  if printf '%s\n' "$cfg" | grep -qx 'identityagent none' && printf '%s\n' "$cfg" | grep -qx 'forwardagent no'; then
    ok "ssh $HOST agent-free" "IdentityAgent none, ForwardAgent no"
  else
    bad "ssh $HOST agent-free" "ssh -G $HOST must report identityagent none + forwardagent no (make _setup-ssh)"
  fi

  # Forwarding lives on the mini-fwd alias (1Password agent; may prompt).
  if ssh -o ControlPath=none -o BatchMode=yes "$HOST-fwd" 'ssh-add -l' >/dev/null 2>&1; then
    ok "agent forwarding" "$HOST-fwd: mini can use this machine's keys"
  else
    bad "agent forwarding" "$HOST-fwd: forwarded agent has no usable keys"
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
# 1Password being locked.
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
    *"|DOWN|"*) host_bad "kuma monitors" "at least one MacMini monitor is DOWN — see above" ;;
    *)          ok "kuma monitors" "all up" ;;
  esac
}

# --- Background jobs (both machines) -------------------------------------------
# The graded table from jobs-grade — the only grading logic. Informational: a bad
# grade is a skip-style note here, the heartbeat relays it to Slack.
section_jobs() {
  hdr "Background jobs (jobrun state dir)"
  local bun_dir out summary rc=0
  bun_dir=$(/bin/bash "$DOTFILES_DIR/scripts/lib/bun-bin.sh" 2>/dev/null) || { skip "jobs" "bun not found — not graded"; return; }
  out=$("$bun_dir/bun" "$DOTFILES_DIR/scripts/lib/jobs-grade.ts" --table 2>&1) || rc=$?   # one grading run: table + verdict line
  summary=$(printf '%s\n' "$out" | tail -n 1)
  printf '%s\n' "$out" | sed '$d' | sed 's/^/    /'
  case "$rc" in
    0) ok "jobs" "$summary" ;;
    2) skip "jobs" "$summary (the heartbeat posts changes to Slack)" ;;
    *) skip "jobs" "jobs-grade failed (rc=$rc): $summary" ;;
  esac
}

# --- Service registry (mini) --------------------------------------------------
# config/mini/services.yaml + the repos' mini-services.yaml (docs/mini-registry.md): FAIL on a loaded job the registry does
# not know, on a job whose program is inside a worktree and on a service below its declared process_type (or whose plist lost it); a budget breach is a WARN. The same check feeds the heartbeat.
section_registry() {
  hdr "Service registry (make mini-ps)"
  local bun_dir out summary debt rc=0
  bun_dir=$(/bin/bash "$DOTFILES_DIR/scripts/lib/bun-bin.sh" 2>/dev/null) || { skip "registry" "bun not found — not checked"; return; }
  out=$("$bun_dir/bun" "$DOTFILES_DIR/scripts/mini-registry.ts" check 2>&1) || rc=$?
  summary=$(printf '%s\n' "$out" | tail -n 1)
  printf '%s\n' "$out" | sed '$d' | sed 's/^/    /'
  debt=$("$bun_dir/bun" "$DOTFILES_DIR/scripts/mini-registry.ts" debt 2>&1) || true
  if [[ -n "$debt" ]]; then
    printf '    recorded breaches (debt, exceptions; rules/run-on-mini.md):\n'
    printf '%s\n' "$debt" | sed 's/^/      /'
  fi
  # --verify: another lead's fresh unregistered job, or a name two repos' registry files both claim, is not this change's.
  # An invalid registry prints "FAIL registry invalid:" plus indented error lines and no summary; every other FAIL line stays a FAIL.
  if [ "$rc" -eq 1 ] && [ "$VERIFY" -eq 1 ]; then
    local own_fail
    own_fail=$(printf '%s\n' "$out" | grep -vE '^FAIL loaded job not in the registry|^registry: ' \
      | grep -E '^FAIL|^  [^ ]' | grep -vE '^  duplicate name |^FAIL registry invalid:$' || true)
    if [ -z "$own_fail" ]; then rc=2; fi
  fi
  case "$rc" in
    0) ok "registry" "$summary" ;;
    2) skip "registry" "WARN: $summary" ;;
    *) bad "registry" "$summary" ;;
  esac
}

# TCC: a LaunchAgent program that is ad-hoc signed or on a versioned path loses its file-access grant on every
# upgrade (docs/tcc.md). Static and read-only; the check itself lives in scripts/tcc-check.sh.
section_tcc() {
  hdr "TCC (durable file-access grants)"
  local out rc=0
  out=$(bash "$DOTFILES_DIR/scripts/tcc-check.sh" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then ok "tcc" "$(printf '%s' "$out" | sed 's/^ *✓ tcc: //')"; return; fi
  printf '%s\n' "$out" | sed 's/^/    /'
  host_bad "tcc" "unclassified LaunchAgent program(s) above (docs/tcc.md)"
}

# External volume (docs/external-ssd.md), the mini's only (BACKEND=cache): silent while config/external-volume.json says attached=false; with it true,
# OK when present, a yellow WARN (never a failure) when absent, locked or unreadable.
section_external_volume() {
  local out rc=0
  out=$(bash "$DOTFILES_DIR/scripts/external-volume-check.sh" 2>&1) || rc=$?
  [ -n "$out" ] || return 0
  hdr "External volume"
  if [ "$rc" -eq 0 ]; then ok "external volume" "$out"; else skip "external volume" "WARN: $out"; fi
}

# Storage (docs/storage.md §Status), both machines: warns on a declared automount share that is not healthy and, on the
# mini, on a mirror older than 36 h. A warning, never a failure, and never in the liveness push.
section_storage() {
  hdr "Storage (make storage-status)"
  local out rc=0 n
  out=$(bash "$DOTFILES_DIR/scripts/storage-status.sh" --json 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    skip "storage" "storage-status failed (rc=$rc): $(printf '%s' "$out" | head -n 1)"
    return
  fi
  if [ "$(printf '%s' "$out" | jq '.shares | length')" -eq 0 ]; then
    skip "storage shares" "$(printf '%s' "$out" | jq -r '.shares_reason // "none declared"')"
  fi
  while IFS='|' read -r name state warned reason; do
    [ -n "$name" ] || continue
    if [ "$warned" = true ]; then skip "storage $name" "WARN: $state: $reason"
    else ok "storage $name" "$state"; fi
  done < <(printf '%s' "$out" | jq -r '. as $s | .shares[] | .name as $n | "\(.name)|\(.state)|\([$s.warnings[] | select(.subject == $n)] | length > 0)|\(.reason // "")"')
  n=$(printf '%s' "$out" | jq -r '.warnings[] | select(.code == "mirror_stale") | .message')
  if [ -n "$n" ]; then skip "storage mirror" "WARN: $n"
  elif [ "$(printf '%s' "$out" | jq '.mirror.available')" = true ]; then ok "storage mirror" "finished $(printf '%s' "$out" | jq '(.mirror.age_seconds / 3600) | floor') h ago"; fi
}

# --- Run -----------------------------------------------------------------------

section_launchagents
section_core
section_tcc
section_architecture
section_jobs
section_storage
section_brew
section_worktrees

if [ "$BACKEND" = "cache" ]; then
  section_external_volume   # the mini's drive: never on the MacBook
  section_registry
  section_drift
  section_claude_accounts
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
      "$TIMEOUT_BIN" 120 ssh "$HOST" "cd ~/SourceRoot/dotfiles && make $([ "$VERIFY" -eq 1 ] && echo verify || echo doctor)"
      mini_rc=$?
    else
      skip "mini doctor" "no 'timeout'/'gtimeout' on PATH — running unbounded"
      ssh "$HOST" "cd ~/SourceRoot/dotfiles && make $([ "$VERIFY" -eq 1 ] && echo verify || echo doctor)"
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
