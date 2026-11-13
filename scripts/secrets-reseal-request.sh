#!/usr/bin/env bash
set +x
set -euo pipefail

# secrets-reseal-request — the ONE way an agent on the mini asks the owner for a
# secrets reseal. Replaces hand-written `ask-human.sh ask 'reseal the secrets cache'
# --cmd 'make secrets-seed'`, which raised a full biometric reseal every time anyone
# noticed a missing ref (105 requests in the human-queue history, 5 Errands on
# 2026-11-13 alone).
#
# What it does differently:
#   - it looks first. The missing-ref set is the refs in dotfiles-private's
#     headless.refs / headless.iu.refs that the sealed cache has no key for. Keys are
#     plaintext in SOPS-JSON (only values are encrypted), so this needs no decrypt, no
#     age key and no 1Password — it is safe to call from any agent on the mini.
#   - empty set → nothing is raised (and an open request for an earlier set is cleared).
#   - one request per set: the key is a hash of the sorted missing refs, so asking again
#     for the same set while it is open is a no-op, and a changed set replaces the old
#     request instead of stacking beside it.
#   - the request names the exact refs and the account(s) that must be signed in, and
#     runs the INCREMENTAL path (`make secrets-seed-new`): one new ref = one `op` read,
#     one biometric pass, every other value kept.
#   - its Errand carries a `--check` (`needed`) that stays true only while a ref is
#     still missing, so the request closes itself once the cache has the ref — however
#     that happened.
#
# Usage:
#   scripts/secrets-reseal-request.sh [request]   raise the request if refs are missing
#   scripts/secrets-reseal-request.sh status      list the missing refs (exit 0 = none, 1 = some)
#   scripts/secrets-reseal-request.sh needed      the Errand check: exit 0 while refs are missing
#
# Refs are not secret (they name vault/item/field), so printing them is fine; values
# are never read here.

SECRETS_PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
CACHE_FILE="$SECRETS_PRIVATE_REPO/cache/secrets.enc.json"
REFS_FILE="$SECRETS_PRIVATE_REPO/headless.refs"
IU_REFS_FILE="$SECRETS_PRIVATE_REPO/headless.iu.refs"
IU_ACCOUNT="careerpartner"   # keys namespaced `careerpartner|<ref>`; tkrumm keys are bare (secrets-seed.sh cache_key)
STATE_DIR="${SECRETS_RESEAL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/secrets-reseal}"
LAST_KEY_FILE="$STATE_DIR/last-key"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASK_HUMAN="${SECRETS_RESEAL_ASK_HUMAN:-$HERE/ask-human.sh}"
# The check runs later on the mini from the factory, not from this checkout (a worktree
# may be gone by then): name the canonical copy.
CHECK_SCRIPT="${SECRETS_RESEAL_CHECK_SCRIPT:-\$HOME/SourceRoot/dotfiles/scripts/secrets-reseal-request.sh}"

# The factory runs `needed` as the Errand's check with whatever PATH it has; exit codes 1..125
# there mean "no longer needed" and CLOSE the request. So in that mode a setup problem (no jq,
# no refs file, any unexpected failure) must read as "still needed" (exit 0): the only
# answer this script may give in `needed` mode is a deliberate 0 or 1.
case ":$PATH:" in *":/opt/homebrew/bin:"*) : ;; *) PATH="/opt/homebrew/bin:$PATH" ;; esac
export PATH
if [[ "${1:-}" == needed ]]; then set -E; trap 'exit 0' ERR; fi

if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq not installed" >&2
  [[ "${1:-}" == needed ]] && exit 0
  exit 2
fi
if [[ ! -f "$REFS_FILE" ]]; then
  echo "✗ no headless.refs at $REFS_FILE" >&2
  [[ "${1:-}" == needed ]] && exit 0
  exit 2
fi

# --- the missing set ---------------------------------------------------------
# MISSING[i] / MISSING_ACCT[i] stay index-aligned.
MISSING=()
MISSING_ACCT=()

collect() {  # $1=file  $2=account  $3=key prefix ("" or "acct|") — expected keys onto EXPECTED
  local file="$1" prefix="$3" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* || "$line" != op://* ]] && continue
    EXPECTED+="${prefix}${line}"$'\n'
  done < "$file"
}

CACHE_KEYS=""
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_KEYS="$(jq -r 'keys[]' "$CACHE_FILE" 2>/dev/null || true)"
fi
EXPECTED=""
collect "$REFS_FILE" tkrumm ""
[[ -f "$IU_REFS_FILE" ]] && collect "$IU_REFS_FILE" "$IU_ACCOUNT" "$IU_ACCOUNT|"
# One grep, not one per ref: the lists are a few hundred refs long.
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if [[ "$key" == "$IU_ACCOUNT|"* ]]; then
    MISSING+=("${key#"$IU_ACCOUNT|"}"); MISSING_ACCT+=("$IU_ACCOUNT")
  else
    MISSING+=("$key"); MISSING_ACCT+=(tkrumm)
  fi
done < <(printf '%s' "$EXPECTED" | awk '!seen[$0]++' | grep -vxF -f <(printf '%s\n' "$CACHE_KEYS") || true)

missing_set_id() {  # stable id of the SORTED missing set (account + ref)
  local i
  for ((i = 0; i < ${#MISSING[@]}; i++)); do printf '%s %s\n' "${MISSING_ACCT[$i]}" "${MISSING[$i]}"; done \
    | LC_ALL=C sort | shasum -a 256 | cut -c1-10
}

print_missing() {
  local i
  for ((i = 0; i < ${#MISSING[@]}; i++)); do
    printf '  %s  (account %s)\n' "${MISSING[$i]}" "${MISSING_ACCT[$i]}"
  done
}

# --- subcommands -------------------------------------------------------------
cmd_status() {
  if ((${#MISSING[@]} == 0)); then
    echo "the cache holds every ref in the lists"
    return 0
  fi
  echo "${#MISSING[@]} ref(s) missing from the cache:"
  print_missing
  return 1
}

cmd_needed() {
  if ((${#MISSING[@]} > 0)); then exit 0; fi
  exit 1
}

cmd_request() {
  mkdir -p "$STATE_DIR"
  local last=""
  [[ -f "$LAST_KEY_FILE" ]] && last="$(cat "$LAST_KEY_FILE")"

  if ((${#MISSING[@]} == 0)); then
    # Whatever we asked for is in the cache now: close the request, once.
    if [[ -n "$last" ]]; then
      "$ASK_HUMAN" clear "$last" --note "the cache holds every ref in the lists" >/dev/null 2>&1 || true
      rm -f "$LAST_KEY_FILE"
    fi
    echo "nothing to request — the cache holds every ref in the lists"
    return 0
  fi

  local key
  key="secrets-reseal-$(missing_set_id)"

  # One request per set: still open under this key → say so and stop. (list --json is
  # the same probe gate-pin-notice.sh uses.)
  if "$ASK_HUMAN" list --json 2>/dev/null | grep -q "\"key\":\"$key\""; then
    echo "already requested (key $key): ${#MISSING[@]} missing ref(s)"
    print_missing
    return 0
  fi
  # A different set replaces the old request rather than sitting beside it.
  if [[ -n "$last" && "$last" != "$key" ]]; then
    "$ASK_HUMAN" clear "$last" --as superseded --note "the missing-ref set changed" >/dev/null 2>&1 || true
  fi

  # A ref committed on the mini and not pushed is invisible to the MacBook's seed.
  if [[ -d "$SECRETS_PRIVATE_REPO/.git" ]] \
     && [[ "$(git -C "$SECRETS_PRIVATE_REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != 0 ]]; then
    echo "! $SECRETS_PRIVATE_REPO has unpushed commits — the MacBook seals from its own checkout; push first" >&2
  fi

  local n="${#MISSING[@]}" what text i accts="" a
  if ((n == 1)); then what="1 new ref"; else what="$n new refs"; fi
  for a in tkrumm "$IU_ACCOUNT"; do
    for ((i = 0; i < n; i++)); do
      [[ "${MISSING_ACCT[$i]}" == "$a" ]] && { accts+="${accts:+, }$a"; break; }
    done
  done
  text="Secrets cache: $what missing from the mini's cache. Runs the incremental seal — it reads ONLY these refs (one biometric pass) and keeps every other value."
  text+=$'\n'"Missing:"
  for ((i = 0; i < n; i++)); do text+=$'\n'"  ${MISSING[$i]}  (account ${MISSING_ACCT[$i]})"; done
  text+=$'\n'"1Password must be signed in on the MacBook for: $accts. If an account is unreachable the seal still delivers the reachable ones and names the one to sign in."

  # What runs on the MacBook. The seal reads the refs from the MacBook's OWN checkout of
  # dotfiles-private, so it is pulled first — over the 1Password ssh agent (a non-login
  # context has none of its own: the first live request died on "Permission denied
  # (publickey)", 2026-11-13). A failed pull is not fatal by itself; what is fatal is a
  # checkout that still lacks a missing ref, because the seal would then read nothing and
  # report success (the 2026-09-07 failure). Each missing ref is asserted before sealing.
  local cmd guard="" listfile qref
  # shellcheck disable=SC2016  # $HOME must expand on the MacBook, not here
  cmd='export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"; '
  cmd+="git -C ~/SourceRoot/dotfiles-private pull --ff-only || echo '! pull failed — sealing from the checkout as it is'; "
  for ((i = 0; i < n; i++)); do
    listfile=headless.refs
    [[ "${MISSING_ACCT[$i]}" == "$IU_ACCOUNT" ]] && listfile=headless.iu.refs
    printf -v qref '%q' "${MISSING[$i]}"
    guard+="sed 's/^[[:space:]]*//;s/[[:space:]]*\$//' ~/SourceRoot/dotfiles-private/$listfile | grep -qxF -- $qref || { echo \"✗ \"$qref\" is not in this Mac's dotfiles-private checkout (pull failed?) — nothing sealed\"; exit 1; }; "
  done
  cmd+="$guard"
  cmd+="cd ~/SourceRoot/dotfiles && hc run --timeout 900 'make secrets-seed-new'"
  "$ASK_HUMAN" ask "$text" --cmd "$cmd" --key "$key" --check "bash \"$CHECK_SCRIPT\" needed" || true
  printf '%s\n' "$key" > "$LAST_KEY_FILE"
  echo "requested $what (key $key)"
}

case "${1:-request}" in
  request) cmd_request ;;
  status) cmd_status ;;
  needed) cmd_needed ;;
  -h|--help|help) sed -n '3,36p' "${BASH_SOURCE[0]}" ;;
  *) echo "usage: secrets-reseal-request.sh [request|status|needed]" >&2; exit 2 ;;
esac
