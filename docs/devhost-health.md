# Dev-host health heartbeat and upstream drift (mini only)

The full rationale behind the two monitoring surfaces on the mini. Commands and
one-line gotchas live in `AGENTS.md`.

## The heartbeat

`scripts/devhost-health-check.sh` runs every 300 s via the
`com.jkrumm.devhost-health` LaunchAgent, wrapped in `jobrun` (below), and pushes **three** Uptime Kuma
monitors. `MacMini Dev Host - Push` is the **liveness** monitor: it says the mini is reachable and its core is alive,
never "healthy" and never "slow" (next section). The **eighteen** components below (sshd moved to the liveness phase) grade the host's health and ride
a second push:

| Component | Checks |
|-|-|
| tailscale | daemon state + node-key expiry days |
| sshd | listener present (graded in the liveness phase, not repeated here) |
| core | the herdr-core (`scripts/lib/core-health.sh`, shared with `doctor.sh`): `scripts/lib/core-up.sh` (the default socket answers AND a launchd-born core exists, `herdr-core --hc-launchd` with parent pid 1), then `hc server status` — **FAIL** when `core_up` is false (message = why + fix; a core that answers without being launchd-born is a stray, attributed to sshd with no keychain) or `hc` does not answer, **WARN** when `scripts/hc-responsible.py` finds the core or a holder not attributed to `Herdr Core.app` (old Cellar holders stay until their terminals end) or the other machine's core version differs (`hc machine ls`, else `ssh <peer-host> hc --version` cached 30 min; an unreachable laptop is not a fault). Never starts anything: `core_up` (bare socket connect + `ps`) comes first, because any `hc` call auto-starts a stray core; `make herdr-core-test` |
| git push credential | `op://mini/github/token` resolves (no network call) |
| dev vhosts | Cloudflare DNS module, wildcard cert days-left, DNS A-record drift, token/include permissions |
| memory | pressure level + swap as a share of RAM: **WARN** above `DEVHOST_MEM_SWAP_PCT_MAX` (25 %, justified in [Memory budget](#memory-budget-issue-1035)), **FAIL** above `DEVHOST_MEM_SWAP_PCT_FAIL` (75 %) or at pressure critical. Swap does not drain when its cause is gone (2026-11-07: 28 % stayed parked for hours after the leak was killed, DOWN with 0 swapouts), so the share alone pages only at leak size; the rate is `swapouts`. Also names `fseventsd` (`top` MEM, compressed pages included, no root; `ps` RSS shows 4.7G for 61G) above `DEVHOST_FSEVENTSD_MAX_MB` (10 GiB) as a WARN |
| swapouts | cumulative `vm.compressor.swapper.swapouts_total` → MiB/300s delta — **FAIL** past `DEVHOST_SWAPOUT_MB_PER_300S_MAX` (2 GiB); a state write that fails **FAILs** too, never a silent re-seed |
| kernel panics | newest `panic-*.panic` / `panic-*.ips` (`panic-full-…` and the watchdog form `panic-base+socd-…`) / `Kernel-*.panic` / `Kernel_*.panic` in `/Library/Logs/DiagnosticReports` younger than `DEVHOST_PANIC_MAX_AGE_DAYS` (3) — **WARN**, never FAIL. The message carries the panic headline (the `panicString` before its first newline, without the `panic(cpu N caller 0x…):` prefix), e.g. `kernel panic 0d ago: watchdog timeout: no checkins from watchdogd in 94 seconds (…) (autorestart recovered, report panic-full-….panic)`. The reboot push below is the alert |
| launchd restarts | delta on `runs` for every KeepAlive job, **excluding a marked restart and `Terminated: 15`** (both deliberate) |
| boot path | plist on disk + `launchctl print` path match for every KeepAlive job (brew services resolved under either name — `homebrew.mxcl.<x>` / `sh.brew.<x>`, see `scripts/lib/brew-service.sh`) |
| services | hermes gateway, colima, caddy, dnsmasq, postgres, the Kuma door (`:8795/healthz`) — each gated on its plist. agent-workflows (host + audio), brain-web and walkingpad are **not** probed here: Kuma pulls them through the door (`kuma-door/registry.json`), so a second probe would be a duplicate signal. The audio-vs-host version-mismatch comparison went with the probe on purpose: the door proves liveness only, and agent-workflows' own `make verify` covers release parity |
| claude auth | keychain credential, then the token fallback |
| claude version | `claude --version` matches the last version `make claude-accounts-verify` verified — **WARN** when unverified |
| AGENTS.md flag | the cached GrowthBook flag `tengu_agents_md_mod` in `~/.claude.json` is true (else Claude Code may not load AGENTS.md) — **WARN** |
| obsidian | CLI answers (i.e. the app is running) |
| disk | used % under the ceiling (93) **and** free space above the floor (20G) — the ceiling is not raised to follow the volume's band (81-84% used at the oldest rotated log entries, 90% on 2026-10-10, 92-94% now), because that would hide a genuinely near-full disk; the floor guards a small volume |
| runaways | report-only CPU-time reaper |
| jobs | `jobs-grade` over the `jobrun` state dir (`~/.local/state/jobs`) — any `failing`/`stale`/`flapping`/`unloaded` label is a **WARN**, never FAIL. A job not ok for 2 consecutive grades is filed as a **signal on its owner repo** through the factory (`jobs-grade --report`, below), not posted to ntfy; a grader that cannot run is a WARN too. `jobs ok (0)` until jobs are wrapped |
| quota | both Claude accounts from the picker's cache (`claude-account usage --json`; falls back to `agw quota`), appended (`quota iu 5h 8% · 7d 88% \| me 5h 3% · 7d 12%`); **WARN** at 5 h ≥ 90 % on the interactive account, or a sample older than 6 h |

A component exits 0 (healthy), 2 (WARN — named in the msg, no streak, never a
page) or anything else (FAIL — subject to the boot grace and streak rules below).

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, and prints the runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

### Liveness first, detail second (issue 870)

`MacMini Dev Host - Push` paged DOWN nine times in 48 h (2026-11-10..12) and not once because the mini was dead: each time the
host was swap-thrashing (swapouts 5 GB per 300 s, load 200+, fseventsd at 260 % CPU) and the slow components (`check_core` 40 s,
the factory relay 20 s, the spent budget) delayed or lost the single push that used to sit at the END of the run. The monitor
now means *the mini is unreachable or its core is dead*. The run is ordered:

1. **Dead-machine checks**, each bounded at `DEVHOST_LIVENESS_STEP_TIMEOUT` (5 s, ~15 s in all): tailnet `Running` (from the
   snapshot, itself bounded at 5 s), sshd listening, herdr-core socket answering (`core_up`, a bare connect plus `ps`; no
   `hc` call).
2. **The liveness push, at once.** `up` with the check notes, or `down` (`dead machine: …`) when a check *definitely* fails.
   Transient tolerance is unchanged (`DEVHOST_TRANSIENT_FAILS` runs in a row, never inside the boot grace). A check that
   merely **timed out** is "slow, not proven dead": it stays `up` as WARN text until `DEVHOST_LIVENESS_TIMEOUT_STREAK` (6)
   timeouts in a row. Measured by the test suite: the liveness push lands about 1 s after the start while a component
   hangs for 6 s.
3. **Side monitors**, then the **slow components** (the nineteen), unchanged and still bounded and budgeted.
4. **The detail push.** The main monitor gets a second `up` with the full summary: a component FAIL is WARN text there and
   never turns it DOWN, and a liveness DOWN is never overwritten. The component verdict goes to the optional **detail
   monitor** (`MacMini Dev Host Detail - Push`, URL file `~/.config/uptime-kuma/devhost-detail-push-url`, opt-in like collie:
   no file, no push): its DOWN is what the factory door routes to a lead, so a full disk or a dead login reaches a
   repo, not the owner's phone. The monitor is made in homelab (`make uk-sync`); the file is written once the monitor exists.

### Forensics: the rolling snapshot and the panic push (issue 1034)

2026-11-13 the mini kernel-panicked (`watchdog timeout: no checkins from watchdogd in 94 seconds`); the report named no
culprit, nothing had recorded what ran, and nobody was told (`docs/incident-2026-11-13-mini-panic.md`). Code:
`scripts/lib/devhost-forensics.sh`, run right after the liveness push so neither can delay it.

- **Snapshot.** Every run appends one compact JSON line to `~/Library/Logs/devhost-snapshots.jsonl`
  (`DEVHOST_SNAPSHOT_LOG`; never `/tmp`): `ts`, `up_s`, `load` (1/5/15 min), `pressure` (the kernel's 1/2/4), `swap_used_mb`,
  `swapfiles` (count in `/private/var/vm`), `free_pages` (`vm_stat`), `disk_free_gb` (the Data volume), `procs`, the counts
  `claude`, `node`, `virtualization`, and `top_rss` / `top_cpu`, the top 8 processes each as `{cmd, pid, rss_mb | cpu}`
  (command basename). About 2.5 KB a line, ~720 KB a day. Four tools (`sysctl`, `vm_stat`, `ps`, `df`), each bounded
  at `DEVHOST_SNAPSHOT_TOOL_TIMEOUT` (5 s); a tool that fails leaves its fields `null`/empty, never the run. Skipped when the
  liveness phase already used `DEVHOST_SNAPSHOT_START_LIMIT` (100 s). `scripts/log-rotate.sh` caps it (16 MB, one `.1`
  generation: about three weeks each). Read the minutes before a hang with
  `jq -c '[.ts,.load[0],.pressure,.swap_used_mb,.top_rss[0].cmd]' ~/Library/Logs/devhost-snapshots.jsonl | tail`.
- **Reboot / panic push.** The first heartbeat that sees a panic report it has not announced (younger than
  `DEVHOST_PANIC_MAX_AGE_DAYS`) sends **one ntfy push** (topic `alerts`, priority high, `DEVHOST_PANIC_NTFY_TOPIC`) with the
  headline, the boot time and the time to ready (seconds from boot to the first heartbeat that found tailnet, sshd and the
  core alive; "not ready" plus the failing check when one is down). Once per panic *report*: `<mtime> <name>` of the announced
  report is stored in `~/.local/state/devhost-health/panic-notified` after a delivered push; a failed push stores nothing and
  the next run retries until the age window ends. The bearer comes from the secrets cache, the server from the homelab ntfy
  config (`NTFY_URL` overrides, as in `jobs-grade`). Tested through `DEVHOST_DIAGNOSTIC_REPORTS_DIR` (a fixture report) and
  `DEVHOST_TEST_UPTIME_S`; never panic the host to test.
- **Why a push at all.** The Dev Host monitor (interval 600 s, 1 retry, ntfy on DOWN) is PENDING after one missed push and
  DOWN only after a second: **an outage shorter than 10 minutes never reaches DOWN**, and a panic that recovers by itself
  (autorestart) is exactly that. The reboot push is the alert for it. The monitor intervals live in the homelab repo and are
  unchanged here.

### Recovery after a boot (issue 1126)

After the 2026-11-13 panic reboot hc-resume typed 25 resumes and five minutes later only 10 terminals showed as
`claude-code`; nothing computed "resumable versus running". `scripts/recovery-check.sh` does, read-only:
`make recovery-check` prints one line, `make recovery-check ARGS=--json` the per-terminal rows.

```
recovery: 25 resumable, 10 running claude, 12 waiting, 3 skipped
```

| Number | Counts |
|-|-|
| resumable | live terminals, kept, labelled `jk.claude.session`: what hc-resume may bring back |
| running claude | resumable whose foreground is `claude` (or whose agent reported itself, hc-resume's own live-agent rule) |
| waiting | resumable, not running, foreground positively a login shell: not typed into yet, or typed and Claude is still loading |
| skipped | the rest: foreground unknown or another program, which hc-resume never types into |

running + waiting + skipped = resumable. The JSON adds, per terminal, hc-resume's last verdict since boot from
`~/Library/Logs/hc-resume.log`: `sent` (at), `skipped` or `failed` (with the reason). A waiting terminal with verdict
`sent` was typed and Claude has not started yet; one with no verdict is still in hc-resume's queue.

**Expected curve** (defaults, `docs/herdr-core.md` §Resume pacing): tailnet up at T; `waiting` falls by one every 3 s (three
in flight), the last send is typed about T + 75 s for 25 sessions, `running` follows each send by Claude's own start time,
so `running = resumable` about 2 to 3 minutes after tailnet-up. Still short at 10 minutes: read the `failed` and `skipped`
reasons, then the pacing lines in the log.

**In the heartbeat.** `check_core` runs the sub-check only while the host booted less than 45 minutes ago
(`DEVHOST_RECOVERY_WINDOW_S`, 2700): the line is appended to the core detail, and the counts go to
`~/Library/Logs/devhost-snapshots.jsonl` as `{ts, up_s, tailnet_up_s, recovery: {resumable, running, waiting, skipped, sent}}`
(`jq -c 'select(.recovery) | [.ts,.recovery]' ~/Library/Logs/devhost-snapshots.jsonl`: the curve per 5-minute run). From 10
minutes after the heartbeat first saw the tailnet Running (`DEVHOST_RECOVERY_WARN_AFTER_S`, stamp
`~/.local/state/devhost-health/tailnet-up-at`) it adds a **WARN** when running is below resumable: never a FAIL, never a
DOWN. A terminal someone closed on purpose stays labelled and counts as waiting, so the WARN can outlast a real recovery;
the window ends it. `DEVHOST_RECOVERY=0` turns the sub-check off. It never runs when no launchd-born core answers
(`lib/core-up.sh` first, so `hc` never starts a core) and its one `terminal.list` over `hc connect` is bounded at 5 s.
Rollback: revert the commit; nothing else depends on it.

### Job failures reach a lead, not the owner (`jobs-grade --report`)

`jobs-grade --summary --report` (run in the `jobs` component) replaced `--ntfy`. A job not ok for **2 consecutive grades**
(the heartbeat grades every 5 min) files `factory signal file --from agent:dotfiles --repo <owner>` with one stable title per
job (`Background job <label> needs a fix`, so a repeat amends the same item) and the run tail in the text. A job is reported
**at most once per 24 h**, so a flapping job costs one signal a day; recovery sends nothing. ntfy topic `alerts` is only
the fallback when `factory` cannot be reached, at priority 3, also at most once a day per job, and the factory is retried
every tick. State: `~/.local/state/jobs-grade/report.json` (`JOBS_GRADE_REPORT_STATE`).

**One hung tool fails only its own component.** On 2026-11-06 `obsidian version` hung
~28 h inside the script; launchd never starts a second instance of a running job, so the
one pusher behind three monitors froze and all three went DOWN. Now:

- Every component, and every side-monitor detail, runs through `run_bounded <secs> <cmd>`:
  a background subshell in its **own process group** with stdout captured to a temp file under
  the state dir. Past the deadline the whole group gets `TERM`, 3 s later `KILL`
  (`kill -- -<pgid>`, never a pattern kill), and the component reports
  `<name> timed out after <secs>s (hung tool; killed)` (rc 124). That is an ordinary FAIL, with
  the same boot-grace and streak rules as any other. A normal finish leaves no watchdog behind
  (the parent polls). The eager `tailscale status` snapshot at load is bounded the same way.
- `DEVHOST_COMPONENT_TIMEOUT` (default 40 s) bounds one component, except `check_claude_auth`, which has
  `DEVHOST_CLAUDE_AUTH_TIMEOUT` (default 100 s): it cold-starts the claude binary once per account plus the expiry
  helper, and under sustained host load (load average ~30, swap parked) that outran 40 s — 56 timeouts on
  2026-11-10/11, nine in a row at 19:07-19:43Z paged the composite DOWN (issue 832) while every probe answered in
  well under a second by hand. A component that takes `DEVHOST_SLOW_COMPONENT_LOG` (15 s) or more is logged to
  stderr (`slow component: <name> took Ns`), so a repeat is attributable from `~/Library/Logs/devhost-health.log`.
  The widening did not end the pages (issue 840, 2026-11-11: nine more 100 s runs, every probe 0.1 s by hand), so the
  hang is a single stuck `claude auth status` / `secrets-run` / `claude-account expiry` call, not load. Each of those
  probes now has its own bound (`CLAUDE_PROBE_TIMEOUT`, 20 s, `claude_bounded` in `scripts/lib/claude-auth-check.sh`:
  own process group, group KILL, the group's `ps` rows written to the local log before the kill). A hung probe is **no
  verdict**, not a dead login: WARN naming the account (`claude auth status hung … for <id> — no verdict`), never a page
  by itself; the other accounts are still graded. A dead login still answers (and FAILs as before).
  `DEVHOST_HEARTBEAT_BUDGET`
  (default 200 s, measured from script start, so the snapshot and side monitors count) bounds the
  composite loop, and each component gets at most the budget that is left. Once it is spent the remaining components are not run: each contributes
  `FAIL: <component> not run (heartbeat budget spent)` through the normal grading, so the
  composite push is always reached. Side monitors: `DEVHOST_SIDE_MONITOR_TIMEOUT` (20 s).
- **Order:** the liveness push first (above), then the three side monitors (collie, factory, secrets freshness), each
  independently, then the component loop, then the detail push. A component hang can starve neither.
- **Under `jobrun`** (`--every 300 --timeout 270`, owner `dotfiles`; state
  `~/.local/state/jobs/com.jkrumm.devhost-health.json`, removed by `make devhost-health-teardown`):
  a non-zero exit is a recorded job failure that `jobs-grade --report` files as a signal on this repo. So the script exits
  **0 whenever every Kuma push was delivered** (a DOWN verdict is a delivered state, and Kuma
  alerts on it) and **1 only when a push failed or no push URL resolved**. `kuma_push` (`scripts/lib/kuma-push.sh`)
  retries a transport failure (curl timeout, refused, reset; never an HTTP error) once, and only once per run: a single
  stalled Kuma push used to fail the whole job, and a dead Kuma must not double every push.
- `DEVHOST_COMPONENTS` replaces the component list (space-separated function names); it exists
  for `make devhost-heartbeat-test`, which drives the timeout, budget, order and exit paths
  against a stub `curl`.

**It is a bash 3.2 script and must stay one.** The plist sets a `PATH` only so `jobrun` finds
bun, with the system dirs **first** (`/usr/bin:/bin:/usr/sbin:/sbin:~/.local/bin:/opt/homebrew/bin:/usr/local/bin`),
so `/usr/bin/env bash` is still
Apple's 3.2 — no `mapfile`, no `${var,,}`, no `"${arr[@]}"` on a possibly-empty
array under `set -u`, which is why checks accumulate into newline-delimited
strings. A `brew install bash` would make the interactive run silently start
accepting constructs launchd will fail on.

**Push for the composite and the jobs, pull for service health.** The ACL grants
`tag:homelab → tag:vps` but *not* `tag:homelab → tag:mac`, so Kuma cannot reach
the mini in general, and an open inbound grant would be new attack surface for
checks the mini can run itself. The composite and every job therefore still push.
Service health is the one exception: Kuma pulls it through the **Kuma door**
(`kuma-door/`, `127.0.0.1:8795`), a single narrow grant `tag:homelab →
tag:devhost` on `tcp:8795` plus a `tailscale serve` row for `8795` (both in
dotfiles-private). The door is GET-only and relays only the loopback URLs listed
in `kuma-door/registry.json` as `GET /h/<name>` — status code through, body capped
at 4 KiB, no part of the request forwarded — so the grant exposes health answers,
not the services. Kuma's monitors are generated from the same registry
(`make kuma-door-gen`), so a service is added in one place. The door's own
liveness (`/healthz`) is graded by the `services` component, so a dead door pages
from the push side even though Kuma sees it as every service down at once.

**One monitor, not thirteen.** tailscale/sshd/the core fail together when the mini
sleeps or drops off the tailnet, so separate monitors would be simultaneous pages
saying one thing; the failing component is named in the push `msg`, where the
diagnosis belongs. The rest are deliberate exceptions — a token expires, `brew
upgrade caddy` reverts a DNS module, a service crash-loops, a disk fills, all on
an otherwise healthy host — folded in anyway, because a dedicated Kuma monitor is
worth less than one more named component in the `msg`.

**The line that holds is absence, not independence.** A component that can be
legitimately *missing* on a good machine gets its own monitor, since folding it
in would page "dev host DOWN" for a feature this host lacks — collie and secrets
freshness. Merely *independent* components stay in the composite and SKIP when
unconfigured: `check_dev_vhosts` without `DEV_DOMAIN`, the service probes without
their plists, `claude auth` and the obsidian CLI without their binaries.

### Transient tolerance

The first power-cut test produced a DOWN page that was pure noise: the host
booted 08:53:20, the agent ran 08:54:24, and two agents did not start until
08:56:08 — **+2m48s, both at the same second**, a deferred launchd bootstrap pass
rather than a fault. (An earlier diagnosis said those agents "never load" and
blamed Background Task Management — wrong, they were late. Don't re-engineer two
working plists.) With `maxretries 1` (retry 600 s) two failed pushes in a row page, so a stall past one run is a DOWN alert on *every* reboot.

| Knob | Default | Effect |
|-|-|-|
| `DEVHOST_BOOT_GRACE_SECONDS` | 300 | under this uptime, every failing component reports `starting` and the push stays UP |
| `DEVHOST_TRANSIENT_FAILS` | 3 | outside the grace, a check reports `degraded n/3` and FAILs only on the third consecutive run |
| `DEVHOST_REBOOT_NOTE_SECONDS` | 600 | the summary carries `host rebooted Ns ago` |

Two things that were got wrong first:

- **The boot grace covers every component, not just liveness ones.** Failures
  cascade at boot — `check_dev_vhosts` needs the tailnet IP, so it fails while
  tailscaled is merely slow — and a liveness-only grace still paged on every
  reboot.
- **The axis is level- vs edge-triggered, not liveness vs state.** A streak
  counter *permanently silences* an edge-triggered check rather than delaying it,
  which is why `check_launchd_restarts` (a delta, true for one run per restart)
  is the sole `IMMEDIATE_COMPONENTS` member.

**None of this relaxes "the machine died"** — a dead host emits no push at all
and Kuma's own missed-heartbeat is untouched, which is the property
the low `maxretries` exists to protect.

### Checks whose obvious implementation is wrong

- **Restart detection is a delta** against
  `~/.local/state/devhost-health/launchd-runs`, never a threshold on `runs`:
  `runs` is cumulative since load, so failing on `runs > 1` pages forever over a
  `Killed: 9` from weeks ago. The alertable fact is "restarted since the last
  check" — for the core, that its job just restarted (a kickstart keeps terminals, a `bootout` ends them).
  `StartInterval` agents are excluded (there `runs` counts scheduled runs), and
  so is **`Terminated: 15`**: SIGTERM only reaches a KeepAlive job because a
  human or a Makefile target asked launchd to bounce it, so a `make
  hermes-restart` is not an incident. That one exclusion was 40 of the 67
  dev-host DOWN alerts between 2026-06-14 and 2026-09-07 — the component's
  dominant output was false. `Killed: 9` (jetsam, the case it was written for),
  `Abort trap: 6`, `Segmentation fault: 11`, `Bus error: 10` and a signal-less
  crash-loop all still page; a deliberate restart is reported in the component's
  own text and in the `history:` tail instead.
- **A clean exit 0 is not evidence of intent — a marker is.** research-gateway
  and agent-gateway (both retired 2026-10-29) drained and exited 0 on their own, so their deploys carried no signal
  and paged every time (87 messages in 14 days to 2026-09-27, a third of
  #alerts). "No signal + exit 0 = deliberate" was rejected: a KeepAlive daemon
  that bails cleanly on missing config crash-loops with exactly that shape. So
  every restart path that leaves the job loaded (`kickstart -k`, self-exit +
  KeepAlive) appends an epoch to
  `~/.local/state/devhost/deliberate-restart/<label>` first; one line excuses
  one bump within 10 min and is consumed by it. Writers: the
  deploy scripts of agent-workflows and iris.
  `bootout`+`bootstrap` needs none (a fresh load restarts at `runs = 1`).
  Contract and logic: `scripts/lib/launchd-restarts.sh`; proof:
  `make launchd-restarts-test`.
- **Memory storm detection is the swapout RATE, not the pressure level or the
  swap share.** On 2026-09-27 an eight-hour Claude-pane storm swapped 19-107 GiB
  every 300 s while `kern.memorystatus_vm_pressure_level` sat at 2 — which
  `1c33c67` grades WARN (rc=2, never pages) — so the pressure branch
  short-circuited the swap-percent gate and nothing paged; that gate then fired
  only on the settled level-1 reading, i.e. as a false positive on a recovering
  host. The rate is agnostic to the cause, so it also subsumes the leaked-child
  case `check_runaways` cannot see (it needs PPID 1 / high accumulated CPU /
  a SourceRoot cwd). `check_swapouts` deltas the cumulative
  `vm.compressor.swapper.swapouts_total` (pages × `hw.pagesize`) against a state
  file, re-seeds instead of paging when the counter falls across a reboot, and
  FAILs past 2 GiB/300s on the normal 3-streak path. Proof:
  `make swapout-rate-test`; logic: `scripts/lib/swapout-rate.sh`.
- **The runaway reaper gates on accumulated CPU time crossed with lifetime
  average CPU**, never instantaneous `%CPU` (a compile pegs a core) and never
  accumulated time alone (a healthy long-lived service crosses any fixed
  CPU-minute line eventually, then pages forever). `claude --bg` daemons are
  excluded by name — PPID 1 with a SourceRoot cwd is their design. It reports and
  never kills.

### One scheduler, four monitors

Collie, the software factory and secrets freshness are pushed by this same agent to their **own**
monitors, before the composite (each bounded at 20 s, each pushing independently). A second LaunchAgent would be pure duplication; only the push target
differs, and each URL file's absence is silent by design, so a machine without
collie or without a seeded cache never fails the script.

- **Collie's check asserts behaviour, not liveness** — 200 on loopback *and* 403
  for a spoofed `Host`, both on **`/api/snapshot`**. `/` serves the SPA shell to
  any Host and always answers 200, so the same probe against `/` reports a
  healthy guard as broken. The second assertion is the point: collie's hardening
  lives in a `.env` launchd does not load on its own, so a mis-started bridge
  passes every liveness probe with its DNS-rebinding guard silently gone.
- **The factory** (`Software Factory - Push`, URL file `~/.config/uptime-kuma/factory-push-url`,
  override `FACTORY_PUSH_URL_FILE`) relays the factory's own verdict: `GET
  http://127.0.0.1:7793/health` (loopback, no token) carries `heartbeat: { ok, reason,
  tickAt, queueMovedAt }`, `ok` meaning the tick advanced and the queue moved within 30
  minutes. `ok` → up (`tick …, queue moved …`); no answer, a 503, no `heartbeat` or `ok:
  false` → down with the factory's `reason` (else the curl failure); the DOWN push is
  delivered and the script still exits 0. The factory deploys by bootout+bootstrap, so a
  probe can land in the restart gap (four deploys in five minutes paged on 2026-11-06): a
  no-answer is retried (3 probes, 3 s each, 4 s apart, inside the 20 s side-monitor bound),
  and a fresh `deliberate-restart/com.jkrumm.software-factory` mark (written by the
  factory's `scripts/deploy.sh`, read only here, consumed by the launchd check) reports
  `restarting` as up. No mark and still silent after the retries pages; a 503 or `ok: false`
  answer is a verdict and is never retried. No URL file, no push. The monitor and the file are made from
  `homelab`, not here.
- **Secrets-cache freshness** replaced a weekly agent (Mon 09:15) under which a
  cache going stale on a Tuesday was invisible for six days — six days of
  services potentially coming up credential-less. It runs in the 300 s script and
  pushes `MacMini Secret Seed - Push` on an 8-day mtime threshold, **never
  decrypting**. That monitor's `interval: 691200` in
  `homelab/uptime-kuma/monitors.yaml` stays as-is deliberately: it is now only
  the missed-heartbeat backstop, since the script pushes DOWN explicitly at 8
  days and a dead agent shows up on the composite within ten minutes.
- **`scripts/secrets-freshness-check.sh` is NOT redundant.** The MacBook's
  auto-reseed calls it over ssh as its last step, to refresh the heartbeat the
  instant a new cache lands instead of leaving the monitor red for 5 minutes.
  `devhost-health-check.sh` has its own `secrets_freshness_detail()` and shares
  only `scripts/lib/kuma-push.sh` with it. Check `grep -rn secrets-freshness-check`
  before believing any claim that something here is dead.

### Wiring a push monitor

Fully declarative, no browser step: `make uk-sync` creates the monitor, and the
push token is retrievable in the same session via `uptime-kuma-api`
(`api.get_monitor(<id>)["pushToken"]` → `https://uptime.jkrumm.com/api/push/<token>`
into a chmod-600 file).

- `--username` defaults to `jkrumm` in `sync.py`, not `admin` — a script assuming
  otherwise fails the login and returns an empty token, not an error. Only
  `active` is genuinely unsupported for push monitors; comments claiming
  otherwise were stale and believed for months.
- **The push token lives in a chmod-600 file, not 1Password**, so monitoring
  never depends on the secrets cache being seeded.
- **`maxretries` is 1 with `retry_interval` 600 s** (`homelab/uptime-kuma/monitors.yaml`) — time-to-DOWN is
  `interval + maxretries × retry_interval` ≈ 20 minutes; the default 3 would turn it into 40. Kuma's interval (600 s) stays longer than the agent's cadence (300 s)
  so one skipped run does not page.
- Traps: `set -o pipefail` + `grep -q` turns a SIGPIPE into a false failure;
  `op run` masks injected secrets in its own stdout, so a remote script printing
  a full push URL returns the domain as `<concealed by 1Password>` (print the
  token alone); a LaunchAgent has no shell aliases, so `tailscale` needs an
  absolute path.

**The heartbeat asserts resolvability, not push rights** — it makes no network
call to GitHub, because at 300 s with `maxretries 1` a provider outage would page
as "dev host down". The stronger `git push --dry-run` lives in `make doctor`.
That split earned itself: the credential resolved fine on the mini while the
deployed helper still pointed at a read-only token, and only the dry-run saw it.

## Memory budget (issue 1035)

Why the mini sat at 8.7–14.1 GB swap (27–44 % of 32 GB) all day on 2026-11-13, with `swapouts ok` (parked pages, not
thrashing). Measured read-only (`top -o mem`, `vm_stat`, `memory_pressure`, `ps`, `colima ssh -- free`) at 23:20 CET, 4 h 19 min
after the post-panic reboot: swap 0, compressor 11 GB, `PhysMem 30G used`, pressure normal. Swap fills over uptime; this is the
working set that fills it.

| Class | Procs | top MEM | Budget (after) | Note |
|-|-|-|-|-|
| VM guests (Virtualization.framework) | 2 | 8.1 GB | **6.1 GB** | Colima 6.1 GB resident, teamchat VM 2.0 GB; compressor holds ~11.6 GB of their pages |
| weatherorb python | 14 | 5.6 GB | 3.6 GB | steady ~0.9 GB; the `round` worker's two pool processes burst to 2–2.8 GB each for minutes |
| host postgres@18 | 47 | 5.1 GB | 5.1 GB | `shared_buffers = 4GB` (weatherorb, deliberate), counted on the io worker and checkpointer |
| claude sessions | 18 | 4.1 GB | 7 GB | ~0.23 GB each (idle resumed ones 0.19, working leads 0.4); 30 terminals = 7 GB |
| node / bun / opencode | 57 | 3.6 GB | 3.6 GB | dev servers, MCP servers, opencode |
| system daemons + launchd | 263 | 2.3 GB | 2.3 GB | plus 2.3 GB wired |
| unclassified | 352 | 2.9 GB | 2.9 GB | |
| Obsidian, Chrome, 1Password | 15 | 0.5 GB | 1 GB | Chrome is small here |
| lima / network / core | 27 | 0.5 GB | 0.5 GB | |
| **Total** | | **32.6 GB** | **≤ 28 GB** | RAM is 32 GB; the compressor absorbed the excess, swap takes what it cannot |

`top`'s per-process compressed figure double counts across the VMs; the kernel's own number is the 11 GB compressor above.

**Top two drivers of swap**

1. **The two VMs, 8.1 GB, and the host cannot take it back.** Virtualization.framework does not balloon: pages the guest
   touched stay resident on the host. The Colima guest uses 1.5 GB (nine containers, 1.2 GB) yet holds 4.4 GB of page cache, so
   the host carries 6.1 GB of which 4.4 GB is idle cache that compresses to nothing useful and ages into swap. The teamchat
   VM is the same shape (0.7 GB used of 4 GiB).
2. **Postgres `shared_buffers = 4GB`, 5.1 GB.** Hot, always resident. It was bought on purpose: weatherorb's nearest-spot p95
   missed (81–104 ms) at the stock 128 MB and passes (31–38 ms) at 4 GB (`weatherorb/docs/history`). Kept.

Not top two but the spikes that tip it over: weatherorb's two round pool processes (up to 5 GB for minutes, hourly), and the
claude fleet growing through the day (about 25 resumed terminals after a boot, working lead sessions at 0.4 GB).

**The budget**

- **Applied (config):** `COLIMA_MEMORY` on the mini 6 → **4** (`Makefile`; AGENTS.md and `docs/remote-dev.md` follow). It
  lands on the next planned `make colima-restart`; nothing was restarted. Guest peak is unknown (steady 1.5 GB, the heaviest
  container limit is 3 GiB); revert signal is a guest OOM kill (`colima ssh -- dmesg | rg -i oom`) or `available` under
  1 GB: go to 5 GB, not back to 6. Saves ~2 GB host-resident and ~2 GB less to compress.
- **Ceiling on agent terminals: not set.** 30 terminals ≈ 7 GB fits the budget; capping needs a choice of *which* terminals
  hc-resume skips, which the owner's constraint forbids (pacing and order only). Past ~30 live `claude` processes expect
  swap above the warn line.
- **Swap warn threshold stays at 25 % (8 GB).** After the budget the logical set is ≈ 27 GB + 2.3 GB wired = 29 GB, under 32:
  steady swap should be 0–2 GB, so 8 GB means two classes over budget, not a normal day. Today's 8.7–14 GB corresponds to a
  ~36–40 GB set, and that is what the WARN should name. Lowering it would only add noise before the window; raising it
  would hide exactly this. FAIL at 75 % and the 2 GiB/300 s swapout-rate FAIL stay: the rate, not the level, is the thrash
  signal. Check after the restart: `jq '.swap_used_mb' ~/Library/Logs/devhost-snapshots.jsonl` at day two of uptime,
  expected under 4096.

**Findings for the owner (defaults, not applied)**

| Finding | Default | Why not applied |
|-|-|-|
| teamchat VM 4 GiB → 2 GiB (0.7 GB used) | 2 GiB | profile lives in the IuRoot teamchat repo; its restart is already owner-timed (after MR !296) |
| weatherorb `round` pool: cap concurrent processes at one | one | another repo; filed as a signal there |
| postgres `shared_buffers` 4 GB → 2 GB | keep 4 GB | trades 31–38 ms p95 for ~2 GB; a measured product choice |
| Chrome / Obsidian | no limit | 0.5 GB, not a driver |

## Upstream drift

`make brew-upgrade` asserts its own invariants and the heartbeat fails loudly on
a broken host, but neither ever says *a pin has drifted* — so the collie plugin
sat five releases behind (two security fixes on a shell-equivalent surface) and
was found by accident, months later. `scripts/drift-check.sh` closes that: the
heartbeat runs it once a day as a bounded side job after its composite push (the
`com.jkrumm.drift-check` agent was retired 2026-11-06); the on-demand run is part of `make doctor`.
There stale drift (past the grace, `✗` lines) is a **WARN**, not a FAIL: it is maintenance waiting
for the owner's window (a macOS restart, `make tailscale-upgrade`), the Drift monitor already pages it,
and a red `make verify` failed the Watch of unrelated factory Issues (737). A drift-check that
crashes (exit 1 with no `✗` line) is still a FAIL.

| Command | Does |
|-|-|
| `make doctor` | Includes the drift report (read-only, no push) |
| `make drift-check-setup` | Dev-host gated, run by `make setup`: seeds the brew-upgrade stamp, removes the retired agent |
| `make drift-check-teardown` | Unload + remove the retired agent (idempotent) |

Side-job rules (`devhost-health-check.sh`): runs when `$STATE_DIR/drift-last-run`
is older than 20 h or absent, through `run_bounded` with `DEVHOST_DRIFT_TIMEOUT`
(60 s); a completed run stamps now, a timed-out run stamps backdated so it retries
in about 1 h, not every 5 min. It is skipped when the heartbeat already used more
than 200 s: the composite push is reached by ~230 s (200 s budget from script start + kill grace
+ a 15 s push + at most one 2 s + 10 s push retry) and drift adds at most 60 s from a start at or under 200 s, inside jobrun's 270 s. Its exit code never touches the heartbeat's; it pushes to
`MacMini Drift - Push` itself (2-day Kuma interval, valid while a push arrives
daily). `DEVHOST_DRIFT_CHECK_BIN` overrides the script path for tests.

It watches the collie commit pin (`COLLIE_REF`), the versions compiled into caddy
(`XCADDY_VERSION`, `CADDY_DNS_MODULE_VERSION`), brew-upgrade recency and pending
macOS updates. **Pins are read out of the Makefile, never duplicated.** Tag
resolution is shared with `make collie-upgrade` via `scripts/lib/github-tags.sh`:
the subtle half is `tag_commit`'s annotated-tag peel, since
Collie is built from the *dereferenced* commit, and reading the tag
object's own sha reports drift no upgrade can clear.

**It reports and never upgrades, deliberately.** The hazard here is not a
compromised release, it is *silent config revert*: caddy loses its DNS module and
nothing fails for ~60 days; colima's plist reverts and nothing fails until the
next power cut. An unattended upgrader on the host running herdr-core, colima,
agent-workflows, Hermes and every dev door is a mechanism for introducing exactly that
at 3am with nobody watching. `make collie-upgrade` is the paired human-invoked
applier (needs a TTY, refuses automation): **notice unattended, apply attended.**

`make mini-macos-update` (the macOS applier) writes a best-effort record on the mini before it
reboots it: `herdr-core-resume-pre-reboot-<stamp>.tsv` (one line per terminal that carries a
`jk.claude.session` label: address, session, config, cwd, state; taken only when launchd says
`com.jkrumm.herdr-core` is running, since any `hc` call would otherwise auto-start a core). `hc-resume` revives the sessions
after the reboot; the tsv is what it should find.

Four decisions that are not arbitrary:

- **A daily side job of the heartbeat, no agent of its own.** Every check here
  is a **network call** and the 300 s composite deliberately refuses to touch
  GitHub, so drift runs after the composite push, at most once per 20 h and
  bounded (60 s), with its own monitor. That is safe because every heartbeat run
  is bounded; a network failure degrades to `skipped`, never to a page.
- **Age grace, not bare "is it behind".** A drifted pin is named in the msg
  immediately but FAILs only after `DRIFT_GRACE_DAYS` (14), keyed on the
  **component, never the version** — keying on the version lets a fast-releasing
  upstream reset the clock to zero forever.
- **brew is a recency stamp, not an outdated count.** homebrew/core moves daily,
  so "something is outdated" would sit red permanently; the alertable fact is
  that the guarded upgrader has not run
  (`~/.local/state/brew-upgrade/last-success`, seeded to *now* at setup — a
  monitor whose first act is to report a fault it invented is one you disbelieve).
- **macOS is read from Apple's own cached scan**
  (`RecommendedUpdates` in `/Library/Preferences/com.apple.SoftwareUpdate`), not
  a live `softwareupdate -l` — the background scan already ran.

A network failure degrades to **`skipped`** in the msg and never to DOWN:
"GitHub was unreachable" and "you are five releases behind" are opposite
conclusions. Both paths are tested rather than asserted (backdate a `first-seen`
entry → stale, exit 1; point `GIT_BIN` at `/usr/bin/false` → every pin check
`skipped`, exit 0). The push URL file is optional and its absence silent.
**Bash 3.2**, same constraint and same reason as the heartbeat.
