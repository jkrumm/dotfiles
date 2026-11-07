#!/bin/bash
# iumac-gate.sh — the forced command behind the mini->iumac key.
#
# config/ssh/authorized_keys.iumac pins this script with `command=`, so every
# connection that key makes lands here with the requested command in
# $SSH_ORIGINAL_COMMAND. The key's job is a short list of named operations
# (reachability probe, human-queue dialogs, notifications, claude re-login,
# account snapshots, usage-tracker pulls); this gate maps each verb to its one
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
# repo, and IUMAC_GATE_RSYNC replaces the rsync binary.
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

ID_RE='^[A-Za-z0-9._-]+$'
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

  ask-push)
    [ "$argc" -eq 2 ] || refuse "$verb"
    [[ "${words[1]}" =~ $ID_RE ]] || refuse "$verb"
    case "${words[1]}" in . | ..) refuse "$verb" ;; esac
    log "$verb" allow
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    exec bash "$H/SourceRoot/dotfiles/scripts/ask-human.sh" push "${words[1]}"
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

  hc-version)
    [ "$argc" -eq 1 ] || refuse "$verb"
    log "$verb" allow
    exec "$H/.local/bin/hc" --version
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
