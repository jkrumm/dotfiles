# Claude Max auth for the headless dev host (WP4).
#
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
# (herdr panes, mosh, `desk`), and `~/.zshenv` sources it directly for
# NON-interactive ones — `ssh mini 'claude …'` reads only `.zshenv`, and that is
# precisely the path whose acceptance test this whole package is gated on. The
# limit, stated plainly: it does not reach a bash script or a LaunchAgent that
# execs the binary directly. Those must export the variable themselves.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH. `ca`, `claude_iu` and `claude_bridge`
# (claude.zsh) launch through `env`, which resolves the binary from PATH and
# bypasses shell functions entirely. Their off-Max `ANTHROPIC_AUTH_TOKEN` flow
# is therefore untouched by this file — by construction, not by a guard that
# could rot. `c` / `cs` / `cf` use a prefix assignment, which in zsh *does*
# resolve a function, so those pick the token up as intended.
#
# DEV HOST ONLY. Gated on the `cache` secrets backend marker — the same signal
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

  claude() {
    # An explicit token in the environment always wins — never second-guess a
    # caller that already decided.
    if [[ -n $CLAUDE_CODE_OAUTH_TOKEN ]]; then
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

fi
