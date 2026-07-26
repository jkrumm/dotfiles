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
# than with the other four. It is folded in anyway because the alternative —
# a second Uptime Kuma push monitor — needs the browser to create (the API
# can't make push monitors on UK 2.x), and a check that exists only in a plan
# catches nothing. Revisit if it ever pages independently often enough to be
# noise.
#
# Fail-loud, never fail-silent: if the push URL can't be resolved we exit
# non-zero WITHOUT pushing, so Uptime Kuma's own missed-heartbeat fires. A
# monitor that silently stops reporting is worse than no monitor.
#
# Usage: devhost-health-check.sh
#   DEVHOST_PUSH_URL       Uptime Kuma push URL; if unset, read from the
#                          chmod-600 DEVHOST_PUSH_URL_FILE below.

# LaunchAgents get a minimal PATH and no shell aliases — note `tailscale` is an
# alias to the app bundle in the interactive shell and would simply not exist
# here. Resolve every binary by absolute path.
HERDR_BIN="${HERDR_BIN:-/opt/homebrew/bin/herdr}"
MOSH_SERVER_BIN="${MOSH_SERVER_BIN:-/opt/homebrew/bin/mosh-server}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
GIT_CRED_HELPER_BIN="${GIT_CRED_HELPER_BIN:-$HOME/.local/bin/git-credential-secrets-cache}"
ALF_BIN="${ALF_BIN:-/usr/libexec/ApplicationFirewall/socketfilterfw}"

# The push token is low-sensitivity (it can only spoof a heartbeat) but still
# lives in a chmod-600 file rather than 1Password on purpose: monitoring must not
# depend on the secrets cache being seeded, or a stale cache would take the
# monitor down with it. Resolution + push live in the shared lib.
# shellcheck source=lib/kuma-push.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/kuma-push.sh"

PUSH_URL_FILE="${DEVHOST_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/devhost-push-url}"
push_url=$(kuma_resolve_push_url "${DEVHOST_PUSH_URL:-}" "$PUSH_URL_FILE") || exit 1

push() { kuma_push "$push_url" "$1" "$2"; }

# --- Components -------------------------------------------------------------
# Each returns 0 and echoes a short OK detail, or returns 1 and echoes why.

check_tailscale() {
  local state
  state=$("$TAILSCALE_BIN" status --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null) || true
  [[ "$state" == "Running" ]] || { echo "tailscaled not Running (state=${state:-unreachable})"; return 1; }
  echo "tailnet up"
}

check_sshd() {
  # Inbound auth is always the *connecting* machine's key — the mini holds no
  # key material and cannot ssh to itself — so liveness here is "is something
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
  # monitor runs with maxretries 0. Local resolvability is the honest signal;
  # a server-side revocation surfaces on first push, not here.
  [[ -x "$GIT_CRED_HELPER_BIN" ]] || { echo "git credential helper missing (run: make git-headless)"; return 1; }
  local out
  out=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT_CRED_HELPER_BIN" get 2>/dev/null) || true
  /usr/bin/grep -q '^password=.' <<<"$out" \
    || { echo "github credential unresolvable (reseed: make secrets-seed from the MacBook)"; return 1; }
  echo "git push ready"
}

# --- Run --------------------------------------------------------------------

details=()
failure=""
for component in check_tailscale check_sshd check_herdr check_mosh check_git_push; do
  if detail=$("$component"); then
    details+=("$detail")
  else
    # First failure wins the alert text; keep checking so the message can still
    # carry the full picture.
    [[ -n "$failure" ]] || failure="$detail"
    details+=("FAIL: $detail")
  fi
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

[[ -z "$failure" && $push_rc -eq 0 ]] || exit 1
