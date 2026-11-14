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
| Other photos: phone archives, old libraries | `SSD/Bilder` | EXT mirror | restic |
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
| EXT mirror (plan row `ext-mirror`, not built yet) | SSD share, `HDD/fuji` and `HDD/Videos` → `EXT/mirror` | nightly, pulled by the mini over S3 (`hl`) | `jobrun` grade and a status file on EXT |
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

## Mounts

One agent, `com.jkrumm.smb-keepalive`, mounts every share and remounts a stale one within 60 s
or on the next network change (`docs/macbook.md` §HomeLab Samba). Shares are declared in
`dotfiles-private/smb-shares.conf`.

| Share | Served by | MacBook | Mac mini |
|-|-|-|-|
| `SSD` | HomeLab Samba | `/Volumes/SSD`, automount | `~/HomeLab/SSD`, automount |
| `HDD` | HomeLab Samba | `/Volumes/HDD`, automount | `~/HomeLab/HDD`, automount |
| `EXT` | mini (plan row `smb-ssd-share`, not built yet) | `/Volumes/EXT`, automount | local disk |
| home folder with `~/Shuttle` | mini | mounted by hand today; automount comes with `smb-ssd-share` | local disk |

Agents on the mini read and write HomeLab files with `hl` (S3). The SMB mounts are for bulk
copies and for people.

## Status

Not built yet: `make storage-status` (plan row `storage-status`) prints shares, mounts, free
space and the age of the mirror and the backup, and `--json` feeds a Tinycast command on the
MacBook. Until then: `make smb-keepalive-status` for the mounts, the Kuma push monitor for restic.

## Decided by the owner, 2026-11-14

| Question | Decision |
|-|-|
| Shutterflow's RAW root, now that EXT sits on the mini | `HDD/fuji/RAWs` through the share; EXT only mirrors. He repoints Shutterflow himself |
| Big videos offsite | no |
| The 2.0 TiB film copy on the HDD's second partition | delete, after file-by-file proof against `HDD/Filme` (homelab row `storage-consolidate`). Jellyfin's library is the copy that stays |
| Personal folders on EXT | documents to `SSD/Dokumente`, drone and project videos to `HDD/Videos`, the rescued USB stick dropped once its unique files are moved |
| Immich | retired (homelab issue 1201). It only showed the pre-Shutterflow copy of the finals in `SSD/Bilder/Fuji`; that copy and the old staging folder go once B2 is proven to hold every file |

Still open: the mini's 19 GiB Photos library (`~/Pictures`, last written 2026-05) has no declared home or copy.

## Found on 2026-11-14

Content hashes over the SSD share, `HDD/fuji` and the personal folders on EXT.

| Finding | Size | State |
|-|-|-|
| Fuji RAWs and videos on EXT and on the HDD are identical (6,320 and 418 files, name and size) | 280 GiB | wanted: it becomes `EXT/mirror/fuji` by a rename. An owner session that morning made them equal: 4 RAWs and 23 videos copied to the HDD, 1,549 culled RAWs (43 GiB) deleted there; those stay in restic for the retention time |
| Personal folders on EXT (documents, a rescued USB stick, drone and project videos) exist nowhere else | 22 GiB | **single copy, in no backup**: moves to the HomeLab |
| Second film copy on the HDD's other partition, frozen since 2025-01 | 2.0 TiB | stale: delete after approval |
| Old Shutterflow staging folder overlaps the finals folder | 13 GiB of 27 | stale: the library on the MacBook superseded both |
| Byte-identical duplicates elsewhere in the SSD share | under 3 GiB | not worth a pass |

The duplication the many iterations were suspected of is small. The real gap was the opposite:
data with one copy.
