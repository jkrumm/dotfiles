---
description: The contract for the mini's external USB SSD (volume name in config/external-volume.json): the gate every dependent calls, absent and locked tolerance, the unlock job, the doctor and heartbeat check, the TCC class, what stays off it, and the read-only format check. Read before a job writes to the volume or a change touches its mount.
---

# External SSD — the volume contract

The volume can be absent, locked or half-mounted at boot or after a USB hiccup, and launchd has no mount dependency. So **every
dependent gates itself**. The contract is path-agnostic: the volume's name is in `config/external-volume.json`, its mount point is read
from `diskutil` at run time and appears in no tracked file. What the volume holds and why: `docs/storage.md`; its budget: `docs/disk.md`.

**As attached (2026-11-14):** the drive is mounted, unlocked, APFS with FileVault, and weatherorb already writes to it, without the gate.
`attached` in the config stays `false` until the plan row `ssd-adopt` writes the sentinel, installs the unlock job and turns the checks
on. While it is `false` the gate, the check and the unlock job are silent no-ops.

## Rules

1. **No lead formats, erases, converts, repartitions, encrypts or decrypts the drive.** No script here names such a diskutil verb
   (`scripts/volume-gate.test.sh` greps for them). An unsuitable format is a Decision; cleaning up is the owner's.
2. **A job touches the volume only through the gate:** `scripts/lib/volume-gate.sh run -- <cmd>` hands the command `$VOLUME_ROOT`; from a
   script, `volume-gate.sh root` prints it (exit 1 when not present). Never a path typed by hand, never `mkdir -p` of it.
3. **Present** = mounted, unlocked, and the sentinel file at the volume root reads (bounded to 5 s: a pending TCC prompt freezes the
   read, it does not fail it). Anything else prints one line and exits 0, runs nothing, creates nothing, never falls back to the internal disk:

   | State | Line | Cause |
   |-|-|-|
   | `unattached` | `skipped: volume not attached` | `attached: false` |
   | `absent` | `skipped: volume absent` | no such volume, or it vanished between the probe and the read |
   | `locked` | `skipped: volume locked` | FileVault volume not unlocked |
   | `unreadable` | `skipped: volume unreadable` | mounted, but the sentinel did not read: the wrong volume, or a TCC grant pending |
   | (run) | `skipped: volume vanished during run` | the command failed and the volume is gone; a failure with the volume still there keeps its own rc |

4. **A job that skips is a healthy job.** It exits 0, so jobrun grades it green; the check below is what says the volume is missing.

## Unlock

`scripts/external-volume-unlock.sh`, a LaunchAgent (`make external-volume-unlock-setup`, installed by `ssd-adopt`, not by `make setup`):
at load, on mount and every 120 s (a locked APFS volume never mounts, so on-mount alone cannot see it), through jobrun, log
`~/Library/Logs/external-volume-unlock.log`. It reads `diskutil` state only, never a file on the volume (no TCC grant). Mounted, absent
or not attached: silent exit. Locked: `secrets-run read <passphraseRef>` piped into `diskutil apfs unlockVolume <device> -stdinpassphrase`
(stdin, never argv, never `op` on the mini), bounded to 30 s, one run at a time, 15 min back-off after a failure. The ref lives in
`dotfiles-private/headless.refs`, named in `config/external-volume.json`; one the cache lacks goes through `make secrets-reseal-request`.

## Check

`scripts/external-volume-check.sh`, shown by `make doctor` and `make external-volume-check` (the mini only: the drive is its own) and carried by the heartbeat as a component:
**no output** while `attached: false`; present = OK; absent, locked or unreadable = **WARN, never a failure and never a page**. It is not
in the liveness push. `make doctor` shows it as a yellow dot.

## TCC

Reading or writing a removable volume needs the Removable Volumes grant, keyed on the program that opens the file (docs/tcc.md). A
program that does is listed with `"class": "removable"` in `config/tcc-programs.json`; `make tcc-check` rejects an unknown class and
counts the listed ones. Steps for a new program:

1. List it (label, why) in `config/tcc-programs.json`.
2. Run its gate once as that job, so the prompt appears: `launchctl kickstart gui/$(id -u)/<label>`, or wait for its next run.
3. Answer the prompt at the mini's screen (or ask the owner through an Errand). Until then the gate reports `unreadable`, and a read
   blocked on the dialog is cut at 5 s.
4. Proof is the job's own log: no `skipped: volume unreadable` after its next run. A probe from a core terminal proves nothing: `Herdr Core.app`
   holds Full Disk Access (docs/tcc.md).

Listed today: `com.jkrumm.devhost-health` (the check reads the sentinel). weatherorb's jobs and the mirror job join when `ssd-adopt` and
`ext-mirror` put them behind the gate.

## Keep off the volume

Swap and the Colima VM disk, `~/.colima`, herdr-core state and logs, `~/Library/Logs`, the secrets cache, LaunchAgent programs, Postgres's
data directory (`docs/postgres.md`), anything the boot path reads. Spotlight off (`mdutil -i off`) and a Time Machine exclusion
(`tmutil addexclusion`) are steps of `ssd-adopt`.

**Docker.** The VM disk and named volumes stay internal. A container bind of a volume directory is allowed only behind the gate, and
is blocked today by a second constraint: `colima/mounts.mini.txt` is the VM's virtiofs list, and a path in it that is absent at
`colima start` makes the VM, which is on the boot path, depend on the volume. No volume path goes in that list until a follow-up
designs it. Candidates for later (sizes from `docs/disk.md`), a question and not a task: `student-enrolment_mysql-data` 29 GiB (IU data,
the owner's call), `vps_clickstack-ch-data` 9 GiB (likely waste), and outside Docker `~/.local/state/athena-poc` 22 GiB and
`~/.cache/cloud-wave` 10 GiB.

## Format check (read-only, run by `ssd-adopt`)

`diskutil info <name>`, `diskutil apfs list`, free space, top-level sizes (`du -xd1` on the mount point); nothing is deleted or written.

| Finding | Outcome |
|-|-|
| APFS, encrypted | keep: the unlock job applies |
| APFS unencrypted | keep; the unlock job is a no-op, a Decision only if the owner wants it encrypted |
| HFS+, exFAT, MBR | Decision: copy the data to a HomeLab share first (`hl`), then the owner decides the reformat |

## Proving absent and locked tolerance on the real drive

In a window where no dependent job runs, never by reboot or cable pull: `diskutil unmount` (absent: the gate skips, `make doctor` WARNs),
`diskutil apfs lockVolume` then wait for the unlock job (locked, then unlocked again), `diskutil mount`. The hermetic proof is
`make volume-gate-test` (a stub `diskutil`, a temp directory as the stand-in volume).
