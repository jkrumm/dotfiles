#!/usr/bin/env bash
# op-signed-in — the ONE answer to "can `op` resolve secrets for <account> right
# now?". Exit 0 if yes, 1 if the app is locked, absent, or not authorized.
#
# Usage:  scripts/lib/op-signed-in.sh <account>
# Env:    OP_BIN (default: op)         OP_SIGNED_IN_TIMEOUT (default: 20s)
#
# WHY THIS EXISTS AS A SHARED FILE. The obvious probe is `op whoami`, and it is
# wrong on both of these Macs — wrong in the direction that is hardest to catch,
# because it fails CLOSED and every caller then reports a tidy, deliberate-looking
# refusal. Under 1Password's DESKTOP-APP integration (the only mode used here)
# there is no CLI session token, so:
#
#   $ op whoami --account tkrumm        → rc=1  "account is not signed in"
#   $ op account get --account tkrumm   → rc=0
#   $ op read op://common/anthropic/...  → resolves, instantly
#
# all three measured on 2026-08-17 with op 2.38.1, seconds apart, on an unlocked
# app. A whoami-gated command is therefore not "strict", it is permanently dead.
#
# That had already happened four times over before anyone noticed, because each
# site failed with its own plausible message: the auto-reseed skipped on every
# hourly tick for 11 days; `make tailscale-acl-diff` — on the ONLY machine that
# can push the tailnet ACL — died telling you to run `op signin`; `make
# secrets-rotate` refused and sent you to the mini, which is the one place
# rotation genuinely cannot run; and `make status` reported the session expired
# forever. Five copies of one wrong idea, so fixing four of them would have left
# the fifth to spread it back.
#
# So: one file, one probe, and `rules/makefile-conventions.md` points here rather
# than printing a snippet people paste. If a future op release changes what a
# usable session looks like, this is the single place that is wrong.
#
# WHY `op account get`. It is the cheapest call that actually exercises the
# desktop-app handshake: no secret leaves 1Password, it is one call, it returns
# instantly against an unlocked app, and against a locked one it raises exactly
# ONE dialog — which is the single biometric moment a guarded command should
# have. Bounded by `timeout` because an unanswered dialog otherwise hangs the
# caller indefinitely; stdin is closed so `op` can never drop into a prompt that
# a LaunchAgent has no way to answer.
set -euo pipefail

acct="${1:-}"
[ -n "$acct" ] || { echo "usage: $(basename "$0") <1password-account>" >&2; exit 2; }

OP_BIN="${OP_BIN:-op}"
OP_SIGNED_IN_TIMEOUT="${OP_SIGNED_IN_TIMEOUT:-20}"

command -v "$OP_BIN" >/dev/null 2>&1 || exit 1

# `timeout` is coreutils, i.e. Homebrew — present on both Macs but not something
# to hard-require, since this probe is called from `make setup` on a machine that
# may not have finished installing anything yet. Degrade to an unbounded call
# rather than reporting "locked" on a perfectly good app.
if command -v timeout >/dev/null 2>&1; then
  timeout -k 5 "$OP_SIGNED_IN_TIMEOUT" "$OP_BIN" account get --account "$acct" </dev/null >/dev/null 2>&1
else
  "$OP_BIN" account get --account "$acct" </dev/null >/dev/null 2>&1
fi
