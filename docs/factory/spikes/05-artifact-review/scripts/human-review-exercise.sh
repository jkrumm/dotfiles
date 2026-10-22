#!/bin/bash
# Option C: human-review 0.8.2. A = nobody answers (default settings); B..E = hr_exercise.py (comment, send, crash, inbox).
set -u; source "$(dirname "$0")/lib.sh"
trap 'stop_all' EXIT
rm -rf "$S/home/.human-review" "$S/out/open-calls.log"; cp "$S/artifacts/BRIEF.md" "$S/artifacts/BRIEF-a.md"
echo "== A: nobody opens the review (defaults): how long is the agent held?"
"$D/hr" "$S/artifacts/BRIEF-a.md" | sed -n 1,2p
t0=$(now); out=$("$D/hr" poll "$S/artifacts/BRIEF-a.md" 2>/dev/null); t1=$(now)
echo "$out"; held=$(secs "$t0" "$t1"); echo "   agent released after ${held}s"
check "poll returns closed" "$(echo "$out" | jq -r .status)" "closed"
check "reason" "$(echo "$out" | jq -r .reason)" "window_closed"
check "released within 55-130 s (60 s never-opened threshold, checked by a 60 s sweep, so 60 or 120 s)" "$(python3 -c "print('yes' if 55 <= $held <= 130 else 'no')")" "yes"
echo "   browser opens recorded by the open shim: $(wc -l < "$S/out/open-calls.log" | tr -d ' ')"
pkill -f "$S/human-review/node_modules" 2>/dev/null; sleep 1
python3 -I "$D/hr_exercise.py"
r=$?; echo; echo "RESULT (A): $pass passed, $fail failed; (B-E) exit $r"
