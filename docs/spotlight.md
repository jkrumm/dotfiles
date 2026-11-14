# Spotlight on the dev host

Issue 1273. The mini's Data volume has its Spotlight **file index switched off** (`make spotlight-fence`); the heartbeat's
`spotlight` component (WARN-only) says when it is on again. This page is what was measured and why it is the whole
volume and not a list of directories.

## What the filing assumed, and what is true (macOS 26.7.2, 2026-11-14)

Probes: a file with a unique token per case, `mdfind -name` until it showed up (seconds) or not at all.

| Case | Indexed |
|-|-|
| plain directory under `~/tmp` | yes |
| directory named `x.noindex` | **no** — the name is honoured |
| directory holding a `.metadata_never_index` file | **yes** — the marker is not honoured, nested or not |
| dot-directory (`.dot`) | no |
| `~/SourceRoot/…`, `~/IuRoot/…` | **no** — never indexed |
| `.claude/worktrees`, `.software-factory/releases`, `.cache`, `.claude` | no (dot-directories, or under SourceRoot) |

So the worktrees, `node_modules` under SourceRoot and the factory releases were never what Spotlight indexed. What it indexes
is everything else that churns: `~/orb/data` (1 046 changed files in 30 min), `~/cache/weatherorb`, `~/kiri-trial-dl`,
`~/tmp`, `~/go`, `~/Library`. A per-directory fence would be a `*.noindex` rename of other repos' data directories (the
`rb` repo's `~/.rb/data.noindex` already follows it) or an entry in the Search Privacy list, which is root-only
(`mdutil -P` reads it as root) or a System Settings click, and neither survives a new directory by itself.

## What it costs

CPU as a share of one core, from the accumulated CPU time of each daemon over a window (`make spotlight-load SECS=300`):

| Window | load avg | fseventsd | mds + mds_stores | corespotlightd |
|-|-|-|-|-|
| 21:55, 60 s | 21 | 5 % | 8 % | 19 % |
| 21:58, 60 s | 15 | 21 % | 14 % | 0 % |
| 21:58, 300 s | 11 | 11 % | 5 % | 4 % |
| 22:04, 300 s (control: nothing changed) | 10 | 15 % | 9 % | 5 % |
| owner's reading, 21:50 | 48 | 17-31 % | ~10 % | 45 % |

The numbers swing by a factor of ten between windows, so one reading proves nothing: a before/after needs the same
300 s window on both sides, and the control row shows the noise (the two 300 s windows differ by 4 points in `mds`).
Steady state, the file index (mds, mds_stores, the mdworker_shared helpers) is 5-14 % of a core, not a core.

## What was tried and cannot be fenced

- **`corespotlightd`** (the 45 % peak): its load is queries from `spotlightknowledged.updater` (pid in the log's `pid:`
  field, about 84 searches a minute, "Processed 0 items"), not indexing of files. `launchctl disable
  gui/<uid>/com.apple.spotlightknowledged.updater` is recorded but does not hold: launchd starts it again over Mach IPC (`runs`
  went to 6), and `launchctl bootout` is refused by SIP (error 150). Left alone, the disable was reverted.
- **`fseventsd`**: it serves every watcher on the host (agents, dev servers, Spotlight itself); the only lever is the daily
  restart that already exists (`com.jkrumm.fseventsd-watch`). A `.fseventsd/no_log` file at the volume root would stop the
  on-disk history, but it is root-only and its gain was not measurable here, so it is not done.
- The Search Privacy list: root-only, one entry per directory, and invisible to the owner as a file in git.

## What is done

`make spotlight-fence` runs `sudo -n mdutil -i off /System/Volumes/Data`, allowed by one sudoers rule
(`scripts/sudoers.d/spotlight-index`, installed once by `make spotlight-sudoers`, which the owner runs through ask-human; the
mini's sudo password is MacBook-only). `make setup` converges it; without the rule it says so and carries on.
`make spotlight-check` is the read-only state.

**What the owner loses:** Spotlight, Finder and `mdfind` search of files on the mini. Nothing on the mini calls them (no
script, skill or hook uses `mdfind`), the MacBook's Spotlight is a different machine, and CoreSpotlight (app items, Photos
search) is a separate store that this does not touch. The external SSD already has indexing off (`docs/external-ssd.md`).

**Rollback:** `sudo mdutil -i on /System/Volumes/Data`, then remove `/etc/sudoers.d/spotlight-index`.

**New data directories** need no step while the index is off. If it is ever turned on again (the WARN says so), a churning data
directory named `*.noindex` is the one per-directory form macOS honours.
