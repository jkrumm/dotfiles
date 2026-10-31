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
| MacBook | Full Disk Access → `~/.local/libexec/herdr-core-launcher` | same; the app's terminals run in that core |

Both are queued with `ask-human` (one batch per machine). After a grant: `make tcc-probe`. The grants on
`~/.local/bin/herdr-core` can stay; they match nothing once the symlink points at the Cellar.

## 1Password (`op`) — the AppData dialog

`op` reads the desktop app's group container to handshake, which is `SystemPolicyAppData`. The grant is keyed on the
path, which is `/opt/homebrew/Caskroom/1password-cli/<ver>/op`, so every `brew upgrade` drops it. "Allow" does not persist
(it re-prompts per `op` process); Full Disk Access on that exact path supersedes the check (`AGENTS.md` §Secrets).

Recipes, cheapest first. **None is verified yet**: it needs the launcher grant on the MacBook and a Touch ID prompt in
front of the owner, and `secrets-run` stays untouched (`AGENTS.md` §Secrets), so the item stops here and is reported.

1. `OP_LOAD_DESKTOP_APP_SETTINGS=false` + `OP_CACHE=false` in headless contexts. Undocumented; verify with
   `OP_… op whoami` while watching `log show` for a `kTCCServiceSystemPolicyAppData` request from `op`.
2. Run `make secrets-seed` from a core terminal on the MacBook once its launcher holds FDA: `op` inherits the grant, and
   the Caskroom path stops mattering. The pushed `ask-human --cmd` arrives through ssh, so route it through `hc exec`
   (responsible process: the launcher) instead of the ssh session.
3. A stable-path copy of `op` with its own FDA grant, refreshed after each upgrade.

When one is verified: wire it into `secrets-seed` / `brew-upgrade.sh` and drop the FDA-on-Caskroom-path assertion
(`brew-upgrade.sh` §op, `docs/homebrew.md`).
