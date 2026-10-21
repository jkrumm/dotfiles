# The mini's disk, accounted for

**Goal:** every GB on the mini's 1 TB SSD is named, by owner and purpose. Waste is gone. Data with value but no local use lives on the HomeLab over S3. A durable sweep keeps it that way.
**Gate:** `make check` where this repo has it, for any script or plist change; every deletion recorded with before/after `df` in this file's **Left behind**.

## Wave 1 — Know every GB, drop the waste, move the past            <!-- status: done -->
Owner, 2026-10-20: "I have a terabyte SSD here. What the fuck is taking all that space? … I want to get this done once and for all, and really track down what's happening. Some old builds piling up, … keeping historic data for ages … which we could put onto the HomeLab hard drive … I'm usually not running the student data analysis locally anymore … the Colima stuff." And: weatherorb must never choose a worse architecture over ~30 GB.

What is known (orchestrator, 2026-10-20):
- `df` shows ~66 GiB free of 926; it dips toward the 50 GB `disk_low` floor while weatherorb builds a round (~22 GB transient).
- weatherorb itself is ~111 GB: `products/` 59 GB (21 GB of shadows, which weatherorb's Wave 81 deletes on 2026-10-22), `data/` 40, `var/` 12, plus its Postgres on :5433.
- `.colima` was measured at 137 GB on 2026-10-17.
- Chrome `code_sign_clone` dirs are swept daily by `log-rotate`, since dotfiles PR #23.

**Boundaries:**
- **weatherorb (`~/SourceRoot/weatherorb`, its Postgres databases, `~/Library/Logs/weatherorb.*`) is production.** Measure and report it, never delete or move anything in it. Its moves are a weatherorb wave; send the orchestrator (herdr tab `weatherorb-f4`, pane w22:p14) your weatherorb findings as a message.
- Anything that is not regenerable (data, datasets, documents, models a human made) is copied to the HomeLab first and verified by checksum, and only then deleted locally.
- Regenerable things are deleted after you check what regenerates them: caches, build output, docker images, simulators, package stores.
- Never `git stash`.
- Never touch another repo's uncommitted work: check `git status` first and report rather than delete.

- [x] **Measure.**
  - Top-down `du` (bounded, `-x`), plus APFS local snapshots (`tmutil listlocalsnapshots /`), purgeable space and swap/sleepimage.
  - Per repo under `~/SourceRoot` and `~/IuRoot`: node_modules, `.build`, `.venv`, `dist`, `target`, `.next`, large data dirs.
  - Library: Caches, Developer (Xcode, CoreSimulator, CommandLineTools), Application Support.
  - Homebrew cache, uv, bun, npm, pip, cargo.
  - Colima: the VM disk image's apparent vs allocated size, and `docker system df -v` inside it (images, containers, volumes, build cache).
  - The Android SDK and AVDs (weatherorb's `apps/mobile` used `w18_api35`).
  - Ollama or other model stores; Postgres data dirs; logs.
  - Output: one table (path, GB, owner/purpose, class: **needed** / **waste** / **move to HomeLab** / **ask owner**), sorted by size, to ~95 % of the used space.
- [x] **Drop the waste**, largest first. Record before/after `df` for each.
  - Colima: prune unused images, stopped containers, dangling volumes and build cache. Find out (with `/research`) whether the colima VM disk can be shrunk or recreated smaller, and do it only if no needed volume is lost.
  - Stale build dirs of finished work; simulators and SDK images no longer used; package caches.
- [x] **Move the past to the HomeLab.**
  - Use `hl` (S3 against the HomeLab VersityGW; `~/SourceRoot/homelab/docs/s3.md`; dotfiles AGENTS.md *HomeLab files*). The mini's key writes only `inbox`, with no delete.
  - The student data analysis (find it, likely under `~/IuRoot` or `~/SourceRoot`; the owner no longer runs it locally) and any other dataset with value but no local use: copy, verify by checksum, then delete locally. Record where each now lives.
  - If a dedicated bucket is better than `inbox`, coordinate with the HomeLab agent: herdr tab `homelab-09`, pane w3N:p1, working on HomeLab file access and S3 storage. Message it, don't edit `~/SourceRoot/homelab` yourself.
- [x] **weatherorb's archive over S3** (coordination only, no weatherorb code). weatherorb's archive (its ADR 0009) is pulled today by the HomeLab through a forced-command ssh door.
  - The owner wants it on the HomeLab's S3 API instead, with historic weatherorb data that is not needed locally kept there.
  - Ask `homelab-09` for a `weatherorb` bucket and a mini key that writes it, read and write, with no delete if the HomeLab wants immutability.
  - Report the bucket, key reference and policy to the orchestrator `weatherorb-f4`, which plans the weatherorb side as its own wave.
- [x] **Keep it.** Add durable sweeps for what regrows to `log-rotate` (or its own `jobrun` job), each with a size line in its log: docker build cache, package caches, simulator leftovers. Write `docs/disk.md`: the budget per owner, what is swept, what lives on the HomeLab and how to get it back. Link it from AGENTS.md.
- [x] Exit:
  - the table covers ≥ 95 % of used space;
  - free space before → after, measured outside a weatherorb round build;
  - every moved dataset verified on the HomeLab;
  - the weatherorb findings and the S3 bucket handed to `weatherorb-f4`;
  - the sweeps running.

**Left behind:**
- **Free space: 66 GiB → 431 GiB** (Data volume, `df`), the last reading at 19:00 with two weatherorb blend rounds on disk and no third in flight. The budget table is in `docs/disk.md` and covers ~95 % of the 470 GiB used.
- **Where the gap was:** `~/.Trash` held 246 GiB. The agent cannot see it (no Full Disk Access; also `Mail`, `Messages`, `MobileSync`), so `du` skipped it silently. It was measured and emptied through `ask-human` over `ssh mini`; the owner approved the irreversible empty in the native dialog. The gotcha is now in `docs/disk.md` and AGENTS.md.
- **Deletions, host `df -k` before → after (free KiB):**
  - `~/.colima/_lima/_disks/colima-w50` (orphaned weatherorb W50 VM data disk): 51016120 → 80568932, +28 GiB.
  - Docker: dangling images and containers, images unused for more than 14 days (`image prune -a --filter until=336h`), build cache capped at 15 GB. That is ~13 GB inside the VM, then `colima ssh -- sudo fstrim -a` (83 GiB trimmed): +37 GiB host. The data disk went from 110 to 78 GiB allocated.
  - Package caches: uv +1.7 GiB, brew +2.7 GiB, npm +4.4 GiB, bun +9.7 GiB.
  - `~/.Trash`: 162105160 → 420255476, +246 GiB.
  - Android cask `android-commandlinetools` (with its SDK and system images), `~/.android/avd/w18_api35`, `~/.gradle` caches, cleared by weatherorb-f4: +10.9 GiB. The reinstall pointer is in `docs/disk.md`.
  - `/Users/Shared/Epic Games` (2023 installs, no launcher): +12.5 GiB.
  - `$TMPDIR` (239k leaked test dirs) and OCR sessions older than 14 days, the first sweep run: +4.1 GiB.
  - Moved media, deleted after verification: +7.4 GiB (next item).
- **Moved to the HomeLab:** bucket `mini-archive` (restic → B2 nightly), not `inbox` (homelab-09's call). `~/Movies/{Squid Game,YT Saver}`, `~/Downloads/mindsera_memos` and `~/SY` now live under `homelab:mini-archive/mac-mini/<same path>`. Each was verified with `hl check --download` (0 differences, 1184 files) before the local delete. The sha256 manifests are in `mini-archive/mac-mini/_sha256/`. A killed first attempt into `inbox` left two aborted multipart uploads; homelab-09 cleaned them up.
- **Not moved, owner decision:** the "student data analysis" is IU student data. It is the Docker volume `student-enrolment_mysql-data` (29 GB, mounted by the running `idss-mysql` container of `~/IuRoot/epos.student-enrolment`), plus `~/IuRoot/prometheus-scripts/analysis/kafka-snapshots` (3.4 GB) and the bounded IU state backups (6.8 GB). Copying careerpartner/IU PII onto the personal HomeLab is a data-protection call, not a disk call. My recommendation is to delete the MySQL volume (it is a local dev copy that can be re-imported) rather than archive it. Also for the owner: `vps_clickstack-ch-data` (9 GB, no container, likely waste), `~/Pictures/Photos Library` (19 GB).
- **weatherorb:** findings and the S3 brief went to weatherorb-f4, which took them into its Wave 82. Bucket `weatherorb-archive`, key `op://homelab/s3-weatherorb/*` (added to `dotfiles-private/headless.refs` in 54de881; the mini cache is reseeded), put + read with no delete, `If-None-Match: *`, SHA256 HEAD check before a local delete. Cutover is a message to homelab-09.
- **Sweep:** `com.jkrumm.disk-sweep`, daily at 04:40 on `jobrun` with `--timeout 3600`, is installed and loaded. `make disk-sweep-run` runs it once, `make disk-sweep-test` is in `make check`. Two review rounds; the first round's three blockers (an lsof guard that failed open, rm and find failures counted as success) are fixed and tested.
- **Noticed, other repos' bugs (not fixed):** warden's and agent-gateway's test suites leak temp dirs into `$TMPDIR` (`merge-db*`, `warden-cli*`, `ledger-test*`, `agent-gateway-*-test-*`, ~300k entries), and agent-gateway's `/check` leaks `fallow-audit-base-cache-*` at ~2.3 GB/day. The sweep bounds both, but the leaks themselves should be fixed upstream. homelab-09 committed this wave's WIP Makefile hunks in aaae4bd (`git commit -a` in a shared checkout); bf655d7 made master coherent.
- **Stopped:** at the committed close-out (orchestrated). No next wave is planned in this file.
