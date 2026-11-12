---
description: How a background-job or service failure reaches a human today, on both Macs. Covers the three alert paths (Uptime Kuma, HyperDX, jobs-grade; jobs-grade ends in a factory signal on the owner repo, with ntfy only as the fallback; Kuma and HyperDX still in Slack until their own moves), the jobrun/jobs-grade tiers T0 and T1, the source of truth per question, dead-man's-switch vs failure semantics, and the MacBook. Nothing auto-heals. The warden-era design is archived in docs/archive/ops-signals-2026-10-warden-era.md.
---

# Ops signals — from a failing job to a human

> **Nothing auto-heals.** Every alert ends in a message a human reads and acts on: a factory signal on the owner repo for job failures, ntfy topic `alerts` (priority 3) only when the factory is unreachable (Kuma and HyperDX still post to Slack until they move too). The autonomous
> remediation loop (warden) was switched off 2026-10-27; its design is kept in
> `docs/archive/ops-signals-2026-10-warden-era.md`. GitHub issues are no longer worked
> automatically.

## 1. Alert paths

| Source | Path | Where it lands |
|-|-|-|
| Uptime Kuma monitor | status change → provider `Slack - Alerts` | Slack |
| HyperDX alert | alert and OK → `Slack #alerts` | Slack `#alerts` |
| Background job (`jobrun` / Hermes cron) | run record → `jobs-grade` (the only grader) → `jobs-grade --summary --report`, run inside the 300 s mini heartbeat | a factory **signal on the job's owner repo** once the job is not ok for 2 consecutive grades (at most one per job per day); ntfy topic `alerts` at priority 3 only as the fallback when `factory` is unreachable. A lead fixes it; the owner is not paged |
| KeepAlive service | `services` and `check_launchd_restarts` components of the 300 s heartbeat → the **detail** Kuma push (`MacMini Dev Host Detail - Push`, opt-in URL file) | Dead port or restart loop: DOWN on the detail monitor → the factory door → a lead. Until that monitor and its URL file exist (homelab signal filed with issue 870) a component FAIL is WARN text on `MacMini Dev Host - Push` and **reaches nobody** |
| MacBook | `~/.wakeup` runs `jobs-grade --notify` | macOS notification only |

The heartbeat stays WARN-only for jobs: a job failure shows up as a **WARN** line in the push message
and never turns a monitor DOWN, so Kuma does not become a second reporting path for the same
failure. `MacMini Dev Host - Push` pages only when the mini is unreachable or its core is dead (tailnet, sshd, core
socket); the other components' verdict rides the detail monitor, which the factory door routes to a lead.

## 2. Kuma's role

Kuma is the calm, outside-in backstop. It watches what only an outside observer can see:
- **The mini and the heartbeat are alive** — `MacMini Dev Host` (composite), `Agent Gateway`. If the
  mini is dark, nothing local can report it.
- **A user-facing symptom** — `Hermes Agent`, `WeatherOrb Watchdog`, `Home Line`.
- **Data left the box** — the backup push monitors (`Brain Backup`, `Hermes Backup`, `1Password
  Backup`); only the receiving side can confirm an off-site copy.

Push monitors use `maxretries ≥ 1`; page only on what is urgent and actionable, batch-job and backup
failures are tickets, not pages.

## 3. Tiers

| Tier | Owner | Does |
|-|-|-|
| **T0 record** | `jobrun` (wrapper) | Writes the run's start, finish, rc, duration, tail and run id to the state dir |
| **T1 self-heal** | the job itself, plus launchd | In-job retry with backoff and a deadline, escalating its own ladder (netgear-watchdog is the model). Next-tick retry comes free from launchd; KeepAlive restarts after the 10 s throttle |

Past T1 a failure is a signal or a message (a factory signal for jobs, Slack for Kuma and HyperDX). There is no T2 (automatic remediation) any more; T3 is the
human reading the alert, plus `human-queue` (`ask-human`) for physical, biometric or TCC work.

## 4. Source of truth (one per question)

| Question | Truth | Not this, because |
|-|-|-|
| **Is job X healthy right now?** | **The `jobrun` state dir** (`~/.local/state/jobs/<label>.json`) on the job's machine. One grading function, `scripts/lib/jobs-grade`, is shared by the heartbeat, `make doctor` and the MacBook wake hook | **Kuma** only knows "a push arrived": no rc, no tail, loses a flap between pushes. **OTel/HyperDX** can alert on absence, but would put the mini's local truth behind the VPS collector, so a network blip makes every job look dead at once |
| **What happened over time?** | **OTel, as a mirror only**: `jobrun` emits one best-effort OTLP log per run (`service.name=jobrun`) for dashboards and trends. Never alerting | — |
| **Is the mini itself alive?** | **Kuma** (§2) | — |

## 5. Dead-man's switch vs failure

| Situation | Example | Who detects it | How |
|-|-|-|-|
| Ran, failed | rc≠0, deadline hit | `jobrun` (T0) → grade | `consecutive_fail`, `last_rc` |
| Ran, "succeeded" while a step failed | a backup rotation | the job: each step must propagate rc | Wrapper-level detection is impossible; this is the owner repo's bug |
| Didn't run: plist unloaded, exit 78, binary gone, a launchd firing missed | — | **The grader, not the job.** `jobs-grade` flags `now − last_started > every + grace` and cross-checks `launchctl print gui/501/<label>` | Run by the heartbeat (WARN, ntfy on change) |
| Machine dark or heartbeat dead | — | **Kuma** (outside-in) | The only layer that survives the mini being off |
| Hung, still running | a deadlocked run | `jobrun --timeout` (TERM, then KILL); KeepAlive services through `/health` | launchd skips `StartInterval` firings while the job runs, so a hang otherwise looks exactly like "didn't run" |
| Crash-looping service | KeepAlive restart storm | `check_launchd_restarts` | launchd has no `StartLimitBurst` equivalent: it retries forever at the 10 s throttle, so this check is the start limiter |
| Flapping | ok/fail alternating, so the consecutive counter never trips | `jobs-grade`: ≥ 3 failures in 24 h counts as failing even if interleaved, until the latest 3 runs are all green | One message per change in the not-ok set |

launchd facts this relies on (from `man launchd.plist`):
- `StartInterval` firings are **missed** while the machine is asleep **or the job is still running**
  (built-in no-overlap), so `jobrun` needs a lock only across labels.
- `StartCalendarInterval` jobs **run on wake** if a firing was missed during sleep.
- Spawns are throttled to once per 10 s by default (`ThrottleInterval`).

## 6. MacBook

The MacBook is self-contained for detection and escalation. A sleeping, roaming MacBook makes
absence normal, so a mini-side dead-man's switch would page every night, and its jobs' consequences
are local to a present human.
- The same `jobrun` and state dir.
- Grade **on wake**: `~/.wakeup` (sleepwatcher) runs `jobs-grade --notify`, with staleness measured
  against awake time. `StartInterval` ticks missed while asleep are not failures.
- The escalation is a native macOS notification; T1 is the job's own ladder.
- `opbackup` keeps its weekly Kuma monitor, because its data leaves the box.

Job inventory and the `jobrun` pattern: `docs/background-jobs.md`.
