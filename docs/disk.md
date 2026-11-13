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
| `~/.local` | 25 | usage-tracker 3.8, opencode 3.7, fnm 3.3 (16 node versions), IU `prometheus-scripts` state backups 6.8 (hourly 48 h + daily 30 d, bounded by `com.iu.prometheus-state-backup`) | needed |
| `/private/var` | 20 | `$TMPDIR` 17 (Chrome code-sign clones, test-suite tmp dirs), system | swept |
| `~/Pictures/Photos Library` | 19 | personal photos | ask owner |
| `~/.claude` | 16 | Claude Code transcripts (`projects/`; argo 6.8) | needed (Claude Code prunes by `cleanupPeriodDays`) |
| `/opt/homebrew` | 16 | Cellar 8.6, postgresql@18 data 6.0 (:5433, weatherorb and others) | needed |
| `~/IuRoot` | 13 | IU repos. `prometheus-scripts/analysis` 4.6 (`kafka-snapshots` 3.4) | ask owner (IU data, below) |
| `/private/tmp` | 12 | agent scratch (`basalt-briefs`, `pytest-of-root`, wave logs) | macOS periodic cleanup |
| `/Applications` | 11 | apps | needed |
| `/Library` | 7.5 | system-wide | needed |
| `~/.hermes` | 7.2 | Hermes agent: install, `state.db` 1.6 | needed |
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

## Sweeps: what keeps it this way

| Job | Cadence | Bounds |
|-|-|-|
| `com.jkrumm.disk-sweep` (`scripts/disk-sweep.sh`) | 04:40 daily | Docker build cache LRU-capped at 15 GB and dangling images removed (never tagged images, volumes or containers), `colima ssh -- sudo fstrim -a`, `$TMPDIR` top-level entries > 3 days that nothing holds open, `uv cache prune` (probes the cache lock for 20 s; a lock held by another uv process logs `uv prune skipped: cache lock held by pid N` and is not a failure) and `brew cleanup -s`, npm and bun caches over 3 / 5 GB, unavailable simulators |
| `com.jkrumm.log-rotate` | every 15 min | owned logs at 16 MB, Chrome `code_sign_clone` dirs > 2 h (one `lsof`, background priority, 4 rm workers, at most 1500 removals or 300 s per run, counted from script start; the lsof is bounded at 90 s). Agents launch ~300-600 Chrome/h; the 24 h gate at 400/h grew the stock to 14k clones (a clone is mostly shared APFS blocks, ~0.5 MB real, so the stock is a load and inode burden more than a disk one; the 16-49 GB/h Beszel page of issue 839 recovered on its own to 86.6% within the hour, consistent with the weatherorb round-build transient of ~22 GB above; the writer was not caught in the act, see "Round-build page" below) |

Each step writes one `free space +N MB` line to `~/Library/Logs/disk-sweep.log`. Run it once
with `make disk-sweep-run`. That target is also the sanctioned route for the docker prunes,
because the `docker-makefile` hook blocks raw docker in this repo.

## Round-build page (Beszel "disk filling fast")

Caught in the act on 2026-11-12 (issue 864, 87.7%, "+13.9 GB/h"): weatherorb's `worker-round`
writes the next blend round to `products/weatherorb_blend/.building-<round_id>/` (hidden, so a
plain `ls` misses it) while `current` and `previous` (~24.4 GB each) are still on disk, so a
round in flight is three rounds, ~73 GB, for the ~2 h a build runs. At commit the oldest is
removed and the stock falls back to ~49 GB. The page fires every 3 h round with a growth slope
over 0.5 GB/h and ~87-89% used; the peak stays under the 90% line only while the rest of the
volume holds ~110 GiB free. Nothing leaks: confirm with
`du -xsk ~/SourceRoot/weatherorb/products/weatherorb_blend/.building-*` (grows ~7 MB/s) and the
`free space` drop after the round commits. Act only when used stays above 90% after a commit
or `.building-*` outlives its round (> 3 h, a crashed build leaves it). The Beszel rule is
software-factory's (`config/infra.json`), not this repo's.

Issue 909 (2026-11-12, 90.2-90.4% for ~25 min) was the same transient with less headroom: the
`1300Z` build held 23 GB of ~24 GB, `products/` read 73 GB (three rounds), and the commit at
~16:30 brought used to 88% (120 GiB free). The line is now crossed at the peak because the rest
of the volume grew since 2026-10-20 (re-measured the same day, `du -xk`, GiB):

| Path | GiB | Was | Note |
|-|-|-|-|
| `~/.colima/_lima/_disks/colima` | 91 | 78 (whole `~/.colima`) | main docker VM, swept daily |
| `~/.colima/_lima/_disks/colima-teamchat` | 30 | n/a | teamchat VM data disk, running, owner-timed restart pending |
| `~/.colima/_lima/_disks/colima-athena-poc` | 4.7 | n/a | no `in_use_by`, last written 2026-10-31: orphan PoC disk, ask owner before `colima delete --data` |
| `~/Library` | 66 | 36 | `Application Support` 20 (Chrome 9.8), `Developer` 18 (CoreSimulator 11, Xcode 6.6), `Caches` 14 |
| `~/.claude` | 27 | 16 | transcripts (`projects/`) |
| `$TMPDIR` / `/private/tmp` | 23 / 21 | 17 / 12 | |

A page with `.building-*` present and `products/` near 73 GB needs no action; a repeat at the
same peak means the baseline above, not weatherorb, needs trimming (CoreSimulator runtimes
and the orphan PoC disk are the cheap first cuts, both owner calls).

## Factory worktree stock (Beszel "disk above 90%", no `.building-*`)

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

## `/private/tmp` stock (Beszel "disk above 90%", 94%, no `.building-*`, worktrees small)

Issue 1026 (2026-11-13, 94% flat for 95+ min, 58 GiB free) was neither a round build (two
rounds in `weatherorb_blend`) nor worktrees (basalt-ui 13 GiB, the rest under 5). `/private/tmp`
held 32 GiB in ~21.8k entries (12 GiB on 2026-10-20) and nothing swept it. The mini kernel-panicked
that evening (watchdogd starved, ~19:00 CET) and the reboot emptied it: 85%, 138 GiB free, 12
entries. The swap headroom at 94% was thin (swap 9-14 GB over 12 swapfiles in `/private/var/vm`
before the panic; none after the reboot), so a full volume is part of panic prevention. Next
time: `du -xk -d1 /private/tmp` once (a `du` per entry forks out at 20k entries), clean what is
older than 3 days that nothing holds open. Still on disk, owner calls: `~/.local/state/athena-poc`
22 GiB (`investigate/` 20 GiB, untouched since Nov 2), `~/.cache/cloud-wave` 10 GiB,
`colima-athena-poc` 4.7 GiB. A sweep step for `/private/tmp` is not added: the root cause
(which writer leaked 20 GiB there) was not caught before the reboot.

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
