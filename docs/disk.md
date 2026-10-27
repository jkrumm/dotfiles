# Disk — the mini's 1 TB, accounted for

The mini's Data volume is 926 GiB. On 2026-10-20 it had 66 GiB free, and weatherorb's round
builds (~22 GB transient) pushed it toward the 50 GB `disk_low` floor. After one audit wave
(dotfiles `docs/waves/PLAN.md` Wave 1) it had 431 GiB free at 19:00 (two blend rounds on disk, no third in flight). This page is the budget, the
sweeps that hold it, and where the moved data lives.

## Budget per owner

Measured 2026-10-20 after the cleanup, `du -xk`, GiB. Used ≈ 480 GiB.

| Path | GiB | Owner / purpose | Class |
|-|-|-|-|
| `~/SourceRoot/weatherorb` | 135 | weatherorb production: `products/` 68 (two blend rounds of 23 each, plus skill and scenario products), `data/` 50 (model downloads), `var/` 13 (basemap 7.4) | needed. weatherorb's moves are weatherorb waves (its Wave 82: archive to S3) |
| `~/.colima` (data disk, sparse) | 78 | Colima VM. Docker: images ~30, named volumes ~48, build cache capped at 15 | needed. Swept daily |
| ↳ volume `student-enrolment_mysql-data` | 29 | IU epos.student-enrolment local MySQL (container `idss-mysql`, running) | **ask owner**: IU student data, see below |
| ↳ volume `vps_clickstack-ch-data` | 9 | local ClickStack telemetry, no container | ask owner (likely waste) |
| `~/Library` | 36 | Chrome profile 6.3, Caches ~14, Notion, Teams, Slack, MacWhisper | needed (app state) |
| `~/SourceRoot` other repos | 30 | node_modules (argo 2.9, basalt-ui 1.9, …), `shutterflow/target` 8.5 (active Rust build) | needed. Regenerable |
| `~/.local` | 25 | agent-gateway 4.6, usage-tracker 3.8, opencode 3.7, fnm 3.3 (16 node versions), IU `prometheus-scripts` state backups 6.8 (hourly 48 h + daily 30 d, bounded by `com.iu.prometheus-state-backup`) | needed |
| `/private/var` | 20 | `$TMPDIR` 17 (Chrome code-sign clones, test-suite tmp dirs), system | swept |
| `~/Pictures/Photos Library` | 19 | personal photos | ask owner |
| `~/.claude` | 16 | Claude Code transcripts (`projects/`; argo 6.8) | needed (Claude Code prunes by `cleanupPeriodDays`) |
| `/opt/homebrew` | 16 | Cellar 8.6, postgresql@18 data 6.0 (:5433, weatherorb and others) | needed |
| `~/IuRoot` | 13 | IU repos. `prometheus-scripts/analysis` 4.6 (`kafka-snapshots` 3.4) | ask owner (IU data, below) |
| `/private/tmp` | 12 | agent scratch (`basalt-briefs`, `pytest-of-root`, wave logs) | macOS periodic cleanup |
| `/Applications` | 11 | apps | needed |
| `~/.opencodereview` | 8 | agent-gateway OCR session logs | swept (14 days) |
| `/Library` | 7.5 | system-wide | needed |
| `~/.hermes` | 7.2 | Hermes agent: install, `state.db` 1.6 | needed |
| `~/.cache` | 4.5 | uv 2.3, puppeteer, … | swept |
| everything else | ~15 | `~/go` 2.7, `.rustup` 2.1, `.research-gateway` 1.4, … | needed |

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
| `$TMPDIR` test leftovers, OCR sessions > 14 days | 4 GiB | 239k leaked tmp dirs (test suites) |

## Sweeps: what keeps it this way

| Job | Cadence | Bounds |
|-|-|-|
| `com.jkrumm.disk-sweep` (`scripts/disk-sweep.sh`) | 04:40 daily | Docker build cache LRU-capped at 15 GB and dangling images removed (never tagged images, volumes or containers), `colima ssh -- sudo fstrim -a`, OCR sessions > 14 days, `$TMPDIR` top-level entries > 3 days that nothing holds open, `uv cache prune` and `brew cleanup -s`, npm and bun caches over 3 / 5 GB, unavailable simulators |
| `com.jkrumm.log-rotate` | hourly | owned logs at 16 MB, Chrome `code_sign_clone` dirs > 24 h |

Each step writes one `free space +N MB` line to `~/Library/Logs/disk-sweep.log`. Run it once
with `make disk-sweep-run`. That target is also the sanctioned route for the docker prunes,
because the `docker-makefile` hook blocks raw docker in this repo.

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
