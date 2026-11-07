#!/bin/bash
# Prints what the other machine reads for `claude-account health`: usage, expiry
# and the pending re-login asks, separated by `@@` lines. Runs on the peer behind
# the iumac-gate verbs account-snapshot / account-snapshot-core.
# Must stay in sync with PEER_SCRIPT (and PENDING_SH) in scripts/claude-account.ts.
"$HOME/.local/bin/claude-account" usage --json; echo '@@'; "$HOME/.local/bin/claude-account" expiry --json; echo '@@'; for f in "$HOME"/.local/state/human-queue/*.req; do [ -e "$f" ] && grep -q claude-relogin "$f" || continue; b="${f%.req}"; [ -e "$b.res" ] || echo "$(basename "$b") $(stat -f %m "$f")"; done
