#!/usr/bin/env bash
set -euo pipefail

# gate-pin-notice — the IuRoot deploy gate (epos-tool-athena `deploy-gate/`)
# pins the release-dialog helper by sha256: ask-human.sh, every script it names
# (human-queue.sh, lib/human-queue-json.sh) and the notify hook. A change to any
# of them silences the gate's release dialog and turns `make verify` red in every
# gated repo until the OWNER re-pins. The re-pin stays owner-only; this script
# only makes sure the owner is told, once, with the exact command.
#
# Run at the end of `make deploy` on the mini. Reads the pin list from the
# installed gate's config.json (`ask_human_pins`: realpath -> sha256). If that is
# unreadable it falls back to FALLBACK_PINS below (a test checks it against the
# live config) and compares against the shas seen at the previous run.
#
#   drift (a pinned file's sha256 differs from its pin) -> one human-queue item,
#     key `gate-pin`, no expiry; a newer drift replaces it (same key supersedes).
#   drift unchanged since the last notice -> nothing (no nag per deploy).
#   no drift (the owner re-pinned, or nothing pinned changed) -> clear the item.
#
# Env (tests): DOTFILES_DIR, GATE_PIN_CONFIG, GATE_PIN_STATE, ASK_HUMAN.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$HERE/.." && pwd)}"
CONFIG="${GATE_PIN_CONFIG:-$HOME/.local/libexec/prometheus-deploy-gate/config.json}"
STATE="${GATE_PIN_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/gate-pin-seen}"
ASK_HUMAN="${ASK_HUMAN:-$HERE/ask-human.sh}"
KEY="gate-pin"
SCAN_COMMITS=60
REPIN_CMD="ssh mini 'cd ~/IuRoot/epos-tool-athena && git pull --ff-only && make deploy-gate-install'"

# Used only when the installed gate's config is unreadable. Keep in step with
# deploy-gate/install.sh (the helper, the *.sh it names beside it or in lib/,
# the notify hook); gate-pin-notice.test.sh compares it with the live config.
FALLBACK_PINS=(
  scripts/ask-human.sh
  scripts/human-queue.sh
  scripts/lib/human-queue-json.sh
  scripts/human-queue-notify-hook.sh
)

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Lines "<abs path> <pinned sha256 | ->" for every pinned file.
read_pins() {
  local f
  if [[ -r "$CONFIG" ]] && command -v python3 >/dev/null 2>&1; then
    if python3 -I - "$CONFIG" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1])).get("ask_human_pins") or {}
if not pins:
    sys.exit(3)
for path, sha in pins.items():
    print(path, sha)
PY
    then return 0; fi
  fi
  for f in "${FALLBACK_PINS[@]}"; do printf '%s -\n' "$DOTFILES_DIR/$f"; done
}

# Commit in DOTFILES_DIR whose version of <abs path> hashes to <sha>, or empty.
commit_of_pin() {
  local abs="$1" want="$2" rel c
  rel="${abs#"$DOTFILES_DIR"/}"
  [[ "$rel" != "$abs" ]] || return 0
  while read -r c; do
    [[ -n "$c" ]] || continue
    if [[ "$(git -C "$DOTFILES_DIR" show "$c:$rel" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" == "$want" ]]; then
      printf '%s' "$c"; return 0
    fi
  done < <(git -C "$DOTFILES_DIR" log -n "$SCAN_COMMITS" --format=%H -- "$rel" 2>/dev/null)
}

mkdir -p "$(dirname "$STATE")"
head_sha="$(git -C "$DOTFILES_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

declare -a drifted=() ranges=() now_lines=()
fallback=0
while read -r path pinned; do
  [[ -n "$path" ]] || continue
  [[ -f "$path" ]] || { drifted+=("$path"); ranges+=("$path: missing"); now_lines+=("$path missing"); continue; }
  cur="$(sha_of "$path")"
  now_lines+=("$path $cur")
  if [[ "$pinned" == "-" ]]; then
    fallback=1
    prev="$(awk -v p="$path" '$1==p {print $2" "$3}' "$STATE" 2>/dev/null || true)"
    [[ -n "$prev" ]] || continue            # first run: baseline only
    [[ "${prev%% *}" != "$cur" ]] || continue
    drifted+=("$path"); ranges+=("$path: ${prev##* }..$head_sha")
  else
    [[ "$cur" != "$pinned" ]] || continue
    drifted+=("$path")
    from="$(commit_of_pin "$path" "$pinned")"
    if [[ -n "$from" ]]; then
      ranges+=("$path: $from..$head_sha")
    else
      ranges+=("$path: pinned content not found in the last $SCAN_COMMITS commits (pin ${pinned:0:12}, now ${cur:0:12})")
    fi
  fi
done < <(read_pins)

# Fallback mode: remember what this run saw (and at which commit) for the next.
if (( fallback )); then
  for l in "${now_lines[@]}"; do printf '%s %s\n' "$l" "$head_sha"; done > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
fi

if (( ${#drifted[@]} == 0 )); then
  # Only the real pins say the owner re-pinned; the fallback cannot, so its item ages out instead.
  (( fallback )) || "$ASK_HUMAN" clear "$KEY" --note "the gate's pinned files match their pins" >/dev/null 2>&1 || true
  echo "    ✓ deploy gate pins hold (no pinned file changed)"
  exit 0
fi

# Signature of this drift: unchanged drift is not re-announced on every deploy.
sig="$(printf '%s\n' "${now_lines[@]}" | shasum -a 256 | cut -d' ' -f1)"
SIGFILE="$STATE.notified"
if [[ "$(cat "$SIGFILE" 2>/dev/null || true)" == "$sig" ]] \
   && "$ASK_HUMAN" list --json 2>/dev/null | grep -q "\"key\":\"$KEY\""; then
  echo "    · deploy gate re-pin already requested (${#drifted[@]} pinned file(s) changed)"
  exit 0
fi

text="Deploy gate pin drift: dotfiles changed a file the IuRoot deploy gate pins, so its release dialog is silently off and make verify is red in the gated repos until you re-pin. Changed (pin commit..now):"
for r in "${ranges[@]}"; do text+=$'\n'"  $r"; done
text+=$'\n'"Review the diff, then re-pin from your epos-tool-athena clone on the mini: $REPIN_CMD"

expires=never; (( fallback )) && expires=7d
"$ASK_HUMAN" ask "$text" --cmd "$REPIN_CMD" --key "$KEY" --expires "$expires" >/dev/null
printf '%s' "$sig" > "$SIGFILE"
echo "    ! deploy gate pin drift: re-pin requested via human-queue (key $KEY)"
