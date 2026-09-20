# Homebrew — supply-chain hardening + privacy
# See dependency-hygiene rule: minimal surface, deliberate upgrades, no blind auto-upgrade.

# Tap trust — formulae/casks/commands from untrusted third-party taps are ignored.
# Trusted taps are allow-listed via `brew trust [--formula|--cask] <tap>/<name>`
# (oven-sh/bun, satococoa/tap; `make setup` trusts exactly what the Brewfile declares).
#
# NO EXPORT ANY MORE. `HOMEBREW_REQUIRE_TAP_TRUST=1` was belt-and-braces over the
# Homebrew 6 default; Homebrew 7 (both machines run 7.0.4) turned it into a
# deprecation that prints
#   Warning: Calling HOMEBREW_REQUIRE_TAP_TRUST is deprecated! Use the default
#   behaviour instead.
# on EVERY brew invocation. A permanent warning on a command that is scripted and
# parsed all over this repo is worse than no belt at all — it trains the eye to skip
# brew's warnings, which is where the real ones appear. The behaviour it asked for is
# the default and stays on without it; `brew trust --json v1` shows the live store.

# Refuse downloads that redirect from HTTPS down to insecure HTTP.
export HOMEBREW_NO_INSECURE_REDIRECT=1

# No usage analytics (also persisted via `brew analytics off`).
export HOMEBREW_NO_ANALYTICS=1

# Note: auto-*update* (refreshing formula definitions before a command) is left ON —
# it surfaces security fixes. Auto-*upgrade* (unattended `brew upgrade`) stays OFF —
# not for npm-style supply-chain reasons (homebrew/core is reviewed PRs + CI-built
# bottles), but because caddy silently reverts local config on upgrade and casks
# are vendor binaries where the release-age cooldown applies. Use `make brew-upgrade`.
