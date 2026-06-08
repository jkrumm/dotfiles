# Homebrew — supply-chain hardening + privacy
# See dependency-hygiene rule: minimal surface, deliberate upgrades, no blind auto-upgrade.

# Refuse formulae/casks/commands from untrusted third-party taps. Trusted taps are
# allow-listed via `brew trust --formula <tap>/<formula>` (oven-sh/bun, satococoa/tap).
# Becomes Homebrew's default in 6.0 — adopting early closes the biggest attack surface.
export HOMEBREW_REQUIRE_TAP_TRUST=1

# Refuse downloads that redirect from HTTPS down to insecure HTTP.
export HOMEBREW_NO_INSECURE_REDIRECT=1

# No usage analytics (also persisted via `brew analytics off`).
export HOMEBREW_NO_ANALYTICS=1

# Note: auto-*update* (refreshing formula definitions before a command) is left ON —
# it surfaces security fixes. Auto-*upgrade* (unattended `brew upgrade`) is the
# npm-style risk and is deliberately NOT enabled; upgrade one package at a time.
