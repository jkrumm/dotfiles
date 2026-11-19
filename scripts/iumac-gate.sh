#!/bin/bash
# iumac-gate.sh — the forced command behind the mini->iumac key.
#
# config/ssh/authorized_keys.iumac pins this script with `command=`, so every
# connection that key makes lands here with the requested command in
# $SSH_ORIGINAL_COMMAND. The key's job is a short list of named operations
# (reachability probe, human-queue dialogs, notifications, claude re-login,
# account snapshots, a granted catalogue command with no dialog (auto-run), a dotfiles pull with its link targets, the Herdr glance and claude-account pulls, agent notes (term-ls, term-note), a read-only report, a repo fast-forward,
# usage-tracker pulls); this gate maps each verb to its one
# fixed action and refuses everything else. Least privilege: the mini's
# outbound credential can do what the mini needs and no more.
#
# Rules:
#   - the original command is never evaluated: it is split into words with
#     `read -ra` and dispatched on word 1; arguments are validated, never run;
#   - any shell metacharacter in the raw string refuses the request, for every
#     verb (the two iu-portal scrape literals are matched verbatim first);
#   - unknown verb or unexpected arity -> "refused: <verb>" on stderr, exit 126;
#   - the 1Password agent socket is never inherited (unset first);
#   - one log line per decision (verb + allow/refuse only, never arguments or
#     stdin) in ~/Library/Logs/iumac-gate.log.
#
# Test seams (tests only; sshd never sets them): IUMAC_GATE_HOME replaces $HOME
# for every path below so a temp tree of stub scripts can stand in for the real
# repo; IUMAC_GATE_RSYNC / IUMAC_GATE_GIT replace the rsync and git binaries; IUMAC_GATE_IOREG replaces ioreg (the auto-run lock probe); IUMAC_GATE_REPORT_TIMEOUT /
# IUMAC_GATE_PULL_TIMEOUT replace the `report` (60 s) and `repo-pull` (300 s) limits.
#
# Runs on the MacBook under /bin/bash 3.2: no associative arrays, no mapfile.
unset SSH_AUTH_SOCK

H="${IUMAC_GATE_HOME:-$HOME}"
raw="${SSH_ORIGINAL_COMMAND:-}"
LOG="$H/Library/Logs/iumac-gate.log"

log() { # <verb> <allow|refuse> — best effort, never fails the command
  {
    mkdir -p "$H/Library/Logs"
    printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" >>"$LOG"
    local n
    n=$(wc -l <"$LOG")
    if [ "${n:-0}" -gt 2000 ]; then
      tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
  } >/dev/null 2>&1 || true
}

# A verb name that is safe to print and log, whatever the caller sent.
safe_verb() {
  local v="${1:-}"
  case "$v" in
    '' | *[!A-Za-z0-9._-]*) printf '?' ;;
    *) printf '%s' "${v:0:32}" ;;
  esac
}

refuse() { # <verb>
  local v
  v="$(safe_verb "${1:-}")"
  log "$v" refuse
  printf 'refused: %s\n' "$v" >&2
  exit 126
}

# run_limited <seconds> <command...> — run it with stderr merged into stdout, stdin closed, a time limit and the output
# cut to 64 KB; sets LIMITED_RC (124 on the time limit). The watchdog has no stdio, so ssh never waits on it.
run_limited() {
  local secs="$1" out pid wd
  shift
  out="$(mktemp "${TMPDIR:-/tmp}/iumac-gate.XXXXXX")" || {
    LIMITED_RC=1
    return
  }
  "$@" >"$out" 2>&1 </dev/null &
  pid=$!
  (
    sleep "$secs"
    kill -0 "$pid" 2>/dev/null || exit 0
    : >"$out.timeout"
    pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  wd=$!
  wait "$pid" 2>/dev/null
  LIMITED_RC=$?
  pkill -P "$wd" 2>/dev/null
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  if [ -e "$out.timeout" ]; then
    LIMITED_RC=124
    rm -f "$out.timeout"
  fi
  head -c 65536 "$out"
  # A cut or newline-less output must not swallow the caller's own last line.
  LIMITED_NEEDNL=0
  if [ -s "$out" ] && [ "$(head -c 65536 "$out" | tail -c 1 | wc -l | tr -d ' ')" -eq 0 ]; then LIMITED_NEEDNL=1; fi
  rm -f "$out"
}

if [ -z "$raw" ]; then
  log "(none)" refuse
  echo "refused" >&2
  exit 126
fi

# --- iu-portal scrape (usage-tracker): exact literals, they contain `&&` ----
SCRAPE='cd ~/.local/share/iu-portal/tool && bun scrape.ts daily monthly'
if [ "$raw" = "$SCRAPE" ] || [ "$raw" = "$SCRAPE --no-latest" ]; then
  log iu-scrape allow
  export PATH="$H/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
  cd "$H/.local/share/iu-portal/tool" || exit 1
  if [ "$raw" = "$SCRAPE" ]; then
    exec bun scrape.ts daily monthly
  fi
  exec bun scrape.ts daily monthly --no-latest
fi

# --- universal metacharacter rule -------------------------------------------
nl=$'\n'
cr=$'\r'
case "$raw" in
  *[\;\&\|\`\$\(\)\<\>\\\"\']* | *"$nl"* | *"$cr"*)
    read -ra _w <<<"${raw%%[[:space:]]*}"
    refuse "${_w[0]:-}"
    ;;
esac

read -ra words <<<"$raw"
verb="${words[0]:-}"
argc=${#words[@]}

[ -n "$verb" ] || refuse ""

# --- auto-run ----------------------------------------------------------------------------------------------
# `auto-run`: one request JSON on stdin (the same file `gui-run` gets); when its command is byte-equal to a template of
# config/macbook-auto-classes.tsv, the template's class is granted on THIS MacBook (~/.config/jk/auto-run.consent, written
# only by `human-queue.sh consent grant`, never by a gate verb) and the kill switch (~/.config/jk/auto-run.off) is absent,
# the command runs with no dialog. Stdout carries exactly one result JSON line, like gui-run, plus "via":"auto-run" and
# "class":"<class>" (a dialog's line has neither; the factory counts and labels the run by them). Exit 77: not a class, not
# granted or switched off (the caller falls back to the dialog); 75: a biometric class on a locked screen (nothing runs, the
# request stays pending). The log gets the verb, a fixed reason word or the class and the exit, never the command.
AUTO_DIR="$H/.config/jk"

auto_refuse() { # <exit> <reason word>
  log auto-run "refuse:$2"
  printf 'auto-run refused: %s\n' "$2" >&2
  exit "$1"
}

# 0 = the screen is locked, or cannot be read (a biometric prompt would only time out).
auto_screen_locked() {
  local out
  out="$("${IUMAC_GATE_IOREG:-/usr/sbin/ioreg}" -n Root -d1 -a 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" | tr -d '\n\t ' | grep -q '<key>CGSSessionScreenIsLocked</key><true/>'
}

# A template as an anchored ERE: the literal text escaped, the one slot <N> = 1 to 4 digits; rc 1 on any other <slot>.
auto_template_regex() {
  local t="$1" esc slot='[0-9]{1,4}'
  case "${t//<N>/}" in *'<'* | *'>'*) return 1 ;; esac
  esc="$(printf '%s' "$t" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
  printf '^%s$' "${esc//<N>/$slot}"
}

auto_run() {
  local req id text cmd tsv class="" needs="" limit="" c t n l re consent mode
  [ -e "$AUTO_DIR/auto-run.off" ] && auto_refuse 77 killswitch
  req="$(head -c 20000)"
  die() { auto_refuse 77 input; }
  # shellcheck source=lib/human-queue-json.sh
  [ -r "$H/SourceRoot/dotfiles/scripts/lib/human-queue-json.sh" ] || auto_refuse 77 nolib
  source "$H/SourceRoot/dotfiles/scripts/lib/human-queue-json.sh"
  id="$(json_field "$req" id)"
  validate_id "$id"
  cmd="$(json_field "$req" cmd)"
  [ -n "$cmd" ] || auto_refuse 77 nocmd
  [ "$(printf '%s' "$cmd" | LC_ALL=C tr -d '\000-\037\177')" = "$cmd" ] || auto_refuse 77 control
  tsv="$H/SourceRoot/dotfiles/config/macbook-auto-classes.tsv"
  [ -r "$tsv" ] || auto_refuse 77 nocatalogue
  while IFS=$'\t' read -r c t n l _; do
    case "$c" in '' | '#'*) continue ;; esac
    [[ "$c" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
    case "$n" in none | biometric) ;; *) continue ;; esac
    [[ "$l" =~ ^[0-9]{1,4}$ ]] || continue
    re="$(auto_template_regex "$t")" || continue
    if [[ "$cmd" =~ $re ]]; then class="$c" needs="$n" limit="$l"; break; fi
  done <"$tsv"
  [ -n "$class" ] || auto_refuse 77 nomatch
  consent="$AUTO_DIR/auto-run.consent"
  mode="$(stat -f %Lp "$consent" 2>/dev/null)"
  # Granted: listed, owned by this user, and writable by nobody else.
  { [ -f "$consent" ] && [ -O "$consent" ] && ! case "$mode" in ?[2367]? | ??[2367]) true ;; *) false ;; esac && grep -qxF -- "$class" "$consent"; } || auto_refuse 77 notgranted
  if [ "$needs" = biometric ] && auto_screen_locked; then auto_refuse 75 locked; fi

  local tmp tmp2 rc terminal="" st ran_at output_tail
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  text="$(json_field "$req" text)"
  export PATH="$H/.local/bin:/opt/homebrew/bin:/usr/local/bin:$H/.bun/bin:$PATH"
  tmp="$(mktemp "${TMPDIR:-/tmp}/iumac-auto.XXXXXX")" || auto_refuse 77 tmp
  tmp2="$tmp.f"
  run_limited "$limit" env HOME="$H" /bin/bash -c "$cmd" >"$tmp"
  rc="$LIMITED_RC"
  log auto-run "ran:$class exit=$rc"
  # hc leaves a command running past its --timeout (exit 124, "still running as <id>"): pending, not failed.
  if [ "$rc" -eq 124 ] && [[ "$(cat "$tmp")" =~ still\ running\ as\ (t[0-9a-z]+) ]]; then terminal="${BASH_REMATCH[1]}"; fi
  grep -v '^\[hc\] ' "$tmp" >"$tmp2" || true
  output_tail="$(head_tail_lines "$tmp2")"
  rm -f "$tmp" "$tmp2"
  text="$(printable "$text" | tr '\n' ' ' | cut -c1-120)"
  printf '%s\n' 'on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run' | osascript - "iumac auto-run" "ran $class for ${text:-a request}" >/dev/null 2>&1 || true
  if [ -n "$terminal" ]; then
    build_result_json "$id" pending "" "$ran_at" "$output_tail" "$terminal" auto-run "$class"
  else
    st="done"
    [ "$rc" -eq 0 ] || st=failed
    build_result_json "$id" "$st" "$rc" "$ran_at" "$output_tail" "" auto-run "$class"
  fi
  exit 0
}

RELOGIN_ID_RE='^[a-z0-9_-]+$'

case "$verb" in
  true)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exit 0
    ;;

  gui-run)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    exec bash "$H/SourceRoot/dotfiles/scripts/human-queue.sh" gui-run
    ;;

  auto-run)
    # A catalogue command a granted class may run with no dialog (see auto_run above). Needs the request JSON on stdin.
    [ "$argc" -eq 1 ] || refuse "$verb"
    auto_run
    ;;

  notify)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    IFS= read -r title || true
    text="$(head -c 4000 | tr '\n' ' ')"
    title="$(printf '%s' "${title:-}" | head -c 4000 | tr -d '\000-\037\177')"
    text="$(printf '%s' "$text" | tr -d '\000-\037\177')"
    title="${title:0:100}"
    text="${text:0:400}"
    # Same fixed script claude-relogin.sh uses; title/text travel as argv only.
    printf '%s\n' 'on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run' | exec osascript - "$title" "$text"
    ;;

  open-url)
    [ "$argc" -eq 1 ] || refuse "$verb"
    IFS= read -r app || true
    IFS= read -r url || true
    [[ "$url" =~ ^https://[^[:space:]]+$ ]] || refuse "$verb"
    if [ -n "$app" ]; then
      [[ "$app" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,60}$ ]] || refuse "$verb"
      log "$verb" allow
      exec open -a "$app" "$url"
    fi
    log "$verb" allow
    exec open "$url"
    ;;

  relogin)
    [ "$argc" -eq 2 ] || { [ "$argc" -eq 3 ] && [ "${words[2]}" = "--visible" ]; } || refuse "$verb"
    [[ "${words[1]}" =~ $RELOGIN_ID_RE ]] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$H/.bun/bin:$PATH"
    if [ "$argc" -eq 3 ]; then
      exec bash "$H/SourceRoot/dotfiles/scripts/claude-relogin.sh" "${words[1]}" --machine macbook --visible
    fi
    exec bash "$H/SourceRoot/dotfiles/scripts/claude-relogin.sh" "${words[1]}" --machine macbook
    ;;

  account-usage)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec "$H/.local/bin/claude-account" usage --json
    ;;

  account-snapshot)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$H/.bun/bin:$PATH"
    exec bash "$H/SourceRoot/dotfiles/scripts/claude-account-snapshot.sh"
    ;;

  account-snapshot-core)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$H/.bun/bin:$PATH"
    bash "$H/SourceRoot/dotfiles/scripts/lib/core-up.sh" >/dev/null 2>&1 || exit 99
    exec hc exec --timeout 30 bash "$H/SourceRoot/dotfiles/scripts/claude-account-snapshot.sh"
    ;;

  dotfiles-sync)
    # Fast-forward the MacBook's dotfiles checkout from the public repo and run the make targets the pulled range
    # touched (config/macbook-sync.tsv). No arguments; refuses a dirty tree, another branch, a diverged master.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec bash "$H/SourceRoot/dotfiles/scripts/macbook-sync.sh"
    ;;

  herdr-glance-sync)
    # Pull the live factory release's jk-glance through the MacBook's core and reload the Herdr layout when it
    # changed (scripts/herdr-glance-sync.sh). No arguments; the mini's post-deploy hook is the caller.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$PATH"
    exec bash "$H/SourceRoot/dotfiles/scripts/herdr-glance-sync.sh"
    ;;

  claude-account-sync)
    # Bring the MacBook's claude-account (a copy of the factory accounts package's built file) level with the live
    # release on the mini through the core (scripts/claude-account-sync.sh). No arguments; the mini's post-deploy hook is the caller.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$PATH"
    exec bash "$H/SourceRoot/dotfiles/scripts/claude-account-sync.sh"
    ;;

  account-version)
    # `claude-account --version` of this machine, for the mini's doctor row that compares both.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:$H/.bun/bin:$PATH"
    exec "$H/.local/bin/claude-account" --version
    ;;

  term-ls)
    # The MacBook core's terminals that take notes (label jk.notes=accept): id, name, program, state, space. No screen text.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec bash "$H/SourceRoot/dotfiles/scripts/agent-note.sh" ls-local
    ;;

  term-note)
    # A note from a mini agent to a MacBook agent terminal (agent-note). stdin: target id, sender, body. The script
    # delivers only into a terminal labelled jk.notes=accept, caps and strips the body, rate limits, logs; it prints
    # one JSON line and exits 0 delivered, 75 queued, 64 refused.
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec bash "$H/SourceRoot/dotfiles/scripts/agent-note.sh" deliver
    ;;

  hc-version)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec "$H/.local/bin/hc" --version
    ;;

  report)
    # Run one read-only command named in config/macbook-reports.tsv and print its output (stderr merged, 60 s, 64 KB,
    # last line `[exit N]`). Exit 0 whenever the command ran: the caller reads that as "ran", not as the command's verdict.
    [ "$argc" -eq 2 ] || refuse "$verb"
    [[ "${words[1]}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "$verb"
    tsv="$H/SourceRoot/dotfiles/config/macbook-reports.tsv"
    [ -r "$tsv" ] || refuse "$verb"
    cmd=""
    while IFS=$'\t' read -r name rcmd _; do
      case "$name" in '' | '#'*) continue ;; esac
      if [ "$name" = "${words[1]}" ]; then cmd="$rcmd" && break; fi
    done <"$tsv"
    [ -n "$cmd" ] || refuse "$verb"
    log "$verb" allow
    export PATH="$H/.local/bin:/opt/homebrew/bin:/usr/local/bin:$H/.bun/bin:$PATH"
    run_limited "${IUMAC_GATE_REPORT_TIMEOUT:-60}" env HOME="$H" /bin/bash -c "$cmd"
    [ "$LIMITED_NEEDNL" -eq 1 ] && printf '\n'
    printf '[exit %s]\n' "$LIMITED_RC"
    exit 0
    ;;

  repo-pull)
    # Fast-forward one other checkout under ~/SourceRoot over https with no ssh identity (dotfiles is dotfiles-sync).
    # Exit is git's; a refusal of the name or the checkout is 126.
    [ "$argc" -eq 2 ] || refuse "$verb"
    repo="${words[1]}"
    [[ "$repo" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || refuse "$verb"
    case "$repo" in dotfiles | *..*) refuse "$verb" ;; esac
    [ -e "$H/SourceRoot/$repo/.git" ] || refuse "$verb"
    log "$verb" allow
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    # No ssh identity, no agent, no prompt: an ssh remote of github.com is read over https instead.
    export GIT_SSH_COMMAND=/usr/bin/false GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:"
    export GIT_CONFIG_KEY_1="url.https://github.com/.insteadOf" GIT_CONFIG_VALUE_1="ssh://git@github.com/"
    run_limited "${IUMAC_GATE_PULL_TIMEOUT:-300}" "${IUMAC_GATE_GIT:-git}" -C "$H/SourceRoot/$repo" pull --ff-only
    exit "$LIMITED_RC"
    ;;

  rsync)
    # usage-tracker's pull: `rsync --server --sender <opts> . <source>`. Seen
    # from openrsync (macOS /usr/bin/rsync, protocol 29):
    #   rsync --server --sender --delete-before -g -l -o -p -D -r -t --dirs . .claude/projects/
    # and from rsync 3.x: a single bundle such as -logDtpre.iLsfxCIvu. Filters
    # (--include/--exclude) travel over the protocol, not argv.
    [ "$argc" -ge 6 ] || refuse "$verb"
    [ "${words[1]}" = "--server" ] && [ "${words[2]}" = "--sender" ] || refuse "$verb"
    i=3
    while [ "$i" -lt "$argc" ] && [ "${words[$i]}" != "." ]; do
      tok="${words[$i]}"
      case "$tok" in
        --delete | --delete-before | --delete-during | --dirs | --ignore-errors | --numeric-ids) ;;
        --timeout=*) [[ "${tok#--timeout=}" =~ ^[0-9]+$ ]] || refuse "$verb" ;;
        --*) refuse "$verb" ;;
        -*)
          # Short-flag bundle, optionally with rsync 3's `e.<capabilities>`
          # suffix. Letters that take an argument or follow/rewrite paths are
          # refused: L k K (symlink following), T B M f F (argument-taking
          # filters/dirs), C, e (outside the suffix). z (compression) stays:
          # real clients send it with -z and it touches no file.
          flags="$tok"
          suffix=""
          case "$tok" in *e.*) flags="${tok%%e.*}"; suffix="e.${tok#*e.}" ;; esac
          [[ "$flags" =~ ^-[a-zA-Z0-9]+$ ]] || refuse "$verb"
          case "${flags#-}" in *[LkKTBMfFCe]*) refuse "$verb" ;; esac
          if [ -n "$suffix" ]; then [[ "$suffix" =~ ^e\.[A-Za-z0-9]+$ ]] || refuse "$verb"; fi
          ;;
        *) refuse "$verb" ;;
      esac
      i=$((i + 1))
    done
    # exactly: "." then one source path, nothing after
    [ "$((i + 2))" -eq "$argc" ] || refuse "$verb"
    src="${words[$((i + 1))]}"
    SRC_RE='^(\.claude/projects|\.claude/logs|\.codex/sessions(/[0-9]{4}/[0-9]{2})?|\.local/share/usage-tracker)/$'
    [[ "$src" =~ $SRC_RE ]] || refuse "$verb"
    bin="${IUMAC_GATE_RSYNC:-}"
    if [ -z "$bin" ]; then
      if [ -x /usr/bin/rsync ]; then bin=/usr/bin/rsync; else bin=rsync; fi
    fi
    log "$verb" allow
    cd "$H" || exit 1
    exec "$bin" "${words[@]:1}"
    ;;

  *)
    refuse "$verb"
    ;;
esac
