#!/usr/bin/env bash
# remote-dev-fake-hc — the `hc` stub the remote-dev-*.test.sh suites install as ~/.local/bin/hc of a scratch HOME.
# It is a fake core, never a real one: nothing here starts, reaches or changes herdr-core. State is the directory $STATE:
#   terminals.json   the live roster `terminal.list` answers with (a JSON array of full terminal records; default [])
#   doc.json         {"value":…,"version":n} for `doc.get herdr-app` (default value null, version 0)
#   set_conflicts    n: the next n `doc.set` calls answer `conflict`
#   list_broken      `terminal.list` gets no answer · run_error  <kind>: `terminal.run` answers that error
#   run_fail_first   n: the first n `terminal.run` calls are refused · run_hang  `terminal.run` never answers · send_hang  `hc send` never returns · send_crash  `hc send` exits 3 with no error answer
#   read.txt         what `hc read` prints · send_fail / kill_fail / rm_fail   those verbs exit 1
# Every call is recorded: rpc.log (one request per line), runs.jsonl (terminal.run params), sets.jsonl (doc.set params),
# calls.log (CLI verbs, one call per line, words joined by spaces), last_args (the last send's argv, one word per line), hc-called (touched on any call).
set -u
touch "$STATE/hc-called"
cli() { echo "$*" >>"$STATE/calls.log"; }

reply() { # <id> <result-json>
  jq -nc --argjson id "$1" --argjson r "$2" '{jsonrpc:"2.0",id:$id,result:$r}'
}
fail() { # <id> <kind> <message>
  jq -nc --argjson id "$1" --arg k "$2" --arg m "$3" '{jsonrpc:"2.0",id:$id,error:{code:-32000,message:$m,data:{kind:$k}}}'
}

case "${1:-}" in
  connect)
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      echo "$line" >>"$STATE/rpc.log"
      id=$(jq -c '.id' <<<"$line"); method=$(jq -r '.method' <<<"$line")
      case $method in
        hello) reply "$id" '{"version":"0.1.15"}' ;;
        terminal.list)
          [[ -f $STATE/list_broken ]] && continue
          reply "$id" "$(jq -c '{terminals: .}' "$STATE/terminals.json" 2>/dev/null || echo '{"terminals":[]}')" ;;
        terminal.run)
          jq -c '.params' <<<"$line" >>"$STATE/runs.jsonl"
          [[ -f $STATE/run_hang ]] && exec sleep 30
          left=$(cat "$STATE/run_fail_first" 2>/dev/null || echo 0)
          if (( left > 0 )); then echo $((left - 1)) >"$STATE/run_fail_first"; fail "$id" spawn_failed "refused"; continue; fi
          if [[ -f $STATE/run_error ]]; then fail "$id" "$(cat "$STATE/run_error")" "refused"; continue; fi
          n=$(( $(wc -l <"$STATE/runs.jsonl") + 98 ))
          reply "$id" "{\"address\":\"t$n\"}" ;;
        doc.get)
          if [[ -f $STATE/doc_error ]]; then fail "$id" "$(cat "$STATE/doc_error")" "doc refused"; continue; fi
          reply "$id" "$(cat "$STATE/doc.json" 2>/dev/null || echo '{"value":null,"version":0}')" ;;
        doc.set)
          jq -c '.params' <<<"$line" >>"$STATE/sets.jsonl"
          left=$(cat "$STATE/set_conflicts" 2>/dev/null || echo 0)
          if (( left > 0 )); then echo $((left - 1)) >"$STATE/set_conflicts"; fail "$id" conflict "stale version"; continue; fi
          ver=$(jq '.params.version + 1' <<<"$line")
          jq -c --argjson v "$ver" '{value: .params.value, version: $v}' <<<"$line" >"$STATE/doc.json"
          reply "$id" "{\"version\":$ver}" ;;
        *) fail "$id" unknown "$method" ;;
      esac
    done ;;
  send)  shift; cli send "$@"; [[ -f $STATE/send_crash ]] && { echo "ssh: connection reset" >&2; exit 3; }; [[ -f $STATE/send_hang ]] && exec sleep 30; printf '%s\n' "$@" >"$STATE/last_args"; [[ -f $STATE/send_fail ]] && { echo '{"error":{"kind":"blocked"}}'; exit 1; }; echo '{"sent":true}' ;;
  read)  shift; cli read "$@"; cat "$STATE/read.txt" 2>/dev/null ;;
  kill)  shift; cli kill "$@"; [[ -f $STATE/kill_fail ]] && exit 1; echo '{}' ;;
  rm)    shift; cli rm "$@"; [[ -f $STATE/rm_fail ]] && exit 1; echo '{}' ;;
  *)     cli "$@" ;;
esac
exit 0
