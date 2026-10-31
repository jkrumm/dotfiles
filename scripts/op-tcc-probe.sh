#!/usr/bin/env bash
set -u -o pipefail
# op-tcc-probe — acceptance check for "op in a Herdr terminal shows only the Touch ID prompt".
# docs/tcc.md §1Password. MacBook only (secrets backend `op`), and it must run INSIDE a core terminal:
#   hc run --timeout 900 'make op-tcc-probe'          # plain check
#   hc run --timeout 900 'make op-tcc-probe SWAP=1'   # also after a core swap
#
# One check = `op read <ref>` (desktop-app integration ON, biometric unlock untouched: no OP_* env switches),
# then the unified log is searched for a kTCCServiceSystemPolicyAppData prompt since the read started. PASS
# means the read worked and no AppData dialog was raised. "Exactly one Touch ID prompt" is the half only
# a human sees: approve it when it appears and say if anything else showed up.
#
# --swap: points the core at a differently signed copy of the same core (a stand-in for a core update),
# kickstarts it, and checks (1) from THIS terminal, which was born before the swap, and (2) from a terminal
# created after it. The original build is restored on exit.
#
# BASH 3.2.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKEND=$(tr -d '[:space:]' < "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null || echo "")
LABEL="com.jkrumm.herdr-core"
DOMAIN="gui/$(id -u)/$LABEL"
SWAP=0
ONLY_CHECK=""
for a in "$@"; do
  case "$a" in
    --swap) SWAP=1 ;;
    --check) ONLY_CHECK=1 ;;   # internal: the fresh-terminal leg
    *) echo "usage: $(basename "$0") [--swap]" >&2; exit 2 ;;
  esac
done

die() { echo "  ✗ $*" >&2; exit 1; }

[ "$BACKEND" = "op" ] || die "secrets backend is '${BACKEND:-unset}', not 'op': this probe is for the MacBook (the mini has no desktop app)"
[ -n "${HC_TERMINAL_ID:-}" ] || die "not in a core terminal (HC_TERMINAL_ID unset): run it as  hc run --timeout 900 'make op-tcc-probe'  or in a Herdr app terminal"
command -v op >/dev/null || die "op not on PATH"

ref_default() {
  # first real ref in the headless allowlist: names a secret, the value is discarded below
  grep -h -E '^op://' "$HOME/SourceRoot/dotfiles-private/headless.refs" 2>/dev/null | head -1 | awk '{print $1}'
}
REF="${OP_PROBE_REF:-$(ref_default)}"
[ -n "$REF" ] || die "no ref to read: set OP_PROBE_REF=op://vault/item/field (value is discarded)"

# one check: read, then look for an AppData prompt. Prints a PASS/FAIL line, returns 0/1.
check() {
  local label="$1" t0 rc=0 prompts logout errf
  t0=$(date +"%Y-%m-%d %H:%M:%S")
  echo "  · [$label] op read $REF  (approve the Touch ID prompt; anything else that appears is a FAIL)"
  errf=$(mktemp); op read "$REF" >/dev/null 2>"$errf" || rc=$?
  sleep 2   # tccd logs asynchronously
  logout=$(/usr/bin/log show --start "$t0" --predicate 'process == "tccd" AND eventMessage CONTAINS "AUTHREQ_PROMPTING"' --style compact 2>&1)
  case "$logout" in
    *"Operation not permitted"*|*"Could not open"*)
      echo "  ✗ [$label] cannot read the unified log from here (no Full Disk Access for this terminal): that alone says the launcher has no grant"; return 1 ;;
  esac
  rm -f "$errf"
  prompts=$(printf '%s\n' "$logout" | grep -c 'kTCCServiceSystemPolicyAppData')
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ [$label] op read failed (rc=$rc): $(tr '\n' ' ' <"$errf" | cut -c1-200); AppData prompts: $prompts"; return 1
  fi
  if [ "$prompts" -gt 0 ]; then
    echo "  ✗ [$label] op read worked but macOS raised $prompts AppData prompt(s):"
    printf '%s\n' "$logout" | grep 'kTCCServiceSystemPolicyAppData' | sed -E 's/.*(AUTHREQ_PROMPTING.*responsible_path=[^,]*).*/      \1/' | head -3
    return 1
  fi
  echo "  ✓ [$label] op read ok, 0 AppData prompts since $t0"
}

if [ -n "$ONLY_CHECK" ]; then check "fresh terminal after the swap"; exit $?; fi

fail=0
check "this terminal" || fail=1

if [ "$SWAP" = 1 ]; then
  OPT="$(brew --prefix)/opt/herdr-core"
  ORIG=$(readlink "$OPT") || die "$OPT is not a symlink (herdr-core not installed through brew?)"
  CELLAR_DIR="$(cd "$(dirname "$OPT")" && cd "$ORIG" && pwd -P)"
  COPY="${CELLAR_DIR}_swaptest"
  restore() {
    ln -sfn "$ORIG" "$OPT" && launchctl kickstart -k "$DOMAIN" >/dev/null 2>&1
    rm -rf "$COPY"
    echo "  · original core build restored"
  }
  trap restore EXIT
  rm -rf "$COPY"; mkdir -p "$COPY/bin"
  cp "$CELLAR_DIR/bin/herdr-core" "$COPY/bin/herdr-core" && ln -s herdr-core "$COPY/bin/hc" \
    && codesign -f -s - --identifier swapped.build "$COPY/bin/herdr-core" 2>/dev/null || die "could not stage the swapped build"
  old_pid=$(launchctl print "$DOMAIN" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)
  ln -sfn "$(dirname "$ORIG")/$(basename "$COPY")" "$OPT"
  [ "$(cd "$OPT" && pwd -P)" = "$(cd "$COPY" && pwd -P)" ] || die "could not repoint $OPT"
  launchctl kickstart -k "$DOMAIN" || die "kickstart failed"
  i=0; while :; do
    new_pid=$(launchctl print "$DOMAIN" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)
    [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && break
    i=$((i + 1)); [ "$i" -gt 30 ] && die "core job did not restart"; sleep 1
  done
  sleep 3
  core_cmd=$(ps -ww -o command= -p "$(hc server status --json | jq -r .pid)" 2>/dev/null)
  case "$core_cmd" in *_swaptest*) echo "  · core swapped: $(echo "$core_cmd" | cut -c1-110)" ;; *) die "core did not move to the swapped build: $core_cmd" ;; esac
  check "this terminal, born before the swap" || fail=1
  hc run --timeout 600 "$DOTFILES_DIR/scripts/op-tcc-probe.sh --check" || fail=1
fi

[ "$fail" = 0 ] && echo "  ✓ op-tcc-probe: PASS" || echo "  ✗ op-tcc-probe: FAIL (docs/tcc.md §1Password)"
exit "$fail"
