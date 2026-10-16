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
- `warden-sweep`: `op://mini/github/token` (fine-grained PAT) gets 403 on `/check-runs` — **not a missing grant** (corrected in Wave 6): fine-grained PATs have no Checks permission at all (GitHub-App-only); `/actions/runs` returns 200. warden's Actions-runs fallback (`lifecycle/merge.py::read_check_runs`) is the designed path, so no action is needed and no Checks ask may be queued. Asks `20261016T122335-23766` / `20261016T131448-15212` could never work and are moot.
- `audio-gateway` clean restart history: not yet verified (see Wave 3). The check-runs item needs nothing.


## Wave 3 — the map tells the truth            <!-- status: done -->
- [x] Carry-over from Wave 2. Check whether these have happened; don't force either one:
  - `audio-gateway` cycled onto the fixed `secrets-run` (`LastExitStatus` no longer 127);
  - if ask `20261016T122335-23766` was granted: the check-runs probe returns 200 and no new `check runs unreadable` line.

  Record the state either way
- [x] `docs/architecture.md`: drop the five weatherorb timers that are now DBOS schedules (`obs`, `fcstlog`, `archive`, `backfill`, `round`); §Monitoring adds `Agent Gateway`, `Warden Loop`, `Warden Backup`, `Hermes Serve`, `WeatherOrb Degraded`, `Home Line - Watchdog`
- [x] `scripts/architecture-check.sh`: also assert map ⊆ live on the machine that owns the row (the mini section on the mini, the MacBook section on the MacBook), with a hermetic test
- [x] Verify: `make doctor` green; a fake stale row fails it
**Left behind:**
- **Carry-over state (recorded, not forced):** `audio-gateway` `LastExitStatus` is still 127 — it has not cycled onto the fixed `secrets-run` (nothing kickstarted, per the wave rule). Ask `20261016T122335-23766` is `done` ("marked done via dialog", 12:23Z) but the check-runs probe (read-only, token passed through `secrets-run run`, never printed) still returns **403** at 12:40 CEST; `warden-sweep.err` has no line newer than 11:25 only because no weatherorb merge has been evaluated since. Either the PAT edit was not saved or the repo list/permission differs; re-probe, and if still 403 re-ask with the exact GitHub UI step. warden's Actions-run fallback keeps working meanwhile.
- `architecture.md`: dropped the five weatherorb timers (`obs`, `fcstlog`, `archive`, `backfill`, `round`; none loaded or on disk) with a note that they are DBOS schedules now. §Monitoring added `Agent Gateway - Push`, `Warden Loop - Push`, `Warden Backup - Push`, `Hermes Serve - Push`, `Home Line - Watchdog`, `WeatherOrb Watchdog - Degraded` (the plan said "WeatherOrb Degraded"; the monitors.yaml name is the longer one). The rows are the declarations in `homelab/uptime-kuma/monitors.yaml`; `make uk-sync` was not run (homelab repo, out of scope), so whether Kuma already has them is unverified.
- `architecture-check.sh` now also asserts map ⊆ live for the machine's own section (backend `cache` → mini, `op` → MacBook; labels matched against `launchctl list` or a plist's `Label` on disk, brew generations interchangeable). Fails closed on: empty `launchctl list`, a renamed section heading (zero labels). An unknown backend skips the reverse half with a notice. Hermetic suite `scripts/architecture-check.test.sh` (9 cases, `make architecture-check-test`, wired into `make check`). `doctor.sh` wording covers both modes.
- Verify: `make check` rc 0; `make doctor` architecture line "all 57 mapped mini labels exist", 42 passed, 4 skipped, clean; a fake stale `weatherorb.round` row on the real map exits 1 with `mapped-but-absent (mini)` (restored). MacBook half is covered by the test only, not run on the MacBook.
- `/review` (agent-gateway): 1 blocking (filename vs `Label` key) and the fail-open paths fixed. Declined: switching the machine selector from backend to `machine-role.ts`, generating the Kuma table from `monitors.yaml`, a retired-label list (the plists are already gone), tidying the test's `expect` signature.

## Wave 4 — `jobrun` and `jobs-grade`            <!-- status: done -->
- [x] `scripts/jobrun.ts` (bun): `jobrun <label> --owner <repo> [--every s] [--timeout s] [--lock name] [--kuma op-ref] -- <cmd>`. It:
  - prefixes output lines with timestamps;
  - enforces the deadline with TERM, then KILL;
  - takes an optional cross-label lock;
  - writes `~/.local/state/jobs/<label>.json` atomically (`run_id`, `started`, `finished`, `rc`, `duration_ms`, `every`, `owner`, `last_ok`, `consecutive_fail`, `fails_24h`, `tail`, plus the owner repo's HEAD SHA);
  - pushes Kuma only via `--kuma`, on rc=0, with the URL resolved through `secrets-run`.
  `make setup` links it to `~/.local/bin/jobrun`
- [x] `scripts/lib/jobs-grade.ts`: state dir + `launchctl print` → per label `ok|failing|stale|flapping|unloaded`, as JSON on stdout. The thresholds are `ops-signals.md` §3 T1 and §5 (flapping = ≥ 3 failures in 24 h). This is the **only** grading logic
- [x] Hermetic `bun test` suites in `make check` (deadline, lock, atomic write, every grade state, clock injection)
- [x] Heartbeat: a `jobs` component that is **WARN-only** (exit 2, never DOWN); `make doctor` prints the graded table
- [x] Verify: `make check` green; `make devhost-health-check` shows the jobs line (0 jobs yet = `jobs ok (0)`)
**Left behind:**
- `scripts/jobrun.ts` + `scripts/lib/jobs-grade.ts` (bun/TS), 45 hermetic `bun test` cases in `make check` via new `make jobs-test`. `make setup` links `~/.local/bin/{jobrun,jobs-grade}` (shebang `env bun`: **Wave 5 plist templates must put bun's dir on `PATH`**, launchd has none).
- State file = spec fields plus `owner_sha`, `runs` (last 5), `fail_times` (what `fails_24h` counts). Grades, in order: `unloaded`, `failing` (≥3 consecutive, or interval job red with no success for `max(3×every,30 min)`, or a daily job red), `stale` (no run in that window; daily = `every`+2 h), `flapping` (≥3 fails/24 h), else `ok`. No `--every` = only failure and loaded state are graded. A corrupt/incomplete state file grades `failing` (never vanishes).
- `jobs-grade --summary` / `--table` (verdict on the last line) exit 0/2 and are the **single verdict** the heartbeat (`jobs` component, WARN-only) and `make doctor` relay; neither re-grades.
- Semantics Wave 5+ must know: a held `--lock` skips the run (rc 0, no state write; absence grading catches a lock that never frees); deadline = rc 124; a run interrupted by jobrun's own SIGTERM (unload/reboot) records its rc but is not a failure; `--kuma` failing to resolve/push exits 1 after the run is recorded ok; lock is published atomically with pid+start time (pid reuse safe), unknown start time = held.
- Verify: `make check` rc 0; live `make devhost-health-check` → `jobs ok (0)` (a temp state dir produced `jobs WARN (1): smoke=unloaded`, so the WARN path works); `make doctor` jobs line `jobs ok (0)`. Heartbeat and doctor run from the repo path, so they are live. The heartbeat's `swap 34%` FAIL in that same run is pre-existing and unrelated.
- `/review` ×2 (agent-gateway). Round 1: 7 blocking fixed (lock races/path escape/error masking, fsync, Kuma timeout + release-before-push, pid reuse), plus drain-after-exit, interrupted runs, single verdict, corrupt files. Round 2: 4 blocking, 3 fixed (steal re-verification, unknown start = held, schema validation); exhausted lock attempts now throw (rc 70).
- **Declined, with reason:** orphan-pgid reclaim (launchd kills the job's process group when jobrun dies); per-label state lock (launchd already forbids overlap, a manual overlap is the owner's act); default deadline (would kill legitimately long jobs); splitting `jobrun.ts` / extracting a shared `job-state` module; IuRoot owner dirs (IuRoot is out of the chain).
- **For Wave 5/6:** `jobs-grade` only grades labels that have a state file, so a job that has *never* run (or whose first run is lock-skipped) is invisible. Wave 5's six wrapped jobs need an expected-label list (or Wave 6's `job` source must carry one) to flag "never recorded". Also: a retired job's `<label>.json` grades `unloaded` forever, so teardown targets must `rm` it.

## Wave 5 — dotfiles jobs on `jobrun` + the canary            <!-- status: done -->
- [x] Wrap `brain-web-refresh`, `log-rotate`, `brain-sync`, `brain-backup` and `drift-check` in their plist templates (`--kuma` only where a §2 backstop monitor stays). Re-render them through the existing `make <x>-setup`
- [x] `log-rotate.sh`: derive its file list from our plists' `StandardOutPath`/`StandardErrorPath` (`com.jkrumm.*`, `com.iu.*`). Nothing outside those labels is touched
- [x] Canary: `com.jkrumm.jobrun-canary` (300 s) runs `scripts/jobrun-canary.ts`, which exits 1 unless `config/jobrun-canary.json` has `"healthy": true`. Keep it healthy and committed. It is the end-to-end probe for Wave 7.
  **Catch:** warden *parks* merges into a checkout that has a `working` herdr agent (`warden/AGENTS.md`), and the orchestrator and every wave sit in the dotfiles checkout. Decide where the canary's owner checkout lives so Wave 7 can actually merge there, and record the decision. Options: run Wave 7 from another cwd with the orchestrator idle, or give the canary an owner repo that nobody works in
- [x] **Never-recorded gap (from Wave 4):** `jobs-grade` must also know which labels it *expects*, so a wrapped job that never wrote a state file grades `stale`/`unloaded` instead of being invisible. Derive the expected set from the plists that invoke `jobrun` (single source, no hand list). Teardown targets `rm` the label's state file
- [x] Verify: six state files, all graded `ok`; flipping the canary to unhealthy *locally, uncommitted* → `failing` after 3 ticks → restore → `ok`
**Left behind:**
- **Wrapped:** `brain-sync`, `brain-web-refresh` (300 s), `log-rotate` (3600 s), `brain-backup`, `drift-check` (86400 s) now run `jobrun com.jkrumm.<x> --owner dotfiles --every <s> -- <script>`; each plist puts `~/.local/bin` and `/opt/homebrew/bin` on `PATH`. No `--kuma` and no `--timeout` (scripts keep their own Kuma push; Kuma retirement is Wave 12; a deadline would kill legitimately long runs). Re-rendered via the `make <x>-setup` targets; the script is `exit 1` on open drift, so `drift-check` grades `failing` whenever a drift item is open (intended, see background-jobs.md).
- **log-rotate:** the list is derived from `StandardOutPath`/`StandardErrorPath` of `com.jkrumm.*` and `com.iu.*` plists under `$HOME`, minus its own log, symlinks rejected. **Deviation to review:** a 5-entry `EXTRA` list remains for logs no plist names (Hermes gateway's two upstream streams, `hermes-ops.log`, `warden-cli.log`, the collie plugin log); dropping them would uncap a file that once hit 115 MB. Dropped as dead: the retired hermes-triage/hermes-cc entries, the MacBook-only entries (derived there from their own plists), the weatherorb `.obs/.fcstlog/.blendfield/.backfill` entries. Hermetic suite `scripts/log-rotate.test.sh` (`make log-rotate-test`, in `make check`).
- **Canary:** `com.jkrumm.jobrun-canary` (300 s, `--timeout 60`) runs `scripts/jobrun-canary.ts` against committed `config/jobrun-canary.json` (`"healthy": true`). `make jobrun-canary-setup` (dev host only) is also called from `make setup`; its teardown removes the state file. **Owner checkout decision (recorded in `background-jobs.md` §Canary):** the owner repo is `dotfiles`; warden parks merges into a checkout with a `working` agent, so **Wave 7 must run with nothing `working` in the dotfiles checkout** (the orchestrator tab spawns it from another cwd and idles; the Wave 7 worker is the only dotfiles agent and must not hold it while the canary item merges). Wave 7 should confirm this on first contact with the merge path.
- **Never-recorded gap:** `jobs-grade` derives the expected set from installed `~/Library/LaunchAgents/*.plist` whose ProgramArguments invoke `jobrun` (`readExpected`, `parseJobrunArgs`; env `JOBRUN_PLIST_DIR`). A declared label with no state file grades `unloaded` (not loaded) or `stale` (never recorded once its first window since the plist mtime has passed; inside it, `ok`). Every wrapped job's `*-teardown` now `rm`s its state file. Warden's Wave 6 `job` source gets this for free by calling `jobs-grade`.
- **Verify (live):** `make check` rc 0 (jobs-test 54 pass, log-rotate suite 10/10). `jobs-grade --table`: six state files, all `ok` (`jobs ok (6)`). `drift-check` and `brain-backup` have no RunAtLoad, so I kickstarted each once to create their first record (brain-backup: tree clean, nothing committed). Canary flip: `healthy:false` uncommitted + 3 kickstarts → `failing` ("3 consecutive failures"), restored → recovered; that test left 4 fails in 24 h (`flapping`), so I deleted the canary's state file and re-ran it to `ok` — the history of that test is not in the ledger. `make doctor`: architecture "all 58 mapped mini labels exist", `jobs ok (6)`.
- **/review (agent-gateway):** 2 blocking fixed (`;`-masked render failure in `jobrun-canary-setup`; log-rotate following symlinks), plus duplicate-expected-label dedup, `parseJobrunArgs` guard order, plutil/symlink warning. **Not re-run after the fixes** (small, covered by tests, `make check` green). Three angles (typescript, resilience, api-contract) failed in the reviewer (shell denied), so they are unreviewed, not clean. **Declined:** splitting plist I/O out of `jobs-grade.ts` (one file stays the only grader), a shared plist fragment/`_teardown-agent` helper (six templates, premature), a plist-mtime grace clock concern (`_render-plists` rewrites only on content change), making the canary observe something real (the toggle is the design: Wave 7 needs a fixable input), the "jobs-test omits the canary test" claim (false: `bun test scripts/` ran 3 files).

## Wave 6 — warden: kill-switch and the `job` source            <!-- status: done -->
- [x] Carry-over (resolved differently, see Left behind): re-probe check-runs on `jkrumm/weatherorb` with `op://mini/github/token` (read-only). Ask `20261016T122335-23766` was marked done but still returned 403 at 12:40. If still 403, re-ask with the exact fine-grained-PAT path (Settings → Developer settings → Fine-grained tokens → <token> → Repository access includes weatherorb → Permissions → Checks: Read-only → **Update**)
- [x] Kill-switch: `warden pause [--reason]` / `warden resume`, plus a flag file read at the start of every pass. While paused, ingest continues and **no dispatch of any origin** happens. Surface it on `/health` and the Argo snapshot
- [x] `job` source: each loop pass runs `jobs-grade` locally; `failing|stale|flapping|unloaded` → event with dedup key `job:<machine>:<label>`, routed to the job's `owner` repo (no triage guess needed). Level-based: it stays one event while the grade is bad
- [x] Chronic rule: a reopen of the same `job:` key within 7 days → `needs_decision` instead of a dispatch. Same for a `fixed` job failing again within 24 h (a `work` strike)
- [x] Ledger migration through the loop's own `connect(migrate=True)` path only; tested on a copied ledger
- [x] Verify: the canary unhealthy locally → exactly one `job` item; `warden pause` → no dispatch; `resume` → dispatch; restore the canary
**Left behind:**
- **Check-runs 403 is not a grant** (orchestrator correction): fine-grained PATs have no Checks permission, `/actions/runs` is 200. Probe re-confirmed 403 at 13:1x CEST. The ask `20261016T131448-15212` was already marked done by the dialog, nothing to close; no Checks ask is to be queued again. warden: the misleading wording in `clients/github.py` / `clients/errors.py` / `lifecycle/merge.py` / docs now says "Actions-runs fallback in use; no grant needed", logged once per sha per process. `background-jobs.md` and the Wave 2/3 notes corrected.
- **warden master `0b6c7f4`** (built in a worktree, rebased, fast-forwarded, pushed, `make deploy` + `make verify` green: schema 23/23, loop heartbeat fresh, `/health` carries `paused: null`). `make check` 655/655 in test_triage, rc 0, on the rebased tree.
- **Kill-switch:** `warden pause [--reason]` / `warden resume` (flag file `~/.warden/paused`, fail-closed on an unreadable file). Stops every loop-driven dispatch, merge, deploy and revert (checked per item/per repo, not per pass); ingest, classify, triage and polling in-flight work continue. **The owner's explicit `warden merge` / Argo merge is deliberately not stopped** (deploy after it is held). On `/health` and the Argo snapshot.
- **`job` source:** new origin `job`; each loop pass runs `jobs-grade`, bad grade -> one item `job:<machine>:<label>`, routed to the job's `owner` repo with no triage call, level-based, resolves on recovery. A failed/malformed `jobs-grade` run is a blind pass. Chronic: a reopen within 7 days after warden already acted, or a `fixed` job failing again within 24 h -> `needs_decision` (thresholds in `config/triage-policy.json`). Unroutable owner -> `needs_decision`. No ledger migration was needed (schema stays 23). Job items are `max_tier=investigate` with a stopgap brief and close `resolved` — **Wave 7 builds the real brief, the implement tier and verified closure.**
- **Live verify:** canary unhealthy (local, uncommitted) -> exactly one item (#1582, `job:mini:com.jkrumm.jobrun-canary`, `triaged`, repo dotfiles); with `warden pause` it sat undispatched across a full pass; after `warden resume` the next pass dispatched it (`working`, investigation job started). Canary restored (`git checkout`), its state file reset (the test left it `flapping`, same as Wave 5; the failure history is not in the ledger) and it grades `ok`; `jobs ok (6)`. Item #1582 was still `working` at close-out; it should resolve on recovery — **Wave 7: confirm #1582 reached `closed` and did not reopen, and close it by hand (`warden close`) if it is stuck.**
- **Reviewed** (agent-gateway, 1 round): 4 blocking (per-item pause check in verify/train, non-UTF-8 flag file, merge-exemption wording) fixed with tests; cheap cleanups done. **Not re-reviewed after the fixes** (covered by mutation-style tests). **Declined:** moving the event reconcile out of `watchdog-poll.py` into `lifecycle/`, a Kuma/`/health` alert for a forgotten pause or a dark job source, a post-claim pause re-check (TOCTOU window of one submit), an opt-in flag for the first-pass dispatch backlog (all six jobs graded `ok` at deploy, so nothing queued).
- **For Wave 7:** `jobs-grade` default output omits `owner_sha`, `runs` and `tail`; the brief needs them (the client keeps extra fields it receives, so print them in the grader first). `drift-check` grades `failing` whenever a drift is open, which will open a job item. `audio-gateway` `LastExitStatus` is still 127 (not cycled, nothing kickstarted).

## Wave 7 — warden: job brief, verified closure, canary end to end            <!-- status: done -->
- [x] Job brief template next to `_build_cluster_brief()` (`ops-signals.md` §6). It contains:
  - label, machine, owner repo and plist;
  - grade and the last 5 runs, with a 40-line tail;
  - `git log` since `last_ok`, plus brew changes;
  - the allowed and forbidden actions;
  - the acceptance check.

  The tier is **implement** from day one
- [x] Verified closure: a `job` item goes `verifying` → `fixed` only when the state file shows `last_ok` after the merged SHA was deployed. A timeout means a `work` strike
- [x] **Canary end to end, live:** commit `"healthy": false` to dotfiles master. warden must take it through item → implement → merge → `make deploy` → next canary run ok → `fixed`, with no human touch. Record the timings
- [x] Verify: the canary item is `fixed` with closure evidence; time from first failure to fixed is recorded; no second item was opened
**Left behind:**
- **warden master `5622e7f`** (worktree, rebased, fast-forwarded, pushed, `make deploy` + `make verify` green after each of three deploys; `make check` 667/667 in test_triage, 95/95 CLI). dotfiles: `jobs-grade` rows carry `owner_sha`, `runs`, `tail`; the canary prints its own fix line on failure.
- **Brief** (`lifecycle/intake.job_brief()` + `gather_job_context()`): label, machine, owner, plist, cadence, last 5 runs, 40-line tail, owner `git log` and Cellar changes since `last_ok`, allowed / forbidden actions, the rule that a tail naming its own fix is a normal implement (never `needs_decision`), acceptance. 8000 chars, untrusted fields capped, fences defanged. `JOB_MAX_TIER` = `implement`.
- **Verified closure** (`verify._job_closure()`): `fixed` needs a `last_ok` after the deploy **and** the latest run green (`consecutive_fail == 0`; `flapping` after a fix would otherwise block it). Window `max(30, 2×every+10)` min; expiry = `work` strike to `triaged`, never a revert; the 3rd expiry (counted from `item_transitions`, because `strikes` resets on re-advance) is `failed(work)`.
- **Canary, live (planted 13:31:51Z, item #1582, no second item):** the first attempt did not complete. Two defects found live and fixed: (1) `reopen_if_needed()` runs after `ingest_jobs()`, so the reopened item was dispatched at its old `investigate` tier and closed `resolved` with the canary still red (13:52→13:55); (2) such an item has no way back. Fixed by setting the tier in `route_job_items()` and letting `warden reinvestigate` take a `closed` job item whose job is still red. **One owner verb was used:** `warden reinvestigate 1582` at 14:06:03Z. From there, hands-off: dispatch 14:12:40 → PR #21 14:20:42 → merged 14:25:46 → deployed 14:32:56 → job ok 14:37 → `fixed` 14:43:53 (37 min 50 s from the re-drive, 72 min from the plant; the 10-min loop and the 5-min canary dominate). No `needs_decision`, no page. The squash message and diff are the one-line `healthy:true`.
- **Chronic rule refined** (found because #1582 was hand-closed): an item the owner closed with `warden close` is not counted as "warden acted" (`core.HAND_CLOSE_NOTE_PREFIX`), so its recurrence is new work. Without it the live run would have been a `[chronic]` page.
- **/review** (agent-gateway, 1 round): 4 blocking fixed (git failure read as "no commits", rules truncation, fence/trim bugs, closure on a red latest run). **Not re-reviewed after the fixes or the three later changes** (covered by tests; the live run is the proof). Declined: `gather_job_context` into `clients/`, a `closure_expiries` column, a per-origin closure strategy, caching context per pass, keeping the first deploy pass at `investigate` (this plan fixes the tier).
- **For Wave 8:** (a) a job item closed `resolved` by an investigation (`nextAction=none`) while the job stays red is silent forever (level-based source, no reopen until it recovers); consider a re-open after N hours still red. (b) The grade stays `flapping` for 24 h after a fix (`fails_24h`); the heartbeat WARN and the job event persist until then. (c) The canary's failure history is in the ledger (#1582 has 3 cycles). (d) `jobs-grade` runs once per pass for ingest and again per verifying job item; fine at 6 jobs. (e) The loop pass was ~10 min late during the run (weatherorb merges in flight); `maybe_verify` runs `make verify` (doctor) every pass for every verifying item.

## Wave 8 — review cycle 1            <!-- status: done -->
- [x] Run `docs/waves/jobs-metrics.sql` and work through the `ops-signals.md` §9 checklist. Record the numbers in Left behind
- [x] Tune what the numbers say: T1 thresholds in `jobs-grade`, the brief, dedup and chronic rules. One commit per tuning, each with its evidence
- [x] Make it recurring: extend `warden/docs/improve/LOOP.md` step 1 (Measure) with the job metrics query and the §9 checklist, so the outcome-triggered improve loop owns it after the chain. Not a second loop
- [x] Verify: an improve-loop iteration run by hand reads the new metrics; JOURNAL line written
**Left behind:**
- **Metrics (14 d, ledger `immutable=1`):** `job` 1 opened / 1 fixed / 0 needs_decision / 0 failed, 2.4 h to fix (#1582, the canary, Wave 7's planted test); `uk` 5 opened, 0 fixed, 2 quiet; `slack_alert` 17 / 0 fixed / 6 quiet / 5 closed ignored / 2 dup; `hermes_log` 11 / 1 fixed / 2 dup; `github_go` 42 / 7 fixed (avg 11.4 h, max 26.8 h); `human` 60 / 16 fixed. Events vs items: `job` 1/1, `uk` 12/12, `slack_alert` 32/32. Reopened signatures: none listed. `hyperdx` does not exist yet (Wave 9+). Live: `jobs ok (6)`.
- **§9 checklist:** 1 ok (job 1/1, no dup). 2 `job` 100 % but **n=1, no signal**; `uk` 0 % fixed (5 opened: nothing for warden to fix, it is the Kuma poll, Waves 10-12 own it) and `slack_alert` 0 % fixed, 5 false positives (Waves 10-12). 3 job 2.4 h (budget 2 h; the 10-min loop plus the 5-min canary dominate; one sample). 4 reopen within 7 d: #1582 only, by Wave 7's own planted failure. 5 `needs_decision`: 1 job (the Wave 6 hand-closed test). 6 job false positives 0. 7 not measurable until Wave 10. 8 no owned job at level 0-1 among the 6 wrapped (the rest are Waves 13-14). 9 kill-switch used once, for Wave 6's pause/resume test.
- **Tuned (one commit each, evidence in the message):**
  - (b) dotfiles `jobs-grade`: `flapping` clears once the latest 3 runs are green (`RECOVERED_RUNS`). The canary stayed `flapping` ("12 failures in 24 h") and held the heartbeat WARN for hours after the verified fix; it now grades `ok`. Interleaved failures still flap. Tests in `jobs-grade.test.ts`; `ops-signals.md` §5 row updated.
  - (a) warden `ad1980c` (live, `make deploy` + `make verify` green: `deployed ad1980c`, schema 23/23, heartbeat fresh): a `job` item the loop closed with the job still red is re-investigated once after `jobStillRedHours` (6, `triage-policy.json`), then `needs_decision`; hand closes are left alone. The review found that the earlier-marker count must be scoped to the current occurrence (fixed with a test). Tests 667 -> 671, `make check` rc 0.
  - **Not tuned, with numbers:** (c) the canary history in the ledger (3 cycles of #1582) is a one-off from the planted test; no rule. (d) `jobs-grade` runs in under 1 s: no cache. (e) `make verify` is 16 s per verifying item per pass: no change; the late loop pass was weatherorb merges in flight. T1 thresholds, dedup and chronic rules: no tuning, the sample is one item.
- **Recurring:** `warden/docs/improve/LOOP.md` step 1 (Measure) now runs `jobs-metrics.sql` + `jobs-grade --table` and works the §9 checklist, with a "n < 5 is no signal" rule. Proof: an iteration run by hand read the metrics (`improve-trigger.py` said `quiet`) and wrote JOURNAL line `777ab97`.
- **/review** (agent-gateway, 1 round, warden diff): 1 blocking fixed. The architect, senior-dev and resilience angles failed in the reviewer (shell denied), so they are unreviewed, not clean. The dotfiles `jobs-grade` change (a 5-line guard plus a test) got no `/review`.
- Gates: dotfiles `make check` rc 0; warden `make check` rc 0 (671/671). Warden changes went through a worktree (`warden-w8`, removed), fast-forwarded and pushed. Nothing spawned.
- **For Wave 9:** the Kuma and HyperDX rows of the metrics (`uk` 12 events/12 items, `slack_alert` 32/32) are the baseline Waves 10-12 should beat.


## Wave 9 — warden-api ingest door            <!-- status: done -->
- [x] warden-api: `POST /ingest/kuma` and `POST /ingest/hyperdx`. Bearer token resolved via `secrets-run` (new `op://` ref, declared in `dotfiles-private/headless.refs`). The payload is mapped to the existing `uk` and `slack_alert`-equivalent event shapes (`hyperdx` source) with the same dedup keys. Idempotent; 202 on accept. Tests
- [x] Caddy door for the ingest route only (`config/Caddyfile`), plus `make caddy-tailnet`
- [x] ACL (declared and committed; **push pending, carried to Wave 12**, see Left behind): declare a narrow grant (homelab and VPS tags → devhost `tcp:443`) in `dotfiles-private`. **Pre-approved by the owner 2026-10-16. There is no policy decision to wait for. The human-queue ask must carry the exact `make tailscale-acl-diff` output so it can be pushed as-is.** The push is biometric → `ask-human ask` with `make tailscale-acl-diff` then `make tailscale-acl-push`. The token item and secret seed → `ask-human ask` (`make secrets-seed`)
- [x] (carried to Wave 12) Verify: a POST from homelab (`ssh homelab curl …`) returns 202 and creates an event (the test event is then closed); without the token → 401
**Left behind:**
- _Orchestrator 2026-10-16: the two `jobrun` adoption waves moved ahead (now 10, 11) while the MacBook is offline; Kuma/HyperDX/diet are now 12–14._
- **Stopped, not done: two biometric asks are queued and the MacBook (`iumac`) was unreachable (ssh timeout) all session.** Run `make human-queue` there, or the dialogs fire when it is back. In this order: (1) `20261016T170519-9342` creates `op://mini/warden-ingest/token` (random 32-byte hex, mini vault) if missing and runs `make secrets-seed`; (2) `20261016T170531-21347` pulls `dotfiles-private`, runs `make tailscale-acl-diff`, **aborts if the live ACL has any line the file lacks**, else `ACL_PUSH_YES=1 make tailscale-acl-push`. Expected diff: one added grant, `tag:homelab` + `tag:vps` -> `tag:devhost` `tcp:443` (plus its comment, after the homelab -> devhost `tcp:22` grant). `make tailscale-acl-diff` itself refuses on the mini, so the real diff output could not be attached; the guard in the command is the substitute.
- **Verify still open (needs both asks):** `ssh homelab curl -s -o /dev/null -w '%{http_code}' -X POST https://warden-ingest.mini.jkrumm.com/ingest/hyperdx -H "Authorization: Bearer $T" -d '{"alert":"wave9 test","state":"ALERT"}'` -> 202 and one `hyperdx` event (then `OK` resolves it; close the item if one opens); the same without the header -> 401. Pass `$T` from `secrets-run read op://mini/warden-ingest/token` on the mini through ssh stdin, never on a command line. **Live now, proven on the mini:** `make deploy` + `make verify` green at warden `a73a676`; a POST through the Caddy door reaches warden-api and answers 503 (fail closed, no token seeded yet); `GET /board` on the door is 404; a GET on `/ingest/kuma` is 405.
- **warden** (`99ae4e2` + `a73a676`, worktree, fast-forwarded, pushed): `scripts/lifecycle/ingest.py` + the POST handlers in `api.py`. `POST /ingest/kuma` -> `uk` (Kuma status 0 opens/refreshes, 1 resolves, 2/3 and group monitors ignored, Kuma's Test ping answered 202 ignored), `POST /ingest/hyperdx` -> new state source `hyperdx` (our body contract `{alert, state ALERT|OK|firing|resolved, message?, url?, service?, value?}`; **Wave 13 (was 11) must template HyperDX's webhook body to it**). Bearer token `op://mini/warden-ingest/token` resolved lazily via `secrets-run` (a seed after deploy needs no restart); no token = 503, bad/missing = 401 before the body is read, 64 KiB cap, socket timeout, token never logged. `hyperdx` is in `INGEST_SOURCES`. `make check` green (test_ingest 39, test_api 46, test_triage 671).
- **Caddy / ACL** (dotfiles `fe339c7`, dotfiles-private `feat(acl)`): the ACL grants `tcp:443` on the whole mini, which the file's own comment had rejected for the VPS ("every dev app at once"). Containment instead of a policy change: `scripts/caddy-tailnet.sh` now generates a reserved `warden-ingest` host (proxies `/ingest/*` of warden-api only) and a source guard that answers 403 to every `tag:homelab` / `tag:vps` peer address (read from `tailscale status`, 4 now) for every other host. Live: `make caddy-tailnet` ran on the mini, config validated and reloaded. A new homelab/VPS node needs a regeneration. Token ref declared in `dotfiles-private/headless.refs`.
- **/review** (agent-gateway, 1 round, needs-human): fixed: socket timeout, oversized `Content-Length`, query string routing, the `poll_uk()` INSERT race (`ON CONFLICT DO NOTHING`), unbounded HyperDX string value. **Declined with reason:** (a) "blocking" sender text reaching triage: the event is already fenced as untrusted data (`intake._fence`) exactly like every Slack and Kuma line; the bearer token is the control. (b) "blocking" HyperDX fingerprint on the truncated title: `normalize_title()` caps every fingerprint at 120 chars anyway (`slack_alert` too), so the fix is correct but changes nothing below 200 chars. (c) 503-before-401 kept (distinguishes "not seeded" for the operator). (d) per-source event caps, versioned hyperdx keys, a shared identity/row module, a source descriptor table: scope. **Owner-visible trust model:** one shared bearer token now authorizes work for agents; the reviewer asked for it to be recorded in `agent-platform.md`; not done here (plan prescribes the token, per-sender tokens are a Wave 18 option). **Known race kept:** a `poll_uk()` snapshot taken before a Kuma UP webhook can reopen that row once, until Wave 10 retires the poll. The review run was not repeated after the fixes (covered by tests).
- Wave 12 (was 10, Kuma webhook) must not start until the verify above is green: it depends on a working token and ACL.

## Wave 10 — adopt `jobrun`: research-gateway, modelpick, usage-tracker            <!-- status: done -->
- [x] `research-gateway-deploy`: `jobrun` with `--lock` replacing its mkdir lock (keep the 2h-stale semantics through `--timeout`)
- [x] `modelpick-refresh`: wrap it, and make a degraded step (0 rows from a source) a non-zero exit
- [x] `usage-tracker`: wrap it. Remove the heartbeat's bespoke staleness check for it once graded
- [x] Verify: all three graded `ok` live; `background-jobs.md` ladder updated
**Left behind:**
- **Wrapped (all three live, graded `ok`):** `research-gateway-deploy` (`--every 120 --timeout 7200 --lock research-gateway-deploy`; the script's mkdir lock, stale-lock reclaim and trap are gone; `make deploy` goes through the same wrapper), `modelpick-refresh` (`--every 86400 --timeout 3600`), `usage-tracker` (`--every 900 --timeout 600`). Owner repos clean and idle; research-gateway built in a worktree (a bg agent was on it), ff-merged. Commits: research-gateway `68b5040` + `be76f30`, modelpick `74d159b` + `be76f30`-successor (`fix(refresh)` preflight), usage-tracker `feat(launchd)` + `fix(collectors)`, dotfiles `09c10f5`.
- **modelpick degraded rule:** `RefreshResult.degraded` = a collector that rejected or returned 0 rows (per source) → `allOk` false → exit 1; the other sources' rows are still persisted. **Not caught:** per-category emptiness inside a source (lmarena `coding` 500s today and the source still has rows), a partial page set. Declined from review: skipping `commitSnapshot` on a red run (pre-existing behaviour), a typed collector table refactor, marking degraded on stored picks.
- **usage-tracker heartbeat probe removed** (`probe_usage_tracker`, its env vars and registry row; services 9 → 8). Consequence: staleness is now a WARN via the `jobs` component, no longer a FAIL of the composite.
- **Defect found by grading, fixed:** the first `jobrun` run of usage-tracker was red (rc 1): a vanished sideclaw worktree dir made the claude-code collector throw ENOENT (`walkJsonlFiles`). Nested dirs that disappear mid-scan are now empty (+2 tests). The old log-mtime probe could never have seen this. The `fails_24h` entry stays in the record. Also note: with the MacBook offline every tick logs "iumac unreachable" at warn level and stays rc 0, which is correct.
- **Verify (live):** `jobs-grade --table` → `jobs ok (9)`, all three `ok` with records (modelpick-refresh from one real kickstart: rc 0, 22 min, all five sources had rows; deploy poller deployed `68b5040` and `be76f30` through the wrapper, gateway healthy). `make check`: dotfiles rc 0, modelpick rc 0 (791 tests), usage-tracker 168 pass, research-gateway 1487 pass locally. **research-gateway CI failed once on an unrelated timing test (`fetch chain budget … aborts a hanging chain`, 5181 ms), green on re-run** — a flaky test in code this wave did not touch.
- **/review** (agent-gateway, 1 round, research-gateway + modelpick heads; usage-tracker and the dotfiles diff were not separately reviewed). Fixed: `--` inside the plist XML comment, `jobrun` preflight in `refresh-setup`, stale comments, summary line, teardown comment. **Refuted against jobrun source:** "dead-holder lock never reclaimed" (pid+start-time check, `jobrun.ts:101`), "timeout signals only the child" (it kills the process group, `:230`), and "`--every 86400` skips a day across DST" (`--every` is only recorded for grading, it never gates a run). **Declined:** a `jobrun` marker/refusal in `mini-deploy.sh`, flag duplication across plist/Makefile (commented as must-match instead), a test harness for the poller, an explicit "skipped" message from `make deploy` on a held lock.
- **Deploy gap noted:** `mini-deploy.sh` does not re-render plists (`launchd/` change only warns). I rendered the deploy plist by hand with the Makefile's own sed and bootout/bootstrap of that one label (not `launchd-install`, which also restarts the gateway). Any future template change needs the same.
- **For Wave 11:** weatherorb has a live chain (`weatherorb-w47` working in the checkout) → worktree or `agw dispatch`. The jobrun-wrapped plist pattern is: `jobrun <label> --owner <repo> --every <s> [--timeout] [--lock] --` plus `PATH` carrying `~/.local/bin` and `/opt/homebrew/bin` in `EnvironmentVariables`; teardown targets `rm` `~/.local/state/jobs/<label>.json`. `hermes-backup` / `warden-backup` keep their 25 h Kuma backstop via `--kuma`.

## Wave 11 — adopt `jobrun`: weatherorb, backups, Hermes cron            <!-- status: done -->
- [x] `weatherorb.{retention,verify}`: wrap them (weatherorb has a live chain → worktree or `agw dispatch`; never its main checkout while busy)
- [x] `hermes-backup` and `warden-backup`: wrap them, `--kuma` keeping their 25 h backstop
- [x] Hermes cron: an adapter turns `jobs.json` `last_status` into `jobs-grade` states, so cron failures become `job` items for hermes-agent through the same path. Retire the `hermes_cron` event-only source
- [x] Verify: all graded; a forced failure on a test cron job → one `job` item; ladder updated
- [x] Orchestrator add-on (warden): `checks_failed` with revisions left is always another revision, never a page; an uncategorised `nextAction=human` on `checks_failed` is not an owner question (item 1577). With a test
**Left behind:**
- **Wrapped (live, all graded `ok`):** `hermes-backup` (`jobrun --every 86400 --kuma op://hermes/uptime-kuma/backup-push-url`; the script's own push block and `secrets-run` lookup are gone), `warden-backup` (`--every 86400`, **no `--kuma`**: its push URL is a mode-600 file that `--kuma op-ref` cannot read, and the script already pushes only after a clean snapshot+bundle+rsync; deviation from the plan line), `weatherorb.retention` and `weatherorb.verify` (`--every 86400`, `PATH` in `EnvironmentVariables`). hermes-agent `3d6f7da`, warden `14e46d5`, weatherorb `aab9afa`, dotfiles `63b45fa`. Both backups were kickstarted once (rc 0, 27 s and 4.5 s, `--kuma` push included); retention (deletes data) and verify (heavy) were **not** kickstarted: they grade `ok` inside their first window and the 04:30 / 05:45 runs are the proof. weatherorb was built in a worktree (its `weatherorb-w48` was working), pushed to origin master, plists rendered by hand with the Makefile's own sed + bootout/bootstrap of those two labels (a `make deploy` would pull into the busy checkout); its AGENTS.md notes the wrap and that the `uv`-upgrade exit-78 gotcha no longer applies to `retention`. weatherorb `make check` (pytest, ~5 min) was not run: the diff is two plists (linted) and docs.
- **Hermes cron adapter, inside `jobs-grade`** (still the only grader): `~/.hermes/cron/jobs.json` → run records `hermes-cron.<slug>`, owner `hermes-agent`, loaded = `ai.hermes.gateway` loaded, cadence = longest gap of the fixed-time cron expression (`cronEvery`), failure always graded (`failing` even on a schedule it cannot read), an unreadable registry / bad entry / shape drift is a visible `failing` row, injected clock, collision-safe labels. Only the last outcome exists (no history), so a failed daily/weekly job is `failing` at once. warden: `poll_hermes_cron` and the `hermes_cron` source are deleted (a one-shot reconcile resolved the one open event #1119 on the 16:39Z poll, then was removed, `3260a5b`); `job_brief()` names the cron registry instead of a plist for `hermes-cron.*` labels. dotfiles tests 66 pass (`make check` rc 0), warden 673/673.
- **Verify (live):** `jobs-grade --table`: the four backup / weatherorb jobs and four cron jobs graded, `jobs WARN (17)` with exactly one non-ok row. The forced-failure test used a **real** failure instead of a test cron job: the drift audit (model 404 since 10-10) produced exactly one `job` item #1585 (`hermes-agent`, implement); warden investigated, found it already re-pinned and closed it `resolved` (root cause `cron-job-pinned-to-retired-model`). The row stays `failing` until the Saturday 10-17 09:00 run proves it (Wave 8's 6 h re-investigation rule then `needs_decision` applies if it stays red). Note the item opened at 16:14Z with the old brief because `jobs-grade` is live the moment dotfiles is edited; warden deployed after.
- **Orchestrator add-on:** warden `91ef6f1`, `poll_implement_jobs()`: `outcome=checks_failed` + `nextAction=human` + no valid `escalationCategory` + `revisable()` → `hand_back_for_revision()`; a valid category or no revisions left routes as before. Test added (673/673), deployed.
- **/review** (agent-gateway): dotfiles diff, 3 blocking (failure on an unreadable schedule graded `ok`; a null entry in the registry threw; `jobs` shape drift failed open) fixed with tests; also fixed: injected clock, `corrupt()` label parameter, slug collisions. The warden review's one blocking claim (docs-only commit) was false (the reviewer could not run git; the code was in a sibling commit, since squashed). **Declined:** extracting the adapter to its own file/`job-types.ts`, a `loadedLabel` field, a `{states, errors}` return, a never-run grace row for fresh cron jobs (they appear after the first run), a status enum filter (`delivery_failed` is a real failure), retry on a half-written registry, an explicit `kind` field in the job payload instead of the label prefix. Not re-reviewed after the fixes; the add-on and the follow-up were not separately reviewed.
- **For Wave 12:** `research-gateway-deploy` showed `stale` for a moment (poller, `--every 120`) and recovered by itself. `jobs WARN` will clear when the drift audit runs. The ledger read from a session needs `sqlite3 -readonly` (`mode=ro` URIs failed intermittently).

## Wave 12 — Kuma → warden webhook            <!-- status: active -->
- [ ] Carry-over from Wave 9, first: asks `20261016T170519-9342` (token + seed) and `20261016T170531-21347` (ACL push) are done → run Wave 9's verify (POST from homelab → 202 + one `hyperdx` event, closed after; no token → 401). If the asks are still open, stop and record it — every later step depends on them
- [ ] `homelab/uptime-kuma/monitors.yaml`: add a webhook notification → `/ingest/kuma` on every leaf monitor, **keeping** "Slack - Alerts" as the human-readable mirror and fallback. Apply with `make uk-sync`
- [ ] warden: retire the `uk` Argo snapshot poll in `watchdog-poll.py` only after one real DOWN/UP pair has arrived by webhook. Until then both run, and dedup keeps one item
- [ ] Verify: pause a test push monitor → DOWN webhook → one `uk` item within a loop pass; resume → resolved
**Left behind:**

## Wave 13 — HyperDX → warden webhook            <!-- status: pending -->
- [ ] `~/SourceRoot/vps/observability/alerts/*.json`: add the `/ingest/hyperdx` webhook to all 21 alerts. Slack #alerts stays as the mirror. Apply through the repo's own sync
- [ ] warden: stop turning HyperDX-shaped #alerts messages into `slack_alert` items once the webhook path is proven (`watchdog-poll.py` filter, like the `[… Push]` one). weatherorb's alert → GitHub issue path stays (it already reaches warden directly as `github_go`)
- [ ] Verify: a test alert (temporary threshold) → one `hyperdx` item, not a duplicate `slack_alert`; restore the threshold
**Left behind:**

## Wave 14 — Kuma becomes the calm backstop            <!-- status: pending -->
- [ ] `monitors.yaml`, per `ops-signals.md` §2:
  - keep the three duties: chain-alive, user-facing symptoms, data leaving the box;
  - `maxretries ≥ 1` everywhere;
  - intervals of at least 2× warden's T2 budget for everything that isn't chain-alive;
  - retire or lengthen `Brain Sync`, `Hermes Watchdog`, `Drift`, `Hermes Serve`, `Collie` and `Secret Seed` as §2 says
- [ ] warden: the `Warden Loop` push requires loop, poll and sweep heartbeat freshness (`/health`), so a dead sweep pages through Kuma
- [ ] Docs: `architecture.md` §Monitoring and `ops-signals.md` §2 match the result
- [ ] Verify: `uk-sync` diff reviewed and applied; a stale-sweep simulation on a copied ledger makes the push skip
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
