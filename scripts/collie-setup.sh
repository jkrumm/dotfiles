#!/usr/bin/env bash
# collie-setup — install, report on, or remove the standalone Collie bridge.
#
#   collie-setup.sh setup      pinned checkout → build → .env → LaunchAgent → behavioural check
#   collie-setup.sh status     read-only: agent state, pinned vs installed build, the check
#   collie-setup.sh teardown   boot the agent out; checkouts go, .env and state stay
#   collie-setup.sh pair       mint a one-time pairing code for a phone (the bridge's own `pair`)
#
# Collie (docs/collie.md) is the phone control surface: remote shell by design. As of Wave 4 it
# is no longer a herdr plugin. It is upstream's compiled bridge (`bin/collie _exec-bridge`) under
# its own LaunchAgent, driving herdr-core (COLLIE_MUX=herdr-core). `make collie-setup` calls this
# with COLLIE_SOURCE / COLLIE_REF / COLLIE_VERSION from the Makefile, the single pin.
#
# Never `collie start`: that writes its own unit and publishes `tailscale serve` imperatively.
# Serve is declared state (dotfiles-private/tailscale-serve.mini.conf), and the LaunchAgent is
# ours. Launchd-first: the bridge only dials the core's socket, it never starts a core.
#
# THE CHECKOUT IS NEVER A GIT CHECKOUT. Upstream can update a git checkout in place from the
# phone (POST /api/update pulls the newest release tag), which would walk straight past the
# commit pin. So the pinned commit is cloned from a bare cache, built, and then its .git is
# removed: the install classifies as `unknown/loose-binary`, which upstream declines to update.
# One directory per pinned commit; the previous one is kept for a rollback.
#
# Env (overrides exist for scripts/collie-hc-proof.sh; production sets none of them):
#   COLLIE_SOURCE COLLIE_REF COLLIE_VERSION   the pin (required for setup, from the Makefile)
#   COLLIE_LABEL        com.jkrumm.collie        COLLIE_HOME    ~/.local/share/collie
#   COLLIE_CONFIG_DIR   ~/.config/collie         COLLIE_LOG     ~/Library/Logs/collie.log
#   COLLIE_AGENT_DIR    ~/Library/LaunchAgents   COLLIE_PORT    8787
#   COLLIE_STATE_DIR    unset (bridge default ~/.local/state/collie)
#   COLLIE_HC_SESSION / COLLIE_HC_SOCKET   a non-default core session (scratch cores)
#   COLLIE_LEGACY_MIGRATE=0   leave the classic herdr.collie plugin alone (scratch cores)
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LABEL="${COLLIE_LABEL:-com.jkrumm.collie}"
HOME_DIR="${COLLIE_HOME:-$HOME/.local/share/collie}"
CONFIG_DIR="${COLLIE_CONFIG_DIR:-$HOME/.config/collie}"
LOG="${COLLIE_LOG:-$HOME/Library/Logs/collie.log}"
AGENT_DIR="${COLLIE_AGENT_DIR:-$HOME/Library/LaunchAgents}"
PORT="${COLLIE_PORT:-8787}"
CORE_LABEL="${COLLIE_CORE_LABEL:-com.jkrumm.herdr-core}"
LEGACY_LABEL="herdr.collie"
LEGACY_PLUGIN_ID="herdr.collie"
LEGACY_CONFIG_DIR="$HOME/.config/herdr/plugins/config/herdr.collie"
TEMPLATE="$DOTFILES_DIR/scripts/com.jkrumm.collie.plist.template"
PLIST="$AGENT_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"
GIT=/usr/bin/git

die() { echo "  ✗ $*" >&2; exit 1; }
note() { echo "    $*"; }

dev_host_gate() {
  local backend
  backend=$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")
  if [ "$backend" != "cache" ]; then
    echo "    · not the dev host (backend=${backend:-unset}) — collie skipped"
    exit 0
  fi
}

loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }

# Substitute the template's placeholders; the optional per-core env lines go in through a file
# (sed `r`), because a multi-line value does not survive `-e s|…|…|`.
render_plist() {
  local root="$1" extra
  extra=$(mktemp)
  {
    [ -n "${COLLIE_HC_SESSION:-}" ] && printf '    <key>HC_SESSION</key><string>%s</string>\n' "$COLLIE_HC_SESSION"
    [ -n "${COLLIE_HC_SOCKET:-}" ] && printf '    <key>HC_SOCKET</key><string>%s</string>\n' "$COLLIE_HC_SOCKET"
    [ -n "${COLLIE_STATE_DIR:-}" ] && printf '    <key>COLLIE_STATE_DIR</key><string>%s</string>\n' "$COLLIE_STATE_DIR"
  } > "$extra"
  sed -e "s|__COLLIE_LABEL__|$LABEL|g" \
      -e "s|__COLLIE_ROOT__|$root|g" \
      -e "s|__COLLIE_CONFIG_DIR__|$CONFIG_DIR|g" \
      -e "s|__COLLIE_LOG__|$LOG|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "/__COLLIE_EXTRA_ENV__/{r $extra" -e 'd;}' "$TEMPLATE"
  rm -f "$extra"
}

# The root the installed plist points at, or empty.
installed_root() {
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$PLIST" 2>/dev/null || true
}

build_root_for() { echo "$HOME_DIR/${COLLIE_REF:0:12}"; }

# --- checkout + build ---------------------------------------------------------------------
ensure_build() {
  local root marker cache bun_dir
  root=$(build_root_for)
  marker="$root/.pinned-ref"
  if [ "$(cat "$marker" 2>/dev/null || true)" = "$COLLIE_REF" ] && [ -x "$root/bin/collie" ] && [ -f "$root/web/dist/index.html" ]; then
    note "✓ collie $COLLIE_VERSION (${COLLIE_REF:0:7}) built at $root"
    return 0
  fi
  bun_dir=$(bash "$DOTFILES_DIR/scripts/lib/bun-bin.sh") \
    || die "bun not found on PATH, ~/.bun/bin or the Homebrew prefixes — run: brew bundle install"
  note "· bun from $bun_dir"

  mkdir -p "$HOME_DIR"
  cache="$HOME_DIR/git"
  if [ ! -d "$cache" ]; then
    "$GIT" clone --quiet --bare "https://github.com/$COLLIE_SOURCE" "$cache" \
      || die "could not clone $COLLIE_SOURCE"
  fi
  if ! "$GIT" -C "$cache" cat-file -e "${COLLIE_REF}^{commit}" 2>/dev/null; then
    "$GIT" -C "$cache" fetch --quiet --tags origin "$COLLIE_REF" 2>/dev/null \
      || "$GIT" -C "$cache" fetch --quiet --tags origin \
      || die "could not fetch $COLLIE_REF from $COLLIE_SOURCE"
  fi
  [ "$("$GIT" -C "$cache" rev-parse "${COLLIE_REF}^{commit}" 2>/dev/null)" = "$COLLIE_REF" ] \
    || die "$COLLIE_REF is not a commit in $COLLIE_SOURCE — fix COLLIE_REF in the Makefile"

  note "→ building collie $COLLIE_VERSION (${COLLIE_REF:0:7}) at $root"
  rm -rf "$root"
  "$GIT" clone --quiet --no-checkout "$cache" "$root"
  "$GIT" -C "$root" checkout --quiet --detach "$COLLIE_REF"
  [ "$("$GIT" -C "$root" rev-parse HEAD)" = "$COLLIE_REF" ] || die "checkout did not land on $COLLIE_REF"
  # The fetched source builds itself (the same step upstream's bootstrap shim runs): the old
  # binary's build code never touches the new tree. Only the tail is shown; the log is kept.
  mkdir -p "$(dirname "$LOG")"
  if ! (cd "$root" && PATH="$bun_dir:$PATH" bun run cli/main.ts build > "$HOME_DIR/build.log" 2>&1); then
    tail -20 "$HOME_DIR/build.log" >&2
    rm -rf "$root"
    die "collie build failed (full log: $HOME_DIR/build.log)"
  fi
  rm -rf "$root/.git"
  [ -x "$root/bin/collie" ] && [ -f "$root/web/dist/index.html" ] || { rm -rf "$root"; die "build produced no bin/collie or web/dist"; }
  # The compiled binary carries version+commit. A mismatch means we built something else.
  local built want
  built=$(COLLIE_PLUGIN_ROOT="$root" "$root/bin/collie" version 2>/dev/null || true)
  want="$COLLIE_VERSION+${COLLIE_REF:0:10}"
  [ "$built" = "$want" ] || { rm -rf "$root"; die "built $built, expected $want"; }
  printf '%s\n' "$COLLIE_REF" > "$marker"
  note "✓ built $built"
}

# Drop the build dirs we no longer need: keep the one in use and the one that was running.
prune_builds() {
  local keep_a="$1" keep_b="$2" d
  for d in "$HOME_DIR"/*/; do
    d="${d%/}"
    [[ "$(basename "$d")" =~ ^[0-9a-f]{12}$ ]] || continue
    [ "$d" = "$keep_a" ] || [ "$d" = "$keep_b" ] || rm -rf "$d"
  done
}

# --- config -------------------------------------------------------------------------------
# The .env is written once by hand (secrets-adjacent, never templated), except for this
# one-time copy from the plugin's config dir and the COLLIE_MUX line, which is ours.
ensure_env() {
  local env="$CONFIG_DIR/.env"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [ ! -f "$env" ]; then
    [ -f "$LEGACY_CONFIG_DIR/.env" ] \
      || die "no .env at $CONFIG_DIR — write it by hand first (docs/collie.md §The .env)"
    cp "$LEGACY_CONFIG_DIR/.env" "$env"
    note "✓ .env copied from the plugin's config dir"
  fi
  chmod 600 "$env"
  if grep -q '^COLLIE_MUX=' "$env"; then
    if ! grep -q '^COLLIE_MUX=herdr-core$' "$env"; then
      sed -i '' 's|^COLLIE_MUX=.*|COLLIE_MUX=herdr-core|' "$env"
      note "✓ COLLIE_MUX set to herdr-core in the .env"
    fi
  else
    printf '\nCOLLIE_MUX=herdr-core\n' >> "$env"
    note "✓ COLLIE_MUX=herdr-core appended to the .env"
  fi
  # The settings that make this remote shell safe to leave running. Missing = refuse, never default.
  grep -q '^COLLIE_SKIP_SERVE=1$' "$env" || die ".env lacks COLLIE_SKIP_SERVE=1 — upstream would publish tailscale serve itself"
  grep -Eq '^COLLIE_HOST=(127\.0\.0\.1|localhost)$' "$env" || die ".env lacks COLLIE_HOST=127.0.0.1 — the bridge must stay on loopback"
  grep -Eq '^COLLIE_PUBLIC_HOSTS=.+' "$env" || die ".env lacks COLLIE_PUBLIC_HOSTS — the phone's Host header would be refused"
}

# --- launchd ------------------------------------------------------------------------------
core_running() {
  # A scratch session has its own core under its own job; the live one is checked by label.
  [ -n "${COLLIE_HC_SESSION:-}" ] && return 0
  launchctl print "$DOMAIN/$CORE_LABEL" 2>/dev/null | grep -Eq '^[[:space:]]+state = running'
}

legacy_retire() {
  [ "${COLLIE_LEGACY_MIGRATE:-1}" = "1" ] || return 0
  local legacy_plist="$AGENT_DIR/$LEGACY_LABEL.plist"
  if loaded "$LEGACY_LABEL"; then
    launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
    note "✓ legacy $LEGACY_LABEL (upstream plugin supervisor) booted out"
  fi
  if [ -f "$legacy_plist" ]; then
    rm -f "$legacy_plist"
    note "✓ legacy $LEGACY_LABEL plist removed"
  fi
}

legacy_plugin_uninstall() {
  [ "${COLLIE_LEGACY_MIGRATE:-1}" = "1" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  if herdr plugin list --json 2>/dev/null | jq -e --arg id "$LEGACY_PLUGIN_ID" '.result.plugins[]? | select(.plugin_id==$id)' >/dev/null 2>&1; then
    # TODO(Wave 7): drop classic — the whole plugin migration goes with classic herdr.
    if herdr plugin uninstall "$LEGACY_PLUGIN_ID" >/dev/null 2>&1; then
      note "✓ $LEGACY_PLUGIN_ID plugin uninstalled"
    else
      note "! could not uninstall the $LEGACY_PLUGIN_ID plugin — remove it by hand: herdr plugin uninstall $LEGACY_PLUGIN_ID"
    fi
  fi
}

activate() {
  local root="$1" new changed=0 prev_root
  prev_root=$(installed_root)
  mkdir -p "$AGENT_DIR" "$(dirname "$LOG")"
  new=$(mktemp)
  render_plist "$root" > "$new"
  plutil -lint "$new" >/dev/null || { rm -f "$new"; die "rendered plist is invalid"; }
  if [ ! -f "$PLIST" ] || ! cmp -s "$new" "$PLIST"; then
    mv "$new" "$PLIST"
    chmod 644 "$PLIST"
    changed=1
  else
    rm -f "$new"
  fi
  launchctl print "$DOMAIN" >/dev/null 2>&1 \
    || die "no $DOMAIN session to bootstrap into — log in at the console once, then re-run: make collie-setup"

  if [ "$changed" = "1" ] || ! loaded "$LABEL"; then
    legacy_retire
    loaded "$LABEL" && launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed for $PLIST"
    note "✓ $LABEL bootstrapped (RunAtLoad + KeepAlive)"
  else
    legacy_retire
    note "· $LABEL up to date"
  fi
  PREV_ROOT="$prev_root"
}

# --- commands -----------------------------------------------------------------------------
cmd_setup() {
  : "${COLLIE_SOURCE:?run via make collie-setup}" "${COLLIE_REF:?run via make collie-setup}" "${COLLIE_VERSION:?run via make collie-setup}"
  dev_host_gate
  [ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
  core_running || die "$CORE_LABEL is not running — run: make herdr-core-setup (Collie never starts a core)"
  local root
  root=$(build_root_for)
  ensure_build
  ensure_env
  PREV_ROOT=""
  activate "$root"
  if ! COLLIE_PORT="$PORT" COLLIE_EXPECT_VERSION="$COLLIE_VERSION+${COLLIE_REF:0:10}" bash "$DOTFILES_DIR/scripts/collie-check.sh"; then
    echo "  ✗ behavioural check failed — stopping the bridge so the front door proxies to nothing" >&2
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    echo "    log: $LOG" >&2
    exit 1
  fi
  legacy_plugin_uninstall
  prune_builds "$root" "${PREV_ROOT:-}"
  note "↳ Front door is declared state, not this target: the tailnet binding is"
  note "  a row in dotfiles-private/tailscale-serve.mini.conf, applied by"
  note "  'make tailscale-serve'. URL: https://mini.<tailnet>.ts.net:8788"
  note "↳ The phone additionally needs an ACL grant (tag:phone → tcp:8788),"
  note "  applied from the MacBook only — see dotfiles-private's tailscale-acl.jsonc"
  note "  + 'make tailscale-acl-diff/push'."
}

cmd_status() {
  echo "  LaunchAgent ($LABEL):"
  local row pid status
  row=$(launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l {print $1" "$2}')
  if [ -z "$row" ]; then
    echo "    ✗ not loaded — run: make collie-setup"
  else
    read -r pid status <<< "$row"
    if [ "$pid" = "-" ]; then
      echo "    ✗ loaded but NOT running (last exit $status) — check $LOG"
    else
      echo "    ✓ loaded and running (pid $pid, last exit $status)"
    fi
  fi
  if loaded "$LEGACY_LABEL"; then
    echo "    ! legacy $LEGACY_LABEL is still loaded — run: make collie-setup"
  fi
  local root pinned
  root=$(installed_root)
  if [ -n "$root" ]; then
    pinned=$(cat "$root/.pinned-ref" 2>/dev/null || true)
    if [ -n "${COLLIE_REF:-}" ] && [ "$pinned" != "$COLLIE_REF" ]; then
      echo "    ✗ installed ${pinned:0:7}, Makefile pins ${COLLIE_REF:0:7} — run: make collie-setup"
    else
      echo "    ✓ installed build ${pinned:0:7} matches the pin"
    fi
  fi
  echo "  Behavioural check (http://127.0.0.1:$PORT):"
  COLLIE_PORT="$PORT" COLLIE_CHECK_WAIT_S=3 bash "$DOTFILES_DIR/scripts/collie-check.sh" || true
  echo "  tailscale serve:"
  local ts
  ts=$(bash -c "source '$DOTFILES_DIR/scripts/lib/tailscale-cli.sh'; echo \"\$TAILSCALE_BIN \${TAILSCALE_SOCKET:+--socket=\$TAILSCALE_SOCKET}\"" 2>/dev/null || true)
  # shellcheck disable=SC2086  # $ts is a command plus an optional flag, split on purpose
  if [ -n "$ts" ] && out=$($ts serve status 2>/dev/null); then
    printf '%s\n' "$out" | sed 's/^/    /'
  else
    echo "    · tailscale not reachable"
  fi
}

# The bridge gates every /api route behind a paired device (upstream ADR 0086), and the code is
# minted on the host's terminal on purpose. The compiled binary cannot find its checkout or the
# config dir by itself, so the plist's environment is repeated here.
cmd_pair() {
  local root
  root=$(installed_root)
  [ -n "$root" ] && [ -x "$root/bin/collie" ] || die "collie is not installed — run: make collie-setup"
  COLLIE_PLUGIN_ROOT="$root" HERDR_PLUGIN_CONFIG_DIR="$CONFIG_DIR" "$root/bin/collie" pair
}

# Deliberately NOT `collie uninstall`: that always attempts a tailscale serve teardown, even under
# COLLIE_SKIP_SERVE=1. Serve is declared state in this repo and no upstream script gets to mutate it.
cmd_teardown() {
  local l f
  for l in "$LABEL" "$LEGACY_LABEL"; do
    [ "$l" = "$LEGACY_LABEL" ] && [ "${COLLIE_LEGACY_MIGRATE:-1}" = "0" ] && continue
    f="$AGENT_DIR/$l.plist"
    if loaded "$l"; then
      launchctl bootout "$DOMAIN/$l" 2>/dev/null || true
      echo "  ✓ $l booted out"
    fi
    [ -f "$f" ] && { rm -f "$f"; echo "  ✓ $l plist removed"; }
  done
  [ "${COLLIE_LEGACY_MIGRATE:-1}" = "0" ] || legacy_plugin_uninstall
  rm -rf "$HOME_DIR"
  echo "  ✓ checkouts removed ($HOME_DIR)"
  echo "  · $CONFIG_DIR (.env) and the bridge's state dir (paired devices) left in place"
  echo "  · dotfiles-private/tailscale-serve.mini.conf left untouched — that is"
  echo "    declared state, not this target's to change."
}

case "${1:-}" in
  setup) cmd_setup ;;
  status) cmd_status ;;
  teardown) cmd_teardown ;;
  pair) cmd_pair ;;
  *) echo "usage: collie-setup.sh setup|status|teardown|pair" >&2; exit 2 ;;
esac
