# PRD — Subtraction pass on the personal dev setup

Status: draft, 2026-08-30. Delete this file when the last phase lands.

## Problem

The setup has grown by accretion. Every incident became a make target, a
heartbeat component, a doc section and a paragraph in `CLAUDE.md`; nothing was
ever removed. Measured today:

| Surface | Size |
|-|-|
| `dotfiles/CLAUDE.md` | 99,930 chars (limit 150k) — `## Remote dev` alone 18.8k; OpenCode + Battery + opbackup + Remote dev = half the file |
| `Makefile` | 3,028 lines, 136 targets |
| Global skills / scripts / docs / zsh modules | 27 / 44 / 18 / 14 |
| Retired-but-present | `localai/` (24 tracked files), `litellm/` (proxy still running on the mini, serving only its own liveness pings), OpenCode (config + zsh + AGENTS.md), `/sync` skill, `cqueue/` (45k untracked build files + tombstone in `docs/archive`) |
| Duplicated ways to do one thing | 2 ways in (`dev`/mosh vs `desk`/herdr --remote), 2 terminals (cmux vs Ghostty, two config files), 3 launchers (`c`/`ca`/`oc`), 3 dev-server doors (`.test`, portdoor, clean), 5 overlapping read-only diagnostics (`remote-dev-doctor`, `mini-sweep`, `launchagents-check`, `drift-check`, `make status`) |
| Unmapped | 6 mini repos not in the repo table (`meteo` with 8 LaunchAgents, `hermes-webui`, `basalt-ui-obsidian`, `brain-sources`, `linewatch-router-spike`, `dispatch-scratch`); 1 MacBook repo not in the sanctioned set (`shutterflow`); ~35 LaunchAgents on the mini with no single list anywhere |

The concrete cost showed up today twice: `dev` is broken because the pinned
`mosh` links a `libprotobuf` that `make brew-upgrade` upgraded out from under it
(a pin protects the binary, not its dylib graph), and **the `colima` + `herdr`
boot plists are gone from `~/Library/LaunchAgents` on the mini** — both jobs run
only from launchd's cached definition since the 2026-08-29 reboot, and no
monitor checks the boot path. The next power cut takes Docker and herdr down
silently.

The alternative considered and rejected: moving the environment to Omarchy
(try-omarchy VM on the MacBook). It adds a third environment and a fourth OS,
contradicts the chosen architecture (MacBook = thin client, mini = always-on
dev host), and none of this repo ports. What Omarchy has that this setup lacks
is coherence through *deletion* — which is this PRD.

## Goals

1. **One canonical map.** `docs/architecture.md`: every machine, every repo on
   each machine, every LaunchAgent/LaunchDaemon and which repo owns it, every
   inbound door, the secrets flow, and what monitors what. Anything not on the
   map is either added or deleted — never left implicit.
2. **One of each.** One way in (`desk`), one terminal (Ghostty), two launchers
   (`c`, `ca`), two dev-server doors (`.test`, clean `.mini.jkrumm.com`), one
   push heartbeat + one on-demand `make doctor`.
3. **Nothing retired stays on disk.** Git history is the archive.
4. **`CLAUDE.md` under 40k chars**, tables and pointers, narrative moved to
   `docs/` or deleted with the thing it described.
5. **The boot path is asserted, not assumed** — the colima/herdr plist gap can
   never recur silently.

## Non-goals

- No new tooling, no new abstractions, no Omarchy, no rewrite of anything that
  stays (secrets-run, tailnet ACL-as-code, herdr/Tailscale layering, Colima
  plist repair, brain-sync, collie — all keep their current shape).
- No changes to `homelab`, `vps`, `homelab-private` content; they are referenced
  from the map, not restructured.
- `meteo`'s missing plist templates (6 of 8 agents installed by hand) are
  *listed* on the map as a known gap; templating them is meteo's own pass.
- Hermes internals untouched beyond removing the retired `localai-helper`.
- No `brew upgrade` of anything as part of this pass.

## Decisions already made

| Area | Decision |
|-|-|
| Way in | keep `desk` (`herdr --remote`); **drop `dev` and mosh entirely** — zsh function, brew pin, ALF-allowlist target, `udp:60000-61000` ACL grant, heartbeat component, `brew-upgrade` invariant, `remote-dev-doctor` step, docs. `desk` cannot ride mosh (herdr speaks its own protocol over ssh; mosh is a terminal, not a tunnel), so roaming is the accepted loss: on a network change, re-run `desk`; panes live on the mini either way. |
| Terminal | drop cmux (cask, `TERM` workaround, second Ghostty config file). Plain Ghostty, one config file, themes still copied. |
| Launchers | `c` + `ca`. Drop OpenCode (`oc`, `opencode.json`, `AGENTS.md`, `opencode.zsh`, docs section). |
| Retired stacks | delete `localai/` + `/localai` skill; **stop + delete litellm** (`com.litellm.proxy`, `litellm/`, `docs/deepseek-litellm-bridge.md`) and remove sideclaw's dormant bridge path (usage-tracker's `litellm` collector stays for historical rows); remove `localai-helper` from hermes-agent. |
| Skills | drop `/sync` (pre-split world). Re-evaluate `/analyze` (its DeepSeek subprocess path dies with the bridge): keep only if it works without it. |
| Dev doors | drop `portdoor` (the 3 opt-in port doors, `host=rewrite`, the `.ports` flags, docs). |
| Diagnostics | one `make doctor` (read-only, self-routes on the backend marker) absorbing `remote-dev-doctor`, `mini-sweep`, `launchagents-check`, and drift-check's on-demand run. The daily drift agent and the 5-min heartbeat stay (notice unattended). |
| Pins | pin `caddy` only. Record on the map: a pin needs its deps pinned too, or it rots. |
| Dead dirs | `cqueue/` (untracked) + `docs/archive/queue-feature.md`; `docs/macbook-handover.md`, `docs/mini-move-handover.md`; MacBook `homelab-private` checkout. |
| Mini repos | archive-bundle + delete `sy-serendipity`, `vibe-stack`; fold `linewatch-router-spike/FINDINGS.md` into `linewatch/docs`, delete the dir; move `brain-sources` out of `~/SourceRoot`. Keep `meteo`, `hermes-webui` (upstream fork, live `WorkingDirectory`), `basalt-ui-obsidian`, `dispatch-scratch` — all get repo-table rows. |
| MacBook repos | `shutterflow` becomes a sanctioned exception (like `photo-flow`); sanctioned set = `dotfiles`, `dotfiles-private`, `photo-flow`, `shutterflow`, `brain`. |
| Colima/herdr plists | phase 0, first task. Re-converge through the existing `_setup-colima` / `make herdr-setup` paths **without restarting either job**; then research Homebrew 6.0's `brew services` change (it no longer lists either formula while `brew services info` says `started`) before trusting `brew services` output anywhere in the Makefile; add a boot-path assertion (plist exists + `launchctl print` path matches) to the heartbeat for colima, herdr, and every KeepAlive agent. |

## Technical approach — phases

Each phase is one or more `/implement` briefs on **disjoint file groups**,
verified and committed before the next. "Runs on" says where the change must be
*executed*; edits to tracked files can be made anywhere and pulled.

### Phase 0 — stop the bleeding, draw the map

| Task | Runs on | Human-timed? |
|-|-|-|
| 0.1 Re-converge colima + herdr plists, verify file + `launchctl print` path, no restart | mini | yes (touches live supervision) |
| 0.2 `/research` Homebrew 6.0 `brew services` semantics; patch every Makefile target that parses `brew services list` | MacBook | no |
| 0.3 Boot-path assertion in `devhost-health-check.sh` (plist on disk for every loaded `com.jkrumm.*`/`homebrew.mxcl.*` KeepAlive job) + `make colima-status` / `herdr-status` assert the same | MacBook, verify on mini | no |
| 0.4 `docs/architecture.md` from the inventory (appendix below): machines · repos per machine · agents per machine with owner repo + schedule + log path · doors · secrets flow · monitoring. Plus `scripts/architecture-check.sh` (folded into `make doctor` later): every loaded `com.jkrumm.*` label on this machine must appear in the map, else exit 1 | MacBook, run on both | no |

### Phase 1 — delete retired (parallel groups, disjoint files)

| Group | Files / state | Runs on |
|-|-|-|
| 1a localai | `localai/`, `.claude/skills/localai/`, Makefile targets, Brewfile/uv deps, CLAUDE.md section; hermes-agent `localai-helper` (one `dispatch implement`) | MacBook; hermes bit on mini |
| 1b litellm | bootout `com.litellm.proxy`, delete `litellm/`, `docs/deepseek-litellm-bridge.md`, Makefile targets, heartbeat component, CLAUDE.md; sideclaw bridge removal (one `dispatch implement`, keep the `iu-openai` usage sink) | bootout on mini; rest MacBook |
| 1c OpenCode | `config/opencode/`, `config/zsh/opencode.zsh`, zshrc line, symlink-map rows, Makefile setup step, CLAUDE.md section, Brewfile entry if any | MacBook |
| 1d skills + dirs | `skills/sync/`, `/analyze` decision, `cqueue/` (untracked, rm), `docs/archive/`, both handover docs, MacBook `homelab-private` | MacBook |
| 1e mini dirs | bundle `sy-serendipity` + `vibe-stack` → `~/SourceRoot-archive`, delete; `linewatch-router-spike/FINDINGS.md` → `linewatch/docs/router-spike.md` (one `dispatch implement` in linewatch), delete dir; `brain-sources` → `~/Documents/brain-sources` | mini |

### Phase 2 — collapse duplicates (parallel groups, disjoint files)

| Group | Files / state | Runs on |
|-|-|-|
| 2a mosh/dev | `config/zsh/remote-dev.zsh` (`dev` fn), Brewfile (`mosh`), `_setup-packages` pin list, `make mosh-allow`/ALF targets, heartbeat `check_mosh`, `brew-upgrade.sh` invariant, `remote-dev-doctor` step, `config/ssh_config` if any mosh-specific lines, `dotfiles-private/tailscale-acl.jsonc` `udp:60000-61000` grant, docs. `brew unpin mosh && brew uninstall mosh` on both machines. ACL push from the MacBook (biometric). | edits MacBook; uninstall both; ACL push MacBook |
| 2b cmux/Ghostty | Brewfile (`cmux` cask), collapse `config/ghostty/config` + `config.appsupport` into one file + one symlink row, `_setup-ghostty`, `SetEnv TERM` note in `ssh_config` (keep the line, drop the cmux rationale), `## Terminal Setup` + theme doc references. Uninstall cmux on both. | MacBook |
| 2c portdoor | `scripts/caddy-tailnet.sh` + `caddy-registry.py` (`portdoor`/`host=rewrite` flags), `~/.config/caddy-tailnet.ports` on the mini, `check_dev_vhosts`, docs. Keep the `exclude` flag. | edits MacBook; `make caddy-tailnet` on mini |
| 2d `make doctor` | new `scripts/doctor.sh` composing the surviving checks from `remote-dev-doctor.sh`, `mini-sweep`, `launchagents-check.sh`, `drift-check.sh --once`, `architecture-check.sh`; self-routes on the backend marker; delete the four standalone targets, keep the drift LaunchAgent pointing at the same script. `make status` calls it. | MacBook, run on both |
| 2e pins | `_setup-packages` pin list → `caddy` only; `brew-upgrade.sh` invariants reduced accordingly | MacBook |

### Phase 3 — docs rewrite

- `dotfiles/CLAUDE.md` rewritten section by section to **< 40k chars**: every
  section becomes commands + table + one-line gotchas + a `docs/X.md` pointer.
  Narrative for things that *stay* moves verbatim into the matching `docs/`
  file; narrative for things deleted in phases 1–2 is deleted. Gate: `wc -c`.
- `config/global.CLAUDE.md`: repo table gains `meteo`, `hermes-webui`,
  `basalt-ui-obsidian`, `shutterflow`, `dispatch-scratch`; sanctioned set
  updated; every mosh/cmux/OpenCode/`dev`/`/sync` mention removed; Machines
  section points at `docs/architecture.md`.
- `docs/remote-dev.md`: mosh, `dev`, portdoor sections removed; herdr/`desk`
  kept.
- Memory files under `~/.claude/projects/…/memory/` that mention `/sync` or
  `dev` updated.

## Success criteria

| Check | Pass condition |
|-|-|
| `wc -c CLAUDE.md` | < 40,000 |
| `grep -rli -E 'mosh|cmux|opencode|localai|litellm' --exclude-dir=.git .` | only `docs/archive`-free history: **0 files** (git log is the archive) |
| `make setup` on MacBook and mini | idempotent, exit 0, no manual step |
| `make hooks-test`, `make brew-check` (both machines), `shellcheck` on touched scripts | green |
| `desk` from the MacBook | attaches; `dev` is not a command |
| `make doctor` on both machines | exit 0; every loaded `com.jkrumm.*` / `homebrew.mxcl.*` label appears in `docs/architecture.md` |
| Colima + herdr | plist on disk on the mini, `launchctl print` path matches, heartbeat asserts it; a **deliberate, scheduled** `sudo shutdown -r now` on the mini brings colima, herdr, every listed agent and the heartbeat back UP within `DEVHOST_BOOT_GRACE_SECONDS` |
| `com.litellm.proxy` | not loaded, no plist, no `litellm` process |
| Tailnet ACL | no `udp:60000-61000` grant; `make tailscale-acl-diff` clean after push |
| Repo tables | every dir in `~/SourceRoot` on either machine has a row in `docs/architecture.md`, or does not exist |

## Appendix — inventory (2026-08-30)

### Mini repos not in the current repo table

| Repo | State | Disposition |
|-|-|-|
| `meteo` | daily commits, 8 LaunchAgents (`backfill`, `blendfield`, `fcstlog`, `obs`, `serve`, `sync`, `tileserver`, `watchdog`), 3 processes; 6 agents have no plist in-repo; README empty, purpose in PRD.md | keep, map, flag plist gap |
| `hermes-webui` | unmodified upstream fork, `WorkingDirectory` of `com.jkrumm.hermes-webui` | keep, map as dependency checkout |
| `basalt-ui-obsidian` | v0 unreleased, active | keep, map |
| `dispatch-scratch` | disposable dispatch test target by design | keep, map |
| `brain-sources` | not git; epub + folder | move out |
| `linewatch-router-spike` | not git; RE spike, `FINDINGS.md` | fold + delete |
| `sy-serendipity` | 2026-05-04 | archive + delete |
| `vibe-stack` | 2026-06-02 | archive + delete |

### LaunchAgents on the mini by owner repo

| Owner | Labels |
|-|-|
| dotfiles | `brain-backup` 03:30 · `brain-sync` 300s · `brain-web-refresh` 300s · `devhost-health` 300s · `drift-check` 09:40 · `lock-at-boot` RunAtLoad · `log-rotate` 3600s · `obsidian-autostart` RunAtLoad · `com.litellm.proxy` KeepAlive (**delete**) · `homebrew.mxcl.colima` KeepAlive (**plist missing**) · `homebrew.mxcl.herdr` KeepAlive (**plist missing**) · `com.colima.docker-socket` daemon · `homebrew.mxcl.caddy` daemon |
| hermes-agent | `ai.hermes.gateway` (generated by hermes_cli) · `hermes-serve` · `hermes-webui` · `hermes-backup` 03:00 · `hermes-liveness` · `hermes-serve-liveness` · `hermes-webui-liveness` (all 300s) |
| meteo | 8 (see above) — `tileserver` last exit SIGTERM under KeepAlive |
| linewatch | `linewatch-collector-agent` · `linewatch-watchdog` (KeepAlive) · `linewatch-heartbeat` 60s |
| sideclaw | `sideclaw-server` KeepAlive |
| usage-tracker | `usage-tracker` 900s |
| king-smith-walkingpad-mac | `walkingpad` KeepAlive |
| third-party / stock | `herdr.collie` · `homebrew.mxcl.dnsmasq` · `homebrew.mxcl.tailscale` |

### LaunchAgents on the MacBook

`batt-reset` · `brain-sync` · `db-tunnel` · `opbackup` · `photoflow` (logs to `/tmp`, known) · `tailnet-sshd` · `homebrew.mxcl.colima`.

### Brew state on the mini

Pinned `caddy`, `mosh`. Outdated: `mosh` 1.4.0_40→_41 (held, broken dylib), `age`, `libomp`, `mole`, `node`; casks incl. `cmux`. `brew services list` does not enumerate `colima`/`herdr` (Homebrew 6.0.20).
