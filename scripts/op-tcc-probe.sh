#!/usr/bin/env bash
set -u -o pipefail
# op-tcc-probe — acceptance check for "op in a Herdr terminal shows only the Touch ID prompt".
# docs/tcc.md §1Password. MacBook only (secrets backend `op`). A terminal program takes its holder's identity, so
# `op` in a Herdr terminal is judged as Herdr Core.app and the Full Disk Access grant on that bundle covers it. The
# probe re-runs itself in a fresh terminal (`hc run`), so it works from any shell:
#   make op-tcc-probe
# Run it again after `make herdr-core-update` (a new core build must keep the grant).
#
# One check = `op read <ref>` (desktop-app integration ON, biometric unlock untouched: no OP_* env switches),
# then the unified log is searched for a kTCCServiceSystemPolicyAppData prompt since the read started. PASS
# means the read worked and no AppData dialog was raised. "Exactly one Touch ID prompt" is the half only
# a human sees: approve it when it appears and say if anything else showed up.
#
# BASH 3.2.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKEND=$(tr -d '[:space:]' < "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null || echo "")
[ "$#" -eq 0 ] || { echo "usage: $(basename "$0")" >&2; exit 2; }

die() { echo "  ✗ $*" >&2; exit 1; }

[ "$BACKEND" = "op" ] || die "secrets backend is '${BACKEND:-unset}', not 'op': this probe is for the MacBook (the mini has no desktop app)"
if [ -z "${OP_TCC_PROBE_FRESH:-}" ]; then
  # never `hc` unless a launchd-born core answers: hc would auto-start a stray one
  bash "$DOTFILES_DIR/scripts/lib/core-up.sh" >/dev/null || die "no launchd-born core is up ($(bash "$DOTFILES_DIR/scripts/lib/core-up.sh")): not starting a core for a probe"
  q=$(printf '%q' "$DOTFILES_DIR/scripts/op-tcc-probe.sh")
  echo "  · re-running in a fresh core terminal (hc run)"
  # hc run starts in /, and the account is chosen from cwd: carry the caller's cwd and OP_PROBE_REF over
  qcwd=$(printf '%q' "$PWD")
  qref=""; [ -z "${OP_PROBE_REF:-}" ] || qref="OP_PROBE_REF=$(printf '%q' "$OP_PROBE_REF") "
  exec hc run --timeout 900 "cd $qcwd && env ${qref}OP_TCC_PROBE_FRESH=1 bash $q"
fi
[ -n "${HC_TERMINAL_ID:-}" ] || die "not in a core terminal (HC_TERMINAL_ID unset): run  make op-tcc-probe"
command -v op >/dev/null || die "op not on PATH"
# the account comes from the workspace helper, never a bare `op` call (config/zsh/secrets.zsh; it guards on an unset SSH_CONNECTION)
set +u; . "$DOTFILES_DIR/config/zsh/secrets.zsh"; set -u
# the probe must exercise desktop-app integration with biometric unlock, not a token or a switched-off integration
for v in OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_TOKEN OP_CONNECT_HOST OP_SESSION; do
  [ -z "${!v:-}" ] || die "$v is set: that bypasses the desktop-app handshake this probe exists to test (unset it)"
done
[ "${OP_LOAD_DESKTOP_APP_SETTINGS:-}" != "false" ] || die "OP_LOAD_DESKTOP_APP_SETTINGS=false is set: unset it, it is not the route on the MacBook"

ref_default() {
  # first real ref in the headless allowlist: names a secret, the value is discarded below
  grep -h -E '^op://' "$HOME/SourceRoot/dotfiles-private/headless.refs" 2>/dev/null | head -1 | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//'
}
REF="${OP_PROBE_REF:-$(ref_default)}"
[ -n "$REF" ] || die "no ref to read: set OP_PROBE_REF=op://vault/item/field (value is discarded)"

# one check: read, then look for an AppData prompt. Prints a PASS/FAIL line, returns 0/1.
check() {
  local label="$1" t0 rc=0 prompts logout errf
  t0=$(date +"%Y-%m-%d %H:%M:%S")
  echo "  · [$label] op_run read $REF  (approve the Touch ID prompt; anything else that appears is a FAIL)"
  errf=$(mktemp); op_run read "$REF" >/dev/null 2>"$errf" || rc=$?
  sleep 2   # tccd logs asynchronously
  local lrc=0
  logout=$(/usr/bin/log show --start "$t0" --predicate 'process == "tccd" AND eventMessage CONTAINS "AUTHREQ_PROMPTING"' --style compact 2>&1) || lrc=$?
  case "$logout" in
    *"Operation not permitted"*|*"Could not open"*)
      echo "  ✗ [$label] cannot read the unified log from here, so the probe is INCONCLUSIVE, not a failed grant: this terminal's holder predates the bundle or carries an inherited environment, or the account lacks log access. Measured 2026-11-13: the same probe passes from a terminal of a clean holder (0 AppData prompts, one Touch ID). Run it from a plain Terminal tab (docs/tcc.md)"; rm -f "$errf"; return 1 ;;
  esac
  if [ "$lrc" -ne 0 ] || ! printf '%s\n' "$logout" | grep -q '^Timestamp'; then
    echo "  ✗ [$label] the log query did not run cleanly (rc=$lrc): $(printf '%s' "$logout" | head -c 200)"; rm -f "$errf"; return 1
  fi
  prompts=$(printf '%s\n' "$logout" | grep -c 'kTCCServiceSystemPolicyAppData')
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ [$label] op read failed (rc=$rc): $(tr '\n' ' ' <"$errf" | cut -c1-200); AppData prompts: $prompts"; rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  if [ "$prompts" -gt 0 ]; then
    echo "  ✗ [$label] op read worked but macOS raised $prompts AppData prompt(s):"
    printf '%s\n' "$logout" | grep 'kTCCServiceSystemPolicyAppData' | sed -E 's/.*(AUTHREQ_PROMPTING.*responsible_path=[^,]*).*/      \1/' | head -3
    return 1
  fi
  echo "  ✓ [$label] op read ok, 0 AppData prompts since $t0"
}

check "this terminal" && { echo "  ✓ op-tcc-probe: PASS"; exit 0; }
echo "  ✗ op-tcc-probe: FAIL (docs/tcc.md §1Password)"
exit 1
