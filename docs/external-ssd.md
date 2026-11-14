---
description: The contract for the mini's external USB SSD (volume name in config/external-volume.json): the gate every dependent calls, absent and locked tolerance, the unlock job, the doctor and heartbeat check, the TCC class, what stays off it, and the read-only format check. Read before a job writes to the volume or a change touches its mount.
---

# External SSD — the volume contract

The volume can be absent, locked or half-mounted at boot or after a USB hiccup, and launchd has no mount dependency. So **every
dependent gates itself**. The contract is path-agnostic: the volume's name is in `config/external-volume.json`, its mount point is read
from `diskutil` at run time and appears in no tracked file. What the volume holds and why: `docs/storage.md`; its budget: `docs/disk.md`.

## As attached (2026-11-14, issue 1238)

Read-only first, measured on the mini (`diskutil info`, `diskutil apfs list`, `du -xd1`):

| Fact | Value |
|-|-|
| Volume | `EXT`, one APFS volume in its own container on a GPT USB disk (EFI + container), case-insensitive, owners disabled, SMART verified |
| Encryption | FileVault (APFS native), one crypto user, hint `EXT SSD` |
| Size | 931 GiB container; 526 GiB used, 406 GiB free (57 %) at 20:20 CET |
| Top level (GiB) | `Bilder` 168.7, `weatherorb` 166.5 (weatherorb's, with its own marker `.weatherorb-data-root`), `Videos` 110.4, `usb-rescue` 11.2, `Steuer` 7.4, `mirror` 3.4 (the `ext-mirror` row has started it), `Dokumente` ~0, Spotlight and system dirs ~0.5 |
| Not ours | `Bilder`, `Videos`, `Steuer`, `Dokumente`, `usb-rescue` are the owner's folders; they move to the HomeLab or become `mirror/fuji` in other rows. The end state is `weatherorb/` and `mirror/` only |
| What unlocks it | The **login keychain**: it holds an "Encrypted Volume Password" item for the volume (created 2023-05), which macOS uses at login. There is no 1Password item for it that the secrets cache knows, so `passphraseRef` stays `null` and the unlock job is a no-op when the volume is locked (`skipped: passphrase ref not set`) |

Changes made on the drive: the sentinel `.volume-gate`, and Spotlight turned off (`mdutil -i off`, which updates `.Spotlight-V100`). The
Time Machine exclusion was already set (`tmutil isexcluded` says `[Excluded]`; no Time Machine destination exists). Nothing was moved,
renamed or deleted. `attached` is `true`.

**An unmount locks it.** `diskutil unmount EXT` on this FileVault volume leaves it locked, and `diskutil mount` then refuses ("encrypted
and locked APFS Volume; use `diskutil apfs unlockVolume`"). Only an unlock brings it back, which is the unlock job's work and needs the
passphrase from a ref, or the owner's hand (`ssh -t mini 'diskutil apfs unlockVolume <device>'`, typing it). Reading the keychain item
with `security find-generic-password -w` from an agent blocks on an ACL dialog nobody sees. Proof on the real drive, 2026-11-14:

| Step | Gate | `make external-volume-check` |
|-|-|-|
| mounted and unlocked | `present` | `external volume present`, rc 0 |
| `diskutil unmount EXT` (no job open on it; weatherorb's are unloaded) | `locked`, a job skips with one line | WARN, rc 2 |
| `diskutil mount EXT` | refused, still `locked` | WARN, rc 2 |
| unlocked by the owner | `present` | OK, rc 0 |

Open: the passphrase ref. Until a 1Password item holds it and `headless.refs` lists it (then `make secrets-reseal-request`), a lock or a
reboot that the login keychain does not cover needs the owner. Do not repeat the unmount proof until then.

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

`scripts/external-volume-unlock.sh`, a LaunchAgent (`make external-volume-unlock-setup`, run by `make setup` on the mini once `attached` is `true`):
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

Listed today: `com.jkrumm.devhost-health` (the check reads the sentinel) and weatherorb's `serve`, `watchdog`, `worker-ingest` and
`worker-round` (their `data/`, `products/` and `var/` entries are symlinks onto the volume). weatherorb's jobs are unloaded (V1 frozen),
so no grant could be probed for them; the first run after a revival raises the prompt. The heartbeat's grant is probed by its first run
after this change merges (its log, `~/Library/Logs/devhost-health.log`, shows `external volume present` or `unreadable`). The mirror job
joins when `ext-mirror` puts it behind the gate; weatherorb was asked by signal to put its jobs behind it.

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

In a window where no dependent job runs, never by reboot or cable pull: `diskutil unmount` (the volume reads `locked`: the gate skips,
`make doctor` WARNs), then the unlock job re-unlocks it within 120 s, **only once `passphraseRef` is set**; a plain `diskutil mount` does
not work on this drive (§As attached). The hermetic proof is `make volume-gate-test` (a stub `diskutil`, a temp directory as the
stand-in volume).
