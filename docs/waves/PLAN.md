# The mini's disk, accounted for

**Goal:** every GB on the mini's 1 TB SSD is named, by owner and purpose. Waste is gone. Data with value but no local use lives on the HomeLab over S3. A durable sweep keeps it that way.
**Gate:** `make check` where this repo has it, for any script or plist change; every deletion recorded with before/after `df` in this file's **Left behind**.

## Wave 1 — Know every GB, drop the waste, move the past            <!-- status: active -->
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

- [ ] **Measure.**
  - Top-down `du` (bounded, `-x`), plus APFS local snapshots (`tmutil listlocalsnapshots /`), purgeable space and swap/sleepimage.
  - Per repo under `~/SourceRoot` and `~/IuRoot`: node_modules, `.build`, `.venv`, `dist`, `target`, `.next`, large data dirs.
  - Library: Caches, Developer (Xcode, CoreSimulator, CommandLineTools), Application Support.
  - Homebrew cache, uv, bun, npm, pip, cargo.
  - Colima: the VM disk image's apparent vs allocated size, and `docker system df -v` inside it (images, containers, volumes, build cache).
  - The Android SDK and AVDs (weatherorb's `apps/mobile` used `w18_api35`).
  - Ollama or other model stores; Postgres data dirs; logs.
  - Output: one table (path, GB, owner/purpose, class: **needed** / **waste** / **move to HomeLab** / **ask owner**), sorted by size, to ~95 % of the used space.
- [ ] **Drop the waste**, largest first. Record before/after `df` for each.
  - Colima: prune unused images, stopped containers, dangling volumes and build cache. Find out (with `/research`) whether the colima VM disk can be shrunk or recreated smaller, and do it only if no needed volume is lost.
  - Stale build dirs of finished work; simulators and SDK images no longer used; package caches.
- [ ] **Move the past to the HomeLab.**
  - Use `hl` (S3 against the HomeLab VersityGW; `~/SourceRoot/homelab/docs/s3.md`; dotfiles AGENTS.md *HomeLab files*). The mini's key writes only `inbox`, with no delete.
  - The student data analysis (find it, likely under `~/IuRoot` or `~/SourceRoot`; the owner no longer runs it locally) and any other dataset with value but no local use: copy, verify by checksum, then delete locally. Record where each now lives.
  - If a dedicated bucket is better than `inbox`, coordinate with the HomeLab agent: herdr tab `homelab-09`, pane w3N:p1, working on HomeLab file access and S3 storage. Message it, don't edit `~/SourceRoot/homelab` yourself.
- [ ] **weatherorb's archive over S3** (coordination only, no weatherorb code). weatherorb's archive (its ADR 0009) is pulled today by the HomeLab through a forced-command ssh door.
  - The owner wants it on the HomeLab's S3 API instead, with historic weatherorb data that is not needed locally kept there.
  - Ask `homelab-09` for a `weatherorb` bucket and a mini key that writes it, read and write, with no delete if the HomeLab wants immutability.
  - Report the bucket, key reference and policy to the orchestrator `weatherorb-f4`, which plans the weatherorb side as its own wave.
- [ ] **Keep it.** Add durable sweeps for what regrows to `log-rotate` (or its own `jobrun` job), each with a size line in its log: docker build cache, package caches, simulator leftovers. Write `docs/disk.md`: the budget per owner, what is swept, what lives on the HomeLab and how to get it back. Link it from AGENTS.md.
- [ ] Exit:
  - the table covers ≥ 95 % of used space;
  - free space before → after, measured outside a weatherorb round build;
  - every moved dataset verified on the HomeLab;
  - the weatherorb findings and the S3 bucket handed to `weatherorb-f4`;
  - the sweeps running.

**Left behind:**
