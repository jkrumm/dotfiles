#!/usr/bin/env bash
# remote-dev-help.test — `rd --help` lists every verb the dispatch accepts, `rd <verb> --help` documents it, and help
# has no side effect: no hc call, no ssh hop, no agent started (fake `hc` and `ssh` record any call).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-help-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home/.local/bin" "$TMP/home/SourceRoot/myrepo/.git" "$TMP/xdg/secrets"
echo cache >"$TMP/xdg/secrets/backend"
cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
chmod +x "$TMP/home/.local/bin/hc"
# any ssh hop or claude call is a side effect: record it
for b in ssh claude factory; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$STATE/called"\nexit 1\n' "$b" >"$TMP/bin/$b"; chmod +x "$TMP/bin/$b"
done
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
unset RD_DRY_RUN

rd() { out=$(bash "$HERE/remote-dev.sh" "$@" 2>"$TMP/err"); rc=$?; err=$(cat "$TMP/err"); }

# The verbs the dispatch accepts: the arm labels of the last `case "${1:-}" in` block (words, no flags, no empty arm).
dispatched=$(awk '/^  repos\)/{f=1} f&&/^esac/{exit} f' "$HERE/remote-dev.sh" | sed -n 's/^  \([a-z|]*\)).*/\1/p' | tr '|' '\n' | sort -u | tr '\n' ' ')
[ "$(wc -w <<<"$dispatched")" -ge 7 ] && ok "dispatch parsed: $dispatched" || bad "dispatch parse found too few verbs: $dispatched"

rd --help
[ "$rc" -eq 0 ] && ok "rd --help exits 0" || bad "rd --help exit $rc"
top=$out
for v in $dispatched; do has "rd --help lists '$v'" "$top" "rd $v"; done
has "rd --help names the retired verbs" "$top" "Retired"
for form in "-h" "help" ""; do
  if [ -z "$form" ]; then rd; else rd "$form"; fi
  [ "$rc" -eq 0 ] && [ "$out" = "$top" ] && ok "rd ${form:-<bare>} prints the same text, exit 0" || bad "rd ${form:-<bare>}: rc=$rc"
done

for v in work agents read say repos reap; do
  rd "$v" --help
  [ "$rc" -eq 0 ] && ok "rd $v --help exits 0" || bad "rd $v --help exit $rc: $err"
  has "rd $v --help documents the verb" "$out" "rd $v"
  rd help "$v"
  has "rd help $v prints the same" "$out" "rd $v"
done
rd work --help; has "work --help lists its flags" "$out" "--role R"; has "work --help lists --kind" "$out" "--kind K"
rd reap -h;     has "reap -h lists --dry-run" "$out" "--dry-run"
rd issue --help; has "a retired verb's --help points at the factory CLI" "$out" "factory issue new"

# nothing ran: no hc call, no ssh hop, no claude, no factory lookup
[ ! -e "$STATE/hc-called" ] && ok "help never called hc" || bad "help called hc"
[ ! -e "$STATE/called" ] && ok "help made no ssh/claude/factory call" || bad "help called: $(cat "$STATE/called")"
[ ! -e "$STATE/runs.jsonl" ] && ok "help started no terminal" || bad "help started a terminal"

# only the word right after the verb is help: the text of a message or prompt is never swallowed
RD_DRY_RUN=1 rd say worker --help
lacks "rd say <agent> --help is not help" "$out" "rd say <agent> <text"

# an unknown verb is still an error, with --help or without
rd frobnicate --help
[ "$rc" -ne 0 ] && ok "unknown verb with --help still fails" || bad "unknown verb exited 0"

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
