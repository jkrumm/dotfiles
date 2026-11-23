# Recovery drill

How to tell whether the mini recovered, and how to prove it without breaking it. Four parts: read recovery after any
reboot (read-only), the owner's quiet-window drill (by hand), the scratch-core proof that never touches the production
core (by hand), and the planned restart for a macOS update (`make planned-restart`). Background: `docs/incident-2026-11-13-mini-panic.md` (the standing constraint), `docs/herdr-core.md`
§Resume pacing, `docs/devhost-health.md` §Recovery after a boot.

**Who runs what.** Part 1 only reads; anyone, agent or owner, can run it. Parts 2 and 3 contain commands that stop or start
a core. `hooks/herdr-core-guard.ts` denies them to every Claude session (also inside `ssh`, `bash -c`, `hc run`), so no
agent runs them and no agent should try to get round the guard. The owner runs them, and the result is a measured line
pasted back, never a claim.

## 1. After any reboot (read-only)

Recovery is **measured, not assumed**: terminals with a resumable session versus terminals running `claude` again. Read in
this order; each step answers a question the next one depends on.

| # | Read | Answers |
|-|-|-|
| 1 | The pushes (ntfy) | Did the mini notice, and how long was it gone |
| 2 | `make recovery-check` | Did every Claude terminal come back |
| 3 | `~/Library/Logs/hc-resume.log` | If not, what hc-resume did and when |
| 4 | `~/Library/Logs/devhost-snapshots.jsonl` | What the host looked like while it recovered |

**1. The pushes.** Two independent signals, in this order for an unplanned reboot:

- `MacMini Door - HTTP` goes DOWN about 3 to 4 minutes after the mini stops answering (interval 60 s, two retries at 60 s;
  homelab `uptime-kuma/monitors.yaml`), straight to ntfy, then UP when the door answers again. It says "unreachable". A
  planned reboot pages it once too. An outage shorter than about 3 minutes pages nobody; that is what the next push is for.
- The reboot push (topic `alerts`, high priority): the first heartbeat after boot sends the panic headline, the boot time and
  the **time to ready**, the seconds from boot to the first heartbeat that found tailnet, sshd and the core alive (`not ready`
  plus the failing check when one is down). It arrives after the mini is back and says "rebooted". Once per panic report,
  also for a planned reboot that left a report.

The Dev Host push monitors (interval 600 s, one retry) are not the fast path: they need about 20 minutes to reach DOWN.

**2. `make recovery-check`.** Read-only, safe at any time; it never starts a core (`lib/core-up.sh` first, one bounded
`terminal.list`). One line:

```
recovery: 25 resumable, 25 running claude, 0 waiting, 0 skipped
```

That is the live line from 2026-11-14, a full recovery. After the 2026-11-13 panic, five minutes after boot, it read
10 running and the rest still queued.

| Number | Meaning | If it is not 0 for long |
|-|-|-|
| resumable | kept terminals labelled `jk.claude.session`: what hc-resume may bring back | the denominator, never a problem on its own |
| running claude | resumable whose foreground is `claude` | the goal: `running = resumable` |
| waiting | resumable, at a login shell: not typed into yet, or typed and Claude still loading | hc-resume is slow or stuck: step 3 |
| skipped | resumable, foreground unknown or another program: hc-resume never types into those | read the `skipped` reason in `--json` |

running + waiting + skipped = resumable. `make recovery-check ARGS=--json` adds per terminal hc-resume's verdict since boot
(`sent` with a time, `skipped` or `failed` with a reason). A terminal closed on purpose keeps its label and counts as
waiting, so a lone `waiting` can be a false alarm; one with verdict `sent` was typed and is loading, one with no verdict is
still in the queue.

**Expected curve** (defaults, 3 in flight, 3 s apart, tailnet wait up to 120 s): with tailnet up at T, `waiting` falls by
one every 3 s, the last send is typed at about T + 75 s for 25 sessions, and `running = resumable` about 2 to 3 minutes
after tailnet-up. Short at 10 minutes is a finding. The heartbeat WARNs from there on (never FAIL, never DOWN), names the
waiting count, files one factory signal per boot when any terminal waits, and stops measuring 45 minutes after boot. hc-resume
re-reads the roster every 15 s for 10 minutes after it connects (`docs/herdr-core.md` §Rescan), so a terminal whose
foreground was unknown in the first snapshot is resumed by a later read; if `waiting` stays anyway, the log says why.

**3. `hc-resume.log`** (UTC). The lines that carry the curve:

```
rg -n 'hc-resume started|pacing:|tailnet|no core|resume ' ~/Library/Logs/hc-resume.log | tail -60
```

| Line | Reads as |
|-|-|
| `hc-resume started pid=…` then `pacing: max 3 in flight, 3000 ms apart, tailnet wait 120000 ms` | boot of the job; the pacing in force |
| `tailnet up after N ms` / `tailnet not up after … ms: resuming anyway` | the gate: N is the tailnet's own time, not ours |
| `no core: …` | hc-resume refused a stray or a missing core and retries; nothing is typed until a launchd-born core answers |
| `resume <addr> <session> (<account>)` | one send; consecutive stamps should be about 3 s apart, never more than 3 within a window of 3 s |
| `resume <addr> failed: …`, `skip <addr>: …` | the per-terminal reason; a skip is logged once per terminal and reason (`foreground unknown`, `foreground is <program>`, `live <app> session (agent status)`), and a terminal whose foreground was unknown is read again by the rescan |
| `rescan failed: …`, `rescan done after N s: …` | a failed `terminal.list` (first of a streak); the rescan ended because every resumable terminal is running or skipped on purpose |
| `stream ended (core restart?), reconnecting` | the core's stream ended, **or hc-resume was restarted by a deploy** (`docs/herdr-core.md` §Core restarts, classified); a real core restart is followed by `no core:` or `resume` lines, never by a new pid |

**4. `devhost-snapshots.jsonl`** (UTC, one line per 5-minute heartbeat plus the recovery line while the host is under 45
minutes old):

```
jq -c 'select(.recovery) | [.ts, .up_s, .tailnet_up_s, .recovery.running, .recovery.resumable]' ~/Library/Logs/devhost-snapshots.jsonl | tail -12
jq -c '[.ts, .load[0], .pressure, .swap_used_mb, .top_rss[0].cmd]' ~/Library/Logs/devhost-snapshots.jsonl | tail -12
```

The first is the curve per 5 minutes; the second shows load and memory pressure while it ran. The incident's reference
points: load 175 then 404 with 25 starts in 9 ms, sshd and tailscale reachable only after about 7.5 minutes. Paced, nothing
should look like that; load staying below 30 is the line where heartbeat components started timing out (issue 832).

A planned reboot through `make mini-macos-update` also leaves `~/Library/Logs/herdr-core-resume-pre-reboot-<stamp>.tsv`:
one line per labelled terminal. After the reboot the tsv is the list the curve must reach.

**What the answer is.**

| Finding | Next |
|-|-|
| `running = resumable` within 3 minutes of tailnet-up | recovered; record the line and the time to ready |
| `waiting` falls but slowly, resumes spaced further apart than 3 s | load: read step 4, the swap and the top process |
| `waiting` stays, log shows `no core:` | a stray or missing core: `make herdr-core-status` (responsibility), then `docs/herdr-core.md` §Strays; the repair is the owner's |
| `skipped` stays | a foreground other than a shell: `ARGS=--json` names the reason |
| `resumable` lower than the tsv or the earlier count | labels were cleared (a deliberate exit) or terminals were lost with the holder; compare with `hc ls` |

## 2. The owner's drill, in a quiet window (by hand)

**What it proves, and what it does not.** It stops the production core and starts it again through launchd. Every program
in every terminal ends, every terminal comes back as a shell, and `hc-resume` has to bring the Claude sessions back: the
same path as 2026-11-13 18:09 (25 resumes) and 2026-11-13 07:02 (18 of 18), with the host staying up. It does **not**
exercise boot ordering, the tailnet gate under real load, or the reboot push. Those have only the next real reboot as
proof. It is not run to prove a change; it is run once to get a measured curve for the paced hc-resume, and again after a
change near the core only if the owner chooses.

**Preconditions.** All of them, or it waits.

- The Data volume is under 85% used: `df -h /System/Volumes/Data` (swapfiles need headroom; the panic ran at 94%).
- No factory lead and no agent mid-turn: `hc ls` shows no terminal `working`, and the factory's queue holds nothing live.
  The drill ends every program, so a turn in flight is lost, and so is its uncommitted work. Park or commit first.
- The MacBook's Herdr app is quit. Its machine link reconnects at once over a persistent ssh master and wins the race
  against launchd, which brought the core up as a stray on 2026-11-13 (`docs/herdr-core.md` §How the core runs now).
- A baseline: `make recovery-check` reads `N resumable, N running claude, 0 waiting, 0 skipped` and `make herdr-core-status`
  says `core_up: yes`. If the baseline is not clean the drill measures nothing.
- A time chosen, and the owner at the mini's screen or on ssh from another machine, not from inside Herdr.
- The start epoch written down: `date +%s`.

**The one command.** In a terminal outside Herdr (Terminal.app on the mini's screen; a Herdr terminal would end with the
stop), and with no other `hc` call in between, because any `hc` call while no core answers starts one:

```
hc server stop && launchctl kickstart gui/$(id -u)/com.jkrumm.herdr-core
```

The first half ends the core and replaces the holders. The second starts it launchd-born. `hc-resume` logs `no core:`
until it answers, then resumes.

**What to read afterwards**, with `<epoch>` the value of `date +%s` taken before:

```
make herdr-core-status
make recovery-check ARGS="--since <epoch>"
rg -n 'no core|resume |skip |failed' ~/Library/Logs/hc-resume.log | tail -60
jq -c '[.ts, .load[0], .pressure, .swap_used_mb]' ~/Library/Logs/devhost-snapshots.jsonl | tail -8
```

Watch a second terminal from another machine, `ssh mini true` every few seconds, and note whether any attempt takes more
than 5 s: that is the sshd-and-tailscale reachability the pacing was built for.

**Pass.** Every line holds:

- `core_up: yes` and the responsibility check clean (no stray) within 60 s of the kickstart.
- `recovery: N resumable, N running claude, 0 waiting, 0 skipped` within 5 minutes of the core answering (design: about 3).
- The `resume` lines are spaced about 3 s apart, at most 3 in flight; none `failed`; every `skip` has a reason that holds.
- `ssh mini true` answered inside 5 s at every attempt, and load stayed below 30 in the snapshots.

**Not a pass, and what it is.** A stray (`core_up: NO`) is a finding about the start path, not about hc-resume: the repair
is `hc server restart`, which kept all programs on 2026-11-13 and whether it also cures a core born as a stray is untested.
Running short at 10 minutes is a finding about hc-resume. Either way the result is the line plus the log excerpt, and a
signal on this repo.

**Rollback.** Nothing to revert; the drill changes no file. If the core does not come back, `launchctl kickstart
gui/$(id -u)/com.jkrumm.herdr-core` again, then `docs/herdr-core.md` §Strays. Terminals the drill left as shells resume by
hand: `claude --resume <id>` from the label (`hc get <t>`).

**The result.** The owner pastes back the measured lines (`recovery-check` before and after, the first and last `resume` stamp,
the peak `load[0]`, the longest `ssh` answer) as a comment on the Issue or a note, and the first measured run replaces the
design estimate in `docs/herdr-core.md` §Resume pacing.

## 3. The scratch-core proof (by hand, never touches production)

Proves hc-resume's logic (queue, pacing, one send per terminal and session, resume after a lost program) on a throwaway
core with its own `HC_SESSION` and `XDG_*` paths. The production socket, state and holders are not involved, which is why
it is safe to repeat. The recipe is the Wave 3 one (`docs/herdr-core.md` §Verified facts, item 10), run by the owner
because `hc server` and `hc connect` are exactly what the guard denies an agent.

```
export HC_SESSION=drill1
export D=/tmp/hcs-drill1
mkdir -p $D/{config,data,state,cache}
export XDG_CONFIG_HOME=$D/config XDG_DATA_HOME=$D/data XDG_STATE_HOME=$D/state XDG_CACHE_HOME=$D/cache
cd ~/SourceRoot/dotfiles
```

**Check it is not production** before anything else: `hc server status --json` must show a socket and pid different from
`make herdr-core-status`. If it shows the same socket, stop; do not continue.

```
# a stand-in for a Claude terminal: labelled like a session, then idle
hc run --bg --keep --name standin sh -c \
  'printf %s "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"0d6f3a52-drill\"}" \
   | CLAUDE_CONFIG_DIR=$D/cfgdir bun hooks/hc-session-label.ts; exec sleep 600'
hc get standin   # labels jk.claude.session and jk.claude.config are present

# hc-resume against the scratch core, tailnet gate off, log to a file
HC_RESUME_TAILNET_WAIT_MS=0 bun scripts/hc-resume.ts > $D/resume.log 2>&1 &
echo $! > $D/resume.pid
```

Then lose the program: `kill -9 <pid of the sleep>` (`hc get standin` names it). Read `$D/resume.log`:

| Expect | Shows |
|-|-|
| `pacing: max 3 in flight, 3000 ms apart, tailnet wait 0 ms` | the knobs in force |
| one `resume <addr> 0d6f3a52-drill (…)` | the send |
| `hc read standin` | `env CLAUDE_CONFIG_DIR='…/cfgdir' claude --dangerously-skip-permissions --resume 0d6f3a52-drill` typed at the prompt |
| a second `kill -9` of that process | **no** second send: one attempt per terminal and session id |

For the pacing, label 6 stand-ins the same way with distinct session ids, lose all 6 programs at once, and read the
stamps: starts 3 s apart, never more than 3 in flight. Set `HC_RESUME_STAGGER_MS` and `HC_RESUME_MAX_INFLIGHT` on the
`bun scripts/hc-resume.ts` line to see other values take effect.

**Teardown**, in the same shell (so `HC_SESSION` still points at the scratch core): `kill $(cat $D/resume.pid)`, then
`hc server stop`, then `rm -r $D`. If the shell was closed, do not run `hc server stop` from a new one before exporting
`HC_SESSION=drill1` again: without it the command stops the production core.

**Pass.** One send per lost program, the typed line is exactly the documented one, paced as above, scratch core gone and
`make herdr-core-status` unchanged (same pid as before).

The automated counterpart is `scripts/hc-resume.test.ts` (hermetic, in `make check`); this drill adds the live core and the
real shell.

## 4. A planned restart (macOS update or maintenance): `make planned-restart`

Automatic macOS install is off (`docs/devhost-health.md` §Update policy), so a pending update waits for this, run by the owner
from the MacBook in a quiet hour. On 2026-11-15 an unplanned install restarted the mini at 01:11 with 12 leads working and
11 sessions stayed down for seven hours; this is the same restart with the leads told and the queue held.

```
DRY_RUN=1 make planned-restart     # prints every step with its command and runs nothing
make planned-restart               # TTY prompt, or YES=1
REASON=maintenance make planned-restart   # a plain reboot with no macOS update pending
```

`REASON=maintenance` is the way to reboot the mini after brew, cask, Safari or Tailscale upgrades: steps 1-3 and 5-6 are unchanged, step 0 no longer needs a pending update, and step 4 is `scripts/mini-reboot.sh` in place of the macOS applier. Without it a run with nothing pending exits 0 at step 0 and reboots nothing.

| Step | What it does | If it fails |
|-|-|-|
| 0 | MacBook only (backend `op`), mini reachable, an update actually pending (else exit 0, nothing drained) | stops, nothing changed |
| 1 | `factory queue set drain`: no Issue is admitted | refused = stop; an unannounced restart is the incident |
| 2 | `factory session note` to every non-idle lead: the time, "commit and push, start no merge or deploy, you are resumed afterwards"; then 5 min (`PLANNED_RESTART_GRACE`) | a failed note is named, the run goes on |
| 3 | for every project of the queue, `factory merge-lock` then `factory deploy-lock` with `-- true`: returns when the running window has ended (up to 90 min each) | a lock that does not free stops the run and puts the queue back to run |
| 4 | `scripts/mini-macos-update.sh` (YES=1): snapshot of the resume labels, installs, waits down and up, asserts the version moved. `REASON=maintenance`: `scripts/mini-reboot.sh` (YES=1): the same snapshot (`scripts/lib/resume-snapshot.sh`), an op-fed `sudo -S shutdown -r +0`, waits down and up, asserts the boot time moved | the queue **stays drained** and the output says so; the applier's header owns the "never force a reboot" rule |
| 5 | polls `make recovery-check ARGS=--json` on the mini until `waiting` is 0 (hc-resume is paced; up to 45 min) | the queue stays drained; read §1 |
| 6 | `factory queue set run` | the line to run by hand is printed |

A failure before step 4 undrains the queue (nothing happened); from step 4 on it never does, because a half-restarted host with
leads running into it is worse than a held queue. Not run by an agent: it reboots the host every agent runs on, and a lead's
own session is one of the terminals it ends. A pending update past 14 days stays a `waiting for a restart window` line in the drift report: no signal, no page, never a nightly install.
