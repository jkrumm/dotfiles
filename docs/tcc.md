---
description: How macOS TCC (Full Disk Access, Files and Folders, AppData) bites our headless and unattended programs, the three patterns that make a grant durable, the per-binary classification of both machines, and the one-time grants. Read before touching a LaunchAgent program, a core update or a 1Password dialog.
---

# TCC — durable file-access grants

> - **A grant is keyed on the program's resolved path plus its code requirement.** An ad-hoc signature's requirement is
>   its cdhash, so every new build fails the row silently, and a versioned path (Cellar, Caskroom,
>   `~/.local/share/claude/versions/<v>`) moves on every upgrade.
> - **TCC judges the responsible process:** for a LaunchAgent that is the job's own program, inherited by every
>   descendant unless a child disclaims. herdr-core's holders and core disclaim, so terminal programs are judged as the
>   holder or core itself: the signed `Herdr Core.app`. No user-installed PPPC profile on an unmanaged Mac, no scripted FDA grant.
> - **The symptom is a freeze, not an error:** the first `open()` of `~/Documents`, `~/Desktop`, `~/Downloads`, iCloud or
>   another app's data raises a dialog on a screen nobody looks at, and the calling process stops at 0 % CPU.
>   `sample <pid>` shows `openat`; `log show --predicate 'process == "tccd"'` shows `AUTHREQ_PROMPTING … responsible_path=…`.

## The three patterns

| Pattern | Use when | How |
|-|-|-|
| **Signed bundle** | a long-lived program with its own identity that spawns many others (the herdr-core and every terminal in it) | Upstream's `Herdr Core.app` (Developer ID team `2W9652Q7QR`, `dev.herdr.core`, notarized) at the fixed path `~/.local/share/herdr-core/active/Herdr Core.app`. The core, each holder and the terminal programs are attributed to the bundle; Full Disk Access is granted to that path once and survives updates. We build nothing |
| **Launcher** | a LaunchAgent whose programs call `op` (or touch protected folders) and whose own program is ad-hoc or on a versioned path | A tiny native Mach-O at a stable path is the LaunchAgent's `Program`; it `posix_spawn`s the real program as a child (no disclaim). The grant goes to the launcher once. Used: `~/.local/libexec/herdr-core-launcher` for `com.jkrumm.opbackup` only (the name is historical; the grant is keyed on it) |
| **No grant** | the job only touches `~/SourceRoot`, `~/IuRoot`, `/opt/homebrew`, `~/.local`, `/tmp` | Nothing to do. Listed in `config/tcc-programs.json` so the check stays quiet on purpose |

A stable path or a signature whose designated requirement does not carry the cdhash (`--identifier` plus an explicit
`-r='designated => identifier "…"'`) is what makes the launcher's grant durable (§The launcher).

## The launcher (opbackup only)

`scripts/herdr-core-launcher.c` → `make herdr-core-launcher` (via `scripts/herdr-core-launcher-build.sh`; a prerequisite
of `opbackup-setup` only, never of `herdr-core-setup`) builds it to `~/.local/libexec/herdr-core-launcher`, signed with the
identifier `com.jkrumm.herdr-core-launcher` and an explicit designated requirement
`identifier "com.jkrumm.herdr-core-launcher"`. An ordinary ad-hoc signature's requirement is its cdhash, so every rebuild
loses the grant (`tccd: Failed to match existing code requirement`); this one is identical across rebuilds (proven
2026-11-01). The build reruns when the source hash **or the signing mode** changes (both in `.src-sha`); a changed
requirement queues the Full Disk Access re-grant through `ask-human`, an unchanged one swaps silently. Until the first
rebuild after the migration, the installed binary may still carry a cdhash requirement: `make tcc-check` WARNs "re-sign
pending" (informational; do not rebuild just to clear it, a rebuild loses the grant). Its source still carries comments
about the old core job: do not edit the file for that, the hash would trigger the rebuild.

**Why not a self-signed certificate (researched 2026-11-01, macOS 26):** `codesign -s` refuses an untrusted self-signed
identity (`CSSMERR_TP_NOT_TRUSTED`) and trusting it raises a SecurityAgent dialog, so it is not scriptable over ssh. The
identifier-only requirement gives the same durability.

## herdr-core: who macOS attributes terminals to

Since core 0.1.17 every holder re-execs with `responsibility_spawnattrs_setdisclaim`, so a terminal program takes its
holder's identity; the detached core is its own responsible process. Full Disk Access on a launcher therefore never covered
terminal programs (only the core and `hc exec` children): that was the cause of the endless "herdr-core möchte auf Daten aus
anderen Apps zugreifen" dialogs. Core 0.1.18 ships upstream's own identity, `Herdr Core.app`, and `make tcc-probe` proves it:
a fresh `hc run` terminal reads Documents, Desktop and Downloads, and `scripts/hc-responsible.py` (python3 ctypes on
`responsibility_get_pid_responsible_for_pid`) lists, for the core and every holder, who is responsible and exits 1 for any
whose responsible process is not inside `Herdr Core.app` (a Homebrew Cellar herdr-core, sshd, a launcher).

- Terminals born before the cutover keep their old holder, and with it the old identity, until they end. Never judge a
  grant from a pre-existing terminal; the probe runs in a fresh `hc run` terminal by itself.
- A core started by a client over ssh is attributed to sshd (a stray; `lib/core-up.sh` fails it, `docs/herdr-core.md`).
- Probe without a dialog: Full Disk Access never prompts, it only allows or denies, so `hc exec /usr/bin/sqlite3
  "/Library/Application Support/com.apple.TCC/TCC.db" "select 1"` is safe on an unwatched screen;
  `log show --predicate 'process == "tccd" AND eventMessage CONTAINS "AUTHREQ_ATTRIBUTION"'` names the `responsible_path`.
- Upstream still says that session-scoped AppData consent on macOS 26 may prompt anyway. Never click "Allow" as a fix (it
  re-prompts per process), and never promise "never again" in docs.

## Per-program classification

`make tcc-check` (read-only, in `make doctor`) reads every `~/Library/LaunchAgents/*.plist`, resolves the program, and
flags one that is ad-hoc signed (`codesign -dv`) or on a versioned path. A flagged label that is not in
`config/tcc-programs.json` fails the check. A job that runs `op` (`OP_JOBS` in the script) must run through the launcher.

Mini, 2026-10-31 (68 agents; the unified log of the last 7 days holds no `AUTHREQ_PROMPTING` from any of them, only from the scratch cores of this work):

| Program | Why flagged | Class |
|-|-|-|
| `com.iu.athena-postgres`, `sh.brew.postgresql@18` | Cellar path, ad-hoc | no grant (data under `/opt/homebrew/var`) |
| `com.iu.prometheus-dashboard-autodeploy`, `com.iu.teamchat-runtime-deploy` | python3 in a Cellar path | no grant (`~/IuRoot`) |
| `com.iu.prometheus-vpn-watcher`, `com.jkrumm.weatherorb.worker-*`, `…watchdog` | uv python, ad-hoc | no grant (`~/IuRoot`, `~/SourceRoot`) |
| `com.jkrumm.modelpick-web` | bun in a Cellar path (Developer ID signed) | no grant |
| `com.jkrumm.weatherorb.serve` | ad-hoc built `openmeteo-api` | no grant (`~/SourceRoot/weatherorb`) |
| `com.jkrumm.collie` | compiled bridge in `~/.local/share/collie` | no grant (own config, state and log only) |
| `homebrew.mxcl.sleepwatcher` | Cellar path, ad-hoc | no grant |
| bash/zsh/osascript/python-by-shebang jobs, `jobrun`/script jobs | Apple platform binaries or unsigned scripts: stable identity | not flagged |

Not LaunchAgents but the same failure: `claude` (`~/.local/share/claude/versions/<v>`, a fresh client on every
auto-update), `op` (Caskroom path). Anything they spawn from a **core terminal** is covered
by the `Herdr Core.app` grant; run from a plain Ghostty shell they are not.

MacBook (different user home): LaunchAgent programs were read over ssh; the TCC log is not readable from an ssh session
(`Could not open local log store`), so the MacBook's prompt history is part of its grant batch. Flagged there:
`com.iu.prometheus-vpn-watcher` (uv python), `sh.brew.ntfy-mac` (was `homebrew.mxcl.`; brew renamed its service labels) and
`homebrew.mxcl.sleepwatcher` (Cellar, ad-hoc). They need no grant. The MacBook has no `com.jkrumm.herdr-core` job; the Herdr app starts its core.

## One-time grants

| Machine | Grant | Why |
|-|-|-|
| mini | Full Disk Access → `~/.local/share/herdr-core/active/Herdr Core.app` | the core, every holder and every program in a core terminal; survives updates (Developer ID identity at a fixed path). Re-grant only if the signing identifier or team changes |
| mini | Local Network and microphone prompts for Herdr Core | answer them once at the mini's screen; unanswered, terminal programs that reach the LAN freeze or fail |
| MacBook | Full Disk Access → the same bundle path | same; the Herdr app's terminals run in that core, and it is what spares `op` the AppData dialog (§1Password) |
| MacBook | Local Network and microphone prompts | as on the mini |
| MacBook | Full Disk Access → `~/.local/libexec/herdr-core-launcher` | only for `com.jkrumm.opbackup` (the pattern "Launcher"); granted, keyed on the binary's current cdhash |
| MacBook | Full Disk Access → Ghostty.app (optional) | `op` and everything else started from a plain Ghostty tab |

Both bundle grants are a human step in System Settings (no scripted grant): `make herdr-core-setup` and `make tcc-probe`
print it when the probe fails. After a grant: `make tcc-probe`. A grant earlier given to `~/.local/bin/herdr-core` or to the
launcher for the core matches nothing and can be removed.

## 1Password (`op`) — the AppData dialog

**Acceptance (owner, 2026-10-31):** `op` (biometric, desktop-app integration ON) in any Herdr terminal on the MacBook shows
only the 1Password Touch ID prompt, never *"op möchte auf Daten aus anderen Apps zugreifen"*
(`kTCCServiceSystemPolicyAppData`), and that survives core updates and `brew upgrade 1password-cli`. No
`OP_LOAD_DESKTOP_APP_SETTINGS=false` on the MacBook: it can cost biometric unlock.

**Cause:** `op` reads the desktop app's group container to handshake. The grant is keyed on the requesting program's
path, which for a bare `op` is `/opt/homebrew/Caskroom/1password-cli/<ver>/op`, so every `brew upgrade` drops it, and
"Allow" does not persist (it re-prompts per `op` process). **Full Disk Access on the responsible process supersedes the
AppData check**, so the fix is to make `op` run under a process that holds FDA durably, not to grant `op` itself.

| Context where `op` runs (MacBook) | Responsible process | Covered by |
|-|-|-|
| A Herdr app terminal, `hc run`, `hc exec` (incl. Claude Code and `make secrets-seed` started there) | the holder, i.e. `Herdr Core.app` | the bundle's FDA, survives core updates |
| `ask-human --cmd` / `make human-queue` commands (arrive over ssh) | sshd | **not covered**: wrap the command as `hc run --timeout 900 '<cmd>'`. The mini's `secrets-seed` guidance (SessionStart hook) already does |
| `com.jkrumm.opbackup` LaunchAgent (backup + the secrets reseed guard) | its program | the plist's program is the launcher, which spawns bash; `make opbackup-setup` builds the launcher first, `make tcc-check` fails otherwise |
| Ghostty (login shells, Claude Code started there) | Ghostty.app | Full Disk Access on Ghostty.app: a Developer-ID-signed app, so the row survives updates. One-time grant, a broad one: it covers every program in every Ghostty tab |
| `ssh <peer-host> '… op …'` from the mini | sshd | **not covered**: use `ask-human` with the `hc run` wrapper |
| Anything else that launches `op` (a new LaunchAgent, a cron-like job) | its program | run it through the launcher: `ProgramArguments` = launcher, then the real program; add the label to `OP_JOBS` in `scripts/tcc-check.sh` |

**Acceptance check:** `make op-tcc-probe` on the MacBook (it re-execs through `hc run`; refuses unless a launchd-born core
is up). It reads one ref from `dotfiles-private/headless.refs` (value discarded; via `op_run`, so the account follows the
workspace), then searches the unified log for an `AUTHREQ_PROMPTING … kTCCServiceSystemPolicyAppData` since the read began;
PASS means the read worked and none was raised. Re-run it after every `make herdr-core-update`. "Exactly one Touch ID
prompt" is the half only the person at the machine sees. A terminal without Full Disk Access cannot even read that log,
which the probe reports as FAIL.

**macOS 27 (upstream's official interactive fix):** Files & Folders, "Data shared by 1Password", per terminal app. It is
per-terminal and interactive, so it does not help unattended callers. **Service accounts** cannot read the Private vault and
are rate limited, so they are no replacement either; our `secrets-run` cache shim (the mini's validated pattern, SOPS+age
cache, no `op` call) stays the answer for headless callers (1Password shell-plugins #606).

When the probe passes once on the MacBook: drop the FDA-on-Caskroom-path assertion in `scripts/brew-upgrade.sh` §op and the
`docs/homebrew.md` row; add the Ghostty FDA row if `op` is used from plain Ghostty tabs.

Rejected: a stable-path copy of `op` (refresh logic after each upgrade, one more grant to keep) and the
`OP_LOAD_DESKTOP_APP_SETTINGS` switch (undocumented, may cost biometric unlock). `secrets-run` is untouched
(`AGENTS.md` §Secrets).
