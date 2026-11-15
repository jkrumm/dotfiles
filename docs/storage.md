# Storage — where personal data lives, and every copy of it

One rule: **each class of data has one home. Every other copy is made by a job, never by hand.**
A file that exists in two places because someone dragged it there is a bug.

Measured on 2026-11-14. Server names, users and credentials are in `dotfiles-private` and the
`homelab` repo, not here.

## The four disks

| Disk | Where | Size, used | Role |
|-|-|-|-|
| **SSD** share | HomeLab, internal SSD | 466 GiB, share holds 164 | Home of everything personal and small: documents, photos, books |
| **HDD** share | HomeLab, one encrypted USB disk, no redundancy | 14 TiB, 4.5 used | Home of everything big: camera RAWs and videos, films, audiobooks; also service state and machine backups |
| **EXT** | Mac mini, external USB SSD, FileVault | 931 GiB, 526 used | Second local copy of what must not be lost, plus weatherorb's working data. Home of nothing |
| **B2** | Backblaze, restic repository | 353 GiB stored | The offsite copy |

The MacBook and the phone are clients. Nothing lives on them that is not also somewhere above,
with one exception: the Shutterflow library, which syncs its finals to B2 itself.

## What lives where

| Class | Home | Local copy | Offsite |
|-|-|-|-|
| Documents (tax, finance, studies, CV, sailing) | `SSD/Dokumente` | EXT mirror | restic |
| Fuji finals | the Shutterflow library on the MacBook | none | B2, by Shutterflow's own sync |
| Phone photos since 2021 (20,981 library assets, 78 GiB of originals) | iCloud Photos | nightly export to `SSD/Bilder/iCloud` by `com.jkrumm.icloud-photos-export` (§iCloud Photos export); complete once Photos has downloaded the originals | restic |
| Other photos: phone archives to 2020, old libraries to 2019 | `SSD/Bilder` | EXT mirror | restic |
| Books, dev archive, small personal videos, public files | `SSD/{Bücher,Dev,Videos,Public}` | EXT mirror | restic |
| Fuji RAWs | `HDD/fuji/RAWs` | EXT mirror | restic |
| Fuji videos | `HDD/fuji/Videos` | EXT mirror | none (owner, 2026-11-14) |
| Other big personal videos (drone, projects) | `HDD/Videos` | EXT mirror | none |
| Films, series, audiobooks, downloads | `HDD` | none | none (replaceable) |
| Machine and service backups (Hermes, Postgres dumps, account dumps) | `HDD/backups` | none | restic |
| weatherorb working data | `EXT/weatherorb` | none | its own archive bucket on the HDD (weatherorb ADR 0009) |

Big videos have two copies in one flat and none outside it: the owner's call of 2026-11-14,
they are not worth B2 storage. A fire or a break-in loses them.

## Layout

```
SSD/                      HDD/                       EXT/
  Bilder/                   fuji/RAWs  fuji/Videos     weatherorb/   weatherorb's data root
  Dokumente/                Videos/                    mirror/       pulled copies, read-only by convention
  Bücher/                   Filme/                       ssd/        <- the SSD share
  Dev/                      Hörbücher/                   fuji/       <- HDD/fuji
  Videos/                   backups/                     videos/     <- HDD/Videos
  Public/                   inbox/  <service>/
```

- **New files go to the home, through the share.** Never to EXT, never to a Mac's disk "for now".
- **`HDD/inbox`** is the one drop folder for agents and for anything unsorted.
- **`EXT/mirror` is written by one job only.** Edit a file there and the next run overwrites it.
- **Top level stays fixed.** A new kind of data gets a folder inside an existing class.

## Copies and who makes them

| Job | From → to | When | Proof it ran |
|-|-|-|-|
| restic (`homelab` repo, `docs/backups.md`) | SSD share, `HDD/fuji/RAWs`, `HDD/backups`, service state → B2 | daily 03:30 | Uptime Kuma push monitor, 25 h |
| EXT mirror (`com.jkrumm.ext-mirror`, dotfiles; §EXT mirror) | SSD share, `HDD/fuji` and `HDD/Videos` → `EXT/mirror/{ssd,fuji,videos}` | nightly 05:00, pulled by the mini over S3 (`hl`), behind the volume gate | `jobrun` grade and `EXT/mirror/.status.json` |
| iCloud Photos export (`com.jkrumm.icloud-photos-export`, dotfiles) | the mini's Photos library → `SSD/Bilder/iCloud/<year>/<month>/` | nightly 01:30, over S3 (`hl`) | `jobrun` grade, `Bilder/iCloud/.status.json` |
| Shutterflow sync (its own app) | finals on the MacBook → B2 | on demand | the app's pipeline view |

The mirror pulls over S3 because the mini's S3 key cannot delete on the HomeLab, and because a
pull does not depend on an SMB mount being healthy. A file deleted at home moves to
`EXT/mirror/.deleted/<date>/` for 30 days before it goes.

Restic as measured: last run 2026-11-14 03:30, 162,685 files, 382 GiB, 26 snapshots back to
2026-05, retention 14 daily / 8 weekly / 12 monthly / 5 yearly. The snapshot was compared with
the live sources file by file the same day: 5,657 live files (1.4 GiB) are not in it, all by an
exclude rule (build output, caches, macOS metadata), among them one 1.3 GiB phone video whose
name ends in `.tmp`. Open gaps (homelab row `restic-verify`): no scheduled `restic check`, no
restore drill since 2026-05-04, and the 1Password vault export (`~/backups/1password` on the
HomeLab, age-encrypted, the recovery root for everything else) is not a source.

## iCloud Photos export

`scripts/icloud-photos-export.py` (`make icloud-photos-export-setup`, mini only) archives the phone photos, which have iCloud and
the phone as their only copies. Nothing in it talks to Apple or to Photos: the mini is signed in to iCloud Photos with
**Download Originals to this Mac**, Photos itself pulls the originals, and the job reads the library files.

| Piece | How |
|-|-|
| Reader | `osxphotos` 0.78.1 (`uv tool install`, pinned as `OSXPHOTOS_VERSION` in the Makefile), read-only against `~/Pictures/Photos Library.photoslibrary`. No AppleScript, no PhotoKit, no Automation prompt |
| Permission | the two osxphotos steps run as `hc exec` children of the herdr core, so they read the library under `Herdr Core.app`'s Full Disk Access (`docs/tcc.md`); the job's own program holds no grant. The job checks `scripts/lib/core-up.sh` before any `hc` call (a call starts a stray core, which has no grant): core not up at 01:30 is one `FAILED` line, exit 1, graded `failing`, and no core is started |
| Scope | library assets that are not trashed and not in a shared album (`--not-shared`): 20,981 on 2026-11-14, 2020 to today. The 14,478 shared-album assets (2017 to 2026, other people's photos at reduced size, 1,456 with a local file) are named in the status as `shared_album_assets_excluded` and not exported. The plan row's 35,540 counted both, plus the trash |
| Target | `homelab:ssd/Bilder/iCloud/<year>/<month>/<YYYY-MM-DD_HHMMSS>_<original name>`; an edit is `…_edited.<ext>` beside the original, a Live Photo's `.mov` beside its still. Written with `hl` (S3), never through `~/HomeLab/SSD` |
| Incremental | the ledger (`~/.local/state/icloud-photos-export/ledger.json`, a copy at `Bilder/iCloud/.ledger.json`, restored from it when the state is lost) records each asset's stamp (modified or added date, edit flag, size). Unchanged assets are not touched; a changed one is exported again over its own names |
| Archive, not a mirror | no `--cleanup`, no delete anywhere (the mini's S3 key cannot delete either): an asset removed or trashed in Photos stays, counted as `kept_after_removal`. A second asset that would land on an archive name already taken fails loudly instead of overwriting it |
| Bounds | batches of 1,000 assets or 10 GiB staged under `~/.local/state/icloud-photos-export/stage`, uploaded with `hl copy`, size-checked with `hl check --one-way`, then emptied; each osxphotos step ends at 600 s; no new batch after 6,000 s (`jobrun --timeout 7200`); nothing starts below 40 GiB free on the Data volume. An asset whose original, edit render or Live video is not on disk yet is `pending_local` and waits for the next night |
| Away | HomeLab unreachable: one `skipped` line, exit 0. A missing `hl` secret or a failed asset: exit 1 |
| Status | `Bilder/iCloud/.status.json` and a local copy: `library_assets`, `exported_assets`, `pending_local`, `new_this_run`, `changed_this_run`, `failed`, `kept_after_removal`, `shared_album_assets_excluded`, `bytes_uploaded_this_run`, `free_gib`, `last_ok`. `make icloud-photos-export-status` prints it and the job's grade |

Measured on 2026-11-14 against the live library from a core terminal, with a local stand-in for `hl`: 1,052 of the 1,068 originals then on disk
(a Live Photo or edit whose second file was missing waited) exported in 227 s (query about 60 s), 2.5 GB, three batches' worth of
staging at most; the second run exported 0 and took 69 s. The export of everything waits on Photos: **Download Originals to
this Mac** (Photos > Settings > iCloud) is the owner's one click, and the job exports whatever is on disk each night until the
download ends. Switching Photos back to Optimize Mac Storage later frees the space but new photos then stop arriving as originals,
so the export would miss them.

Restic's 03:30 run covers `SSD/Bilder`, and the EXT mirror pulls it from there, so the archive reaches the offsite copy the
night after it is written.

## EXT mirror

`scripts/ext-mirror.py` (`make ext-mirror-setup`, mini only, once `attached` is true) keeps `EXT/mirror/{ssd,fuji,videos}` equal to
`homelab:ssd`, `homelab:hdd/fuji` and `homelab:hdd/Videos`. It is the only writer of `EXT/mirror`.

| Piece | How |
|-|-|
| When | 05:00 daily, after the iCloud export (01:30) and restic (03:30); `jobrun --timeout 43200 --lock ext-mirror`, log `~/Library/Logs/ext-mirror.log` |
| Gate | the script re-executes itself through `scripts/lib/volume-gate.sh run --`: volume absent, locked or unreadable is one `skipped: volume <state>` line, exit 0, nothing run or created, never a path on the internal disk. It is listed `removable` in `config/tcc-programs.json` |
| Away | every source is probed before any sync: HomeLab unreachable (no such host, timeout, refused) is `skipped: HomeLab not reachable`, exit 0, nothing created. Any other probe failure, a rejected key included, and a key `hl` cannot resolve are failures (exit 1) |
| Lock | a run holds `EXT/mirror/.lock` (`flock`, released when the process ends however it ends); a second one is `skipped: a run is already in progress`, exit 0, so the nightly job and a long manual first copy never sync into the mirror together |
| Floor | less than 60 GiB free on the volume (`EXT_MIRROR_MIN_FREE_GIB`): `refusing to start`, exit 1 |
| Sync | `rclone sync` over `hl`, size and modification time (the gateway gives Samba-written files no usable etag, `homelab` `docs/s3.md` Caveats). Excludes what restic excludes (trash, macOS metadata, build output, Immich thumbs and encoded video, the gateway's `.sgwtmp`), except `*.tmp`, which restic loses real files to |
| Deletes | a file changed or deleted at the source moves to `EXT/mirror/.deleted/<YYYY-MM-DD>/<source>/` (`--backup-dir`) and the dated folder is removed after 30 days (`EXT_MIRROR_RETAIN_DAYS`); nothing else under `.deleted` is touched. The HomeLab is never written: the mini's key cannot delete there either |
| Empty source | a source that lists empty over a mirror that holds files is a share that is not mounted at home: that source is refused and the run fails, the mirror stays |
| Check | monthly (`EXT_MIRROR_CHECK_EVERY_DAYS`, `--check-now` forces it): `rclone check --download` over a sample per source, 100 files and at most 1 GiB (both ends are read over the slow link), drawn with a seed from the month and the source name, so a re-run draws the same files. A difference or missing file fails the run and is recorded; a failed check is repeated every night until it passes |
| Status | `EXT/mirror/.status.json`: `started`, `finished`, `ok`, `free_gib`, per source `files`, `bytes`, `transferred`, `transferred_bytes`, `moved_to_deleted`, `errors`, `ok`, and `check` (`finished`, `seed`, `ok`, per source `sampled`, `matched`, `differ`, `missing_in_mirror`, `errors`). `make storage-status` reads it and warns past 36 h; `make ext-mirror-status` prints it and the grade |
| Restore | a mistake at home is in `.deleted/<date>/` for 30 days; copy it back through the share. A file edited on the mirror is overwritten the next night |

Adoption (2026-11-15): the volume held a hand copy of `HDD/fuji` as `Bilder/RAWs` and `Videos/Videos`. Compared with the HomeLab by
name and size first (6,320 and 418 files, nothing the HomeLab lacked but a `.DS_Store`), then renamed on the same volume to
`mirror/fuji/RAWs` and `mirror/fuji/Videos`; the copy's modification times were set to the HomeLab's, so the first sync verified instead of
copying 280 GiB. Manual runs: `make ext-mirror-run ARGS=--dry-run`.

The path from the mini to the HomeLab carries about 2 MiB/s whatever the stream count (measured 2026-11-15: `hl` with 4 and with 16 streams, and a read through the SMB mount, all the same; 92 ms), so the first copy of the SSD share (164 GiB) takes about a day. `EXT_MIRROR_TRANSFERS` (16) only keeps small files from queueing behind large ones. The job's timeout is 12 h; a night that ends at the timeout is graded failing and the next one resumes where it stopped, so a night after the first copy is minutes.

## Mounts

One agent, `com.jkrumm.smb-keepalive`, mounts every share and remounts a stale one within 60 s
or on the next network change (`docs/macbook.md` §HomeLab Samba). Shares are declared in
`dotfiles-private/smb-shares.conf`.

| Share | Served by | MacBook | Mac mini |
|-|-|-|-|
| `SSD` | HomeLab Samba | `/Volumes/SSD`, automount | `~/HomeLab/SSD`, automount |
| `HDD` | HomeLab Samba | `/Volumes/HDD`, automount | `~/HomeLab/HDD`, automount |
| `EXT` | mini (macOS file sharing, SMB; share point = the volume's mount point, `docs/external-ssd.md` §Share) | `/Volumes/EXT`, automount (volatile: skipped while the drive is absent or locked) | local disk |
| home folder with `~/Shuttle` | mini (macOS file sharing) | `/Volumes/<mini user>`, automount | local disk |

Agents on the mini read and write HomeLab files with `hl` (S3). The SMB mounts are for bulk
copies and for people. **A launchd job cannot read an SMB mount**: macOS answers `Operation not
permitted`, or hangs on a prompt nobody sees, unless its program holds the Network Volumes grant,
and that grant is keyed on a versioned binary path. Jobs use `hl`; the keepalive itself reads nothing from a mount (`stat` of a name that cannot exist, `docs/macbook.md`) and mounts through a transient job outside `jobrun`'s chain; terminals in the Herdr core
read the mounts through its Full Disk Access.

## Status

`make storage-status` (`scripts/storage-status.sh`, both Macs) prints one page: each declared share with its state and free
space, the keepalive's grade, on the mini the external volume and the mirror, and the age of the last restic success.
`make storage-status ARGS=--json` is the contract below; the Tinycast command on the MacBook reads it (`ssh mini` runs it
there, the MacBook's own mounts come from its own run). `--no-remote` skips the one network read that is not a mount.
`make doctor` carries the check (`section_storage`): a **WARN, never a failure**, for a declared automount share that is not
healthy and, on the mini, a mirror older than 36 h (`STORAGE_MIRROR_MAX_AGE_HOURS`). It is not in the liveness push.

Read-only and bounded: it never mounts, unmounts or writes, and every call has a deadline (`STORAGE_PROBE_SECONDS`, default 5;
shares are probed in parallel), so a dead mount costs seconds, not a hang. A launchd job cannot list an SMB mount (see
Mounts), so the probe reads nothing from the share: the keepalive's own (`smb/smb-keepalive.sh`), `stat <mount>` and then
`stat` of a name that cannot exist, which has to reach the server. ENOENT is `healthy`; a hang is a silent server and
`Operation timed out` a dropped session (`stale`). `df -k` supplies free and total only (it is answered from cache, so it is
no liveness proof) and must name an `//…` SMB file system, not the boot volume. `smbutil statshares` is not used: it hangs
under a job's program. The server name never appears in the output.

### JSON contract (`schema: 1`)

A source that does not exist yet is not an error: its section has `available: false` and a `reason`, and its data fields are
absent or null. Consumers must branch on `available`, never on a missing key.

| Field | Type | Meaning |
|-|-|-|
| `schema` | `1` | Bumped on a breaking change |
| `generated_at`, `host` | ISO UTC string, `"mini"` or `"macbook"` | |
| `shares[]` | array | One per row of `smb-shares.conf` for this host, in file order. Empty with `shares_reason` set when none is declared |
| `shares[].name` | string | Share name (`SSD`, `HDD`); never the server |
| `shares[].automount` | boolean | The row's automount flag |
| `shares[].state` | `healthy`, `stale`, `not_mounted`, `unreachable`, `unprobeable` | `stale` = mounted but a probe hung or failed; `not_mounted` = reachable on 445, nothing mounted; `unreachable` = not mounted and no answer on 445; `unprobeable` = macOS refused the probe (`Operation not permitted`), neither healthy nor stale |
| `shares[].mounted`, `reachable` | boolean | From the mount table; from `nc` on 445 |
| `shares[].mount_point` | string or null | Absolute path while mounted |
| `shares[].healthy` | boolean or null | `null` only for `unprobeable` |
| `shares[].free_bytes`, `total_bytes` | number or null | From `df` of the mounted share; null unless `healthy` |
| `shares[].reason` | string or null | Why it is not healthy |
| `shares_reason` | string or null | Why `shares` is empty |
| `keepalive` | object | The keepalive's row from `jobs-grade`. `available`, `reason`; when available also `grade` (`ok`, `failing`, `stale`, `unloaded`, …), `rc`, `last_run`, `last_run_age_seconds`, `last_ok`, `consecutive_fail` |
| `external_volume` | object | The mini's gate (`scripts/lib/volume-gate.sh`). `available` (false while `unattached`), `state` (`unattached`, `absent`, `locked`, `unreadable`, `present`; null on the MacBook), `free_bytes`, `total_bytes` (number or null, only when present), `reason` |
| `mirror` | object | `<volume>/mirror/.status.json` written by `ext-mirror`. `available` is false with a `reason` while the volume is not present, the file does not exist (not built yet) or it has no readable `finished`; when available: `finished` (ISO), `age_seconds`, `sources` (the file's `sources`, passed through, or null) |
| `backup` | object | Age of the last restic success, read from the Uptime Kuma push monitor `Restic Backup - Push` over the keyless ssh `make doctor` already uses (no new credential). `available`, `reason`; when available `source`, `last_success`, `last_success_epoch`, `age_seconds`. Not available when Kuma cannot be reached (not a backup fault) or with `--no-remote` |
| `warnings[]` | array | `{code, subject, message}`; `code` is `share_not_healthy` (an automount share whose state is neither `healthy` nor `unprobeable`) or `mirror_stale` (older than the limit). Empty when all is well |

Exit 0 whenever a status was produced, warnings included; 1 on a missing dependency; 2 on a bad flag. `make storage-status-test`
holds the same contract as a `jq` predicate, plus a hanging-`stat` fixture.

Example, trimmed (`"…"` marks omitted fields):

```json
{"schema":1,"host":"mini",
 "shares":[{"name":"SSD","state":"healthy","mount_point":"/Users/me/HomeLab/SSD","free_bytes":189631221760,"total_bytes":499694788608,"…":"…"}],
 "keepalive":{"available":true,"grade":"ok","last_run_age_seconds":42,"…":"…"},
 "external_volume":{"available":false,"state":"unattached","reason":"not adopted yet (attached=false in config/external-volume.json)"},
 "mirror":{"available":false,"reason":"the external volume is unattached"},
 "backup":{"available":true,"age_seconds":56618,"…":"…"},
 "warnings":[]}
```

Measured on the mini, 2026-11-14: both shares `healthy`, the volume `unattached`, the mirror not built, restic 15 h old, the
keepalive `unloaded` with 378 failures in a row (issue 1106 owns that).

## Decided by the owner, 2026-11-14

| Question | Decision |
|-|-|
| Shutterflow's RAW root, now that EXT sits on the mini | `HDD/fuji/RAWs` through the share; EXT only mirrors. He repoints Shutterflow himself |
| Big videos offsite | no |
| The 2.0 TiB film copy on the HDD's second partition | delete, after file-by-file proof against `HDD/Filme` (homelab row `storage-consolidate`). Jellyfin's library is the copy that stays |
| Personal folders on EXT | documents to `SSD/Dokumente`, drone and project videos to `HDD/Videos`, the rescued USB stick dropped once its unique files are moved |
| Immich | retired (homelab issue 1201). It only showed the pre-Shutterflow copy of the finals in `SSD/Bilder/Fuji`; that copy and the old staging folder go once B2 is proven to hold every file |

The mini's Photos library (`~/Pictures`, 19 GiB) stays: it is the signed-in iCloud client, with
1,093 of the originals on disk, and the machine the export reads from. Once Photos holds all originals (**Download Originals**, §iCloud Photos export) it grows by about 75 GiB, then about 15 GiB a year (`docs/disk.md`).

## Found on 2026-11-14

Content hashes over the SSD share, `HDD/fuji` and the personal folders on EXT.

| Finding | Size | State |
|-|-|-|
| Fuji RAWs and videos on EXT and on the HDD are identical (6,320 and 418 files, name and size) | 280 GiB | wanted: it becomes `EXT/mirror/fuji` by a rename. An owner session that morning made them equal: 4 RAWs and 23 videos copied to the HDD, 1,549 culled RAWs (43 GiB) deleted there; those stay in restic for the retention time |
| Personal folders on EXT (documents, a rescued USB stick, drone and project videos) exist nowhere else | 22 GiB | **single copy, in no backup**: moves to the HomeLab |
| Second film copy on the HDD's other partition, frozen since 2025-01 | 2.0 TiB | stale: delete after approval |
| Old Shutterflow staging folder overlaps the finals folder | 13 GiB of 27 | stale: the library on the MacBook superseded both |
| Byte-identical duplicates elsewhere in the SSD share | under 3 GiB | not worth a pass |
| iCloud Photos is the only copy of the phone photos from 2021 on. The library on the SSD share ends in 2019, the phone folders in 2020, and none of the mini's local originals exist on the HomeLab | 78 GiB of originals (96 GiB with shared albums) | **one copy, at a sync service**, until the nightly export has caught up with Photos' download: §iCloud Photos export |

The duplication the many iterations were suspected of is small. The real gap was the opposite:
data with one copy.
