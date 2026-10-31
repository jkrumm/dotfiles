---
description: How macOS TCC (Full Disk Access, Files and Folders, AppData) bites our headless and unattended programs, the three patterns that make a grant durable, the per-binary classification of both machines, and the one-time grants. Read before touching a LaunchAgent program, a core upgrade or a 1Password dialog.
---

# TCC — durable file-access grants

> - **A grant is keyed on the program's resolved path plus its code requirement.** An ad-hoc signature's requirement is
>   its cdhash, so every new build fails the row silently, and a versioned path (Cellar, Caskroom,
>   `~/.local/share/claude/versions/<v>`) moves on every upgrade.
> - **TCC judges the responsible process:** for a LaunchAgent that is the job's own program, inherited by every
>   descendant unless a child disclaims. No user-installed PPPC profile on an unmanaged Mac, no scripted FDA grant.
> - **The symptom is a freeze, not an error:** the first `open()` of `~/Documents`, `~/Desktop`, `~/Downloads`, iCloud or
>   another app's data raises a dialog on a screen nobody looks at, and the calling process stops at 0 % CPU.
>   `sample <pid>` shows `openat`; `log show --predicate 'process == "tccd"'` shows `AUTHREQ_PROMPTING … responsible_path=…`.

## The three patterns

| Pattern | Use when | How |
|-|-|-|
| **Launcher** | a long-lived job spawns many programs that may touch protected folders (the herdr-core and every terminal in it) | A tiny native Mach-O at a stable path is the LaunchAgent's `Program`; it `posix_spawn`s the real program as a child. The grant goes to the launcher once. Used: `~/.local/libexec/herdr-core-launcher` |
| **Stable path or signature** | one binary needs its own grant and cannot run under a launcher | A copy at an unversioned path, or re-signed with one stable self-signed identity and an explicit `--identifier`, then `bootout` + `bootstrap` (launchd pins the code identity at bootstrap). Fallback only; not needed so far |
| **No grant** | the job only touches `~/SourceRoot`, `~/IuRoot`, `/opt/homebrew`, `~/.local`, `/tmp` | Nothing to do. Listed in `config/tcc-programs.json` so the check stays quiet on purpose |

## The launcher (design verified 2026-10-31)

`scripts/herdr-core-launcher.c` → `make herdr-core-setup` builds it to `~/.local/libexec/herdr-core-launcher`, ad-hoc signed
with the fixed identifier `com.jkrumm.herdr-core-launcher`. It rebuilds **only when the source hash changes**, because a
new binary is a new code identity and the grant is lost once. Evidence (attribution, swap, what is still unproven):
`docs/herdr-core.md` §Launcher evidence. The check that proves the grant is `make tcc-probe` (a core terminal runs `ls`
on Documents, Desktop and Downloads; blocked means no grant). Do not run it without the grant on a screen nobody
watches without dismissing the dialog afterwards.

## Per-program classification

`make tcc-check` (read-only, in `make doctor`) reads every `~/Library/LaunchAgents/*.plist`, resolves the program, and
flags one that is ad-hoc signed (`codesign -dv`) or on a versioned path. A flagged label that is not in
`config/tcc-programs.json` fails the check. The core job must also run through the launcher.

Mini, 2026-10-31 (68 agents; the unified log of the last 7 days holds no `AUTHREQ_PROMPTING` from any of them, only from the scratch cores of this work):

| Program | Why flagged | Class |
|-|-|-|
| `com.jkrumm.herdr-core` | was the ad-hoc core; now the launcher | launcher |
| `com.iu.athena-postgres`, `sh.brew.postgresql@18` | Cellar path, ad-hoc | no grant (data under `/opt/homebrew/var`) |
| `com.iu.prometheus-dashboard-autodeploy`, `com.iu.teamchat-runtime-deploy` | python3 in a Cellar path | no grant (`~/IuRoot`) |
| `com.iu.prometheus-vpn-watcher`, `com.jkrumm.weatherorb.worker-*`, `…watchdog` | uv python, ad-hoc | no grant (`~/IuRoot`, `~/SourceRoot`) |
| `com.jkrumm.modelpick-web` | bun in a Cellar path (Developer ID signed) | no grant |
| `com.jkrumm.weatherorb.serve` | ad-hoc built `openmeteo-api` | no grant (`~/SourceRoot/weatherorb`) |
| `herdr.collie` | ad-hoc plugin binary | no grant, retires with Wave 7 |
| `homebrew.mxcl.sleepwatcher` | Cellar path, ad-hoc | no grant |
| bash/zsh/osascript/python-by-shebang jobs, `jobrun`/script jobs | Apple platform binaries or unsigned scripts: stable identity | not flagged |

Not LaunchAgents but the same failure: `claude` (`~/.local/share/claude/versions/<v>`, a fresh client on every
auto-update), `op` (Caskroom path), `herdr` classic (Cellar path). Anything they spawn from a **core terminal** is covered
by the launcher's grant; run from a plain Ghostty shell they are not.

MacBook (different user home): LaunchAgent programs were read over ssh; the TCC log is not readable from an ssh session
(`Could not open local log store`), so the MacBook's prompt history is part of its grant batch. Flagged there:
`com.jkrumm.herdr-core` (launcher), `com.iu.prometheus-vpn-watcher` (uv python), `homebrew.mxcl.ntfy-mac` and
`homebrew.mxcl.sleepwatcher` (Cellar, ad-hoc). The last three need no grant.

## One-time grants

| Machine | Grant | Why |
|-|-|-|
| mini | Full Disk Access → `~/.local/libexec/herdr-core-launcher` | every program in a core terminal; survives core upgrades |
| MacBook | Full Disk Access → `~/.local/libexec/herdr-core-launcher` | same; the app's terminals run in that core, and it is what spares `op` the AppData dialog (§1Password) |
| MacBook | Full Disk Access → Ghostty.app (optional) | `op` and everything else started from a plain Ghostty tab |

Both are queued with `ask-human` (one batch per machine). After a grant: `make tcc-probe`. The grants on
`~/.local/bin/herdr-core` can stay; they match nothing once the symlink points at the Cellar.

## 1Password (`op`) — the AppData dialog

**Acceptance (owner, 2026-10-31):** `op` (biometric, desktop-app integration ON) in any Herdr terminal on the MacBook shows
only the 1Password Touch ID prompt, never *"op möchte auf Daten aus anderen Apps zugreifen"*
(`kTCCServiceSystemPolicyAppData`), and that survives core updates and `brew upgrade 1password-cli`. No
`OP_LOAD_DESKTOP_APP_SETTINGS=false` on the MacBook: it can cost biometric unlock.

**Cause:** `op` reads the desktop app's group container to handshake. The grant is keyed on the requesting program's
path, which for a bare `op` is `/opt/homebrew/Caskroom/1password-cli/<ver>/op`, so every `brew upgrade` drops it, and
"Allow" does not persist (it re-prompts per `op` process). **Full Disk Access on the responsible process supersedes the
AppData check**, so the fix is to make `op` run under a process that holds FDA durably, not to grant `op` itself.

**Fix:** the launcher pattern on the MacBook as well, plus routing every other `op` caller under the launcher or a
terminal app that has its own grant. `op`'s own path stops mattering.

| Context where `op` runs (MacBook) | Responsible process | Covered by |
|-|-|-|
| A Herdr app terminal, `hc run`, `hc exec` (incl. Claude Code and `make secrets-seed` started there) | `herdr-core-launcher` | the launcher's FDA, survives core swaps (below) |
| `ask-human --cmd` / `make human-queue` commands (arrive over ssh) | sshd | **not covered**: wrap the command as `hc run --timeout 900 '<cmd>'`. The mini's `secrets-seed` guidance (SessionStart hook) already does |
| `com.jkrumm.opbackup` LaunchAgent (backup + the secrets reseed guard) | its program | the plist's program is the launcher, which spawns bash; `make opbackup-setup` builds the launcher first, `make tcc-check` fails otherwise |
| Ghostty (login shells, Claude Code started there) | Ghostty.app | Full Disk Access on Ghostty.app: a Developer-ID-signed app, so the row survives updates. One-time grant, a broad one: it covers every program in every Ghostty tab |
| `ssh iumac '… op …'` from the mini | sshd | **not covered**: use `ask-human` with the `hc run` wrapper |
| Anything else that launches `op` (a new LaunchAgent, a cron-like job) | its program | run it through the launcher: `ProgramArguments` = launcher, then the real program; add the label to `OP_JOBS` in `scripts/tcc-check.sh` |

**Why a core swap keeps the grant:** the key is the launcher (stable path, identifier `com.jkrumm.herdr-core-launcher`),
and a terminal's attribution survives the death of the process that spawned it. Measured 2026-10-31 on the mini: a
terminal born *before* a `kickstart -k` that swapped the core for a differently signed build, running `ls ~/Documents`
*after* it, was attributed to `responsible=com.jkrumm.herdr-core-launcher, responsible_path=~/.local/libexec/herdr-core-launcher`
(the launcher pid it names is gone). Without a grant that attribution is the only thing observable; the grant itself is
exercised by the probe below.

**Acceptance check, with evidence:** `scripts/op-tcc-probe.sh`, run inside a core terminal on the MacBook:

```text
hc run --timeout 900 'make op-tcc-probe SWAP=1'
```

It reads one ref from `dotfiles-private/headless.refs` (value discarded), then searches the unified log for an
`AUTHREQ_PROMPTING … kTCCServiceSystemPolicyAppData` since the read began; PASS means the read worked and none was raised.
`SWAP=1` repeats the check from the same terminal and from a fresh one after pointing the core at a differently signed
copy and kickstarting it (the original build is restored on exit). "Exactly one Touch ID prompt" is the half only the
person at the machine sees. A terminal without Full Disk Access cannot even read that log, which the probe reports as
FAIL. Evidence is recorded below when run.

**Status (2026-10-31):** design and attribution evidence are in; the grant on the MacBook launcher, the cutover and the
probe run are pending the owner (ask-human, MacBook). When the probe passes:
1. Drop the FDA-on-Caskroom-path assertion in `scripts/brew-upgrade.sh` §op and the `docs/homebrew.md` row.
2. Ghostty: add the FDA row if `op` is used from plain Ghostty tabs.

Rejected: a stable-path copy of `op` (recipe 3: refresh logic after each upgrade, one more grant to keep) and the
`OP_LOAD_DESKTOP_APP_SETTINGS` switch (undocumented, may cost biometric unlock). `secrets-run` is untouched
(`AGENTS.md` §Secrets).
