# Spike 1 — beads or the warden ledger as the Task system of record

- Status: result, ready to become the Task-SoR ADR (BRIEF Phase 4, spike 1). Date 2026-10-22. About 1 h 15 min of work, scratch only (`~/.local/share/factory/spikes/01-beads/`).
- Recommendation: **extend the warden ledger (SQLite) with `tasks`, `task_deps` and a ready query; do not adopt beads as the Task SoR now.** Confidence 80 %. Flip conditions in section 6.

## 1. Context and problem statement

One system of record for Tasks across about 34 personal repos (committed) and a few work repos (must stay out of their git). The mother → lead → wave model needs a blocker-aware ready queue, atomic claims, leases with heartbeat and reclaim after a crash, and read paths for Argo, warden and Hermes. Either adopt beads (`bd` v1.3.1, Dolt-backed) or extend the existing warden ledger (SQLite). Drivers: ready/claim correctness, crash behaviour, cost per call, operational surface, fit with both workspaces, access paths, churn risk.

## 2. Considered options

- **A. beads, per-repo embedded.** `bd init` per repo, Dolt linked into the 138 MB `bd` binary, single writer (file lock).
- **B. beads, one shared Dolt server.** One `dolt sql-server` (2.2.0, the pin) with one database per project prefix (`bd init --shared-server`).
- **C. warden-ledger extension.** `tasks` + `task_deps`, recursive-CTE ready query, claim lease by conditional UPDATE, heartbeat, reclaim. Built as `scripts/sqlite_tasks.py`, **65 lines**, bd-compatible verbs.

## 3. What ran

Install: release metadata for both projects (0.7 s); download bd v1.3.1 darwin-arm64 (48 MB) + checksums (2.5 s); Dolt v2.2.0 (41 MB, 1.8 s); sha256 against `checksums.txt` and API digests (1.6 s); extract each archive into its own empty dir, install into `bin/` (2.2 s). **Total 14.3 s.** From release metadata: beads v1.3.1 published 2026-09-30, npm `@beads/bd` 1.3.1 (2026-10-01, MIT); Dolt pin 2.2.0 (2026-07-15), Dolt latest 2.5.1 (2026-10-20). HOME was redirected into the scratch prefix.

Data (`02-build-datasets.py`): 210 tasks in three scratch repos.

|item|content|
|-|-|
|a) warden snapshot|43 open items (all `needs_decision`); 18 alert-origin are signals; **25 work items** (4 feature-shaped, 21 fix-shaped; 15 GitHub issues, 4 human requests, 6 jobs)|
|b) Round 5|epic + W1–W10 + 56 checklist tasks, 13 *Order* edges as `blocks`, plus the owner-decision gate on W4|
|c) fleet plans|weatherorb (active W84, pending W85–W87, held cutover, R1/R6, 4 parked decisions) and basalt-ui (W44 active, 13 pending waves), waves chained in file order|
|edges|31 local `blocks`, 158 parent-child, 2 cross-repo `external:`|

Repos: `df` (Round 5 + 11 warden items), `wo` (weatherorb + 14 warden items), `bu` (basalt-ui). **Load caveat:** load average 10–35 on 12 cores (about 20 during beads series, about 16 for the final baseline series); CPU ms per call is the comparable figure.

## 4. Measurements

### 4.1 Setup and footprint

|-|A embedded|B shared server|C SQLite extension|
|-|-|-|-|
|setup|3× `bd init -p <p> --skip-agents --skip-hooks`: 16.9 s (4.5–7.0 s each)|same + `--shared-server`: 25.9 s (first 13.5 s incl. server start)|two `CREATE TABLE` at first use|
|always-on processes|0|1 `dolt sql-server`: RSS 214 MB after setup, 312 MB after the run, 25 MB fresh; idle CPU 0.0 %; `bd serve` adds a helper (4.6)|0|
|binaries|`bd` 138 MB|`bd` 138 MB + `dolt` 113 MB|0|
|load of 210 tasks|237 s|119 s|10 s (38 ms per CLI call)|
|disk after the run|df 31 MB / 481 Dolt commits, wo 7.8 MB, bu 11.5 MB (54–66 KB per write)|per DB 31 / 7 / 12 MB; `.beads/` 24 KB per repo|128 KB for all 210 tasks|
|git after minimal init|5 files (4 under `.beads/` + `.gitignore` edit) + 1 auto-commit|same|none|

### 4.2 Per-operation latency, median of 20, wall ms / CPU ms

|op|A embedded (load ~20)|B shared (load ~18)|C SQLite CLI (load ~16)|
|-|-|-|-|
|create|963 / 483|282 / 120|46 / 36|
|update (CAS for C)|635 / 311|262 / 101|42 / 35|
|ready|531 / 276|172 / 103|40 / 33|
|claim|662 / 299|370 / 107|39 / 34|
|heartbeat|482 / 260|278 / 94|40 / 34|
|close|712 / 395|349 / 102|35 / 31|
|list / show|661 / 333, 653 / 323|198 / 111, 185 / 104|37 / 32, 39 / 33|
|process floor|`bd --version` 131 / 92|91 / 71|`python3 -c pass` 31 / 24|
|in-process|n/a|n/a|ready query 0.34 ms|

Scale (synthetic backlog, `14-scale.py`, `07-baseline-bench.py`):

|tasks|A embedded|B shared|C SQLite in-process ready|
|-|-|-|-|
|1,000|import 25.8 s, 103 MB; ready 383 / 306, create 825 / 581|import 44.3 s; ready 140 / 92, create 303 / 110|0.9 ms, 108 KB|
|2,000|import 87.3 s, 219 MB; ready 499 / 400, create 1,502 / 833|import **failed** at 32.7 s, about half in|5,000: 5.5 ms; 20,000: 26 ms, 1.7 MB|

### 4.3 Semantics and correctness (both topologies unless noted)

|check|result|
|-|-|
|`bd ready` vs independent oracle (210 tasks)|exact match for `df`, `bu`; a blocked epic blocks its children. **`ready` includes epics and decisions**: the mother must pass `--exclude-type epic,decision` (17 of 20 `df` rows are leaf work)|
|chain, reopen, `related`/`discovered-from` non-blocking, cycle rejected|pass; cycle exits 1 at write time|
|fan-in, two blockers closed concurrently, 8 rounds (the 1.3.1 fix)|0 dependents lost|
|claim race, 2 workers, 12 tasks|12 of 12 one winner; loser exit 1|
|fencing|a non-holder can neither claim nor close a held task (exit 1)|
|compare-and-set|exit **13** only on a pure guard mismatch; CAS-claim over a held task is exit 1; **a CAS-claim takes no lease**|
|**`external:` deps**|**0 of 9 scenarios block `bd ready`** (project unconfigured / relative / absolute path × unshipped / closed / shipped); `--explain` says "1 blocker(s) resolved". Enforcement (#4753, 2026-09-02) is under `[Unreleased]` on `main`; the v1.3.1 tree has no `externaldeps` package|
|baseline C vs same oracle|exact match for all three repos; cross-project edge is an ordinary edge|

### 4.4 Crash semantics (`mother.sh`, 26 lines, same for both backends)

Two loops claim a task each and heartbeat every 5 s; one is `kill -9`'d, one `SIGSTOP`'d; a third drains the rest; a reaper polls reclaim from the kill.

|-|A embedded|B shared|C SQLite (TTL 30 s)|
|-|-|-|-|
|stranded after kill|`in_progress` under the dead worker, absent from ready|same|same|
|reclaimed after|**305 s**|**309 s**|30 s (configurable)|
|resumed zombie|next heartbeat fails, learns the lease is gone|same|same|
|kill to all closed|317 s|317 s|36 s|
|2 loops racing, 12 tasks|0 double claims|0|0|

The beads TTL is `DefaultLeaseTTL = 5 * time.Minute`; a context override exists for tests and SDK callers only. `bd reclaim --older-than` is a grace on top of expiry. `bd serve` has 35 paths and no heartbeat or reclaim.

Storage layer (`10-storage-crash.py`): embedded, 10 rounds, 8 `bd create` killed mid-write: nothing lost, no stale lock, next command OK (median 0.67 s). Shared: `dolt sql-server` kill -9 under a write stream ×3: **no acknowledged write lost (14, 9, 14); bd never restarted the server (3/3)**; every command fails with `circuit breaker is open: server appears down, failing fast` until `bd dolt start` (1.3–2.0 s), first successful read 0.2–4.5 s later. SQLite: 10 kills, 35,727 acknowledged commits, 0 lost, integrity ok.

### 4.5 Concurrency (`05-concurrency.py`)

|-|A embedded|B shared|
|-|-|-|
|2 writers × 25 creates|51 s; median 1.05 s, p90 3.4 s, **max 13.0 s**; 0 failed, 0 lost|8.7 s; median 306 ms, p90 419 ms, max 860 ms; 0 failed|
|4 readers × 10 `ready`|median 1.05 s, p90 2.5 s, max 7.7 s|median 160 ms, p90 236 ms, max 342 ms|

### 4.6 IuRoot fit (`08-iuroot.py`, synthetic repos, fake origin on a reserved host)

|variant|tracked change in work repo|other|
|-|-|-|
|default `bd init`|**19 tracked files** (`CLAUDE.md`, `AGENTS.md` rewritten, `.claude/`, `.codex/`, `.cursor/`, hooks), 1 commit|`core.hooksPath` -> `.beads/hooks`|
|`--skip-agents --skip-hooks`|5 files, 1 commit|docs: origin becomes `sync.remote`|
|`--contributor` (wizard; `--non-interactive` rejects it; answering N still initialises and commits)|**tracked `.beads/*` + `.gitignore`, 1 commit; planning-repo path in tracked `config.yaml` as an absolute home path**|routing works: issues land in the planning repo outside the work repo and show in `list`/`ready` from both|
|**`BEADS_DIR` outside + `--stealth`**|**none**|3 lines in `.git/info/exclude`, `[beads] role` in `.git/config`; every command needs `BEADS_DIR`|
|`--stealth` in repo|none|`.beads/` excluded locally|
|C ledger|none by construction; one `TASKS_DB` per workspace|-|

Also: `bd config set external_projects.<p> <path>` edits tracked `config.yaml` with a machine path; `bd dolt push` adds `refs/dolt/data` and an extra branch `refs/heads/__dolt_remote_info__` to the code remote.

### 4.7 Access paths (shared topology)

|path|latency|notes|
|-|-|-|
|CLI per call|161 ms wall / 102 ms CPU (embedded 531 / 276)|JSON; `--brief` barely shrinks `ready` here (48 → 46 KB)|
|`bd serve` HTTP|`ready?limit=100` 29 ms vs CLI 161 ms; `limit=1` 10 ms; `stats` 4 ms; `issues?limit=50` 13 ms; `claimNext` 54 ms; `close` 90 ms|needs the Dolt server; typed 409 `already_claimed`; lease fields present; **no heartbeat, no reclaim**; events endpoint returned 409 (journal off)|
|JSONL export|232 issues, 0.36–0.82 s, 100 KB, labels and dependencies included|`owner` = git email|
|git remote, backup|`bd dolt push` 3.2–3.6 s, 4 MB; fresh clone + `bd bootstrap` 2.4 s restores all 233; backup sync 0.4–1.1 s, restore 0.5–0.7 s|works|
|direct SQL|not measured|couples to a moving schema (v66)|
|C in warden|0.34 ms query in the service that owns the ledger|Argo reads warden's API|

## 5. Failure modes observed

1. `external:` deps inert in the pinned stable release (0 of 9).
2. `bd init` rewrites the repo contract; minimal flags still commit 5 files; contributor routing does not meet "nothing tracked".
3. Shared Dolt server not self-healing (3 of 3); a supervisor and a monitor become new always-on duties.
4. `bd serve` leaves an orphaned `bd db-proxy-child` (parent 1, `--idle-timeout -1ns`, two random loopback ports) after a graceful stop (3 of 3, `17-serve-leak.py`).
5. Crash-detection floor 5 min, untunable; no HTTP heartbeat or reclaim.
6. Embedded: 0.5–1.0 s wall and 0.26–0.48 s CPU per call, growing with size; 13 s worst wait with two writers; 54–66 KB history per write.
7. Server-mode `bd import` failed at 2,000 issues after 32.7 s, not atomic, cause not diagnosed.
8. Lockstep reproduced (`11-lockstep.sh`): bd 1.1.2 database (v53) migrated in place to v66 by the first 1.3.1 command (2.2 s, no consent on embedded); the old binary exits 1: `schema version mismatch: database is at v66, binary knows up to v53 (13 migrations ahead)`; `BD_IGNORE_SCHEMA_SKEW=1` allows reads.
9. Usage metrics on by default (command names, version, platform, machine-derived id; `bd metrics off`; wire traffic not captured).
10. Re-`init` with a used prefix on the shared server is refused (identity guard).
11. Traps: `ready` lists epics/decisions; CAS exits 13 only on guard mismatch, claim conflicts exit 1.

## 6. Decision outcome

**Chosen: C, extend the warden ledger.** Add `tasks`, `task_deps`, an append-only `task_events` in the same transaction, the ready CTE, `claim`/`heartbeat`/`reclaim` as conditional UPDATEs, and a thin `warden task ...` CLI that keeps bd's verbs and JSON field names so agents and a later swap lose nothing. Plan files stay the plan source; the `02-build-datasets.py` parser is the first projector. Argo and Hermes read warden's API.

Why, by weight:
1. **Parity is cheap.** 65 lines pass the same oracle, claim-race, crash and zombie tests with an unchanged mother loop, a configurable lease (30 s vs 305 s), working cross-project edges, 3–14× less CPU per CLI call (31–36 ms vs 94–483 ms) and 0.34 ms in-process.
2. **The headline reasons for beads do not hold in v1.3.1**: `external:` inert, the IuRoot answer touches the work repo, the HTTP path lacks the lease keep-alive.
3. **Operational surface.** A adds a 138 MB binary, a lock queue and auto-migration per repo. B adds a process that does not recover alone, a Dolt pin three minor lines behind upstream (Homebrew's `beads` formula depends on the unpinned `dolt`, 2.5.1 today, which beads calls unmeasured past 2.3.1) and consent-gated migrations.
4. **Tasks join with warden items, attempts and incidents.** With beads that link crosses two stores and needs a one-way projector without joins.
5. **IuRoot fits structurally.** The ledger sits outside every repo; one `TASKS_DB` per workspace.
6. **Churn** (section 7).

**Confidence 80 %.** What beads got right is real (exact ready semantics, the fan-in fix, claim arbitration, fencing, no lost writes in 13 kills, fast server mode). It argues for borrowing the design, not taking the runtime.

Feature delta the extension must add (estimate, not measured: about 5× the baseline, 300–400 lines plus migration and tests): `task_events` history, label filters, comments, hash-style ids, JSONL/projection export. Close fencing is already in the baseline. Not needed: molecules, formulas, wisps, federation, gates, `bd prime`. **Risk to carry:** one SQLite file is one disk, and warden's backup target (the homelab HDD) is itself an open warden item today, where `refs/dolt/data` would give a free off-box copy; add Litestream or the nightly copy to the ADR.

**Flip conditions**, each testable by re-running the scripts:
1. A stable beads release enforces `external:` (`03-topologies.py`, `enforced_in_ready` true) and the owner wants plan-to-plan edges.
2. Two stable minors with no schema migration or patch-level JSON/exit-code change (`11-lockstep.sh` as the gate) and the Dolt pin within one minor of upstream.
3. A second writer host (Dolt remotes then beat one SQLite file).
4. A configurable lease TTL and heartbeat/reclaim over HTTP.
5. The first wave that builds C measures more than about 5× the baseline.

If Phase 3 moves warden to a Postgres-based durable engine, the Task tables move with it; the ready CTE ports unchanged and the decision stands.

## 7. Risks with evidence

|risk|evidence|
|-|-|
|release and schema churn|20 tags in the 6 months since v1.0.0 (10 stable). v1.2.1 "published by accident, without release testing" 2026-08-11 (GitHub prerelease, npm 22:19 that day; v1.2.2 on 08-15 re-cut the 1.1 tree): any command with it migrated schema v53 to v65, later binaries refuse it, recovery is a hand-edited schema cursor. v1.3.1, a patch, has 17 behaviour-changing upgrade notes; v1.3.0 has 27 plus 18 breaking changes. Backend went JSONL, SQLite, Dolt between v0.50 (2026-02-14) and v0.58 (2026-03-03). Stable lags `main` by 630 commits|
|lockstep|failure 8; embedded migrates without consent, a shared server never auto-migrates (`bd migrate schema` after every client upgrades), mixed versions are refused|
|Dolt as a process|failures 3 and 4; pin 2.2.0 vs latest 2.5.1; `releases/latest` can move backwards (a v1.88.2 was created after v2.3.0)|
|integration|CLI per call 0.1–0.5 s CPU; HTTP fast but needs the server and lacks keep-alive; direct SQL couples to a moving schema|
|repo hygiene, telemetry|failures 2 and 9, the `__dolt_remote_info__` branch, auto-set sync remote|

## 8. Not measured, caveats

Metrics wire traffic; direct MySQL-protocol reads; `bd gc`/`flatten` effect on disk; proxied-server mode (experimental); other platforms. Datasets are real but small (210 tasks); scale numbers are synthetic. The baseline is deliberately minimal, so section 6's feature delta is the honest comparison. The first embedded run (`topology-embedded.json`) measured 20 refused closes and one external case; `topology-embedded-rerun.json` supersedes both. The events-endpoint 409 is attributed to the journal being off, not verified.

## 9. Files and reproduction

Scripts in `scripts/`, run in this order with `python3 -I` or `bash`: `01-install.sh`, `02-build-datasets.py`, `03-topologies.py embedded|shared`, `03c-rerun-embedded.py`, `04-serve.py`, `05-concurrency.py`, `06-crash.py beads embedded|shared` and `sqlite` (beads runs take about 6 min), `07-baseline-bench.py`, `08-iuroot.py`, `09-export-backup.py`, `10-storage-crash.py`, `11-lockstep.sh`, `12-merge.py`, `13-release-churn.py`, `14-scale.py`, `15-cas-probe.py`, `16-disk.py`, `17-serve-leak.py`. Shared: `lib.sh`, `spike.py` (its oracle is the acceptance test for any implementation of option C). Baseline `sqlite_tasks.py`, loop `mother.sh`, parity test `test-baseline.sh`. Raw output: `measurements.json`, `results/*.json`.
