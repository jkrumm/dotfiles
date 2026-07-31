#!/usr/bin/env bash
# `set +x` first, before anything reads a secret: this script holds the
# Cloudflare API token in a shell variable, and `bash -x scripts/caddy-tailnet.sh`
# — the obvious way to debug a generator — would trace it straight to stderr.
# Same guard, same reason, as scripts/devhost-health-check.sh.
set +x
set -euo pipefail

# caddy-tailnet — expose this machine's dev servers over the tailnet, via Caddy.
#
# Runs ON the dev host. Regenerates a machine-local Caddy include; the generated
# file is deliberately NOT tracked in dotfiles because it names this machine's
# MagicDNS hostname and Tailscale IP, which the security rule keeps out of git.
# Regenerate it per machine rather than copying it between them.
#
# ONE REGISTRY: config/Caddyfile. Every `<name>.test { reverse_proxy
# localhost:PORT }` block in the tracked Caddyfile is a dev app, and every dev
# app automatically gets a clean tailnet door. A new app needs ZERO work here —
# that is the whole point. Before this, the Caddyfile's 17 apps and
# ~/.config/caddy-tailnet.ports' 4 were two hand-maintained lists that drifted
# silently, and an app only reached the tailnet if you remembered the second
# one. That file is now an opt-OUT + flags file (see the header it seeds).
#
# The Caddyfile is read via `caddy adapt` and the route JSON is walked — never
# regexed. See scripts/lib/caddy-registry.py for why the body defeats regex.
#
# TWO doors, and neither is optional-away from the other:
#
#   1. Port-based .ts.net doors (https://<magicdns>:<port>). Cert comes from
#      tailscaled itself — no DNS provider, no Cloudflare, no ACME — so this is
#      the zero-dependency fallback that must keep working when door 2 can't.
#      OPT-IN per app (`portdoor` flag), and that is a deliberate asymmetry
#      from door 2, not an oversight: this door makes Caddy bind the app's own
#      port number on the tailnet interface, so it collides with any dev server
#      that binds 0.0.0.0 (sideclaw does today) and with `tailscale serve`
#      (rb's :7730 row). Auto-generating 17 of them would have Caddy squat
#      ports that dev servers and `docker compose` then fail to bind, days
#      later, with a confusing error. Door 2 has no such problem — every app
#      shares one :443 listener — which is why it is the one that defaults on.
#
#   2. A clean wildcard door (https://<app>.$DEV_DOMAIN) — ONE Caddy site
#      block on :443 of the tailnet IP, secured by a single wildcard Let's
#      Encrypt cert via Cloudflare DNS-01. Opt-in per MACHINE: only emitted
#      once ~/.config/caddy-tailnet.conf sets DEV_DOMAIN AND a chmod-600
#      Cloudflare token file exists. Needs `make caddy-dns-build` first — stock
#      Homebrew Caddy ships zero DNS provider modules, so the ACME challenge
#      has nowhere to run without it. See that target's comment for the
#      brew-upgrade trap it exists to catch.
#
# Door 2 also serves a LANDING PAGE at https://$DEV_DOMAIN and at
# https://apps.$DEV_DOMAIN — and at any unmatched name, so a typo shows you what
# exists instead of a bare 404. It probes each app same-origin through generated
# `/_up/<name>` routes, so there is no new daemon and no CORS.
#
# The bare $DEV_DOMAIN needs its own A record: a *.$DEV_DOMAIN wildcard covers
# neither the parent name in DNS nor in the cert, so the apex is a second
# subject Caddy provisions separately. devhost-health-check.sh asserts BOTH
# records against the live tailnet IP for that reason — they drift apart.
#
# Why Caddy rather than `tailscale serve`: Tailscale issue #18827 drops
# WebSockets through serve/funnel every 10-40s, which is Vite HMR breaking on a
# timer. Caddy proxies upgrades transparently. `serve` remains right for
# always-on services (rb on :7730, the IU dashboard Funnel on :8443) — those are
# declared in dotfiles-private/tailscale-serve.<machine>.conf and are not this
# script's business.
#
# Certs for door 1 come from tailscaled itself — real Let's Encrypt,
# auto-renewed, no local CA for the client to trust. Caddy runs as root, which
# is what lets it read /Library/Tailscale/sameuserproof-*.

FLAGS_FILE="${CADDY_TAILNET_PORTS:-$HOME/.config/caddy-tailnet.ports}"
CONF_FILE="${CADDY_TAILNET_CONF:-$HOME/.config/caddy-tailnet.conf}"
BREW_PREFIX="$(brew --prefix)"
CADDYFILE="${CADDY_TAILNET_CADDYFILE:-$BREW_PREFIX/etc/Caddyfile}"
# Every input AND output is overridable, so the whole generator can be exercised
# against scratch files without touching the live config:
#
#   CADDY_TAILNET_CADDYFILE  the registry to parse
#   CADDY_TAILNET_PORTS      the opt-out + flags file
#   CADDY_TAILNET_CONF       DEV_DOMAIN + the token path
#   CADDY_TAILNET_OUT        the generated include
#   CADDY_TAILNET_PAGE_DIR   the landing page directory
#   CADDY_TAILNET_NO_RELOAD  skip validate + reload
#
# That completeness is not a convenience. The INPUTS were overridable long
# before the output was, so the obvious way to test a change — point PORTS/CONF
# at scratch files and run it — quietly rewrote the REAL include and reloaded
# Caddy with it; with an empty scratch DEV_DOMAIN that silently deletes the
# clean door for every app. An OUT outside Caddyfile.d also implies NO_RELOAD,
# since validating the live Caddyfile would be judging a file this run did not
# write. Learned by doing it.
OUT="${CADDY_TAILNET_OUT:-$BREW_PREFIX/etc/Caddyfile.d/tailnet.caddy}"
# Landing page lives outside Caddyfile.d so the `*.caddy` include glob can never
# pick it up. Caddy runs as root and reads it regardless of owner.
PAGE_DIR="${CADDY_TAILNET_PAGE_DIR:-$BREW_PREFIX/var/caddy-tailnet}"
REGISTRY_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/caddy-registry.py"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

# Stamped into the flags file to mark it as the post-registry format. Migration
# is gated on its ABSENCE, so it can only ever run once.
FLAGS_SENTINEL="# format: registry-v2"

# The subdomain the landing page answers on. Reserved: an app by this name
# would shadow it, so the generator refuses rather than silently losing the page.
LANDING_NAME="apps"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

[[ -x "$TS" ]] || die "Tailscale.app not found — this is meant to run on the dev host"
[[ -f "$REGISTRY_PY" ]] || die "missing $REGISTRY_PY"
[[ -f "$CADDYFILE" ]] || die "missing $CADDYFILE"

# --- machine-local config ----------------------------------------------------
# Base domain + Cloudflare token path for the clean wildcard door. Shell-sourced
# rather than parsed — two variables, nothing to get wrong. Seeded with an empty
# DEV_DOMAIN so an un-seeded machine is a valid, silent state (door 1 only),
# not an error.
if [[ ! -f "$CONF_FILE" ]]; then
  mkdir -p "$(dirname "$CONF_FILE")"
  cat > "$CONF_FILE" <<'SEED'
# Base domain for clean dev vhosts, e.g. mini.jkrumm.com — leave empty to
# generate only the port-based .ts.net doors.
#
# SET THIS LAST. It is the feature's on-switch for the heartbeat too:
# devhost-health-check.sh treats a non-empty DEV_DOMAIN as "the clean door is
# supposed to work" and then asserts the DNS module, the cert and the A record.
# Filling it in before `make caddy-dns-build` and the token file exist takes
# the MacMini Dev Host monitor DOWN — correctly, but for a feature you were
# still in the middle of wiring up. Order: token file → caddy-dns-build →
# DEV_DOMAIN → make caddy-tailnet.
DEV_DOMAIN=

# chmod-600 file holding a Cloudflare API token scoped to Zone:Read +
# DNS:Edit on the parent zone. Used for the ACME DNS-01 challenge.
CF_TOKEN_FILE=$HOME/.config/caddy/cloudflare-dns.token
SEED
  printf 'seeded %s — edit it and re-run\n' "$CONF_FILE"
fi
# shellcheck disable=SC1090,SC1091
source "$CONF_FILE"

# --- the registry ------------------------------------------------------------
# Parallel indexed arrays, not associative ones: macOS ships bash 3.2 and there
# is no bash 4 in the Brewfile, so `declare -A` is simply unavailable here.
APP_NAME=()
APP_PORT=()
APP_REWRITE=()   # 1 = rewrite upstream Host to localhost:PORT
APP_PORTDOOR=()  # 1 = also publish the port-based .ts.net door
APP_EXCLUDED=()  # 1 = no doors at all

# Capture the extractor's stderr rather than letting it stream past. It reports
# `.test` blocks it refused to guess about (a block with two reverse_proxy
# handlers, a multi-host match, a non-loopback upstream) and those are exactly
# the apps that end up with NO tailnet door — while the summary below otherwise
# reports a confident "N clean doors" and never mentions the omission. The
# retired `whisper.test` block in config/Caddyfile is that shape, so a
# path-split app is a real pattern here, not a hypothetical. Re-printed in the
# summary where it will actually be read.
skipped_file=$(mktemp -t caddy-tailnet-skipped) || die "could not create a temp file"
# shellcheck disable=SC2064
trap "rm -f '$skipped_file'" EXIT
if ! registry=$(python3 "$REGISTRY_PY" --caddyfile "$CADDYFILE" 2>"$skipped_file"); then
  cat "$skipped_file" >&2
  die "could not read the dev-app registry from $CADDYFILE (see above)"
fi
skipped_blocks=$(cat "$skipped_file")

while IFS=$'\t' read -r name port rewrite; do
  [[ -n ${name:-} ]] || continue
  APP_NAME+=("$name")
  APP_PORT+=("$port")
  APP_REWRITE+=("$rewrite")
  APP_PORTDOOR+=(0)
  APP_EXCLUDED+=(0)
done <<< "$registry"

(( ${#APP_NAME[@]} > 0 )) || die "registry came back empty — refusing to tear down every dev door"

# Index of an app by name, or empty. Linear over ~17 entries; a hash would buy
# nothing and bash 3.2 doesn't have one anyway.
app_index() {
  local want="$1" i
  for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
    if [[ "${APP_NAME[$i]}" == "$want" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# Index of the app owning a port, or empty. Used only by the legacy migration.
app_index_by_port() {
  local want="$1" i
  for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
    if [[ "${APP_PORT[$i]}" == "$want" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

if idx=$(app_index "$LANDING_NAME"); then
  die "an app is named '$LANDING_NAME' (port ${APP_PORT[$idx]}) — that name is reserved for the landing page at $LANDING_NAME.\$DEV_DOMAIN. Rename the .test block in $CADDYFILE."
fi

# --- flags file: seed, or migrate the pre-registry format --------------------
# The old format was `PORT [name] [flags]` and WAS the registry. The new one is
# opt-out + flags, keyed by the .test label. Migrating rather than erroring
# keeps `make caddy-tailnet` working on the machine that has the old file, and
# the mapping is exact: every legacy port belongs to a registry app.
flags_header() {
  # Quoted heredoc: every $ and backtick below is literal documentation text.
  printf '%s\n' "$FLAGS_SENTINEL"
  cat <<'HEADER'
# Opt-OUT and flags for the tailnet dev doors. This is NOT the app registry.
#
# The registry is the tracked config/Caddyfile: every `<name>.test {
# reverse_proxy localhost:PORT }` block there automatically gets a clean door at
# https://<name>.$DEV_DOMAIN (see ~/.config/caddy-tailnet.conf). A new app needs
# NO entry here — that is the point. This file records only the exceptions.
#
# Re-run `make caddy-tailnet` after editing. Blank lines and # comments ignored.
#
#   exclude <name>       no doors at all for <name>
#   <name> <flags...>    flags for <name>
#
# Flags:
#
#   portdoor       ALSO publish the port-based fallback door
#                  https://<magicdns>:<PORT>, whose cert comes from tailscaled
#                  itself (no Cloudflare, no ACME). Opt-in, deliberately: this
#                  door makes Caddy bind the app's own port number on the
#                  tailnet interface, so it collides with any dev server that
#                  binds 0.0.0.0 (sideclaw does) and with `tailscale serve`
#                  (rb's :7730 row). The clean door has no such problem —
#                  every app shares one :443 listener — so it is the default.
#
#   host=rewrite   rewrite the upstream Host header to localhost:PORT. The
#                  escape hatch for a dev server that validates Host on
#                  dev-only endpoints and cannot be allowlisted. Carried over
#                  AUTOMATICALLY from a `header_up Host localhost:PORT` in the
#                  app's own .test block (fpp.test has one), so this is only
#                  needed to force it on for an app whose block does not.
#
# Every app served this way needs its dev server to accept the door's Host
# header — Vite/Astro `server.allowedHosts`, Next `allowedDevOrigins` — or it
# answers 403. The landing page at https://apps.$DEV_DOMAIN names that state
# explicitly, because it looks exactly like a proxy fault and is not one.
HEADER
}

if [[ ! -f "$FLAGS_FILE" ]]; then
  mkdir -p "$(dirname "$FLAGS_FILE")"
  flags_header > "$FLAGS_FILE"
  printf 'seeded %s\n' "$FLAGS_FILE"
elif ! grep -q "^$FLAGS_SENTINEL\$" "$FLAGS_FILE"; then
  # No sentinel => this file predates the registry change and its directives are
  # in the old `PORT [name] [flags]` shape. Migrate ONCE, then stamp it.
  #
  # Gating on the sentinel rather than on "does any line start with digits" is
  # deliberate. The registry's own LABEL regex permits an all-numeric app name,
  # so a perfectly valid new-style line like `7700 portdoor` would re-trip a
  # shape sniffer and rewrite the file on every run — silently discarding real
  # directives. A one-way stamp cannot be re-triggered by content.
  backup="$FLAGS_FILE.pre-registry"
  [[ -e "$backup" ]] || cp "$FLAGS_FILE" "$backup"

  migrated=""
  renames=""
  kept=""
  while read -r f1 f2 _rest || [[ -n ${f1:-} ]]; do
    [[ -z ${f1:-} || $f1 == \#* ]] && continue
    if [[ $f1 =~ ^[0-9]+$ ]]; then
      # Legacy: PORT [name] [flags]
      if lidx=$(app_index_by_port "$f1"); then
        migrated+="${APP_NAME[$lidx]} portdoor"$'\n'
        if [[ -n ${f2:-} && "$f2" != "${APP_NAME[$lidx]}" ]]; then
          renames+="    ${f2}.\$DEV_DOMAIN → ${APP_NAME[$lidx]}.\$DEV_DOMAIN"$'\n'
        fi
      else
        warn "legacy entry '$f1 ${f2:-}' has no .test block in $CADDYFILE — dropped"
      fi
    else
      # Already new-style (a hand-added `exclude x` or `x portdoor`). Carry it
      # through verbatim — rewriting the file from the legacy lines alone would
      # silently delete these, and an `exclude` lost that way re-EXPOSES an app
      # on the very run that reports a tidy successful migration.
      kept+="$f1${f2:+ $f2}${_rest:+ $_rest}"$'\n'
    fi
  done < "$FLAGS_FILE"

  { flags_header; printf '\n%s%s' "$kept" "$migrated"; } > "$FLAGS_FILE"

  if [[ -n "$migrated$kept" ]]; then
    n_migrated=$(printf '%s' "$migrated" | grep -c . || true)
    printf '\n  migrated %s to the new opt-out format (old file kept at %s)\n' \
      "$FLAGS_FILE" "$backup"
    printf '  the %d previously-declared ports keep their port doors; every app in\n' "$n_migrated"
    printf '  %s now gets a clean door automatically.\n' "$CADDYFILE"
    if [[ -n "$renames" ]]; then
      printf '\n  clean-door RENAMES (the subdomain is now the .test label):\n%s' "$renames"
    fi
  fi
fi

# Read flags. An unknown name is a WARNING, not fatal: this file outlives the
# Caddyfile blocks it references, and making a removed app break the generator
# would mean a Caddyfile edit can lock you out of regenerating. The warning is
# repeated in the summary, where it is actually read.
stale_flags=""
# `|| [[ -n "$first" ]]` so a final directive with no trailing newline is still
# processed — read returns non-zero at EOF even when it filled the variables,
# which would otherwise drop the last line of a hand-edited file in silence.
while read -r first second rest || [[ -n ${first:-} ]]; do
  [[ -z ${first:-} || $first == \#* ]] && continue

  if [[ "$first" == "exclude" ]]; then
    [[ -n ${second:-} ]] || die "'exclude' with no app name in $FLAGS_FILE"
    if idx=$(app_index "$second"); then
      APP_EXCLUDED[idx]=1
    else
      stale_flags+="exclude $second"$'\n'
    fi
    continue
  fi

  if ! idx=$(app_index "$first"); then
    stale_flags+="$first"$'\n'
    continue
  fi

  # `set -f` around the split: flags are whitespace-separated, but an unquoted
  # expansion is also subject to pathname expansion, so a stray `*` in the file
  # would silently become a list of filenames from the cwd.
  set -f
  # Deliberate word splitting; globbing is disabled by the `set -f` above.
  # shellcheck disable=SC2086
  for flag in ${second:-} ${rest:-}; do
    case "$flag" in
      portdoor)    APP_PORTDOOR[idx]=1 ;;
      host=rewrite) APP_REWRITE[idx]=1 ;;
      *) warn "unknown flag '$flag' for '$first' in $FLAGS_FILE — ignored" ;;
    esac
  done
  set +f
done < "$FLAGS_FILE"

# --- tailnet identity --------------------------------------------------------
# Live values, never hardcoded: a device rename or IP change must not silently
# leave a stale binding behind (the same failure mode tailscale-serve.sh exists
# to prevent).
ts_json=$("$TS" status --json)
HOSTN=$(printf '%s' "$ts_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
IP=$(printf '%s' "$ts_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["Self"]["TailscaleIPs"][0])')
[[ -n $HOSTN && -n $IP ]] || die "could not read this machine's tailnet identity"

# A port door binds $IP:PORT, so anything else already holding that address
# makes `caddy reload` fail outright — taking the WHOLE include down, working
# doors included.
#
# Only `tailscale serve` is checked up front, because it is the one case that
# can be identified with NO false positives: tailscaled owns those ports and
# caddy never does. The general "is something on this port" check is
# deliberately NOT done here — our own caddy is still holding every port it
# published last run, and netstat cannot say whose socket it is, so the check
# fired on all four healthy doors on the first run. A warning that cries wolf
# on the happy path is worse than none: it trains you to skim past the one
# line that would have named a real collision. The real conflict surfaces as a
# reload failure, and `reload_conflict_report` below turns that into a
# diagnosis at the moment it actually matters.
serve_ports=" $("$TS" serve status 2>/dev/null | grep -oE '\.ts\.net:[0-9]+' | cut -d: -f2 | tr '\n' ' ' || true)"

# --- `tailscale serve` rows, for the landing page ----------------------------
# The dev doors are only PART of what this machine publishes: `tailscale serve`
# has its own bindings, and one of them is a Funnel to the PUBLIC INTERNET. A
# page that lists 18 tailnet-only doors and says nothing about the funneled one
# is worse than no page — it reads as a complete exposure map while omitting the
# only row where "who can reach this" has a different answer.
#
# Read LIVE from tailscaled rather than from the declared conf, because the
# question the page answers is what is actually exposed right now, not what was
# intended. Drift between the two is `make tailscale-serve-check`'s job, and the
# page says so rather than quietly implying it re-checked.
#
# Labels come from an OPTIONAL 4th column of the declared conf in the private
# repo — tailscale-serve.sh normalises with `$1|$2|$3`, so extra fields are
# invisible to the applier and cannot cause drift. A missing repo, file or label
# degrades to showing the proxy target: never to a guessed name, since a wrong
# label on an exposure map is the one failure that matters here.
MACHINE=$(printf '%s' "$ts_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["Self"]["HostName"])')
SERVE_CONF="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}/tailscale-serve.$MACHINE.conf"

# The program is read into a variable and passed with `python3 -c`, NOT piped in
# as `python3 - <<'PY'`: a heredoc IS stdin, so it would take the place of the
# `tailscale serve status` pipe and python would read an empty document without
# erroring — the section silently renders as "no bindings" on a machine that has
# three. That is exactly how this first shipped.
serve_py=$(cat <<'SERVE_PY'
import json, os, sys

labels = {}
conf = sys.argv[1] if len(sys.argv) > 1 else ""
if conf and os.path.exists(conf):
    with open(conf) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) >= 4:
                labels[fields[0]] = " ".join(fields[3:])

raw = sys.stdin.read().strip()
cfg = json.loads(raw) if raw and raw != "null" else {}
cfg = cfg or {}
funnel = cfg.get("AllowFunnel") or {}

rows = []
for hostport, web in (cfg.get("Web") or {}).items():
    port = hostport.rsplit(":", 1)[-1]
    proxy = ((web.get("Handlers") or {}).get("/") or {}).get("Proxy", "")
    rows.append({
        "p": port,
        "t": proxy,
        "f": bool(funnel.get(hostport)),
        "l": labels.get(port, ""),
    })
rows.sort(key=lambda r: int(r["p"]))
print(json.dumps(rows, separators=(",", ":")))
SERVE_PY
)

serve_json=$( { "$TS" serve status --json 2>/dev/null || echo null; } \
  | python3 -c "$serve_py" "$SERVE_CONF" ) || serve_json="[]"
[[ -n "$serve_json" ]] || serve_json="[]"

reload_conflict_report() {
  # Called only after a failed reload. netstat, not lsof: caddy runs as a root
  # LaunchDaemon and is invisible to an unprivileged `lsof -iTCP`, which would
  # report a serene all-clear and send the diagnosis the wrong way entirely.
  local listeners i port
  listeners=$(/usr/sbin/netstat -an -p tcp 2>/dev/null | grep LISTEN || true)
  for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
    (( APP_EXCLUDED[i] )) && continue
    (( APP_PORTDOOR[i] )) || continue
    port="${APP_PORT[$i]}"
    if grep -qE "(\*|${IP//./\\.})\.${port}[[:space:]]" <<<"$listeners"; then
      printf '  port door %s:%s — something holds that port on a non-loopback address.\n' \
        "${APP_NAME[$i]}" "$port" >&2
      printf "    If it is a dev server bound to 0.0.0.0, or a 'tailscale serve' row,\n" >&2
      printf "    drop the 'portdoor' flag for %s in %s.\n" "${APP_NAME[$i]}" "$FLAGS_FILE" >&2
    fi
  done
}

# --- door 2 buildable? -------------------------------------------------------
# Missing DEV_DOMAIN or an unreadable token file is a valid, silent "not seeded
# yet" state — door 1 still gets generated. A token file that EXISTS but is more
# permissive than 600 is a different thing (a live misconfiguration of a real
# secret) and is refused loudly rather than silently skipped.
wildcard_enabled=0
if [[ -n "${DEV_DOMAIN:-}" ]]; then
  if [[ -r "${CF_TOKEN_FILE:-}" ]]; then
    perms=$(stat -f '%Lp' "$CF_TOKEN_FILE" 2>/dev/null || echo "")
    [[ "$perms" == "600" ]] \
      || die "$CF_TOKEN_FILE is mode ${perms:-unknown}, expected 600 (it holds a Cloudflare API token) — chmod 600 it"
    wildcard_enabled=1
  else
    printf 'hint: DEV_DOMAIN=%s but no readable Cloudflare token at %s — generating port doors only.\n' \
      "$DEV_DOMAIN" "${CF_TOKEN_FILE:-<unset>}" >&2
    printf '      create it (chmod 600) to also get https://<app>.%s\n' "$DEV_DOMAIN" >&2
  fi
fi

token=""
if (( wildcard_enabled )); then
  # Fail here, not 40 lines later. Without the module, `tls { dns cloudflare }`
  # is an unknown directive and the only symptom is `caddy validate` rejecting
  # the whole config with "generated config is invalid — inspect <file>", which
  # points at a file that is in fact perfectly correct. Name the real cause.
  # Capture first, match second: piping into `grep -q` under `set -o pipefail`
  # SIGPIPEs the producer and reports a healthy module list as a failure.
  modules=$(caddy list-modules 2>/dev/null) || true
  grep -q 'dns.providers.cloudflare' <<<"$modules" \
    || die "caddy has no dns.providers.cloudflare module — the wildcard door needs it. Run: make caddy-dns-build"

  # Read once, trim, never print — this value only ever lands inside $OUT via
  # redirection, never on stdout/stderr.
  token=$(< "$CF_TOKEN_FILE")
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  [[ -n "$token" ]] || die "$CF_TOKEN_FILE is empty"
fi

# --- generate ----------------------------------------------------------------
mkdir -p "$(dirname "$OUT")"

# Keep the last known-good include so a failed validate can put it back. Without
# this, a generator bug leaves a BROKEN include on disk: `caddy reload` refuses
# it, so the running server keeps serving the old config and everything looks
# fine — until the next reboot or `brew services restart caddy`, when Caddy
# fails to start and takes down the local `.test` proxy, metabase, and both
# tailnet doors at once, with nothing connecting the failure to this script.
# Mode is preserved by `cp -p`, so the rollback copy is 600 too.
ROLLBACK=""
if [[ -f "$OUT" ]]; then
  ROLLBACK="$OUT.rollback"
  cp -p "$OUT" "$ROLLBACK"
fi
restore_rollback() {
  [[ -n "$ROLLBACK" && -f "$ROLLBACK" ]] || return 0
  mv -f "$ROLLBACK" "$OUT"
  printf '  restored the previous include — the live config is unchanged.\n' >&2
}

# Tighten the mode BEFORE a single byte of token is written, not after. A plain
# `> "$OUT"` creates the file at the ambient umask — 644 here — so chmodding
# only at the end leaves a window in which the Cloudflare token sits in a
# world-readable file. `>` truncates in place and preserves the existing mode,
# so pre-creating at 600 closes the window on a fresh machine, and re-asserting
# it is a no-op on one where the file already exists.
if (( wildcard_enabled )); then
  # Subshell umask, so the create itself is 600 — `: > "$OUT"` on its own would
  # obey the ambient 022 and briefly exist as 644 (empty, but needlessly so).
  [[ -e "$OUT" ]] || ( umask 077; : > "$OUT" )
  chmod 600 "$OUT" || die "could not chmod 600 $OUT before writing the Cloudflare token"
fi

{
  echo "# GENERATED by scripts/caddy-tailnet.sh — do not edit by hand."
  echo "# Machine-local: names this host's MagicDNS name + Tailscale IP, so it"
  echo "# is deliberately untracked."
  echo "#"
  echo "# The app list comes from the .test blocks in:"
  echo "#   $CADDYFILE"
  echo "# Opt-outs and per-app flags:"
  echo "#   $FLAGS_FILE"
  echo "# DEV_DOMAIN / the Cloudflare token path:"
  echo "#   $CONF_FILE"
  if (( wildcard_enabled )); then
    echo "#"
    echo "# This file CONTAINS the Cloudflare API token below (tls > dns cloudflare)."
    echo "# It is chmod 600 after generation for exactly that reason — do not relax"
    echo "# that, and do not paste its contents anywhere else."
  fi
  echo "#"
  echo "# bind is load-bearing: without it Caddy takes 0.0.0.0:PORT and collides"
  echo "# with the dev server already on 127.0.0.1:PORT."
  echo "#"
  echo "# Upstreams dial 'localhost:PORT', NOT '127.0.0.1:PORT', matching the .test"
  echo "# blocks in the tracked Caddyfile. A dev server does not reliably bind the"
  echo "# IPv4 loopback: Vite, on finding the port already held on another address,"
  echo "# falls back to binding ::1 ALONE and still prints a cheerful 'ready' line."
  echo "# A hardcoded 127.0.0.1 upstream then 502s against an app that is plainly"
  echo "# running — observed here with basalt-playground on 7710 while a port door"
  echo "# held the tailnet IP. 'localhost' resolves to both families and Go's"
  echo "# dialer tries each, so it covers the app whichever way it binds."
  echo ""
  echo "(tailnet) {"
  echo "	bind $IP"
  echo "	tls {"
  echo "		get_certificate tailscale"
  echo "	}"
  echo "}"
  echo ""

  # Door 1 — opt-in port doors.
  for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
    (( APP_EXCLUDED[i] )) && continue
    (( APP_PORTDOOR[i] )) || continue
    echo "# ${APP_NAME[$i]}"
    echo "$HOSTN:${APP_PORT[$i]} {"
    echo "	import tailnet"
    if (( APP_REWRITE[i] )); then
      echo "	reverse_proxy localhost:${APP_PORT[$i]} {"
      echo "		header_up Host localhost:${APP_PORT[$i]}"
      echo "	}"
    else
      echo "	reverse_proxy localhost:${APP_PORT[$i]}"
    fi
    echo "}"
    echo ""
  done

  # Door 2 — one wildcard block for every app.
  if (( wildcard_enabled )); then
    echo "# --- clean dev door: https://<app>.$DEV_DOMAIN --------------------------"
    echo "#"
    echo "# ONE site block for every app below, not one block per app. Caddy 2.10+"
    echo "# issues a SINGLE wildcard cert (*.$DEV_DOMAIN) that covers every host {}"
    echo "# matcher inside one site block; N site blocks would each provision their"
    echo "# own cert, racing Let's Encrypt's ~50-certs-per-registered-domain-per-week"
    echo "# limit for no benefit."
    echo "#"
    echo "# The bare $DEV_DOMAIN is on the address line as a SECOND subject, not a"
    echo "# third door: a wildcard covers only one label below the name, so the apex"
    echo "# gets its own cert either way. Sharing the block means it falls through"
    echo "# every host matcher into the landing-page fallback below, which is the"
    echo "# whole point — https://$DEV_DOMAIN IS the app index. It needs its own A"
    echo "# record too; the wildcard record does not answer for it."
    echo "#"
    echo "# resolvers 1.1.1.1 works around caddy-dns/cloudflare#96 (the provider's"
    echo "# own zone-detection lookups against Cloudflare's authoritative servers"
    echo "# intermittently fail; a public recursive resolver does not)."
    echo "#"
    echo "# Needs the cloudflare DNS module — stock Homebrew Caddy ships none, see"
    echo "# 'make caddy-dns-build'. A later 'brew upgrade caddy' silently reverts"
    echo "# that build (module gone, nothing errors until the cert fails to renew"
    echo "# ~60 days out) — devhost-health-check.sh asserts the module on every run"
    echo "# for that reason; re-run caddy-dns-build after any caddy upgrade."
    echo "*.$DEV_DOMAIN, $DEV_DOMAIN {"
    echo "	bind $IP"
    echo "	tls {"
    echo "		dns cloudflare $token"
    echo "		resolvers 1.1.1.1"
    echo "	}"
    echo ""

    for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
      (( APP_EXCLUDED[i] )) && continue
      # Caddy matcher names cannot start with a non-letter and, verified via
      # `caddy validate` against 2.11.4, dashes and dots are in fact accepted —
      # sanitised to [a-z0-9_] anyway per the house rule of not depending on
      # incidental parser leniency for a generated identifier. The registry
      # already guarantees the name is one lowercase DNS label.
      matcher=$(printf '%s' "${APP_NAME[$i]}" | tr -c 'a-z0-9_' '_')
      echo "	@$matcher host ${APP_NAME[$i]}.$DEV_DOMAIN"
      echo "	handle @$matcher {"
      if (( APP_REWRITE[i] )); then
        # Escape hatch for a dev server that checks Host on dev-only endpoints
        # and can't be allowlisted — same shape as fpp.test in config/Caddyfile.
        echo "		reverse_proxy localhost:${APP_PORT[$i]} {"
        echo "			header_up Host localhost:${APP_PORT[$i]}"
        echo "		}"
      else
        echo "		reverse_proxy localhost:${APP_PORT[$i]}"
      fi
      echo "	}"
      echo ""
    done

    # The bare fallback MUST be last: `handle` blocks in one group are
    # mutually exclusive and first-match, so a bare one written earlier would
    # swallow every named host above.
    echo "	# Landing page + its status probes. Reached at https://$DEV_DOMAIN, at"
    echo "	# https://$LANDING_NAME.$DEV_DOMAIN, and at ANY unmatched name, so a typo"
    echo "	# shows you what exists rather than a bare 404."
    echo "	#"
    echo "	# The /_up/<name> routes are what make the status column work with no"
    echo "	# daemon and no CORS: the page is served from this same origin, so it just"
    echo "	# fetches /_up/<name> and reads the status code. They live nested INSIDE"
    echo "	# this fallback rather than at the top of the block on purpose — at the top"
    echo "	# they would shadow /_up/* on every real app's own subdomain."
    echo "	#"
    echo "	# 'rewrite * /' is load-bearing. Without it the upstream receives"
    echo "	# /_up/<name> and a perfectly healthy dev server answers 404, which is"
    echo "	# indistinguishable from other failures; with it, a live app returns its"
    echo "	# real status. dial_timeout bounds the worst case for a port that hangs"
    echo "	# rather than refusing (a refused connection 502s instantly)."
    echo "	handle {"
    for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
      (( APP_EXCLUDED[i] )) && continue
      echo "		handle /_up/${APP_NAME[$i]} {"
      echo "			rewrite * /"
      echo "			reverse_proxy localhost:${APP_PORT[$i]} {"
      if (( APP_REWRITE[i] )); then
        echo "				header_up Host localhost:${APP_PORT[$i]}"
      else
        # Send the Host the REAL door sends, not the landing page's own. The
        # probe exists to answer "would this app serve its door?", and the
        # 403 state is decided purely by the Host header — so probing with
        # apps.$DEV_DOMAIN would be testing a hostname no app is configured
        # for. It happens to agree whenever the allowlist is the recommended
        # leading-dot form, and to disagree for anyone who allowlisted their
        # one exact door name.
        echo "				header_up Host ${APP_NAME[$i]}.$DEV_DOMAIN"
      fi
      echo "				transport http {"
      echo "					dial_timeout 1s"
      echo "				}"
      echo "			}"
      echo "		}"
    done
    # Catch-all for /_up/<anything-else>, and it has to exist. Without it an
    # unknown probe path falls through to file_server, which has no such file
    # and answers 404 — and 404 is a status the page classifies as UP, because
    # a running app legitimately 404s. So an app with no door at all would
    # render a green badge. The commonest way to hit that is a page left open
    # across a regeneration that excluded an app. 410 is unambiguous: no other
    # path here produces it.
    echo "		handle /_up/* {"
    echo "			respond \"no probe route for this name — regenerate or reload the page\" 410"
    echo "		}"
    echo "		handle {"
    echo "			root * $PAGE_DIR"
    echo "			file_server"
    echo "		}"
    echo "	}"
    echo "}"
    echo ""
  fi
} > "$OUT"

if (( wildcard_enabled )); then
  chmod 600 "$OUT" || die "could not chmod 600 $OUT (it now contains a Cloudflare token)"
fi

# --- landing page ------------------------------------------------------------
# Generated to a file and served with root + file_server rather than inlined in
# a `respond` directive: the page is a few KB of HTML/CSS/JS, and every byte of
# it inside the Caddyfile would be a byte inside the chmod-600 token-bearing
# include, re-escaped, and re-parsed by Caddy on every reload.
#
# `root * <dir>` accepts a nonexistent directory at validate time and a
# directory with no index.html returns 404 rather than a listing — neither
# shows up in `caddy validate`, so the only guard is generating both here.
if (( wildcard_enabled )); then
  mkdir -p "$PAGE_DIR"

  apps_json=""
  for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
    (( APP_EXCLUDED[i] )) && continue
    [[ -n "$apps_json" ]] && apps_json+=","
    apps_json+=$(printf '{"n":"%s","p":%s,"d":%s}' \
      "${APP_NAME[$i]}" "${APP_PORT[$i]}" "${APP_PORTDOOR[$i]}")
  done

  {
    cat <<'PAGE_HEAD'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dev apps</title>
<!-- GENERATED by scripts/caddy-tailnet.sh — do not edit by hand. -->
<!-- Empty data: icon suppresses the favicon request outright. Without it the
     browser asks for /favicon.ico, file_server has none, and every visit logs a
     404 next to the probes' legitimate 502s — noise in exactly the console you
     would open to debug a probe. -->
<link rel="icon" href="data:,">
<style>
:root {
	color-scheme: dark light;
	--bg: #1f1f23; --panel: #27272a; --line: #3f3f46;
	--fg: #d4d4d8; --dim: #a1a1aa; --faint: #71717a;
	--up: #4ea172; --warn: #d19a45; --bad: #d16a6a;
}
@media (prefers-color-scheme: light) {
	:root {
		--bg: #f2f2f5; --panel: #e4e4e7; --line: #d4d4d8;
		--fg: #27272a; --dim: #52525b; --faint: #71717a;
		--up: #2f7d55; --warn: #8a5f1c; --bad: #a83f3f;
	}
}
* { box-sizing: border-box; }
body {
	margin: 0; padding: 2.5rem 1.5rem 4rem;
	background: var(--bg); color: var(--fg);
	font: 13.5px/1.55 ui-monospace, SFMono-Regular, "JetBrainsMono Nerd Font Mono", Menlo, monospace;
}
main { max-width: 60rem; margin: 0 auto; }
h1 { font-size: 1.05rem; font-weight: 600; margin: 0 0 .3rem; }
.sub { color: var(--faint); margin: 0 0 2rem; font-size: .8rem; }
table { width: 100%; border-collapse: collapse; }
th {
	text-align: left; font-weight: 500; color: var(--faint);
	font-size: .68rem; letter-spacing: .09em; text-transform: uppercase;
	padding: 0 .7rem .55rem; border-bottom: 1px solid var(--line);
}
td { padding: .5rem .7rem; border-bottom: 1px solid var(--line); vertical-align: baseline; }
tr:hover td { background: var(--panel); }
/* The whole row is the primary link — the door cell's <a> is kept only so the
   URL is visible, copyable and middle-clickable. cursor+focus ring on the row
   are what make that discoverable; without them it reads as a dead table. */
tbody tr { cursor: pointer; }
tbody tr:focus-visible { outline: 2px solid var(--up); outline-offset: -2px; }
.st { white-space: nowrap; font-size: .78rem; }
.st::before { content: "\25CF"; margin-right: .45rem; }
.up { color: var(--up); }
.down { color: var(--warn); }
.host { color: var(--bad); }
.unknown, .wait { color: var(--faint); }
.name { font-weight: 600; }
.port { color: var(--faint); font-variant-numeric: tabular-nums; }
h2.sec {
	font-size: .68rem; letter-spacing: .09em; text-transform: uppercase;
	color: var(--faint); font-weight: 500; margin: 2.5rem 0 .7rem;
}
h2.sec + .sub { margin-bottom: 1rem; }
/* Funnel is the one row on this page the public internet can reach. It gets the
   same red the Host-rejection state uses — loud on purpose, and never the same
   colour as an ordinary tailnet row. */
.reach { white-space: nowrap; font-size: .78rem; }
.reach::before { content: "\25CF"; margin-right: .45rem; }
.tailnet { color: var(--dim); }
.public { color: var(--bad); font-weight: 600; }
.target { color: var(--faint); font-size: .78rem; }
a { color: inherit; text-decoration: none; border-bottom: 1px solid var(--line); }
a:hover { border-bottom-color: currentColor; }
a.alt { color: var(--faint); font-size: .78rem; }
.doors { display: flex; flex-direction: column; gap: .2rem; align-items: flex-start; }
footer { margin-top: 2.5rem; color: var(--dim); font-size: .78rem; }
footer h2 {
	font-size: .68rem; letter-spacing: .09em; text-transform: uppercase;
	color: var(--faint); font-weight: 500; margin: 0 0 .7rem;
}
footer p { margin: 0 0 .6rem; }
code {
	background: var(--panel); padding: .1rem .35rem; border-radius: 3px;
	color: var(--fg);
}
.k { color: var(--fg); }
</style>
<main>
	<h1>dev apps</h1>
	<p class="sub" id="sub"></p>
	<table>
		<thead>
			<tr>
				<th style="width:12rem">status</th>
				<th>app</th>
				<th style="width:5rem">port</th>
				<th>doors</th>
			</tr>
		</thead>
		<tbody id="rows"></tbody>
	</table>

	<!-- Hidden until the script finds rows: a machine with no serve bindings
	     shows nothing here, not an empty table under a heading. -->
	<section id="serve" hidden>
		<h2 class="sec">tailscale serve</h2>
		<p class="sub" id="servesub"></p>
		<table>
			<thead>
				<tr>
					<th style="width:12rem">reach</th>
					<th>binding</th>
					<th style="width:5rem">port</th>
					<th>door</th>
				</tr>
			</thead>
			<tbody id="serverows"></tbody>
		</table>
	</section>

	<footer>
		<h2>reading the status</h2>
		<p><span class="st up">up</span> &mdash; the dev server answered.</p>
		<p><span class="st down">not running</span> &mdash; nothing is listening on that
			port, so Caddy could not dial it (502). Start the app.</p>
		<p><span class="st host">rejects Host</span> &mdash; the dev server IS running but
			answered <code>403</code>. Almost always the Host allowlist rather than the app's
			own auth: an app config fix, not a proxy fault, and the single most common
			failure here. Add <code class="dom"></code> to:</p>
		<p>
			<span class="k">Vite</span> <code>server.allowedHosts</code>
			&nbsp;&middot;&nbsp;
			<span class="k">Astro</span> <code>vite.server.allowedHosts</code>
			&nbsp;&middot;&nbsp;
			<span class="k">Next.js</span> <code>allowedDevOrigins</code>
		</p>
		<p>For Vite and Astro the leading dot matches the domain and every subdomain, so
			one entry covers every door. Next.js does not understand a leading dot &mdash; it
			globs whole segments, so use <code class="star"></code> instead. A server that
			validates <code>Host</code> on dev-only endpoints and cannot be allowlisted gets
			the <code>host=rewrite</code> flag instead.</p>
		<p><span class="st wait">no response</span> &mdash; the port accepted the connection
			but sent nothing back in 8s. Usually a cold start (a first Vite dependency
			optimise), not a fault &mdash; reload in a moment. <span class="st unknown">unreachable</span>
			means the probe itself failed, <span class="st unknown">no door &mdash; reload</span>
			that this page predates a regeneration that removed the app, and
			<span class="st unknown">unknown</span> a status outside the cases above (a 5xx
			other than 502).</p>
		<h2>the two doors</h2>
		<p>The clean door is one wildcard site block on this host's tailnet <code>:443</code>.
			The <code>.ts.net</code> door is the zero-dependency fallback &mdash; its cert
			comes from tailscaled itself, no Cloudflare and no ACME &mdash; and is opt-in per
			app via the <code>portdoor</code> flag.</p>
		<p>Every row above is <span class="reach tailnet">tailnet only</span>: Caddy binds
			these to this host's Tailscale IP and nothing else. Clicking a row opens its
			clean door.</p>
		<h2>tailscale serve</h2>
		<p>A separate mechanism, listed because it publishes ports this page would
			otherwise leave unaccounted for. <span class="reach public">public</span> means
			Funnel is on for that port &mdash; reachable from the open internet, not just the
			tailnet. Read live from tailscaled when the doors were last generated; the
			declared state lives in the private repo and
			<code>make tailscale-serve-check</code> is what reports drift.</p>
	</footer>
</main>
<script>
PAGE_HEAD
    printf 'const APPS = [%s];\n' "$apps_json"
    printf 'const SERVE = %s;\n' "$serve_json"
    printf 'const DOMAIN = "%s";\n' "$DEV_DOMAIN"
    printf 'const TSNET = "%s";\n' "$HOSTN"
    cat <<'PAGE_TAIL'

document.getElementById("sub").textContent =
	APPS.length + " apps · " + DOMAIN + " · registry: config/Caddyfile";
for (const el of document.querySelectorAll(".dom")) el.textContent = "." + DOMAIN;
for (const el of document.querySelectorAll(".star")) el.textContent = "*." + DOMAIN;

const STATES = {
	up:      ["up", "up"],
	down:    ["down", "not running"],
	host:    ["host", "rejects Host"],
	stale:   ["unknown", "no door — reload"],
	unknown: ["unknown", "unknown"],
	wait:    ["wait", "checking…"],
};

function link(href, text, cls) {
	const a = document.createElement("a");
	a.href = href;
	a.textContent = text;
	if (cls) a.className = cls;
	return a;
}

function cell(text, cls) {
	const td = document.createElement("td");
	if (cls) td.className = cls;
	td.textContent = text;
	return td;
}

// Make the whole row the link. A click that landed on a real <a> is left alone,
// otherwise the secondary links in the door cell would navigate to the row's
// primary target instead of their own — the one thing they exist for. Modifier-
// and middle-clicks open a new tab, so the row behaves like the link it looks
// like rather than like a table that happens to move.
function rowLink(tr, href) {
	tr.tabIndex = 0;
	tr.addEventListener("click", (ev) => {
		if (ev.target.closest("a")) return;
		if (ev.metaKey || ev.ctrlKey || ev.shiftKey) window.open(href, "_blank", "noopener");
		else window.location.href = href;
	});
	tr.addEventListener("auxclick", (ev) => {
		if (ev.button !== 1 || ev.target.closest("a")) return;
		ev.preventDefault();
		window.open(href, "_blank", "noopener");
	});
	tr.addEventListener("keydown", (ev) => {
		if (ev.key !== "Enter" || ev.target !== tr) return;
		window.location.href = href;
	});
}

const tbody = document.getElementById("rows");
const cells = new Map();

for (const app of APPS) {
	const tr = document.createElement("tr");

	const st = document.createElement("td");
	const badge = document.createElement("span");
	badge.className = "st wait";
	badge.textContent = STATES.wait[1];
	st.appendChild(badge);
	cells.set(app.n, badge);

	const name = document.createElement("td");
	name.className = "name";
	name.textContent = app.n;

	const port = document.createElement("td");
	port.className = "port";
	port.textContent = app.p;

	const doors = document.createElement("td");
	const wrap = document.createElement("div");
	wrap.className = "doors";
	const primary = "https://" + app.n + "." + DOMAIN;
	wrap.appendChild(link(primary, app.n + "." + DOMAIN));
	if (app.d) {
		wrap.appendChild(link("https://" + TSNET + ":" + app.p, TSNET + ":" + app.p, "alt"));
	}
	doors.appendChild(wrap);

	rowLink(tr, primary);

	tr.append(st, name, port, doors);
	tbody.appendChild(tr);
}

// tailscale serve — a different mechanism with a different blast radius, so a
// separate table rather than extra rows above. No probing: these are tailscaled's
// own bindings, there is no same-origin /_up route for them, and a cross-origin
// fetch would report failure for every one regardless of health.
if (SERVE.length) {
	const sbody = document.getElementById("serverows");
	const nPublic = SERVE.filter((r) => r.f).length;
	document.getElementById("servesub").textContent =
		SERVE.length + " binding" + (SERVE.length === 1 ? "" : "s") + " · " +
		(nPublic ? nPublic + " reachable from the public internet (Funnel)" : "all tailnet only");

	for (const row of SERVE) {
		const tr = document.createElement("tr");
		const door = "https://" + TSNET + ":" + row.p;

		const reach = document.createElement("td");
		const badge = document.createElement("span");
		badge.className = "reach " + (row.f ? "public" : "tailnet");
		badge.textContent = row.f ? "public — Funnel" : "tailnet only";
		reach.appendChild(badge);

		const what = document.createElement("td");
		what.className = row.l ? "name" : "target";
		what.textContent = row.l || row.t;

		const doorCell = document.createElement("td");
		const wrap = document.createElement("div");
		wrap.className = "doors";
		wrap.appendChild(link(door, TSNET + ":" + row.p));
		// The target is only worth a second line when the label already said what
		// this is; unlabelled rows show it as the name above instead of twice.
		if (row.l) {
			const t = document.createElement("span");
			t.className = "target";
			t.textContent = "→ " + row.t;
			wrap.appendChild(t);
		}
		doorCell.appendChild(wrap);

		rowLink(tr, door);
		tr.append(reach, what, cell(row.p, "port"), doorCell);
		sbody.appendChild(tr);
	}
	document.getElementById("serve").hidden = false;
}

// Same-origin probes through the generated /_up/<name> routes — no CORS, no
// daemon. Caddy answers 502 itself when it cannot dial the upstream, which is
// what separates "not running" from "running but rejecting the Host header".
function classify(status) {
	if (status === 502) return "down";
	if (status === 403) return "host";
	// 410 is the generated catch-all for a name with no probe route — the page
	// is stale relative to the config. Checked before the 2xx-4xx sweep, which
	// would otherwise call it "up".
	if (status === 410) return "stale";
	if (status >= 200 && status < 500) return "up";
	return "unknown";
}

async function probe(app) {
	const badge = cells.get(app.n);
	try {
		const res = await fetch("/_up/" + app.n, {
			method: "GET",
			cache: "no-store",
			redirect: "manual",
			signal: AbortSignal.timeout(8000),
		});
		// An opaque redirect surfaces as status 0 with type "opaqueredirect";
		// the app answered, so that is up.
		const state = res.type === "opaqueredirect" ? "up" : classify(res.status);
		badge.className = "st " + STATES[state][0];
		badge.textContent = STATES[state][1];
	} catch (err) {
		// Distinguish the two ways this throws, because they mean opposite
		// things. Caddy imposes no RESPONSE timeout — dial_timeout bounds only
		// the TCP connect — so the abort below is the only thing bounding a slow
		// upstream, and a healthy-but-slow dev server (a cold Vite optimise pass
		// easily exceeds this) lands here. Calling that "unreachable" reads as
		// "down" and sends you looking for a dead process that is fine.
		const timedOut = err && (err.name === "TimeoutError" || err.name === "AbortError");
		badge.className = "st " + (timedOut ? "wait" : "unknown");
		badge.textContent = timedOut ? "no response (>8s)" : "unreachable";
	}
}

APPS.forEach(probe);
</script>
PAGE_TAIL
  } > "$PAGE_DIR/index.html"
  chmod 644 "$PAGE_DIR/index.html"
fi

# --- validate + reload -------------------------------------------------------
# A scratch run (CADDY_TAILNET_OUT elsewhere) must not validate or reload the
# live Caddyfile — the generated file it produced is not the one that would be
# imported, so both the verdict and the reload would be about the wrong config.
if [[ -n "${CADDY_TAILNET_NO_RELOAD:-}" || "$OUT" != "$BREW_PREFIX/etc/Caddyfile.d/"* ]]; then
  printf '\n  scratch run — wrote %s, skipped validate + reload.\n' "$OUT"
  SKIP_RELOAD=1
else
  SKIP_RELOAD=0
fi

# Both failure paths roll the include back. Leaving a rejected include on disk
# is the worst outcome available here: nothing breaks now (the running server
# keeps its old config), so the failure is invisible until the next restart.
if (( ! SKIP_RELOAD )) && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  restore_rollback
  die "generated config is invalid — inspect $OUT (it holds the Cloudflare token; redact before sharing)"
fi

if (( ! SKIP_RELOAD )) && ! caddy reload --config "$CADDYFILE" --adapter caddyfile 2>/dev/null; then
  # A bind conflict is by far the likeliest cause and the least obvious from
  # caddy's own message, so name the suspects before giving up.
  reload_conflict_report
  restore_rollback
  die "caddy reload failed (is Caddy running? 'brew services list')"
fi

rm -f "$ROLLBACK"

# --- summary -----------------------------------------------------------------
printf '\n  dev doors on %s\n\n' "$HOSTN"

n_clean=0
n_port=0
n_excluded=0
for (( i = 0; i < ${#APP_NAME[@]}; i++ )); do
  if (( APP_EXCLUDED[i] )); then
    printf '    \033[2m%-20s %s  excluded\033[0m\n' "${APP_NAME[$i]}" "${APP_PORT[$i]}"
    n_excluded=$(( n_excluded + 1 ))
    continue
  fi

  flags=""
  (( APP_REWRITE[i] )) && flags=" host=rewrite"

  if (( wildcard_enabled )); then
    printf '    %-20s %s  https://%s.%s%s\n' \
      "${APP_NAME[$i]}" "${APP_PORT[$i]}" "${APP_NAME[$i]}" "$DEV_DOMAIN" "$flags"
    n_clean=$(( n_clean + 1 ))
  else
    printf '    %-20s %s%s\n' "${APP_NAME[$i]}" "${APP_PORT[$i]}" "$flags"
  fi

  if (( APP_PORTDOOR[i] )); then
    printf '    %-20s    https://%s:%s\n' "" "$HOSTN" "${APP_PORT[$i]}"
    n_port=$(( n_port + 1 ))
    case "$serve_ports" in
      *" ${APP_PORT[$i]} "*)
        warn "port door ${APP_NAME[$i]}:${APP_PORT[$i]} collides with a 'tailscale serve' row — drop the portdoor flag, or the serve row" ;;
    esac
  fi
done

if (( wildcard_enabled )); then
  printf '\n    %-20s    https://%s\n' "index" "$DEV_DOMAIN"
  printf '    %-20s    https://%s.%s\n' "" "$LANDING_NAME" "$DEV_DOMAIN"
  printf '    %-20s    (also served at any unmatched name, with live status)\n' ""
  printf '\n  %d clean doors, %d port doors, %d excluded — registry: %s\n' \
    "$n_clean" "$n_port" "$n_excluded" "$CADDYFILE"

  # Same rows the page shows, for the same reason: this output is the other
  # place someone asks "what does this machine expose", and a summary that
  # counts 18 tailnet doors while omitting a live Funnel answers it wrongly.
  printf '%s' "$serve_json" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
if not rows:
    sys.exit(0)
print("\n  tailscale serve — a separate mechanism, listed so this summary is complete\n")
for r in rows:
    # Pad BEFORE colouring: the escape sequence has no width on screen but does
    # in %-16s, so a coloured cell padded by format() comes out short.
    reach = "%-16s" % ("PUBLIC — Funnel" if r["f"] else "tailnet only")
    if r["f"]:
        reach = "\033[31m%s\033[0m" % reach
    print("    %-20s :%-5s %s %s" % (r["l"] or "", r["p"], reach, r["t"]))
' || true
else
  printf '\n  no clean door — set DEV_DOMAIN + a chmod-600 Cloudflare token in %s\n' "$CONF_FILE"
fi

if [[ -n "$skipped_blocks" ]]; then
  printf '\n\033[33m  .test blocks the registry refused to guess about — these have NO door:\033[0m\n'
  printf '%s\n' "$skipped_blocks" | sed 's/^skipped /    /'
  printf '    (a path-split block needs one reverse_proxy per app to be routable by name)\n'
fi

if [[ -n "$stale_flags" ]]; then
  printf '\n\033[33m  stale entries in %s (no such .test app — no effect):\033[0m\n' "$FLAGS_FILE"
  printf '%s' "$stale_flags" | sed 's/^/    /'
fi

printf '\n  Apps need the door'"'"'s Host header allowed (Vite/Astro server.allowedHosts,\n'
printf '  Next allowedDevOrigins) or they answer 403 — the landing page names that state.\n\n'
