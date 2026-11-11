# shellcheck shell=bash
# claude-auth-check — check_claude_auth for devhost-health-check.sh.
#
# Sourceable, no side effects on load, bash 3.2 (launchd hands the heartbeat
# Apple's /bin/bash). Reads these globals, set by the caller (the heartbeat sets
# them, the test overrides them): SECRETS_RUN_BIN, CLAUDE_BIN, JQ_BIN,
# CLAUDE_ACCOUNT_BIN, CLAUDE_ACCOUNTS_REGISTRY, plus USER, HOME and PATH.
# Calls /usr/bin/id. scripts/devhost-login-expiry.test.sh drives it hermetically.

# claude_bounded <secs> <cmd> [args…] — run one probe under its own deadline, in its own process group.
# A probe that outlives it is killed (group KILL, so a helper it spawned and that holds the capture pipe dies too),
# the process table of its group is written to stderr first (the local heartbeat log: a repeat is attributable
# without a repro), and the exit status is 124. Why per probe: issue 840 — `claude auth status` answers in 0.1 s by
# hand, yet some heartbeat runs spent the component's whole 100 s on one hung call and paged the composite DOWN.
# A hang is "no verdict", not "logged out", and one hung probe must not take the other probes' verdicts with it.
# perl, because macOS ships no timeout(1) and the bash 3.2 poll loop of run_bounded needs a file for its capture.
claude_bounded() {
  local secs="$1"
  shift
  /usr/bin/perl -e '
    my $s = shift; my $pid = fork; defined $pid or exit 125;
    if (!$pid) { setpgrp(0, 0); open STDERR, ">/dev/null"; exec @ARGV; exit 127 }
    $SIG{ALRM} = sub {
      system("/bin/ps -axo pgid,pid,ppid,stat,etime,wchan,command | /usr/bin/awk \x27\$1 == $pid\x27 1>&2");
      kill "KILL", -$pid; waitpid $pid, 0; exit 124;
    };
    alarm $s; waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$secs" "$@"
}
CLAUDE_PROBE_TIMEOUT="${CLAUDE_PROBE_TIMEOUT:-20}"

# Run `claude auth status` for one account (id "iu" = the default: CLAUDE_CONFIG_DIR unset) under the probe bound.
# Prints the JSON on stdout. rc 0 answered (possibly empty), rc 124 hung. Probes slower than 5 s are logged.
claude_auth_probe() {
  local id="$1" dir="$2" out rc=0 t0=$SECONDS
  if [[ -n "$dir" ]]; then
    out=$(claude_bounded "$CLAUDE_PROBE_TIMEOUT" env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      CLAUDE_CONFIG_DIR="$dir" USER="${USER:-$(/usr/bin/id -un)}" "$CLAUDE_BIN" auth status) || rc=$?
  else
    out=$(claude_bounded "$CLAUDE_PROBE_TIMEOUT" env USER="${USER:-$(/usr/bin/id -un)}" "$CLAUDE_BIN" auth status) || rc=$?
  fi
  (( SECONDS - t0 >= 5 )) && echo "claude auth probe $id took $(( SECONDS - t0 ))s (rc=$rc)" >&2
  [[ "$rc" == 124 ]] && return 124
  printf '%s' "$out"
  return 0
}

claude_token_works() {
  local tok tout
  [[ -x "$SECRETS_RUN_BIN" ]] || return 1
  tok=$(claude_bounded "$CLAUDE_PROBE_TIMEOUT" "$SECRETS_RUN_BIN" read op://mini/claude/oauth-token) || return 1
  [[ -n "$tok" ]] || return 1
  tout=$(claude_bounded "$CLAUDE_PROBE_TIMEOUT" env CLAUDE_CODE_OAUTH_TOKEN="$tok" USER="${USER:-$(/usr/bin/id -un)}" \
    "$CLAUDE_BIN" auth status) || return 1
  [[ "$("$JQ_BIN" -r '.loggedIn // false' <<<"$tout" 2>/dev/null)" == "true" ]]
}

# The default account (iu, CLAUDE_CONFIG_DIR unset): dead = FAIL. Every other enabled account is
# graded by check_claude_auth below.
check_claude_auth_iu() {
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
  local out logged sub prc=0
  out=$(claude_auth_probe iu "") || prc=$?
  # A hung probe is no verdict, not a dead login: WARN (named, never pages). A dead login answers; it does not hang.
  (( prc == 124 )) && { echo "claude auth status for iu hung (>${CLAUDE_PROBE_TIMEOUT}s, killed) — no verdict"; return 2; }
  [[ -n "$out" ]] || { echo "claude auth status returned nothing — agents may be billing API credits"; return 1; }
  logged=$("$JQ_BIN" -r '.loggedIn // false' <<<"$out" 2>/dev/null) || logged=""
  sub=$("$JQ_BIN" -r '.subscriptionType // "none"' <<<"$out" 2>/dev/null) || sub=""

  # TWO CREDENTIALS, TWO PATHS — and the bare binary above can only see one of
  # them. `config/zsh/claude-auth.zsh` falls back to CLAUDE_CODE_OAUTH_TOKEN from
  # the secrets cache, so a host with a dead keychain but a live token runs every
  # core terminal and `claude --bg` daemon perfectly on Max. Reporting that as "every
  # agent on this host is billing API credits" — as this did — is false, and a
  # component that overstates is one you learn to skim past.
  #
  # So probe the fallback too, and grade the three states differently:
  #   keychain ok                → ok
  #   keychain dead, token works → DEGRADED, and say what to do (a `/login` in a
  #                                core terminal restores a self-refreshing
  #                                credential; the token is a 1-year static one
  #                                with no refresh and no reliable revocation)
  #   neither                    → the real "billing API credits" alert

  if [[ "$logged" != "true" ]]; then
    if claude_token_works; then
      # PASSES, deliberately. Max billing is intact, every core terminal and `claude --bg`
      # daemon works, and the only cost is a worse CREDENTIAL — static 1y, no
      # refresh, no reliable revocation — not a broken host. Failing here would
      # put the composite monitor red indefinitely for a state that has been
      # accepted, and this repo has already learned what that does: the
      # 1Password backup monitor "had spent large stretches red as a nag, which
      # is how you train yourself to ignore it".
      #
      # The condition is still NAMED in the push msg on every run, so it is
      # visible without being an alarm, and the real failure is not softened:
      # when the token stops working the branch below fails loudly. That is also
      # what covers the one-year cliff — no separate expiry monitor needed.
      echo "claude on the cached oauth token (Max ok; keychain login gone — restore with /login in a core terminal, static 1y otherwise)"
      return 0
    fi
    echo "claude NOT logged in and the cached oauth token does not work either — every agent on this host is billing API credits (fix: /login in a core terminal, or claude setup-token; needs a human)"
    return 1
  fi

  [[ "$sub" == "max" ]] \
    || { echo "claude auth is '${sub:-unknown}', not max — agents are off the subscription"; return 1; }
  echo "claude auth ok (max)"
}

# iu dead = FAIL (as before). Any other enabled account dead = WARN: the picker routes around it, and
# its login never has a token fallback (claude-auth.zsh), so the fix is `/login` in a core terminal.
# Login expiry (the 30-day refresh token) is graded after the liveness checks, see the end of the function.
check_claude_auth() {
  local iu_msg iu_rc=0 accts id dir out dead="" ok="" hung="" worst msg prc
  iu_msg=$(check_claude_auth_iu) || iu_rc=$?
  worst=$iu_rc   # the other accounts are checked whatever iu's grade: the worst grade wins (1 FAIL > 2 WARN > 0)
  [[ -x "$CLAUDE_BIN" ]] || { echo "$iu_msg"; return "$iu_rc"; }   # no CLI: check_claude_auth_iu already skipped
  # An unreadable registry means the other accounts went unchecked: say so, never a silent green.
  [[ -r "$CLAUDE_ACCOUNTS_REGISTRY" ]] \
    || { echo "$iu_msg; account registry unreadable ($CLAUDE_ACCOUNTS_REGISTRY) — other accounts unchecked"; (( iu_rc == 1 )) && return 1; return 2; }
  accts=$("$JQ_BIN" -r '.accounts | to_entries[] | select(.value.enabled and .value.dir != null) | "\(.key)\t\(.value.dir)"' "$CLAUDE_ACCOUNTS_REGISTRY" 2>/dev/null) \
    || { echo "$iu_msg; account registry unparsable ($CLAUDE_ACCOUNTS_REGISTRY) — other accounts unchecked"; (( iu_rc == 1 )) && return 1; return 2; }
  while IFS=$'\t' read -r id dir; do
    [[ -n "$id" ]] || continue
    dir="${dir/#\~/$HOME}"
    prc=0
    out=$(claude_auth_probe "$id" "$dir") || prc=$?
    if (( prc == 124 )); then hung+=" $id"; continue; fi
    if [[ "$("$JQ_BIN" -r '.loggedIn // false' <<<"$out" 2>/dev/null)" == "true" ]]; then ok+=" $id"; else dead+=" $id"; fi
  done <<<"$accts"
  msg="$iu_msg"
  if [[ -n "$dead" ]]; then
    msg="$msg; account${dead} NOT logged in — picker routes around it (fix: claude-relogin <id>, or /login in a core terminal with CLAUDE_CONFIG_DIR set)"
    (( worst == 0 )) && worst=2
  elif [[ -n "$ok" ]]; then
    msg="$msg; also${ok}"
  fi
  if [[ -n "$hung" ]]; then
    msg="$msg; claude auth status hung (>${CLAUDE_PROBE_TIMEOUT}s, killed) for${hung} — no verdict"
    (( worst == 0 )) && worst=2
  fi
  # Login expiry: the refresh token ends 30 days after the login (claude-account expiry). Anything but PASS is a WARN
  # (never pages): inside 7 days, an unreadable item, or a check that could not run. It never raises past what
  # check_claude_auth_iu decided: an expired default login is a FAIL only where that policy fails too (keychain dead AND
  # the cached oauth token dead); "keychain dead, cached token works" is an accepted state and stays green-ish (WARN).
  local eid esev edetail expiry_msg=""
  while IFS=$'\t' read -r eid esev edetail; do
    [[ -n "$eid" && "$esev" != PASS ]] || continue
    if [[ "$eid" == "-" ]]; then expiry_msg+="; $edetail"; else expiry_msg+="; $eid $edetail"; fi
    (( worst == 0 )) && worst=2
  done < <(claude_login_expiry)
  echo "$msg$expiry_msg"
  return "$worst"
}

# One line per enabled account: id, severity, detail (tab separated).
# `claude-account expiry --json` does the grading (its `severity` already applies the default-vs-other split) and reads
# only the two timestamps of each account's Keychain item. A helper that is missing, fails or answers garbage must not
# read as healthy: it yields one WARN row "login expiry check could not run (<reason>)" and logs the reason to stderr.
# (The one silent case, no claude CLI at all, returns from check_claude_auth before this runs.)
claude_login_expiry() {
  local out="" rows="" reason=""
  if [[ ! -x "$CLAUDE_ACCOUNT_BIN" ]]; then
    reason="$CLAUDE_ACCOUNT_BIN is not executable"
  elif ! out=$(claude_bounded "$CLAUDE_PROBE_TIMEOUT" env PATH="$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin:$PATH" CLAUDE_ACCOUNTS_REGISTRY="$CLAUDE_ACCOUNTS_REGISTRY" "$CLAUDE_ACCOUNT_BIN" expiry --json); then
    reason="claude-account expiry failed"
  elif ! "$JQ_BIN" -e '.accounts | type == "array"' <<<"$out" >/dev/null 2>&1; then
    reason="claude-account expiry gave no account list"
  elif ! rows=$("$JQ_BIN" -r '.accounts[] | "\(.id)\t\(.severity // .grade)\t\(.detail)"' <<<"$out" 2>/dev/null); then
    reason="claude-account expiry rows unreadable"
  fi
  if [[ -n "$reason" ]]; then
    echo "claude_login_expiry: $reason" >&2
    printf '%s\t%s\t%s\n' "-" WARN "login expiry check could not run ($reason)"
    return 0
  fi
  [[ -z "$rows" ]] || printf '%s\n' "$rows"
}
