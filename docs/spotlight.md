# Spotlight on the dev host

Issue 1273. **Spotlight indexing is off on every volume of the mini**, by the owner's decision (2026-11-14, `sudo mdutil -a -i off`
from the MacBook), not per directory. The heartbeat's `spotlight` component (`scripts/spotlight-check.sh check`) **fails** when
`mdutil -sa` shows a volume with indexing on again, which a macOS update can do, or when `mdutil` gives no readable state.

**Undo:** `sudo mdutil -a -i on` (the index rebuilds, which costs CPU for hours). **Fix after an update turned it on:**
`sudo mdutil -a -i off`, a step that needs the owner's sudo, so an Errand with that command, never a sudoers rule.

## Do not rely on `mdfind` or `mdls` on the mini

They return nothing (or stale results) with the index off. Checked with `rg` over `~/SourceRoot` and `~/IuRoot` (2026-11-14): no
script, skill, hook or service of the owner's repos calls them. Two mentions remain, both harmless: `tinycast-extensions`
documents that Spotlight is disabled and does not use it, and `epos-tool-athena/bash/start-frontends.sh` tries `mdfind` as a
fallback after the other lookups and treats an empty answer as "not found". An agent finds files with `rg`, `fd` or `ls` in a
named directory, never by Spotlight.

## What the filing assumed, and what was true (macOS 26.7.2)

Probes: a file with a unique token per case, `mdfind -name` until it showed up (seconds) or not at all.

| Case | Indexed |
|-|-|
| plain directory under `~/tmp` | yes |
| directory named `x.noindex` | **no**, the name is honoured |
| directory holding a `.metadata_never_index` file | **yes**, the marker is not honoured, nested or not |
| dot-directory | no |
| `~/SourceRoot/…`, `~/IuRoot/…` | **no**, never indexed |
| `.claude/worktrees`, `.software-factory/releases`, `.cache`, `.claude` | no |

So the worktrees, the factory releases and `node_modules` under SourceRoot were never what Spotlight indexed. It indexed
what else churns: `~/orb/data` (1 046 changed files in 30 min), `~/cache/weatherorb`, `~/kiri-trial-dl`, `~/tmp`, `~/go`,
`~/Library`. A per-directory fence is a `*.noindex` rename of other repos' data or a root-only Search Privacy entry;
neither survives a new directory by itself, which is why the volume-wide switch is the right answer here.

## The measurement

CPU as a share of one core, from the accumulated CPU time of each daemon over the same 300 s window (`make spotlight-load
SECS=300`). The numbers swing by a factor of ten between windows, so only windows at a similar load are compared.

| 300 s window | load avg | mds_stores | mds | corespotlightd | fseventsd |
|-|-|-|-|-|-|
| 21:58, indexing on | 11 | 2.2 % | 2.7 % | 4.4 % | 11.0 % |
| 22:04, indexing on (control) | 10 | 3.5 % | 5.2 % | 4.8 % | 14.7 % |
| 22:16, indexing **off** | 10 | 0 | 3.2 % | 4.3 % | 8.9 % |

At the load the owner measured at (48, a 60 s window at 21:50: corespotlightd 45 %, fseventsd 17-31 %, mds about 10 %, ten
`mdworker_shared`) the daemons were far above these; shorter 60 s windows at load 15-21 read corespotlightd 0-19 %, fseventsd
5-21 %, mds + mds_stores 8-14 %.

What the switch bought: `mds_stores` and the `mdworker_shared` helpers are gone, `mds` is down to a residue. That is about
**3-6 % of a core** at load 10, not a core, plus the import bursts of the helpers when files change under load. What it did
not touch: `corespotlightd` (4 % here, 45 % at the owner's peak) and `fseventsd`.

## `corespotlightd`

Its load is queries, not file indexing: `spotlightknowledged.updater` (the Spotlight Knowledge embedding job) asks it about 84
times a minute and processes 0 items. It cannot be fenced. `launchctl disable gui/<uid>/com.apple.spotlightknowledged.updater`
is recorded but does not hold (launchd starts it again over Mach IPC, `runs` rose to 6), and `launchctl bootout` is refused by
SIP (error 150). The disable was reverted. Nothing to do.

## `fseventsd`: who it serves under load

It is not Spotlight's. `log show --predicate 'process == "fseventsd"'` records each client registration (`fsevent_add_client … for
pid N`, no path): 50 registrations in 30 min, the top seven pids all `claude` sessions with 5-6 streams each (36 sessions were
running), the rest short-lived processes already gone. Claude Code watches its directory tree, so every session is a client of
every event under its checkout.

The event volume is the other factor: in a 3-minute window 3 272 files under `~/SourceRoot` changed (without `node_modules`):
2 019 in one weatherorb worktree, 980 in one argo worktree, about 100 in all the rest. These are source files rewritten across
a whole tree (a branch switch, a formatter or a generator run), which is agents' ordinary work. Each event is delivered to every
client watching a parent directory.

Is anything worth doing? No. The three levers are all poor: (1) stopping clients means stopping the agents' file watching;
(2) a `.fseventsd/no_log` file at the volume root stops the on-disk event history, is root-only, and would not reduce the live
delivery that drives the CPU; its gain could not be measured here; (3) the daily `com.jkrumm.fseventsd-watch` restart already
exists for the leak case. At load 10 it costs 9-15 % of a core; the 40 % peaks come with the load, not before it. To look again
when it peaks: `make spotlight-load SECS=60` and the `log show` line above name the same daemons and the registrations.
