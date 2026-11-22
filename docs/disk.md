# Disk — the mini's 1 TB, accounted for

The mini's Data volume is 926 GiB. On 2026-10-20 it had 66 GiB free, and weatherorb's round
builds (~22 GB transient) pushed it toward the 50 GB `disk_low` floor. After one audit wave
(dotfiles `docs/waves/PLAN.md` Wave 1) it had 431 GiB free at 19:00 (two blend rounds on disk, no third in flight). This page is the budget, the
sweeps that hold it, and where the moved data lives.

## Budget per owner

Measured 2026-10-20 after the cleanup, `du -xk`, GiB. Used ≈ 480 GiB.

| Path | GiB | Owner / purpose | Class |
|-|-|-|-|
| `~/SourceRoot/weatherorb` | 158 | weatherorb production, re-measured 2026-11-11 (the 2026-10-20 audit read 135): `products/` 47 (after Wave 82, the shadow retirement), `data/` ~89, peaking ~100 with the chunk sawtooth (`ecmwf_ifs` 36.6 came back on trial 2026-10-21 under the owner's no-disk-bar ruling; retention is healthy, a dry run frees 0), `var/` 22 | needed. weatherorb's moves are weatherorb waves. Its S3 archive (Wave 81, ADR 0009) moves `var/` past-track and dumps, never `data/` |
| `~/.colima` (data disk, sparse) | 78 | Colima VM. Docker: images ~30, named volumes ~48, build cache capped at 15 | needed. Swept daily |
| ↳ volume `student-enrolment_mysql-data` | 29 | IU epos.student-enrolment local MySQL (container `idss-mysql`, running) | **ask owner**: IU student data, see below |
| ↳ volume `vps_clickstack-ch-data` | 9 | local ClickStack telemetry, no container | ask owner (likely waste) |
| `~/Library` | 36 | Chrome profile 6.3, Caches ~14, Notion, Teams, Slack, MacWhisper | needed (app state) |
| `~/SourceRoot` other repos | 30 | node_modules (argo 2.9, basalt-ui 1.9, …), `shutterflow/target` 8.5 (active Rust build) | needed. Regenerable |
| `EXT` volume (external USB SSD, APFS + FileVault, 931 GiB, 526 used, 406 free, measured 2026-11-14 by issue 1238: `Bilder` 169, `weatherorb` 167, `Videos` 110, `usb-rescue` 11, `Steuer` 7, `mirror` 3) | 0 internal | `weatherorb/` (weatherorb's working data), `mirror/` (the nightly pulled HomeLab copy, row `ext-mirror`); the other top-level folders are the owner's and leave in rows `storage-consolidate` and `ext-mirror` | **external**. Not part of the 926 GiB; it is on the internal budget's relief side. Read and written only behind the volume gate: `docs/external-ssd.md` |
| `~/.local` | 25 | usage-tracker 3.8, opencode 3.7, fnm 3.3 (16 node versions), IU `prometheus-scripts` state backups 6.8 (hourly 48 h + daily 30 d, bounded by `com.iu.prometheus-state-backup`) | needed |
| `/private/var` | 20 | `$TMPDIR` 17 (Chrome code-sign clones, test-suite tmp dirs), system | swept |
| `~/Pictures/Photos Library` | 105 (measured 2026-11-20, Issue 2566; 19 at the 2026-10-20 audit) | the signed-in iCloud Photos client, the source of the nightly export (`docs/storage.md` §iCloud Photos export) | needed. Grows by about 15 GiB a year; the export job refuses to start below 40 GiB free. Measured before the toggle, 2026-11-14: Data volume 292 GiB free of 926 (68 % used). Measured 2026-11-20: 74 GiB free, 92 % used, with the library at 105 GiB; the 77 % projection for after the download is superseded |
| `~/.claude` | 16 | Claude Code transcripts (`projects/`; argo 6.8) | needed (Claude Code prunes by `cleanupPeriodDays`, 7 days; see §Sweeps) |
| `/opt/homebrew` | 16 | Cellar 8.6, postgresql@18 data 6.0: the mini's one Postgres (`docs/postgres.md`), stays on this disk; grows by about 4 GB with the Docker and Athena databases at the cutover, and lost 1 GB of leaked weatherorb test databases on 2026-11-14 | needed |
| `~/IuRoot` | 13 | IU repos. `prometheus-scripts/analysis` 4.6 (`kafka-snapshots` 3.4) | ask owner (IU data, below) |
| `/private/tmp` | 12 | agent scratch (`basalt-briefs`, `pytest-of-root`, wave logs) | swept by the `tmpdir` step (entries > 3 days) |
| `/Applications` | 11 | apps | needed |
| `/Library` | 7.5 | system-wide | needed |
| `~/.hermes` | 7.2 | Hermes agent: install, `state.db` 1.6 | needed |
| `~/cache/<repo>/seed` | ~9 per Rust repo | cargo-target-seed seeds (`docs/cargo-target-seed.md`); an old one goes a day after its successor | pruned by the tool and by the sweep's `seeds` step |
| `~/.cache` | 4.5 | uv 2.3, puppeteer, … | swept |
| everything else | ~15 | `~/go` 2.7, `.rustup` 2.1, … | needed |

The VM volume (swap, 5 GiB) and the System, Preboot and Recovery volumes (~22 GiB) sit outside
the Data volume.

## What the audit removed

| What | Freed (host `df`) | Why it could go |
|-|-|-|
| `~/.Trash` | 246 GiB | Finder's Trash on a headless machine is never emptied. Held Plex 108, OrbStack 23, game and app bundles, movies and old repo copies. The owner approved emptying it in the native dialog |
| Colima `fstrim` after the prunes | 37 GiB | the data disk is a sparse file. Pruned blocks return to macOS only on trim |
| `~/.colima/_lima/_disks/colima-w50` | 28 GiB | orphaned data disk from weatherorb Wave 50's VM proof. `colima delete` keeps the data disk unless you pass `--data` |
| `/Users/Shared/Epic Games` | 13 GiB | 2023 game installs, no launcher installed |
| Android SDK + AVD `w18_api35` + `~/.gradle` caches | 11 GiB | weatherorb's mobile app is paused until its UI rewrite. Reinstall below |
| bun, npm, uv, Homebrew caches | 19 GiB | package caches |
| Docker build cache and stale images (> 14 days) | ~13 GiB in the VM | regenerable |
| Personal media moved to the HomeLab (table below) | 7.6 GiB | copied, verified, then deleted |
| `$TMPDIR` test leftovers | 4 GiB | 239k leaked tmp dirs (test suites) |

## Alert

One alert, in ClickStack (vps registry): `Infra mini filesystem >= 93% (15m)` on `system.filesystem.utilization` for `/System/Volumes/Data`, 5 min evaluation. the heartbeat's `disk` check (`check_disk`, `scripts/devhost-health-check.sh`) FAILs at 93% too. The 90% line of the retired Beszel rule is gone: the sweeps below run before the alert, so a page now means the sweep did not hold. Kept at 93% on 2026-11-20 (Issue 2566): the volume now rests at 92-94%, so one build crosses it; see the Issue 2566 entry below.

## Sweeps: what keeps it this way

Two LaunchAgents run `scripts/disk-sweep.sh`; every step is one bounded rule that prints one `<step>: …, free space +N MB` line to
`~/Library/Logs/disk-sweep.log`.

| Job | Cadence | Runs |
|-|-|-|
| `com.jkrumm.disk-sweep-fstrim` (`disk-sweep.sh colima-trim`) | every 4 h, at :15 | `colima-trim` alone: returns what the Colima data disk regrows between the daily sweeps (20+ GiB within hours, Issue 2315). Its log line reads `disk-sweep: 1 steps` |
| `com.jkrumm.disk-sweep` (`disk-sweep.sh`) | 04:40 daily | every step below, in this order |
| `com.jkrumm.log-rotate` | every 15 min | owned logs at 16 MB, Chrome `code_sign_clone` dirs > 2 h (one `lsof`, background priority, 4 rm workers, at most 1500 removals or 300 s per run, counted from script start; the lsof is bounded at 90 s). Agents launch ~300-600 Chrome/h; the 24 h gate at 400/h grew the stock to 14k clones (a clone is mostly shared APFS blocks, ~0.5 MB real, so the stock is a load and inode burden more than a disk one; the 16-49 GB/h disk page of issue 839 recovered on its own to 86.6% within the hour, consistent with the weatherorb round-build transient of ~22 GiB above; the writer was not caught in the act, see "Round-build page" below) |

| Step | Removes | Never |
|-|-|-|
| `tmpdir` | top-level entries > 3 days in `$TMPDIR` and in this user's `/private/tmp` (macOS does not clear it) that nothing holds open and nothing beneath is recent | Apple-owned, `.lock`, sockets, `sunlnk` entries; with no `lsof` answer it removes nothing |
| `node-cache` | files in `$TMPDIR/node-compile-cache` not written for 3 days | |
| `pkg-caches` | `uv cache prune` (probes the lock 20 s, then `--force`; the holder is named), `brew cleanup -s`, npm cache over 3 GB, bun cache over 5 GB | |
| `lima-cache` | Lima IPSW downloads untouched for a day | while a `limactl create/start/clone` runs |
| `sim-runtimes` | simulator runtimes: per platform the newest version stays, every other deletable one goes (iOS 27.0 beside 27.1 is 8 GB) | the newest per platform; a runtime `simctl` calls not deletable |
| `simulators` | `simctl delete unavailable` (the devices a removed runtime orphaned) | |
| `worktrees` | a closed Issue's factory worktree `target/` (beside a `Cargo.toml`) and `node_modules/`, where `factory issue show` says `closed` | the source; an Issue the factory cannot show |
| `seeds` | in `~/cache/<repo>/seed`, every seed a day old except the seed of the key `cargo-target-seed` prints for the repo's main checkout and the newest. The key's options are the ones the tool recorded in `seed/.args` on its last clone or build | a seed of the current key; any seed of a repo whose key cannot be computed (no `.args`, no checkout, no tool): the line names it. `.args` is written by the next clone or build, so seeds a repo made before that keep until then |
| `scratch` | (1) `~/cache/<repo>/<issue>` of a closed Issue; (2) any directory in `~/cache/<repo>/` or `~/cache/` whose name carries Issue ids (runs of 3-6 digits, leading zeros dropped: `scratch2802`, `e028-rerun`, `weatherorb-2171`) that are all closed, once nothing beneath is under 2 days old; (3) anything else directly in `~/cache/<repo>/` (a repo under `~/SourceRoot` or `~/IuRoot`) untouched 14 days; (4) `~/.cache/cloud-wave` directories untouched 14 days; (5) sccache over `DISK_SWEEP_SCCACHE_MAX_GB` (5) | `seed`; top-level files of `~/cache`; a name with an id the factory cannot show, or one Issue still open (an epic number such as `e233` that is no Issue keeps the dir for the 14-day rule) |
| `docker` | build cache LRU-capped at 5 GB (`--all`, or the cap is not honoured), dangling images, tagged images no container uses and built over 48 h ago (the VPS cron's rule), unused anonymous volumes (a 64-hex name, removed by name) | a volume with a name: unused ones are only listed in the log with their size; containers; an image a container references |
| `colima-trim` | `colima ssh -- sudo fstrim -a`: returns the pruned blocks to the host | |

Run it once with `make disk-sweep-run`. That target is also the sanctioned route for the docker prunes, because the `docker-makefile`
hook blocks raw docker in this repo.

**Claude Code transcripts** are bounded by Claude Code itself, not the sweep: `cleanupPeriodDays` is 7 in `config/settings.template.json`
(Issue 2845; the default is 30, the minimum 1, and 0 is a validation error). At startup it deletes `~/.claude/projects/*/*.jsonl`
with their subagent and tool-result spills, `file-history`, `plans`, `debug` and other session data older than that; auto-memory
files stay. `projects/` was 31.6 GB with 21 MB older than 14 days, growing 2.2 GB a day. Every account home that shares `projects/`
must carry the same value (`docs/claude-accounts.md`). A session older than 7 days cannot be resumed.

## Round-build page ("disk filling fast")

Caught in the act on 2026-11-12 (issue 864, 87.7%, "+13.9 GB/h"): weatherorb's `worker-round`
writes the next blend round to `products/weatherorb_blend/.building-<round_id>/` (hidden, so a
plain `ls` misses it) while `current` and `previous` (~24.4 GB each) are still on disk, so a
round in flight is three rounds, ~73 GB, for the ~2 h a build runs. At commit the oldest is
removed and the stock falls back to ~49 GB. The page fires every 3 h round with a growth slope
over 0.5 GB/h and ~87-89% used; the peak stays under the 90% line only while the rest of the
volume holds ~110 GiB free. Nothing leaks: confirm with
`du -xsk ~/SourceRoot/weatherorb/products/weatherorb_blend/.building-*` (grows ~7 MB/s) and the
`free space` drop after the round commits. Act only when used stays above 90% after a commit
or `.building-*` outlives its round (> 3 h, a crashed build leaves it). The page's rule was Beszel's (retired 2026-11-19); the live alert is ClickStack's, see §Alert.

Issue 909 (2026-11-12, 90.2-90.4% for ~25 min) was the same transient with less headroom: the
`1300Z` build held 23 GB of ~24 GB, `products/` read 73 GB (three rounds), and the commit at
~16:30 brought used to 88% (120 GiB free). The line is now crossed at the peak because the rest
of the volume grew since 2026-10-20 (re-measured the same day, `du -xk`, GiB):

| Path | GiB | Was | Note |
|-|-|-|-|
| `~/.colima/_lima/_disks/colima` | 91 | 78 (whole `~/.colima`) | main docker VM, swept daily |
| `~/.colima/_lima/_disks/colima-athena-poc` | 4.7 | n/a | no `in_use_by`, last written 2026-10-31: orphan PoC disk. Its profile was deleted on 2026-11-14 (issue 1119, nothing referenced it) without `--data`; the disk itself is the owner's call |
| `~/Library` | 66 | 36 | `Application Support` 20 (Chrome 9.8), `Developer` 18 (CoreSimulator 11, Xcode 6.6), `Caches` 14 |
| `~/.claude` | 27 | 16 | transcripts (`projects/`) |
| `$TMPDIR` / `/private/tmp` | 23 / 21 | 17 / 12 | |

A page with `.building-*` present and `products/` near 73 GB needs no action; a repeat at the
same peak means the baseline above, not weatherorb, needs trimming (CoreSimulator runtimes
and the orphan PoC disk are the cheap first cuts, both owner calls).

## Factory worktree stock (disk page at 90%, no `.building-*`)

Issue 1000 (2026-11-13, 90.1% flat for 10 min, 794 GiB used) was the baseline, not a round build:
`~/SourceRoot/<repo>/.claude/worktrees/factory-N-1` is never removed after the Issue closes
(the factory's Reaper ends processes, not directories; filed as issue 1003). basalt-ui held 84
(51 GB, ~600 MB each of `node_modules`), software-factory 71 (26 GB), iris 8, agent-workflows 12.
Removing those whose Issue is closed and whose branch has a MERGED PR (or, direct-to-master, whose
HEAD is an ancestor of `origin/HEAD`) took the volume from 90% to 88% (108 GiB free). A page that
arrives with no `.building-*` present: `du -xsh ~/SourceRoot/*/.claude/worktrees`, then
`factory issue show issue_<N> | jq -r .state` per directory, and `git worktree remove --force`
the closed, merged ones. Keep a closed one whose branch has no merged PR and unmerged commits.
Other cheap cuts if it recurs: `~/.local/state/athena-poc` 22 GB (Oct 30 - Nov 2 PoC runs),
`~/.cache/cloud-wave` 10 GB, `~/.colima/_lima/_disks/colima-athena-poc` 30 GB sparse (owner calls).

## `/private/tmp` stock (disk page at 94%, no `.building-*`, worktrees small)

Issue 1026 (2026-11-13, 94% flat for 95+ min, 58 GiB free) was neither a round build (two
rounds in `weatherorb_blend`) nor worktrees (basalt-ui 13 GiB, the rest under 5). `/private/tmp`
held 32 GiB in ~21.8k entries (12 GiB on 2026-10-20) and nothing swept it. The mini kernel-panicked
that evening (watchdogd starved, ~19:00 CET) and the reboot emptied it: 85%, 138 GiB free, 12
entries. The swap headroom at 94% was thin (swap 9-14 GB over 12 swapfiles in `/private/var/vm`
before the panic; none after the reboot), so a full volume is part of panic prevention. Next
time: `du -xk -d1 /private/tmp` once (a `du` per entry forks out at 20k entries), clean what is
older than 3 days that nothing holds open. Still on disk, owner calls: `~/.local/state/athena-poc`
22 GiB (`investigate/` 20 GiB, untouched since Nov 2), `~/.cache/cloud-wave` 10 GiB,
`colima-athena-poc` 4.7 GiB. Issue 2830 (2026-11-21) put `/private/tmp` into the sweep's tmpdir step, for this user's top-level entries only (root's, such as `pytest-of-root`, stay). The root cause, which writer leaked the 20 GiB, is still not caught.

## Lima macOS VMs (disk page at 95%, no `.building-*`, worktrees reaped)

Issue 1123 (2026-11-14, 90.9% then 95%, 46 GiB free at the low) was ntfy-mac's clean-machine install
matrix (issue 1115), run from `scripts/clean-machine/` in that repo: macOS guests under `~/.lima/cm-*`, each a
64 GiB sparse disk that reached 26-29 GB after first boot, a `limactl clone` per channel (`cm-26-clt`,
`cm-26-brew`), and the IPSWs in `~/Library/Caches/lima/download` (19.8 and 16.8 GB, kept after the VM exists).
About 130 GB across 5 VMs and 2 IPSWs, written within an hour (25.8 GB/h on the disk page's tail), which is why the
page read 90% and not the round-build shape. Cut: the macOS 26 IPSW (the VM existed), the closed, merged
factory worktrees (basalt-ui 14 GB), and the signal to issue 1115 to `limactl delete` each clone after its
result. `disk-sweep` now carries a `lima-cache` step for the IPSWs. The VM disks themselves are the matrix's:
`limactl list` and `du -sk ~/.lima/*/disk` name them; a stopped `cm-*` whose result is recorded is safe to
`limactl delete -f`.

## Rust worktree `target/` dirs (disk page at 91-92%, no `.building-*`)

Issue 1771 (2026-11-16, 90.9-92.1% for 55+ min, 76 GiB free at the low) was shutterflow's live leads: `~/SourceRoot/shutterflow/.claude/worktrees`
held 126 GB by `du`, nearly all `target/` (one lead's 61 GB, running `cargo check` for two extra targets; the others 17-30 GB). A `target/`
cloned from `~/cache/shutterflow/seed` shares blocks until it is written, so `du` overstates the host cost; the growth is what a lead
compiles itself. Cut: the `target/` of the one closed Issue (its source and a dirty file that is not on master stay), 20 GiB back,
and 17 closed, merged basalt-ui worktrees (about 1.4 GB each). The page came back at 90.2% within the hour; `make disk-sweep-run`
(the Colima data disk had grown to 113 GiB, `fstrim` returned 21 GiB) brought it to 89%, 100 GiB free. The daily 04:40 sweep alone
does not hold the line while three shutterflow leads build at once. The live leads' `target/` dirs are theirs and stay. A repeat: `du -xsh ~/SourceRoot/*/.claude/worktrees`,
then `du -xsh <worktree>/target` per live lead, and `rm -rf` the `target/` (never the worktree) of a closed Issue whose work is not merged.

Issue 1912 (2026-11-17, 90.8% rising to 92%, +46 GB/h, 77 GiB free at the low) was the same shape: no `.building-*`, no Lima VMs,
and shutterflow's worktrees at 219 GB by `du`. Two live leads' `target/` dirs read 79 and 70 GB (they grow while the leads compile); three
closed Issues (1732, 1733, 1750, PRs merged) still held 15-32 GB of `target/` each. `git worktree remove --force` on those three freed 38 GiB
(92% to 88%), and on 8 closed, merged basalt-ui worktrees a little more. Their `D` status lines (hundreds of deleted tracked files) mean an earlier
partial cleanup, not unmerged work; check `gh pr list --state merged --head <branch>` before removing. A repeat with the same two leads still
compiling means shutterflow's leads need a shared `CARGO_TARGET_DIR` or a cleanup step on close, not another manual reap: file it against shutterflow.

Issue 1961 (2026-11-17, `MacMini Dev Host Detail - Push` DOWN, disk 92% to 94% in 22 min, 62 GiB free, over the 93% FAIL line) was the same shape a third time:
two live shutterflow leads held 30 and 32 GB of `target/`, and two closed, merged Issues (1721, 1745) another 51 GB. `git worktree remove --force` on those two
brought it to 91%, 89 GiB free. The Photos library (110 GB, still downloading originals) is the other riser; it is not reapable. The detail
monitor is a disk gauge too: its DOWN means `disk` crossed 93% for three runs, so read the `FAIL:` clause of the last `~/Library/Logs/devhost-health.log` line first.

Issue 2020 (2026-11-17, same monitor, 93% with 70 GiB free after 91% an hour earlier) was a fourth time: live shutterflow leads held 74 GB (1925) and 17 GB (1755) of `target/`,
and the closed, merged Issue 1934 another 26 GB; `git worktree remove --force` on that one gave 90%, 97 GiB free. The reap-on-close or shared `CARGO_TARGET_DIR` ask is on shutterflow's open issue 1773; until it lands, expect a fifth.

Issue 2081 (2026-11-17, same monitor, 94% with 63 GiB free) was the fifth, after 1773's reap-on-close had landed (shutterflow `2329fa63`, 16:59Z): every closed Issue's `target/` was already gone, and the one live lead (1925) held 81 GB of `target/debug` by `du` alone. Reap-on-close does not bound a live lead's growth. `make disk-sweep-run` (Colima `fstrim` +18 GiB, npm and bun caches +7 GiB, +24.8 GiB in all) took it to 91%, 87 GiB free and the monitor recovered on the next run; nothing of a live lead's was touched. Order for a repeat: `du -xsh ~/SourceRoot/*/.claude/worktrees/*/target` (reap only closed, merged Issues'), then `make disk-sweep-run`. The live-growth bound is a signal on shutterflow.

Issue 2163 (2026-11-17 23:00Z, 95% with 48 GiB free) was the sixth. Live shutterflow leads 1892 and 1893 held 28 and 26 GB of `target/`, and closed Issue 1889 (PR 57 closed unmerged, Issue done) another 14 GB; its `target/` went, the worktree stayed. `make disk-sweep-run` freed about nothing: Colima `fstrim` +6 MB, and the uv prune was skipped because another uv process held its lock (pid 69270). Removing `~/Library/Caches/Mozilla.sccache` (9.3 GB, regenerable) together with 1889's `target/` brought it to 93%, 68 GiB free. The next regenerable cuts are sccache (9 GB) and `~/.cache/uv` (8.6 GB); the sweep's uv step is skipped whenever a uv process holds the lock, so the sweep alone will not reach them. The structural fix is still shutterflow's issue 1773 (reap on close or a shared `CARGO_TARGET_DIR`).

Issue 2175 (2026-11-18 02:19Z, `MacMini Dev Host Detail - Push` DOWN; Issue 2174, the vps disk page, was the same event) was the seventh: free space fell from 100 to 54 GiB in 50 minutes (89% to 94%, the `disk` FAIL at 93% for three runs) under `rustc` and a shutterflow test binary, then came back to 68 GiB by itself once the build ended. No closed Issue's `target/` was left to reap (live 1896 and 1897 held 16-18 GB each, the main checkout 16 GB). `make disk-sweep-run` did the work this time: Colima `fstrim` +22.7 GiB (the data disk had regrown to 55.7 GiB trimmed), `$TMPDIR` entries older than 3 days +1.7 GiB, package caches +2.6 GiB, 17.9 GiB in all, 93% to 91%, 84 GiB free. The uv prune was skipped again (a uv process, pid 69270, holds the cache lock). Read it as: the sweep returns the Colima disk, and a live build swings the volume by 40-50 GiB inside an hour, so with the ceiling at 93% the monitor will keep flapping until shutterflow bounds a live lead's `target/` (issue 1773). Order for a repeat: `du -xsh ~/SourceRoot/*/.claude/worktrees/*/target` (reap closed, merged only), then `make disk-sweep-run`, then read the `FAIL:` clause of the last `~/Library/Logs/devhost-health.log` line.

Issue 2235 (2026-11-18 07:57Z, same monitor, `disk 94% used (max 93%), 56G free`, 83 to 54 GiB free in 30 min) was the eighth, and the first where the lever was not a `target/`: both live shutterflow leads (1920, 1926) held 37 and 19 GB, no closed Issue had one left, and `make disk-sweep-run` returned only 8.5 GiB (Colima `fstrim` +7.8 GiB, `$TMPDIR` +0.9 GiB, 94% still). The cargo seed store `~/cache/shutterflow/seed` held two seeds, 50 and 23 GB by `du`: the Nov 16 one outlived its successor because `cargo-target-seed` prunes only at the end of a seed `build`, and a lock change since (Nov 17 and Nov 18) had not been followed by one. Nothing held it open (`lsof`) and no worktree's key could still match it, so `rm -rf` of that seed dir freed **40 GiB** (94% to 89%, 103 GiB free) and the monitor recovered on the next run. A seed is `cp -c` cloned, so `du` overstates what a live clone shares, but the seed's own unshared blocks are real. Order for a repeat, first step added: `du -xsh ~/cache/*/seed/*` (remove a superseded seed no `lsof` line names), then the worktree `target/` reap, then `make disk-sweep-run`.

Issue 2315 (2026-11-18 18:39Z, same monitor, `disk 93% used (max 93%), 68G free (persisted 3 runs)`) was the ninth. Six shutterflow worktrees held 42-60 GB of `target/` each; three of them (2186, 2307, 2312) had merged PRs but were still in Watch, so no closed Issue had one to reap and the live ones stayed. Removing the two superseded cargo seeds (`afc95607`, `0755e925`, 57 GB by `du`, nothing in `lsof`) freed **nothing** on `df`: the live `target/` dirs are `cp -c` clones of them, so the shared blocks stay until the clones go, which is the opposite of Issue 2235 where no clone remained. `make disk-sweep-run` did the work: Colima `fstrim` +23.5 GiB (39.4 GiB trimmed), bun cache +5.4 GiB, `$TMPDIR` swept, +25.3 GiB in all, 93% to 90%, 93 GiB free (89%, 107 GiB free when the monitor recovered at 18:52Z). The sweep took 9 minutes, so a repeat that must land fast runs it first. Read it as: with six live `target/` dirs at 40-60 GB the volume sits within one build of the 93% line; the lever that is still free is Colima's `fstrim`, which regrows by 20+ GiB within hours.

Issue 2360 (2026-11-18 22:27Z, same monitor, 94% then 95%, 52 GiB free) was the tenth, and the lever was not a worktree `target/`, a seed or Colima: `~/.software-factory/data/hygiene/shutterflow-<sha>-<rand>` held nine idle dirs, one per factory hygiene run of the last hour, each a `cp -c` clone of the cargo seed that had grown its own `target/` (55 GB each by `du`). No process and no open file (`lsof +D <dir>/target/debug`) named any of them; the tenth was a live run and stayed. `rm -rf` of the nine freed **37 GiB** real (95% to 91%, 89 GiB free) and the monitor recovered. Nothing reaps them (signal to software-factory, Issue 2362), so the next page of this kind starts here. Order for a repeat, new first step: `du -xsh ~/.software-factory/data/hygiene/*` and remove every dir `ps -Ao command | rg -F <dir>` does not name, then the seed, `target/` and `make disk-sweep-run` steps above.

Issue 2566 (2026-11-20 10:15Z, `Infra mini filesystem >= 93%` page, 94% with 57 GiB free) was the eleventh. Not a round build, no hygiene dirs, no stale seeds; live shutterflow lead 2286 held 55 GB of `target/` and stayed. `make disk-sweep-run` (9 min) returned +19.6 GiB (Colima `fstrim` +19.4, `$TMPDIR` +0.3; uv prune skipped, lock held by pid 69270): 94% to 92%, 77 GiB free. The baseline moved: the Photos library is 105 GiB (`du -xsk`, 2026-11-20; the Photos row said 19, about 95 once downloaded), so the Data volume now rests at 92-94% with one live Rust lead, and any one build crosses 93%.

Decision: the line stays at 93%. Raising it lets the volume sit where issue 1026's panic began (94%, thin swap); lowering it only adds pages. The sweep stays at 04:40 daily. An `fstrim`-only job every few hours would bank the ~20 GiB that regrows within hours (Issue 2315), but it is a new scheduled job, so it is a follow-up signal, not part of this change. Shutterflow's bound on a live lead's `target/` (issue 1773) remains the structural fix. `vps` `docs/observability.md` still gives 88-92% as the mini's normal disk level; filed to vps, with no line change and so no door-route change.

Issue 2756 (2026-11-21 08:20Z, `Infra mini filesystem >= 93%` page, Data volume 98% with 20 GiB free, below the 94% line where issue 1026's panic began) was the twelfth, and the lever was not a live build: the regenerable dirs of closed Issues' factory worktrees. weatherorb's `core/target` held 31 GB across 7 closed worktrees (factory-2703 alone 11 GB), and basalt-ui's `node_modules` ~1.3 GB each across about 20. Removing the `target/` and `node_modules/` of every closed Issue's worktree freed **38 GiB** (98% to 94%, 56 GiB free). The sweep's `worktrees` step now does that daily. It reaches only `factory-N-M` worktrees under `~/SourceRoot/*` and `~/IuRoot/*` whose Issue `factory issue show issue_N` reports `closed`: a `target/` goes only beside a `Cargo.toml`, the source and the git checkout stay, and an Issue the factory cannot show is kept. Second lever, not in the sweep: `~/ShutterflowLab/e2e` held 69 GB by `du` in closed Issues' lab runs (1579, 1732-1734, 1890); shutterflow's own `make lab-clean APPLY=1` freed only 2 GiB real, because the runs are APFS clones of the seed.

Issue 2830 (2026-11-21, the Data volume at 94-95% after the thirteenth page, Issues 2812 and 2834): the tmpdir step had aborted on one vanished entry (fixed on master in `0fa7e77`, so the 04:40 run that failed saw no tmp sweep), and three more gaps let a day of stock stay. Closed here: `node-cache` (`$TMPDIR/node-compile-cache` files not written for 3 days; a directory rule never reaches a cache rewritten all day), `/private/tmp` in the tmpdir step (this user's top-level entries, not open), and `uv cache prune` retried with `--force` when a `uv run` holds the cache lock (pid 69270 had held it six days, so the prune was skipped every night). Measured on the mini the same day: `~/.local/state/prometheus-scripts/backups` is 15.5 GiB, not the 6.8 in the table above. Not closed, follow-up signals: cargo seeds whose key no worktree can produce (only a `build` prunes a seed); `~/cache` dirs not named by a bare Issue id (`e233`, `exp2850`, `scratch2802`, `weatherorb-1416`), whose id rule is a naming decision; docker images beyond dangling (a Decision: the VPS's 48 h rule would prune the rollback targets this script keeps). The owner's calls stand: the Photos library (110 GiB) to EXT, `~/.local/state/athena-poc`, the Colima volumes; the 93% line stays.

## What goes to the external SSD

**Class `external` in the budget table above:** a row for a volume that is not part of the Data volume. It counts nothing against the
internal `disk_low` floor, can be absent, and is read only through the gate (`docs/external-ssd.md`). Measured 2026-11-14 with the
volume attached: internal 926 GiB, 581 used, 309 free (66%); EXT 931 GiB, 525 used, 405 free (57%). The first table's `weatherorb` row
predates the move; its `data/` and `products/` live on EXT now.

Two things, and nothing else (`docs/storage.md` is the map of every disk): weatherorb's working
data under `weatherorb/` (owner decision of 2026-11-14, issue 1119; moved the same day, 167 GiB),
and `mirror/`, the nightly pulled copy of the HomeLab's SSD share and of `HDD/fuji` (plan row
`ext-mirror`). Never on it: Postgres's data directory (`docs/postgres.md`), Docker and the Colima
VM disk, swap, anything the factory or the boot path needs. Budget of the 931 GiB: weatherorb 167
now and about 228 with V2, the mirror about 445, which leaves roughly 250 GiB while the Fuji
archive grows by about 15 GiB a month.

## What lives on the HomeLab

The 2026-10 sweep moved `~/Movies/{Squid Game,YT Saver}`, `~/Downloads/mindsera_memos` and `~/SY`
to the HomeLab. On 2026-10-22 only the memos were kept, at `homelab:ssd/Dokumente/mindsera_memos`
(restic-backed); the rest was deleted (SY photos are in the image CDN). Restore:
`hl copy homelab:ssd/Dokumente/mindsera_memos ~/Downloads/mindsera_memos`. weatherorb's archive
goes to the bucket `weatherorb-archive` (key `op://homelab/s3-weatherorb/*`); its runbook is
weatherorb's ADR 0009 and `~/SourceRoot/homelab/docs/s3.md`.

## Reinstall pointers

- **Android SDK + emulator** (weatherorb `apps/mobile`): `brew install --cask
  android-commandlinetools`, then `sdkmanager` for platform-tools, emulator, the platform and the
  system image, then recreate AVD `w18_api35`. Exact env and build steps:
  `~/SourceRoot/weatherorb/apps/mobile/README.md`. The cask is not in the Brewfile.

## Gotchas

- **Agents cannot see `~/.Trash`, `~/Library/{Mail,Messages,Biome}` or `MobileSync`.** The
  Claude process has no Full Disk Access, so `du` skips them silently, and the 246 GiB Trash was
  invisible this way. To measure them, run `ask-human ask '…' --cmd "ssh mini 'du -xhd1
  ~/.Trash …'"`. The mini's sshd session can read them.
- `docker system df` overstates reclaimable image space (layers are shared). The host only
  gets space back after `fstrim`.

## Rule (moved from the root AGENTS.md)

**Disk** — the mini's budget per owner, the daily `com.jkrumm.disk-sweep` (`make
disk-sweep-run` runs it once), what moved to the HomeLab and how to
restore it: `docs/disk.md`. **Agents cannot see `~/.Trash`** (no Full Disk Access; it held
246 GiB unnoticed) — measure it through `ask-human` over `ssh mini`.
