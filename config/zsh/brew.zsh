# Homebrew — supply-chain hardening + privacy
# See dependency-hygiene rule: minimal surface, deliberate upgrades, no blind auto-upgrade.

# Refuse formulae/casks/commands from untrusted third-party taps. Trusted taps are
# allow-listed via `brew trust --formula <tap>/<formula>` (oven-sh/bun, satococoa/tap).
# Both machines are on Homebrew 6.x already (6.0.0 shipped 11 June 2026, where this
# became the default) — the export is now belt-and-braces, not an early adoption.
export HOMEBREW_REQUIRE_TAP_TRUST=1

# Refuse downloads that redirect from HTTPS down to insecure HTTP.
export HOMEBREW_NO_INSECURE_REDIRECT=1

# No usage analytics (also persisted via `brew analytics off`).
export HOMEBREW_NO_ANALYTICS=1

# Note: auto-*update* (refreshing formula definitions before a command) is left ON —
# it surfaces security fixes. Auto-*upgrade* (unattended `brew upgrade`) stays OFF —
# not for npm-style supply-chain reasons (homebrew/core is reviewed PRs + CI-built
# bottles), but because caddy/mosh silently revert local config on upgrade and casks
# are vendor binaries where the release-age cooldown applies. Use `make brew-upgrade`.
