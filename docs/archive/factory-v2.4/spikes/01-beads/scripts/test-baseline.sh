#!/usr/bin/env bash
# Functional parity check of sqlite_tasks.py against the bd semantics the mother relies on.
cd "$(dirname "$0")" || exit 1
export TASKS_DB="${TMPDIR:-/tmp}/spike_t.db" LEASE_TTL=2; rm -f "$TASKS_DB"*
T="python3 sqlite_tasks.py"
A=$($T create "A" --project t | jq -r .id); B=$($T create "B" --project t | jq -r .id)
E=$($T create "E" -t epic --project t | jq -r .id); C=$($T create "C child of E" --parent "$E" --project t | jq -r .id)
$T dep add "$E" "$A"
echo "ready, A blocks E and so E's child C (expect A,B):" $($T ready --json --exclude-type epic | jq -r '[.[].title]|join(",")')
$T update "$A" --claim --actor w1; echo "claim rc=$? (0)"
$T update "$A" --claim --actor w2; echo "foreign claim rc=$? (1)"
$T heartbeat "$A" --actor w1; echo "heartbeat rc=$? (0)"
$T update "$B" --if-status open --status in_progress -a w1; echo "cas ok rc=$? (0)"
$T update "$B" --if-status open --status in_progress -a w2; echo "cas stale rc=$? (13)"
sleep 3; echo "reclaim:" $($T reclaim --older-than 0)
echo "ready after reclaim (A reclaimed; B was CAS-claimed without a lease and stays in progress):" $($T ready --json --exclude-type epic | jq -r '[.[].title]|join(",")')
$T close "$A" --actor w1; echo "close by non-holder rc=$? (expect 1 once B is held by w1):" ; $T close "$B" --actor w2; echo " rc=$?"; $T close "$B" --actor w1
echo "ready after closing A,B (C unblocked through E):" $($T ready --json --exclude-type epic | jq -r '[.[].title]|join(",")')
rm -f "$TASKS_DB"*
