#!/usr/bin/env bash
# Live test against the running gateway (localhost:7780 = production). 2 quick jobs total.
# Usage: ./live-test.sh > live-transcript.txt 2>&1
cd "$(dirname "$0")" || exit 1
n=0
call() { # call <runtime> <env-assignments...> -- <args...>; logs stdout (trimmed), last stderr line, exit code
  local rt=$1; shift; local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  n=$((n+1)); local t0=$SECONDS
  env "${envs[@]}" "$rt" agw-poc.ts "$@" >/tmp/agw-out.$$ 2>/tmp/agw-err.$$; local code=$?
  echo "--- call $n [$rt] ${envs[*]} agw-poc $*"
  echo "exit=$code  wall=$((SECONDS-t0))s"
  echo "stdout: $(head -c 500 /tmp/agw-out.$$)"; [ "$(wc -c </tmp/agw-out.$$)" -gt 500 ] && echo "        ... ($(wc -c </tmp/agw-out.$$) bytes total)"
  echo "stderr(last): $(tail -n1 /tmp/agw-err.$$)"
  LAST_CODE=$code; LAST_OUT=/tmp/agw-out.$$; LAST_ERR=/tmp/agw-err.$$
}
Q="Name the two most widely used generic OpenAPI to CLI generators and one limitation of each"

echo "=== (c) 404 jobId, (d) unknown flag, offline schema"
call node X=1 -- research status job-does-not-exist
call node X=1 -- research run "$Q" --depth quick --bogus
call node X=1 -- schema --exit-codes
call node X=1 -- research run "$Q" --depth quick           # no --commit, non-TTY

echo; echo "=== (a) budget 5s on a quick job -> pending; (b) resume completes"
call node AGW_WAIT_BUDGET_S=5 -- research run "$Q" --depth quick --commit
JOB=$(sed -n 's/.*"jobId":"\([^"]*\)".*/\1/p' "$LAST_OUT" | head -1)
echo "jobId=$JOB"
HINT=$(tail -n1 "$LAST_ERR" | sed -n 's/.*"hint":"\([^"]*\)".*/\1/p'); echo "resume hint: $HINT"
call node X=1 -- ${HINT#agw-poc }
cp "$LAST_OUT" /tmp/agw-job-A.json

echo; echo "=== bun, default budget (110s): a quick job should finish in ONE call"
call bun X=1 -- research run "What is restish and how does it differ from openapi-generator CLI" --depth quick --commit
echo; echo "=== cancel on a finished job (idempotent), and wait on it again"
call bun X=1 -- research cancel "$JOB" --commit
call bun X=1 -- research cancel "$JOB"
echo; echo "total CLI invocations: $n"
