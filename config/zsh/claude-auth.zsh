# The `claude` shell function: account pick for interactive starts (all machines) and the
# Claude Max token fallback for the headless dev host (mini only, WP4).
#
# ONE FUNCTION, TWO JOBS. `claude()` at the bottom is the only definition on any machine:
#
#   1. Account pick. A `claude` typed into an interactive zsh — which is exactly what
#      `herdr agent start` does into a pane — picks its account with
#      `claude-account pick --lane ${USAGE_LANE:-interactive}` (docs/claude-accounts.md), unless
#      CLAUDE_ACCOUNT_PICKED is already set: every chooser that decided an account sets that
#      variable (`c`/`cs`/`cf`, `rd wave|work|fan`), and it is inherited by children. The marker, not
#      CLAUDE_CONFIG_DIR, carries the decision because an iu pick is `unset CLAUDE_CONFIG_DIR` — it
#      looks identical to "nobody chose". Non-interactive shells, `claude -p`, info flags and
#      subcommands (auth, mcp, …) never pick. `--resume <id>` keeps the session's account.
#   2. Token fallback (below), via `_claude_auth_run`. Defined as a real fallback only on the dev host;
#      everywhere else it is a plain `command claude`.
#
# The pick helpers (`_claude_account_line`, `_claude_enter_account`) live in claude.zsh, which only
# interactive shells load; `~/.zshenv` sources THIS file alone for non-interactive ones, so the
# pick branch is guarded by `-o interactive` and never needs them there.
#
# THE TOKEN FALLBACK — the failure it exists to prevent.
# THE FAILURE THIS EXISTS TO PREVENT. Claude Code's Max credentials live in the
# macOS **login keychain**, which is unlocked by a human typing a password at
# login. Two things on this machine cannot reach it:
#
#   - an ssh session (`ssh mini 'claude --bg …'`), because it is not in the GUI
#     session at all;
#   - after WP6, the auto-login session itself — automatic login never supplies
#     the password to the keychain subsystem, so the login keychain stays LOCKED
#     even though a desktop is up.
#
# In both cases `claude` does not error. It reports `Not logged in`, silently
# falls back to **API Usage Billing**, and still lists healthy in
# `claude agents`. That is why this is a hard gate before FileVault goes off.
#
# THE FIX. `claude setup-token` mints a long-lived OAuth token that is honoured
# via `CLAUDE_CODE_OAUTH_TOKEN` with no keychain involved. It is stored as
# `op://mini/claude/oauth-token` and reaches this machine through the same
# age-encrypted offline cache as every other headless secret. It must be that
# variable and never `ANTHROPIC_API_KEY` — exporting the latter flips billing to
# API credits, i.e. it *causes* the exact failure this prevents.
#
# WHY A FUNCTION, AND NOT A SHIM IN ~/.local/bin. `~/.local/bin/claude` is a
# symlink the Claude Code updater rewrites on every version bump. A shim placed
# there is silently reverted by the next self-update — the same class of failure
# as `brew upgrade caddy` dropping the DNS module. A zsh function has no such
# lifecycle: it is defined from tracked config on every shell.
#
# WHERE IT APPLIES. `~/.zshrc` sources this via conf.d for interactive shells
# (herdr panes, `desk`), and `~/.zshenv` sources it directly for
# NON-interactive ones — `ssh mini 'claude …'` reads only `.zshenv`, and that is
# precisely the path whose acceptance test this whole package is gated on. The
# limit, stated plainly: it does not reach a bash script or a LaunchAgent that
# execs the binary directly. Those must export the variable themselves.
#
# TOKEN FALLBACK = DEFAULT ACCOUNT ONLY (CLAUDE_CONFIG_DIR unset, account iu).
#
# WHAT IT DELIBERATELY DOES NOT TOUCH. `ca` and `claude_iu` (claude.zsh) launch
# through `env`, which resolves the binary from PATH and
# bypasses shell functions entirely. Their off-Max `ANTHROPIC_AUTH_TOKEN` flow
# is therefore untouched by this file — by construction, not by a guard that
# could rot (they also never pick: their account is chosen by their own launcher).
# `c` / `cs` / `cf` call `claude` as a function, so they get the token logic as
# intended — and the marker they set makes the wrapper skip its own pick.
#
# DEV HOST ONLY (the token fallback; the pick applies on every machine). Gated on
# the `cache` secrets backend marker — the same signal
# `git-headless`, `collie-setup` and `caddy-tailnet` use. On the MacBook the
# backend is `op`, where `secrets-run` passes through to live biometric `op`:
# wiring this there would pop a Touch ID prompt on every single `claude` launch.
# The gate is a file read, so a non-dev-host shell pays nothing at all.
#
# SILENT WHEN THE REF IS ABSENT, ON PURPOSE. Until the human has run
# `claude setup-token` and the cache has been reseeded, the read fails and this
# falls through to whatever auth `claude` already had — which on a logged-in
# machine is the working keychain session. It must not break the status quo to
# announce a future step. The reporter for the failure case is
# `check_claude_auth` in scripts/devhost-health-check.sh, which fails the 5-min
# heartbeat on anything other than a logged-in Max session.

if [[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend ]] \
  && [[ "$(<${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend)" == cache ]]; then

  # KEYCHAIN FIRST, TOKEN ONLY IF IT IS ACTUALLY DEAD. This ordering is the whole
  # point and it was inverted for months: the original injected the token
  # unconditionally the moment the ref existed, which is a PREEMPTION, not the
  # fallback the header above describes.
  #
  # That inversion is self-fulfilling. Claude Code's keychain credential is a
  # short access token plus a ROLLING refresh token — it renews itself when the
  # binary uses it, and only then. Preempt it on every zsh launch and nothing on
  # this machine ever exercises it, so it quietly ages out and the "fallback"
  # becomes the only thing holding the host up. Measured 2026-08-17: the bare
  # binary reported `loggedIn: false, authMethod: none` while every herdr pane
  # worked fine on the token. It would also have silently swallowed the next
  # `/login` — you would restore the keychain and still be running on the token,
  # with no way to tell.
  #
  # So: probe the real credential, prefer it, and fall back only on failure.
  #
  # NO CACHING OF THE VERDICT, and that is a deliberate retreat from a version
  # that cached the positive one for an hour in ~/.local/state/claude-auth.
  # Within a day it produced a `keychain-ok` stamp on a host whose bare binary
  # reported `loggedIn: false` — impossible by the code as written, not
  # reproducible on demand, and not explained by the obvious hypothesis either
  # (running the binary WITH the token persists no credential; measured
  # 2026-08-18, bare reports false before and after).
  #
  # An unexplained stamp is not a cosmetic problem here: a wrong positive
  # suppresses the fallback for a full hour, so `claude` runs with no credential
  # at all and silently bills API credits — the exact failure this file exists to
  # prevent, reintroduced by the optimisation guarding it. The saving was 245ms
  # (measured) per launch, against a Claude Code startup an order of magnitude
  # larger. Probing every time is simple, always correct, and cheap enough that
  # the complexity could never have paid for itself. If the probe ever becomes
  # genuinely expensive, cache it then — with a mechanism whose failure mode is
  # "probe again", not "run unauthenticated".

  _claude_auth_run() {
    # Any non-default account (CLAUDE_CONFIG_DIR set, docs/claude-accounts.md) is
    # NEVER given the IU token: it is a different login, and injecting it ran the
    # session on the wrong account. This branch comes BEFORE the explicit-token
    # one, so an inherited CLAUDE_CODE_OAUTH_TOKEN cannot override that login either.
    # A dead login is only reported, and then runs WITHOUT any API credential
    # (ANTHROPIC_API_KEY / AUTH_TOKEN stripped): it must not fall back to API billing.
    if [[ -n ${CLAUDE_CONFIG_DIR-} ]]; then
      if command env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
        command env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude "$@"
      else
        print -u2 "claude: not logged in under CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR — run /login in a herdr pane (no token fallback for this account)"
        command env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude "$@"
      fi
      return
    fi

    # An explicit token in the environment always wins — never second-guess a
    # caller that already decided.
    if [[ -n $CLAUDE_CODE_OAUTH_TOKEN ]]; then
      command claude "$@"
      return
    fi

    # The real credential, exercised on every launch — which is also what keeps
    # its rolling refresh alive, the whole point of preferring it.
    if command claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
      command claude "$@"
      return
    fi

    local tok
    tok=$(secrets-run read op://mini/claude/oauth-token 2>/dev/null) || tok=""
    if [[ -z $tok ]]; then
      command claude "$@"
      return
    fi

    # Prefix assignment, not `env VAR=… claude`: `env` puts the value in the
    # child's argv, where `ps auxww` shows it to anything on the machine. The
    # prefix form passes it in the environment block only.
    CLAUDE_CODE_OAUTH_TOKEN="$tok" command claude "$@"
  }

else
  _claude_auth_run() { command claude "$@"; }
fi

# True when the args start a session — the only thing worth an account pick. Info flags, print mode
# (`claude -p` subprocesses) and subcommands never do; the list is the `claude --help` command set
# (a subcommand added later just gets one harmless pick until it is listed here).
_claude_starts_session() {
  local a
  for a in "$@"; do
    case $a in
      -p|--print|-v|--version|-h|--help|--bg|--background) return 1 ;;
    esac
  done
  case ${1-} in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade) return 1 ;;
  esac
  return 0
}

# True when CLAUDE_ACCOUNT_PICKED still describes this environment: the marked account's registry dir is
# the current CLAUDE_CONFIG_DIR (iu = unset). A stale marker inherited from a long-lived parent (the herdr
# server's env, an old shell) fails this and the pick runs. Every chooser sets marker and dir together.
# An unreadable registry cannot say otherwise, so the marker stands.
_claude_marker_valid() {
  [[ -n ${CLAUDE_ACCOUNT_PICKED-} ]] || return 1
  local want
  want=$(jq -r --arg id "$CLAUDE_ACCOUNT_PICKED" '.accounts[$id] | if . == null then "?" else (.dir // "") end' \
    "${_CLAUDE_ACCOUNTS_REGISTRY-}" 2>/dev/null) || return 0
  [[ $want == "?" ]] && return 1
  want=${want/#\~/$HOME}
  [[ ${want:A} == "${CLAUDE_CONFIG_DIR:+${CLAUDE_CONFIG_DIR:A}}" || ( -z $want && -z ${CLAUDE_CONFIG_DIR-} ) ]]
}

claude() {
  if [[ -o interactive ]] && ! _claude_marker_valid && (( $+functions[_claude_account_line] )) && _claude_starts_session "$@"; then
    local out
    local -a parts
    # A failing forced/session lookup is the only rc 1; fall through to the plain run rather than block.
    if out=$(_claude_account_line "" "${USAGE_LANE:-interactive}" "$(_claude_resume_id "$@")"); then
      parts=("${(@f)out}")
      (
        _claude_enter_account "$parts[1]" "$parts[2]" "$parts[3]"
        _claude_auth_run "$@"
      )
      return
    fi
  fi
  _claude_auth_run "$@"
}
