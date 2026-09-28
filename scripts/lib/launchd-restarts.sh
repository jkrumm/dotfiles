#!/usr/bin/env bash
# launchd-restarts — check_launchd_restarts for devhost-health-check.sh.
#
# Sourceable, no side effects on load, bash 3.2 (launchd hands the heartbeat
# Apple's /bin/bash). Reads these globals, every one overridable so the test can
# drive it over a scratch dir and a stubbed launchctl:
#
#   LAUNCHD_KEEPALIVE   label|plist|… rows to watch (the caller builds it)
#   STATE_DIR           where the last `runs` reading per label is remembered
#   LAUNCHCTL_BIN AWK_BIN DATE_BIN
#   DEVHOST_DELIBERATE_RESTART_DIR / DEVHOST_DELIBERATE_RESTART_WINDOW   (below)
#
# THE DELIBERATE-RESTART MARKER CONTRACT. A restart path that bumps `runs` on a
# job it leaves LOADED — `launchctl kickstart -k`, or asking the process to exit
# so KeepAlive respawns it — appends the current epoch to
#
#     ~/.local/state/devhost/deliberate-restart/<label>
#
# right before it restarts:
#
#     d="$HOME/.local/state/devhost/deliberate-restart"; mkdir -p "$d" && date +%s >> "$d/<label>"
#
# Writers today: research-gateway `scripts/mini-deploy.sh` and `make
# launchd-restart` (gateway + lightpanda), sideclaw `make reload`. The writers
# inline that line rather than sourcing this file — a deploy script must not
# depend on a dotfiles checkout path. `bootout` + `bootstrap` (herdr-restart,
# colima-restart, hermes, sideclaw install) needs no marker: a freshly loaded
# job starts again at `runs = 1`, which is never a bump.
#
# One marker line excuses one bump inside the window, and exactly that many
# lines (oldest first) are consumed by the check that evaluates the bump. So a
# service that crash-loops after a deploy still pages: the loop's extra bumps
# outnumber the marker lines, and the next cycle finds none left. A marker
# never excuses a kill, a crash signal or a non-zero exit — only exit 0 or
# SIGTERM. A deploy that restarts into a crashing build therefore pages too. A marker is the only thing a crash
# loop cannot leave behind — which is why this replaced "exit 0 means
# deliberate": a KeepAlive daemon that bails cleanly on missing config also
# exits 0, forever.
DELIBERATE_RESTART_DIR="${DEVHOST_DELIBERATE_RESTART_DIR:-$HOME/.local/state/devhost/deliberate-restart}"
# Two check intervals: the heartbeat runs every 300 s, so a marked restart is
# always seen by the first or second run after it.
DELIBERATE_RESTART_WINDOW="${DEVHOST_DELIBERATE_RESTART_WINDOW:-600}"

# Count marker lines for $1 no older than the window. A timestamp up to 60 s in
# the future still counts (written during this very run); garbage lines don't.
_deliberate_marks() {
  local file="$DELIBERATE_RESTART_DIR/$1"
  [[ -f "$file" ]] || { echo 0; return; }
  # shellcheck disable=SC2016  # $1 is an awk field, not a shell expansion
  "$AWK_BIN" -v now="$2" -v win="$DELIBERATE_RESTART_WINDOW" '
    $1 ~ /^[0-9]+$/ && now - $1 <= win && $1 - now <= 60 { n++ }
    END { print n + 0 }' "$file" 2>/dev/null || echo 0
}

# Drop the $2 oldest fresh lines for $1, keep the rest (a second deploy's
# marker written before its own bump), prune stale ones. temp + mv.
_consume_marks() {
  local file="$DELIBERATE_RESTART_DIR/$1"
  [[ -f "$file" ]] || return 0
  # shellcheck disable=SC2016
  "$AWK_BIN" -v now="$3" -v win="$DELIBERATE_RESTART_WINDOW" '
    $1 ~ /^[0-9]+$/ && now - $1 <= win && $1 - now <= 60 { print $1 }' "$file" 2>/dev/null \
    | /usr/bin/sort -n | /usr/bin/tail -n +"$(( $2 + 1 ))" > "$file.tmp" 2>/dev/null || true
  if [[ -s "$file.tmp" ]]; then
    /bin/mv -f "$file.tmp" "$file" 2>/dev/null || true
  else
    /bin/rm -f "$file.tmp" "$file" 2>/dev/null || true
  fi
}

check_launchd_restarts() {
  # KeepAlive makes a crash-looping service look EXACTLY like a healthy one:
  # launchd restarts it, the port comes back, every liveness check goes green.
  # The evidence is already sitting in `launchctl print` and nothing read it —
  # herdr is at `runs = 2` with `last terminating signal = Killed: 9`, the OOM
  # kill that silently emptied its panes.
  #
  # This is a DELTA, not a threshold on `runs`. `runs` is cumulative since load,
  # so failing on runs > 1 would page forever over an event from weeks ago; the
  # alertable fact is "a service restarted since the last 5-minute check", which
  # for herdr means every pane's processes are gone RIGHT NOW. It pages for one
  # cycle and clears, which is the correct shape for an edge.
  #
  # StartInterval agents (this one included, at runs = 1333) are deliberately
  # absent from the list — `runs` counts scheduled invocations there and would
  # increment every single cycle.
  #
  # TWO THINGS MAKE A RESTART DELIBERATE, and both are report-only:
  #
  #   1. A marker (header contract) covering the whole bump, on exit 0 or
  #      SIGTERM — a marker never launders `Killed: 9`, a crash signal or a
  #      non-zero exit. research-gateway
  #      and sideclaw drain and exit 0 on their own, so their restarts carry no
  #      signal at all — 87 dev-host messages in the 14 days to 2026-09-27, a
  #      third of #alerts, were every research-gateway deploy paging this.
  #   2. `Terminated: 15`. SIGTERM is launchd asking politely, which only ever
  #      happens because a human or a Makefile target asked it to — 40 of the 67
  #      DOWN alerts between 2026-06-14 and 2026-09-07 were `make hermes-restart`
  #      and friends.
  #
  # Everything else pages: `Killed: 9` (jetsam/OOM — the herdr case it was
  # written for), `Abort trap: 6`, `Segmentation fault: 11`, a crash loop that
  # exits non-zero with no signal, and — deliberately — an UNMARKED clean exit 0,
  # because a daemon that bails on missing config looks exactly like that.
  #
  # A deliberate restart is still REPORTED — named in this component's own text
  # and, since a restarted job has runs != 1, again in the `history:` tail.
  local uid state_file now seen="" restarted="" deliberate="" history="" consume=""
  local label plist out runs sig exit_code cause prev marks note n clean
  uid=$(/usr/bin/id -u)
  now=$("$DATE_BIN" +%s)
  state_file="$STATE_DIR/launchd-runs"
  /bin/mkdir -p "$STATE_DIR" 2>/dev/null || true

  while IFS='|' read -r label plist _; do
    [[ -n "$label" ]] || continue
    [[ -f "$plist" ]] || continue
    out=$("$LAUNCHCTL_BIN" print "gui/$uid/$label" 2>/dev/null) || continue
    # shellcheck disable=SC2016  # $2 is an awk field, not a shell expansion
    runs=$("$AWK_BIN" -F' = ' '/^[[:space:]]*runs = /{ print $2; exit }' <<<"$out")
    [[ -n "$runs" ]] || continue
    # shellcheck disable=SC2016
    sig=$("$AWK_BIN" -F' = ' '/^[[:space:]]*last terminating signal = /{ print $2; exit }' <<<"$out")
    # shellcheck disable=SC2016
    exit_code=$("$AWK_BIN" -F' = ' '/^[[:space:]]*last exit code = /{ print $2; exit }' <<<"$out")
    # Why the last exit happened: the signal if there was one, else the exit
    # code — so a clean self-exit reads "exit 0" and a signal-less crash loop
    # "exit 78", instead of both reading as nothing.
    cause="$sig"
    [[ -n "$cause" || -z "$exit_code" ]] || cause="exit ${exit_code}"
    seen="${seen}${label} ${runs}
"
    # Surface a non-clean history even when nothing changed this cycle: a `-9`
    # in the record is the difference between "restarted on purpose" and "was
    # killed", and it belongs in the msg where the diagnosis happens.
    if [[ "$runs" != "1" ]]; then
      history="${history:+$history }${label##*.}=${runs}${cause:+(${cause})}"
    fi
    marks=$(_deliberate_marks "$label" "$now")
    # shellcheck disable=SC2016
    prev=$("$AWK_BIN" -v l="$label" '$1 == l { print $2; exit }' "$state_file" 2>/dev/null) || prev=""
    # No previous reading (first run, or a newly wired service) — seed and move
    # on. Inventing a comparison against zero would page once for every service
    # on the first run after install.
    if [[ -n "$prev" ]] && (( runs > prev )); then
      clean=0
      [[ "$sig" == "Terminated: 15" || ( -z "$sig" && "$exit_code" == "0" ) ]] && clean=1
      if (( marks >= runs - prev && clean )); then
        deliberate="${deliberate:+$deliberate, }${label} restarted (${prev}→${runs}${cause:+, ${cause}} — marked deliberate)"
      elif [[ "$sig" == "Terminated: 15" ]]; then
        deliberate="${deliberate:+$deliberate, }${label} restarted (${prev}→${runs}, SIGTERM — deliberate)"
      else
        note=""
        if (( marks > 0 && ! clean )); then
          note=", marker ignored — not a clean exit"
        elif (( marks > 0 )); then
          note=", only ${marks} marked"
        fi
        restarted="${restarted:+$restarted, }${label} restarted (${prev}→${runs}${cause:+, ${cause}}${note})"
      fi
      # Consumed either way, one line per bump: a marker excuses the bump it was
      # written for, never a later one. Deferred until the new `runs` is
      # persisted — consuming first and dying before the state write would
      # re-see this bump next run with its marker gone, and page it.
      consume="${consume}${label} $(( runs - prev ))
"
    elif (( marks == 0 )); then
      # Nothing fresh left — a marker whose restart never bumped (a kickstart
      # that failed, a bootout path that wrote one anyway) must not linger.
      /bin/rm -f "$DELIBERATE_RESTART_DIR/$label" 2>/dev/null || true
    fi
  done <<<"$LAUNCHD_KEEPALIVE"

  # temp + mv: a torn state file would either re-seed (missing an edge) or
  # compare against garbage (a phantom page).
  if [[ -n "$seen" ]]; then
    { printf '%s' "$seen" > "$state_file.tmp"; } 2>/dev/null \
      && /bin/mv -f "$state_file.tmp" "$state_file" 2>/dev/null \
      && while read -r label n; do
           [[ -z "$label" ]] || _consume_marks "$label" "$n" "$now"
         done <<<"$consume" || true
  fi

  [[ -z "$restarted" ]] || { echo "${restarted}${deliberate:+; also ${deliberate}}"; return 1; }
  echo "no crash restarts${deliberate:+ (${deliberate})}${history:+ (history: $history)}"
}
