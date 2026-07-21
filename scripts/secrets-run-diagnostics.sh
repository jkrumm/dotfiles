#!/usr/bin/env bash
# secrets-run-diagnostics.sh — error-path remediation wording for `secrets-run`.
#
# SOURCED, never executed, and ONLY from the miss path (see load_diagnostics() in
# secrets-run). The happy path — decrypt, look up, inject — never touches this file,
# which is the point of the split: the sole secret path stays the smallest thing a
# reader has to trust, and this "which account holds it / what should I type" logic
# can be read and tested on its own.
#
# TRUST: sourced into secrets-run's own shell, so at runtime it is exactly as
# privileged as the shim. That is acceptable only because it is loaded from the
# shim's REAL directory (symlinks resolved) — write access there already implies
# control of secrets-run itself, so this adds no new surface. It must never be
# loaded from a symlink's directory (e.g. ~/.local/bin), which is a different
# trust domain.
#
# Depends on secrets-run for: die(), normalize_account(), DEFAULT_OP_ACCOUNT,
# OP_ACCOUNT, CACHE_REFS[]. Defines no state of its own beyond MISSING_REFS_SHOWN.
# Rationale + the three parser bugs this logic went through: design.md D15.

# Which ref-list a missing ref belongs in — the two accounts seed from different
# files (and under different Private-vault policies), so a "reseed" hint that names
# the wrong file sends the reader to edit a list that can never satisfy them.
refs_file_hint() {
  local acct
  acct=$(normalize_account "$OP_ACCOUNT")
  if [[ "$acct" == "$DEFAULT_OP_ACCOUNT" ]]; then
    printf 'headless.refs'
  else
    printf 'headless.iu.refs'
  fi
}

# Accounts (other than the current one) whose cache namespace holds $1.
#
# Exists because the "add to <list> and reseed" hint is actively WRONG when the ref
# is already seeded under the other account: it sends the reader to re-seal a cache
# that already has what they need, when the real fix is one environment variable.
# That misdiagnosis cost a full day on 2026-07-20.
#
# Reads key PRESENCE only, never values — and discloses nothing that headless.refs /
# headless.iu.refs don't already state in plaintext, so it does not weaken the
# per-account namespace boundary (see docs/security-review.md).
# Matches by INVERTING cache_key()'s construction, never by splitting on the first
# '|'. A vault/item/field name may itself contain a pipe (1Password does not forbid
# it) and bare keys are the raw ref, so "first '|' separates account from ref" is
# wrong: it would read the bare key `op://vault|item/field` as account `op://vault`.
# Instead: a bare key must equal the ref exactly, and a namespaced key must end with
# "|<ref>" whose remaining prefix is pipe-free (normalize_account forbids '|' in an
# account, so a prefix containing one means this key belongs to some *other* ref that
# merely shares the suffix). A namespaced key can never be mistaken for a bare one —
# refs are validated to start with `op://`, which no `<account>|…` key does.
accounts_holding_ref() {  # $1=ref → prints matching account names, one per line
  local ref="$1" cur key acct i
  cur=$(normalize_account "$OP_ACCOUNT")
  for ((i = 0; i < ${#CACHE_REFS[@]}; i++)); do
    key="${CACHE_REFS[$i]}"
    if [[ "$key" == "$ref" ]]; then
      acct="$DEFAULT_OP_ACCOUNT"          # bare key = the default account's namespace
    elif [[ "$key" == *"|$ref" ]]; then
      acct="${key%"|$ref"}"
      # CROSS-FILE INVARIANT: this guard assumes every BARE cache key is a literal
      # `op://…` ref — that is what makes a ref-fragment prefix always contain '://'.
      # The invariant is enforced in secrets-seed.sh (which seals the keys) and by
      # verb_read/parse_tpl (which validate refs), NOT here. If seed's key generation
      # ever seals a bare key that is not an op:// ref, this silently reopens.
      # The prefix must be a PLAUSIBLE ACCOUNT, or this is a suffix collision rather
      # than a namespaced key. Two ways it can lie, both reproduced in review:
      #   `A|<ref-containing-|>` whose tail matches         → prefix keeps a '|'
      #   a BARE ref that merely ends with "|<ref>"         → prefix is a ref fragment
      # The second is the dangerous one: it would name a bogus account whose cache_key()
      # reconstructs the bare key exactly, so following the advice returns an unrelated
      # secret. Refs always begin `op://`, so a ref-fragment prefix always carries '://';
      # a real account identifier (`tkrumm`, `careerpartner.1password.com`) never does.
      case "$acct" in
        *'|'* | *'/'* | *':'* | '') continue ;;
      esac
    else
      continue
    fi
    [[ "$acct" == "$cur" ]] && continue
    printf '%s\n' "$acct"
  done | sort -u
}

# The one other account that holds EVERY given ref, if there is exactly one (the
# whole-template case). Empty otherwise — a half-match means a real gap too, so the
# caller must fall back to the safe reseed advice rather than the cross-account fix.
# INTERSECTS the per-ref holder sets rather than demanding each ref have exactly one
# holder. A ref can legitimately live under two accounts (op://Private/collide/token
# really does exist in both), and an early "more than one holder → give up" made the
# whole template fall back to the known-wrong reseed advice even when one account did
# hold every missing ref. Both lists are `sort -u`-ed, so `comm -12` is well-defined.
common_other_account() {  # $@=refs → prints the account, or nothing
  local ref accts common="" first=1
  (($# > 0)) || return 0
  for ref in "$@"; do
    accts=$(accounts_holding_ref "$ref")
    [[ -n "$accts" ]] || return 0        # a ref nobody else holds → a real gap
    if ((first)); then
      common="$accts"; first=0
    else
      common=$(comm -12 <(printf '%s\n' "$common") <(printf '%s\n' "$accts"))
    fi
    [[ -n "$common" ]] || return 0       # holders disagree → no single answer
  done
  [[ "$common" == *$'\n'* ]] && return 0  # still ambiguous → stay safe
  printf '%s' "$common"
}

# The one place the cross-account remediation is worded — both the `read` path and the
# template path render it from here, so they cannot drift apart.
cross_account_advice() {  # $1=account holding the refs → prints the advice sentence
  # The account is SHELL-QUOTED in the remediation. It is derived from cache-key text,
  # and normalize_account still permits spaces — so an unquoted `OP_ACCOUNT=foo bar
  # secrets-run …` would, on copy-paste, set OP_ACCOUNT=foo and try to run `bar`.
  # This string is advice a human is invited to paste; it must be paste-safe.
  local quoted
  quoted=$(printf '%q' "$1")
  printf 'already seeded under account '\''%s'\'', not '\''%s'\'' — re-run with: OP_ACCOUNT=%s secrets-run …  (no reseed needed)' \
    "$1" "$(normalize_account "$OP_ACCOUNT")" "$quoted"
}

# Likewise the reseed remediation, for the genuinely-absent case.
reseed_advice() {
  printf 'add to %s and reseed: make secrets-seed' "$(refs_file_hint)"
}

# The remediation clause for a set of missing refs. Kept as a trailing clause for the
# single-ref `read` path, where the ref list is one item and cannot bury the advice.
# THE branch: cross-account fix, or reseed. Both call sites drive from this one
# decision — they differ only in the shape of the sentence they wrap it in, and having
# each re-derive the branch is exactly how the two paths drift apart.
# Sets globals rather than printing, because the caller needs to know WHICH branch was
# taken, and a `$(...)` capture would run this in a subshell and lose it.
DIAG_ADVICE=""
DIAG_BRANCH=""
# shellcheck disable=SC2034  # DIAG_BRANCH is read by resolve_from_cache() in secrets-run,
# which sources this file — shellcheck cannot see across the source boundary.
compute_missing_advice() {  # $@=refs → sets DIAG_ADVICE + DIAG_BRANCH (cross|reseed)
  local common
  common=$(common_other_account "$@")
  if [[ -n "$common" ]]; then
    DIAG_BRANCH="cross"; DIAG_ADVICE=$(cross_account_advice "$common")
  else
    DIAG_BRANCH="reseed"; DIAG_ADVICE=$(reseed_advice)
  fi
}

missing_refs_hint() {  # $@=refs → prints the trailing " — <advice>" clause
  compute_missing_advice "$@"
  printf ' — %s' "$DIAG_ADVICE"
}

# How many missing refs to name before eliding. A whole-template miss is routinely
# 60+ refs; naming them all pushes the one actionable sentence past where anyone reads
# (the 2026-07-20 message ran 4768 chars with the fix at the very end).
MISSING_REFS_SHOWN=8

# Print at most MISSING_REFS_SHOWN of "$@", eliding the remainder.
format_missing_list() {  # $@=display strings
  local shown=$(($# < MISSING_REFS_SHOWN ? $# : MISSING_REFS_SHOWN))
  printf '%s' "${*:1:$shown}"
  (($# > shown)) && printf ' … (+%d more)' "$(($# - shown))"
  return 0
}

