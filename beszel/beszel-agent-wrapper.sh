#!/usr/bin/env bash
# Exec'd by com.jkrumm.beszel-agent (LaunchAgent). Its sole job is sourcing
# the credential env file at RUNTIME so HUB_URL/TOKEN/KEY never sit in the
# plist as plaintext EnvironmentVariables — that is exactly what
# scripts/doctor.sh's LaunchAgent audit flags. Same shape as
# collie-ctl.sh's `_exec-bridge`.
set -euo pipefail

ENV_FILE="$HOME/.config/beszel/beszel-agent.env"
[ -r "$ENV_FILE" ] || { echo "beszel-agent-wrapper: no env file at $ENV_FILE" >&2; exit 1; }

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

exec "$HOME/.local/bin/beszel-agent"
