#!/usr/bin/env bash
set +x
set -euo pipefail

# devhost-health-check — remote-dev readiness HEARTBEAT for the Mac mini,
# reported to an Uptime Kuma push monitor (`MacMini Dev Host - Push`, group
# `Local`).
#
# Why push and not a probe: the Tailscale ACL grants `tag:homelab → tag:vps`
# but NOT `tag:homelab → tag:mac`, so the homelab Uptime Kuma physically
# cannot reach the mini. Rather than open an inbound grant just for monitoring
# (new attack surface, for a check that only ever reports on the mini itself),
# the mini pushes outbound over the already-granted `tag:mac → tag:homelab`
# tcp:443. Same pattern as MacMini Secret Seed - Push and the Hermes monitors.
#
# ONE composite monitor, not five: herdr/sshd/tailscaled/mosh all fail together
# when the mini sleeps or drops off the tailnet, so separate monitors would just
# be simultaneous pages saying the same thing. The failing component is named in
# the push `msg`, which is where the diagnosis belongs.
#
# `check_git_push` is the deliberate exception to that reasoning: it fails on
# its own schedule (a token expires while the host is perfectly healthy) rather
# than with the other four. It is folded in anyway because a second monitor
# wasn't worth it for one component. Revisit if it ever pages independently
# often enough to be noise.
#
# `check_dev_vhosts` (the clean https://<app>.$DEV_DOMAIN door — see
# scripts/caddy-tailnet.sh) is the same exception for the same reason: a
# reverted DNS module, an aging cert, or a drifted A record can each happen
# on a perfectly healthy dev host, independently of herdr/sshd/tailscaled/mosh
# — but it is one component, not another whole monitor. It SKIPS (not fails)
# on a machine that never set DEV_DOMAIN — see its own comment.
#
# `make uk-sync` CAN create push monitors — settled by doing it on 2026-07-28,
# when it created "MacMini Collie - Push" (id=205) against uptime-kuma:2 with
# uptime-kuma-api 1.2.1. Worth recording how this went wrong twice, because the
# failure mode was documentation rather than code: seven comments in
# homelab/uptime-kuma/monitors.yaml plus one in sync.py asserted the opposite,
# so a stale note got treated as a constraint and briefly "corrected" the
# accurate claim here into a false one. The token is fetchable too
# (api.get_monitor(id)["pushToken"]), so wiring a new monitor needs no browser.
# Read the call site, not the comment above it.
#
# Collie is NOT in the loop below for that reason turned around: it genuinely
# does not fail with the other five, so it got its own monitor rather than an
# exception. See the block after the composite push at the bottom. Secrets
# freshness is the second such case, folded in here from its own weekly
# LaunchAgent — see that block for why weekly was the wrong cadence.
#
# The composite has since grown past "the four that fail together": memory
# pressure, launchd restart counts, always-on service liveness, `claude auth`,
# the obsidian CLI, disk, and runaway processes are all in it. That is the same
# judgement check_git_push and check_dev_vhosts already record, applied
# repeatedly: each of them CAN fail while the other components are healthy, and
# for each of them a dedicated Kuma monitor was worth less than one more named
# component in the msg. The line that still holds is the one collie and secrets
# freshness are on the far side of — a component that can be ABSENT on a
# perfectly good machine gets its own monitor, because folding it in would page
# "dev host DOWN" for a feature this host does not have.
#
# Fail-loud, never fail-silent: if the push URL can't be resolved we exit
# non-zero WITHOUT pushing, so Uptime Kuma's own missed-heartbeat fires. A
# monitor that silently stops reporting is worse than no monitor.
#
# bash 3.2 ONLY. launchd hands a user agent PATH=/usr/bin:/bin:/usr/sbin:/sbin
# unless the plist says otherwise, and this one does not — so `/usr/bin/env
# bash` resolves to Apple's /bin/bash 3.2, not Homebrew's 5.x, even though
# `make devhost-health-check` from an interactive shell gets 5.x. No mapfile,
# no ${var,,}, and no "${arr[@]}" on a possibly-empty array (3.2 calls that an
# unbound variable under `set -u`). New accumulators here are strings for
# exactly that reason.
#
# Usage: devhost-health-check.sh
#   DEVHOST_PUSH_URL       Uptime Kuma push URL; if unset, read from the
#                          chmod-600 DEVHOST_PUSH_URL_FILE below.

# LaunchAgents get a minimal PATH and no shell aliases — note `tailscale` is an
# alias to the app bundle in the interactive shell and would simply not exist
# here. Resolve every binary by absolute path.
HERDR_BIN="${HERDR_BIN:-/opt/homebrew/bin/herdr}"
MOSH_SERVER_BIN="${MOSH_SERVER_BIN:-/opt/homebrew/bin/mosh-server}"
# Tailscale CLI: resolved by lib/tailscale-cli.sh, NOT hardcoded. The mini moved
# to the open-source brew daemon on 2026-08-06 while the app-bundle path stayed
# on disk (the dormant macsys extension is kept for rollback) — so the old
# hardcoded path still answers here, from the stopped daemon, and this check
# would page "tailnet down" on a healthy host. See that lib's header.
# shellcheck source=lib/tailscale-cli.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tailscale-cli.sh"
GIT_CRED_HELPER_BIN="${GIT_CRED_HELPER_BIN:-$HOME/.local/bin/git-credential-secrets-cache}"
ALF_BIN="${ALF_BIN:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
COLLIE_PLIST="${COLLIE_PLIST:-$HOME/Library/LaunchAgents/herdr.collie.plist}"
COLLIE_URL="${COLLIE_URL:-http://127.0.0.1:8787}"
CADDY_BIN="${CADDY_BIN:-/opt/homebrew/bin/caddy}"
DIG_BIN="${DIG_BIN:-/usr/bin/dig}"
OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"
DATE_BIN="${DATE_BIN:-/bin/date}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
AWK_BIN="${AWK_BIN:-/usr/bin/awk}"
SED_BIN="${SED_BIN:-/usr/bin/sed}"
PS_BIN="${PS_BIN:-/bin/ps}"
DF_BIN="${DF_BIN:-/bin/df}"
LSOF_BIN="${LSOF_BIN:-/usr/sbin/lsof}"
SYSCTL_BIN="${SYSCTL_BIN:-/usr/sbin/sysctl}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
# The fallback credential path claude-auth.zsh uses. Needed here so the auth
# check can see which of the two credentials is actually holding the host up.
SECRETS_RUN_BIN="${SECRETS_RUN_BIN:-$HOME/.local/bin/secrets-run}"
OBSIDIAN_BIN="${OBSIDIAN_BIN:-/usr/local/bin/obsidian}"
PLISTBUDDY_BIN="${PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
# Both halves of colima's supervised boot path, named once so probe_colima and
# the DEVHOST_SERVICES gate below cannot drift apart. The wrapper path is the
# checkout path on purpose — it is what `make _colima-supervise` writes into the
# plist, so anything else in there means brew regenerated it.
COLIMA_PLIST="${COLIMA_PLIST:-$HOME/Library/LaunchAgents/homebrew.mxcl.colima.plist}"
COLIMA_START_WRAPPER="${COLIMA_START_WRAPPER:-$HOME/SourceRoot/dotfiles/colima/colima-start.sh}"
CADDY_ADMIN_URL="${CADDY_ADMIN_URL:-http://127.0.0.1:2019}"
SIDECLAW_URL="${SIDECLAW_URL:-http://127.0.0.1:7705}"
LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
HERMES_PORT="${HERMES_PORT:-8642}"

# Thresholds, every one overridable so a check can be driven to its failing
# side on a healthy machine — otherwise the only way to test the alarm is to
# break the host.
MEM_SWAP_PCT_MAX="${DEVHOST_MEM_SWAP_PCT_MAX:-25}"
DISK_USED_PCT_MAX="${DEVHOST_DISK_USED_PCT_MAX:-90}"
DISK_FREE_GB_MIN="${DEVHOST_DISK_FREE_GB_MIN:-20}"
# 30d, not the cert check's 21d, and the asymmetry is the point: an expired
# wildcard cert is fixable over the tailnet, an expired NODE KEY takes the
# tailnet itself away and needs a human at the machine. Lead time has to be
# longer for the failure you cannot fix remotely.
TS_KEY_EXPIRY_DAYS_MIN="${DEVHOST_TS_KEY_EXPIRY_DAYS_MIN:-30}"
RUNAWAY_CPU_MINUTES="${DEVHOST_RUNAWAY_CPU_MINUTES:-600}"
RUNAWAY_CPU_PCT_MIN="${DEVHOST_RUNAWAY_CPU_PCT_MIN:-50}"
SECRETS_FRESHNESS_MAX_AGE_DAYS="${SECRETS_FRESHNESS_MAX_AGE_DAYS:-8}"
SECRETS_CACHE_FILE="${SECRETS_CACHE_FILE:-$HOME/SourceRoot/dotfiles-private/cache/secrets.enc.json}"
# Restart detection is a DELTA, so it needs somewhere to remember the last
# reading. ~/.local/state, not /tmp: /tmp is world-writable and this file
# decides whether a page fires.
STATE_DIR="${DEVHOST_HEALTH_STATE_DIR:-$HOME/.local/state/devhost-health}"

# --- Transient tolerance -----------------------------------------------------
# WHY THIS EXISTS. The first real power-cut test (2026-08-01) produced a DOWN
# page that was pure noise: the host booted at 08:53:20, this agent ran at
# 08:54:24, and sideclaw + linewatch-collector did not come up until 08:56:08 —
# ~2m48s after boot, both at the same second, i.e. a deferred launchd bootstrap
# pass rather than a fault. Everything was healthy by the next run. With
# `maxretries 0` on the Kuma side (deliberate — it keeps time-to-DOWN at 10min
# rather than 40), that single failed push is a full DOWN alert on EVERY reboot.
#
# A monitor that cries wolf after every power blip does not make you better
# informed, it trains you to ignore it — and then the one real outage looks like
# the twelve fake ones. So: report, do not hide.
#
# THE DISTINCTION THAT MATTERS is LEVEL-triggered vs EDGE-triggered, not
# liveness vs state — that was the first cut and it was wrong twice over.
#
# A consecutive-failure counter only works for a LEVEL-triggered check, where the
# condition keeps being true while it is broken. An EDGE-triggered check fires
# once on a transition and clears itself on the next run, so it can never reach a
# streak of 3 — a threshold does not delay it, it silences it PERMANENTLY.
# check_launchd_restarts is exactly that: a delta against a state file, true for
# one run per restart. It must stay immediate.
#
# Everything else is level-triggered and gets the streak, including the state
# checks. Delaying a cert-expiry or disk-full page by ~15 minutes costs nothing
# real (a 21-day cert warning does not care), while flap tolerance is worth a
# lot — a dig that fails once should not page. The first cut kept state checks
# immediate and still paged on every reboot anyway, via cascade:
# check_dev_vhosts needs the tailnet IP, so it fails whenever tailscaled is
# merely slow.
#
# WHAT THIS DOES NOT RELAX: if the host is gone, no push lands at all and Kuma's
# own missed-heartbeat fires on its own schedule, untouched by anything here.
# Time-to-DOWN for "the machine died" is unchanged; only in-band component
# failures on a machine that is still talking get slack.
BOOT_GRACE_SECONDS="${DEVHOST_BOOT_GRACE_SECONDS:-300}"
TRANSIENT_FAILS_BEFORE_ALERT="${DEVHOST_TRANSIENT_FAILS:-3}"
IMMEDIATE_COMPONENTS="check_launchd_restarts"
# Show "host rebooted" for two check intervals, so a reboot is visible in the
# heartbeat text rather than only as a gap someone has to notice.
REBOOT_NOTE_SECONDS="${DEVHOST_REBOOT_NOTE_SECONDS:-600}"

# Seconds since boot. Returns a LARGE number when kern.boottime cannot be
# parsed — failing toward "no grace, alert normally" rather than toward a
# permanent grace window that would silence this script forever.
#
# ANCHOR THE PATTERN. kern.boottime prints
#     { sec = 1785567200, usec = 570831 } Sat Aug  1 08:53:20 2026
# and a leading `.*sec = ` is GREEDY, so it matches the SECOND occurrence and
# captures **usec**. That yielded uptime ≈ 1.78e9 on a host up 12 minutes, which
# silently disables every grace window below while every test still passes —
# caught here only because the reboot note failed to appear. Anchor at `^{`.
#
# The plausibility check is the backstop for the next variant of that bug: any
# reading that is negative, or implies a boot before 2020, is treated as a parse
# failure rather than trusted. A wrong-but-huge number is the dangerous
# direction, because it looks like a healthy long-running host.
host_uptime_seconds() {
  local boot now up
  boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')
  case "${boot:-}" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  if (( boot < 1600000000 )); then echo 999999; return 0; fi
  now=$(date +%s)
  up=$(( now - boot ))
  if (( up < 0 )); then echo 999999; return 0; fi
  echo "$up"
}

# Same env var name scripts/caddy-tailnet.sh reads — one machine-local file,
# one name, so there is exactly one place to look when either disagrees with
# the other about whether the clean dev-vhost door is configured.
CADDY_TAILNET_CONF="${CADDY_TAILNET_CONF:-$HOME/.config/caddy-tailnet.conf}"
CADDY_TAILNET_INCLUDE="${CADDY_TAILNET_INCLUDE:-/opt/homebrew/etc/Caddyfile.d/tailnet.caddy}"

# The push token is low-sensitivity (it can only spoof a heartbeat) but still
# lives in a chmod-600 file rather than 1Password on purpose: monitoring must not
# depend on the secrets cache being seeded, or a stale cache would take the
# monitor down with it. Resolution + push live in the shared lib.
# shellcheck source=lib/kuma-push.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/kuma-push.sh"

PUSH_URL_FILE="${DEVHOST_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/devhost-push-url}"
push_url=$(kuma_resolve_push_url "${DEVHOST_PUSH_URL:-}" "$PUSH_URL_FILE") || exit 1

push() { kuma_push "$push_url" "$1" "$2"; }

# --- Shared helpers -----------------------------------------------------------

# `tailscale status --json` is wanted by three checks (backend state + key
# expiry here, the node IP in check_dev_vhosts, the node IP again to reach
# Hermes). It is read ONCE, EAGERLY, at load time — see the assignment below the
# function — so all three read the same snapshot and cannot disagree with each
# other inside a single run.
#
# EAGER, not lazy-with-a-cache, and that is the whole point: every check runs
# inside `detail=$("$component")`, i.e. a SUBSHELL, so a cache variable assigned
# on first use is assigned in a child and discarded when it exits. A lazy cache
# here is not a slow cache, it is no cache at all — it looked like one for long
# enough to grow a comment claiming a consistency property it never delivered.
# Nothing is lost by being eager: check_tailscale runs unconditionally, so the
# snapshot is always needed.
#
# Emits one line: <BackendState>|<tailnet IPv4>|<days until KeyExpiry>
# The third field is EMPTY when the node key does not expire — the state WP1
# leaves this machine in — and "?" when it is present but unparseable.
_ts_snapshot() {
  local json
  json=$(ts_run status --json 2>/dev/null) || true
  [[ -n "$json" ]] || return 1
  "$PYTHON_BIN" -c '
import datetime, json, sys
d = json.load(sys.stdin)
me = d.get("Self") or {}
days = ""
ke = me.get("KeyExpiry")
if ke:
    days = "?"
    try:
        # RFC3339. Trim sub-second digits (tailscale can emit nanoseconds,
        # which fromisoformat rejects before 3.11) and normalise the Z.
        head, _, tail = ke.partition(".")
        if tail:
            ke = head + "+00:00"
        else:
            ke = ke.replace("Z", "+00:00")
        delta = datetime.datetime.fromisoformat(ke) - datetime.datetime.now(datetime.timezone.utc)
        days = str(delta.days)
    except ValueError:
        pass
print("%s|%s|%s" % (d.get("BackendState", ""), (me.get("TailscaleIPs") or [""])[0], days))
' <<<"$json" 2>/dev/null || return 1
}

# The one call. `|| _TS_SELF=""` because `set -e` would abort the whole run on an
# unreachable tailscaled — which is a condition check_tailscale exists to REPORT,
# not a reason to stop reporting.
_TS_SELF=$(_ts_snapshot) || _TS_SELF=""

tailscale_self() {
  [[ -n "$_TS_SELF" ]] || return 1
  printf '%s' "$_TS_SELF"
}

tailnet_ip() {
  local out ip
  out=$(tailscale_self) || return 1
  ip=${out#*|}; ip=${ip%%|*}
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

# `ps -o time=` / `-o etime=` in [[dd-]hh:]mm:ss[.ff] → whole seconds.
hms_to_seconds() {
  local t="$1" days=0 s=0 part old_ifs
  case "$t" in *-*) days=${t%%-*}; t=${t#*-} ;; esac
  t=${t%%.*}
  old_ifs="$IFS"; IFS=:
  # Deliberately unquoted: IFS=: is doing the splitting. The input is digits
  # and colons only, so there is nothing for a glob to match.
  # shellcheck disable=SC2086
  for part in $t; do s=$(( s * 60 + 10#$part )); done
  IFS="$old_ifs"
  echo $(( s + days * 86400 ))
}

http_code() {
  "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time "${2:-4}" "$1" 2>/dev/null || true
}

# --- Components -------------------------------------------------------------
# Each returns 0 and echoes a short OK detail, or returns 1 and echoes why.

check_tailscale() {
  local out state days
  out=$(tailscale_self) || out=""
  state=${out%%|*}
  days=${out##*|}
  [[ "$state" == "Running" ]] || { echo "tailscaled not Running (state=${state:-unreachable})"; return 1; }

  # THE CONTESTED-STACK CHECK. Nothing else here can see this failure, and it is
  # the worst-shaped one on this host. On 2026-08-06's first post-migration
  # reboot macOS relaunched the old macsys app as the container for its still
  # activated system extension, and two Tailscale stacks fought over the tunnel.
  # Every signal above stayed GREEN — BackendState Running, correct IP and tags,
  # 29 peers, `tailscale ping` 25ms — while sshd, caddy and even ICMP were
  # silently dropped. Only `tailscale serve` kept answering, because it
  # terminates inside tailscaled and never touches the host network stack.
  #
  # So this asserts the CAUSE, not the symptom. Probing a host port is the
  # obvious alternative and is strictly worse: this heartbeat runs ON the mini,
  # so it reaches every one of those ports over loopback and sees nothing wrong.
  if [[ "$TAILSCALE_BIN" == "/opt/homebrew/bin/tailscale" ]] \
     && /usr/bin/pgrep -x Tailscale >/dev/null 2>&1; then
    echo "the macsys Tailscale app is RUNNING alongside the brew daemon — two stacks contesting the tunnel; sshd/caddy/ICMP over the tailnet are being dropped right now even though everything else looks healthy (fix: quit it, move /Applications/Tailscale.app aside — docs/remote-dev.md §8)"
    return 1
  fi

  # Node-key expiry, which BackendState cannot see: it flips to a non-Running
  # state only AFTER the key expires, i.e. after the machine has already
  # dropped off the tailnet and taken ssh, mosh, every dev door and this very
  # push with it. There is no remote fix at that point — reauth is a browser on
  # the machine. So the useful assertion is days of lead time, not liveness.
  #
  # An EMPTY days field means the key does not expire (WP1 turns that on for
  # this node) and is SKIPPED, silently and permanently. That is the correct
  # steady state, not a degraded one — a check that nagged about a disabled
  # expiry would be pure noise on the machine it was written for.
  if [[ -z "$days" ]]; then
    echo "tailnet up (key expiry disabled)"
    return 0
  fi
  if [[ "$days" == "?" ]]; then
    # Surfaced rather than failed: an unreadable timestamp is a tailscale
    # output change, not an outage, and it is visible in the msg every run.
    echo "tailnet up (key expiry unreadable)"
    return 0
  fi
  (( days > TS_KEY_EXPIRY_DAYS_MIN )) \
    || { echo "tailnet node key expires in ${days}d (< ${TS_KEY_EXPIRY_DAYS_MIN}d) — reauth needs a browser ON the mini, so this is not remotely fixable once it lapses"; return 1; }
  echo "tailnet up (key ${days}d)"
}

check_sshd() {
  # Inbound auth is always the *connecting* machine's key — the mini has no
  # key for itself and cannot ssh to itself — so liveness here is "is something
  # listening on 22", not "can I authenticate". Note sshd is socket-activated:
  # `launchctl print` reports "not running" while idle, which is NOT a fault, so
  # the listening socket is the only honest signal.
  #
  # Capture first, match second. Piping into `grep -q` makes grep exit on the
  # first hit, netstat die of SIGPIPE, and `set -o pipefail` report the whole
  # pipeline as failed — a permanent false "sshd down" on a healthy machine.
  local netstat_out
  netstat_out=$(/usr/sbin/netstat -an 2>/dev/null) || true
  /usr/bin/grep -qE '\.22[[:space:]]+.*LISTEN' <<<"$netstat_out" \
    || { echo "sshd not listening on 22"; return 1; }
  echo "sshd listening"
}

check_herdr() {
  # `herdr status --json` exposes server.running as a real boolean. Prefer it
  # over scraping the human output: herdr is pre-1.0, and a reformatted status
  # line would silently flip a text scrape to the wrong answer rather than
  # failing loudly. A missing/!=true value here is treated as down, which is the
  # safe direction — an unreadable status IS a reason to look.
  local running
  running=$("$HERDR_BIN" status --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("server",{}).get("running"))' 2>/dev/null) || true
  [[ "$running" == "True" ]] \
    || { echo "herdr server down (brew service KeepAlive should have restarted it)"; return 1; }
  echo "herdr up"
}

check_mosh() {
  # mosh-server is spawned per-connection, so presence of the binary is the
  # only thing worth asserting about the process itself; a missing one means the
  # Brewfile drifted.
  [[ -x "$MOSH_SERVER_BIN" ]] || { echo "mosh-server missing"; return 1; }

  # The Application Firewall is per-process and does NOT auto-allow Homebrew
  # binaries (no Developer ID signature), so mosh-server must be in its
  # allowlist or every datagram is dropped AFTER a successful ssh handshake —
  # the client blames a firewalled UDP port, which reads like a missing
  # Tailscale ACL grant and sent one diagnosis entirely the wrong way.
  #
  # This is asserted on every run rather than trusted from `make mosh-firewall`
  # because socketfilterfw stores the RESOLVED path and the brew symlink points
  # into a version-stamped Cellar dir: `brew upgrade mosh` silently un-allows
  # it. The upgrade is the regression this is here to catch.
  local real
  real=$(/usr/bin/readlink -f "$MOSH_SERVER_BIN" 2>/dev/null || echo "$MOSH_SERVER_BIN")
  if [[ -x "$ALF_BIN" ]]; then
    local apps
    apps=$("$ALF_BIN" --listapps 2>/dev/null) || true
    /usr/bin/grep -qF "$real" <<<"$apps" \
      || { echo "mosh-server not in the Application Firewall allowlist — UDP will be dropped (fix: make mosh-firewall)"; return 1; }
  fi
  echo "mosh ready"
}

check_git_push() {
  # A dev host that cannot push is not a working dev host, and this is the one
  # component here that fails SILENTLY and INDEPENDENTLY of the other four.
  # That breaks the "one composite monitor" reasoning above slightly — it is
  # included anyway because the alternative was finding out during real work,
  # which is exactly what happened on 2026-07-26 when the old `gh` keyring token
  # expired unnoticed. The msg names the component, so the page is still
  # diagnosable.
  #
  # Ask the credential helper the same question git asks, rather than checking
  # the token some other way: the previous failure was precisely a helper that
  # exited 0 while returning nothing, which every liveness check short of this
  # one would have called healthy.
  #
  # Deliberately NO network call to GitHub. Validating the token upstream would
  # make a GitHub outage or a flaky link page as "dev host down", and the
  # monitor runs with maxretries 0.
  #
  # So this asserts RESOLVABILITY, not push rights, and the message says
  # "credential ready" rather than "push ready" on purpose — a check that claims
  # more than it tested is the same silent-rot failure it exists to prevent. An
  # under-scoped or server-side-revoked token still surfaces on first push.
  [[ -x "$GIT_CRED_HELPER_BIN" ]] || { echo "git credential helper missing (run: make git-headless)"; return 1; }
  local out
  out=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT_CRED_HELPER_BIN" get 2>/dev/null) || true
  /usr/bin/grep -q '^password=.' <<<"$out" \
    || { echo "github credential unresolvable (reseed: make secrets-seed from the MacBook)"; return 1; }
  echo "git credential ready"
}

check_collie() {
  # Opt-in per machine (`make collie-setup`), so absence is not a failure —
  # a machine that never wired the phone surface must not page forever.
  [[ -f "$COLLIE_PLIST" ]] || { echo "collie not installed (skipped)"; return 0; }

  # Two assertions, and the second is the point of this check existing.
  #
  # Liveness alone is not enough here. The bridge is remote shell access, and
  # its hardening lives entirely in a `.env` that launchd does NOT load on its
  # own — the bridge reads process.env only and systemd's `EnvironmentFile=` has
  # no launchd equivalent, so any start path that reaches `bun` without sourcing
  # the .env first brings the bridge up with COLLIE_PUBLIC_HOSTS unset. Upstream's
  # LaunchAgent (0.21.0+) routes through collie-ctl.sh, which does source it — but
  # that is upstream's invariant to keep, not ours, and it is one refactor away
  # from silently inverting. The failure is invisible to every liveness signal:
  # `launchctl list` reports status 0, the UI works, and the DNS-rebinding guard
  # is simply gone. So assert the BEHAVIOUR, not the config.
  #
  # Both calls are loopback-only. No tailnet hop, no external dependency — a
  # network wobble must not page this monitor (same reasoning as check_git_push
  # deliberately not calling GitHub).
  local code
  code=$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 3 "$COLLIE_URL/" 2>/dev/null) || true
  [[ "$code" == "200" ]] \
    || { echo "collie bridge not answering (got ${code:-000}; check: make collie-status)"; return 1; }

  code=$("$CURL_BIN" -s -H 'Host: evil.example.com' -o /dev/null -w '%{http_code}' \
    --max-time 3 "$COLLIE_URL/api/snapshot" 2>/dev/null) || true
  [[ "$code" == "403" ]] \
    || { echo "collie hardening LOST — spoofed Host got ${code:-000}, expected 403 (the .env did not reach the process)"; return 1; }

  echo "collie up (rebind guard active)"
}

check_dev_vhosts() {
  # The clean dev-vhost door (https://<app>.$DEV_DOMAIN, scripts/caddy-tailnet.sh
  # + `make caddy-dns-build`). Folded into the COMPOSITE monitor below, not a
  # dedicated one — same exception check_git_push already is: this does NOT
  # fail together with tailscaled/sshd/herdr/mosh (a reverted DNS module, a
  # cert nearing expiry, or a drifted A record can all happen on an otherwise
  # perfectly healthy dev host), but it is one component, and a second Kuma
  # push monitor wasn't worth it for this one either. Revisit only if it ever
  # pages independently often enough to be noise, same as that comment says.
  #
  # SKIP silently, exactly like the collie push-URL absence: a machine that
  # never set DEV_DOMAIN in caddy-tailnet.conf has no clean door and must not
  # fail this heartbeat over a feature it doesn't use.
  [[ -f "$CADDY_TAILNET_CONF" ]] || { echo "dev vhosts not configured (skipped)"; return 0; }
  local DEV_DOMAIN="" CF_TOKEN_FILE=""
  # shellcheck disable=SC1090,SC1091
  source "$CADDY_TAILNET_CONF"
  [[ -n "${DEV_DOMAIN:-}" ]] || { echo "dev vhosts not configured (skipped)"; return 0; }

  # 1. The brew-upgrade trap: `brew upgrade caddy` silently reverts the
  # binary to the module-less stock build, and nothing errors until the
  # wildcard cert fails to renew ~60 days out. This is the only thing here
  # that catches it before then. Capture first, match second — piping
  # straight into `grep -q` would SIGPIPE the producer and, under
  # `set -o pipefail`, misreport a healthy module list as a failure.
  local modules
  modules=$("$CADDY_BIN" list-modules 2>/dev/null) || true
  /usr/bin/grep -q 'dns.providers.cloudflare' <<<"$modules" \
    || { echo "caddy missing dns.providers.cloudflare (brew upgrade reverted it — fix: make caddy-dns-build)"; return 1; }

  # 2. Cert lifetime, probed LOCALLY. Deliberately no outbound call to
  # Cloudflare or Let's Encrypt — same restraint as check_git_push's comment
  # above: at a 300s cadence with maxretries 0, a third-party API wobble must
  # not page "dev host down". `health.$DEV_DOMAIN` need not resolve to
  # anything real; SNI alone is enough for the wildcard cert to be served.
  local ip
  ip=$(tailnet_ip) || ip=""
  [[ -n "$ip" ]] || { echo "dev vhosts: could not read this machine's tailnet IP"; return 1; }

  local enddate
  enddate=$(echo | "$OPENSSL_BIN" s_client -connect "$ip:443" -servername "health.$DEV_DOMAIN" 2>/dev/null \
    | "$OPENSSL_BIN" x509 -noout -enddate 2>/dev/null) || true
  enddate=${enddate#notAfter=}
  [[ -n "$enddate" ]] || { echo "dev vhosts: could not read the wildcard cert's expiry (is caddy serving *.${DEV_DOMAIN}?)"; return 1; }

  local end_epoch days_left
  end_epoch=$("$DATE_BIN" -j -f '%b %d %T %Y %Z' "$enddate" +%s 2>/dev/null) || true
  [[ -n "$end_epoch" ]] || { echo "dev vhosts: could not parse cert expiry '$enddate'"; return 1; }
  days_left=$(( (end_epoch - $("$DATE_BIN" +%s)) / 86400 ))
  (( days_left > 21 )) \
    || { echo "dev vhosts: wildcard cert has ${days_left}d left (< 21d)"; return 1; }

  # 3. A-record drift: the node's Tailscale IP can change (rename, re-key,
  # relocation) and nothing else in this stack notices — the clean door just
  # times out, silently, everywhere, with no error on either end. Same lesson
  # as the missing-ACL-grant failure mode already documented for the port
  # doors: the listener/record is the thing that has to be checked, because
  # nothing upstream of it complains when it goes stale.
  #
  # BOTH records are checked, because they are two records. `health.$DEV_DOMAIN`
  # answers from the wildcard and covers every app door; the bare $DEV_DOMAIN —
  # the app index — has its own A record, since a wildcard does not answer for
  # the name it hangs off. Only the apex going stale is the quiet one: every app
  # keeps working and just the front page dies.
  local name published
  for name in "health.$DEV_DOMAIN" "$DEV_DOMAIN"; do
    published=$("$DIG_BIN" +short "$name" 2>/dev/null | tail -1) || true
    [[ "$published" == "$ip" ]] \
      || { echo "dev vhosts: ${name} resolves to ${published:-nothing}, tailnet IP is $ip (DNS record drifted)"; return 1; }
  done

  # 4. The token and the generated include must both stay 600. Unlike 1-3,
  # this is a live secret-handling misconfiguration if it ever fails, not a
  # transient condition — so it is asserted every run, not just at generation
  # time in caddy-tailnet.sh.
  local token_perm out_perm
  token_perm=$("$STAT_BIN" -f '%Lp' "${CF_TOKEN_FILE:-}" 2>/dev/null || echo "")
  out_perm=$("$STAT_BIN" -f '%Lp' "$CADDY_TAILNET_INCLUDE" 2>/dev/null || echo "")
  [[ "$token_perm" == "600" ]] \
    || { echo "dev vhosts: ${CF_TOKEN_FILE:-<unset>} is mode ${token_perm:-missing}, expected 600"; return 1; }
  [[ "$out_perm" == "600" ]] \
    || { echo "dev vhosts: $CADDY_TAILNET_INCLUDE is mode ${out_perm:-missing}, expected 600"; return 1; }

  echo "dev vhosts up (cert ${days_left}d left, DNS in sync)"
}

check_memory() {
  # The single most likely thing to break this machine, and until now nothing
  # watched it. An OOM kill has already taken herdr once — and the monitor
  # reported "herdr up" straight through it, in BOTH directions: healthy before
  # the kill, healthy again seconds later once KeepAlive restarted an EMPTY
  # layout. Every process in every pane was gone and no check could tell.
  #
  # Two signals, both single sysctl reads, and NEITHER is a raw swap number.
  # macOS grows AND SHRINKS the swap file on demand, so "3.7G of 5.1G used"
  # reads alarming while being the steady state right after a cleanup — a
  # threshold on that number would alarm on a healthy machine and go quiet on a
  # sick one whose swap file happened to grow. Threshold on what is scarce:
  #   1. kern.memorystatus_vm_pressure_level — the kernel's own verdict
  #      (1 normal, 2 warn, 4 critical). This is the signal that PRECEDES a
  #      jetsam kill, which is exactly the event that cost us herdr.
  #   2. swap in use as a fraction of PHYSICAL RAM, which does not move when
  #      the swap file is resized underneath it.
  local level swap phys
  level=$("$SYSCTL_BIN" -n kern.memorystatus_vm_pressure_level 2>/dev/null) || level=""
  swap=$("$SYSCTL_BIN" -n vm.swapusage 2>/dev/null) || swap=""
  phys=$("$SYSCTL_BIN" -n hw.memsize 2>/dev/null) || phys=""
  [[ -n "$level" && -n "$swap" && -n "$phys" ]] \
    || { echo "memory: sysctl unreadable (pressure=${level:-?} swap=${swap:+set} memsize=${phys:+set})"; return 1; }

  # vm.swapusage is a human string: "total = 5120.00M  used = 3672.38M  ...".
  # awk both parses it and does the division — the value is fractional and
  # bash has no floats.
  local parsed used_mb pct phys_gb
  # shellcheck disable=SC2016  # $i/$(i+2) are awk fields, not shell expansions
  parsed=$("$AWK_BIN" -v phys="$phys" '{
      for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); break }
      u = v + 0
      unit = substr(v, length(v), 1)
      if (unit == "G") u *= 1024; else if (unit == "K") u /= 1024
      printf "%d %d", u, (u * 1048576.0 / phys) * 100
    }' <<<"$swap") || parsed=""
  used_mb=${parsed%% *}
  pct=${parsed##* }
  [[ -n "$used_mb" && -n "$pct" ]] || { echo "memory: could not parse vm.swapusage '$swap'"; return 1; }
  phys_gb=$(( phys / 1073741824 ))

  local level_name
  case "$level" in
    1) level_name="normal" ;;
    2) level_name="WARN" ;;
    4) level_name="CRITICAL" ;;
    *) level_name="level=$level" ;;
  esac

  (( level < 2 )) \
    || { echo "memory pressure ${level_name} — the kernel is about to start jetsam-killing (swap ${used_mb}M = ${pct}% of ${phys_gb}G RAM)"; return 1; }
  (( pct <= MEM_SWAP_PCT_MAX )) \
    || { echo "swap ${used_mb}M = ${pct}% of ${phys_gb}G RAM (max ${MEM_SWAP_PCT_MAX}%) — something is leaking"; return 1; }
  echo "memory ok (pressure ${level_name}, swap ${used_mb}M = ${pct}% of ${phys_gb}G)"
}

# label|plist whose absence means "not wired on this machine"
LAUNCHD_KEEPALIVE="\
homebrew.mxcl.herdr|$HOME/Library/LaunchAgents/homebrew.mxcl.herdr.plist
homebrew.mxcl.colima|$HOME/Library/LaunchAgents/homebrew.mxcl.colima.plist
com.jkrumm.sideclaw-server|$HOME/Library/LaunchAgents/com.jkrumm.sideclaw-server.plist
com.litellm.proxy|$HOME/Library/LaunchAgents/com.litellm.proxy.plist
ai.hermes.gateway|$HOME/Library/LaunchAgents/ai.hermes.gateway.plist
herdr.collie|$HOME/Library/LaunchAgents/herdr.collie.plist"

check_launchd_restarts() {
  # KeepAlive makes a crash-looping service look EXACTLY like a healthy one:
  # launchd restarts it, the port comes back, every liveness check goes green.
  # The evidence is already sitting in `launchctl print` and nothing read it —
  # herdr is at `runs = 2` with `last terminating signal = Killed: 9`, the OOM
  # kill that silently emptied its panes.
  #
  # This is a DELTA, not a threshold on `runs`. `runs` is cumulative since load,
  # so failing on runs > 1 would page forever over an event from weeks ago; the
  # alertable fact is "a service restarted since the last 5-minute check", which
  # for herdr means every pane's processes are gone RIGHT NOW. It pages for one
  # cycle and clears, which is the correct shape for an edge.
  #
  # StartInterval agents (this one included, at runs = 1333) are deliberately
  # absent from the list — `runs` counts scheduled invocations there and would
  # increment every single cycle.
  local uid state_file seen="" restarted="" history=""
  local entry label plist out runs sig prev
  uid=$(/usr/bin/id -u)
  state_file="$STATE_DIR/launchd-runs"
  /bin/mkdir -p "$STATE_DIR" 2>/dev/null || true

  while IFS='|' read -r label plist; do
    [[ -n "$label" ]] || continue
    [[ -f "$plist" ]] || continue
    out=$("$LAUNCHCTL_BIN" print "gui/$uid/$label" 2>/dev/null) || continue
    # shellcheck disable=SC2016  # $2 is an awk field, not a shell expansion
    runs=$("$AWK_BIN" -F' = ' '/^[[:space:]]*runs = /{ print $2; exit }' <<<"$out")
    [[ -n "$runs" ]] || continue
    # shellcheck disable=SC2016
    sig=$("$AWK_BIN" -F' = ' '/^[[:space:]]*last terminating signal = /{ print $2; exit }' <<<"$out")
    seen="${seen}${label} ${runs}
"
    # Surface a non-clean history even when nothing changed this cycle: a `-9`
    # in the record is the difference between "restarted on purpose" and "was
    # killed", and it belongs in the msg where the diagnosis happens.
    if [[ "$runs" != "1" ]]; then
      history="${history:+$history }${label##*.}=${runs}${sig:+(${sig})}"
    fi
    # shellcheck disable=SC2016
    prev=$("$AWK_BIN" -v l="$label" '$1 == l { print $2; exit }' "$state_file" 2>/dev/null) || prev=""
    # No previous reading (first run, or a newly wired service) — seed and move
    # on. Inventing a comparison against zero would page once for every service
    # on the first run after install.
    [[ -n "$prev" ]] || continue
    if (( runs > prev )); then
      restarted="${restarted:+$restarted, }${label} restarted (${prev}→${runs}${sig:+, ${sig}})"
    fi
  done <<<"$LAUNCHD_KEEPALIVE"

  # temp + mv: a torn state file would either re-seed (missing an edge) or
  # compare against garbage (a phantom page).
  if [[ -n "$seen" ]]; then
    printf '%s' "$seen" > "$state_file.tmp" 2>/dev/null \
      && /bin/mv -f "$state_file.tmp" "$state_file" 2>/dev/null || true
  fi

  [[ -z "$restarted" ]] || { echo "$restarted"; return 1; }
  echo "no restarts${history:+ (history: $history)}"
}

# name|gate path whose absence means "not installed here"|probe function
DEVHOST_SERVICES="\
sideclaw|$HOME/Library/LaunchAgents/com.jkrumm.sideclaw-server.plist|probe_sideclaw
litellm|$HOME/Library/LaunchAgents/com.litellm.proxy.plist|probe_litellm
hermes|$HOME/Library/LaunchAgents/ai.hermes.gateway.plist|probe_hermes
colima|$COLIMA_PLIST|probe_colima
caddy|/Library/LaunchDaemons/homebrew.mxcl.caddy.plist|probe_caddy
dnsmasq|/Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist|probe_dnsmasq"

probe_sideclaw() {
  local code
  code=$(http_code "$SIDECLAW_URL/health")
  [[ "$code" == "200" ]] || { echo "sideclaw not answering on $SIDECLAW_URL (got ${code:-000})"; return 1; }
}

probe_litellm() {
  # /health/liveliness, NOT /health. The latter dials every configured model
  # upstream, which would turn a provider wobble into a "dev host down" page
  # and break the no-outbound-calls rule check_git_push exists to keep.
  local code
  code=$(http_code "$LITELLM_URL/health/liveliness")
  [[ "$code" == "200" ]] || { echo "litellm bridge not answering on $LITELLM_URL (got ${code:-000})"; return 1; }
}

probe_hermes() {
  # Hermes binds the TAILNET address, not loopback, so unlike every other probe
  # here this one needs the node IP. Still no network hop — it is this machine's
  # own interface.
  local ip code
  ip=$(tailnet_ip) || ip=""
  [[ -n "$ip" ]] || { echo "hermes: no tailnet IP to probe (tailscaled down?)"; return 1; }
  code=$(http_code "http://${ip}:${HERMES_PORT}/health")
  [[ "$code" == "200" ]] || { echo "hermes gateway not answering on :${HERMES_PORT} (got ${code:-000})"; return 1; }
}

probe_colima() {
  # Ask the docker socket rather than shelling `docker info`: same answer, but
  # it exercises the exact /var/run/docker.sock → ~/.colima/default/docker.sock
  # symlink the com.colima.docker-socket LaunchDaemon maintains and that the
  # Raycast extension, Testcontainers and every IDE depend on. It also needs no
  # PATH and carries its own timeout — a wedged VM makes `docker info` block,
  # and a blocked call inside a 300s heartbeat is its own outage.
  local out
  out=$("$CURL_BIN" -s --max-time 6 --unix-socket "$DOCKER_SOCK" 'http://localhost/_ping' 2>/dev/null) || true
  [[ "$out" == "OK" ]] || { echo "colima/docker socket not answering at $DOCKER_SOCK (got ${out:-nothing})"; return 1; }

  # Second assertion: the SUPERVISOR POLICY, which liveness cannot see. This is
  # the collie lesson applied to colima — a running VM proves nothing about what
  # happens the next time a start FAILS, and that is the only case that matters
  # on a headless box after a power cut.
  #
  # Homebrew generates this plist with `KeepAlive { SuccessfulExit = true }`,
  # which retries only on a ZERO exit — inverted, because `colima start -f` exits
  # non-zero exactly when the VM failed to come up. `make _colima-supervise`
  # rewrites it to bare `KeepAlive = true` plus colima/colima-start.sh (bounded
  # retry; bare KeepAlive alone would boot-loop a broken image every 10s).
  #
  # It is asserted every run, not trusted from setup, because brew REGENERATES
  # the plist on every `brew upgrade colima` AND every `brew services
  # start/restart` — and nothing errors when it does. The VM keeps running, the
  # ping above stays green, and the revert surfaces only as a failed start that
  # never gets retried. Same silent-config-revert class as the caddy DNS module
  # in check_dev_vhosts; scripts/brew-upgrade.sh asserts the same two facts on
  # the upgrade path.
  local keepalive program
  keepalive=$("$PLISTBUDDY_BIN" -c 'Print :KeepAlive' "$COLIMA_PLIST" 2>/dev/null) || keepalive=""
  program=$("$PLISTBUDDY_BIN" -c 'Print :ProgramArguments:0' "$COLIMA_PLIST" 2>/dev/null) || program=""
  # The reverted form prints as a multi-line `Dict { SuccessfulExit = true }`.
  # Flatten it so the failure lands in the Kuma msg as one readable line; the
  # healthy value is a bare `true` and is untouched by this.
  keepalive=${keepalive//$'\n'/ }
  [[ "$keepalive" == "true" ]] \
    || { echo "colima boot path REVERTED — KeepAlive is '${keepalive:-unreadable}', not bare true, so a failed start is never retried (fix: make _colima-supervise)"; return 1; }
  [[ "$program" == "$COLIMA_START_WRAPPER" ]] \
    || { echo "colima boot path REVERTED — ProgramArguments:0 is '${program:-unreadable}', not the bounded-retry wrapper, so a broken image boot-loops every 10s (fix: make _colima-supervise)"; return 1; }
}

probe_caddy() {
  # check_dev_vhosts proves caddy answers TLS on the TAILNET door — but only
  # when DEV_DOMAIN is seeded, and it says nothing about the LOCAL *.test proxy
  # every app on this machine is actually reached through. That asymmetry is
  # what this closes, with two assertions:
  #   1. the admin API answers → the process is alive and serving
  #   2. a *.test Host on :80 gets the http→https redirect → the config it
  #      loaded is the dev proxy, not an empty or half-written one. Caddy
  #      starting clean with a broken config is the failure that assertion 1
  #      alone would call healthy.
  local code
  code=$(http_code "$CADDY_ADMIN_URL/config/")
  [[ "$code" == "200" ]] || { echo "caddy admin API not answering on $CADDY_ADMIN_URL (got ${code:-000})"; return 1; }
  code=$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 4 \
    -H 'Host: devhost-health-probe.test' 'http://127.0.0.1/' 2>/dev/null) || true
  [[ "$code" == 3* ]] \
    || { echo "caddy is up but not serving the *.test proxy (got ${code:-000}, expected a 3xx redirect to https)"; return 1; }
}

probe_dnsmasq() {
  # dnsmasq going down takes every *.test name with it, silently: caddy keeps
  # serving perfectly, nothing logs anything, and every local dev URL just
  # stops resolving. Query a name that exists nowhere else, so a 127.0.0.1
  # answer can only have come from the wildcard.
  local answer
  answer=$("$DIG_BIN" +short +time=2 +tries=1 @127.0.0.1 devhost-health-probe.test 2>/dev/null | tail -1) || true
  [[ "$answer" == "127.0.0.1" ]] \
    || { echo "dnsmasq not resolving *.test (got ${answer:-nothing}) — every .test name on this machine is dead"; return 1; }
}

check_services() {
  # Six always-on services that nothing watched. Each is gated on its own
  # plist, so a machine that never installed one SKIPS it rather than failing —
  # the collie rule, applied six more times.
  local entry name rest gate probe reason up=0 skipped=0 down=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name=${entry%%|*}; rest=${entry#*|}
    gate=${rest%%|*}; probe=${rest##*|}
    if [[ ! -e "$gate" ]]; then skipped=$(( skipped + 1 )); continue; fi
    if reason=$("$probe"); then
      up=$(( up + 1 ))
    else
      down="${down:+$down, }$reason"
    fi
  done <<<"$DEVHOST_SERVICES"

  [[ -z "$down" ]] || { echo "$down"; return 1; }
  # `${skipped:+…}` would fire on the string "0" — count, don't test emptiness.
  local skip_note=""
  (( skipped == 0 )) || skip_note=", $skipped not installed"
  echo "services up (${up}${skip_note})"
}

claude_token_works() {
  local tok tout
  [[ -x "$SECRETS_RUN_BIN" ]] || return 1
  tok=$("$SECRETS_RUN_BIN" read op://mini/claude/oauth-token 2>/dev/null) || return 1
  [[ -n "$tok" ]] || return 1
  tout=$(CLAUDE_CODE_OAUTH_TOKEN="$tok" USER="${USER:-$(/usr/bin/id -un)}" \
    "$CLAUDE_BIN" auth status 2>/dev/null) || return 1
  [[ "$("$JQ_BIN" -r '.loggedIn // false' <<<"$tout" 2>/dev/null)" == "true" ]]
}

check_claude_auth() {
  # The silent-API-billing failure, made visible. An expired OAuth token does
  # not stop anything: `claude --bg` daemons keep starting, `claude agents`
  # keeps listing them healthy, and every one of them quietly bills API credits
  # instead of Max. Nothing else on this machine can see that.
  #
  # SKIP when the CLI is absent (a machine that does not run agents), FAIL when
  # it is present and reports anything other than a logged-in Max session. It
  # was tempting to skip until WP4's `claude setup-token` lands, but that would
  # be skipping on this machine today — verified 2026-07-31, `claude auth
  # status` already returns loggedIn=true / subscriptionType=max from the
  # existing GUI-session login. There is nothing to wait for, and a check that
  # skips while the thing works is a check that will still be skipping when it
  # stops working.
  #
  # USER is defaulted because that is the one variable this lookup needs: with
  # HOME and PATH set but USER stripped, `claude auth status` reports
  # loggedIn=false — i.e. it would fabricate exactly the alert it exists to
  # raise. launchd does hand a user agent USER, so this is belt-and-braces, but
  # the failure it guards against is indistinguishable from the real thing.
  [[ -x "$CLAUDE_BIN" ]] || { echo "claude cli not installed (skipped)"; return 0; }
  local out logged sub
  out=$(USER="${USER:-$(/usr/bin/id -un)}" "$CLAUDE_BIN" auth status 2>/dev/null) || true
  [[ -n "$out" ]] || { echo "claude auth status returned nothing — agents may be billing API credits"; return 1; }
  logged=$("$JQ_BIN" -r '.loggedIn // false' <<<"$out" 2>/dev/null) || logged=""
  sub=$("$JQ_BIN" -r '.subscriptionType // "none"' <<<"$out" 2>/dev/null) || sub=""

  # TWO CREDENTIALS, TWO PATHS — and the bare binary above can only see one of
  # them. `config/zsh/claude-auth.zsh` falls back to CLAUDE_CODE_OAUTH_TOKEN from
  # the secrets cache, so a host with a dead keychain but a live token runs every
  # herdr pane and `rd bg` daemon perfectly on Max. Reporting that as "every
  # agent on this host is billing API credits" — as this did — is false, and a
  # component that overstates is one you learn to skim past.
  #
  # So probe the fallback too, and grade the three states differently:
  #   keychain ok                → ok
  #   keychain dead, token works → DEGRADED, and say what to do (a `/login` in a
  #                                herdr pane restores a self-refreshing
  #                                credential; the token is a 1-year static one
  #                                with no refresh and no reliable revocation)
  #   neither                    → the real "billing API credits" alert

  if [[ "$logged" != "true" ]]; then
    if claude_token_works; then
      echo "claude keychain login is gone; running on the cached oauth token (works, but static 1y — restore with /login in a herdr pane on this host)"
      return 1
    fi
    echo "claude NOT logged in and the cached oauth token does not work either — every agent on this host is billing API credits (fix: /login in a herdr pane, or claude setup-token; needs a human)"
    return 1
  fi

  [[ "$sub" == "max" ]] \
    || { echo "claude auth is '${sub:-unknown}', not max — agents are off the subscription"; return 1; }
  echo "claude auth ok (max)"
}

check_obsidian() {
  # The CLI door /brain and Hermes reach the vault through. Two ways it breaks,
  # and this one call covers both — which is why it is `version` and not a
  # file test:
  #   1. the symlink into the app bundle goes stale (app update, moved bundle),
  #   2. the app is not RUNNING. obsidian-cli is a client of the live app, not a
  #      standalone tool — it talks to ~/.obsidian-cli.sock, and `version`
  #      itself exits 1 with "make sure Obsidian is running" when the app is
  #      down (verified 2026-07-31 against an empty HOME, and re-verified the
  #      same day on 1.13.4 after the 1.1.9 → 1.13.4 cask jump). So a quit
  #      Obsidian is a dead agent door, and this check sees it.
  #      `make obsidian-autostart` is what keeps the app up across a reboot.
  #
  # Do NOT extend this to a richer subcommand without checking its exit code
  # first: obsidian-cli exits **0** on an unknown command AND on a missing
  # required argument, printing the error to stdout (measured on 1.13.4 —
  # `obsidian definitely-not-a-command` and a bare `obsidian search` both
  # return 0). A check gated on `$?` would therefore pass forever the moment a
  # subcommand is renamed upstream. `version` is safe because it is real and
  # its failure path is the socket, not the argument parser.
  [[ -x "$OBSIDIAN_BIN" ]] || { echo "obsidian cli not installed (skipped)"; return 0; }
  local version
  version=$("$OBSIDIAN_BIN" version 2>/dev/null) || \
    { echo "obsidian cli failing — app not running, or the $OBSIDIAN_BIN symlink is stale; /brain and Hermes cannot reach the vault (fix: open -a Obsidian, then make obsidian-autostart)"; return 1; }
  echo "obsidian cli ok (${version%% *})"
}

check_disk() {
  # Hourly SQLite snapshots and unrotated logs both grow without anyone
  # deciding to grow them, and a full data volume takes down every service on
  # this host at once with errors that name anything but the disk.
  #
  # Both a percentage and an absolute floor, because neither alone is right on
  # a 926G volume: 90% still leaves 92G (plenty of warning), while a small
  # volume at 85% can have less headroom than a day of snapshots.
  local line parsed pct free_gb
  line=$("$DF_BIN" -kP "$HOME" 2>/dev/null | tail -1) || true
  [[ -n "$line" ]] || { echo "disk: could not read df for $HOME"; return 1; }
  # shellcheck disable=SC2016  # $4/$5 are awk fields, not shell expansions
  parsed=$("$AWK_BIN" '{ gsub(/%/, "", $5); printf "%d %d", $5, $4 / 1048576 }' <<<"$line") || parsed=""
  pct=${parsed%% *}
  free_gb=${parsed##* }
  [[ -n "$pct" && -n "$free_gb" ]] || { echo "disk: could not parse df output '$line'"; return 1; }
  (( pct < DISK_USED_PCT_MAX )) \
    || { echo "disk ${pct}% used (max ${DISK_USED_PCT_MAX}%), ${free_gb}G free"; return 1; }
  (( free_gb >= DISK_FREE_GB_MIN )) \
    || { echo "disk has ${free_gb}G free (min ${DISK_FREE_GB_MIN}G), ${pct}% used"; return 1; }
  echo "disk ok (${pct}% used, ${free_gb}G free)"
}

check_runaways() {
  # A leaked agent-spawned process burned 1001 CPU-minutes on this machine
  # before anyone noticed. It REPORTS ONLY — nothing running unattended every
  # five minutes should be allowed to kill a process it merely INFERRED was a
  # runaway, and the inference below is explicitly heuristic.
  #
  # Gate on ACCUMULATED CPU time, never instantaneous %CPU: a compile, a test
  # run and an agent thinking hard all peg a core for a minute, and a sampler
  # would page for each.
  #
  # Accumulated time alone is not enough either, and the reason is specific to
  # this host: the always-on services here are PPID 1 with a cwd under
  # ~/SourceRoot too, so given enough uptime a perfectly healthy sideclaw
  # crosses ANY fixed CPU-minute line and then pages forever until someone
  # restarts it. The second gate is therefore the process's LIFETIME AVERAGE
  # (cputime / elapsed) — still computed from accumulated time, not sampled: a
  # runaway spins near 100% for its whole life, an idle service sits near 0.
  #
  # `claude` is EXCLUDED by name. A `claude --bg` daemon reparents to PID 1 by
  # design, sits in a SourceRoot repo, and runs for days — it is the thing this
  # host exists to run, and a reaper that flagged it would be worse than none.
  local hits="" ppid pid cputime etime cmd exe cpu_s el_s pct cwd
  while read -r ppid pid cputime etime cmd; do
    [[ "$ppid" == "1" ]] || continue
    exe=${cmd%% *}
    case "${exe##*/}" in claude) continue ;; esac
    cpu_s=$(hms_to_seconds "$cputime")
    (( cpu_s >= RUNAWAY_CPU_MINUTES * 60 )) || continue
    el_s=$(hms_to_seconds "$etime")
    (( el_s > 0 )) || continue
    pct=$(( cpu_s * 100 / el_s ))
    (( pct >= RUNAWAY_CPU_PCT_MIN )) || continue
    # lsof is the expensive call, so it runs LAST — only on the handful of
    # processes that already cleared both CPU gates, never on all ~480 PPID-1
    # processes this machine has.
    cwd=$("$LSOF_BIN" -a -p "$pid" -d cwd -Fn 2>/dev/null | "$SED_BIN" -n 's/^n//p' | tail -1) || cwd=""
    case "$cwd" in "$HOME"/SourceRoot*) ;; *) continue ;; esac
    hits="${hits:+$hits, }pid $pid ${exe##*/} $(( cpu_s / 60 ))min cpu at ${pct}% lifetime in ${cwd##*/}"
  done < <("$PS_BIN" -Ao ppid=,pid=,time=,etime=,command= 2>/dev/null)

  [[ -z "$hits" ]] || { echo "runaway candidates (NOT killed, investigate): $hits"; return 1; }
  echo "no runaways"
}

# --- Run --------------------------------------------------------------------

details=()
failure=""

uptime_s=$(host_uptime_seconds)
# `if`, not `(( … )) && assign`: under `set -e` an arithmetic compound that
# evaluates false returns 1, and as the last command of an && list that exits
# the whole script — silently, in the COMMON case (a host that booted long ago).
in_boot_grace=0
if (( uptime_s < BOOT_GRACE_SECONDS )); then in_boot_grace=1; fi
# Reboots are otherwise invisible here: check_launchd_restarts does delta
# detection on AGENTS, not on the host, so a 3am power cut that recovers
# perfectly leaves no trace in any heartbeat. One line fixes that, and it is
# arguably worth more than the grace window itself.
(( uptime_s >= REBOOT_NOTE_SECONDS )) || details+=("host rebooted ${uptime_s}s ago")

/bin/mkdir -p "$STATE_DIR" 2>/dev/null || true

for component in check_tailscale check_sshd check_herdr check_mosh check_git_push check_dev_vhosts \
                 check_memory check_launchd_restarts check_services check_claude_auth \
                 check_obsidian check_disk check_runaways; do
  # Substring match on space-padded strings — bash 3.2 has no associative
  # arrays, and this script must stay 3.2 (launchd hands it Apple's /bin/bash).
  is_transient=1
  if [[ " $IMMEDIATE_COMPONENTS " == *" $component "* ]]; then is_transient=0; fi
  streak_file="$STATE_DIR/fail-$component"

  if detail=$("$component"); then
    details+=("$detail")
    rm -f "$streak_file" 2>/dev/null || true
    continue
  fi

  # BOOT GRACE APPLIES TO EVERY COMPONENT, not just the transient ones — and
  # that asymmetry with the streak logic below is deliberate. Failures cascade
  # at boot: check_dev_vhosts needs the tailnet IP, so while tailscaled is still
  # coming up it fails too, and it is (correctly) NOT in the transient set
  # because cert expiry and DNS drift never self-heal. Restricting the grace to
  # the transient list therefore still pages on every reboot, via the cascade —
  # observed directly while testing this change. The window is short, bounded,
  # and anything genuinely broken FAILs on the very next run.
  if (( in_boot_grace )); then
    # Not a failure and not silence: the summary says what is still coming up.
    details+=("$detail (starting, booted ${uptime_s}s ago)")
    continue
  fi

  if (( is_transient )); then
    streak=$(cat "$streak_file" 2>/dev/null || echo 0)
    case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
    streak=$(( streak + 1 ))
    echo "$streak" > "$streak_file" 2>/dev/null || true
    if (( streak < TRANSIENT_FAILS_BEFORE_ALERT )); then
      details+=("$detail (degraded ${streak}/${TRANSIENT_FAILS_BEFORE_ALERT}, may self-heal)")
      continue
    fi
    detail="$detail (persisted ${streak} runs)"
  fi

  # First failure wins the alert text; keep checking so the message can still
  # carry the full picture.
  [[ -n "$failure" ]] || failure="$detail"
  details+=("FAIL: $detail")
done

# `${arr[*]}` joins on the FIRST character of IFS only, so build the separator
# explicitly rather than setting IFS='; ' and silently getting ';'.
summary=$(printf '%s; ' "${details[@]}"); summary=${summary%; }

# Push and health are reported independently: a failed push must not swallow the
# health summary, which is the only diagnosis the local log will ever carry.
push_rc=0
if [[ -n "$failure" ]]; then
  push down "$summary" || push_rc=$?
  echo "✗ $summary" >&2
else
  push up "$summary" || push_rc=$?
  echo "✓ $summary"
fi

if (( push_rc != 0 )); then
  echo "✗ push to Uptime Kuma failed (rc=$push_rc) — Kuma will alert on the missed heartbeat" >&2
fi

# --- Collie: its OWN monitor, driven by this same agent ----------------------
# Collie is deliberately NOT a component of the composite above. It does not
# fail with the other five — it is opt-in per machine and can be absent, down or
# mis-hardened while the dev host is perfectly healthy — so folding it in would
# mark the dev host DOWN and implicate herdr/sshd/tailscaled when nothing is
# wrong with them. That is the same reasoning that keeps the composite composite,
# applied in the other direction.
#
# One SCHEDULER, two monitors: this agent already runs every 300s, so a second
# LaunchAgent would be pure duplication. Only the push target differs.
#
# The push URL file is optional and its absence is silent by design: a machine
# that never ran `make collie-setup` has no collie and no monitor, and must not
# fail this script. Kuma's own missed-heartbeat covers the case where the
# monitor exists but this stops running.
collie_push_rc=0
COLLIE_PUSH_URL_FILE="${COLLIE_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/collie-push-url}"
if [[ -f "$COLLIE_PUSH_URL_FILE" ]]; then
  collie_url=$(kuma_resolve_push_url "${COLLIE_PUSH_URL:-}" "$COLLIE_PUSH_URL_FILE") || collie_url=""
  if [[ -n "$collie_url" ]]; then
    if collie_detail=$(check_collie); then
      kuma_push "$collie_url" up "$collie_detail" || collie_push_rc=$?
      echo "✓ collie monitor: $collie_detail"
    else
      kuma_push "$collie_url" down "$collie_detail" || collie_push_rc=$?
      echo "✗ collie monitor: $collie_detail" >&2
      failure="${failure:-$collie_detail}"
    fi
  fi
fi

# --- Secrets freshness: also its OWN monitor, same scheduler -----------------
# Moved here from com.jkrumm.secrets-freshness, which ran ONCE A WEEK (Mon
# 09:15). A cache going stale on a Tuesday was therefore invisible for six
# days — and the cache is what every headless secret on this machine resolves
# through, so those six days are six days of a service coming up
# credential-less with nothing reporting it. The 300s agent already exists;
# only the push target differs. Same "one scheduler, two monitors" argument
# already made and accepted for collie.
#
# It keeps its OWN monitor for the same reason collie does, not as an
# afterthought: a stale cache does not fail with tailscaled/sshd/herdr/mosh, so
# folding it into the composite would mark the dev host DOWN and implicate four
# healthy components for a reseed reminder.
#
# Threshold unchanged at 8 days — one day of slack past a weekly ritual.
# Reads MTIME only, never decrypts: a health check must not touch a secret
# value. The seed writes atomically (temp + mv), so mtime is the seed time.
secrets_freshness_detail() {
  [[ -f "$SECRETS_CACHE_FILE" ]] \
    || { echo "no secrets cache at $SECRETS_CACHE_FILE — run make secrets-seed from the MacBook"; return 1; }
  local mtime age
  mtime=$("$STAT_BIN" -f %m "$SECRETS_CACHE_FILE" 2>/dev/null) || mtime=0
  (( mtime > 0 )) || { echo "secrets cache mtime unreadable at $SECRETS_CACHE_FILE"; return 1; }
  age=$(( ($("$DATE_BIN" -u +%s) - mtime) / 86400 ))
  (( age <= SECRETS_FRESHNESS_MAX_AGE_DAYS )) \
    || { echo "secrets cache ${age}d old (max ${SECRETS_FRESHNESS_MAX_AGE_DAYS}d) — reseed with make secrets-seed"; return 1; }
  echo "secrets cache ${age}d old"
}

# The push URL file is optional and its absence is silent, exactly as for
# collie: a machine that never seeded a cache has no monitor to report to and
# must not fail this script over it.
secrets_push_rc=0
SECRETS_FRESHNESS_PUSH_URL_FILE="${SECRETS_FRESHNESS_PUSH_URL_FILE:-$HOME/.config/secrets/freshness-push-url}"
if [[ -f "$SECRETS_FRESHNESS_PUSH_URL_FILE" ]]; then
  secrets_url=$(kuma_resolve_push_url "${SECRETS_FRESHNESS_PUSH_URL:-}" "$SECRETS_FRESHNESS_PUSH_URL_FILE") || secrets_url=""
  if [[ -n "$secrets_url" ]]; then
    if secrets_detail=$(secrets_freshness_detail); then
      kuma_push "$secrets_url" up "$secrets_detail" || secrets_push_rc=$?
      echo "✓ secrets monitor: $secrets_detail"
    else
      kuma_push "$secrets_url" down "$secrets_detail" || secrets_push_rc=$?
      echo "✗ secrets monitor: $secrets_detail" >&2
      failure="${failure:-$secrets_detail}"
    fi
  fi
fi

[[ -z "$failure" && $push_rc -eq 0 && $collie_push_rc -eq 0 && $secrets_push_rc -eq 0 ]] || exit 1
