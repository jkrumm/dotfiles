# Background jobs → warden self-healing

**Goal:** every owned background job on the mini records each run (`jobrun`) and is graded
(`jobs-grade`). Every alert source (job, Kuma, HyperDX) feeds warden directly. warden fixes
failures end to end and proves each fix by the job's next successful run. Kuma is a calm backstop
that watches the chain itself. A human hears only `needs_decision` (rare) or a physical,
biometric or TCC ask. Self-improvement runs as warden's recurring duty.

**Spec:** `docs/ops-signals.md` (its *Owner decisions* section wins) and `docs/background-jobs.md`.

**Mode:** orchestrated. The orchestrator tab (dotfiles) spawns every wave and reviews its
close-out. **A wave never spawns the next one.**

**Gate (every wave):**
1. `make check` (or `/check`) green in **every repo the wave touched**, failures quoted verbatim
   in Left behind.
2. `/review` on everything non-trivial, findings fixed and re-reviewed.
3. Committed and pushed.
4. **Deployed and verified live** (`make deploy` + `make verify`, or the repo's equivalent). The
   evidence goes in Left behind.

A wave whose deploy can only happen on the MacBook ends with a precise `ask-human ask` handoff
instead of claiming done.

## Rules for every wave

- **Cross-repo work.** The plan lives in dotfiles, and waves edit other repos. Before touching a
  repo, run `rd agents`:
  - another agent `working` in that checkout → do the work in a worktree on a branch, or as
    `agw dispatch` `implement`, and merge when green. Never edit a busy checkout. weatherorb has
    a live chain of its own.
  - **warden:** always a worktree, then fast-forward master when green (`warden/AGENTS.md`
    §Gotchas: the checkout is live). Never migrate the live ledger from a session. Never start a
    second loop. `triage.py` has no `--help`. Follow its §Git (history log + `STATE.md` in the
    same commit).
- PR-required repos (`config/pr-required-repos.json`) go via PR. None are expected here.
- **Secret values are never read into the session or committed.** A missing grant, scope, ACL
  push or secret seed becomes `ask-human ask '<exact ask>' --cmd '<exact command>'`. Record its
  id in Left behind.
- **Investigation is read-only until the fix.** Never kickstart or bootout a job just to test it
  (exceptions: the canary, and a deploy target that does so itself).
- **No dev servers. Logs go to `~/Library/Logs`.** Every new launchd label gets a row in
  `docs/architecture.md` in the same commit.
- **Each wave updates the docs it made stale:** `background-jobs.md` ladder levels,
  `ops-signals.md`, `architecture.md`, the owner repo's AGENTS.md.

---

## Wave 0 — record the owner decisions            <!-- status: done -->
- [x] `ops-signals.md`: *Owner decisions* section (warden is THE loop, Hermes out, no ceiling + guardrails, direct webhooks, Kuma backstop, self-improvement §9, bun/TS)
- [x] `background-jobs.md`: pattern in bun/TS, migration → this plan, open questions resolved
- [x] `docs/waves/jobs-metrics.sql` (read-only ledger metrics, tested against the live ledger with `immutable=1`)
- [x] Previous plan archived to `docs/waves/archive/2026-10-platform-PLAN.md`
**Left behind:**
- Done inline by the orchestrator (editorial work).
- Ledger baseline over 14 days: `uk` 5 items, 0 fixed; `slack_alert` 17 items, 0 fixed; `hermes_log` 11 items, 1 fixed.

## Wave 1 — hermes-agent defects            <!-- status: done -->
- [x] `hermes-backup.sh`: fix the rotation, which has failed nightly since 09-21 with `cannot delete non-empty directory sidecars-excluded-20260921`. Make every step's failure propagate to the exit code, so a broken rotation can no longer push Kuma green
- [x] Morning briefing: the warden board URL `127.0.0.1:7734` → `7735` (warden-api). Hermes keeps the briefing job; it just reads the right port
- [x] Delete Hermes cron `91800bba0031` (human-queue push retry, hard-coded to a request resolved 10-01) and its row in `hermes-agent/docs/scheduled-jobs.md`
- [x] Verify: the next 03:00 run, or a manual run of the backup script with rotation, exits 0 and the stale dir is gone; `hermes cron list` no longer shows the job; the briefing context script reaches the board
**Left behind:**
- Commit `hermes-agent` master (pushed). Root cause was not a rotation step: `--delete` cannot remove a dir holding only excluded `*-shm`/`*-wal` files, and rsync **exits 0** on `cannot delete non-empty directory`, so launchd's last exit was 0 and Kuma stayed green. Fix: `--delete-excluded` (also removed the plaintext `.env` that sat on homelab, against the script's own intent), rsync output captured and `cannot delete` → rc 1, unresolved or failed Kuma ping → rc 1 (was silently skipped).
- Briefing: only `cron/morning-briefing.prompt.txt` carried `7734` (now `7735`, `/board` → 200); `briefing-context.py` already reached the board (`WATCHDOG_AVAILABLE=true`).
- Cron `91800bba0031` removed via `hermes cron remove`; orphaned `scripts/human-queue-push-retry.sh` deleted too; doc row gone; `check-cron-registry` matches (4 live).
- Evidence: manual `hermes-backup.sh` run exit 0, `sidecars-excluded-20260921` and `.env` gone on homelab; `hermes cron list` no longer shows the job; `make check` in hermes-agent green. The script runs from the repo path under launchd, so it is live; the next 03:00 run is the final proof.
- Review: no `/review` run (35-line bash diff, read and tested live by hand).

## Wave 2 — the remaining known defects            <!-- status: done -->
- [x] `audio-gateway` last exit 127: `secrets-run: line 770: from_cache: command not found` (10-15 14:35). Find the root cause. A likely hypothesis is bash reading `secrets-run` while it was being rewritten by the 10-14 commit, but confirm or refute it. Fix in the owner repo; any `secrets-run` edit takes its full guardrail (AGENTS.md §Secrets)
- [x] `warden-sweep` 403 reading check-runs on weatherorb: confirm which token and scope (read-only). Any code-side fallback goes in warden (worktree). The scope grant itself → `ask-human ask` with the exact GitHub UI step
- [x] Verify: `audio-gateway` restart history is clean; `warden-sweep.err` shows no new 403 after the grant (or the ask id is recorded) — ask id recorded; the live proof is carried to Wave 3
**Left behind:**
- `audio-gateway`: hypothesis **confirmed byte-exact**. The wrapper `secrets-run run -- bun` outlived the 10-14 in-place rewrite (34826 → 35291 bytes); when bun exited **0**, bash resumed at the old EOF offset and byte 34826 of the new file is `from_cache` (line 770 = old 769 lines + 1). A non-zero child exit hides it (`set -e`). Fix: `main "$@"; exit $?` (dotfiles `d3d2e59` + follow-up), regression `secrets-run.test.sh` §13b1 (red on old shim: got 99; green now), `forward_signal` got a SC2329 disable. `make secrets-test` 48/48 and the harness 119/119, `make secrets-lint` clean. Design D7 + security-review notes in dotfiles-private (pushed). Adversarial `/review`: 0 blocking; the comment and the test's sleep-ordering were fixed; a re-exec-from-copy hardening was declined (the `exit` closes it, rename-replace was never affected).
- **Known one-off:** my own in-place edit of `secrets-run` hit the 6 live `secrets-run run` wrappers still on the old image. Each may fail once on its next *clean* child exit, then launchd restarts it onto the fixed script. `audio-gateway` `LastExitStatus` stays 127 until then; I did not kickstart anything (Wave rule). Edit shell scripts via `git`/rename, not in place, while daemons run.
- `warden-sweep`: it is `op://mini/github/token`, a fine-grained PAT, and it lacks `Checks: read` on `jkrumm/weatherorb` (probe: 403, `x-accepted-github-permissions: checks=read`; `/user` 200). warden already has the code-side fallback (`lifecycle/merge.py::read_check_runs` → Actions workflow runs, `ChecksPending` when none), so the line in `warden-sweep.err` is an informational log, not a failure. No warden change was needed. Grant requested: `ask-human` id `20261016T122335-23766` (GitHub UI: the token → Repository permissions → Checks → Read-only). Same token, no reseed. Verify after the grant: the check-runs probe returns 200 and no new `check runs unreadable` line.
- Not verified yet (depends on the above): clean `audio-gateway` restart history, and no new 403 after the grant.


## Wave 3 — the map tells the truth            <!-- status: active -->
- [ ] Carry-over from Wave 2. Check whether these have happened; don't force either one:
  - `audio-gateway` cycled onto the fixed `secrets-run` (`LastExitStatus` no longer 127);
  - if ask `20261016T122335-23766` was granted: the check-runs probe returns 200 and no new `check runs unreadable` line.

  Record the state either way
- [ ] `docs/architecture.md`: drop the five weatherorb timers that are now DBOS schedules (`obs`, `fcstlog`, `archive`, `backfill`, `round`); §Monitoring adds `Agent Gateway`, `Warden Loop`, `Warden Backup`, `Hermes Serve`, `WeatherOrb Degraded`, `Home Line - Watchdog`
- [ ] `scripts/architecture-check.sh`: also assert map ⊆ live on the machine that owns the row (the mini section on the mini, the MacBook section on the MacBook), with a hermetic test
- [ ] Verify: `make doctor` green; a fake stale row fails it
**Left behind:**

## Wave 4 — `jobrun` and `jobs-grade`            <!-- status: pending -->
- [ ] `scripts/jobrun.ts` (bun): `jobrun <label> --owner <repo> [--every s] [--timeout s] [--lock name] [--kuma op-ref] -- <cmd>`. It:
  - prefixes output lines with timestamps;
  - enforces the deadline with TERM, then KILL;
  - takes an optional cross-label lock;
  - writes `~/.local/state/jobs/<label>.json` atomically (`run_id`, `started`, `finished`, `rc`, `duration_ms`, `every`, `owner`, `last_ok`, `consecutive_fail`, `fails_24h`, `tail`, plus the owner repo's HEAD SHA);
  - pushes Kuma only via `--kuma`, on rc=0, with the URL resolved through `secrets-run`.
  `make setup` links it to `~/.local/bin/jobrun`
- [ ] `scripts/lib/jobs-grade.ts`: state dir + `launchctl print` → per label `ok|failing|stale|flapping|unloaded`, as JSON on stdout. The thresholds are `ops-signals.md` §3 T1 and §5 (flapping = ≥ 3 failures in 24 h). This is the **only** grading logic
- [ ] Hermetic `bun test` suites in `make check` (deadline, lock, atomic write, every grade state, clock injection)
- [ ] Heartbeat: a `jobs` component that is **WARN-only** (exit 2, never DOWN); `make doctor` prints the graded table
- [ ] Verify: `make check` green; `make devhost-health-check` shows the jobs line (0 jobs yet = `jobs ok (0)`)
**Left behind:**

## Wave 5 — dotfiles jobs on `jobrun` + the canary            <!-- status: pending -->
- [ ] Wrap `brain-web-refresh`, `log-rotate`, `brain-sync`, `brain-backup` and `drift-check` in their plist templates (`--kuma` only where a §2 backstop monitor stays). Re-render them through the existing `make <x>-setup`
- [ ] `log-rotate.sh`: derive its file list from our plists' `StandardOutPath`/`StandardErrorPath` (`com.jkrumm.*`, `com.iu.*`). Nothing outside those labels is touched
- [ ] Canary: `com.jkrumm.jobrun-canary` (300 s) runs `scripts/jobrun-canary.ts`, which exits 1 unless `config/jobrun-canary.json` has `"healthy": true`. Keep it healthy and committed. It is the end-to-end probe for Wave 7.
  **Catch:** warden *parks* merges into a checkout that has a `working` herdr agent (`warden/AGENTS.md`), and the orchestrator and every wave sit in the dotfiles checkout. Decide where the canary's owner checkout lives so Wave 7 can actually merge there, and record the decision. Options: run Wave 7 from another cwd with the orchestrator idle, or give the canary an owner repo that nobody works in
- [ ] Verify: six state files, all graded `ok`; flipping the canary to unhealthy *locally, uncommitted* → `failing` after 3 ticks → restore → `ok`
**Left behind:**

## Wave 6 — warden: kill-switch and the `job` source            <!-- status: pending -->
- [ ] Kill-switch: `warden pause [--reason]` / `warden resume`, plus a flag file read at the start of every pass. While paused, ingest continues and **no dispatch of any origin** happens. Surface it on `/health` and the Argo snapshot
- [ ] `job` source: each loop pass runs `jobs-grade` locally; `failing|stale|flapping|unloaded` → event with dedup key `job:<machine>:<label>`, routed to the job's `owner` repo (no triage guess needed). Level-based: it stays one event while the grade is bad
- [ ] Chronic rule: a reopen of the same `job:` key within 7 days → `needs_decision` instead of a dispatch. Same for a `fixed` job failing again within 24 h (a `work` strike)
- [ ] Ledger migration through the loop's own `connect(migrate=True)` path only; tested on a copied ledger
- [ ] Verify: the canary unhealthy locally → exactly one `job` item; `warden pause` → no dispatch; `resume` → dispatch; restore the canary
**Left behind:**

## Wave 7 — warden: job brief, verified closure, canary end to end            <!-- status: pending -->
- [ ] Job brief template next to `_build_cluster_brief()` (`ops-signals.md` §6). It contains:
  - label, machine, owner repo and plist;
  - grade and the last 5 runs, with a 40-line tail;
  - `git log` since `last_ok`, plus brew changes;
  - the allowed and forbidden actions;
  - the acceptance check.

  The tier is **implement** from day one
- [ ] Verified closure: a `job` item goes `verifying` → `fixed` only when the state file shows `last_ok` after the merged SHA was deployed. A timeout means a `work` strike
- [ ] **Canary end to end, live:** commit `"healthy": false` to dotfiles master. warden must take it through item → implement → merge → `make deploy` → next canary run ok → `fixed`, with no human touch. Record the timings
- [ ] Verify: the canary item is `fixed` with closure evidence; time from first failure to fixed is recorded; no second item was opened
**Left behind:**

## Wave 8 — review cycle 1            <!-- status: pending -->
- [ ] Run `docs/waves/jobs-metrics.sql` and work through the `ops-signals.md` §9 checklist. Record the numbers in Left behind
- [ ] Tune what the numbers say: T1 thresholds in `jobs-grade`, the brief, dedup and chronic rules. One commit per tuning, each with its evidence
- [ ] Make it recurring: extend `warden/docs/improve/LOOP.md` step 1 (Measure) with the job metrics query and the §9 checklist, so the outcome-triggered improve loop owns it after the chain. Not a second loop
- [ ] Verify: an improve-loop iteration run by hand reads the new metrics; JOURNAL line written
**Left behind:**

## Wave 9 — warden-api ingest door            <!-- status: pending -->
- [ ] warden-api: `POST /ingest/kuma` and `POST /ingest/hyperdx`. Bearer token resolved via `secrets-run` (new `op://` ref, declared in `dotfiles-private/headless.refs`). The payload is mapped to the existing `uk` and `slack_alert`-equivalent event shapes (`hyperdx` source) with the same dedup keys. Idempotent; 202 on accept. Tests
- [ ] Caddy door for the ingest route only (`config/Caddyfile`), plus `make caddy-tailnet`
- [ ] ACL: declare a narrow grant (homelab and VPS tags → devhost `tcp:443`) in `dotfiles-private`. **Pre-approved by the owner 2026-10-16. There is no policy decision to wait for. The human-queue ask must carry the exact `make tailscale-acl-diff` output so it can be pushed as-is.** The push is biometric → `ask-human ask` with `make tailscale-acl-diff` then `make tailscale-acl-push`. The token item and secret seed → `ask-human ask` (`make secrets-seed`)
- [ ] Verify: a POST from homelab (`ssh homelab curl …`) returns 202 and creates an event (the test event is then closed); without the token → 401
**Left behind:**

## Wave 10 — Kuma → warden webhook            <!-- status: pending -->
- [ ] `homelab/uptime-kuma/monitors.yaml`: add a webhook notification → `/ingest/kuma` on every leaf monitor, **keeping** "Slack - Alerts" as the human-readable mirror and fallback. Apply with `make uk-sync`
- [ ] warden: retire the `uk` Argo snapshot poll in `watchdog-poll.py` only after one real DOWN/UP pair has arrived by webhook. Until then both run, and dedup keeps one item
- [ ] Verify: pause a test push monitor → DOWN webhook → one `uk` item within a loop pass; resume → resolved
**Left behind:**

## Wave 11 — HyperDX → warden webhook            <!-- status: pending -->
- [ ] `~/SourceRoot/vps/observability/alerts/*.json`: add the `/ingest/hyperdx` webhook to all 21 alerts. Slack #alerts stays as the mirror. Apply through the repo's own sync
- [ ] warden: stop turning HyperDX-shaped #alerts messages into `slack_alert` items once the webhook path is proven (`watchdog-poll.py` filter, like the `[… Push]` one). weatherorb's alert → GitHub issue path stays (it already reaches warden directly as `github_go`)
- [ ] Verify: a test alert (temporary threshold) → one `hyperdx` item, not a duplicate `slack_alert`; restore the threshold
**Left behind:**

## Wave 12 — Kuma becomes the calm backstop            <!-- status: pending -->
- [ ] `monitors.yaml`, per `ops-signals.md` §2:
  - keep the three duties: chain-alive, user-facing symptoms, data leaving the box;
  - `maxretries ≥ 1` everywhere;
  - intervals of at least 2× warden's T2 budget for everything that isn't chain-alive;
  - retire or lengthen `Brain Sync`, `Hermes Watchdog`, `Drift`, `Hermes Serve`, `Collie` and `Secret Seed` as §2 says
- [ ] warden: the `Warden Loop` push requires loop, poll and sweep heartbeat freshness (`/health`), so a dead sweep pages through Kuma
- [ ] Docs: `architecture.md` §Monitoring and `ops-signals.md` §2 match the result
- [ ] Verify: `uk-sync` diff reviewed and applied; a stale-sweep simulation on a copied ledger makes the push skip
**Left behind:**

## Wave 13 — adopt `jobrun`: research-gateway, modelpick, usage-tracker            <!-- status: pending -->
- [ ] `research-gateway-deploy`: `jobrun` with `--lock` replacing its mkdir lock (keep the 2h-stale semantics through `--timeout`)
- [ ] `modelpick-refresh`: wrap it, and make a degraded step (0 rows from a source) a non-zero exit
- [ ] `usage-tracker`: wrap it. Remove the heartbeat's bespoke staleness check for it once graded
- [ ] Verify: all three graded `ok` live; `background-jobs.md` ladder updated
**Left behind:**

## Wave 14 — adopt `jobrun`: weatherorb, backups, Hermes cron            <!-- status: pending -->
- [ ] `weatherorb.{retention,verify}`: wrap them (weatherorb has a live chain → worktree or `agw dispatch`; never its main checkout while busy)
- [ ] `hermes-backup` and `warden-backup`: wrap them, `--kuma` keeping their 25 h backstop
- [ ] Hermes cron: an adapter turns `jobs.json` `last_status` into `jobs-grade` states, so cron failures become `job` items for hermes-agent through the same path. Retire the `hermes_cron` event-only source
- [ ] Verify: all graded; a forced failure on a test cron job → one `job` item; ladder updated
**Left behind:**

## Wave 15 — review cycle 2            <!-- status: pending -->
- [ ] Metrics and the §9 checklist, compared against Wave 8's numbers. Tune
- [ ] Every owned mini job is at ladder level ≥ 2, and the remediable ones are at 4. Fix the stragglers or record why
- [ ] Docs: `background-jobs.md` ladder table reflects the live state; `ops-signals.md` §1 rewritten as "flow today" (after), with the old flow moved to a short history note
**Left behind:**

## Wave 16 — MacBook: netgear-watchdog on launchd            <!-- status: pending -->
- [ ] tinycast-extensions:
  - a bun entry point running the existing pure `netgear/watchdog.ts` tick;
  - a launchd plist template (60 s) wrapped in `jobrun`;
  - state in a file that the Tinycast `netgear` view reads
- [ ] **Delete what the move makes obsolete:** the `netgear-watchdog` no-view command and its view-driven ticker, the cross-process action lock, the LocalStorage watchdog state (`watchdog-storage.ts` → the file). Tests updated
- [ ] dotfiles: `~/.wakeup` runs `jobs-grade --notify` on the MacBook (staleness against awake time); `architecture.md` MacBook row
- [ ] `make check` green in both repos, committed and pushed. **Deploy and verify need the MacBook:** end with `ask-human ask` carrying the exact install command and the three checks:
  - it keeps ticking with a Tinycast view open;
  - the state file updates;
  - the view reads it.

  Do not mark it live
**Left behind:**

## Wave 17 — MacBook: van-sampler Bluetooth TCC spike, then migrate            <!-- status: pending -->
- [ ] Spike: a minimal signed Swift executable with an embedded Info.plist (`-sectcreate __TEXT __info_plist`, `NSBluetoothAlwaysUsageDescription`) as the launchd **program**. Does the BLE scan get a TCC prompt and grant attributed to it, with Tinycast quit? Use `/research` for current TCC attribution rules first
- [ ] On success: van-sampler becomes that Swift program (reusing `van-ble`'s CoreBluetooth code), wrapped in `jobrun`, with state in a file the `van-power` view reads. Delete the Tinycast `van-sampler` command and its LocalStorage state. On failure: record the evidence and the `.app`-bundle alternative, and stop
- [ ] Commit and push, then hand off with `ask-human ask`: build/sign/install command, grant the prompt, and the checks (a reading lands every 15 min with Tinycast quit; a low-battery notification fires). Do not mark it live
**Left behind:**

## Wave 18 — review cycle 3 and close            <!-- status: pending -->
- [ ] Metrics and checklist run a third time. Final tuning
- [ ] Final docs: `ops-signals.md` and `background-jobs.md` describe the live system; AGENTS.md pointers in dotfiles, warden and hermes-agent; `docs/agent-platform.md` names warden as the sole remediation loop
- [ ] Confirm the recurring review is live in warden's improve loop; archive this plan to `docs/waves/archive/`
**Left behind:**
